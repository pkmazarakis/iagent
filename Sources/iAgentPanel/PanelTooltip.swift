import AppKit
import SwiftUI

extension Notification.Name {
    static let panelWindowWillOrderOut = Notification.Name(
        "iAgentPanel.PanelWindowWillOrderOut"
    )
}

enum PanelTooltipMetrics {
    static let defaultDelay: TimeInterval = 0.5
    static let gap: CGFloat = 6
    static let edgeInset: CGFloat = 8
    static let textWidth: CGFloat = 240

    static func frame(
        anchorRect: NSRect,
        tooltipSize: NSSize,
        parentFrame: NSRect,
        screenFrame: NSRect
    ) -> NSRect {
        let safeScreenFrame = screenFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let parentScreenIntersection = parentFrame.intersection(safeScreenFrame)
        let horizontalBounds = parentScreenIntersection.width >= tooltipSize.width
            ? parentScreenIntersection
            : safeScreenFrame

        let minimumX = horizontalBounds.minX
        let maximumX = max(minimumX, horizontalBounds.maxX - tooltipSize.width)
        let proposedX = anchorRect.midX - tooltipSize.width / 2
        let x = min(max(proposedX, minimumX), maximumX)

        let belowY = anchorRect.minY - gap - tooltipSize.height
        let aboveY = anchorRect.maxY + gap
        let y: CGFloat
        if belowY >= safeScreenFrame.minY {
            y = belowY
        } else if aboveY + tooltipSize.height <= safeScreenFrame.maxY {
            y = aboveY
        } else {
            let maximumY = max(safeScreenFrame.minY, safeScreenFrame.maxY - tooltipSize.height)
            y = min(max(belowY, safeScreenFrame.minY), maximumY)
        }

        return NSRect(origin: NSPoint(x: x, y: y), size: tooltipSize)
    }
}

@MainActor
final class PanelTooltipHoverGate {
    var delay: TimeInterval
    var onShow: () -> Void
    var onHide: () -> Void

    private(set) var isHovering = false
    private(set) var hasPendingShow = false
    private(set) var isPresented = false

    private var generation = 0
    private var pendingTask: Task<Void, Never>?

    init(
        delay: TimeInterval = PanelTooltipMetrics.defaultDelay,
        onShow: @escaping () -> Void,
        onHide: @escaping () -> Void
    ) {
        self.delay = delay
        self.onShow = onShow
        self.onHide = onHide
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering

        if hovering {
            scheduleShow()
        } else {
            cancelPendingShow()
            if isPresented {
                isPresented = false
                onHide()
            }
        }
    }

    func cancel() {
        isHovering = false
        cancelPendingShow()
        if isPresented {
            isPresented = false
            onHide()
        }
    }

    func firePendingForTesting() {
        revealIfCurrent(generation: generation)
    }

    private func scheduleShow() {
        cancelPendingShow()
        generation &+= 1
        let scheduledGeneration = generation
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        hasPendingShow = true
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.revealIfCurrent(generation: scheduledGeneration)
        }
    }

    private func cancelPendingShow() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        hasPendingShow = false
    }

    private func revealIfCurrent(generation scheduledGeneration: Int) {
        guard isHovering,
              hasPendingShow,
              scheduledGeneration == generation
        else {
            return
        }
        pendingTask = nil
        hasPendingShow = false
        isPresented = true
        onShow()
    }
}

@MainActor
final class PanelTooltipPresenter {
    private(set) var tooltipWindow: PanelTooltipWindow?
    var onParentWindowUnavailable: (() -> Void)?

    private var parentWindowObservers: [PanelTooltipObserverToken] = []

    deinit {
        for observer in parentWindowObservers {
            NotificationCenter.default.removeObserver(observer.value)
        }
    }

    func show(text: String, anchorView: NSView) {
        guard !text.isEmpty,
              let parentWindow = anchorView.window,
              parentWindow.isVisible
        else {
            hide()
            return
        }

        hide()

        let tooltipWindow = PanelTooltipWindow()
        let hostingView = NSHostingView(
            rootView: PanelTooltipBubble(text: text)
                .environment(\.colorScheme, .dark)
        )
        hostingView.sizingOptions = [.intrinsicContentSize]
        let tooltipSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: tooltipSize)

        tooltipWindow.contentView = hostingView
        tooltipWindow.setContentSize(tooltipSize)
        tooltipWindow.level = parentWindow.level
        tooltipWindow.appearance = parentWindow.appearance ?? NSAppearance(named: .darkAqua)

        let anchorRectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorRectOnScreen = parentWindow.convertToScreen(anchorRectInWindow)
        let screenFrame = parentWindow.screen?.frame ?? NSScreen.main?.frame ?? parentWindow.frame
        let tooltipFrame = PanelTooltipMetrics.frame(
            anchorRect: anchorRectOnScreen,
            tooltipSize: tooltipSize,
            parentFrame: parentWindow.frame,
            screenFrame: screenFrame
        )
        tooltipWindow.setFrame(tooltipFrame, display: true)

        parentWindow.addChildWindow(tooltipWindow, ordered: .above)
        tooltipWindow.orderFront(nil)
        self.tooltipWindow = tooltipWindow
        observeVisibility(of: parentWindow)
    }

    func hide() {
        stopObservingParentWindow()
        guard let tooltipWindow else { return }
        if let parentWindow = tooltipWindow.parent {
            parentWindow.removeChildWindow(tooltipWindow)
        }
        tooltipWindow.orderOut(nil)
        self.tooltipWindow = nil
    }

    private func observeVisibility(of parentWindow: NSWindow) {
        stopObservingParentWindow()
        let center = NotificationCenter.default
        parentWindowObservers = [
            PanelTooltipObserverToken(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self, weak parentWindow] _ in
                MainActor.assumeIsolated {
                    guard let self, let parentWindow else { return }
                    if !parentWindow.isVisible
                        || !parentWindow.occlusionState.contains(.visible)
                    {
                        self.parentWindowBecameUnavailable()
                    }
                }
            }),
            PanelTooltipObserverToken(center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.parentWindowBecameUnavailable()
                }
            }),
            PanelTooltipObserverToken(center.addObserver(
                forName: .panelWindowWillOrderOut,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.parentWindowBecameUnavailable()
                }
            }),
        ]
    }

    private func stopObservingParentWindow() {
        let center = NotificationCenter.default
        for observer in parentWindowObservers {
            center.removeObserver(observer.value)
        }
        parentWindowObservers.removeAll()
    }

    private func parentWindowBecameUnavailable() {
        onParentWindowUnavailable?()
        hide()
    }
}

private final class PanelTooltipObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol

    init(_ value: NSObjectProtocol) {
        self.value = value
    }
}

final class PanelTooltipWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

private struct PanelTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.88))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: PanelTooltipMetrics.textWidth, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color(red: 0.12, green: 0.12, blue: 0.13),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
    }
}

private struct PanelTooltipModifier: ViewModifier {
    let text: String
    let delay: TimeInterval

    func body(content: Content) -> some View {
        content.background {
            PanelTooltipAnchor(text: text, delay: delay)
        }
    }
}

private struct PanelTooltipAnchor: NSViewRepresentable {
    let text: String
    let delay: TimeInterval

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, delay: delay)
    }

    func makeNSView(context: Context) -> PanelTooltipTrackingView {
        let view = PanelTooltipTrackingView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: PanelTooltipTrackingView, context: Context) {
        context.coordinator.update(text: text, delay: delay)
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(
        _ nsView: PanelTooltipTrackingView,
        coordinator: Coordinator
    ) {
        nsView.onHoverChange = nil
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        private var text: String
        private weak var anchorView: PanelTooltipTrackingView?
        private let presenter = PanelTooltipPresenter()
        private lazy var hoverGate = PanelTooltipHoverGate(
            delay: delay,
            onShow: { [weak self] in
                guard let self, let anchorView = self.anchorView else { return }
                self.presenter.show(text: self.text, anchorView: anchorView)
            },
            onHide: { [weak self] in
                self?.presenter.hide()
            }
        )
        private var delay: TimeInterval

        init(text: String, delay: TimeInterval) {
            self.text = text
            self.delay = delay
        }

        func attach(to view: PanelTooltipTrackingView) {
            anchorView = view
            presenter.onParentWindowUnavailable = { [weak self] in
                self?.hoverGate.cancel()
            }
            view.onHoverChange = { [weak self] hovering in
                self?.hoverGate.setHovering(hovering)
            }
        }

        func update(text: String, delay: TimeInterval) {
            let textChanged = self.text != text
            self.text = text
            self.delay = delay
            hoverGate.delay = delay
            if textChanged, hoverGate.isPresented, let anchorView {
                presenter.show(text: text, anchorView: anchorView)
            }
        }

        func cancel() {
            hoverGate.cancel()
            presenter.hide()
            presenter.onParentWindowUnavailable = nil
            anchorView = nil
        }
    }
}

private final class PanelTooltipTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self
            )
        )
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func mouseEntered(with _: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with _: NSEvent) {
        onHoverChange?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            onHoverChange?(false)
        }
    }
}

extension View {
    func panelTooltip(
        text: String,
        delay: TimeInterval = PanelTooltipMetrics.defaultDelay
    ) -> some View {
        modifier(PanelTooltipModifier(text: text, delay: delay))
    }
}

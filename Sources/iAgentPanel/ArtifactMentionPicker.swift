@preconcurrency import AppKit
import QuartzCore
import SwiftUI
import iAgentCore

/// Presents artifact suggestions in a separate nonactivating child panel. The
/// panel is intentionally outside the main panel's masked SwiftUI hierarchy so
/// a tall result list is not clipped by the panel contour or an editor scroll
/// view, and the active editor remains first responder while the list is open.
@MainActor
struct ArtifactMentionPickerAnchor: NSViewRepresentable {
    @Binding var text: String
    let mentions: [ArtifactMention]
    let writesMarkdown: Bool
    let isActive: Bool
    var requiresFirstResponderInsideAnchor = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ArtifactMentionAnchorView {
        let view = ArtifactMentionAnchorView()
        view.coordinator = context.coordinator
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: ArtifactMentionAnchorView, context: Context) {
        context.coordinator.update(
            anchorView: nsView,
            text: $text,
            mentions: mentions,
            writesMarkdown: writesMarkdown,
            isActive: isActive,
            requiresFirstResponderInsideAnchor: requiresFirstResponderInsideAnchor
        )
    }

    static func dismantleNSView(_ nsView: ArtifactMentionAnchorView, coordinator: Coordinator) {
        coordinator.tearDown()
        nsView.coordinator = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var anchorView: ArtifactMentionAnchorView?
        private let presenter = ArtifactMentionPopoverPresenter()

        func update(
            anchorView: ArtifactMentionAnchorView,
            text: Binding<String>,
            mentions: [ArtifactMention],
            writesMarkdown: Bool,
            isActive: Bool,
            requiresFirstResponderInsideAnchor: Bool
        ) {
            self.anchorView = anchorView
            presenter.update(
                anchorView: anchorView,
                text: text,
                mentions: mentions,
                writesMarkdown: writesMarkdown,
                isActive: isActive,
                requiresFirstResponderInsideAnchor: requiresFirstResponderInsideAnchor
            )
        }

        func anchorDidMoveToWindow() {
            guard let anchorView else { return }
            presenter.anchorDidMoveToWindow(anchorView)
        }

        func tearDown() {
            presenter.tearDown()
        }
    }
}

@MainActor
final class ArtifactMentionAnchorView: NSView {
    weak var coordinator: ArtifactMentionPickerAnchor.Coordinator?

    override var isFlipped: Bool { true }
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.anchorDidMoveToWindow()
    }
}

extension View {
    /// Attaches the desktop artifact picker without changing the control's
    /// layout or hit testing.
    func artifactMentionPicker(
        text: Binding<String>,
        mentions: [ArtifactMention],
        writesMarkdown: Bool,
        isActive: Bool,
        requiresFirstResponderInsideAnchor: Bool = false
    ) -> some View {
        background {
            ArtifactMentionPickerAnchor(
                text: text,
                mentions: mentions,
                writesMarkdown: writesMarkdown,
                isActive: isActive,
                requiresFirstResponderInsideAnchor: requiresFirstResponderInsideAnchor
            )
            .allowsHitTesting(false)
        }
    }
}

private enum ArtifactMentionPickerGeometry {
    static let surfaceWidth: CGFloat = 352
    static let emptyHeight: CGFloat = 48
    static let maximumViewportHeight: CGFloat = 388
    static let sectionHorizontalInset: CGFloat = 12
    static let sectionHeaderHeight: CGFloat = 22
    static let sectionHeaderBottomSpacing: CGFloat = 4
    static let rowHeight: CGFloat = 34
    static let rowSelectionHorizontalInset: CGFloat = 7
    static let rowLeadingPadding: CGFloat = 5
    static let rowTrailingPadding: CGFloat = 8
    static let selectionCornerRadius: CGFloat = 6
    static let scrollFadeHeight: CGFloat = 24
}

@MainActor
private final class ArtifactMentionPickerModel: ObservableObject {
    @Published private(set) var sections: [ArtifactMentionSection] = []
    @Published private(set) var selectedMentionID: String?
    @Published private(set) var hoveredMentionID: String?
    @Published private(set) var viewportHeight = ArtifactMentionPickerGeometry.emptyHeight
    @Published private(set) var isScrollable = false

    private var queryText = ""
    private var selectionHandler: ((ArtifactMention) -> Void)?

    var visibleItems: [ArtifactMention] {
        sections.flatMap(\.items)
    }

    var contentHeight: CGFloat {
        guard !sections.isEmpty else { return ArtifactMentionPickerGeometry.emptyHeight }
        return sections.reduce(0) { height, section in
            height
                + ArtifactMentionPickerGeometry.sectionHeaderHeight
                + ArtifactMentionPickerGeometry.sectionHeaderBottomSpacing
                + CGFloat(section.items.count) * ArtifactMentionPickerGeometry.rowHeight
        }
    }

    func update(
        sections: [ArtifactMentionSection],
        queryText: String,
        selectionHandler: @escaping (ArtifactMention) -> Void
    ) {
        let previousIDs = visibleItems.map(\.id)
        let nextIDs = sections.flatMap(\.items).map(\.id)
        let queryChanged = self.queryText != queryText
        self.queryText = queryText
        self.selectionHandler = selectionHandler

        if self.sections != sections {
            self.sections = sections
        }

        if queryChanged || previousIDs != nextIDs
            || selectedMentionID.map({ !nextIDs.contains($0) }) == true
        {
            selectedMentionID = nextIDs.first
        } else if selectedMentionID == nil {
            selectedMentionID = nextIDs.first
        }
    }

    func setViewportHeight(_ height: CGFloat) {
        let resolved = max(ArtifactMentionPickerGeometry.emptyHeight, height)
        if abs(viewportHeight - resolved) > 0.5 {
            viewportHeight = resolved
        }
        let scrollable = contentHeight > resolved + 0.5
        if isScrollable != scrollable {
            isScrollable = scrollable
        }
    }

    func moveSelection(_ delta: Int) {
        let items = visibleItems
        guard !items.isEmpty, delta != 0 else { return }

        let currentIndex = selectedMentionID.flatMap { id in
            items.firstIndex(where: { $0.id == id })
        }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(items.count - 1, max(0, currentIndex + delta))
        } else {
            // A missing/stale selection enters the flattened list in the
            // direction of travel instead of skipping an edge item.
            nextIndex = delta > 0 ? 0 : items.count - 1
        }
        selectedMentionID = items[nextIndex].id
    }

    func selectCurrent() {
        guard let selectedMentionID,
              let mention = visibleItems.first(where: { $0.id == selectedMentionID })
        else { return }
        select(mention)
    }

    func select(_ mention: ArtifactMention) {
        selectionHandler?(mention)
    }

    func setHovered(_ id: String, hovering: Bool) {
        if hovering {
            hoveredMentionID = id
        } else if hoveredMentionID == id {
            hoveredMentionID = nil
        }
    }
}

@MainActor
private struct ArtifactMentionPopoverContent: View {
    @ObservedObject var model: ArtifactMentionPickerModel

    var body: some View {
        VStack(spacing: 0) {
            if model.sections.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("No matching artifacts")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                    Spacer()
                }
                .padding(.horizontal, ArtifactMentionPickerGeometry.sectionHorizontalInset)
                .frame(height: ArtifactMentionPickerGeometry.emptyHeight)
            } else {
                mentionList
            }
        }
        .frame(width: ArtifactMentionPickerGeometry.surfaceWidth)
        .background(
            Color(red: 0.075, green: 0.075, blue: 0.08).opacity(0.985),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Artifact suggestions")
        .accessibilityIdentifier("artifact-mention-picker")
    }

    private var mentionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sections) { section in
                        sectionHeader(section.kind)
                        ForEach(section.items) { mention in
                            mentionRow(mention)
                                .id(mention.id)
                        }
                    }
                }
            }
            .frame(height: model.viewportHeight)
            .scrollIndicators(.visible)
            .overlay(alignment: .bottom) {
                if model.isScrollable {
                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.56)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: ArtifactMentionPickerGeometry.scrollFadeHeight)
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: model.selectedMentionID) { _, selectedID in
                guard let selectedID else { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    proxy.scrollTo(selectedID, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
            .onAppear {
                if let selectedID = model.selectedMentionID {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ kind: ArtifactMentionKind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(kind.displayName.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(.white.opacity(0.4))
        .padding(.horizontal, ArtifactMentionPickerGeometry.sectionHorizontalInset)
        .frame(
            height: ArtifactMentionPickerGeometry.sectionHeaderHeight,
            alignment: .bottomLeading
        )
        .padding(.bottom, ArtifactMentionPickerGeometry.sectionHeaderBottomSpacing)
    }

    private func mentionRow(_ mention: ArtifactMention) -> some View {
        Button {
            model.select(mention)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mention.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                if let subtitle = mention.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "return")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        .white.opacity(model.selectedMentionID == mention.id ? 0.48 : 0.22)
                    )
            }
            .padding(.leading, ArtifactMentionPickerGeometry.rowLeadingPadding)
            .padding(.trailing, ArtifactMentionPickerGeometry.rowTrailingPadding)
            .frame(height: ArtifactMentionPickerGeometry.rowHeight)
            .background(
                model.selectedMentionID == mention.id || model.hoveredMentionID == mention.id
                    ? Color.agentBlue.opacity(0.16)
                    : .clear,
                in: RoundedRectangle(
                    cornerRadius: ArtifactMentionPickerGeometry.selectionCornerRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ArtifactMentionPickerGeometry.rowSelectionHorizontalInset)
        .onHover { model.setHovered(mention.id, hovering: $0) }
        .accessibilityLabel(
            [mention.kind.displayName, mention.title, mention.subtitle]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

}

@MainActor
private final class ArtifactMentionPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ArtifactMentionPopoverPresenter {
    private let model = ArtifactMentionPickerModel()
    private weak var anchorView: NSView?
    private var panel: ArtifactMentionPopoverPanel?
    private var hostingView: NSHostingView<ArtifactMentionPopoverContent>?
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var currentText: Binding<String>?
    private var currentMentions: [ArtifactMention] = []
    private var writesMarkdown = false
    private var isActive = false
    private var requiresFirstResponderInsideAnchor = false
    private var suppressedText: String?

    private static let edgeInset: CGFloat = 10
    private static let anchorGap: CGFloat = 8

    func update(
        anchorView: NSView,
        text: Binding<String>,
        mentions: [ArtifactMention],
        writesMarkdown: Bool,
        isActive: Bool,
        requiresFirstResponderInsideAnchor: Bool
    ) {
        self.anchorView = anchorView
        currentText = text
        currentMentions = mentions
        self.writesMarkdown = writesMarkdown
        self.isActive = isActive
        self.requiresFirstResponderInsideAnchor = requiresFirstResponderInsideAnchor
        if suppressedText != text.wrappedValue {
            suppressedText = nil
        }
        installWindowObservers(for: anchorView.window)
        refreshPresentation()
    }

    func anchorDidMoveToWindow(_ anchorView: NSView) {
        self.anchorView = anchorView
        installWindowObservers(for: anchorView.window)
        refreshPresentation()
    }

    func tearDown() {
        hide()
        removeWindowObservers()
        hostingView = nil
        panel = nil
        currentText = nil
    }

    private func refreshPresentation() {
        guard let anchorView,
              let text = currentText,
              isActive,
              suppressedText != text.wrappedValue,
              (!requiresFirstResponderInsideAnchor || firstResponderIsInside(anchorView)),
              let query = ArtifactMentionQuery(input: text.wrappedValue)
        else {
            hide()
            return
        }

        let sections = ArtifactMentionCatalog.sections(
            matching: query.text,
            in: currentMentions,
            itemsPerSection: 3
        )
        model.update(sections: sections, queryText: query.text) { [weak self] mention in
            self?.select(mention)
        }
        show(relativeTo: anchorView)
    }

    private func select(_ mention: ArtifactMention) {
        guard let text = currentText,
              let query = ArtifactMentionQuery(input: text.wrappedValue)
        else {
            hide()
            return
        }
        var value = text.wrappedValue
        query.replacing(in: &value, with: mention, markdown: writesMarkdown)
        if !value.hasSuffix(" ") {
            value.append(" ")
        }
        text.wrappedValue = value
        hide()
    }

    private func show(relativeTo anchorView: NSView) {
        guard let parentWindow = anchorView.window,
              let screen = parentWindow.screen ?? NSScreen.main
        else {
            hide()
            return
        }

        let panel = ensurePanel(parentWindow: parentWindow)
        let anchorOnScreen = presentationAnchorRect(
            for: anchorView,
            in: parentWindow
        )
        let screenFrame = screen.visibleFrame.insetBy(
            dx: Self.edgeInset,
            dy: Self.edgeInset
        )

        let desiredViewportHeight = min(
            ArtifactMentionPickerGeometry.maximumViewportHeight,
            model.contentHeight
        )
        let desiredHeight = desiredViewportHeight
        let availableBelow = max(0, anchorOnScreen.minY - screenFrame.minY - Self.anchorGap)
        let availableAbove = max(0, screenFrame.maxY - anchorOnScreen.maxY - Self.anchorGap)
        let placeBelow: Bool
        if availableBelow >= desiredHeight {
            placeBelow = true
        } else if availableAbove >= desiredHeight {
            placeBelow = false
        } else {
            placeBelow = availableBelow >= availableAbove
        }

        let availableHeight = max(
            ArtifactMentionPickerGeometry.emptyHeight,
            placeBelow ? availableBelow : availableAbove
        )
        let panelHeight = min(desiredHeight, availableHeight)
        model.setViewportHeight(panelHeight)

        let width = min(ArtifactMentionPickerGeometry.surfaceWidth, screenFrame.width)
        let x = min(
            max(screenFrame.minX, anchorOnScreen.minX),
            screenFrame.maxX - width
        )
        let y = placeBelow
            ? anchorOnScreen.minY - Self.anchorGap - panelHeight
            : anchorOnScreen.maxY + Self.anchorGap
        let frame = NSRect(x: x, y: y, width: width, height: panelHeight)
        let wasVisible = panel.isVisible
        panel.setFrame(frame, display: true)

        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFrontRegardless()
        installEventMonitorIfNeeded()

        guard !wasVisible else {
            panel.alphaValue = 1
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.2,
                    0.8,
                    0.2,
                    1
                )
                panel.animator().alphaValue = 1
            }
        }
    }

    private func ensurePanel(parentWindow: NSWindow) -> ArtifactMentionPopoverPanel {
        if let panel { return panel }

        let panel = ArtifactMentionPopoverPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ArtifactMentionPickerGeometry.surfaceWidth,
                height: ArtifactMentionPickerGeometry.emptyHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = parentWindow.collectionBehavior
        panel.level = NSWindow.Level(rawValue: parentWindow.level.rawValue + 1)

        let hostingView = NSHostingView(
            rootView: ArtifactMentionPopoverContent(model: model)
        )
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = panel.contentView?.bounds ?? .zero
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView
        return panel
    }

    private func hide() {
        removeEventMonitor()
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        panel.orderOut(nil)
        panel.parent?.removeChildWindow(panel)
    }

    private func handleEvent(
        windowNumber: Int,
        hasDisallowedModifiers: Bool,
        keyCode: UInt16
    ) -> Bool {
        guard let panel, panel.isVisible, let anchorView else { return false }
        guard windowNumber == anchorView.window?.windowNumber,
              !hasDisallowedModifiers
        else { return false }

        switch keyCode {
        case 125: // Down arrow
            guard !model.visibleItems.isEmpty else { return false }
            model.moveSelection(1)
            return true
        case 126: // Up arrow
            guard !model.visibleItems.isEmpty else { return false }
            model.moveSelection(-1)
            return true
        case 36, 76: // Return / keypad Enter
            guard !model.visibleItems.isEmpty else { return false }
            model.selectCurrent()
            return true
        case 53: // Escape
            suppressedText = currentText?.wrappedValue
            hide()
            return true
        default:
            return false
        }
    }

    /// Hidden picker attachments must be completely inert. Install the local
    /// key monitor only while this presenter's child panel is visible; pointer
    /// events always travel through AppKit normally, including picker-row
    /// clicks in the child panel.
    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let windowNumber = event.windowNumber
            let hasDisallowedModifiers = !event.modifierFlags
                .intersection([.command, .control, .option])
                .isEmpty
            let keyCode = event.keyCode
            let consumed = MainActor.assumeIsolated {
                self?.handleEvent(
                    windowNumber: windowNumber,
                    hasDisallowedModifiers: hasDisallowedModifiers,
                    keyCode: keyCode
                ) == true
            }
            return consumed ? nil : event
        }
    }

    private func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func firstResponderIsInside(_ anchorView: NSView) -> Bool {
        guard let window = anchorView.window,
              window.isKeyWindow,
              let responderView = window.firstResponder as? NSView,
              responderView.window === window
        else { return false }

        if responderView === anchorView
            || responderView.isDescendant(of: anchorView)
            || anchorView.isDescendant(of: responderView)
        {
            return true
        }

        let anchorFrame = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        let responderFrame = window.convertToScreen(
            responderView.convert(responderView.bounds, to: nil)
        )
        let intersection = anchorFrame.intersection(responderFrame)
        return !intersection.isNull
            && intersection.width > 2
            && intersection.height > 2
    }

    /// NSTextInputClient reports its first rect in screen coordinates. Using
    /// that insertion rect keeps the menu beside multiline text instead of at
    /// the far edge of the containing editor. SwiftUI fields that do not
    /// expose a field editor fall back to their full control bounds.
    private func presentationAnchorRect(
        for anchorView: NSView,
        in window: NSWindow
    ) -> NSRect {
        if let textView = window.firstResponder as? NSTextView,
           firstResponderIsInside(anchorView)
        {
            let selection = textView.selectedRange()
            let insertionRange = NSRange(location: selection.location, length: 0)
            var actualRange = NSRange(location: NSNotFound, length: 0)
            let insertionRect = textView.firstRect(
                forCharacterRange: insertionRange,
                actualRange: &actualRange
            )
            if insertionRect.width.isFinite,
               insertionRect.height.isFinite,
               insertionRect.minX.isFinite,
               insertionRect.minY.isFinite,
               !insertionRect.isEmpty
            {
                return insertionRect
            }
        }

        let anchorInWindow = anchorView.convert(anchorView.bounds, to: nil)
        return window.convertToScreen(anchorInWindow)
    }

    private func installWindowObservers(for window: NSWindow?) {
        removeWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSText.didBeginEditingNotification,
            NSText.didEndEditingNotification,
        ]
        windowObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak window] note in
                if let observedWindow = note.object as? NSWindow, observedWindow !== window {
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    self?.refreshPresentation()
                }
            }
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
    }
}

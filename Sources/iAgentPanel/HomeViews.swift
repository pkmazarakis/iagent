import AppKit
import SwiftUI

enum HomeSection: Int, CaseIterable, Identifiable, Sendable {
    case calendar
    case codex
    case todos

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .codex: "Codex"
        case .todos: "Todos"
        }
    }
}

private enum HomeAssets {
    static let calendarOutline = svg(
        named: "calendar-outline",
        size: NSSize(width: 18, height: 18)
    )
    static let calendarDigits: [Int: NSImage] = Dictionary(
        uniqueKeysWithValues: (0 ... 9).compactMap { digit in
            svg(
                named: "calendar-digit-\(digit)",
                size: NSSize(width: 5, height: 8)
            ).map { (digit, $0) }
        }
    )

    private static func svg(named name: String, size: NSSize) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "CalendarDays"
        ), let image = NSImage(contentsOf: url), let copy = image.copy() as? NSImage
        else {
            return nil
        }
        copy.isTemplate = true
        copy.size = size
        return copy
    }
}

struct HomeDashboardView: View {
    @ObservedObject var controller: PanelController
    @ObservedObject private var calendarService: CalendarEventService

    init(controller: PanelController) {
        self.controller = controller
        _calendarService = ObservedObject(wrappedValue: controller.calendarService)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            briefing(at: context.date)
        }
    }

    private func briefing(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            briefingText(at: date)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .frame(height: 88)
    }

    private func greeting(at date: Date) -> String {
        switch Calendar.autoupdatingCurrent.component(.hour, from: date) {
        case 0 ..< 12: "Good morning"
        case 12 ..< 17: "Good afternoon"
        default: "Good evening"
        }
    }

    private func briefingText(at date: Date) -> some View {
        let eventCount = calendarService.events.count
        let liveCount = controller.activeCount
        let todoCount = controller.openTodoCount
        let muted = Color.white.opacity(0.4)
        let primary = Color.white.opacity(0.93)
        let scheduleWords = Array(scheduleOutlook(at: date).split(separator: " "))
        let day = 31

        return InlineFlowLayout(horizontalSpacing: 5, verticalSpacing: 2) {
            Text("\(greeting(at: date)),")
                .foregroundStyle(muted)

            if let name = controller.localFirstName {
                Text("\(name).")
                    .foregroundStyle(primary)
            }

            Text("You have")
                .foregroundStyle(muted)

            HomeBriefingLink(action: { open(.calendar) }) { hovering in
                HStack(spacing: 5) {
                    CalendarDayFlowIcon(
                        day: day,
                        color: .white.opacity(0.93),
                        isHovering: hovering
                    )

                    Text("\(eventCount) \(eventCount == 1 ? "event" : "events"),")
                        .foregroundStyle(primary)
                        .underline(hovering, color: primary)
                }
            }

            HomeBriefingLink(action: { open(.codex) }) { hovering in
                HStack(spacing: 5) {
                    HomeOpenAIBlossom(isHovering: hovering)

                    Text("\(liveCount) Codex \(liveCount == 1 ? "task" : "tasks") live,")
                        .foregroundStyle(primary)
                        .underline(hovering, color: primary)
                }
            }

            Text("and")
                .foregroundStyle(muted)

            HomeBriefingLink(action: { open(.todos) }) { hovering in
                HStack(spacing: 5) {
                    HomeTodoCheckbox(isHovering: hovering)

                    Text("\(todoCount) \(todoCount == 1 ? "todo" : "todos").")
                        .foregroundStyle(primary)
                        .underline(hovering, color: primary)
                }
            }

            ForEach(Array(scheduleWords.enumerated()), id: \.offset) { _, word in
                Text(String(word))
                    .foregroundStyle(muted)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func open(_ section: HomeSection) {
        controller.selectedHomeSection = section
        controller.openHomeSection(section)
    }

    private func scheduleOutlook(at date: Date) -> String {
        if let current = calendarService.events.first(where: { $0.isHappening(at: date) }) {
            return "You're in \(current.title) until \(current.endDate.formatted(date: .omitted, time: .shortened))."
        }
        if let next = calendarService.events.first(where: { $0.isAllDay || $0.startDate > date }) {
            return "Next is \(next.title) at \(next.timeText())."
        }
        return "Your calendar is clear for the rest of today."
    }
}

private struct HomeBriefingLink<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label(hovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct HomeOpenAIBlossom: View {
    let isHovering: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationDegrees: Double = 0

    var body: some View {
        OpenAIBlossomIcon(
            size: 15,
            color: .white.opacity(0.93),
            rotation: .degrees(reduceMotion ? 0 : rotationDegrees)
        )
        .onChange(of: isHovering) { _, hovering in
            guard hovering, !reduceMotion else { return }
            withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 1)) {
                rotationDegrees += 360
            }
        }
    }
}

private struct InlineFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    private struct Placement {
        var origin: CGPoint
        let size: CGSize
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        measure(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let result = measure(maxWidth: bounds.width, subviews: subviews)
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                proposal: ProposedViewSize(
                    width: placement.size.width,
                    height: placement.size.height
                )
            )
        }
    }

    private func measure(
        maxWidth: CGFloat,
        subviews: Subviews
    ) -> (size: CGSize, placements: [Placement]) {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var lineStart = 0
        var measuredWidth: CGFloat = 0

        func centerCurrentLine() {
            guard lineStart < placements.count else { return }
            for index in lineStart ..< placements.count {
                placements[index].origin.y += (lineHeight - placements[index].size.height) / 2
            }
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedX = x == 0 ? 0 : x + horizontalSpacing
            if proposedX > 0, proposedX + size.width > maxWidth {
                centerCurrentLine()
                measuredWidth = max(measuredWidth, x)
                y += lineHeight + verticalSpacing
                x = 0
                lineHeight = 0
                lineStart = placements.count
            }

            let itemX = x == 0 ? 0 : x + horizontalSpacing
            placements.append(Placement(origin: CGPoint(x: itemX, y: y), size: size))
            x = itemX + size.width
            lineHeight = max(lineHeight, size.height)
        }

        centerCurrentLine()
        measuredWidth = max(measuredWidth, x)
        return (
            CGSize(width: measuredWidth, height: y + lineHeight),
            placements
        )
    }
}

private struct CalendarDayFlowIcon: View {
    let day: Int
    let color: Color
    let isHovering: Bool

    private let iconSize: CGFloat = 18
    private let digitHeight: CGFloat = 6.5
    @State private var replayID = 0

    var body: some View {
        ZStack {
            calendarOutline

            HStack(spacing: 0.75) {
                if normalizedDay >= 10 {
                    CalendarDigitTrack(
                        targetDigit: normalizedDay / 10,
                        replayID: replayID,
                        delayMilliseconds: 0,
                        color: color
                    )
                }

                CalendarDigitTrack(
                    targetDigit: normalizedDay % 10,
                    replayID: replayID,
                    delayMilliseconds: normalizedDay >= 10 ? 35 : 0,
                    color: color
                )
            }
            .frame(height: digitHeight)
            .offset(y: 2.2)
        }
        .frame(width: 20, height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calendar day \(day)")
        .onChange(of: isHovering) { _, hovering in
            guard hovering else { return }
            replayID &+= 1
        }
    }

    private var normalizedDay: Int {
        min(31, max(1, day))
    }

    @ViewBuilder
    private var calendarOutline: some View {
        if let image = HomeAssets.calendarOutline {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(color)
                .frame(width: iconSize, height: iconSize)
        } else {
            Image(systemName: "calendar")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
        }
    }

}

private struct CalendarDigitTrack: View {
    let targetDigit: Int
    let replayID: Int
    let delayMilliseconds: Int
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedDigit: Int

    init(
        targetDigit: Int,
        replayID: Int,
        delayMilliseconds: Int,
        color: Color
    ) {
        self.targetDigit = targetDigit
        self.replayID = replayID
        self.delayMilliseconds = delayMilliseconds
        self.color = color
        _displayedDigit = State(initialValue: targetDigit)
    }

    var body: some View {
        ZStack {
            digitImage(displayedDigit)
                .id(displayedDigit)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
        }
        .frame(width: 4, height: 6.5)
        .clipped()
        .task(id: replayID) {
            guard replayID > 0 else { return }
            await replay()
        }
    }

    @ViewBuilder
    private func digitImage(_ value: Int) -> some View {
        if let image = HomeAssets.calendarDigits[value] {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(color)
                .frame(width: 4, height: 6.5)
        } else {
            Text("\(value)")
                .font(.system(size: 5, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 4, height: 6.5)
        }
    }

    @MainActor
    private func replay() async {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            displayedDigit = targetDigit
        }

        guard !reduceMotion else { return }
        if delayMilliseconds > 0 {
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
        }

        let offsets = [3, 7, 5]
        let seed = replayID * 2
        let sequence = offsets.map { (targetDigit + $0 + seed) % 10 } + [targetDigit]

        for digit in sequence {
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.21)) {
                displayedDigit = digit
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
        }
    }
}

private struct HomeTodoCheckbox: View {
    let isHovering: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var replayID = 0
    @State private var pinchProgress: CGFloat = 0
    @State private var pressScale: CGFloat = 1
    @State private var checkProgress: CGFloat = 1

    var body: some View {
        ReferenceTodoCheckbox(
            fillProgress: 1,
            pinchProgress: pinchProgress,
            rightPullProgress: 0,
            pressScale: pressScale,
            checkProgress: checkProgress
        )
        .frame(width: 20, height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open todos")
        .onChange(of: isHovering) { _, hovering in
            guard hovering else { return }
            replayID &+= 1
        }
        .task(id: replayID) {
            guard replayID > 0 else { return }
            await replay()
        }
    }

    @MainActor
    private func replay() async {
        guard !reduceMotion else { return }

        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            pinchProgress = 0
            pressScale = 1
            checkProgress = 1
        }

        withAnimation(.linear(duration: 0.22)) {
            pinchProgress = 1
            pressScale = 0.948
            checkProgress = 0.18
        }
        guard await sleep(milliseconds: 220) else { return }

        withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.34)) {
            pinchProgress = 0.18
            pressScale = 0.985
            checkProgress = 1
        }
        guard await sleep(milliseconds: 340) else { return }

        withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.44)) {
            pinchProgress = 0
            pressScale = 1
        }
    }

    private func sleep(milliseconds: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}

struct CalendarDayView: View {
    @ObservedObject private var controller: PanelController
    @ObservedObject private var calendarService: CalendarEventService

    init(controller: PanelController) {
        _controller = ObservedObject(wrappedValue: controller)
        _calendarService = ObservedObject(wrappedValue: controller.calendarService)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.agentBlue)

                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))

                Spacer()

                NumberFlowText(
                    "\(calendarService.events.count)",
                    fontSize: 10,
                    weight: .semibold,
                    color: .white.opacity(0.46),
                    reservedWidth: 18
                )
                Text(calendarService.events.count == 1 ? "event" : "events")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))

                Button {
                    calendarService.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(EditorIconButtonStyle())
                .help("Refresh Calendar")
            }
            .padding(.horizontal, 20)
            .frame(height: 38)

            calendarContent
        }
    }

    @ViewBuilder
    private var calendarContent: some View {
        switch calendarService.accessState {
        case .granted:
            if calendarService.events.isEmpty {
                CalendarAccessStateView(
                    symbol: "calendar.badge.checkmark",
                    title: "No events today",
                    detail: "Your calendar is clear."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(calendarService.events) { event in
                            CalendarEventRow(
                                event: event,
                                referenceNow: calendarService.referenceNow,
                                action: calendarService.openCalendar,
                                startRecording: {
                                    controller.startMeetingCaptureFromCalendar(event)
                                }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        case .idle, .requesting:
            CalendarAccessStateView(
                symbol: "calendar.badge.clock",
                title: "Connecting Calendar",
                detail: "Waiting for macOS calendar access."
            )
        case .denied, .restricted:
            CalendarAccessStateView(
                symbol: "calendar.badge.exclamationmark",
                title: "Calendar access is off",
                detail: "Allow iAgent in Privacy & Security to see today’s events.",
                actionTitle: "Open Settings",
                action: calendarService.openCalendarPrivacySettings
            )
        case let .failed(message):
            CalendarAccessStateView(
                symbol: "exclamationmark.triangle",
                title: "Calendar unavailable",
                detail: message,
                actionTitle: "Try again",
                action: calendarService.requestAccess
            )
        }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEventItem
    let referenceNow: Date
    let action: () -> Void
    let startRecording: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(event.tint.color.opacity(event.hasEnded(at: referenceNow) ? 0.34 : 0.9))
                        .frame(width: 6, height: 6)

                    Text(event.timeText())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(event.hasEnded(at: referenceNow) ? 0.3 : 0.54))
                        .frame(width: 68, alignment: .leading)

                    Text(event.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(event.hasEnded(at: referenceNow) ? 0.36 : 0.82))
                        .lineLimit(1)

                    if isCurrent {
                        Text("Now")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(event.tint.color)
                    }

                    Spacer(minLength: 12)

                    Text(event.calendarTitle)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.32))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 96, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Calendar")

            if isCurrent {
                Button(action: startRecording) {
                    Circle()
                        .fill(Color.agentCoral)
                        .frame(width: 8, height: 8)
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.28), lineWidth: 0.5)
                        }
                        .frame(width: 24, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Start recording \(event.title)")
                .accessibilityLabel("Start recording \(event.title)")
            } else {
                Color.clear
                    .frame(width: 24, height: 40)
                    .allowsHitTesting(false)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 40)
        .background(.white.opacity(hovering ? 0.035 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var isCurrent: Bool {
        event.isHappening(at: referenceNow)
    }
}

private struct CalendarAccessStateView: View {
    let symbol: String
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))

            Text(detail)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.agentBlue)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

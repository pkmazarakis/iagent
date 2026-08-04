import AppKit
import Carbon
import Combine
import QuartzCore
import SwiftUI
import iAgentCore

private enum PanelMetrics {
    static let notchSize = NSSize(width: 210, height: 38)
    static let expandedWidth: CGFloat = 760
    static let compactSize = NSSize(width: 656, height: 34)
    static let maximumExpandedHeight: CGFloat = 348
    static let minimumExpandedHeight: CGFloat = 128
    static let homeExpandedHeight: CGFloat = 128
    static let headerHeight: CGFloat = 36
    static let expandedRampWidth: CGFloat = 16
    static let expandedRampDepth: CGFloat = 20
    static let topMaskOverscan: CGFloat = 1
    static let transitionDuration: TimeInterval = 0.3
}

private enum PanelPresentation: Equatable {
    case notch
    case compact
    case expanded
}

enum AgentState: String, Sendable {
    case running
    case waitingForInput
    case needsApproval
    case completed
    case failed

    var label: String {
        switch self {
        case .running: "Running"
        case .waitingForInput: "Waiting"
        case .needsApproval: "Approval"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    var color: Color {
        switch self {
        case .running: .agentGreen
        case .waitingForInput: .agentBlue
        case .needsApproval: .agentAmber
        case .completed: Color.white.opacity(0.5)
        case .failed: .agentCoral
        }
    }

    var isActive: Bool {
        switch self {
        case .running, .waitingForInput, .needsApproval: true
        case .completed, .failed: false
        }
    }
}

enum ThreadMode: String, Identifiable, Sendable {
    case plan = "Plan"
    case goal = "Goal"
    case voice = "Voice"

    var id: String { rawValue }
}

struct AgentThread: Identifiable, Sendable, Equatable {
    let id: String
    let projectName: String?
    let workspacePath: String?
    let title: String
    let activity: String
    let state: AgentState
    let modes: [ThreadMode]
    let elapsed: String
    let createdAt: Date
    let updatedAt: Date
}

enum PanelContentMode: Hashable, Sendable {
    case home
    case threads
    case calendar
    case create
    case note
    case newThread
    case focus
    case todo
}

enum NoteSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)
}

enum CreationOption: Int, CaseIterable, Identifiable, Sendable {
    case note
    case codexThread
    case focusSession
    case meetingRecorder
    case todo

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .note: "New note"
        case .codexThread: "New codex thread"
        case .focusSession: "New focus session"
        case .meetingRecorder: "Meeting recorder"
        case .todo: "New todo"
        }
    }

    var symbol: String {
        switch self {
        case .note: "square.and.pencil"
        case .codexThread: "chevron.left.forwardslash.chevron.right"
        case .focusSession: "timer"
        case .meetingRecorder: "record.circle"
        case .todo: "checklist"
        }
    }

    var shortcutLabel: String {
        switch self {
        case .note: "⌘N"
        case .codexThread: "⌘C"
        case .focusSession: "⌘F"
        case .meetingRecorder: "⌘R"
        case .todo: "⌘T"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .note: 45
        case .codexThread: 8
        case .focusSession: 3
        case .meetingRecorder: 15
        case .todo: 17
        }
    }
}

enum FocusPreset: Int, CaseIterable, Identifiable, Sendable {
    case pomodoro = 25
    case extended = 50
    case long = 90

    var id: Int { rawValue }
    var focusMinutes: Int { rawValue }

    var breakMinutes: Int {
        switch self {
        case .pomodoro: 5
        case .extended: 10
        case .long: 20
        }
    }
}

final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class PanelHostingView: NSView {
    private let hostedView: NSHostingView<AnyView>
    private let contourMask = CAShapeLayer()

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(rootView: AnyView) {
        hostedView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = false
        hostedView.sizingOptions = []
        hostedView.frame = bounds
        hostedView.autoresizingMask = [.width, .height]
        addSubview(hostedView)
        contourMask.fillColor = NSColor.black.cgColor
        contourMask.anchorPoint = .zero
        contourMask.position = .zero
        contourMask.actions = [
            "bounds": NSNull(),
            "path": NSNull(),
            "position": NSNull(),
        ]
        layer?.mask = contourMask
        updateContourMask(for: bounds.size)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        hostedView.frame = bounds
        updateContourMask(for: newSize)
    }

    override func layout() {
        super.layout()
        hostedView.frame = bounds
        updateContourMask(for: bounds.size)
    }

    override func updateLayer() {
        updateContourMask(for: bounds.size)
    }

    func syncContourMask(for size: NSSize) {
        if abs(frame.width - size.width) > 0.25 || abs(frame.height - size.height) > 0.25 {
            setFrameSize(size)
        }
        hostedView.frame = CGRect(origin: .zero, size: size)
        updateContourMask(for: size)
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }

    func renderedContourHasTopRamps() -> Bool {
        layoutSubtreeIfNeeded()
        displayIfNeeded()
        guard bounds.width >= 64,
              bounds.height >= 24,
              let bitmap = bitmapImageRepForCachingDisplay(in: bounds)
        else {
            return false
        }
        cacheDisplay(in: bounds, to: bitmap)

        let scaleX = CGFloat(bitmap.pixelsWide) / bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / bounds.height
        let y = min(bitmap.pixelsHigh - 1, max(0, Int(10 * scaleY)))
        let outerX = min(bitmap.pixelsWide - 1, max(0, Int(2 * scaleX)))
        let innerX = min(bitmap.pixelsWide - 1, max(0, Int(18 * scaleX)))
        let rightOuterX = max(0, bitmap.pixelsWide - 1 - outerX)
        let rightInnerX = max(0, bitmap.pixelsWide - 1 - innerX)

        func alpha(at x: Int, y sampleY: Int) -> CGFloat {
            bitmap.colorAt(x: x, y: sampleY)?.alphaComponent ?? 0
        }

        let samples = (
            leftOuter: alpha(at: outerX, y: y),
            leftInner: alpha(at: innerX, y: y),
            rightOuter: alpha(at: rightOuterX, y: y),
            rightInner: alpha(at: rightInnerX, y: y),
            centerTop: alpha(at: bitmap.pixelsWide / 2, y: 0)
        )
        let hasRamps = samples.leftOuter < 0.2
            && samples.leftInner > 0.8
            && samples.rightOuter < 0.2
            && samples.rightInner > 0.8
            && samples.centerTop > 0.98
        if !hasRamps {
            let maskBounds = contourMask.bounds
            let pathBounds = contourMask.path?.boundingBoxOfPath ?? .zero
            print(
                "[ramp] size=\(Int(bounds.width))x\(Int(bounds.height)) "
                    + "alpha=\(samples.leftOuter),\(samples.leftInner),"
                    + "\(samples.rightOuter),\(samples.rightInner),\(samples.centerTop) "
                    + "layer=\(Int(layer?.bounds.width ?? 0))x\(Int(layer?.bounds.height ?? 0)) "
                    + "host=\(Int(hostedView.frame.width))x\(Int(hostedView.frame.height)) "
                    + "mask=\(Int(maskBounds.width))x\(Int(maskBounds.height)) "
                    + "path=\(Int(pathBounds.width))x\(Int(pathBounds.height))"
            )
        }
        return hasRamps
    }

    private func updateContourMask(for size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        let path = PanelContourShape().path(in: bounds).cgPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contourMask.anchorPoint = .zero
        contourMask.position = .zero
        contourMask.bounds = CGRect(origin: .zero, size: size)
        contourMask.path = path
        layer?.mask = contourMask
        CATransaction.commit()
        CATransaction.flush()
    }
}

@MainActor
final class PanelController: ObservableObject {
    @Published var expanded = false
    @Published var compactVisible = true
    @Published var contentVisible = false
    @Published private(set) var isPanelHidden = false
    @Published var lastOpenSource = "initial"
    @Published var threads: [AgentThread] = []
    @Published var databasePath = ""
    @Published var loadError: String?
    @Published private(set) var referenceNow = Date()
    @Published var selectedThreadID: String?
    @Published var hoveredThreadID: String?
    @Published private(set) var keyboardSelectionRevision = 0
    @Published private(set) var keyboardSelectionDirection = 1
    private(set) var focusRestorationCount = 0
    @Published var dictationTargetThreadID: String?
    @Published var contentMode: PanelContentMode = .home {
        didSet {
            guard oldValue != contentMode else { return }
            resizeExpandedPanel()
        }
    }

    @Published private(set) var projectOrder: [String] = []
    @Published private(set) var collapsedProjectIDs: Set<String> = []
    @Published var selectedHomeSection: HomeSection = .calendar
    @Published var selectedCreationOption: CreationOption = .note
    @Published var editorTitle = ""
    @Published var editorBody = ""
    @Published private(set) var noteEditorDocumentID = "draft-\(UUID().uuidString)"
    @Published private(set) var noteEditorFocusRequest = 0
    @Published var noteShowsRawMarkdown = false
    @Published var noteFindVisible = false
    @Published private(set) var noteSaveState: NoteSaveState = .idle
    @Published var statusMessage: String?
    @Published var isSubmitting = false
    @Published var isStartingDictation = false
    @Published var lastSavedDocument: LocalDocument?
    @Published var focusTask = ""
    @Published private(set) var focusPreset: FocusPreset = .pomodoro
    @Published private(set) var focusRemaining: TimeInterval = 25 * 60
    @Published private(set) var focusIsRunning = false
    @Published var todoDraft = ""
    @Published private(set) var todoComposerFocusRequest = 0
    @Published private(set) var todoComposerIsFocused = false
    @Published private(set) var todos: [LocalTodo] = []
    @Published private(set) var savedTodoListNames: [String] = []
    @Published private(set) var completingTodoIDs: Set<UUID> = []
    @Published private(set) var fadingTodoIDs: Set<UUID> = []
    @Published private(set) var showingPastTodos = false
    @Published private(set) var cloudSyncStatus = IAgentCloudSyncStatus()
    private(set) var lastOpenedThreadID: String?

    let dictation = SpeechDictationService()
    let meetingCapture: MeetingCaptureService
    let calendarService: CalendarEventService
    let localFirstName: String?

    weak var window: PanelWindow?
    private var transitionID = 0
    private var targetPresentation: PanelPresentation = .compact
    private var frameAnimationTimer: Timer?
    private var frameAnimationStartFrame = NSRect.zero
    private var frameAnimationTargetFrame = NSRect.zero
    private var frameAnimationStartedAt: TimeInterval = 0
    private var frameAnimationDuration: TimeInterval = 0
    private var frameAnimationCompletion: (@MainActor @Sendable () -> Void)?
    private var frameAnimationGeneration = 0
    private var refreshTimer: Timer?
    private var refreshInFlight = false
    private var refreshPending = false
    private var refreshDebounceTask: Task<Void, Never>?
    private var focusTimer: Timer?
    private var focusEndsAt: Date?
    private var noteAutosaveTask: Task<Void, Never>?
    private var todoCompletionTasks: [UUID: Task<Void, Never>] = [:]
    private var desktopSyncTimer: Timer?
    private var desktopSyncDebounceTask: Task<Void, Never>?
    private var desktopSyncInFlight = false
    private var desktopSyncFetchPending = false
    private var hasLoadedThreads = false
    private var loadedThreadLimit = 200
    private let fileMonitor = CodexFileMonitor()
    private let documentStore: LocalDocumentStore
    private let todoStore: LocalTodoStore
    private let desktopSync: DesktopSyncCoordinator
    private let projectPreferences: ProjectSectionPreferenceStore
    private let codexClient = CodexAppServerClient()
    private let codexDesktopSender = CodexDesktopPromptSender()
    private let isSmokeTest: Bool

    var activeCount: Int {
        threads.filter(\.state.isActive).count
    }

    var liveThreads: [AgentThread] {
        threads.filter(\.state.isActive).sorted { $0.updatedAt > $1.updatedAt }
    }

    var compactCalendarEvent: CalendarEventItem? {
        let now = max(referenceNow, calendarService.referenceNow)
        return calendarService.events.first(where: { $0.isHappening(at: now) })
            ?? calendarService.events.first(where: { !$0.isAllDay && $0.startDate > now })
            ?? calendarService.events.first(where: \.isAllDay)
    }

    var recordableMeetingEvent: CalendarEventItem? {
        let now = max(referenceNow, calendarService.referenceNow)
        let armingWindow = now.addingTimeInterval(10 * 60)
        return calendarService.events.first {
            !$0.isAllDay
                && $0.startDate <= armingWindow
                && $0.endDate > now
        }
    }

    var openTodoCount: Int {
        todos.filter { !$0.isCompleted }.count
    }

    var editorWordCount: Int {
        editorBody.split(whereSeparator: { $0.isWhitespace }).count
    }

    var visibleTodos: [LocalTodo] {
        todos.filter { !$0.isCompleted || completingTodoIDs.contains($0.id) }
    }

    var pastTodos: [LocalTodo] {
        todos
            .filter { $0.isCompleted && !completingTodoIDs.contains($0.id) }
            .sorted {
                ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt)
            }
    }

    var todoListNames: [String] {
        var seen: Set<String> = []
        return (savedTodoListNames + todos.compactMap(\.listName))
            .compactMap { rawName in
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let key = name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                guard seen.insert(key).inserted else { return nil }
                return name
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var priorityTodos: [LocalTodo] {
        let endOfToday = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: 1,
            to: Calendar.autoupdatingCurrent.startOfDay(for: Date())
        ) ?? Date.distantFuture

        return todos
            .filter { todo in
                !todo.isCompleted
                    && (todo.isStarred || todo.dueDate.map { $0 < endOfToday } == true)
            }
            .sorted { lhs, rhs in
                if lhs.isStarred != rhs.isStarred { return lhs.isStarred }
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.createdAt > rhs.createdAt
                }
            }
    }

    var activityThreads: [AgentThread] {
        AgentThread.activityFeed(from: threads, now: referenceNow)
    }

    var projectSections: [ThreadProjectSection] {
        let sections = ThreadProjectSection.build(from: threads, excluding: [])
        let byID = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        let knownIDs = Set(projectOrder)
        return projectOrder.compactMap { byID[$0] }
            + sections.filter { !knownIDs.contains($0.id) }
    }

    var orderedThreads: [AgentThread] {
        let activityIDs = Set(activityThreads.map(\.id))
        return activityThreads + projectSections.flatMap { section in
            collapsedProjectIDs.contains(section.id)
                ? []
                : section.threads.filter { !activityIDs.contains($0.id) }
        }
    }

    var panelTitle: String {
        switch contentMode {
        case .home: homeTitle
        case .threads: "Codex"
        case .calendar: "Calendar"
        case .create: "Create"
        case .note: lastSavedDocument == nil ? "New note" : "Note"
        case .newThread: "New codex thread"
        case .focus: "New focus session"
        case .todo: showingPastTodos ? "Past todos" : "Todo"
        }
    }

    var homeTitle: String {
        localFirstName.map { "Hello \($0)" } ?? "Home"
    }

    var expandedSize: NSSize {
        NSSize(width: PanelMetrics.expandedWidth, height: preferredExpandedHeight)
    }

    private var preferredExpandedHeight: CGFloat {
        let height: CGFloat
        switch contentMode {
        case .home:
            height = PanelMetrics.homeExpandedHeight
        case .threads:
            var contentHeight: CGFloat = activityThreads.isEmpty ? 0 : 30 + CGFloat(activityThreads.count) * 36
            for section in projectSections {
                contentHeight += 40
                if !collapsedProjectIDs.contains(section.id) {
                    contentHeight += CGFloat(section.threads.count) * 36
                }
            }
            if contentHeight == 0 {
                contentHeight = 102
            }
            height = PanelMetrics.headerHeight + contentHeight
        case .create:
            height = PanelMetrics.headerHeight + CGFloat(CreationOption.allCases.count) * 44 + 12
        case .note:
            height = 310
        case .newThread:
            height = 260
        case .focus:
            height = 190
        case .todo:
            let todoCount = showingPastTodos ? pastTodos.count : visibleTodos.count
            let visibleRows = min(6, max(2, todoCount))
            let composerHeight: CGFloat = showingPastTodos ? 0 : TodoLayoutMetrics.composerHeight
            height = PanelMetrics.headerHeight
                + composerHeight
                + CGFloat(visibleRows) * TodoLayoutMetrics.rowHeight
                + TodoLayoutMetrics.bottomPadding
        case .calendar:
            let visibleRows = min(6, max(2, calendarService.events.count))
            height = PanelMetrics.headerHeight + 38 + CGFloat(visibleRows) * 40 + 8
        }

        return min(
            PanelMetrics.maximumExpandedHeight,
            max(PanelMetrics.minimumExpandedHeight, height)
        )
    }

    init(
        smokeTest: Bool = CommandLine.arguments.contains("--smoke-test"),
        preferences: UserDefaults = .standard
    ) {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        localFirstName = fullName.split(whereSeparator: \.isWhitespace).first.map(String.init)
        isSmokeTest = smokeTest
        calendarService = CalendarEventService(smokeTest: smokeTest)
        projectPreferences = ProjectSectionPreferenceStore(defaults: preferences)
        let localDocumentStore = smokeTest
            ? LocalDocumentStore(
                rootURL: URL(fileURLWithPath: "/private/tmp/iagent-smoke-library", isDirectory: true)
            )
            : LocalDocumentStore()
        documentStore = localDocumentStore
        meetingCapture = MeetingCaptureService(documentStore: localDocumentStore)
        todoStore = LocalTodoStore(rootURL: localDocumentStore.rootURL)
        desktopSync = DesktopSyncCoordinator(
            documentStore: localDocumentStore,
            smokeTest: smokeTest
        )
        if smokeTest {
            try? FileManager.default.removeItem(at: todoStore.fileURL)
            try? FileManager.default.removeItem(at: todoStore.listFileURL)
        }
        todos = (try? todoStore.load()) ?? []
        savedTodoListNames = (try? todoStore.loadListNames()) ?? []
        projectOrder = projectPreferences.loadOrder()
        collapsedProjectIDs = projectPreferences.loadCollapsedIDs()
        codexClient.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .turnCompleted(threadID, status):
                if threadID == self.dictationTargetThreadID {
                    self.statusMessage = status == "completed" ? "Codex finished" : "Codex \(status)"
                }
                self.scheduleThreadRefresh()
            case let .attentionRequired(_, message), let .processStopped(message):
                self.statusMessage = message
            }
        }
        calendarService.onChange = { [weak self] in
            self?.resizeExpandedPanel()
            self?.scheduleDesktopSync(fetchRemote: false)
        }
    }

    func attach(window: PanelWindow) {
        self.window = window
        applyPinnedWindowFrame(targetFrame(expanded: false), display: true)
    }

    func startThreadUpdates() {
        calendarService.start()
        refreshThreads()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshThreads()
            }
        }
        refreshTimer?.tolerance = 0.1

        desktopSyncTimer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleDesktopSync(fetchRemote: true, delay: .zero)
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        desktopSyncTimer = timer
        scheduleDesktopSync(fetchRemote: true, delay: .milliseconds(350))
    }

    func stopThreadUpdates() {
        cancelFrameAnimation()
        noteAutosaveTask?.cancel()
        noteAutosaveTask = nil
        desktopSyncDebounceTask?.cancel()
        desktopSyncDebounceTask = nil
        desktopSyncTimer?.invalidate()
        desktopSyncTimer = nil
        if contentMode == .note {
            saveLocalDocument(kind: .note, announce: false)
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        fileMonitor.stop()
        dictation.cancel()
        meetingCapture.shutdown()
        codexClient.stop()
        calendarService.stop()
        Task { await desktopSync.stop() }
        focusTimer?.invalidate()
        focusTimer = nil
    }

    private func refreshThreads() {
        guard !refreshInFlight else {
            refreshPending = true
            return
        }
        refreshInFlight = true
        let limit = loadedThreadLimit

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return try Result<CodexThreadLoadResult, CodexThreadLoaderError>.success(
                        CodexThreadLoader.loadRecent(limit: limit)
                    )
                } catch {
                    return Result<CodexThreadLoadResult, CodexThreadLoaderError>.failure(
                        CodexThreadLoaderError(message: error.localizedDescription)
                    )
                }
            }.value

            guard let self else { return }
            self.refreshInFlight = false
            switch result {
            case let .success(loaded):
                self.hasLoadedThreads = true
                self.referenceNow = Date()
                self.resizeExpandedPanel()
                if self.threads != loaded.threads {
                    self.threads = loaded.threads
                    self.reconcileProjectOrder()
                    self.resizeExpandedPanel()
                }
                if self.databasePath != loaded.databasePath {
                    self.databasePath = loaded.databasePath
                }
                if self.loadError != nil {
                    self.loadError = nil
                }
                self.fileMonitor.update(paths: loaded.watchPaths) { [weak self] in
                    Task { @MainActor in
                        self?.scheduleThreadRefresh()
                    }
                }
                if loaded.hasMore, self.loadedThreadLimit < 200 {
                    self.loadedThreadLimit = 200
                    self.refreshPending = true
                }
                if let selectedThreadID = self.selectedThreadID,
                   !loaded.threads.contains(where: { $0.id == selectedThreadID })
                {
                    self.selectedThreadID = nil
                }
                self.scheduleDesktopSync(fetchRemote: false)
            case let .failure(error):
                if self.loadError != error.localizedDescription {
                    self.loadError = error.localizedDescription
                }
            }

            if self.refreshPending {
                self.refreshPending = false
                self.refreshThreads()
            }
        }
    }

    private func scheduleThreadRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refreshThreads()
        }
    }

    private func scheduleDesktopSync(
        fetchRemote: Bool,
        delay: Duration = .milliseconds(650)
    ) {
        desktopSyncFetchPending = desktopSyncFetchPending || fetchRemote
        desktopSyncDebounceTask?.cancel()
        desktopSyncDebounceTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            self.performDesktopSync()
        }
    }

    private func performDesktopSync() {
        guard !desktopSyncInFlight else {
            desktopSyncFetchPending = true
            return
        }

        let fetchRemote = desktopSyncFetchPending
        desktopSyncFetchPending = false
        desktopSyncInFlight = true
        let input = DesktopSyncInput(
            threads: hasLoadedThreads ? threads : nil,
            calendarEvents: calendarService.accessState.canReadEvents
                ? calendarService.events
                : nil,
            todos: todos,
            todoListNames: todoListNames,
            projectOrder: projectOrder
        )

        Task { [weak self] in
            guard let self else { return }
            let state = await self.desktopSync.synchronize(
                input: input,
                fetchRemote: fetchRemote
            )
            self.applyDesktopSyncState(state, basedOn: input)
            self.desktopSyncInFlight = false
            if self.desktopSyncFetchPending {
                self.scheduleDesktopSync(fetchRemote: true, delay: .milliseconds(200))
            }
        }
    }

    private func applyDesktopSyncState(
        _ state: DesktopWritableSyncState,
        basedOn input: DesktopSyncInput
    ) {
        let inputTodos = Dictionary(uniqueKeysWithValues: input.todos.map { ($0.id, $0) })
        let currentTodos = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let locallyDeletedIDs = Set(inputTodos.keys).subtracting(currentTodos.keys)
        var mergedTodos = Dictionary(uniqueKeysWithValues: state.todos.map { ($0.id, $0) })

        for id in locallyDeletedIDs {
            mergedTodos.removeValue(forKey: id)
        }
        for current in todos {
            if let remote = mergedTodos[current.id] {
                if current.updatedAt > remote.updatedAt {
                    mergedTodos[current.id] = current
                }
            } else if let captured = inputTodos[current.id] {
                if current.updatedAt > captured.updatedAt {
                    mergedTodos[current.id] = current
                }
            } else {
                mergedTodos[current.id] = current
            }
        }

        let nextTodos = mergedTodos.values.sorted { $0.createdAt > $1.createdAt }
        if nextTodos != todos {
            todos = nextTodos
            try? todoStore.save(nextTodos)
            resizeExpandedPanel()
        }

        let nextListNames = Self.mergedTodoListNames(
            local: savedTodoListNames,
            remote: state.todoListNames
        )
        if nextListNames != savedTodoListNames {
            savedTodoListNames = nextListNames
            try? todoStore.saveListNames(nextListNames)
        }
        cloudSyncStatus = state.status
    }

    private static func mergedTodoListNames(
        local: [String],
        remote: [String]
    ) -> [String] {
        var seen: Set<String> = []
        return (remote + local).filter { name in
            let key = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return seen.insert(key).inserted
        }
    }

    private func reconcileProjectOrder() {
        let sectionIDs = ThreadProjectSection.build(from: threads, excluding: []).map(\.id)
        let nextOrder = ProjectSectionPreferenceStore.appendingNewIDs(sectionIDs, to: projectOrder)
        guard nextOrder != projectOrder else { return }
        projectOrder = nextOrder
        projectPreferences.saveOrder(nextOrder)
        scheduleDesktopSync(fetchRemote: false)
    }

    func toggleProjectSection(_ sectionID: String) {
        if collapsedProjectIDs.contains(sectionID) {
            collapsedProjectIDs.remove(sectionID)
        } else {
            collapsedProjectIDs.insert(sectionID)
            if let selectedThreadID,
               projectSections.first(where: { $0.id == sectionID })?.threads.contains(where: { $0.id == selectedThreadID }) == true
            {
                self.selectedThreadID = nil
            }
        }
        projectPreferences.saveCollapsedIDs(collapsedProjectIDs)
        resizeExpandedPanel()
    }

    @discardableResult
    func collapseProjectSectionForDrag(_ sectionID: String) -> Bool {
        guard !collapsedProjectIDs.contains(sectionID) else { return false }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            collapsedProjectIDs.insert(sectionID)
            if let selectedThreadID,
               projectSections.first(where: { $0.id == sectionID })?.threads.contains(where: { $0.id == selectedThreadID }) == true
            {
                self.selectedThreadID = nil
            }
        }
        projectPreferences.saveCollapsedIDs(collapsedProjectIDs)
        resizeExpandedPanel(animated: false)
        return true
    }

    func moveProject(_ draggedProjectID: String, toVisibleIndex insertionIndex: Int) -> Bool {
        let visibleOrder = projectSections.map(\.id)
        let reordered = ProjectSectionPreferenceStore.moving(
            draggedProjectID,
            to: insertionIndex,
            in: visibleOrder
        )
        guard reordered != visibleOrder else { return false }

        let visibleIDs = Set(visibleOrder)
        let hiddenIDs = projectOrder.filter { !visibleIDs.contains($0) }
        projectOrder = reordered + hiddenIDs
        projectPreferences.saveOrder(projectOrder)
        scheduleDesktopSync(fetchRemote: false)
        return true
    }

    func threadURL(for thread: AgentThread) -> URL? {
        URL(string: "codex://threads/\(thread.id)")
    }

    func openThread(_ thread: AgentThread) {
        if let dictationTargetThreadID, dictationTargetThreadID != thread.id {
            cancelDictation()
        }
        selectedThreadID = thread.id
        lastOpenedThreadID = thread.id
        if isSmokeTest {
            restorePanelFocus()
            return
        }
        guard let url = threadURL(for: thread) else { return }

        guard let codexApplicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            _ = NSWorkspace.shared.open(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.restorePanelFocus()
            }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: codexApplicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.statusMessage = "Could not open Codex: \(error.localizedDescription)"
                }
                self?.restorePanelFocus()
            }
        }
    }

    private func restorePanelFocus() {
        focusPanelForKeyboardNavigation()
    }

    private func focusPanelForKeyboardNavigation() {
        guard targetPresentation == .expanded, let window else { return }
        focusRestorationCount += 1
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        if let contentView = window.contentView {
            if contentMode == .note,
               !noteFindVisible,
               let noteEditor = markdownEditorTextView(in: contentView)
            {
                window.makeFirstResponder(noteEditor)
            } else {
                window.makeFirstResponder(contentView)
            }
        }
    }

    private func markdownEditorTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            let typeName = String(reflecting: type(of: textView))
            if typeName.contains("MarkdownEngine.NativeTextView") {
                return textView
            }
        }

        for subview in view.subviews {
            if let match = markdownEditorTextView(in: subview) {
                return match
            }
        }
        return nil
    }

    private func noteMarkerIsHidden(at location: Int, in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage,
              location >= 0,
              location < storage.length,
              let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        else {
            return false
        }
        return font.pointSize <= 0.2
    }

    private var noteEditorHasKeyboardFocus: Bool {
        guard let window,
              let contentView = window.contentView,
              let editor = markdownEditorTextView(in: contentView)
        else {
            return false
        }
        return window.firstResponder === editor
    }

    func setHoveredThread(_ threadID: String, hovering: Bool) {
        guard contentMode == .threads, dictationTargetThreadID == nil else { return }
        if hovering {
            hoveredThreadID = threadID
        } else if hoveredThreadID == threadID {
            hoveredThreadID = nil
        }
    }

    func showCreationMenu() {
        if dictation.isRecording || dictationTargetThreadID != nil {
            cancelDictation()
        }
        isStartingDictation = false
        contentMode = .create
        selectedCreationOption = .note
        hoveredThreadID = nil
        statusMessage = nil
    }

    func showHome() {
        dictation.cancel()
        isStartingDictation = false
        dictationTargetThreadID = nil
        hoveredThreadID = nil
        contentMode = .home
        statusMessage = nil
        isSubmitting = false
    }

    func showThreads() {
        contentMode = .threads
        selectedThreadID = nil
        hoveredThreadID = nil
        statusMessage = nil
    }

    func showCalendar() {
        calendarService.start()
        contentMode = .calendar
        statusMessage = nil
    }

    func showTodos() {
        showingPastTodos = false
        contentMode = .todo
        statusMessage = nil
    }

    func openHomeSection(_ section: HomeSection) {
        switch section {
        case .calendar: showCalendar()
        case .codex: showThreads()
        case .todos: showTodos()
        }
    }

    func chooseCreationOption(_ option: CreationOption) {
        switch option {
        case .note:
            openNewNote(source: "create-menu")
        case .codexThread:
            resetSharedEditorDraft(for: option)
            contentMode = .newThread
        case .focusSession:
            resetSharedEditorDraft(for: option)
            contentMode = .focus
        case .meetingRecorder:
            resetSharedEditorDraft(for: option)
            startStandaloneMeetingCapture()
        case .todo:
            resetSharedEditorDraft(for: option)
            showingPastTodos = false
            contentMode = .todo
        }
    }

    func openNewNote(source: String = "new-note") {
        guard !meetingCapture.isActive else {
            statusMessage = "Finish the meeting recording before starting another note"
            return
        }

        if contentMode == .note, !flushCurrentNoteIfNeeded() {
            return
        }

        dictation.cancel()
        isStartingDictation = false
        dictationTargetThreadID = nil
        hoveredThreadID = nil
        selectedCreationOption = .note
        editorTitle = ""
        editorBody = ""
        lastSavedDocument = nil
        noteEditorDocumentID = "draft-\(UUID().uuidString)"
        noteShowsRawMarkdown = false
        noteFindVisible = false
        noteSaveState = .idle
        statusMessage = nil
        contentMode = .note
        setExpanded(true, source: source)
        requestNoteEditorFocus()
    }

    func requestNoteEditorFocus() {
        noteEditorFocusRequest += 1
        focusPanelForKeyboardNavigation()
        DispatchQueue.main.async { [weak self] in
            self?.focusPanelForKeyboardNavigation()
        }
    }

    func noteDraftDidChange() {
        guard contentMode == .note,
              !isStartingDictation,
              !dictation.isRecording
        else {
            return
        }

        if let lastSavedDocument,
           lastSavedDocument.title == editorTitle,
           lastSavedDocument.body == editorBody
        {
            noteAutosaveTask?.cancel()
            noteAutosaveTask = nil
            noteSaveState = .saved
            return
        }

        noteAutosaveTask?.cancel()
        guard hasDocumentContent else {
            noteSaveState = .idle
            statusMessage = nil
            return
        }

        noteSaveState = .saving
        statusMessage = nil
        noteAutosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self, self.contentMode == .note else { return }
            self.saveLocalDocument(kind: .note)
            self.noteAutosaveTask = nil
        }
    }

    func toggleNoteFind() {
        noteFindVisible.toggle()
        if !noteFindVisible {
            requestNoteEditorFocus()
        }
    }

    func toggleNoteSourceMode() {
        noteShowsRawMarkdown.toggle()
        requestNoteEditorFocus()
    }

    private func resetSharedEditorDraft(for option: CreationOption) {
        isStartingDictation = false
        selectedCreationOption = option
        statusMessage = nil
        editorTitle = ""
        editorBody = ""
        lastSavedDocument = nil
        noteSaveState = .idle
    }

    func requestTodoComposerFocus() {
        todoComposerFocusRequest += 1
    }

    func setTodoComposerFocused(_ focused: Bool) {
        todoComposerIsFocused = focused
    }

    @discardableResult
    func addTodo(
        id: UUID = UUID(),
        dueDate: Date? = nil,
        listName: String? = nil
    ) -> UUID? {
        let title = todoDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let normalizedListName = listName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.autoupdatingCurrent

        todos.insert(
            LocalTodo(
                id: id,
                title: title,
                isCompleted: false,
                dueDate: dueDate.map(calendar.startOfDay(for:)),
                listName: normalizedListName?.isEmpty == false ? normalizedListName : nil,
                createdAt: Date()
            ),
            at: 0
        )
        rememberTodoList(normalizedListName)
        todoDraft = ""
        saveTodos()
        resizeExpandedPanel()
        return id
    }

    func toggleTodo(_ id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }

        if todos[index].isCompleted {
            todoCompletionTasks[id]?.cancel()
            todoCompletionTasks[id] = nil
            todos[index].isCompleted = false
            todos[index].completedAt = nil
            todos[index].updatedAt = Date()
            withAnimation(.easeOut(duration: 0.16)) {
                completingTodoIDs.remove(id)
                fadingTodoIDs.remove(id)
            }
            saveTodos()
            resizeExpandedPanel()
            return
        }

        todos[index].isCompleted = true
        todos[index].completedAt = Date()
        todos[index].updatedAt = Date()
        completingTodoIDs.insert(id)
        saveTodos()

        todoCompletionTasks[id]?.cancel()
        todoCompletionTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(2550))
            } catch {
                return
            }
            guard let self, self.completingTodoIDs.contains(id) else { return }

            withAnimation(.easeOut(duration: 0.18)) {
                _ = self.fadingTodoIDs.insert(id)
            }

            do {
                try await Task.sleep(for: .milliseconds(190))
            } catch {
                return
            }
            guard self.completingTodoIDs.contains(id) else { return }

            withAnimation(.spring(response: 0.28, dampingFraction: 0.9, blendDuration: 0.05)) {
                self.completingTodoIDs.remove(id)
                self.fadingTodoIDs.remove(id)
            }
            self.todoCompletionTasks[id] = nil
            self.resizeExpandedPanel()
        }
    }

    func toggleTodoStar(_ id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].isStarred.toggle()
        todos[index].updatedAt = Date()
        saveTodos()
    }

    func toggleTodoDueToday(_ id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        let calendar = Calendar.autoupdatingCurrent
        if let dueDate = todos[index].dueDate, calendar.isDateInToday(dueDate) {
            setTodoDueDate(id, dueDate: nil)
        } else {
            setTodoDueDate(id, dueDate: Date())
        }
    }

    func setTodoDueDate(_ id: UUID, dueDate: Date?) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].dueDate = dueDate.map(Calendar.autoupdatingCurrent.startOfDay(for:))
        todos[index].updatedAt = Date()
        saveTodos()
    }

    func setTodoList(_ id: UUID, listName: String?) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        let normalized = listName?.trimmingCharacters(in: .whitespacesAndNewlines)
        todos[index].listName = normalized?.isEmpty == false ? normalized : nil
        todos[index].updatedAt = Date()
        rememberTodoList(normalized)
        saveTodos()
    }

    func rememberTodoList(_ listName: String?) {
        guard let normalized = listName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty,
              !savedTodoListNames.contains(where: {
                  $0.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
              })
        else {
            return
        }

        savedTodoListNames.append(normalized)
        savedTodoListNames.sort {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        saveTodoListNames()
    }

    func toggleTodoHistory() {
        showingPastTodos.toggle()
        resizeExpandedPanel()
    }

    func deleteTodo(_ id: UUID) {
        todoCompletionTasks[id]?.cancel()
        todoCompletionTasks[id] = nil
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9, blendDuration: 0.04)) {
            todos.removeAll { $0.id == id }
            completingTodoIDs.remove(id)
            fadingTodoIDs.remove(id)
        }
        saveTodos()
        resizeExpandedPanel()
    }

    private func saveTodos() {
        do {
            try todoStore.save(todos)
            statusMessage = nil
            scheduleDesktopSync(fetchRemote: false)
        } catch {
            statusMessage = "Could not save todos: \(error.localizedDescription)"
        }
    }

    private func saveTodoListNames() {
        do {
            try todoStore.saveListNames(savedTodoListNames)
            statusMessage = nil
            scheduleDesktopSync(fetchRemote: false)
        } catch {
            statusMessage = "Could not save todo lists: \(error.localizedDescription)"
        }
    }

    var focusTimeText: String {
        let seconds = max(0, Int(focusRemaining.rounded(.up)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func selectFocusPreset(_ preset: FocusPreset) {
        stopFocusTimer()
        focusPreset = preset
        focusRemaining = TimeInterval(preset.focusMinutes * 60)
        statusMessage = nil
    }

    func toggleFocusSession() {
        if focusIsRunning {
            pauseFocusSession()
            return
        }

        if focusRemaining <= 0 {
            focusRemaining = TimeInterval(focusPreset.focusMinutes * 60)
        }
        focusIsRunning = true
        focusEndsAt = Date().addingTimeInterval(focusRemaining)
        statusMessage = nil
        startFocusTimer()
    }

    func resetFocusSession() {
        stopFocusTimer()
        focusRemaining = TimeInterval(focusPreset.focusMinutes * 60)
        statusMessage = nil
    }

    private func pauseFocusSession() {
        updateFocusRemaining()
        stopFocusTimer()
    }

    private func startFocusTimer() {
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFocusRemaining()
            }
        }
        focusTimer?.tolerance = 0.02
    }

    private func updateFocusRemaining() {
        guard focusIsRunning, let focusEndsAt else { return }
        focusRemaining = max(0, focusEndsAt.timeIntervalSinceNow)
        guard focusRemaining <= 0 else { return }
        stopFocusTimer()
        statusMessage = "Focus complete"
        NSSound.beep()
    }

    private func stopFocusTimer() {
        focusTimer?.invalidate()
        focusTimer = nil
        focusEndsAt = nil
        focusIsRunning = false
    }

    func returnHome() {
        if contentMode == .note, !flushCurrentNoteIfNeeded() {
            return
        }
        dictation.cancel()
        isStartingDictation = false
        dictationTargetThreadID = nil
        hoveredThreadID = nil
        contentMode = .home
        editorTitle = ""
        editorBody = ""
        noteFindVisible = false
        noteShowsRawMarkdown = false
        noteSaveState = .idle
        statusMessage = nil
        isSubmitting = false
    }

    func toggleDictation() {
        guard !meetingCapture.isActive else {
            statusMessage = "Meeting capture is already using the microphone"
            return
        }
        if dictation.isRecording {
            _ = dictation.stop()
            statusMessage = "Press Enter to send"
            return
        }

        let targetThreadID = contentMode == .threads ? hoveredThreadID : nil
        if let targetThreadID {
            isStartingDictation = false
            dictationTargetThreadID = targetThreadID
            selectedThreadID = targetThreadID
            contentMode = .threads
        } else {
            if contentMode == .note, !flushCurrentNoteIfNeeded() {
                return
            }
            isStartingDictation = true
            dictationTargetThreadID = nil
            selectedCreationOption = .note
            editorTitle = ""
            editorBody = ""
            lastSavedDocument = nil
            noteEditorDocumentID = "voice-note-\(UUID().uuidString)"
            noteShowsRawMarkdown = false
            noteFindVisible = false
            noteSaveState = .idle
            contentMode = .note
        }

        setExpanded(true, source: "dictation")
        statusMessage = "Starting microphone"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dictation.start()
                self.isStartingDictation = false
                self.statusMessage = nil
            } catch {
                self.isStartingDictation = false
                self.statusMessage = error.localizedDescription
                self.dictationTargetThreadID = nil
            }
        }
    }

    func commitDictation() {
        let transcript = dictation.isRecording
            ? dictation.stop()
            : dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            statusMessage = "No speech was detected"
            return
        }

        if let threadID = dictationTargetThreadID {
            submitPrompt(transcript, to: threadID)
        } else {
            dictation.cancel()
            isStartingDictation = false
            editorBody = transcript
            saveLocalDocument(kind: .note)
        }
    }

    func cancelDictation() {
        dictation.cancel()
        isStartingDictation = false
        dictationTargetThreadID = nil
        statusMessage = nil
        noteSaveState = .idle
        if contentMode != .threads {
            contentMode = .home
        }
    }

    func saveCurrentDocument() {
        switch contentMode {
        case .note:
            noteAutosaveTask?.cancel()
            noteAutosaveTask = nil
            saveLocalDocument(kind: .note)
        default:
            break
        }
    }

    func createCodexThread() {
        let prompt = editorBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSubmitting else {
            if prompt.isEmpty {
                statusMessage = "Enter a prompt first"
            }
            return
        }

        isSubmitting = true
        statusMessage = "Starting Codex"
        let cwd = selectedWorkspacePath()
        Task { [weak self] in
            guard let self else { return }
            do {
                let submission = try await self.codexClient.startThread(prompt: prompt, cwd: cwd)
                self.selectedThreadID = submission.threadID
                self.statusMessage = "New Codex task started"
                self.isSubmitting = false
                self.contentMode = .threads
                self.editorBody = ""
                self.scheduleThreadRefresh()
            } catch {
                self.isSubmitting = false
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func openLocalLibrary() {
        let url = documentStore.rootURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func submitPrompt(_ prompt: String, to threadID: String) {
        guard !isSubmitting else { return }
        isSubmitting = true
        statusMessage = "Sending to Codex"

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.codexDesktopSender.sendPrompt(prompt, to: threadID)
                self.statusMessage = "Sent to Codex"
                self.isSubmitting = false
                self.scheduleThreadRefresh()
                try? await Task.sleep(for: .milliseconds(850))
                guard self.dictationTargetThreadID == threadID else { return }
                self.dictationTargetThreadID = nil
                self.statusMessage = nil
            } catch {
                self.isSubmitting = false
                self.statusMessage = error.localizedDescription
            }
        }
    }

    private var hasDocumentContent: Bool {
        !editorTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !editorBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    private func flushCurrentNoteIfNeeded() -> Bool {
        noteAutosaveTask?.cancel()
        noteAutosaveTask = nil
        guard hasDocumentContent else {
            noteSaveState = .idle
            return true
        }
        return saveLocalDocument(kind: .note, announce: false)
    }

    @discardableResult
    private func saveLocalDocument(
        kind: LocalDocumentKind,
        announce: Bool = true
    ) -> Bool {
        guard hasDocumentContent else {
            noteSaveState = .idle
            statusMessage = nil
            return true
        }

        do {
            let document: LocalDocument
            if let lastSavedDocument, lastSavedDocument.kind == kind {
                document = try documentStore.update(
                    lastSavedDocument,
                    title: editorTitle,
                    body: editorBody
                )
            } else {
                document = try documentStore.save(
                    kind: kind,
                    title: editorTitle,
                    body: editorBody
                )
            }
            lastSavedDocument = document
            editorTitle = document.title
            noteSaveState = .saved
            statusMessage = nil
            scheduleDesktopSync(fetchRemote: false)
            return true
        } catch {
            let message = error.localizedDescription
            noteSaveState = .failed(message)
            statusMessage = announce ? "Could not save: \(message)" : nil
            return false
        }
    }

    private func selectedWorkspacePath() -> String {
        if let selectedThreadID,
           let path = threads.first(where: { $0.id == selectedThreadID })?.workspacePath,
           FileManager.default.fileExists(atPath: path)
        {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    func handleKeyCode(_ keyCode: UInt16) -> Bool {
        handleKeyEvent(keyCode, modifiers: [])
    }

    func handleKeyEvent(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard targetPresentation == .expanded else { return false }

        if dictation.isRecording {
            switch keyCode {
            case 36, 76:
                commitDictation()
                return true
            case 53:
                cancelDictation()
                return true
            default:
                return false
            }
        }

        let hasPendingDictation = dictationTargetThreadID != nil
            || (contentMode == .note && !dictation.transcript.isEmpty)
        if hasPendingDictation, keyCode == 36 || keyCode == 76 {
            commitDictation()
            return true
        }

        if keyCode == 53, contentMode != .home {
            returnHome()
            return true
        }

        if contentMode == .create,
           modifiers.contains(.command),
           let option = CreationOption.allCases.first(where: { $0.keyCode == keyCode })
        {
            chooseCreationOption(option)
            return true
        }

        if contentMode == .todo,
           modifiers.contains(.command),
           keyCode == 14
        {
            requestTodoComposerFocus()
            return true
        }

        if contentMode == .note, modifiers.contains(.command) {
            let hasShift = modifiers.contains(.shift)
            let hasOption = modifiers.contains(.option)
            let editorIsFocused = noteEditorHasKeyboardFocus

            switch Int(keyCode) {
            case kVK_ANSI_S:
                saveCurrentDocument()
                return true
            case kVK_ANSI_F:
                noteFindVisible = true
                return true
            case kVK_ANSI_B where editorIsFocused && !hasShift && !hasOption:
                NoteEditorFormatting.applyBold()
                return true
            case kVK_ANSI_I where editorIsFocused && !hasShift && !hasOption:
                NoteEditorFormatting.applyItalic()
                return true
            case kVK_ANSI_U where editorIsFocused && !hasShift && !hasOption:
                NoteEditorFormatting.applyUnderline()
                return true
            case kVK_ANSI_K where editorIsFocused && !hasShift && !hasOption:
                NoteEditorFormatting.requestLinkEditor()
                return true
            case kVK_ANSI_X where editorIsFocused && hasShift:
                NoteEditorFormatting.applyStrikethrough()
                return true
            case kVK_ANSI_7 where editorIsFocused && hasShift:
                NoteEditorFormatting.applyOrderedList()
                return true
            case kVK_ANSI_8 where editorIsFocused && hasShift:
                NoteEditorFormatting.applyUnorderedList()
                return true
            case kVK_ANSI_1 where editorIsFocused && hasOption:
                NoteEditorFormatting.applyHeading(1)
                return true
            case kVK_ANSI_2 where editorIsFocused && hasOption:
                NoteEditorFormatting.applyHeading(2)
                return true
            case kVK_ANSI_3 where editorIsFocused && hasOption:
                NoteEditorFormatting.applyHeading(3)
                return true
            default:
                break
            }
        }

        if modifiers.contains(.command), keyCode == 36 || keyCode == 76 {
            switch contentMode {
            case .note:
                saveCurrentDocument()
                return true
            case .newThread:
                createCodexThread()
                return true
            default:
                break
            }
        }

        if contentMode == .create {
            switch keyCode {
            case 125:
                moveCreationSelection(by: 1)
            case 126:
                moveCreationSelection(by: -1)
            case 36, 76:
                chooseCreationOption(selectedCreationOption)
            default:
                return false
            }
            return true
        }

        if contentMode == .focus {
            switch keyCode {
            case 36, 76:
                toggleFocusSession()
            default:
                return false
            }
            return true
        }

        if contentMode == .home {
            switch keyCode {
            case 53:
                setCompact(source: "escape")
            case 125:
                moveHomeSelection(by: 1)
            case 126:
                moveHomeSelection(by: -1)
            case 36, 76:
                openHomeSection(selectedHomeSection)
            default:
                return false
            }
            return true
        }

        guard contentMode == .threads else { return false }

        switch keyCode {
        case 53:
            returnHome()
        case 125:
            moveSelection(by: 1)
        case 126:
            moveSelection(by: -1)
        case 36, 76:
            guard let selectedThreadID,
                  let thread = orderedThreads.first(where: { $0.id == selectedThreadID })
            else {
                return true
            }
            openThread(thread)
        default:
            return false
        }
        return true
    }

    private func moveCreationSelection(by offset: Int) {
        let options = CreationOption.allCases
        let current = options.firstIndex(of: selectedCreationOption) ?? 0
        let next = min(max(current + offset, 0), options.count - 1)
        selectedCreationOption = options[next]
    }

    private func moveHomeSelection(by offset: Int) {
        let sections = HomeSection.allCases
        let current = sections.firstIndex(of: selectedHomeSection) ?? 0
        let next = min(max(current + offset, 0), sections.count - 1)
        selectedHomeSection = sections[next]
    }

    private func moveSelection(by offset: Int) {
        let list = orderedThreads
        guard !list.isEmpty else {
            selectedThreadID = nil
            return
        }

        guard let selectedThreadID,
              let currentIndex = list.firstIndex(where: { $0.id == selectedThreadID })
        else {
            self.selectedThreadID = offset > 0 ? list.first?.id : list.last?.id
            keyboardSelectionDirection = offset
            keyboardSelectionRevision += 1
            return
        }

        let nextIndex = min(max(currentIndex + offset, 0), list.count - 1)
        self.selectedThreadID = list[nextIndex].id
        keyboardSelectionDirection = offset
        keyboardSelectionRevision += 1
    }

    func targetFrame(expanded: Bool) -> NSRect {
        targetFrame(for: expanded ? .expanded : .compact)
    }

    private func targetFrame(for presentation: PanelPresentation) -> NSRect {
        switch presentation {
        case .notch:
            targetFrame(size: PanelMetrics.notchSize)
        case .compact:
            targetFrame(size: PanelMetrics.compactSize)
        case .expanded:
            targetFrame(size: expandedSize)
        }
    }

    private func targetFrame(size: NSSize) -> NSRect {
        let screen = window?.screen ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = max(1, window?.backingScaleFactor ?? screen?.backingScaleFactor ?? 1)
        let width = Self.pixelAligned(size.width, scale: scale)
        let height = Self.pixelAligned(size.height, scale: scale)
        let x = Self.pixelAligned(screenFrame.midX - width / 2, scale: scale)
        let top = Self.pixelAligned(screenFrame.maxY, scale: scale)

        return NSRect(
            x: x,
            y: top - height,
            width: width,
            height: height
        )
    }

    private static func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    @discardableResult
    private func applyPinnedWindowFrame(_ proposedFrame: NSRect, display: Bool) -> NSRect {
        guard let window else { return proposedFrame }
        let screen = window.screen ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = max(1, window.backingScaleFactor)
        let width = Self.pixelAligned(proposedFrame.width, scale: scale)
        let height = Self.pixelAligned(proposedFrame.height, scale: scale)
        let top = Self.pixelAligned(screenFrame.maxY, scale: scale)
        let pinnedFrame = NSRect(
            x: Self.pixelAligned(screenFrame.midX - width / 2, scale: scale),
            y: top - height,
            width: width,
            height: height
        )

        window.setFrame(pinnedFrame, display: false)
        if abs(window.frame.maxY - top) > 0.001 {
            window.setFrameTopLeftPoint(NSPoint(x: pinnedFrame.minX, y: top))
        }
        let appliedFrame = window.frame
        (window.contentView as? PanelHostingView)?.syncContourMask(for: appliedFrame.size)
        if display {
            window.displayIfNeeded()
        }
        return appliedFrame
    }

    private func resizeExpandedPanel(animated: Bool = true) {
        guard targetPresentation == .expanded, let window else { return }
        let frame = targetFrame(size: expandedSize)
        if frameAnimationTimer != nil,
           Self.framesMatch(frameAnimationTargetFrame, frame)
        {
            return
        }
        guard abs(window.frame.width - frame.width) > 0.5
            || abs(window.frame.height - frame.height) > 0.5
            || abs(window.frame.origin.y - frame.origin.y) > 0.5
        else {
            return
        }

        if animated {
            animateWindow(to: frame, duration: PanelMetrics.transitionDuration)
        } else {
            cancelFrameAnimation()
            applyPinnedWindowFrame(frame, display: true)
        }
    }

    func openFromNotchWheel() {
        setExpanded(true, source: "wheel")
    }

    func openFromCompactSurface() {
        guard !meetingCapture.isActive else { return }
        setExpanded(true, source: "compact-surface")
    }

    func openCalendarFromCompactTime() {
        showCalendar()
        setExpanded(true, source: "compact-calendar-time")
    }

    func startMeetingCapture(_ event: CalendarEventItem) {
        guard !meetingCapture.isActive else { return }
        if dictation.isRecording || dictationTargetThreadID != nil {
            cancelDictation()
        }
        statusMessage = "Preparing meeting capture"
        if isSmokeTest {
            do {
                try meetingCapture.startPreview(event: event)
                statusMessage = nil
            } catch {
                statusMessage = error.localizedDescription
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.meetingCapture.start(event: event)
                self.statusMessage = nil
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func startMeetingCaptureFromCalendar(_ event: CalendarEventItem) {
        guard !meetingCapture.isActive else { return }
        startMeetingCapture(event)
        setCompact(source: "calendar-meeting-recorder")
    }

    func startStandaloneMeetingCapture() {
        guard !meetingCapture.isActive else { return }
        let startedAt = Date()
        let event = CalendarEventItem(
            id: "standalone-meeting-\(UUID().uuidString)",
            title: "Meeting recording",
            startDate: startedAt,
            endDate: startedAt.addingTimeInterval(60 * 60),
            isAllDay: false,
            calendarTitle: "Local recording",
            location: nil,
            tint: CalendarEventTint(red: 1, green: 0.35, blue: 0.28)
        )
        startMeetingCapture(event)
        setCompact(source: "create-meeting-recorder")
    }

    func stopMeetingCapture() {
        guard meetingCapture.isActive else { return }
        let event = meetingCapture.currentEvent
        let startedAt = Date().addingTimeInterval(-meetingCapture.elapsed)
        Task { [weak self] in
            guard let self,
                  let note = await self.meetingCapture.stop()
            else { return }

            let endedAt = Date()

            self.lastSavedDocument = note
            self.editorTitle = note.title
            self.editorBody = note.body
            self.noteEditorDocumentID = note.id
            self.noteShowsRawMarkdown = false
            self.noteFindVisible = false
            self.noteSaveState = .saved
            self.selectedCreationOption = .note
            self.contentMode = .note
            self.statusMessage = nil
            self.setExpanded(true, source: "meeting-note")
            self.requestNoteEditorFocus()
            Task {
                await self.desktopSync.publishMeeting(
                    document: note,
                    event: event,
                    startedAt: startedAt,
                    endedAt: endedAt
                )
            }
        }
    }

    func dismissMeetingCaptureFailure() {
        meetingCapture.dismissFailure()
        statusMessage = nil
    }

    func handleGlobalPanelEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, targetPresentation == .expanded {
            handleOutsideClick()
            return
        }

        guard targetPresentation == .notch else { return }
        let point = NSEvent.mouseLocation
        guard isInsideNotchTrigger(point) else { return }

        let source = event.type == .scrollWheel ? "global-wheel" : "global-click"
        setExpanded(true, source: source)
    }

    func handleOutsideClick() {
        guard targetPresentation == .expanded else { return }
        setCompact(source: "outside-click")
    }

    func isInsideNotchTrigger(_ point: NSPoint) -> Bool {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        guard let screen else { return false }

        let triggerWidth = PanelMetrics.notchSize.width + 36
        let triggerHeight = PanelMetrics.notchSize.height + 18
        let triggerFrame = NSRect(
            x: screen.frame.midX - triggerWidth / 2,
            y: screen.frame.maxY - triggerHeight,
            width: triggerWidth,
            height: triggerHeight
        )
        return triggerFrame.contains(point)
    }

    func toggleFromGlobalHotKey() {
        if isPanelHidden {
            isPanelHidden = false
            guard let window else { return }
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            window.orderFrontRegardless()

            if meetingCapture.isActive {
                targetPresentation = .compact
                expanded = false
                compactVisible = true
                contentVisible = false
                applyPinnedWindowFrame(targetFrame(for: .compact), display: true)
            } else {
                setExpanded(true, source: "option-space-restore")
            }
            return
        }

        toggle()
    }

    func hidePanelCompletely() {
        guard !isPanelHidden else { return }
        isPanelHidden = true
        transitionID += 1
        cancelFrameAnimation()
        dictation.cancel()
        dictationTargetThreadID = nil
        hoveredThreadID = nil

        window?.alphaValue = 0
        window?.ignoresMouseEvents = true
        targetPresentation = .compact
        expanded = false
        compactVisible = true
        contentVisible = false
        applyPinnedWindowFrame(targetFrame(for: .compact), display: false)
    }

    func toggle() {
        guard !meetingCapture.isActive else { return }
        if targetPresentation == .expanded {
            setCompact(source: "toggle")
        } else {
            setExpanded(true, source: "toggle")
        }
    }

    func setExpanded(_ nextExpanded: Bool, source: String = "manual", animated: Bool = true) {
        setPresentation(nextExpanded ? .expanded : .compact, source: source, animated: animated)
    }

    func setCompact(source: String = "manual", animated: Bool = true) {
        setPresentation(.compact, source: source, animated: animated)
    }

    private func setNotch(source: String, animated: Bool) {
        setPresentation(.notch, source: source, animated: animated)
    }

    private func setPresentation(
        _ nextPresentation: PanelPresentation,
        source: String,
        animated: Bool
    ) {
        if isPanelHidden {
            isPanelHidden = false
            window?.alphaValue = 1
            window?.ignoresMouseEvents = false
            window?.orderFrontRegardless()
        }
        guard nextPresentation != targetPresentation || !animated else { return }
        targetPresentation = nextPresentation
        transitionID += 1
        let activeTransition = transitionID

        if nextPresentation == .expanded {
            lastOpenSource = source
            calendarService.start()
        } else {
            dictation.cancel()
            dictationTargetThreadID = nil
            hoveredThreadID = nil
        }

        guard let window else { return }
        window.orderFrontRegardless()

        switch nextPresentation {
        case .expanded:
            expanded = true
            compactVisible = false
            contentVisible = false
            window.contentView?.layoutSubtreeIfNeeded()
            focusPanelForKeyboardNavigation()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.targetPresentation == .expanded else { return }
                self.focusPanelForKeyboardNavigation()
            }
        case .compact:
            withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.12)) {
                contentVisible = false
            }
            if !animated || !expanded {
                expanded = false
                compactVisible = true
                window.contentView?.layoutSubtreeIfNeeded()
            }
        case .notch:
            withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.12)) {
                contentVisible = false
            }
        }

        guard animated else {
            cancelFrameAnimation()
            expanded = nextPresentation == .expanded
            compactVisible = nextPresentation == .compact
            contentVisible = nextPresentation == .expanded
            applyPinnedWindowFrame(targetFrame(for: nextPresentation), display: true)
            return
        }

        if nextPresentation == .expanded {
            animateWindow(
                to: targetFrame(for: .expanded),
                duration: PanelMetrics.transitionDuration
            ) { [weak self] in
                self?.focusPanelForKeyboardNavigation()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self, activeTransition == self.transitionID else { return }
                withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.14)) {
                    self.contentVisible = true
                }
            }
        } else if nextPresentation == .compact {
            animateWindow(
                to: targetFrame(for: .compact),
                duration: PanelMetrics.transitionDuration
            ) { [weak self] in
                guard let self, activeTransition == self.transitionID else { return }
                self.expanded = false
                self.compactVisible = true
            }
        } else {
            animateWindow(
                to: targetFrame(for: .notch),
                duration: PanelMetrics.transitionDuration
            ) { [weak self] in
                guard let self, activeTransition == self.transitionID else { return }
                self.expanded = false
                self.compactVisible = false
            }
        }
    }

    private func animateWindow(
        to frame: NSRect,
        duration: TimeInterval,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let window else { return }
        cancelFrameAnimation()
        frameAnimationStartFrame = window.frame
        frameAnimationTargetFrame = frame
        frameAnimationStartedAt = CACurrentMediaTime()
        frameAnimationDuration = duration
        frameAnimationCompletion = completion
        frameAnimationGeneration += 1

        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceFrameAnimation()
            }
        }
        frameAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
    }

    private func advanceFrameAnimation() {
        guard window != nil else {
            cancelFrameAnimation()
            return
        }

        let linearProgress = min(
            1,
            max(0, (CACurrentMediaTime() - frameAnimationStartedAt) / frameAnimationDuration)
        )
        let easedProgress = Self.panelAnimationProgress(linearProgress)
        let nextFrame = NSRect(
            x: frameAnimationStartFrame.origin.x
                + (frameAnimationTargetFrame.origin.x - frameAnimationStartFrame.origin.x) * easedProgress,
            y: frameAnimationStartFrame.origin.y
                + (frameAnimationTargetFrame.origin.y - frameAnimationStartFrame.origin.y) * easedProgress,
            width: frameAnimationStartFrame.width
                + (frameAnimationTargetFrame.width - frameAnimationStartFrame.width) * easedProgress,
            height: frameAnimationStartFrame.height
                + (frameAnimationTargetFrame.height - frameAnimationStartFrame.height) * easedProgress
        )
        applyPinnedWindowFrame(nextFrame, display: true)

        if linearProgress >= 1 {
            let completion = frameAnimationCompletion
            frameAnimationTimer?.invalidate()
            frameAnimationTimer = nil
            frameAnimationCompletion = nil
            applyPinnedWindowFrame(frameAnimationTargetFrame, display: true)
            completion?()
        }
    }

    private func cancelFrameAnimation() {
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        frameAnimationCompletion = nil
    }

    private static func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= 0.5
            && abs(lhs.origin.y - rhs.origin.y) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5
            && abs(lhs.height - rhs.height) <= 0.5
    }

    private static func panelAnimationProgress(_ progress: Double) -> CGFloat {
        let x1 = 0.165
        let y1 = 0.84
        let x2 = 0.44
        let y2 = 1.0
        var parameter = progress

        for _ in 0 ..< 7 {
            let x = cubicBezier(parameter, first: x1, second: x2)
            let derivative = cubicBezierDerivative(parameter, first: x1, second: x2)
            guard abs(derivative) > 0.000_01 else { break }
            parameter = min(1, max(0, parameter - (x - progress) / derivative))
        }

        return CGFloat(cubicBezier(parameter, first: y1, second: y2))
    }

    private static func cubicBezier(_ t: Double, first: Double, second: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * first
            + 3 * inverse * t * t * second
            + t * t * t
    }

    private static func cubicBezierDerivative(
        _ t: Double,
        first: Double,
        second: Double
    ) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * first
            + 6 * inverse * t * (second - first)
            + 3 * t * t * (1 - second)
    }

    func repositionForCurrentScreen() {
        guard window != nil else { return }
        applyPinnedWindowFrame(targetFrame(for: targetPresentation), display: true)
    }

    func capturePNG(named filename: String) throws -> URL {
        guard let window, let view = window.contentView else {
            throw SmokeError("Panel content view is missing.")
        }

        func invalidateDisplayTree(_ current: NSView) {
            current.needsDisplay = true
            current.layer?.setNeedsDisplay()
            current.subviews.forEach(invalidateDisplayTree)
        }

        invalidateDisplayTree(view)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SmokeError("Could not create bitmap representation.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SmokeError("Could not encode PNG.")
        }

        let url = try artifactURL(named: filename)
        try data.write(to: url)
        return url
    }

    private func artifactURL(named filename: String) throws -> URL {
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let repositoryRoot = bundleParent.lastPathComponent == ".build"
            ? bundleParent.deletingLastPathComponent()
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let artifacts = repositoryRoot.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        return artifacts.appendingPathComponent(filename)
    }

    private func validateThreadPresentationLogic() throws {
        guard AppAssets.openAIBlossom != nil else {
            throw SmokeError("Expected the bundled OpenAI blossom SVG to load.")
        }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-48 * 60 * 60)
        let recent = now.addingTimeInterval(-2 * 60 * 60)
        let samples = [
            AgentThread(
                id: "running",
                projectName: "alpha",
                workspacePath: "/tmp/alpha",
                title: "Running",
                activity: "Working",
                state: .running,
                modes: [],
                elapsed: "2m",
                createdAt: old,
                updatedAt: recent
            ),
            AgentThread(
                id: "created",
                projectName: "alpha",
                workspacePath: "/tmp/alpha",
                title: "Created recently",
                activity: "Complete",
                state: .completed,
                modes: [.plan],
                elapsed: "<1m",
                createdAt: recent,
                updatedAt: old
            ),
            AgentThread(
                id: "stale",
                projectName: "beta",
                workspacePath: "/tmp/beta",
                title: "Older task",
                activity: "Complete",
                state: .completed,
                modes: [],
                elapsed: "4m",
                createdAt: old,
                updatedAt: old
            ),
        ]

        let feed = AgentThread.activityFeed(from: samples, now: now)
        guard feed.map(\.id) == ["running", "created"] else {
            throw SmokeError("The 24-hour activity feed did not prioritize live work or include recent creation time.")
        }

        let sections = ThreadProjectSection.build(from: samples, excluding: [])
        guard sections.count == 2,
              sections.first(where: { $0.name == "alpha" })?.threads.map(\.id) == ["running", "created"],
              sections.first(where: { $0.name == "beta" })?.threads.map(\.id) == ["stale"]
        else {
            throw SmokeError("Project sections did not retain tasks that also appear in the activity feed.")
        }

        let suiteName = "com.platon.iagent-panel.smoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SmokeError("Could not create isolated project-order preferences.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectSectionPreferenceStore(defaults: defaults)
        let moved = ProjectSectionPreferenceStore.moving("beta", to: 0, in: ["alpha", "beta"])
        let movedDown = ProjectSectionPreferenceStore.moving(
            "alpha",
            to: 2,
            in: ["alpha", "beta", "gamma"]
        )
        let projectFrames = [
            "alpha": CGRect(x: 0, y: 0, width: 200, height: 40),
            "beta": CGRect(x: 0, y: 40, width: 200, height: 40),
            "gamma": CGRect(x: 0, y: 80, width: 200, height: 40),
        ]
        let liftedToTop = ProjectDragPlacement.insertionIndex(
            pointerY: 12,
            orderedIDs: ["alpha", "beta", "gamma"],
            frames: projectFrames,
            draggedID: "beta"
        )
        let liftedToBottom = ProjectDragPlacement.insertionIndex(
            pointerY: 120,
            orderedIDs: ["alpha", "beta", "gamma"],
            frames: projectFrames,
            draggedID: "beta"
        )
        store.saveOrder(moved)
        store.saveCollapsedIDs(["alpha"])
        guard moved == ["beta", "alpha"],
              movedDown == ["beta", "gamma", "alpha"],
              liftedToTop == 0,
              liftedToBottom == 2,
              store.loadOrder() == moved,
              store.loadCollapsedIDs() == ["alpha"]
        else {
            throw SmokeError("Project drag order or collapse state did not survive a preference reload.")
        }

        let todoRoot = URL(
            fileURLWithPath: "/private/tmp/iagent-todo-store-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: todoRoot) }
        let todoStore = LocalTodoStore(rootURL: todoRoot)
        let persistedTodos = [
            LocalTodo(
                id: UUID(),
                title: "First local todo",
                isCompleted: false,
                dueDate: recent,
                listName: "Work",
                createdAt: now
            ),
            LocalTodo(
                id: UUID(),
                title: "Completed local todo",
                isCompleted: true,
                completedAt: now,
                createdAt: recent
            ),
        ]
        try todoStore.save(persistedTodos)
        let persistedTodoLists = ["Personal", "Work"]
        try todoStore.saveListNames(persistedTodoLists)
        guard try todoStore.load() == persistedTodos,
              try todoStore.loadListNames() == persistedTodoLists,
              LocalTodo(
                  id: UUID(),
                  title: "Recent todo",
                  isCompleted: false,
                  createdAt: now.addingTimeInterval(-125)
              ).createdRelativeText(referenceDate: now) == "2m",
              LocalTodo(
                  id: UUID(),
                  title: "Older todo",
                  isCompleted: true,
                  createdAt: now.addingTimeInterval(-120 * 24 * 60 * 60)
              ).createdRelativeText(referenceDate: now) == "4mon",
              CreationOption.allCases.map(\.title) == [
                  "New note",
                  "New codex thread",
                  "New focus session",
                  "Meeting recorder",
                  "New todo",
              ],
              CreationOption.meetingRecorder.shortcutLabel == "⌘R",
              CreationOption.todo.shortcutLabel == "⌘T"
        else {
            throw SmokeError("Expected local todos and Create-menu shortcuts to persist their exact values.")
        }

        let twoMinutesAgo = now.addingTimeInterval(-125)
        let oneHundredTwentyDaysAgo = now.addingTimeInterval(-120 * 24 * 60 * 60)
        guard samples[0].updatedRelativeText(referenceDate: now) == "2h",
              AgentThread(
                  id: "relative-time",
                  projectName: nil,
                  workspacePath: nil,
                  title: "Relative time",
                  activity: "Testing",
                  state: .completed,
                  modes: [],
                  elapsed: "2m",
                  createdAt: twoMinutesAgo,
                  updatedAt: twoMinutesAgo
              ).updatedRelativeText(referenceDate: now) == "2m",
              AgentThread(
                  id: "old-relative-time",
                  projectName: nil,
                  workspacePath: nil,
                  title: "Old relative time",
                  activity: "Testing",
                  state: .completed,
                  modes: [],
                  elapsed: "2m",
                  createdAt: oneHundredTwentyDaysAgo,
                  updatedAt: oneHundredTwentyDaysAgo
              ).updatedRelativeText(referenceDate: now) == "17w"
        else {
            throw SmokeError("Expected task timestamps to describe time since the latest update.")
        }

        guard SelectionRevealEdge.required(
            for: CGRect(x: 0, y: 20, width: 100, height: 32),
            viewportHeight: 100
        ) == nil,
            SelectionRevealEdge.required(
                for: CGRect(x: 0, y: 84, width: 100, height: 32),
                viewportHeight: 100
            ) == .bottom,
            SelectionRevealEdge.required(
                for: CGRect(x: 0, y: -8, width: 100, height: 32),
                viewportHeight: 100
            ) == .top
        else {
            throw SmokeError("Keyboard reveal logic must leave visible rows still and reveal only clipped rows.")
        }

        let expandedContour = PanelContourShape().path(
            in: CGRect(x: 0, y: 0, width: PanelMetrics.expandedWidth, height: 348)
        )
        guard expandedContour.contains(CGPoint(x: 10, y: 1)),
              !expandedContour.contains(CGPoint(x: 2, y: 36)),
              expandedContour.contains(CGPoint(x: 18, y: 36)),
              expandedContour.contains(CGPoint(x: PanelMetrics.expandedWidth - 10, y: 1)),
              !expandedContour.contains(CGPoint(x: PanelMetrics.expandedWidth - 2, y: 36)),
              expandedContour.contains(CGPoint(x: PanelMetrics.expandedWidth - 18, y: 36)),
              ThreadMode.plan.symbol == "lightbulb"
        else {
            throw SmokeError("Expected symmetric concave top ramps and the lightbulb plan glyph.")
        }

        let openingRects = [
            CGRect(x: 0, y: 0, width: 230, height: 48),
            CGRect(
                x: 0,
                y: 0,
                width: PanelMetrics.compactSize.width,
                height: PanelMetrics.compactSize.height
            ),
            CGRect(x: 0, y: 0, width: 360, height: 96),
            CGRect(x: 0, y: 0, width: 560, height: 210),
        ]
        for rect in openingRects {
            let contour = PanelContourShape().path(in: rect)
            guard contour.contains(CGPoint(x: 10, y: 1)),
                  !contour.contains(CGPoint(x: 2, y: 18)),
                  contour.contains(CGPoint(x: 18, y: 18)),
                  contour.contains(CGPoint(x: rect.maxX - 10, y: 1)),
                  !contour.contains(CGPoint(x: rect.maxX - 2, y: 18)),
                  contour.contains(CGPoint(x: rect.maxX - 18, y: 18)),
                  !contour.contains(CGPoint(x: 2, y: rect.maxY - 2)),
                  !contour.contains(CGPoint(x: rect.maxX - 2, y: rect.maxY - 2)),
                  contour.contains(CGPoint(x: rect.midX, y: rect.maxY - 2))
            else {
                throw SmokeError("Expected persistent top ramps and rounded bottom corners throughout every opening frame.")
            }
        }
    }

    func runSmokeTest(dataWaitAttempt: Int = 0) {
        let delay = dataWaitAttempt == 0 ? 0.75 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.threads.isEmpty,
               self.loadError == nil,
               dataWaitAttempt < 20
            {
                self.runSmokeTest(dataWaitAttempt: dataWaitAttempt + 1)
                return
            }

            do {
                try self.validateThreadPresentationLogic()
                guard let window = self.window, let screenFrame = NSScreen.main?.frame else {
                    throw SmokeError("Window or screen is unavailable.")
                }

                guard self.contentMode == .home,
                      self.panelTitle == self.homeTitle,
                      self.expandedSize.height == PanelMetrics.homeExpandedHeight
                else {
                    throw SmokeError("Expected Home to be the default panel destination.")
                }
                self.setNotch(source: "smoke-setup", animated: false)
                self.showThreads()

                let collapsedFrame = window.frame
                let expectedExpandedSize = self.expandedSize
                guard abs(collapsedFrame.maxY - screenFrame.maxY) <= 0.01 else {
                    throw SmokeError("Expected collapsed notch to touch physical screen top. frame=\(collapsedFrame) screen=\(screenFrame)")
                }

                guard collapsedFrame.height <= 42, collapsedFrame.width <= 220 else {
                    throw SmokeError("Expected compact notch frame, got \(collapsedFrame).")
                }

                let triggerProbe = NSPoint(x: screenFrame.midX, y: screenFrame.maxY - collapsedFrame.height)
                guard self.isInsideNotchTrigger(triggerProbe) else {
                    throw SmokeError("Expected the visible lower notch edge to be in the global trigger zone.")
                }

                let collapsedURL = try self.capturePNG(named: "iagent-native-notch-collapsed.png")
                var wheelEventReachedHandler = false
                let catcher = ScrollCatcher.CatcherView()
                catcher.onWheel = {
                    wheelEventReachedHandler = true
                    self.openFromNotchWheel()
                }

                catcher.scrollWheel(with: SmokeScrollEvent())
                guard wheelEventReachedHandler else {
                    throw SmokeError("Synthetic scroll-wheel event did not reach the notch handler.")
                }

                for (delay, filename) in [
                    (0.016, "iagent-native-panel-opening-016ms.png"),
                    (0.045, "iagent-native-panel-opening-045ms.png"),
                    (0.080, "iagent-native-panel-opening-080ms.png"),
                ] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        _ = try? self.capturePNG(named: filename)
                        guard let hostingView = window.contentView as? PanelHostingView,
                              hostingView.renderedContourHasTopRamps(),
                              abs(window.frame.maxY - screenFrame.maxY) <= 0.01
                        else {
                            self.failSmoke("Panel detached or its rendered ramps disappeared at \(Int(delay * 1_000))ms during opening.")
                            return
                        }
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard window.firstResponder === window.contentView,
                          self.handleKeyCode(125),
                          self.selectedThreadID == self.orderedThreads.first?.id
                    else {
                        self.failSmoke("Hotkey-style opening did not provide immediate arrow-key navigation.")
                        return
                    }
                    self.selectedThreadID = nil
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    let frame = window.frame
                    guard frame.width > collapsedFrame.width + 24,
                          frame.width < expectedExpandedSize.width,
                          frame.height > collapsedFrame.height + 16,
                          frame.height < expectedExpandedSize.height,
                          abs(frame.maxY - screenFrame.maxY) <= 0.01,
                          (window.contentView as? PanelHostingView)?.renderedContourHasTopRamps() == true
                    else {
                        self.failSmoke("Open animation lost its pinned frame or rendered ramps: \(frame).")
                        return
                    }
                    _ = try? self.capturePNG(named: "iagent-native-panel-opening.png")
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
                    do {
                        let expandedFrame = window.frame
                        guard self.expanded, self.lastOpenSource == "wheel" else {
                            throw SmokeError("Expected panel to be opened by wheel source.")
                        }

                        guard self.contentVisible else {
                            throw SmokeError("Expected dashboard content to finish its reveal animation.")
                        }

                        guard window.firstResponder === window.contentView else {
                            throw SmokeError("Expected the panel host to retain keyboard focus after opening.")
                        }

                        guard abs(expandedFrame.maxY - screenFrame.maxY) <= 0.01 else {
                            throw SmokeError("Expected expanded panel to remain pinned to physical top. frame=\(expandedFrame) screen=\(screenFrame)")
                        }

                        guard abs(expandedFrame.width - self.expandedSize.width) <= 2,
                              abs(expandedFrame.height - self.expandedSize.height) <= 2
                        else {
                            throw SmokeError("Expected expanded panel dimensions, got \(expandedFrame).")
                        }

                        guard expandedFrame.height <= 350 else {
                            throw SmokeError("Expected the task panel height to be reduced by roughly one third.")
                        }

                        guard !self.threads.isEmpty, self.databasePath.hasSuffix(".sqlite") else {
                            throw SmokeError("Expected recent threads from the local Codex SQLite store. error=\(self.loadError ?? "none")")
                        }

                        guard self.threads.contains(where: { $0.state.isActive }),
                              self.threads.allSatisfy({ !$0.title.isEmpty && !$0.activity.isEmpty && !$0.elapsed.isEmpty })
                        else {
                            throw SmokeError("Expected populated real-thread rows and at least one live loading state.")
                        }

                        let activityCutoff = self.referenceNow.addingTimeInterval(-24 * 60 * 60)
                        guard !self.activityThreads.isEmpty,
                              self.activityThreads.allSatisfy({
                                  $0.createdAt >= activityCutoff || $0.updatedAt >= activityCutoff
                              })
                        else {
                            throw SmokeError("Expected the activity section to contain only tasks created or modified in the last 24 hours.")
                        }

                        var encounteredInactiveTask = false
                        for thread in self.activityThreads {
                            if thread.state.isActive, encounteredInactiveTask {
                                throw SmokeError("Expected currently live tasks to remain above inactive recent tasks.")
                            }
                            if !thread.state.isActive {
                                encounteredInactiveTask = true
                            }
                        }

                        let activityIDs = Set(self.activityThreads.map(\.id))
                        let projectTaskIDs = self.projectSections.flatMap(\.threads).map(\.id)
                        let projectIDs = Set(self.projectSections.map(\.id))
                        guard activityIDs.isSubset(of: Set(projectTaskIDs)),
                              Set(self.orderedThreads.map(\.id)).count == self.orderedThreads.count,
                              projectIDs.isSubset(of: Set(self.projectOrder)),
                              self.panelTitle == "Codex"
                        else {
                            throw SmokeError("Expected activity tasks inside their projects, unique keyboard rows, persisted project IDs, and the Codex title.")
                        }

                        guard let thread = self.threads.first,
                              let threadURL = self.threadURL(for: thread),
                              threadURL.scheme == "codex",
                              NSWorkspace.shared.urlForApplication(toOpen: threadURL) != nil
                        else {
                            throw SmokeError("Expected Codex task links to have a registered desktop handler.")
                        }

                        guard self.orderedThreads.count >= 2 else {
                            throw SmokeError("Expected at least two keyboard-navigable tasks.")
                        }

                        self.selectedThreadID = nil
                        let hoverTargetID = self.orderedThreads[0].id
                        let selectionRevision = self.keyboardSelectionRevision
                        self.setHoveredThread(hoverTargetID, hovering: true)
                        guard self.hoveredThreadID == hoverTargetID,
                              self.selectedThreadID == nil,
                              self.keyboardSelectionRevision == selectionRevision
                        else {
                            throw SmokeError("Pointer hover must not select or scroll the task list.")
                        }
                        self.setHoveredThread(hoverTargetID, hovering: false)

                        let focusRestorationCount = self.focusRestorationCount
                        guard self.handleKeyCode(125),
                              self.selectedThreadID == self.orderedThreads[0].id,
                              self.handleKeyCode(125),
                              self.selectedThreadID == self.orderedThreads[1].id,
                              self.handleKeyCode(126),
                              self.selectedThreadID == self.orderedThreads[0].id,
                              self.handleKeyCode(36),
                              self.lastOpenedThreadID == self.orderedThreads[0].id,
                              self.focusRestorationCount == focusRestorationCount + 1,
                              window.canBecomeKey
                        else {
                            throw SmokeError("Expected arrow keys and Enter to open the selected task and request panel focus.")
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            do {
                                let expandedURL = try self.capturePNG(named: "iagent-native-panel-expanded.png")
                                self.runFeatureSmokeSequence(
                                    window: window,
                                    screenFrame: screenFrame,
                                    collapsedFrame: collapsedFrame,
                                    expandedFrame: expandedFrame,
                                    collapsedURL: collapsedURL,
                                    expandedURL: expandedURL,
                                    wheelEventReachedHandler: wheelEventReachedHandler
                                )
                            } catch {
                                self.failSmoke(String(describing: error))
                            }
                        }
                    } catch {
                        self.failSmoke(String(describing: error))
                    }
                }
            } catch {
                self.failSmoke(String(describing: error))
            }
        }
    }

    private func runFeatureSmokeSequence(
        window: PanelWindow,
        screenFrame: NSRect,
        collapsedFrame: NSRect,
        expandedFrame: NSRect,
        collapsedURL: URL,
        expandedURL: URL,
        wheelEventReachedHandler: Bool
    ) {
        var accumulatedSpeech = SpeechTranscriptAccumulator()
        accumulatedSpeech.update(with: "Keep the first phrase")
        accumulatedSpeech.markSpeechResumed()
        accumulatedSpeech.update(with: "and append this after a pause")
        guard accumulatedSpeech.text == "Keep the first phrase and append this after a pause" else {
            failSmoke("Expected resumed speech to append without replacing the earlier transcript.")
            return
        }

        Task { @MainActor in
            do {
                showCreationMenu()
                try await Task.sleep(for: .milliseconds(140))
                let createTransitionFrame = window.frame
                guard createTransitionFrame.height > self.expandedSize.height + 1,
                      createTransitionFrame.height < expandedFrame.height - 1,
                      abs(createTransitionFrame.maxY - screenFrame.maxY) <= 2
                else {
                    throw SmokeError("Expected a visible, top-pinned transition into the compact create view. frame=\(createTransitionFrame)")
                }
                let dynamicResizeURL = try self.capturePNG(named: "iagent-panel-dynamic-resize.png")

                try await Task.sleep(for: .milliseconds(420))
                let createFrame = window.frame
                guard self.contentMode == .create,
                      self.panelTitle == "Create",
                      abs(createFrame.height - self.expandedSize.height) <= 2,
                      createFrame.height < expandedFrame.height,
                      abs(createFrame.maxY - screenFrame.maxY) <= 2
                else {
                    throw SmokeError("Expected a compact, top-pinned creation menu with a dynamic title. frame=\(createFrame)")
                }
                let createURL = try self.capturePNG(named: "iagent-create-menu.png")

                self.chooseCreationOption(.meetingRecorder)
                try await Task.sleep(for: .milliseconds(380))
                guard self.meetingCapture.isListening,
                      self.meetingCapture.currentEvent?.title == "Meeting recording",
                      !self.expanded,
                      self.compactVisible
                else {
                    throw SmokeError("Expected Meeting recorder to enter compact listening mode.")
                }
                let standaloneMeetingURL = try self.capturePNG(
                    named: "iagent-standalone-meeting-recorder.png"
                )
                self.meetingCapture.shutdown()
                self.showCreationMenu()
                self.setExpanded(true, source: "smoke-create-restore", animated: false)

                self.selectedCreationOption = .todo
                try await Task.sleep(for: .milliseconds(80))
                let createBottomURL = try self.capturePNG(
                    named: "iagent-create-menu-bottom-selection.png"
                )

                self.selectedCreationOption = .note
                guard self.handleKeyCode(125), self.selectedCreationOption == .codexThread,
                      self.handleKeyCode(126), self.selectedCreationOption == .note
                else {
                    throw SmokeError("Expected arrow keys to move through creation options.")
                }

                guard self.handleKeyEvent(17, modifiers: .command),
                      self.contentMode == .todo,
                      self.panelTitle == "Todo"
                else {
                    throw SmokeError("Expected Command-T to open the local todo view from Create.")
                }
                try await Task.sleep(for: .milliseconds(380))

                guard !self.todoComposerIsFocused else {
                    throw SmokeError("Expected Todo to open with a genuine idle composer state.")
                }
                let todoInputIdleURL = try self.capturePNG(named: "iagent-todo-input-idle.png")
                let focusRequest = self.todoComposerFocusRequest
                guard self.handleKeyEvent(14, modifiers: .command),
                      self.todoComposerFocusRequest == focusRequest + 1
                else {
                    throw SmokeError("Expected Command-E to focus the Todo composer.")
                }
                try await Task.sleep(for: .milliseconds(130))
                guard self.todoComposerIsFocused else {
                    throw SmokeError("Expected the Todo composer to become first responder.")
                }
                let todoInputFocusMorphURL = try self.capturePNG(
                    named: "iagent-todo-input-focus-morph.png"
                )
                try await Task.sleep(for: .milliseconds(80))
                let todoInputFocusedURL = try self.capturePNG(named: "iagent-todo-input-focused.png")

                self.todos = [
                    LocalTodo(
                        id: UUID(),
                        title: "Write the next implementation prompt",
                        isCompleted: false,
                        listName: "Work",
                        createdAt: Date().addingTimeInterval(-120)
                    ),
                    LocalTodo(
                        id: UUID(),
                        title: "Archive the finished task",
                        isCompleted: false,
                        createdAt: Date().addingTimeInterval(-240)
                    ),
                ]
                self.rememberTodoList("Work")
                self.saveTodos()

                self.todoDraft = "Review the active Codex tasks"
                _ = withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.22)) {
                    self.addTodo()
                }
                try await Task.sleep(for: .milliseconds(80))
                guard self.todos.first?.title == "Review the active Codex tasks",
                      self.todoDraft.isEmpty
                else {
                    throw SmokeError("Expected the submitted todo to insert at the top as one list transition.")
                }
                let todoAddTransitionURL = try self.capturePNG(named: "iagent-todo-add-transition.png")
                try await Task.sleep(for: .milliseconds(300))
                let todoAddSettledURL = try self.capturePNG(named: "iagent-todo-add-settled.png")

                guard self.todos.count == 3, self.openTodoCount == 3 else {
                    throw SmokeError("Expected the todo view to add three local tasks.")
                }
                self.toggleTodo(self.todos[1].id)
                self.toggleTodoStar(self.todos[1].id)
                self.setTodoDueDate(self.todos[1].id, dueDate: Date())
                self.toggleTodoStar(self.todos[0].id)
                self.setTodoDueDate(
                    self.todos[2].id,
                    dueDate: Date()
                )
                self.setTodoList(self.todos[2].id, listName: "Personal")
                try await Task.sleep(for: .milliseconds(82))
                guard self.completingTodoIDs.contains(self.todos[1].id),
                      !self.fadingTodoIDs.contains(self.todos[1].id),
                      self.todos[1].completedAt != nil,
                      self.todos[2].dueDate != nil,
                      self.todos[2].listName == "Personal",
                      self.todoListNames == ["Personal", "Work"],
                      try self.todoStore.loadListNames() == ["Personal", "Work"]
                else {
                    throw SmokeError("Expected todo completion, due-date, and list metadata to persist.")
                }
                let todoPinchURL = try self.capturePNG(named: "iagent-todo-checkbox-pinch.png")

                try await Task.sleep(for: .milliseconds(208))
                let todoReleaseURL = try self.capturePNG(named: "iagent-todo-checkbox-release.png")

                try await Task.sleep(for: .milliseconds(58))
                let todoPullURL = try self.capturePNG(named: "iagent-todo-checkbox-pull.png")

                try await Task.sleep(for: .milliseconds(152))
                let todoStrikeURL = try self.capturePNG(named: "iagent-todo-checkbox-strike.png")

                for _ in 0 ..< 150 where !self.fadingTodoIDs.contains(self.todos[1].id) {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard self.fadingTodoIDs.contains(self.todos[1].id) else {
                    throw SmokeError("Expected the completed todo to enter its delayed fade phase.")
                }
                let todoFadeURL = try self.capturePNG(named: "iagent-todo-completion-fade.png")

                try await Task.sleep(for: .milliseconds(420))
                guard !self.completingTodoIDs.contains(self.todos[1].id),
                      self.visibleTodos.count == 2
                else {
                    throw SmokeError("Expected the completed todo to leave the active list after fading.")
                }
                let todoFrame = window.frame
                guard self.openTodoCount == 2,
                      self.priorityTodos.count == 2,
                      try self.todoStore.load() == self.todos,
                      abs(todoFrame.height - self.expandedSize.height) <= 2,
                      todoFrame.height < expandedFrame.height,
                      abs(todoFrame.maxY - screenFrame.maxY) <= 2
                else {
                    throw SmokeError("Expected todos to persist in a compact, top-pinned view.")
                }
                let todoURL = try self.capturePNG(named: "iagent-todo-list.png")

                self.toggleTodoHistory()
                try await Task.sleep(for: .milliseconds(380))
                guard self.showingPastTodos,
                      self.panelTitle == "Past todos",
                      self.pastTodos.count == 1,
                      self.pastTodos[0].title == "Write the next implementation prompt"
                else {
                    throw SmokeError("Expected completed todos to appear in the Past todos view.")
                }
                let todoHistoryURL = try self.capturePNG(named: "iagent-todo-history.png")

                self.toggleTodoHistory()
                try await Task.sleep(for: .milliseconds(300))
                guard !self.showingPastTodos, self.panelTitle == "Todo" else {
                    throw SmokeError("Expected the history control to restore the open todo list.")
                }

                let homeResizeGeneration = self.frameAnimationGeneration
                self.showHome()
                self.resizeExpandedPanel()
                self.resizeExpandedPanel()
                guard self.frameAnimationGeneration == homeResizeGeneration + 1 else {
                    throw SmokeError("Repeated Home resize requests restarted the active frame transition.")
                }
                try await Task.sleep(for: .milliseconds(180))
                let homeMountURL = try self.capturePNG(named: "iagent-home-mount-motion.png")
                try await Task.sleep(for: .milliseconds(200))
                let homeFrame = window.frame
                guard self.contentMode == .home,
                      self.panelTitle == self.homeTitle,
                      self.calendarService.accessState == .granted,
                      self.calendarService.events.count == 3,
                      self.activeCount > 0,
                      self.openTodoCount == 2,
                      abs(homeFrame.height - self.expandedSize.height) <= 2,
                      homeFrame.height == PanelMetrics.homeExpandedHeight,
                      abs(homeFrame.maxY - screenFrame.maxY) <= 2
                else {
                    throw SmokeError("Expected Home to consolidate Calendar, live Codex, and open todos.")
                }
                let homeURL = try self.capturePNG(named: "iagent-home-dashboard.png")

                self.selectedHomeSection = .calendar
                guard self.handleKeyCode(125), self.selectedHomeSection == .codex,
                      self.handleKeyCode(126), self.selectedHomeSection == .calendar,
                      self.handleKeyCode(36), self.contentMode == .calendar
                else {
                    throw SmokeError("Expected arrow keys and Enter to navigate Home sections.")
                }

                try await Task.sleep(for: .milliseconds(380))
                let calendarFrame = window.frame
                guard self.panelTitle == "Calendar",
                      self.calendarService.events.map(\.title) == [
                          "Product planning",
                          "Design review",
                          "Dinner with Maya",
                      ],
                      self.calendarService.events.first?.linkURLs.first?.host
                          == "meet.example.com",
                      abs(calendarFrame.height - self.expandedSize.height) <= 2,
                      calendarFrame.height > homeFrame.height,
                      abs(calendarFrame.maxY - screenFrame.maxY) <= 2
                else {
                    throw SmokeError("Expected a compact, chronological view of today’s Calendar events.")
                }
                let calendarURL = try self.capturePNG(named: "iagent-calendar-today.png")

                guard self.handleKeyCode(53), self.contentMode == .home else {
                    throw SmokeError("Expected Escape to return from Calendar to Home.")
                }

                self.chooseCreationOption(.focusSession)
                try await Task.sleep(for: .milliseconds(380))
                let focusFrame = window.frame
                guard self.contentMode == .focus,
                      self.panelTitle == "New focus session",
                      abs(focusFrame.height - self.expandedSize.height) <= 2,
                      focusFrame.height <= 194,
                      abs(focusFrame.maxY - screenFrame.maxY) <= 2
                else {
                    throw SmokeError("Expected a compact, top-pinned focus session. frame=\(focusFrame)")
                }
                let focusURL = try self.capturePNG(named: "iagent-focus-session.png")

                self.selectFocusPreset(.extended)
                guard self.focusRemaining == 50 * 60,
                      self.focusPreset.breakMinutes == 10
                else {
                    throw SmokeError("Expected the extended focus strategy to use a 50/10 interval.")
                }
                self.selectFocusPreset(.pomodoro)
                let startingFocusTime = self.focusRemaining
                self.toggleFocusSession()
                try await Task.sleep(for: .milliseconds(1080))
                guard self.focusIsRunning, self.focusRemaining < startingFocusTime else {
                    throw SmokeError("Expected the focus countdown to advance while running.")
                }
                let numberFlowURL = try self.capturePNG(named: "iagent-number-flow-focus.png")
                self.toggleFocusSession()
                guard !self.focusIsRunning else {
                    throw SmokeError("Expected the focus countdown to pause cleanly.")
                }

                self.showThreads()
                try await Task.sleep(for: .milliseconds(380))
                guard let target = self.orderedThreads.first else {
                    throw SmokeError("Expected a task for inline dictation preview.")
                }
                self.selectedThreadID = target.id
                self.dictationTargetThreadID = target.id
                let dictationPreview = "Use the current project context and turn the latest findings into a concise implementation plan that we can review tomorrow morning."
                self.dictation.startPreview(
                    transcript: dictationPreview,
                    speechActive: true
                )
                try await Task.sleep(for: .milliseconds(220))

                let inlineURL = try self.capturePNG(named: "iagent-inline-dictation.png")
                guard self.dictation.isRecording,
                      !self.dictation.isReadyToSubmit,
                      self.dictationTargetThreadID == target.id
                else {
                    throw SmokeError("Expected active inline dictation with a live waveform.")
                }

                self.dictation.setPreviewSpeechActive(false)
                try await Task.sleep(for: .milliseconds(260))
                let inlineIdleURL = try self.capturePNG(named: "iagent-inline-dictation-idle.png")
                guard self.dictation.isRecording,
                      !self.dictation.isReadyToSubmit,
                      self.dictationTargetThreadID == target.id,
                      self.handleKeyCode(53),
                      !self.dictation.isRecording,
                      self.dictationTargetThreadID == nil
                else {
                    throw SmokeError("Expected Escape to cancel paused targeted dictation without collapsing.")
                }

                self.setCompact(source: "smoke-option-n-setup", animated: false)
                self.editorTitle = "Stale draft"
                self.editorBody = "This must be cleared by the direct note route."
                self.lastSavedDocument = nil
                self.openNewNote(source: "option-n")
                try await Task.sleep(for: .milliseconds(380))
                let noteFrame = window.frame
                guard self.contentMode == .note,
                      self.panelTitle == "New note",
                      self.editorTitle.isEmpty,
                      self.editorBody.isEmpty,
                      self.lastSavedDocument == nil,
                      self.lastOpenSource == "option-n",
                      abs(noteFrame.height - self.expandedSize.height) <= 2,
                      noteFrame.height < expandedFrame.height,
                      abs(noteFrame.maxY - screenFrame.maxY) <= 2
                else {
                    throw SmokeError("Expected Option-N to open a clean, content-fitted note editor. frame=\(noteFrame)")
                }
                guard let contentView = window.contentView,
                      let noteTextView = self.markdownEditorTextView(in: contentView),
                      window.firstResponder === noteTextView,
                      !self.handleKeyEvent(UInt16(kVK_ANSI_N), modifiers: [])
                else {
                    throw SmokeError("Expected the Markdown body to receive focus while normal editor keystrokes pass through.")
                }
                let noteEditorURL = try self.capturePNG(named: "iagent-note-editor.png")

                noteTextView.insertText(
                    "Formatting",
                    replacementRange: NSRange(location: 0, length: 0)
                )
                noteTextView.setSelectedRange(NSRange(location: 0, length: 10))
                NoteEditorFormatting.applyBold()
                try await Task.sleep(for: .milliseconds(180))
                guard self.editorBody == "**Formatting**",
                      noteTextView.selectedRange() == NSRange(location: 2, length: 10),
                      self.noteMarkerIsHidden(at: 0, in: noteTextView),
                      self.noteMarkerIsHidden(at: 12, in: noteTextView),
                      let boldStorage = noteTextView.textStorage,
                      let boldFont = boldStorage.attribute(
                        .font,
                        at: 2,
                        effectiveRange: nil
                      ) as? NSFont,
                      boldFont.fontDescriptor.symbolicTraits.contains(.bold)
                else {
                    throw SmokeError("Expected bold to remain visual while its Markdown source markers stay hidden. body=\(self.editorBody)")
                }
                try await Task.sleep(for: .milliseconds(180))
                guard self.noteSaveState == .saving else {
                    throw SmokeError("Expected formatting changes to expose the compact saving indicator.")
                }
                let noteToolbarURL = try self.capturePNG(named: "iagent-note-toolbar.png")

                self.editorBody = "1 < 2"
                try await Task.sleep(for: .milliseconds(140))
                noteTextView.setSelectedRange(NSRange(location: 0, length: 5))
                NoteEditorFormatting.applyUnderline()
                try await Task.sleep(for: .milliseconds(180))
                guard self.editorBody == "<u>1 < 2</u>",
                      self.noteMarkerIsHidden(at: 0, in: noteTextView),
                      self.noteMarkerIsHidden(at: 8, in: noteTextView),
                      let underlineStorage = noteTextView.textStorage,
                      underlineStorage.attribute(
                        .underlineStyle,
                        at: 3,
                        effectiveRange: nil
                      ) != nil
                else {
                    throw SmokeError("Expected underline to render visually while preserving hidden HTML-compatible source.")
                }

                self.editorBody = "First\nSecond"
                try await Task.sleep(for: .milliseconds(140))
                noteTextView.setSelectedRange(NSRange(location: 0, length: 12))
                NoteEditorFormatting.applyUnderline()
                try await Task.sleep(for: .milliseconds(180))
                guard self.editorBody == "<u>First</u>\n<u>Second</u>",
                      self.noteMarkerIsHidden(at: 0, in: noteTextView),
                      self.noteMarkerIsHidden(at: 13, in: noteTextView),
                      let multilineStorage = noteTextView.textStorage,
                      multilineStorage.attribute(
                        .underlineStyle,
                        at: 3,
                        effectiveRange: nil
                      ) != nil,
                      multilineStorage.attribute(
                        .underlineStyle,
                        at: 16,
                        effectiveRange: nil
                      ) != nil
                else {
                    throw SmokeError("Expected multiline underline to render each physical line without literal tags.")
                }

                self.editorBody = ""
                try await Task.sleep(for: .milliseconds(140))
                noteTextView.setSelectedRange(NSRange(location: 0, length: 0))
                NoteEditorFormatting.applyBold()
                try await Task.sleep(for: .milliseconds(40))
                guard self.editorBody.isEmpty, noteTextView.string.isEmpty else {
                    throw SmokeError("Expected an empty-caret style to arm invisibly without inserting raw markers.")
                }
                noteTextView.insertText(
                    "Fresh",
                    replacementRange: NSRange(location: 0, length: 0)
                )
                try await Task.sleep(for: .milliseconds(180))
                guard self.editorBody == "**Fresh**",
                      noteTextView.selectedRange() == NSRange(location: 7, length: 0),
                      self.noteMarkerIsHidden(at: 0, in: noteTextView),
                      self.noteMarkerIsHidden(at: 7, in: noteTextView)
                else {
                    throw SmokeError("Expected the first typed text to inherit an armed visual style with hidden source.")
                }

                self.editorBody = "Task"
                try await Task.sleep(for: .milliseconds(140))
                noteTextView.setSelectedRange(NSRange(location: 0, length: 4))
                NoteEditorFormatting.applyTaskList()
                try await Task.sleep(for: .milliseconds(180))
                guard self.editorBody == "- [ ] Task",
                      noteTextView.selectedRange() == NSRange(location: 6, length: 4),
                      self.noteMarkerIsHidden(at: 2, in: noteTextView),
                      let checklistStorage = noteTextView.textStorage,
                      checklistStorage.attribute(
                        .taskCheckbox,
                        at: 2,
                        effectiveRange: nil
                      ) != nil
                else {
                    throw SmokeError("Expected the checklist control to create a visual unchecked task row.")
                }

                let mixedChecklist = "1. [ ] Ordered\n\nPlain\nNext"
                self.editorBody = mixedChecklist
                try await Task.sleep(for: .milliseconds(140))
                let nextLine = (mixedChecklist as NSString).range(of: "Next")
                noteTextView.setSelectedRange(NSRange(location: 0, length: nextLine.location))
                NoteEditorFormatting.applyTaskList()
                try await Task.sleep(for: .milliseconds(180))
                guard self.editorBody == "1. [ ] Ordered\n\n- [ ] Plain\nNext",
                      noteTextView.selectedRange() == NSRange(
                        location: 0,
                        length: nextLine.location + 6
                      )
                else {
                    throw SmokeError("Expected mixed checklist conversion to preserve ordered tasks, blank separators, selection, and the exclusive next line.")
                }

                self.editorBody = """
                ## Project note

                A **focused** Markdown editor with <u>live formatting</u>.

                - [ ] Capture the next step
                - [x] Keep it local
                """
                for _ in 0 ..< 30 where self.noteSaveState != .saving {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard self.noteSaveState == .saving else {
                    throw SmokeError("Expected a dirty note to show its compact saving state.")
                }
                for _ in 0 ..< 100 where self.noteSaveState != .saved {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let autosaved = self.lastSavedDocument,
                      FileManager.default.fileExists(atPath: autosaved.fileURL.path),
                      self.editorTitle == "Project note",
                      autosaved.body == self.editorBody,
                      self.noteSaveState == .saved,
                      self.handleKeyEvent(UInt16(kVK_ANSI_F), modifiers: [.command]),
                      self.noteFindVisible
                else {
                    throw SmokeError("Expected Markdown edits to move from saving to saved and Command-F to open find and replace.")
                }
                self.noteFindVisible = false
                self.requestNoteEditorFocus()
                try await Task.sleep(for: .milliseconds(250))

                let focusedToken = (self.editorBody as NSString).range(of: "**focused**")
                let underlineOpen = (self.editorBody as NSString).range(of: "<u>")
                let underlineText = (self.editorBody as NSString).range(of: "live formatting")
                let uncheckedTask = (self.editorBody as NSString).range(of: "[ ]")
                let checkedTask = (self.editorBody as NSString).range(of: "[x]")
                guard focusedToken.location != NSNotFound,
                      underlineOpen.location != NSNotFound,
                      underlineText.location != NSNotFound,
                      uncheckedTask.location != NSNotFound,
                      checkedTask.location != NSNotFound,
                      let sampleStorage = noteTextView.textStorage,
                      self.noteMarkerIsHidden(at: 0, in: noteTextView),
                      self.noteMarkerIsHidden(at: underlineOpen.location, in: noteTextView),
                      self.noteMarkerIsHidden(at: uncheckedTask.location, in: noteTextView),
                      sampleStorage.attribute(
                        .underlineStyle,
                        at: underlineText.location,
                        effectiveRange: nil
                      ) != nil,
                      sampleStorage.attribute(
                        .taskCheckbox,
                        at: uncheckedTask.location,
                        effectiveRange: nil
                      ) != nil,
                      sampleStorage.attribute(
                        .taskCheckbox,
                        at: checkedTask.location,
                        effectiveRange: nil
                      ) != nil
                else {
                    throw SmokeError("Expected the saved sample to retain visual heading, underline, and checklist styling over hidden source.")
                }
                noteTextView.setSelectedRange(NSRange(
                    location: focusedToken.location + 2,
                    length: 7
                ))
                try await Task.sleep(for: .milliseconds(160))
                guard self.noteMarkerIsHidden(at: focusedToken.location, in: noteTextView),
                      self.noteMarkerIsHidden(at: focusedToken.location + 9, in: noteTextView)
                else {
                    throw SmokeError("Expected Markdown markers to remain hidden around an active formatted selection.")
                }
                let markdownEditorURL = try self.capturePNG(named: "iagent-note-markdown.png")

                self.dictation.startPreview(
                    transcript: "Capture the idea while it is fresh and save it with the project notes."
                )
                try await Task.sleep(for: .milliseconds(160))
                let noteURL = try self.capturePNG(named: "iagent-note-dictation.png")

                self.dictation.cancel()
                self.openNewNote(source: "smoke-note-save")
                try await Task.sleep(for: .milliseconds(120))
                self.editorTitle = "Smoke note"
                self.editorBody = "Local Markdown storage check."
                self.saveCurrentDocument()
                guard let saved = self.lastSavedDocument,
                      FileManager.default.fileExists(atPath: saved.fileURL.path),
                      saved.fileURL.path.hasPrefix("/private/tmp/iagent-smoke-library"),
                      try String(contentsOf: saved.fileURL, encoding: .utf8)
                        == "# Smoke note\n\nLocal Markdown storage check.\n"
                else {
                    throw SmokeError("Expected exact Markdown round-tripping in the isolated smoke library.")
                }

                self.showThreads()
                try await Task.sleep(for: .milliseconds(380))
                let restoredThreadFrame = window.frame
                guard self.contentMode == .threads,
                      self.panelTitle == "Codex",
                      abs(restoredThreadFrame.height - self.expandedSize.height) <= 2,
                      abs(restoredThreadFrame.maxY - screenFrame.maxY) <= 2
                else {
                    throw SmokeError("Expected the task list to restore its content-fitted Codex frame. frame=\(restoredThreadFrame)")
                }

                let originalThreads = self.threads
                guard let metadataPreviewThread = originalThreads.first(where: { $0.modes.contains(.plan) })
                    ?? originalThreads.first(where: { !$0.modes.isEmpty })
                    ?? originalThreads.first
                else {
                    throw SmokeError("Expected a task for the project-row metadata preview.")
                }

                self.refreshTimer?.invalidate()
                self.refreshTimer = nil
                self.refreshDebounceTask?.cancel()
                self.refreshDebounceTask = nil
                self.fileMonitor.stop()
                self.threads = [metadataPreviewThread]

                guard let previewSection = self.projectSections.first(where: { !$0.threads.isEmpty }) else {
                    throw SmokeError("Expected a populated project section for the metadata preview.")
                }
                let previewWasCollapsed = self.collapsedProjectIDs.contains(previewSection.id)
                if previewWasCollapsed {
                    self.toggleProjectSection(previewSection.id)
                }
                self.selectedThreadID = previewSection.threads.first?.id

                guard self.collapseProjectSectionForDrag(previewSection.id),
                      self.collapsedProjectIDs.contains(previewSection.id),
                      self.selectedThreadID == nil,
                      self.projectPreferences.loadCollapsedIDs().contains(previewSection.id)
                else {
                    throw SmokeError("Expected drag lift to close and persist an expanded project before reordering.")
                }
                self.toggleProjectSection(previewSection.id)
                self.selectedThreadID = previewSection.threads.first?.id
                self.resizeExpandedPanel(animated: false)
                try await Task.sleep(for: .milliseconds(260))
                let projectRowsURL = try self.capturePNG(named: "iagent-project-rows.png")

                self.threads = originalThreads
                if previewWasCollapsed {
                    self.toggleProjectSection(previewSection.id)
                }
                self.resizeExpandedPanel(animated: false)

                guard self.handleKeyCode(53), self.contentMode == .home else {
                    throw SmokeError("Expected Escape to return from Codex to Home.")
                }
                try await Task.sleep(for: .milliseconds(380))
                let restoredHomeFrame = window.frame
                guard abs(restoredHomeFrame.height - PanelMetrics.homeExpandedHeight) <= 2,
                      abs(restoredHomeFrame.maxY - screenFrame.maxY) <= 2
                else {
                    throw SmokeError("Expected Escape from Codex to restore the Home view.")
                }

                self.showCalendar()
                self.calendarService.prepareMeetingPreview()
                guard let armedMeeting = self.recordableMeetingEvent,
                      self.compactCalendarEvent?.id == armedMeeting.id,
                      armedMeeting.title == "Roadmap sync",
                      armedMeeting.linkURLs.first?.host == "meet.example.com",
                      armedMeeting.isHappening(at: self.calendarService.referenceNow)
                else {
                    throw SmokeError("Expected the current meeting to expose its recording control.")
                }

                try await Task.sleep(for: .milliseconds(380))
                guard self.contentMode == .calendar,
                      self.calendarService.events.first?.id == armedMeeting.id
                else {
                    throw SmokeError("Expected the active meeting to remain visible in Calendar.")
                }
                let calendarRecordingURL = try self.capturePNG(
                    named: "iagent-calendar-recordable-meeting.png"
                )

                self.showHome()
                let preservedCompactMode = self.contentMode
                self.handleOutsideClick()

                try await Task.sleep(for: .milliseconds(140))
                let frame = window.frame
                guard frame.width > PanelMetrics.compactSize.width + 2,
                      frame.width < PanelMetrics.expandedWidth - 2,
                      frame.height > PanelMetrics.compactSize.height,
                      frame.height < restoredHomeFrame.height - 16,
                      self.expanded,
                      !self.compactVisible,
                      abs(frame.maxY - screenFrame.maxY) <= 0.01,
                      (window.contentView as? PanelHostingView)?.renderedContourHasTopRamps() == true
                else {
                    throw SmokeError("Compact animation lost its pinned frame or rendered ramps: \(frame).")
                }
                _ = try? self.capturePNG(named: "iagent-native-panel-closing.png")

                try await Task.sleep(for: .milliseconds(340))
                let finalFrame = window.frame
                guard !self.expanded,
                      self.compactVisible,
                      self.contentMode == preservedCompactMode,
                      abs(finalFrame.width - PanelMetrics.compactSize.width) <= 2,
                      abs(finalFrame.height - PanelMetrics.compactSize.height) <= 2,
                      abs(finalFrame.maxY - screenFrame.maxY) <= 0.01,
                      self.calendarService.events.count == 3,
                      self.activeCount > 0,
                      self.openTodoCount == 2
                else {
                    throw SmokeError("Outside click did not settle into the live compact status header: \(finalFrame).")
                }
                let compactURL = try self.capturePNG(named: "iagent-compact-status.png")

                self.meetingCapture.startFailurePreview(
                    event: armedMeeting,
                    message: "Screen & System Audio Recording permission is required in System Settings."
                )
                try await Task.sleep(for: .milliseconds(120))
                guard self.meetingCapture.hasCompactStatus,
                      !self.meetingCapture.isActive,
                      !self.expanded,
                      self.compactVisible
                else {
                    throw SmokeError("Expected a dismissible compact meeting error.")
                }
                let meetingErrorURL = try self.capturePNG(named: "iagent-meeting-error.png")
                self.dismissMeetingCaptureFailure()
                guard !self.meetingCapture.hasCompactStatus,
                      self.meetingCapture.state == .idle
                else {
                    throw SmokeError("Expected the red meeting control to dismiss the failed state.")
                }

                try self.meetingCapture.startPreview(event: armedMeeting)
                try await Task.sleep(for: .milliseconds(120))
                guard self.meetingCapture.isListening,
                      self.meetingCapture.currentEvent?.id == armedMeeting.id,
                      !self.meetingCapture.latestTranscript.isEmpty,
                      self.meetingCapture.currentNote?.fileURL.path.hasPrefix(
                          "/private/tmp/iagent-smoke-library"
                      ) == true,
                      !self.expanded,
                      self.compactVisible
                else {
                    throw SmokeError("Expected compact meeting capture with a live transcript and local note.")
                }
                let meetingListeningURL = try self.capturePNG(
                    named: "iagent-meeting-listening.png"
                )

                self.stopMeetingCapture()
                for _ in 0 ..< 40
                    where self.contentMode != .note || !self.expanded
                {
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard self.contentMode == .note,
                      self.expanded,
                      !self.meetingCapture.isActive,
                      let meetingNote = self.lastSavedDocument,
                      meetingNote.title == "Roadmap sync",
                      meetingNote.body.contains("## Transcript"),
                      meetingNote.body.contains("revised milestones"),
                      FileManager.default.fileExists(atPath: meetingNote.fileURL.path)
                else {
                    throw SmokeError("Expected stopping capture to open the completed local meeting note.")
                }
                try await Task.sleep(for: .milliseconds(340))
                let meetingNoteURL = try self.capturePNG(named: "iagent-meeting-note.png")

                self.showHome()
                self.setCompact(source: "smoke-meeting-reset", animated: false)

                self.openFromCompactSurface()
                try await Task.sleep(for: .milliseconds(100))
                let openingFrame = window.frame
                guard self.expanded,
                      !self.compactVisible,
                      openingFrame.width > PanelMetrics.compactSize.width + 2,
                      openingFrame.width < PanelMetrics.expandedWidth - 2,
                      openingFrame.height > PanelMetrics.compactSize.height,
                      openingFrame.height < self.expandedSize.height,
                      abs(openingFrame.maxY - screenFrame.maxY) <= 0.01,
                      (window.contentView as? PanelHostingView)?.renderedContourHasTopRamps() == true
                else {
                    throw SmokeError("Expanded transition did not preserve its intermediate frame and rendered ramps.")
                }
                let openingURL = try self.capturePNG(named: "iagent-native-panel-opening.png")

                try await Task.sleep(for: .milliseconds(380))
                guard self.expanded,
                      !self.compactVisible,
                      self.contentMode == preservedCompactMode,
                      self.lastOpenSource == "compact-surface",
                      abs(window.frame.height - self.expandedSize.height) <= 2
                else {
                    throw SmokeError("Expected the compact surface to restore the preserved view.")
                }

                self.setCompact(source: "smoke-calendar-time-setup", animated: false)
                self.openCalendarFromCompactTime()
                try await Task.sleep(for: .milliseconds(480))
                guard self.expanded,
                      self.contentMode == .calendar,
                      self.panelTitle == "Calendar",
                      self.lastOpenSource == "compact-calendar-time",
                      abs(window.frame.height - self.expandedSize.height) <= 2
                else {
                    throw SmokeError("Expected the compact event time to open Calendar.")
                }
                self.setExpanded(false, source: "smoke-finish", animated: false)

                print("[smoke] nativeNotch=\(Int(collapsedFrame.width))x\(Int(collapsedFrame.height)) top=\(Int(collapsedFrame.maxY))")
                print("[smoke] nativeExpanded=\(Int(expandedFrame.width))x\(Int(expandedFrame.height)) top=\(Int(expandedFrame.maxY)) source=\(self.lastOpenSource) wheelEvent=\(wheelEventReachedHandler)")
                print("[smoke] dynamicHeights=threads:\(Int(restoredThreadFrame.height)) home:\(Int(homeFrame.height)) calendar:\(Int(calendarFrame.height)) create:\(Int(createFrame.height)) todo:\(Int(todoFrame.height)) focus:\(Int(focusFrame.height)) note:\(Int(noteFrame.height))")
                print("[smoke] realRootThreads=\(self.threads.count) activity24h=\(self.activityThreads.count) projects=\(self.projectSections.count) running=\(self.activeCount) keyboard=up/down/enter/escape database=\(self.databasePath)")
                print("[smoke] pauseTranscript=\(accumulatedSpeech.text)")
                print("[smoke] localNote=\(saved.fileURL.path)")
                print("[smoke] collapsedScreenshot=\(collapsedURL.path)")
                print("[smoke] compactScreenshot=\(compactURL.path)")
                print("[smoke] meetingErrorScreenshot=\(meetingErrorURL.path)")
                print("[smoke] meetingListeningScreenshot=\(meetingListeningURL.path)")
                print("[smoke] meetingNoteScreenshot=\(meetingNoteURL.path)")
                print("[smoke] openingScreenshot=\(openingURL.path)")
                print("[smoke] expandedScreenshot=\(expandedURL.path)")
                print("[smoke] projectRowsScreenshot=\(projectRowsURL.path)")
                print("[smoke] dynamicResizeScreenshot=\(dynamicResizeURL.path)")
                print("[smoke] createScreenshot=\(createURL.path)")
                print("[smoke] standaloneMeetingScreenshot=\(standaloneMeetingURL.path)")
                print("[smoke] createBottomScreenshot=\(createBottomURL.path)")
                print("[smoke] todoInputIdleScreenshot=\(todoInputIdleURL.path)")
                print("[smoke] todoInputFocusMorphScreenshot=\(todoInputFocusMorphURL.path)")
                print("[smoke] todoInputFocusedScreenshot=\(todoInputFocusedURL.path)")
                print("[smoke] todoAddTransitionScreenshot=\(todoAddTransitionURL.path)")
                print("[smoke] todoAddSettledScreenshot=\(todoAddSettledURL.path)")
                print("[smoke] todoPinchScreenshot=\(todoPinchURL.path)")
                print("[smoke] todoReleaseScreenshot=\(todoReleaseURL.path)")
                print("[smoke] todoPullScreenshot=\(todoPullURL.path)")
                print("[smoke] todoStrikeScreenshot=\(todoStrikeURL.path)")
                print("[smoke] todoFadeScreenshot=\(todoFadeURL.path)")
                print("[smoke] todoScreenshot=\(todoURL.path)")
                print("[smoke] todoHistoryScreenshot=\(todoHistoryURL.path)")
                print("[smoke] homeMountScreenshot=\(homeMountURL.path)")
                print("[smoke] homeScreenshot=\(homeURL.path)")
                print("[smoke] calendarScreenshot=\(calendarURL.path)")
                print("[smoke] calendarRecordingScreenshot=\(calendarRecordingURL.path)")
                print("[smoke] focusScreenshot=\(focusURL.path)")
                print("[smoke] numberFlowScreenshot=\(numberFlowURL.path)")
                print("[smoke] inlineDictationScreenshot=\(inlineURL.path)")
                print("[smoke] inlineIdleScreenshot=\(inlineIdleURL.path)")
                print("[smoke] noteEditorScreenshot=\(noteEditorURL.path)")
                print("[smoke] noteToolbarScreenshot=\(noteToolbarURL.path)")
                print("[smoke] markdownEditorScreenshot=\(markdownEditorURL.path)")
                print("[smoke] noteDictationScreenshot=\(noteURL.path)")
                NSApp.terminate(nil)
            } catch {
                self.failSmoke(String(describing: error))
            }
        }
    }

    func runCalendarLiveTest(attempt: Int = 0) {
        if attempt == 0 {
            showCalendar()
            setExpanded(true, source: "calendar-live-test", animated: false)
            calendarService.refresh(forceReload: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let waitingForCalendar = self.calendarService.accessState == .requesting
                || self.calendarService.supplementalRefreshInFlight
            if waitingForCalendar, attempt < 80 {
                self.runCalendarLiveTest(attempt: attempt + 1)
                return
            }

            do {
                self.resizeExpandedPanel(animated: false)
                let screenshotURL = try self.capturePNG(named: "iagent-calendar-live.png")
                let mappedLines = self.calendarService.events.map { event in
                    let links = event.linkURLs.map(\.absoluteString).joined(separator: ",")
                    return "[calendar-live:mapped] title=\(event.title) "
                        + "calendar=\(event.calendarTitle) links=[\(links)]"
                }
                mappedLines.forEach { print($0) }
                let diagnosticLines = [
                    "[calendar-live] access=\(String(describing: self.calendarService.accessState))",
                    "[calendar-live] supplementalError=\(self.calendarService.supplementalRefreshError ?? "none")",
                ] + self.calendarService.liveDiagnosticLines + mappedLines + [
                    "[calendar-live] screenshot=\(screenshotURL.path)",
                ]
                let diagnosticURL = try self.artifactURL(named: "iagent-calendar-live.log")
                try diagnosticLines.joined(separator: "\n").appending("\n").write(
                    to: diagnosticURL,
                    atomically: true,
                    encoding: .utf8
                )

                guard self.calendarService.accessState == .granted else {
                    throw SmokeError(
                        "Calendar access is \(String(describing: self.calendarService.accessState)). "
                            + "diagnostics=\(diagnosticURL.path)"
                    )
                }

                guard let meeting = self.calendarService.events.first(where: {
                    $0.title.localizedCaseInsensitiveCompare("Meeting") == .orderedSame
                }) else {
                    throw SmokeError("The live Calendar view did not contain the Meeting event.")
                }
                guard !meeting.linkURLs.isEmpty else {
                    throw SmokeError(
                        "Meeting rendered without an open-link URL. screenshot=\(screenshotURL.path)"
                    )
                }

                print("[calendar-live] meetingLink=\(meeting.linkURLs[0].absoluteString)")
                print("[calendar-live] screenshot=\(screenshotURL.path)")
                NSApp.terminate(nil)
            } catch {
                self.failSmoke(String(describing: error))
            }
        }
    }

    private func failSmoke(_ message: String) {
        fputs("Smoke failed: \(message)\n", stderr)
        fflush(stderr)
        exit(1)
    }
}

struct SmokeError: LocalizedError, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    var errorDescription: String? { description }
}

final class SmokeScrollEvent: NSEvent {}

struct PanelView: View {
    @ObservedObject var controller: PanelController

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .allowsHitTesting(false)

            if controller.expanded {
                ExpandedPanel(controller: controller)
            } else if controller.compactVisible {
                CompactPanel(controller: controller)
                    .frame(width: PanelMetrics.compactSize.width, height: PanelMetrics.compactSize.height)
            } else {
                NotchTrigger(controller: controller)
                    .frame(width: PanelMetrics.notchSize.width, height: PanelMetrics.notchSize.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct CompactPanel: View {
    @ObservedObject var controller: PanelController
    @ObservedObject private var calendarService: CalendarEventService
    @ObservedObject private var meetingCapture: MeetingCaptureService

    init(controller: PanelController) {
        self.controller = controller
        _calendarService = ObservedObject(wrappedValue: controller.calendarService)
        _meetingCapture = ObservedObject(wrappedValue: controller.meetingCapture)
    }

    var body: some View {
        ZStack {
            Button {
                controller.openFromCompactSurface()
            } label: {
                Color.black
                    .contentShape(PanelContourShape())
            }
            .buttonStyle(.plain)
            .help("Expand panel")

            if meetingCapture.hasCompactStatus {
                meetingStatus
            } else {
                idleStatus
            }

            CameraDot()
                .frame(width: 11, height: 11)
                .padding(.top, 5)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
        .frame(width: PanelMetrics.compactSize.width, height: PanelMetrics.compactSize.height)
    }

    private var idleStatus: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                compactMetric(
                    count: calendarService.events.count,
                    help: "Today's calendar events",
                    action: {
                        controller.showCalendar()
                        controller.setExpanded(true, source: "compact-calendar")
                    }
                ) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(width: 14, height: 14)
                }

                compactMetric(
                    count: controller.activeCount,
                    help: "Live Codex tasks",
                    action: {
                        controller.showThreads()
                        controller.setExpanded(true, source: "compact-codex")
                    }
                ) {
                    OpenAIBlossomIcon(size: 12, color: .white.opacity(0.76))
                        .frame(width: 14, height: 14)
                }

                compactMetric(
                    count: controller.openTodoCount,
                    help: "Open todos",
                    action: {
                        controller.showTodos()
                        controller.setExpanded(true, source: "compact-todos")
                    }
                ) {
                    Image(systemName: "checkmark.square")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(width: 14, height: 14)
                }
            }

            Spacer(minLength: 20)

            HStack(spacing: 14) {
                if let event = controller.compactCalendarEvent {
                    compactEvent(event)
                }

                HStack(spacing: 0) {
                    Button {
                        controller.showCreationMenu()
                        controller.setExpanded(true, source: "compact-create")
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(HeaderIconButtonStyle(isActive: false))
                    .help("Create")

                    Button {
                        controller.setExpanded(true, source: "compact-expand")
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(HeaderIconButtonStyle(isActive: false))
                    .help("Expand panel")
                }
            }
        }
        .padding(.leading, PanelMetrics.expandedRampWidth + 20)
        .padding(.trailing, PanelMetrics.expandedRampWidth + 10)
        .frame(height: PanelMetrics.compactSize.height)
    }

    private var meetingStatus: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(meetingCapture.isActive ? meetingCapture.latestSource.rawValue.uppercased() : "ERROR")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.34))
                    .frame(width: 36, alignment: .leading)

                LatestTranscriptLine(
                    text: meetingCapture.displayTranscript,
                    isPlaceholder: meetingCapture.latestTranscript.isEmpty
                )
                .frame(maxWidth: .infinity, minHeight: 20)
                .clipped()
            }
            .padding(.leading, PanelMetrics.expandedRampWidth + 20)
            .padding(.trailing, 8)
            .frame(width: compactSideWidth, height: PanelMetrics.compactSize.height)
            .clipped()

            Color.clear
                .frame(width: PanelMetrics.notchSize.width)
                .allowsHitTesting(false)

            HStack(spacing: 8) {
                NumberFlowText(
                    meetingCapture.elapsedText,
                    fontSize: 10,
                    weight: .semibold,
                    color: .white.opacity(0.52),
                    reservedWidth: 42,
                    alignment: .trailing,
                    lineHeight: 14
                )

                WaveformView(levels: meetingCapture.levels, color: .white)
                    .frame(width: 104, height: 18)

                Button {
                    if meetingCapture.isActive {
                        controller.stopMeetingCapture()
                    } else {
                        controller.dismissMeetingCaptureFailure()
                    }
                } label: {
                    Circle()
                        .fill(Color.agentCoral)
                        .frame(width: 8, height: 8)
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.28), lineWidth: 0.5)
                        }
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(HeaderIconButtonStyle(isActive: false))
                .disabled(meetingCapture.state == .stopping)
                .help(meetingCapture.isActive ? "Stop and open meeting note" : "Dismiss recording error")
            }
            .padding(.leading, 8)
            .padding(.trailing, PanelMetrics.expandedRampWidth + 10)
            .frame(width: compactSideWidth, height: PanelMetrics.compactSize.height)
        }
        .frame(width: PanelMetrics.compactSize.width)
        .frame(height: PanelMetrics.compactSize.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            meetingCapture.isActive
                ? "Recording \(meetingCapture.currentEvent?.title ?? "meeting")"
                : "Meeting recording error"
        )
    }

    private var compactSideWidth: CGFloat {
        (PanelMetrics.compactSize.width - PanelMetrics.notchSize.width) / 2
    }

    private func compactEvent(_ event: CalendarEventItem) -> some View {
        HStack(spacing: 3) {
            if !event.isAllDay {
                Button {
                    controller.startMeetingCapture(event)
                } label: {
                    Circle()
                        .fill(Color.agentCoral)
                        .frame(width: 7, height: 7)
                        .frame(width: 12, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Start recording \(event.title)")
                .accessibilityLabel("Start recording \(event.title)")
            }

            Button {
                controller.openCalendarFromCompactTime()
            } label: {
                NumberFlowText(
                    event.timeText(),
                    fontSize: 10,
                    weight: .medium,
                    color: .white.opacity(0.44),
                    reservedWidth: 58,
                    alignment: .leading,
                    lineHeight: 14
                )
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(event.title)
        }
    }

    private func compactMetric<Icon: View>(
        count: Int,
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon()

                NumberFlowText(
                    "\(count)",
                    fontSize: 10,
                    weight: .semibold,
                    color: .white.opacity(0.56),
                    reservedWidth: 14,
                    alignment: .leading,
                    lineHeight: 14
                )
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct NotchTrigger: View {
    @ObservedObject var controller: PanelController

    var body: some View {
        ZStack {
            Color.black

            VStack {
                CameraDot()
                    .frame(width: 11, height: 11)
                    .padding(.top, 7)
                Spacer(minLength: 0)
            }

            ScrollCatcher(
                onWheel: {
                    controller.openFromNotchWheel()
                },
                onHover: { _ in }
            )
        }
        .frame(width: PanelMetrics.notchSize.width, height: PanelMetrics.notchSize.height)
        .contentShape(Rectangle())
        .onTapGesture {
            controller.setExpanded(true, source: "click")
        }
    }
}

struct ExpandedPanel: View {
    @ObservedObject var controller: PanelController
    @State private var threadRowFrames: [String: CGRect] = [:]
    @State private var projectRowFrames: [String: CGRect] = [:]
    @State private var draggedProjectID: String?
    @State private var projectDragLocationY: CGFloat = 0
    @State private var projectDragGrabOffset: CGFloat = 0
    private let threadListCoordinateSpace = "codex-thread-list"

    var body: some View {
        ZStack(alignment: .top) {
            ExpandedPanelBackground()

            VStack(spacing: 0) {
                header

                panelContent
                    .id(controller.contentMode)
                    .transition(.opacity)
            }
            .padding(.leading, PanelMetrics.expandedRampWidth)
            .padding(.trailing, PanelMetrics.expandedRampWidth)
            .opacity(controller.contentVisible ? 1 : 0)
            .animation(
                .timingCurve(0.165, 0.84, 0.44, 1, duration: 0.14),
                value: controller.contentMode
            )

            CameraDot()
                .frame(width: 11, height: 11)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch controller.contentMode {
        case .home:
            HomeDashboardView(controller: controller)
        case .threads:
            if controller.threads.isEmpty {
                emptyState
            } else {
                threadList
            }
        case .create:
            CreationMenuView(controller: controller)
        case .note:
            LocalDocumentEditorView(controller: controller, kind: .note)
        case .newThread:
            NewCodexThreadView(controller: controller)
        case .focus:
            FocusSessionView(controller: controller)
        case .todo:
            TodoListView(controller: controller)
        case .calendar:
            CalendarDayView(controller: controller)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if controller.contentMode != .home {
                Button {
                    controller.returnHome()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(HeaderIconButtonStyle(isActive: false))
                .help("Back to Home")
            }

            Text(controller.panelTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(1)

            Spacer(minLength: 64)

            if controller.contentMode == .threads {
                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.activeCount > 0 ? Color.agentGreen : Color.white.opacity(0.28))
                        .frame(width: 6, height: 6)

                    HStack(spacing: 3) {
                        NumberFlowText(
                            "\(controller.activeCount)",
                            fontSize: 11,
                            color: .white.opacity(0.52),
                            reservedWidth: 16
                        )
                        Text("running")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                }
            }

            if controller.contentMode == .home || controller.contentMode == .threads {
                Button {
                    controller.showCreationMenu()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(HeaderIconButtonStyle(isActive: false))
                .help("Create")
            }

            if controller.contentMode == .todo {
                Button {
                    controller.toggleTodoHistory()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(HeaderIconButtonStyle(isActive: controller.showingPastTodos))
                .help(controller.showingPastTodos ? "Show open todos" : "Show past todos")
            }

            Button {
                controller.setCompact(source: "header-collapse")
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(HeaderIconButtonStyle(isActive: false))
            .help("Collapse panel")
        }
        .padding(.leading, controller.contentMode == .home ? 20 : 6)
        .padding(.trailing, 10)
        .frame(height: PanelMetrics.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
        }
    }

    private var threadList: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !controller.activityThreads.isEmpty {
                            SectionLabel("Active threads")

                            ForEach(controller.activityThreads) { thread in
                                threadRow(thread, placement: .activity)
                            }
                        }

                        ForEach(controller.projectSections) { section in
                            projectSection(section)
                        }
                    }
                    .animation(
                        .timingCurve(0.165, 0.84, 0.44, 1, duration: 0.2),
                        value: controller.projectOrder
                    )
                }
                .coordinateSpace(name: threadListCoordinateSpace)
                .scrollIndicators(.hidden)
                .onPreferenceChange(ThreadRowFramePreferenceKey.self) { frames in
                    threadRowFrames = frames
                }
                .onPreferenceChange(ProjectRowFramePreferenceKey.self) { frames in
                    projectRowFrames = frames
                }
                .onChange(of: controller.keyboardSelectionRevision) { _, _ in
                    revealKeyboardSelection(proxy: proxy, viewportHeight: viewport.size.height)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let message = controller.statusMessage,
               controller.dictationTargetThreadID == nil
            {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle.fill")
                    Text(message)
                        .lineLimit(2)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 11)
                .frame(minHeight: 30)
                .background(Color(red: 0.08, green: 0.085, blue: 0.1), in: RoundedRectangle(cornerRadius: 7))
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func threadRow(
        _ thread: AgentThread,
        placement: ThreadRowPlacement,
        rowID: String? = nil,
        isPrimaryOccurrence: Bool = true
    ) -> some View {
        Group {
            if controller.dictationTargetThreadID == thread.id {
                InlineDictationThreadRow(
                    thread: thread,
                    dictation: controller.dictation,
                    statusMessage: controller.statusMessage,
                    isSubmitting: controller.isSubmitting,
                    isProjectChild: placement == .project
                )
            } else {
                Button {
                    controller.openThread(thread)
                } label: {
                    AgentThreadRow(
                        thread: thread,
                        placement: placement,
                        isSelected: controller.selectedThreadID == thread.id,
                        referenceNow: controller.referenceNow
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    controller.setHoveredThread(thread.id, hovering: hovering)
                }
            }
        }
        .id(rowID ?? thread.id)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ThreadRowFramePreferenceKey.self,
                    value: isPrimaryOccurrence
                        ? [thread.id: geometry.frame(in: .named(threadListCoordinateSpace))]
                        : [:]
                )
            }
        }
    }

    @ViewBuilder
    private func projectSection(_ section: ThreadProjectSection) -> some View {
        let collapsed = controller.collapsedProjectIDs.contains(section.id)
        let isDragging = draggedProjectID == section.id

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ProjectSectionRow(
                    section: section,
                    isCollapsed: collapsed,
                    isDragging: isDragging
                ) {
                    controller.toggleProjectSection(section.id)
                }
                .offset(y: projectDragOffset(for: section.id))
                .scaleEffect(isDragging ? 1.012 : 1)
                .shadow(
                    color: .black.opacity(isDragging ? 0.48 : 0),
                    radius: isDragging ? 12 : 0,
                    y: isDragging ? 7 : 0
                )
                .highPriorityGesture(projectDragGesture(for: section.id))
            }
            .frame(height: 40)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ProjectRowFramePreferenceKey.self,
                        value: [section.id: geometry.frame(in: .named(threadListCoordinateSpace))]
                    )
                }
            }

            if !collapsed {
                ForEach(section.threads) { thread in
                    let isActivityDuplicate = controller.activityThreads.contains { $0.id == thread.id }
                    threadRow(
                        thread,
                        placement: .project,
                        rowID: isActivityDuplicate ? "project:\(section.id):\(thread.id)" : thread.id,
                        isPrimaryOccurrence: !isActivityDuplicate
                    )
                }
            }
        }
        .zIndex(isDragging ? 100 : 0)
    }

    private func projectDragOffset(for projectID: String) -> CGFloat {
        guard draggedProjectID == projectID,
              let frame = projectRowFrames[projectID]
        else {
            return 0
        }
        return projectDragLocationY - projectDragGrabOffset - frame.minY
    }

    private func projectDragGesture(for projectID: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(threadListCoordinateSpace))
            .onChanged { value in
                guard let frame = projectRowFrames[projectID] else { return }

                if draggedProjectID == nil {
                    _ = controller.collapseProjectSectionForDrag(projectID)
                    draggedProjectID = projectID
                    projectDragGrabOffset = min(max(value.startLocation.y - frame.minY, 0), frame.height)
                }
                guard draggedProjectID == projectID else { return }

                projectDragLocationY = value.location.y
                let liftedMidY = value.location.y - projectDragGrabOffset + frame.height / 2
                let visibleOrder = controller.projectSections.map(\.id)
                let insertionIndex = ProjectDragPlacement.insertionIndex(
                    pointerY: liftedMidY,
                    orderedIDs: visibleOrder,
                    frames: projectRowFrames,
                    draggedID: projectID
                )

                withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.2)) {
                    _ = controller.moveProject(projectID, toVisibleIndex: insertionIndex)
                }
            }
            .onEnded { _ in
                withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.2)) {
                    draggedProjectID = nil
                    projectDragLocationY = 0
                    projectDragGrabOffset = 0
                }
            }
    }

    private func revealKeyboardSelection(
        proxy: ScrollViewProxy,
        viewportHeight: CGFloat
    ) {
        guard let selectedThreadID = controller.selectedThreadID else { return }

        let edge: SelectionRevealEdge?
        if let rowFrame = threadRowFrames[selectedThreadID] {
            edge = SelectionRevealEdge.required(
                for: rowFrame,
                viewportHeight: viewportHeight
            )
        } else {
            edge = controller.keyboardSelectionDirection >= 0 ? .bottom : .top
        }

        guard let edge else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(selectedThreadID, anchor: edge == .top ? .top : .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.7))

            Text(controller.loadError ?? "Loading recent Codex threads")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ThreadRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ProjectRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(height: 30)
    }
}

private enum ThreadMetadataMetrics {
    static let iconRailWidth: CGFloat = 80
    static let gap: CGFloat = 12
    static let dividerWidth: CGFloat = 1
    static let timeWidth: CGFloat = 24
}

struct ProjectSectionRow: View {
    let section: ThreadProjectSection
    let isCollapsed: Bool
    let isDragging: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.workspacePath == nil ? "house" : "folder")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 20)

            Text(section.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            if !section.threads.isEmpty {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            }

            Spacer()

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: ThreadMetadataMetrics.iconRailWidth, height: 1)

                Color.clear
                    .frame(width: ThreadMetadataMetrics.gap, height: 1)

                Color.clear
                    .frame(width: ThreadMetadataMetrics.dividerWidth, height: 1)

                Color.clear
                    .frame(width: ThreadMetadataMetrics.gap, height: 1)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(isDragging ? 0.82 : hovering ? 0.55 : 0.34))
                    .frame(width: 18, height: 18)
                    .frame(width: ThreadMetadataMetrics.timeWidth, alignment: .trailing)
                    .help("Drag to reorder project")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 40)
        .background(
            isDragging
                ? Color(red: 0.065, green: 0.067, blue: 0.074)
                : Color.white.opacity(hovering ? 0.035 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
    }
}

enum ThreadRowPlacement: Equatable {
    case activity
    case project
}

struct AgentThreadRow: View {
    let thread: AgentThread
    let placement: ThreadRowPlacement
    let isSelected: Bool
    let referenceNow: Date
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if placement == .activity {
                HStack(spacing: 12) {
                    Text(thread.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let projectName = thread.projectName {
                        Text(projectName)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ThreadTrailingMetadata(thread: thread, referenceNow: referenceNow)
            } else {
                Text(thread.title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                ThreadTrailingMetadata(thread: thread, referenceNow: referenceNow)
            }
        }
        .padding(.leading, placement == .project ? 50 : 20)
        .padding(.trailing, 20)
        .frame(height: 36)
        .background(.white.opacity(isSelected ? 0.065 : (hovering ? 0.035 : 0)))
        .onHover { hovering = $0 }
    }
}

private struct ThreadTrailingMetadata: View {
    let thread: AgentThread
    let referenceNow: Date

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                if !thread.modes.isEmpty {
                    ThreadModeIcons(modes: thread.modes)
                }

                if thread.state != .completed {
                    ThreadStateIcon(state: thread.state)
                        .frame(width: 18)
                }
            }
            .frame(width: ThreadMetadataMetrics.iconRailWidth, alignment: .trailing)

            Spacer().frame(width: ThreadMetadataMetrics.gap)

            Rectangle()
                .fill(.white.opacity(0.13))
                .frame(width: ThreadMetadataMetrics.dividerWidth, height: 14)

            Spacer().frame(width: ThreadMetadataMetrics.gap)

            NumberFlowText(
                thread.updatedRelativeText(referenceDate: referenceNow),
                fontSize: 10,
                color: .white.opacity(thread.state.isActive ? 0.66 : 0.42),
                reservedWidth: ThreadMetadataMetrics.timeWidth
            )
            .help(
                "Updated \(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))"
            )
        }
    }
}

private struct ThreadModeIcons: View {
    let modes: [ThreadMode]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(modes.prefix(2)) { mode in
                Image(systemName: mode.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mode.color)
                    .frame(width: 18, height: 18)
                    .help(mode.rawValue)
            }
        }
    }
}

struct ThreadStateIcon: View {
    let state: AgentState
    @State private var spinning = false

    var body: some View {
        Group {
            switch state {
            case .running:
                Circle()
                    .trim(from: 0.08, to: 0.74)
                    .stroke(state.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(2)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
            case .waitingForInput:
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(state.color)
            case .needsApproval:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(state.color)
            case .completed:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(state.color)
            case .failed:
                Image(systemName: "xmark.circle")
                    .foregroundStyle(state.color)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .frame(width: 16, height: 16)
        .help(state.label)
        .onAppear {
            guard state == .running else { return }
            withAnimation(.linear(duration: 0.78).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

extension ThreadMode {
    var symbol: String {
        switch self {
        case .plan: "lightbulb"
        case .goal: "target"
        case .voice: "waveform"
        }
    }

    var color: Color {
        switch self {
        case .plan: .agentBlue
        case .goal: .agentGreen
        case .voice: .agentAmber
        }
    }
}

struct ExpandedPanelBackground: View {
    var body: some View {
        Color(red: 0.008, green: 0.009, blue: 0.012)
    }
}

struct PanelContourShape: Shape {
    func path(in rect: CGRect) -> Path {
        let widthRange = PanelMetrics.expandedWidth - PanelMetrics.notchSize.width
        let expansion = min(
            1,
            max(0, (rect.width - PanelMetrics.notchSize.width) / widthRange)
        )
        let rampWidth = PanelMetrics.expandedRampWidth
        let rampDepth = min(PanelMetrics.expandedRampDepth, rect.height / 2)
        let bottomRadius = min(
            20 + 4 * expansion,
            rect.width / 2,
            max(0, rect.height - rampDepth)
        )
        let topY = rect.minY - PanelMetrics.topMaskOverscan
        let leftBodyX = rect.minX + rampWidth
        let rightBodyX = rect.maxX - rampWidth
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: topY))
        path.addLine(to: CGPoint(x: rect.maxX, y: topY))

        path.addCurve(
            to: CGPoint(x: rightBodyX, y: rect.minY + rampDepth),
            control1: CGPoint(
                x: rect.maxX - rampWidth * 0.4,
                y: topY
            ),
            control2: CGPoint(
                x: rightBodyX,
                y: rect.minY + rampDepth * 0.4
            )
        )

        path.addLine(to: CGPoint(x: rightBodyX, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rightBodyX - bottomRadius, y: rect.maxY),
            control: CGPoint(x: rightBodyX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: leftBodyX + bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: leftBodyX, y: rect.maxY - bottomRadius),
            control: CGPoint(x: leftBodyX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: leftBodyX, y: rect.minY + rampDepth))

        path.addCurve(
            to: CGPoint(x: rect.minX, y: topY),
            control1: CGPoint(
                x: rect.minX + rampWidth,
                y: rect.minY + rampDepth * 0.4
            ),
            control2: CGPoint(
                x: rect.minX + rampWidth * 0.4,
                y: topY
            )
        )

        path.closeSubpath()
        return path
    }
}

struct CameraDot: View {
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.5, green: 0.63, blue: 0.77).opacity(0.74),
                        Color(red: 0.06, green: 0.09, blue: 0.13),
                        Color.black,
                    ],
                    center: UnitPoint(x: 0.36, y: 0.34),
                    startRadius: 0,
                    endRadius: 7
                )
            )
            .overlay(Circle().stroke(.white.opacity(0.05), lineWidth: 1))
    }
}

struct ScrollCatcher: NSViewRepresentable {
    var onWheel: () -> Void
    var onHover: (Bool) -> Void

    func makeNSView(context _: Context) -> CatcherView {
        let view = CatcherView()
        view.onWheel = onWheel
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: CatcherView, context _: Context) {
        nsView.onWheel = onWheel
        nsView.onHover = onHover
    }

    final class CatcherView: NSView {
        var onWheel: (() -> Void)?
        var onHover: ((Bool) -> Void)?

        override var acceptsFirstResponder: Bool { true }

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

        override func scrollWheel(with _: NSEvent) {
            onWheel?()
        }

        override func mouseDown(with _: NSEvent) {
            onWheel?()
        }

        override func mouseEntered(with _: NSEvent) {
            onHover?(true)
        }

        override func mouseExited(with _: NSEvent) {
            onHover?(false)
        }
    }
}

extension Color {
    static let agentGreen = Color(red: 0.365, green: 0.886, blue: 0.624)
    static let agentAmber = Color(red: 0.941, green: 0.78, blue: 0.4)
    static let agentBlue = Color(red: 0.416, green: 0.718, blue: 1.0)
    static let agentCoral = Color(red: 1.0, green: 0.35, blue: 0.28)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = PanelController()
    private var screenObserver: NSObjectProtocol?
    private var globalNotchMonitor: Any?
    private var keyboardMonitor: Any?
    private var panelHotKey: GlobalHotKey?
    private var dictationHotKey: GlobalHotKey?
    private var newNoteHotKey: GlobalHotKey?
    private var visibilityHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_: Notification) {
        let isSmokeTest = CommandLine.arguments.contains("--smoke-test")
        let isCalendarLiveTest = CommandLine.arguments.contains("--calendar-live-test")
        NSApp.setActivationPolicy(isCalendarLiveTest ? .regular : .accessory)
        if isCalendarLiveTest {
            NSApp.activate(ignoringOtherApps: true)
        }

        let panel = PanelWindow(
            contentRect: controller.targetFrame(expanded: false),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none

        let hostingView = PanelHostingView(
            rootView: AnyView(
                PanelView(controller: controller).environment(\.colorScheme, .dark)
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
        hostingView.layerContentsRedrawPolicy = .duringViewResize
        panel.contentView = hostingView
        panel.orderFrontRegardless()

        controller.attach(window: panel)
        controller.startThreadUpdates()

        let panelHotKey = GlobalHotKey(
            identifier: 1,
            shortcuts: [
                .init(
                    keyCode: UInt32(kVK_Space),
                    modifiers: UInt32(optionKey),
                    label: "Option-Space"
                ),
                .init(
                    keyCode: UInt32(kVK_Space),
                    modifiers: UInt32(controlKey | optionKey),
                    label: "Control-Option-Space"
                ),
            ]
        ) { [weak controller] in
            controller?.toggleFromGlobalHotKey()
        }
        self.panelHotKey = panelHotKey
        if let label = panelHotKey.register() {
            print("[hotkey] registered=\(label)")
        } else {
            fputs("[hotkey] panel registration failed\n", stderr)
        }

        let dictationHotKey = GlobalHotKey(
            identifier: 2,
            shortcuts: [
                .init(
                    keyCode: UInt32(kVK_ANSI_V),
                    modifiers: UInt32(optionKey),
                    label: "Option-V"
                ),
            ]
        ) { [weak controller] in
            controller?.toggleDictation()
        }
        self.dictationHotKey = dictationHotKey
        if let label = dictationHotKey.register() {
            print("[hotkey] registered=\(label)")
        } else {
            fputs("[hotkey] dictation registration failed\n", stderr)
        }

        let newNoteHotKey = GlobalHotKey(
            identifier: 3,
            shortcuts: [
                .init(
                    keyCode: UInt32(kVK_ANSI_N),
                    modifiers: UInt32(optionKey),
                    label: "Option-N"
                ),
            ]
        ) { [weak controller] in
            controller?.openNewNote(source: "option-n")
        }
        self.newNoteHotKey = newNoteHotKey
        if let label = newNoteHotKey.register() {
            print("[hotkey] registered=\(label)")
        } else {
            fputs("[hotkey] new-note registration failed\n", stderr)
        }

        let visibilityHotKey = GlobalHotKey(
            identifier: 4,
            shortcuts: [
                .init(
                    keyCode: UInt32(kVK_ANSI_M),
                    modifiers: UInt32(optionKey),
                    label: "Option-M"
                ),
            ]
        ) { [weak controller] in
            controller?.hidePanelCompletely()
        }
        self.visibilityHotKey = visibilityHotKey
        if let label = visibilityHotKey.register() {
            print("[hotkey] registered=\(label)")
        } else {
            fputs("[hotkey] visibility registration failed\n", stderr)
        }

        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak controller] event in
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated {
                controller?.handleKeyEvent(
                    keyCode,
                    modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                ) == true
            }
            return handled ? nil : event
        }

        if !isSmokeTest && !isCalendarLiveTest {
            globalNotchMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.scrollWheel, .leftMouseDown]
            ) { [weak controller] event in
                Task { @MainActor in
                    controller?.handleGlobalPanelEvent(event)
                }
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak controller] _ in
            Task { @MainActor in controller?.repositionForCurrentScreen() }
        }

        if isSmokeTest {
            controller.runSmokeTest()
        } else if isCalendarLiveTest {
            controller.runCalendarLiveTest()
        }
    }

    func applicationWillTerminate(_: Notification) {
        controller.stopThreadUpdates()
        panelHotKey?.unregister()
        panelHotKey = nil
        dictationHotKey?.unregister()
        dictationHotKey = nil
        newNoteHotKey?.unregister()
        newNoteHotKey = nil
        visibilityHotKey?.unregister()
        visibilityHotKey = nil

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }

        if let globalNotchMonitor {
            NSEvent.removeMonitor(globalNotchMonitor)
        }

        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
    }
}

@main
struct IAgentPanelApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

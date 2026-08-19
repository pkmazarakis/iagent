import AppKit
import Carbon
import Combine
import QuartzCore
import SwiftUI
import iAgentCore

private enum PanelMetrics {
    static let notchWidth: CGFloat = 210
    static let expandedWidth: CGFloat = 760
    // Retina captures use two physical pixels per AppKit point. The requested
    // 50px and 24px additions add 37pt to the 556pt compact-width baseline.
    static let compactWidth: CGFloat = 593
    static let fallbackClosedHeight: CGFloat = 24
    static let maximumExpandedHeight: CGFloat = 348
    static let minimumExpandedHeight: CGFloat = 128
    static let homeExpandedHeight: CGFloat = 128
    static let headerHeight: CGFloat = PanelPageLayout.headerHeight
    static let expandedRampWidth: CGFloat = 16
    static let expandedRampDepth: CGFloat = expandedRampWidth
    static let topMaskOverscan: CGFloat = 1
    static let transitionDuration: TimeInterval = 0.25
    static let contentTransitionDuration: TimeInterval = 0.2
    static let reducedMotionDuration: TimeInterval = 0.14
    static let transitionX1 = 0.165
    static let transitionY1 = 0.84
    static let transitionX2 = 0.44
    static let transitionY2 = 1.0

    static func closedHeight(for screen: NSScreen?) -> CGFloat {
        guard let screen else {
            let statusBarHeight = NSStatusBar.system.thickness
            return statusBarHeight > 0 ? statusBarHeight : fallbackClosedHeight
        }

        let reservedMenuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let displayTopInset = max(reservedMenuBarHeight, screen.safeAreaInsets.top)
        if displayTopInset > 0 {
            return displayTopInset
        }

        let statusBarHeight = NSStatusBar.system.thickness
        return statusBarHeight > 0 ? statusBarHeight : fallbackClosedHeight
    }
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

struct AgentThreadActivity: Identifiable, Sendable, Equatable {
    let id: String
    let text: String
    let occurredAt: Date
}

struct AgentThreadVisibleOutput: Identifiable, Sendable, Equatable {
    let id: String
    let text: String
    let occurredAt: Date
}

struct AgentThread: Identifiable, Sendable, Equatable {
    let id: String
    let projectName: String?
    let workspacePath: String?
    /// Stable opaque workspace identity used by the cross-device Codex projection.
    /// It is intentionally separate from the local path, which must never be synced.
    let workspaceID: String? = nil
    let title: String
    let activity: String
    var activityHistory: [AgentThreadActivity] = []
    var visibleOutputs: [AgentThreadVisibleOutput] = []
    let state: AgentState
    let modes: [ThreadMode]
    let elapsed: String
    let createdAt: Date
    let updatedAt: Date
}

enum PanelContentMode: Hashable, Sendable {
    case home
    case threads
    case notes
    case messages
    case calendar
    case create
    case note
    case newThread
    case focus
    case todo
    case todoDetail(UUID)
}

enum NoteSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)
}

enum MeetingSummaryState: Equatable, Sendable {
    case idle
    case generating
    case ready
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

    override func orderOut(_ sender: Any?) {
        NotificationCenter.default.post(name: .panelWindowWillOrderOut, object: self)
        super.orderOut(sender)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
private final class PanelDisplayLinkTarget: NSObject {
    private let callback: (CADisplayLink) -> Void

    init(callback: @escaping (CADisplayLink) -> Void) {
        self.callback = callback
    }

    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        callback(displayLink)
    }
}

@MainActor
final class PanelHostingView: NSView {
    private let hostedView: NSHostingView<AnyView>
    private let contourMask = CAShapeLayer()
    private var contourSize = NSSize.zero

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

    func syncAnimatedGeometry(for size: NSSize) {
        if abs(frame.width - size.width) > 0.25 || abs(frame.height - size.height) > 0.25 {
            setFrameSize(size)
        } else {
            hostedView.frame = CGRect(origin: .zero, size: size)
        }
        needsLayout = true
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

    func renderedTransitionHasVisibleContent(centerExclusionWidth: CGFloat) -> Bool {
        layoutSubtreeIfNeeded()
        displayIfNeeded()
        guard bounds.width >= centerExclusionWidth,
              bounds.height >= 24,
              let bitmap = bitmapImageRepForCachingDisplay(in: bounds)
        else {
            return false
        }
        cacheDisplay(in: bounds, to: bitmap)

        let scaleX = CGFloat(bitmap.pixelsWide) / bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / bounds.height
        let excludedHalfWidth = centerExclusionWidth * scaleX / 2
        let excludedMinX = CGFloat(bitmap.pixelsWide) / 2 - excludedHalfWidth
        let excludedMaxX = CGFloat(bitmap.pixelsWide) / 2 + excludedHalfWidth
        let sampledHeight = min(bitmap.pixelsHigh, max(1, Int(44 * scaleY)))
        var visibleSamples = 0
        var minimumVisibleY = sampledHeight
        var maximumVisibleY = 0

        for y in stride(from: 0, to: sampledHeight, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard CGFloat(x) < excludedMinX || CGFloat(x) > excludedMaxX,
                      let color = bitmap.colorAt(x: x, y: y),
                      let rgb = color.usingColorSpace(.deviceRGB),
                      rgb.alphaComponent > 0.2,
                      max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) > 0.24
                else {
                    continue
                }
                visibleSamples += 1
                minimumVisibleY = min(minimumVisibleY, y)
                maximumVisibleY = max(maximumVisibleY, y)
            }
        }
        let minimumVerticalSpan = max(4, Int(5 * scaleY))
        let verticalSpan = maximumVisibleY - minimumVisibleY
        let hasUsefulContent = visibleSamples >= 24 && verticalSpan >= minimumVerticalSpan
        if !hasUsefulContent {
            print(
                "[transition-content] samples=\(visibleSamples) span=\(verticalSpan) "
                    + "required=24/\(minimumVerticalSpan) size="
                    + "\(Int(bounds.width))x\(Int(bounds.height))"
            )
        }
        return hasUsefulContent
    }

    private func updateContourMask(for size: NSSize) {
        guard size.width > 0, size.height > 0 else {
            contourSize = .zero
            return
        }
        guard abs(contourSize.width - size.width) > 0.01
            || abs(contourSize.height - size.height) > 0.01
        else {
            return
        }
        contourSize = size
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
    }
}

private enum NoteReloadResult: Sendable {
    case success([LocalDocument])
    case failure(String)
}

enum MessageAccessRecoveryDestination: Equatable {
    case chooseMessagesFolder
    case openPrivacySettings
}

func messageAccessRecoveryDestination(
    isSandboxed: Bool,
    hasAuthorizedMessagesDirectory: Bool
) -> MessageAccessRecoveryDestination {
    isSandboxed && !hasAuthorizedMessagesDirectory
        ? .chooseMessagesFolder
        : .openPrivacySettings
}

@MainActor
final class PanelController: ObservableObject {
    @Published var expanded = false
    @Published var compactVisible = true
    @Published var contentVisible = false
    @Published private(set) var isPanelHidden = false
    @Published private(set) var closedPanelHeight = PanelMetrics.fallbackClosedHeight
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
            if oldValue == .messages, contentMode != .messages {
                selectedMessageConversationID = nil
                messageInboxFilter = .all
            }
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
    @Published private(set) var meetingSummaryState: MeetingSummaryState = .idle
    @Published private(set) var meetingSummaryAnimationRevision = 0
    @Published var selectedMeetingNoteTab: MeetingNoteTab = .summary
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
    @Published private(set) var notes: [LocalDocument] = []
    @Published private(set) var noteCount = 0
    @Published private(set) var noteListIssue: String?
    @Published var todoEditorTitle = ""
    @Published var todoEditorNotes = ""
    @Published private(set) var todoEditorFocusRequest = 0
    @Published var todoShowsRawMarkdown = false
    @Published var todoFindVisible = false
    @Published private(set) var todoSaveState: NoteSaveState = .idle
    @Published private(set) var syncedArtifactMentions: [ArtifactMention] = []
    @Published private(set) var syncedCalendarEvents: [SyncedCalendarEvent] = []
    @Published private(set) var routedTodoID: UUID?
    @Published private(set) var routedCalendarEventID: String?
    @Published private(set) var savedTodoListNames: [String] = []
    @Published private(set) var completingTodoIDs: Set<UUID> = []
    @Published private(set) var fadingTodoIDs: Set<UUID> = []
    @Published private(set) var showingPastTodos = false
    @Published private(set) var cloudSyncStatus = IAgentCloudSyncStatus()
    @Published private(set) var cloudSyncPendingRecordCount = 0
    @Published private(set) var todoStorageIssue: String?
    @Published private(set) var messageConversations: [SyncedMessageConversation] = []
    @Published private(set) var messages: [SyncedMessage] = []
    @Published private(set) var messageReadStates: [SyncedMessageReadState] = []
    @Published private(set) var messageRelayStates: [SyncedMessageRelayState] = []
    @Published private(set) var messageProviderAccess: MessageProviderAccessState = .loading
    @Published private(set) var messageProviderBackfillInFlight = false
    @Published private(set) var messageReplyTransportEnabled = false
    @Published var selectedMessageConversationID: String?
    @Published var messageInboxFilter: MessageInboxFilter = .all
    private var messageInboxIndex = MessageInboxIndex()
    private(set) var lastOpenedThreadID: String?

    let dictation = SpeechDictationService()
    let meetingCapture: MeetingCaptureService
    let calendarService: CalendarEventService
    let localFirstName: String?

    weak var window: PanelWindow?
    private var transitionID = 0
    private var targetPresentation: PanelPresentation = .compact
    private var lastVisiblePresentation: PanelPresentation = .compact
    private var frameDisplayLink: CADisplayLink?
    private var frameDisplayLinkTarget: PanelDisplayLinkTarget?
    private var frameAnimationWatchdogTask: Task<Void, Never>?
    private var frameAnimationDidAdvance = false
    private var frameAnimationStartFrame = NSRect.zero
    private var frameAnimationTargetFrame = NSRect.zero
    private var frameAnimationStartedAt: TimeInterval = 0
    private var frameAnimationDuration: TimeInterval = 0
    private var frameAnimationStartAlpha: CGFloat = 1
    private var frameAnimationTargetAlpha: CGFloat = 1
    private var frameAnimationCompletion: (@MainActor @Sendable () -> Void)?
    private var frameAnimationGeneration = 0
    private var refreshTimer: Timer?
    private var refreshInFlight = false
    private var refreshPending = false
    private var refreshDebounceTask: Task<Void, Never>?
    private var focusTimer: Timer?
    private var focusEndsAt: Date?
    private var noteAutosaveTask: Task<Void, Never>?
    private var noteReloadTask: Task<Void, Never>?
    private var noteReloadGeneration = 0
    private var meetingSummaryTask: Task<Void, Never>?
    private var meetingSummaryDocumentID: String?
    private var meetingCaptureStartTask: Task<Void, Never>?
    private var meetingCaptureStartID: UUID?
    private var meetingCaptureStopTask: Task<Bool, Never>?
    private var meetingCaptureStopID: UUID?
    private var todoCompletionTasks: [UUID: Task<Void, Never>] = [:]
    private var todoAutosaveTask: Task<Void, Never>?
    private var todoEditorBaseTitle = ""
    private var todoEditorBaseNotes: String?
    private var todoEditorHasUnsavedChanges = false
    private var todoEditorHasRemoteConflict = false
    private var desktopSyncTimer: Timer?
    private var desktopSyncDebounceTask: Task<Void, Never>?
    @Published private var desktopSyncInFlight = false
    private var desktopSyncFetchPending = false
    private var cloudSyncStatusObserver: NSObjectProtocol?
    private var cloudSyncStatusRefreshTask: Task<Void, Never>?
    private var cloudSyncStatusRefreshGeneration = 0
    private var messageProviderTask: Task<Void, Never>?
    private var messageProviderRefreshGeneration = 0
    private var todosAreAuthoritative = true
    private var todoListNamesAreAuthoritative = true
    private var todoFileIssue: String?
    private var todoListFileIssue: String?
    private var hasLoadedThreads = false
    private var loadedThreadLimit = 200
    private let fileMonitor = CodexFileMonitor()
    private let documentStore: LocalDocumentStore
    private let todoStore: LocalTodoStore
    private let desktopSync: DesktopSyncCoordinator
    private var messageProvider: any MacMessageProviding
    private let projectPreferences: ProjectSectionPreferenceStore
    private let preferences: UserDefaults
    private let codexClient = CodexAppServerClient()
    private let codexDesktopSender = CodexDesktopPromptSender()
    private let isSmokeTest: Bool
    private let meetingSummarizer: any MeetingSummarizing = LocalMeetingSummarizer()

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

    var visibleMessageConversations: [SyncedMessageConversation] {
        visibleMessageConversations(referenceDate: referenceNow)
    }

    var isMessageInboxSyncing: Bool {
        messageProviderBackfillInFlight
            || desktopSyncInFlight
            || cloudSyncStatus.phase == .syncing
    }

    private func visibleMessageConversations(
        referenceDate: Date
    ) -> [SyncedMessageConversation] {
        messageInboxIndex.orderedVisibleConversations(
            messageConversations,
            referenceDate: referenceDate
        )
    }

    var totalMessageUnreadCount: Int {
        visibleMessageConversations.reduce(0) {
            $0 + messageInboxIndex.unreadCount(
                for: $1.id,
                referenceDate: referenceNow
            )
        }
    }

    var unreadMessageConversationCount: Int {
        visibleMessageConversations.filter {
            messageInboxIndex.unreadCount(
                for: $0.id,
                referenceDate: referenceNow
            ) > 0
        }.count
    }

    var awaitingReplyConversationCount: Int {
        messageInboxIndex.awaitingMyReplyCount(
            for: visibleMessageConversations,
            referenceDate: referenceNow
        )
    }

    func retainedMessages(for conversationID: String) -> [SyncedMessage] {
        messageInboxIndex.retainedMessages(
            for: conversationID,
            referenceDate: referenceNow
        )
    }

    func unreadCount(for conversationID: String) -> Int {
        messageInboxIndex.unreadCount(
            for: conversationID,
            referenceDate: referenceNow
        )
    }

    func isAwaitingReply(for conversation: SyncedMessageConversation) -> Bool {
        messageInboxIndex.isAwaitingMyReply(
            for: conversation,
            referenceDate: referenceNow
        )
    }

    func filteredMessageConversations(
        matching query: String,
        filter: MessageInboxFilter
    ) -> [SyncedMessageConversation] {
        messageInboxIndex.filteredConversations(
            visibleMessageConversations,
            query: query,
            filter: filter,
            referenceDate: referenceNow
        )
    }

    func toggleMessageInboxFilter(_ filter: MessageInboxFilter) {
        messageInboxFilter = messageInboxFilter == filter ? .all : filter
    }

    /// Live desktop sources override the last synchronized projection so the
    /// picker updates immediately after a local edit while still including all
    /// portable note paths materialized by the sync store.
    var artifactMentions: [ArtifactMention] {
        // The desktop calendar page renders today's live EventKit rows. Rebuild
        // this one section from those rows while preserving the synced
        // occurrence's portable route ID for links shared between devices.
        var byID = Dictionary(
            uniqueKeysWithValues: syncedArtifactMentions
                .filter { $0.kind != .calendarEvent }
                .map { ($0.id, $0) }
        )

        for todo in todos {
            let title = todo.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let mention = ArtifactMention(
                kind: .todo,
                artifactID: todo.id.uuidString,
                title: title,
                subtitle: todo.isCompleted ? "Completed" : todo.listName,
                updatedAt: todo.updatedAt
            )
            byID[mention.id] = mention
        }

        for event in calendarService.events {
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let mention = ArtifactMention(
                kind: .calendarEvent,
                artifactID: calendarArtifactID(for: event),
                title: title,
                subtitle: event.startDate.formatted(date: .abbreviated, time: .shortened),
                updatedAt: event.updatedAt
            )
            byID[mention.id] = mention
        }

        for thread in threads {
            let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let mention = ArtifactMention(
                kind: .codexThread,
                artifactID: thread.id,
                title: title,
                subtitle: thread.projectName ?? "Codex",
                updatedAt: thread.updatedAt
            )
            byID[mention.id] = mention
        }

        if let document = lastSavedDocument,
           document.kind == .note,
           let relativePath = documentStore.relativePath(for: document.fileURL)
        {
            let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let mention = ArtifactMention(
                    kind: .note,
                    artifactID: relativePath,
                    title: title,
                    subtitle: document.kind.singularLabel.capitalized,
                    updatedAt: document.createdAt
                )
                byID[mention.id] = mention
            }
        }

        return byID.values.filter { $0.url != nil }.sorted { lhs, rhs in
            let leftKind = ArtifactMentionKind.allCases.firstIndex(of: lhs.kind) ?? .max
            let rightKind = ArtifactMentionKind.allCases.firstIndex(of: rhs.kind) ?? .max
            if leftKind != rightKind { return leftKind < rightKind }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private func calendarArtifactID(for event: CalendarEventItem) -> String {
        let occurrence = syncedCalendarEvent(from: event)
        let matchingIDs = Set(syncedCalendarEvents.lazy.filter {
            $0.deletedAt == nil && $0.isSameOccurrence(as: occurrence)
        }.map(\.id))
        return syncedArtifactMentions.first {
            $0.kind == .calendarEvent && matchingIDs.contains($0.artifactID)
        }?.artifactID ?? event.id
    }

    private func syncedCalendarEvent(from event: CalendarEventItem) -> SyncedCalendarEvent {
        SyncedCalendarEvent(
            id: event.id,
            sourceIdentifier: event.sourceIdentifier,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendarTitle,
            location: event.location,
            notes: event.notes,
            calendarColorHex: event.tint.hexString,
            linkURLs: event.linkURLs,
            updatedAt: event.updatedAt
        )
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

    var selectedTodoID: UUID? {
        guard case let .todoDetail(id) = contentMode else { return nil }
        return id
    }

    var selectedTodo: LocalTodo? {
        guard let selectedTodoID else { return nil }
        return todos.first { $0.id == selectedTodoID }
    }

    var todoEditorDocumentID: String {
        selectedTodoID.map { "todo-\($0.uuidString)" } ?? "todo-none"
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
        case .notes: "Notes"
        case .messages: "Messages"
        case .calendar: "Calendar"
        case .create: "Create"
        case .note:
            if isShowingMeetingNote { "Meeting notes" }
            else { lastSavedDocument == nil ? "New note" : "Note" }
        case .newThread: "New codex thread"
        case .focus: "New focus session"
        case .todo: showingPastTodos ? "Past todos" : "Todo"
        case .todoDetail: "Todo"
        }
    }

    var homeTitle: String {
        localFirstName.map { "Hello \($0)" } ?? "Home"
    }

    var isShowingMeetingNote: Bool {
        contentMode == .note && MeetingNoteCodec.isMeetingNote(editorBody)
    }

    var meetingNoteDocument: MeetingNoteDocument? {
        MeetingNoteCodec.parse(editorBody)
    }

    var meetingSummaryMarkdown: String {
        meetingNoteDocument?.summaryMarkdown ?? ""
    }

    var meetingTranscriptSegments: [MeetingTranscriptSegment] {
        meetingNoteDocument?.transcriptSegments ?? []
    }

    var expandedSize: NSSize {
        NSSize(width: PanelMetrics.expandedWidth, height: preferredExpandedHeight)
    }

    var compactSize: NSSize {
        NSSize(width: PanelMetrics.compactWidth, height: closedPanelHeight)
    }

    var notchSize: NSSize {
        NSSize(width: PanelMetrics.notchWidth, height: closedPanelHeight)
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
        case .notes:
            let visibleRows = min(6, max(2, notes.count))
            height = PanelMetrics.headerHeight + CGFloat(visibleRows) * 48 + 8
        case .messages:
            height = PanelMetrics.maximumExpandedHeight
        case .create:
            height = PanelMetrics.headerHeight + CGFloat(CreationOption.allCases.count) * 44 + 12
        case .note:
            height = isShowingMeetingNote ? PanelMetrics.maximumExpandedHeight : 310
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
        case .todoDetail:
            height = 310
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
        self.preferences = preferences
        messageReplyTransportEnabled = MessageReplyPreferences.isEnabled(in: preferences)
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
        let sandboxAccess = SandboxAccessManager.shared
        messageProvider = MacMessageProviderFactory.make(
            smokeTest: smokeTest,
            preferences: preferences,
            authorizedDatabaseURL: sandboxAccess.authorizedMessagesDatabaseURL,
            requiresSecurityScopedDatabaseURL: !smokeTest && sandboxAccess.isSandboxed
        )
        noteCount = localDocumentStore.documentCount(for: .note)
        if smokeTest {
            try? FileManager.default.removeItem(at: todoStore.fileURL)
            try? FileManager.default.removeItem(at: todoStore.listFileURL)
        }
        do {
            todos = try todoStore.load()
        } catch {
            todosAreAuthoritative = false
            todoFileIssue = error.localizedDescription
        }
        do {
            savedTodoListNames = try todoStore.loadListNames()
        } catch {
            todoListNamesAreAuthoritative = false
            todoListFileIssue = error.localizedDescription
        }
        updateTodoStorageIssue()
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
        updateClosedPanelHeight(for: window.screen ?? NSScreen.main)
        applyPinnedWindowFrame(targetFrame(expanded: false), display: true)
    }

    func startThreadUpdates() {
        startCloudSyncStatusUpdates()
        calendarService.start()
        reloadNotes()
        startMessageProviderUpdates()
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
        resetMeetingNotePresentation()
        noteAutosaveTask?.cancel()
        noteAutosaveTask = nil
        noteReloadTask?.cancel()
        noteReloadTask = nil
        todoAutosaveTask?.cancel()
        todoAutosaveTask = nil
        desktopSyncDebounceTask?.cancel()
        desktopSyncDebounceTask = nil
        desktopSyncTimer?.invalidate()
        desktopSyncTimer = nil
        stopCloudSyncStatusUpdates()
        messageProviderTask?.cancel()
        messageProviderTask = nil
        messageProviderRefreshGeneration &+= 1
        messageProviderBackfillInFlight = false
        if contentMode == .note {
            saveLocalDocument(kind: .note, announce: false)
        } else if case .todoDetail = contentMode {
            saveTodoDetail(announce: false)
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        fileMonitor.stop()
        dictation.cancel()
        meetingCaptureStartID = nil
        meetingCaptureStartTask?.cancel()
        meetingCaptureStartTask = nil
        meetingCapture.shutdown()
        codexClient.stop()
        calendarService.stop()
        Task { await desktopSync.stop() }
        focusTimer?.invalidate()
        focusTimer = nil
    }

    private func startCloudSyncStatusUpdates() {
        guard cloudSyncStatusObserver == nil else { return }
        cloudSyncStatusObserver = NotificationCenter.default.addObserver(
            forName: .iAgentSyncStatusDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCloudSyncStatus()
            }
        }
        refreshCloudSyncStatus()
    }

    private func stopCloudSyncStatusUpdates() {
        if let cloudSyncStatusObserver {
            NotificationCenter.default.removeObserver(cloudSyncStatusObserver)
            self.cloudSyncStatusObserver = nil
        }
        cloudSyncStatusRefreshGeneration &+= 1
        cloudSyncStatusRefreshTask?.cancel()
        cloudSyncStatusRefreshTask = nil
    }

    private func refreshCloudSyncStatus() {
        guard cloudSyncStatusObserver != nil else { return }
        cloudSyncStatusRefreshGeneration &+= 1
        let generation = cloudSyncStatusRefreshGeneration
        cloudSyncStatusRefreshTask?.cancel()
        cloudSyncStatusRefreshTask = Task { [weak self] in
            guard let self else { return }
            let status = await self.desktopSync.currentCloudSyncStatus()
            guard !Task.isCancelled,
                  generation == self.cloudSyncStatusRefreshGeneration
            else { return }
            self.cloudSyncStatus = status
            self.cloudSyncPendingRecordCount = status.pendingRecordCount
            self.cloudSyncStatusRefreshTask = nil
        }
    }

    private func startMessageProviderUpdates() {
        messageProviderTask?.cancel()
        messageProviderRefreshGeneration &+= 1
        let refreshGeneration = messageProviderRefreshGeneration
        messageProviderBackfillInFlight = true
        messageProviderTask = Task { [weak self] in
            guard let self else { return }
            if !self.messageReplyTransportEnabled {
                let scrubbedState = await self.desktopSync.scrubMessageReplyAddresses()
                guard !Task.isCancelled else {
                    self.finishMessageProviderBackfill(refreshGeneration)
                    return
                }
                self.applyDesktopSyncState(scrubbedState, basedOn: nil)
            }
            if !(self.messageProvider is MockMacMessagesProvider) {
                let cleanedState = await self.desktopSync.removeDevelopmentMessageFixtures()
                self.applyDesktopSyncState(cleanedState, basedOn: nil)
            }

            let access = await self.messageProvider.authorizationStatus()
            guard !Task.isCancelled else {
                self.finishMessageProviderBackfill(refreshGeneration)
                return
            }
            self.messageProviderAccess = access
            let relayState = await self.desktopSync.publishMessageRelayState(access)
            self.applyDesktopSyncState(relayState, basedOn: nil)
            guard case .authorized = access else {
                self.finishMessageProviderBackfill(refreshGeneration)
                return
            }

            let cutoff = MessageSyncWindow.cutoff()
            do {
                let backfill = try await self.messageProvider.backfill(since: cutoff)
                guard !Task.isCancelled else {
                    self.finishMessageProviderBackfill(refreshGeneration)
                    return
                }
                self.referenceNow = Date()
                let initialState = await self.desktopSync.ingestMessageBatch(backfill)
                self.applyDesktopSyncState(initialState, basedOn: nil)
                self.markSelectedMessageConversationReadIfNeeded()
                // The authoritative snapshot is usable as soon as it has been
                // applied. A healthy updates stream can stay open indefinitely
                // without yielding, so it must not keep the inbox in a loading
                // state while it waits for the next source change.
                self.finishMessageProviderBackfill(refreshGeneration)

                for try await batch in self.messageProvider.updates(since: cutoff) {
                    guard !Task.isCancelled else { return }
                    self.referenceNow = Date()
                    let nextState = await self.desktopSync.ingestMessageBatch(batch)
                    self.applyDesktopSyncState(nextState, basedOn: nil)
                    self.markSelectedMessageConversationReadIfNeeded()
                }
                self.finishMessageProviderBackfill(refreshGeneration)
            } catch is CancellationError {
                self.finishMessageProviderBackfill(refreshGeneration)
            } catch {
                self.finishMessageProviderBackfill(refreshGeneration)
                self.messageProviderAccess = MacMessageProviderFactory.accessState(for: error)
                let failedState = await self.desktopSync.publishMessageRelayState(
                    self.messageProviderAccess
                )
                self.applyDesktopSyncState(failedState, basedOn: nil)
            }
        }
    }

    private func finishMessageProviderBackfill(_ generation: Int) {
        guard generation == messageProviderRefreshGeneration else { return }
        messageProviderBackfillInFlight = false
    }

    func connectLocalMessages() {
        guard !isSmokeTest else { return }
        let sandboxAccess = SandboxAccessManager.shared
        var authorizedDatabaseURL = sandboxAccess.authorizedMessagesDatabaseURL
        if sandboxAccess.isSandboxed {
            do {
                guard let selectedDatabaseURL = try sandboxAccess
                    .requestMessagesDirectoryAccess(defaults: preferences)
                else { return }
                authorizedDatabaseURL = selectedDatabaseURL
            } catch let error as SandboxMessagesAccessError {
                switch error {
                case .invalidMessagesDirectory:
                    messageProviderAccess = .disabled(error.localizedDescription)
                case .securityScopeUnavailable, .bookmarkCreationFailed:
                    messageProviderAccess = .failed(error.localizedDescription)
                }
                Task { [weak self] in
                    guard let self else { return }
                    let state = await self.desktopSync.publishMessageRelayState(
                        self.messageProviderAccess
                    )
                    self.applyDesktopSyncState(state, basedOn: nil)
                }
                return
            } catch {
                messageProviderAccess = .failed(error.localizedDescription)
                Task { [weak self] in
                    guard let self else { return }
                    let state = await self.desktopSync.publishMessageRelayState(
                        self.messageProviderAccess
                    )
                    self.applyDesktopSyncState(state, basedOn: nil)
                }
                return
            }
        }
        MacMessageProviderFactory.setLocalAccessEnabled(true, preferences: preferences)
        messageProvider = MacMessageProviderFactory.make(
            smokeTest: false,
            preferences: preferences,
            authorizedDatabaseURL: authorizedDatabaseURL,
            requiresSecurityScopedDatabaseURL: sandboxAccess.isSandboxed
        )
        messageProviderAccess = .loading
        startMessageProviderUpdates()
    }

    func setMessageReplyTransportEnabled(_ enabled: Bool) {
        guard messageReplyTransportEnabled != enabled else { return }
        MessageReplyPreferences.setEnabled(enabled, in: preferences)
        messageReplyTransportEnabled = enabled

        // Reply addresses are provider-authored routing data. Rebuild and run
        // one authoritative backfill on both enable and disable so opt-in can
        // publish them. The refresh scrubs them before checking source access
        // on opt-out, so revocation also works while Messages is unavailable.
        guard !isSmokeTest else { return }
        let sandboxAccess = SandboxAccessManager.shared
        messageProvider = MacMessageProviderFactory.make(
            smokeTest: false,
            preferences: preferences,
            authorizedDatabaseURL: sandboxAccess.authorizedMessagesDatabaseURL,
            requiresSecurityScopedDatabaseURL: sandboxAccess.isSandboxed
        )
        messageProviderAccess = .loading
        startMessageProviderUpdates()
    }

    func resolveMessageReplyRecipients(
        for conversationID: String
    ) async throws -> [MessageReplyRecipient] {
        let provider = messageProvider
        do {
            return try await provider.replyRecipients(
                for: conversationID,
                since: MessageSyncWindow.cutoff()
            )
        } catch {
            messageProviderAccess = MacMessageProviderFactory.accessState(for: error)
            throw error
        }
    }

    var messageAccessRecoveryActionTitle: String {
        switch messageAccessRecoveryDestination(
            isSandboxed: SandboxAccessManager.shared.isSandboxed,
            hasAuthorizedMessagesDirectory:
                SandboxAccessManager.shared.hasAuthorizedMessagesDirectory
        ) {
        case .chooseMessagesFolder:
            "Choose Messages Folder"
        case .openPrivacySettings:
            "Open Privacy Settings"
        }
    }

    func recoverLocalMessagesAccess() {
        switch messageAccessRecoveryDestination(
            isSandboxed: SandboxAccessManager.shared.isSandboxed,
            hasAuthorizedMessagesDirectory:
                SandboxAccessManager.shared.hasAuthorizedMessagesDirectory
        ) {
        case .chooseMessagesFolder:
            connectLocalMessages()
        case .openPrivacySettings:
            guard let url = messageFullDiskAccessSettingsURL() else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private func markSelectedMessageConversationReadIfNeeded() {
        guard contentMode == .messages,
              let conversationID = selectedMessageConversationID,
              let latest = retainedMessages(for: conversationID).last,
              unreadCount(for: conversationID) > 0
        else { return }
        applyMessageReadStateLocally(conversationID: conversationID, through: latest)
        Task { [weak self] in
            guard let self else { return }
            let state = await self.desktopSync.markMessageConversationRead(
                conversationID: conversationID,
                through: latest
            )
            self.applyDesktopSyncState(state, basedOn: nil)
        }
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

        retryUnavailableTodoSources()
        let fetchRemote = desktopSyncFetchPending
        desktopSyncFetchPending = false
        desktopSyncInFlight = true
        cloudSyncStatus.phase = .syncing
        let input = DesktopSyncInput(
            threads: hasLoadedThreads ? threads : nil,
            calendarEvents: calendarService.accessState.canReadEvents
                ? calendarService.syncEvents
                : nil,
            todos: todos,
            todoListNames: todoListNames,
            projectOrder: projectOrder,
            todosAreAuthoritative: todosAreAuthoritative,
            todoListNamesAreAuthoritative: todoListNamesAreAuthoritative
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
        basedOn input: DesktopSyncInput?
    ) {
        if let input {
            let nextTodos = DesktopTodoReconciler.merge(
                remote: state.todos,
                captured: input.todos,
                current: todos
            )
            if input.todosAreAuthoritative {
                if nextTodos != todos {
                    do {
                        try todoStore.save(nextTodos)
                        todos = nextTodos
                        todosAreAuthoritative = true
                        todoFileIssue = nil
                        reconcileTodoDetailSelection()
                        resizeExpandedPanel()
                    } catch {
                        todosAreAuthoritative = false
                        todoFileIssue = error.localizedDescription
                    }
                }
            } else if !todosAreAuthoritative, nextTodos != todos {
                // Keep remote todos visible while the canonical iCloud file is unavailable.
                // They remain in memory only; retryUnavailableTodoSources performs the
                // authoritative merge after the file materializes.
                todos = nextTodos
                reconcileTodoDetailSelection()
                resizeExpandedPanel()
            }

            if input.todoListNamesAreAuthoritative {
                let nextListNames = Self.mergedTodoListNames(
                    local: savedTodoListNames,
                    remote: state.todoListNames
                )
                if nextListNames != savedTodoListNames {
                    do {
                        try todoStore.saveListNames(nextListNames)
                        savedTodoListNames = nextListNames
                        todoListNamesAreAuthoritative = true
                        todoListFileIssue = nil
                    } catch {
                        todoListNamesAreAuthoritative = false
                        todoListFileIssue = error.localizedDescription
                    }
                }
            }
            updateTodoStorageIssue()
            reloadNotes()
        }

        messageInboxIndex = MessageInboxIndex(
            messages: state.messages,
            readStates: state.messageReadStates
        )
        messageConversations = state.messageConversations
        messages = state.messages
        messageReadStates = state.messageReadStates
        messageRelayStates = state.messageRelayStates
        if let selectedMessageConversationID,
           !visibleMessageConversations.contains(where: { $0.id == selectedMessageConversationID })
        {
            self.selectedMessageConversationID = nil
        }
        noteCount = state.noteCount
        syncedCalendarEvents = state.calendarEvents
        syncedArtifactMentions = state.artifactMentions
        cloudSyncStatus = state.status
        cloudSyncPendingRecordCount = state.pendingRecordCount
        if state.status.phase == .syncing {
            refreshCloudSyncStatus()
        }
        if contentMode == .messages {
            resizeExpandedPanel()
        }
    }

    private func retryUnavailableTodoSources() {
        if !todosAreAuthoritative {
            do {
                let loaded = try todoStore.load()
                var merged = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
                for current in todos {
                    if let stored = merged[current.id] {
                        if current.updatedAt > stored.updatedAt {
                            merged[current.id] = current
                        }
                    } else {
                        merged[current.id] = current
                    }
                }
                todos = merged.values.sorted { $0.createdAt > $1.createdAt }
                reconcileTodoDetailSelection()
                try todoStore.save(todos)
                todosAreAuthoritative = true
                todoFileIssue = nil
                resizeExpandedPanel()
            } catch {
                todoFileIssue = error.localizedDescription
            }
        }
        if !todoListNamesAreAuthoritative {
            do {
                savedTodoListNames = Self.mergedTodoListNames(
                    local: savedTodoListNames,
                    remote: try todoStore.loadListNames()
                )
                try todoStore.saveListNames(savedTodoListNames)
                todoListNamesAreAuthoritative = true
                todoListFileIssue = nil
            } catch {
                todoListFileIssue = error.localizedDescription
            }
        }
        updateTodoStorageIssue()
    }

    private func updateTodoStorageIssue() {
        let issues = [todoFileIssue, todoListFileIssue].compactMap { $0 }
        todoStorageIssue = issues.isEmpty ? nil : issues.joined(separator: " ")
    }

    private func reconcileTodoDetailSelection() {
        guard let selectedTodoID else { return }
        guard let todo = todos.first(where: { $0.id == selectedTodoID }) else {
            resetTodoDetailPresentation()
            contentMode = .todo
            statusMessage = "That todo is no longer available."
            return
        }

        let remoteTitleChanged = todo.title != todoEditorBaseTitle
        let remoteNotesChanged = todo.notes != todoEditorBaseNotes
        guard remoteTitleChanged || remoteNotesChanged else { return }

        let draftTitle = todoEditorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftNotes = normalizedTodoNotes(todoEditorNotes)
        let titleWasEdited = draftTitle != todoEditorBaseTitle
        let notesWereEdited = draftNotes != todoEditorBaseNotes
        let titleConflicts = titleWasEdited
            && remoteTitleChanged
            && draftTitle != todo.title
        let notesConflict = notesWereEdited
            && remoteNotesChanged
            && draftNotes != todo.notes

        todoEditorBaseTitle = todo.title
        todoEditorBaseNotes = todo.notes
        if !titleWasEdited {
            todoEditorTitle = todo.title
        }
        if !notesWereEdited {
            todoEditorNotes = todo.notes ?? ""
        }

        let rebasedTitle = todoEditorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let rebasedNotes = normalizedTodoNotes(todoEditorNotes)
        todoEditorHasUnsavedChanges = rebasedTitle != todoEditorBaseTitle
            || rebasedNotes != todoEditorBaseNotes
        todoEditorHasRemoteConflict = titleConflicts || notesConflict

        if todoEditorHasRemoteConflict {
            todoAutosaveTask?.cancel()
            todoAutosaveTask = nil
            let message = "This todo changed on another device. Your edits are preserved; press Command-S to keep them."
            todoSaveState = .failed(message)
            statusMessage = message
        } else if !todoEditorHasUnsavedChanges {
            todoAutosaveTask?.cancel()
            todoAutosaveTask = nil
            todoSaveState = .saved
            statusMessage = nil
        }
    }

    func syncNow() {
        scheduleDesktopSync(fetchRemote: true, delay: .zero)
    }

    var cloudSyncHelpText: String {
        var parts: [String] = []
        switch cloudSyncStatus.phase {
        case .idle:
            parts.append(cloudSyncPendingRecordCount == 0 ? "Synced" : "Waiting to upload")
        case .syncing:
            parts.append("Syncing")
        case .offline:
            parts.append("Offline")
        case .accountUnavailable:
            parts.append("iCloud unavailable")
        case .failed:
            parts.append("Sync needs attention")
        }
        if cloudSyncPendingRecordCount > 0 {
            parts.append("\(cloudSyncPendingRecordCount) queued")
        }
        if let lastSuccessfulSyncAt = cloudSyncStatus.lastSuccessfulSyncAt {
            parts.append("last synced \(lastSuccessfulSyncAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if let message = cloudSyncStatus.message, !message.isEmpty {
            parts.append(message)
        }
        if let todoStorageIssue {
            parts.append(todoStorageIssue)
        }
        return parts.joined(separator: " • ")
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
            let shouldFocusMarkdownEditor: Bool
            switch contentMode {
            case .note:
                shouldFocusMarkdownEditor = !noteFindVisible
            case .todoDetail:
                shouldFocusMarkdownEditor = !todoFindVisible
            default:
                shouldFocusMarkdownEditor = false
            }

            if shouldFocusMarkdownEditor,
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
        guard flushCurrentEditorIfNeeded() else { return }
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
        guard flushCurrentEditorIfNeeded() else { return }
        dictation.cancel()
        isStartingDictation = false
        dictationTargetThreadID = nil
        hoveredThreadID = nil
        contentMode = .home
        statusMessage = nil
        isSubmitting = false
    }

    func showThreads() {
        guard flushCurrentEditorIfNeeded() else { return }
        contentMode = .threads
        selectedThreadID = nil
        hoveredThreadID = nil
        statusMessage = nil
    }

    func showNotes() {
        if contentMode == .note, !flushCurrentNoteIfNeeded() { return }
        reloadNotes()
        contentMode = .notes
        statusMessage = nil
        syncNow()
    }

    func showMessages() {
        contentMode = .messages
        selectedMessageConversationID = nil
        messageInboxFilter = .all
        hoveredThreadID = nil
        statusMessage = nil
    }

    func selectMessageConversation(_ conversationID: String) {
        selectedMessageConversationID = conversationID
        guard let latest = retainedMessages(for: conversationID).last else { return }
        applyMessageReadStateLocally(conversationID: conversationID, through: latest)
        Task { [weak self] in
            guard let self else { return }
            let state = await self.desktopSync.markMessageConversationRead(
                conversationID: conversationID,
                through: latest
            )
            self.applyDesktopSyncState(state, basedOn: nil)
        }
    }

    func closeMessageConversation() {
        selectedMessageConversationID = nil
    }

    func navigateBackFromMessages() {
        guard contentMode == .messages else {
            returnHome()
            return
        }
        if selectedMessageConversationID != nil {
            closeMessageConversation()
        } else {
            returnHome()
        }
    }

    private func applyMessageReadStateLocally(
        conversationID: String,
        through message: SyncedMessage
    ) {
        let candidate = SyncedMessageReadState(
            id: conversationID,
            readThroughMessageID: message.id,
            readThroughDate: message.sentAt,
            latestKnownMessageDate: message.sentAt,
            updatedAt: Date(),
            sourceDeviceID: "desktop-local"
        )
        var nextReadStates = messageReadStates
        if let index = nextReadStates.firstIndex(where: { $0.id == conversationID }) {
            let existingCursor = (
                nextReadStates[index].readThroughDate ?? .distantPast,
                nextReadStates[index].readThroughMessageID ?? ""
            )
            guard (message.sentAt, message.id) >= existingCursor else { return }
            nextReadStates[index] = candidate
        } else {
            nextReadStates.append(candidate)
        }
        messageInboxIndex.replaceReadStates(nextReadStates)
        messageReadStates = nextReadStates
    }

    func showCalendar() {
        guard flushCurrentEditorIfNeeded() else { return }
        calendarService.start()
        routedCalendarEventID = nil
        contentMode = .calendar
        statusMessage = nil
    }

    func showTodos() {
        guard flushCurrentEditorIfNeeded() else { return }
        showingPastTodos = false
        routedTodoID = nil
        contentMode = .todo
        statusMessage = nil
        requestTodoComposerFocus()
    }

    /// Handles links authored into rich note text. Artifact routes target the
    /// concrete row/document/task where the local source is available and
    /// otherwise fall back to the containing section with a calm status.
    func openArtifactLink(_ url: URL) {
        guard let destination = IAgentDeepLink(url: url) else { return }

        switch destination {
        case .todos:
            showTodos()
        case .createTodo:
            showTodos()
            requestTodoComposerFocus()
        case .todo(let id):
            routeToTodo(id)
        case .notes:
            openLocalNotesFolder()
        case .createNote:
            openNewNote(source: "artifact-link")
        case .note(let id):
            Task { [weak self] in
                guard let self else { return }
                if let document = await self.desktopSync.localDocument(noteID: id) {
                    self.openMentionedDocument(document)
                } else {
                    self.openLocalNotesFolder()
                    self.statusMessage = "That note is not available on this Mac."
                }
            }
        case .notePath(let relativePath):
            if let document = documentStore.load(relativePath: relativePath),
               document.kind == .note
            {
                openMentionedDocument(document)
            } else {
                openLocalNotesFolder()
                statusMessage = "That note is not available on this Mac."
            }
        case .calendar:
            showCalendar()
        case .calendarEvent(let id):
            routeToCalendarEvent(id)
        case .meetingReady:
            showCalendar()
        case .codex:
            showThreads()
        case .createCodexRequest:
            guard flushCurrentEditorIfNeeded() else { return }
            resetSharedEditorDraft(for: .codexThread)
            contentMode = .newThread
        case .codexThread(let id):
            if let thread = threads.first(where: { $0.id == id }) {
                openThread(thread)
            } else {
                showThreads()
                statusMessage = "That Codex task is no longer available."
            }
        }

        setExpanded(true, source: "artifact-link")
    }

    private func routeToTodo(_ id: UUID) {
        guard flushCurrentEditorIfNeeded() else { return }
        guard let todo = todos.first(where: { $0.id == id }) else {
            showingPastTodos = false
            routedTodoID = nil
            contentMode = .todo
            statusMessage = "That todo is no longer available."
            return
        }
        showingPastTodos = todo.isCompleted
        routedTodoID = id
        contentMode = .todo
        statusMessage = nil
    }

    private func routeToCalendarEvent(_ id: String) {
        guard flushCurrentEditorIfNeeded() else { return }
        calendarService.start()
        contentMode = .calendar
        let event = calendarService.events.first(where: { $0.id == id })
            ?? syncedCalendarEvents.first(where: { $0.deletedAt == nil && $0.id == id })
                .flatMap { target in
                    calendarService.events.first {
                        target.isSameOccurrence(as: syncedCalendarEvent(from: $0))
                    }
                }
        guard let event else {
            routedCalendarEventID = nil
            statusMessage = "That calendar event is not available today."
            return
        }
        routedCalendarEventID = event.id
        statusMessage = nil
    }

    private func openMentionedDocument(_ document: LocalDocument) {
        guard flushCurrentEditorIfNeeded() else { return }
        resetMeetingNotePresentation()
        dictation.cancel()
        isStartingDictation = false
        dictationTargetThreadID = nil
        selectedCreationOption = .note
        lastSavedDocument = document
        editorTitle = document.title
        editorBody = document.body
        noteEditorDocumentID = document.id
        noteShowsRawMarkdown = false
        noteFindVisible = false
        noteSaveState = .saved
        statusMessage = nil
        contentMode = .note
        setExpanded(true, source: "artifact-note")
        requestNoteEditorFocus()
    }

    func openHomeSection(_ section: HomeSection) {
        switch section {
        case .calendar: showCalendar()
        case .codex: showThreads()
        case .messages: showMessages()
        case .notes: showNotes()
        case .todos: showTodos()
        }
    }

    func openNote(_ note: LocalDocument) {
        if contentMode == .note, !flushCurrentNoteIfNeeded() { return }

        resetMeetingNotePresentation()
        dictation.cancel()
        isStartingDictation = false
        dictationTargetThreadID = nil
        hoveredThreadID = nil
        selectedCreationOption = .note
        editorTitle = note.title
        editorBody = note.body
        lastSavedDocument = note
        noteEditorDocumentID = note.id
        noteShowsRawMarkdown = false
        noteFindVisible = false
        noteSaveState = .saved
        statusMessage = nil
        contentMode = .note
        if MeetingNoteCodec.isMeetingNote(note.body) {
            let summary = meetingSummaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty, summary != MeetingNoteCodec.pendingSummary {
                meetingSummaryState = .ready
                selectedMeetingNoteTab = .summary
            } else {
                selectedMeetingNoteTab = .transcript
            }
        }
        setExpanded(true, source: "notes-list")
    }

    func reloadNotes() {
        noteReloadGeneration += 1
        let generation = noteReloadGeneration
        let store = documentStore

        noteReloadTask?.cancel()
        noteReloadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return NoteReloadResult.success(try store.documents(kind: .note))
                } catch {
                    return NoteReloadResult.failure(error.localizedDescription)
                }
            }.value

            guard let self,
                  !Task.isCancelled,
                  generation == self.noteReloadGeneration
            else { return }

            switch result {
            case let .success(documents):
                self.notes = documents
                self.noteListIssue = nil
            case let .failure(message):
                self.noteListIssue = message
            }
            self.resizeExpandedPanel()
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
            requestTodoComposerFocus()
        }
    }

    func openNewNote(source: String = "new-note") {
        guard !meetingCapture.isActive else {
            statusMessage = "Finish the meeting recording before starting another note"
            return
        }

        guard flushCurrentEditorIfNeeded() else { return }

        resetMeetingNotePresentation()
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

    func updateMeetingSummary(_ summaryMarkdown: String) {
        guard isShowingMeetingNote else { return }
        editorBody = MeetingNoteCodec.replacingSummary(
            in: editorBody,
            with: summaryMarkdown
        )
    }

    func finishMeetingSummaryAnimation(documentID: String) {
        guard meetingSummaryDocumentID == documentID,
              case .generating = meetingSummaryState
        else { return }
        meetingSummaryState = .ready
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
        resetMeetingNotePresentation()
        isStartingDictation = false
        selectedCreationOption = option
        statusMessage = nil
        editorTitle = ""
        editorBody = ""
        lastSavedDocument = nil
        noteSaveState = .idle
    }

    private func resetTodoDetailPresentation() {
        todoAutosaveTask?.cancel()
        todoAutosaveTask = nil
        todoEditorBaseTitle = ""
        todoEditorBaseNotes = nil
        todoEditorHasUnsavedChanges = false
        todoEditorHasRemoteConflict = false
        todoEditorTitle = ""
        todoEditorNotes = ""
        todoShowsRawMarkdown = false
        todoFindVisible = false
        todoSaveState = .idle
    }

    private func loadTodoDetailDraft(from todo: LocalTodo) {
        todoAutosaveTask?.cancel()
        todoAutosaveTask = nil
        todoEditorBaseTitle = todo.title
        todoEditorBaseNotes = todo.notes
        todoEditorHasUnsavedChanges = false
        todoEditorHasRemoteConflict = false
        todoEditorTitle = todo.title
        todoEditorNotes = todo.notes ?? ""
        todoSaveState = .saved
    }

    private var todoRemoteConflictMessage: String {
        "This todo changed on another device. Your edits are preserved; press Command-S to keep them."
    }

    private func normalizedTodoNotes(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    func requestTodoComposerFocus() {
        todoComposerFocusRequest += 1
    }

    func setTodoComposerFocused(_ focused: Bool) {
        todoComposerIsFocused = focused
    }

    func openTodo(_ id: UUID) {
        if let selectedTodoID, selectedTodoID != id {
            guard flushCurrentEditorIfNeeded() else { return }
        }
        guard let todo = todos.first(where: { $0.id == id }) else { return }

        loadTodoDetailDraft(from: todo)
        todoShowsRawMarkdown = false
        todoFindVisible = false
        statusMessage = nil
        contentMode = .todoDetail(id)
        setExpanded(true, source: "todo-detail")
        requestTodoEditorFocus()
    }

    func closeTodoDetail() {
        guard case .todoDetail = contentMode else { return }
        guard selectedTodo != nil else {
            resetTodoDetailPresentation()
            contentMode = .todo
            return
        }
        guard flushCurrentEditorIfNeeded(announceTodoFailure: true) else { return }

        contentMode = .todo
        statusMessage = nil
    }

    func requestTodoEditorFocus() {
        todoEditorFocusRequest += 1
        focusPanelForKeyboardNavigation()
        DispatchQueue.main.async { [weak self] in
            self?.focusPanelForKeyboardNavigation()
        }
    }

    func todoDetailDraftDidChange() {
        guard let todo = selectedTodo else { return }

        let title = todoEditorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = normalizedTodoNotes(todoEditorNotes)
        todoEditorHasUnsavedChanges = title != todoEditorBaseTitle
            || notes != todoEditorBaseNotes
        if !todoEditorHasUnsavedChanges {
            todoAutosaveTask?.cancel()
            todoAutosaveTask = nil
            todoEditorHasRemoteConflict = false
            todoSaveState = .saved
            statusMessage = nil
            return
        }

        if todoEditorHasRemoteConflict {
            todoAutosaveTask?.cancel()
            todoAutosaveTask = nil
            todoSaveState = .failed(todoRemoteConflictMessage)
            statusMessage = todoRemoteConflictMessage
            return
        }

        todoAutosaveTask?.cancel()
        guard !title.isEmpty else {
            todoSaveState = .idle
            return
        }

        let todoID = todo.id
        todoSaveState = .saving
        statusMessage = nil
        todoAutosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled,
                  let self,
                  self.selectedTodoID == todoID
            else { return }
            self.saveTodoDetail(announce: false)
            self.todoAutosaveTask = nil
        }
    }

    func toggleTodoFind() {
        todoFindVisible.toggle()
        if !todoFindVisible {
            requestTodoEditorFocus()
        }
    }

    func toggleTodoSourceMode() {
        todoShowsRawMarkdown.toggle()
        requestTodoEditorFocus()
    }

    @discardableResult
    func saveTodoDetail(
        announce: Bool = true,
        resolveConflict: Bool = false
    ) -> Bool {
        guard let id = selectedTodoID,
              let index = todos.firstIndex(where: { $0.id == id })
        else {
            let message = "This todo is no longer available."
            todoSaveState = .failed(message)
            statusMessage = announce ? message : nil
            return false
        }

        let title = todoEditorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            let message = "Add a title before leaving this todo."
            todoSaveState = .failed(message)
            statusMessage = announce ? message : nil
            return false
        }

        let notes = normalizedTodoNotes(todoEditorNotes)
        todoEditorHasUnsavedChanges = title != todoEditorBaseTitle
            || notes != todoEditorBaseNotes
        if !todoEditorHasUnsavedChanges {
            todoEditorHasRemoteConflict = false
            todoSaveState = .saved
            statusMessage = nil
            return true
        }

        if todoEditorHasRemoteConflict, !resolveConflict {
            todoSaveState = .failed(todoRemoteConflictMessage)
            statusMessage = announce ? todoRemoteConflictMessage : nil
            return false
        }

        guard todosAreAuthoritative else {
            let message = todoFileIssue
                ?? "Todos are read-only until the iCloud file finishes downloading."
            todoSaveState = .failed(message)
            statusMessage = announce ? message : nil
            return false
        }

        let originalTodo = todos[index]
        todos[index].title = title
        todos[index].notes = notes
        todos[index].updatedAt = Date()
        todoEditorTitle = title

        if saveTodos() {
            todoEditorBaseTitle = title
            todoEditorBaseNotes = notes
            todoEditorHasUnsavedChanges = false
            todoEditorHasRemoteConflict = false
            todoSaveState = .saved
            statusMessage = nil
            return true
        }

        todos[index] = originalTodo
        let message = statusMessage ?? "Could not save the todo."
        todoSaveState = .failed(message)
        statusMessage = announce ? message : nil
        return false
    }

    func deleteSelectedTodo() {
        guard let id = selectedTodoID else { return }
        guard deleteTodo(id) else {
            let message = statusMessage ?? "Could not delete the todo."
            todoSaveState = .failed(message)
            return
        }
        resetTodoDetailPresentation()
        contentMode = .todo
    }

    @discardableResult
    func addTodo(
        id: UUID = UUID(),
        dueDate: Date? = nil,
        listName: String? = nil
    ) -> UUID? {
        guard canEditTodos else { return nil }
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
            persistTodoMutation(todos[index])
            resizeExpandedPanel()
            return
        }

        todos[index].isCompleted = true
        todos[index].completedAt = Date()
        todos[index].updatedAt = Date()
        completingTodoIDs.insert(id)
        persistTodoMutation(todos[index])

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
        guard canEditTodos else { return }
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].isStarred.toggle()
        todos[index].updatedAt = Date()
        saveTodos()
    }

    func toggleTodoDueToday(_ id: UUID) {
        guard canEditTodos else { return }
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        let calendar = Calendar.autoupdatingCurrent
        if let dueDate = todos[index].dueDate, calendar.isDateInToday(dueDate) {
            setTodoDueDate(id, dueDate: nil)
        } else {
            setTodoDueDate(id, dueDate: Date())
        }
    }

    func setTodoDueDate(_ id: UUID, dueDate: Date?) {
        guard canEditTodos else { return }
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].dueDate = dueDate.map(Calendar.autoupdatingCurrent.startOfDay(for:))
        todos[index].updatedAt = Date()
        saveTodos()
    }

    func setTodoList(_ id: UUID, listName: String?) {
        guard canEditTodos else { return }
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

    @discardableResult
    func deleteTodo(_ id: UUID) -> Bool {
        guard canEditTodos else { return false }
        guard todos.contains(where: { $0.id == id }) else { return false }

        let nextTodos = todos.filter { $0.id != id }
        do {
            try todoStore.save(nextTodos)
        } catch {
            todosAreAuthoritative = false
            todoFileIssue = error.localizedDescription
            updateTodoStorageIssue()
            statusMessage = "Could not delete todo: \(error.localizedDescription)"
            return false
        }

        todoCompletionTasks[id]?.cancel()
        todoCompletionTasks[id] = nil
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9, blendDuration: 0.04)) {
            todos = nextTodos
            completingTodoIDs.remove(id)
            fadingTodoIDs.remove(id)
        }
        todosAreAuthoritative = true
        todoFileIssue = nil
        updateTodoStorageIssue()
        statusMessage = nil
        scheduleDesktopSync(fetchRemote: false)
        resizeExpandedPanel()
        return true
    }

    private var canEditTodos: Bool {
        guard todosAreAuthoritative else {
            statusMessage = todoFileIssue
                ?? "Todos are read-only until the iCloud file finishes downloading."
            return false
        }
        return true
    }

    @discardableResult
    private func persistTodoMutation(_ todo: LocalTodo) -> Bool {
        guard !todosAreAuthoritative else {
            return saveTodos()
        }

        // The canonical JSON file may be an iCloud placeholder. Never overwrite
        // it, but do durably stage this one user-authored edit in the sync store.
        Task { [weak self] in
            guard let self else { return }
            let state = await self.desktopSync.publishTodoMutation(todo)
            self.noteCount = state.noteCount
            self.syncedCalendarEvents = state.calendarEvents
            self.syncedArtifactMentions = state.artifactMentions
            self.cloudSyncStatus = state.status
            self.cloudSyncPendingRecordCount = state.pendingRecordCount
        }
        return true
    }

    @discardableResult
    private func saveTodos() -> Bool {
        do {
            try todoStore.save(todos)
            todosAreAuthoritative = true
            todoFileIssue = nil
            updateTodoStorageIssue()
            statusMessage = nil
            scheduleDesktopSync(fetchRemote: false)
            return true
        } catch {
            todosAreAuthoritative = false
            todoFileIssue = error.localizedDescription
            updateTodoStorageIssue()
            statusMessage = "Could not save todos: \(error.localizedDescription)"
            return false
        }
    }

    private func saveTodoListNames() {
        do {
            try todoStore.saveListNames(savedTodoListNames)
            todoListNamesAreAuthoritative = true
            todoListFileIssue = nil
            updateTodoStorageIssue()
            statusMessage = nil
            scheduleDesktopSync(fetchRemote: false)
        } catch {
            todoListNamesAreAuthoritative = false
            todoListFileIssue = error.localizedDescription
            updateTodoStorageIssue()
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
        guard flushCurrentEditorIfNeeded() else { return }
        resetMeetingNotePresentation()
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

    func navigateBack() {
        if case .todoDetail = contentMode {
            closeTodoDetail()
        } else {
            returnHome()
        }
    }

    var navigationBackHelp: String {
        if case .todoDetail = contentMode {
            return showingPastTodos ? "Back to past todos" : "Back to todos"
        }
        return "Back to Home"
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
            guard flushCurrentEditorIfNeeded() else { return }
            resetMeetingNotePresentation()
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
        case .todoDetail:
            todoAutosaveTask?.cancel()
            todoAutosaveTask = nil
            saveTodoDetail(resolveConflict: true)
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
                if SandboxAccessManager.shared.isSandboxed {
                    try await self.codexDesktopSender.startNewThread(prompt)
                    self.statusMessage = "New Codex task started"
                    self.isSubmitting = false
                    self.contentMode = .threads
                    self.editorBody = ""
                    self.scheduleThreadRefresh()
                    return
                }
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

    func openLocalNotesFolder() {
        let url = documentStore.folderURL(for: .note)
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

    private func startMeetingSummary(
        documentID: String,
        segments: [MeetingTranscriptSegment]
    ) {
        meetingSummaryTask?.cancel()
        meetingSummaryDocumentID = documentID
        meetingSummaryState = .generating

        let summarizer = meetingSummarizer
        meetingSummaryTask = Task { [weak self] in
            let summary = await Task.detached(priority: .userInitiated) {
                summarizer.summarize(segments)
            }.value
            try? await Task.sleep(for: .milliseconds(620))
            guard !Task.isCancelled,
                  let self,
                  self.meetingSummaryDocumentID == documentID,
                  self.lastSavedDocument?.id == documentID,
                  self.isShowingMeetingNote
            else { return }

            self.editorBody = MeetingNoteCodec.replacingSummary(
                in: self.editorBody,
                with: summary
            )
            if self.saveLocalDocument(kind: .note, announce: false) {
                self.meetingSummaryAnimationRevision += 1
            } else {
                self.meetingSummaryState = .failed(
                    self.statusMessage ?? "Could not save the meeting summary"
                )
            }
            self.meetingSummaryTask = nil
        }
    }

    private func resetMeetingNotePresentation() {
        meetingSummaryTask?.cancel()
        meetingSummaryTask = nil
        meetingSummaryDocumentID = nil
        meetingSummaryState = .idle
        meetingSummaryAnimationRevision = 0
        selectedMeetingNoteTab = .summary
    }

    private var hasDocumentContent: Bool {
        !editorTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !editorBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func flushCurrentEditorIfNeeded(
        announceTodoFailure: Bool = false
    ) -> Bool {
        switch contentMode {
        case .note:
            return flushCurrentNoteIfNeeded()
        case .todoDetail:
            guard selectedTodo != nil else {
                resetTodoDetailPresentation()
                return true
            }
            guard flushCurrentTodoIfNeeded(announce: announceTodoFailure) else { return false }
            resetTodoDetailPresentation()
            return true
        default:
            return true
        }
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

    private func flushCurrentTodoIfNeeded(announce: Bool = false) -> Bool {
        todoAutosaveTask?.cancel()
        todoAutosaveTask = nil
        return saveTodoDetail(announce: announce)
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
            if kind == .note {
                noteCount = documentStore.documentCount(for: .note)
                reloadNotes()
            }
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
            if contentMode == .messages, selectedMessageConversationID != nil {
                closeMessageConversation()
            } else {
                navigateBack()
            }
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

        let isMarkdownEditorMode: Bool
        switch contentMode {
        case .note, .todoDetail:
            isMarkdownEditorMode = true
        default:
            isMarkdownEditorMode = false
        }

        if isMarkdownEditorMode, modifiers.contains(.command) {
            let hasShift = modifiers.contains(.shift)
            let hasOption = modifiers.contains(.option)
            let editorIsFocused = noteEditorHasKeyboardFocus

            switch Int(keyCode) {
            case kVK_ANSI_S:
                saveCurrentDocument()
                return true
            case kVK_ANSI_F:
                if case .todoDetail = contentMode {
                    todoFindVisible = true
                } else {
                    noteFindVisible = true
                }
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
            case .note, .todoDetail:
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
        let screen = window?.screen ?? NSScreen.main
        let scale = max(1, window?.backingScaleFactor ?? screen?.backingScaleFactor ?? 1)
        let measuredClosedHeight = Self.pixelAligned(
            PanelMetrics.closedHeight(for: screen),
            scale: scale
        )

        switch presentation {
        case .notch:
            return targetFrame(
                size: NSSize(width: PanelMetrics.notchWidth, height: measuredClosedHeight)
            )
        case .compact:
            return targetFrame(
                size: NSSize(width: PanelMetrics.compactWidth, height: measuredClosedHeight)
            )
        case .expanded:
            return targetFrame(size: expandedSize)
        }
    }

    private func hiddenAnchorFrame() -> NSRect {
        return targetFrame(
            size: NSSize(width: 1, height: closedPanelHeight)
        )
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
    private func applyPinnedWindowFrame(
        _ proposedFrame: NSRect,
        display: Bool,
        synchronizeContent: Bool = true
    ) -> NSRect {
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
        if synchronizeContent {
            (window.contentView as? PanelHostingView)?.syncContourMask(for: appliedFrame.size)
        } else {
            (window.contentView as? PanelHostingView)?.syncAnimatedGeometry(for: appliedFrame.size)
        }
        if display {
            window.displayIfNeeded()
        }
        return appliedFrame
    }

    private func resizeExpandedPanel(animated: Bool = true) {
        guard !isPanelHidden, targetPresentation == .expanded, let window else { return }
        let frame = targetFrame(size: expandedSize)
        if frameDisplayLink != nil,
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

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
        resetMeetingNotePresentation()
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
        let startID = UUID()
        meetingCaptureStartID = startID
        meetingCaptureStartTask?.cancel()
        meetingCaptureStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.meetingCaptureStartID == startID {
                    self.meetingCaptureStartID = nil
                    self.meetingCaptureStartTask = nil
                }
            }
            do {
                try await self.meetingCapture.start(event: event)
                guard self.meetingCaptureStartID == startID else { return }
                self.statusMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard self.meetingCaptureStartID == startID else { return }
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
        guard meetingCapture.canStop else { return }
        let event = meetingCapture.currentEvent
        let startedAt = Date().addingTimeInterval(-meetingCapture.elapsed)
        let stopID = UUID()
        meetingCaptureStopID = stopID
        meetingCaptureStopTask = Task { @MainActor [weak self] in
            guard let self else { return true }
            defer {
                if self.meetingCaptureStopID == stopID {
                    self.meetingCaptureStopID = nil
                    self.meetingCaptureStopTask = nil
                }
            }
            let note: LocalDocument
            do {
                guard let stoppedNote = try await self.meetingCapture.stop() else {
                    return true
                }
                note = stoppedNote
            } catch {
                self.statusMessage = error.localizedDescription
                return false
            }

            let endedAt = Date()

            self.noteCount = self.documentStore.documentCount(for: .note)
            self.reloadNotes()
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
            self.startMeetingSummary(
                documentID: note.id,
                segments: self.meetingCapture.transcriptSegments
            )
            Task {
                await self.desktopSync.publishMeeting(
                    document: note,
                    event: event,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    transcriptSegments: self.meetingCapture.transcriptSegments
                )
            }
            return true
        }
    }

    var meetingCaptureNeedsFinalization: Bool {
        meetingCaptureStartTask != nil
            || meetingCaptureStopTask != nil
            || meetingCapture.state.isActive
    }

    func prepareMeetingCaptureForTermination() async -> Bool {
        if meetingCapture.isPreparing || meetingCaptureStartTask != nil {
            meetingCaptureStartID = nil
            meetingCaptureStartTask?.cancel()
            meetingCaptureStartTask = nil
            meetingCapture.cancelPreparation()
        }

        if let meetingCaptureStopTask {
            return await meetingCaptureStopTask.value
        }

        guard meetingCapture.canStop else {
            return meetingCapture.state != .stopping
        }
        do {
            _ = try await meetingCapture.stop()
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func cancelMeetingCapturePreparation() {
        guard meetingCapture.isPreparing else { return }
        meetingCaptureStartID = nil
        meetingCaptureStartTask?.cancel()
        meetingCaptureStartTask = nil
        meetingCapture.cancelPreparation()
        statusMessage = nil
    }

    func dismissMeetingCaptureFailure() {
        meetingCapture.dismissFailure()
        statusMessage = nil
    }

    func handleGlobalPanelEvent(_ event: NSEvent) {
        guard !isPanelHidden else { return }
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
        guard !isPanelHidden, targetPresentation == .expanded else { return }
        setCompact(source: "outside-click")
    }

    func isInsideNotchTrigger(_ point: NSPoint) -> Bool {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        guard let screen else { return false }

        let triggerWidth = PanelMetrics.notchWidth + 36
        let triggerHeight = PanelMetrics.closedHeight(for: screen) + 18
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
            showPanelFromHidden(
                to: meetingCapture.isActive ? .compact : .expanded,
                source: "option-space-restore",
                animated: true
            )
            return
        }

        toggle()
    }

    func togglePanelVisibility() {
        if isPanelHidden {
            let restoredPresentation = meetingCapture.isActive
                ? PanelPresentation.compact
                : lastVisiblePresentation
            showPanelFromHidden(
                to: restoredPresentation,
                source: "option-m-restore",
                animated: true
            )
        } else {
            hidePanelCompletely(animated: true)
        }
    }

    private func hidePanelCompletely(animated: Bool) {
        guard !isPanelHidden, let window else { return }
        lastVisiblePresentation = targetPresentation == .expanded ? .expanded : .compact
        isPanelHidden = true
        transitionID += 1
        let activeTransition = transitionID
        dictation.cancel()
        dictationTargetThreadID = nil
        hoveredThreadID = nil
        window.ignoresMouseEvents = true

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expanded = lastVisiblePresentation == .expanded
            compactVisible = lastVisiblePresentation == .compact
            contentVisible = lastVisiblePresentation == .expanded
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let completion: @MainActor @Sendable () -> Void = { [weak self, weak window] in
            guard let self,
                  let window,
                  self.isPanelHidden,
                  activeTransition == self.transitionID
            else {
                return
            }
            window.alphaValue = 0
            self.applyPinnedWindowFrame(self.hiddenAnchorFrame(), display: false)
            window.orderOut(nil)
        }

        guard animated else {
            cancelFrameAnimation()
            completion()
            return
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animateWindow(
                to: window.frame,
                duration: PanelMetrics.reducedMotionDuration,
                targetAlpha: 0,
                completion: completion
            )
        } else {
            window.alphaValue = 1
            animateWindow(
                to: hiddenAnchorFrame(),
                duration: PanelMetrics.transitionDuration,
                completion: completion
            )
        }
    }

    private func showPanelFromHidden(
        to requestedPresentation: PanelPresentation,
        source: String,
        animated: Bool
    ) {
        guard isPanelHidden, let window else { return }
        let nextPresentation = requestedPresentation == .notch ? .compact : requestedPresentation
        let wasFullyHidden = !window.isVisible || window.alphaValue <= 0.001

        isPanelHidden = false
        targetPresentation = nextPresentation
        transitionID += 1
        let activeTransition = transitionID

        if nextPresentation == .expanded {
            lastOpenSource = source
            calendarService.start()
        }

        cancelFrameAnimation()
        if wasFullyHidden {
            applyPinnedWindowFrame(hiddenAnchorFrame(), display: false)
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expanded = nextPresentation == .expanded
            compactVisible = nextPresentation == .compact
            contentVisible = nextPresentation == .expanded
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.ignoresMouseEvents = false

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            if wasFullyHidden {
                window.alphaValue = 0
            }
            applyPinnedWindowFrame(targetFrame(for: nextPresentation), display: false)
        } else {
            window.alphaValue = 1
        }
        window.orderFrontRegardless()

        let completion: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self,
                  !self.isPanelHidden,
                  activeTransition == self.transitionID
            else {
                return
            }
            if nextPresentation == .expanded {
                self.focusPanelForKeyboardNavigation()
            }
        }

        guard animated else {
            cancelFrameAnimation()
            window.alphaValue = 1
            applyPinnedWindowFrame(targetFrame(for: nextPresentation), display: true)
            completion()
            return
        }

        if reduceMotion {
            animateWindow(
                to: window.frame,
                duration: PanelMetrics.reducedMotionDuration,
                targetAlpha: 1,
                completion: completion
            )
        } else {
            animateWindow(
                to: targetFrame(for: nextPresentation),
                duration: PanelMetrics.transitionDuration,
                completion: completion
            )
        }

        if nextPresentation == .expanded {
            focusPanelForKeyboardNavigation()
        }
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
            showPanelFromHidden(
                to: nextPresentation,
                source: source,
                animated: animated
            )
            return
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

        guard animated else {
            cancelFrameAnimation()
            expanded = nextPresentation == .expanded
            compactVisible = nextPresentation == .compact
            contentVisible = nextPresentation == .expanded
            applyPinnedWindowFrame(targetFrame(for: nextPresentation), display: true)
            if nextPresentation == .expanded {
                focusPanelForKeyboardNavigation()
            }
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let contentAnimation: Animation? = reduceMotion
            ? nil
            : Animation.timingCurve(
                PanelMetrics.transitionX1,
                PanelMetrics.transitionY1,
                PanelMetrics.transitionX2,
                PanelMetrics.transitionY2,
                duration: PanelMetrics.contentTransitionDuration
            )

        switch nextPresentation {
        case .expanded:
            expanded = true
            contentVisible = false
            window.contentView?.layoutSubtreeIfNeeded()
            focusPanelForKeyboardNavigation()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.targetPresentation == .expanded else { return }
                self.focusPanelForKeyboardNavigation()
            }
        case .compact:
            var compactTransaction = Transaction()
            compactTransaction.disablesAnimations = true
            withTransaction(compactTransaction) {
                compactVisible = true
            }
            withAnimation(contentAnimation) {
                contentVisible = false
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        case .notch:
            withAnimation(contentAnimation) {
                compactVisible = false
                contentVisible = false
            }
        }

        if nextPresentation == .expanded {
            if reduceMotion {
                cancelFrameAnimation()
                applyPinnedWindowFrame(targetFrame(for: .expanded), display: true)
            } else {
                animateWindow(
                    to: targetFrame(for: .expanded),
                    duration: PanelMetrics.transitionDuration
                ) { [weak self] in
                    self?.focusPanelForKeyboardNavigation()
                }
            }

            // Start the surface crossfade in the same transaction as the window morph.
            // A delayed dispatch can be starved by main-thread work and leave a blank shell.
            withAnimation(contentAnimation) {
                compactVisible = false
                contentVisible = true
            }
            if reduceMotion {
                focusPanelForKeyboardNavigation()
            }
        } else if nextPresentation == .compact {
            let completion: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, activeTransition == self.transitionID else { return }
                self.expanded = false
                self.compactVisible = true
            }
            if reduceMotion {
                cancelFrameAnimation()
                applyPinnedWindowFrame(targetFrame(for: .compact), display: true)
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + PanelMetrics.contentTransitionDuration,
                    execute: completion
                )
            } else {
                animateWindow(
                    to: targetFrame(for: .compact),
                    duration: PanelMetrics.transitionDuration,
                    completion: completion
                )
            }
        } else {
            let completion: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, activeTransition == self.transitionID else { return }
                self.expanded = false
                self.compactVisible = false
            }
            if reduceMotion {
                cancelFrameAnimation()
                applyPinnedWindowFrame(targetFrame(for: .notch), display: true)
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + PanelMetrics.contentTransitionDuration,
                    execute: completion
                )
            } else {
                animateWindow(
                    to: targetFrame(for: .notch),
                    duration: PanelMetrics.transitionDuration,
                    completion: completion
                )
            }
        }
    }

    private func animateWindow(
        to frame: NSRect,
        duration: TimeInterval,
        targetAlpha: CGFloat? = nil,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let window else { return }
        cancelFrameAnimation()
        frameAnimationStartFrame = window.frame
        frameAnimationTargetFrame = frame
        frameAnimationStartedAt = CACurrentMediaTime()
        frameAnimationDuration = max(0.001, duration)
        frameAnimationStartAlpha = window.alphaValue
        frameAnimationTargetAlpha = targetAlpha ?? window.alphaValue
        frameAnimationCompletion = completion
        frameAnimationGeneration += 1
        frameAnimationDidAdvance = false

        if Self.framesMatch(frameAnimationStartFrame, frameAnimationTargetFrame),
           abs(frameAnimationStartAlpha - frameAnimationTargetAlpha) <= 0.001
        {
            applyPinnedWindowFrame(frameAnimationTargetFrame, display: true)
            window.alphaValue = frameAnimationTargetAlpha
            frameAnimationCompletion = nil
            completion?()
            return
        }

        let target = PanelDisplayLinkTarget { [weak self] displayLink in
            self?.advanceFrameAnimation(at: displayLink.timestamp)
        }
        let displayLink = window.displayLink(
            target: target,
            selector: #selector(PanelDisplayLinkTarget.displayLinkDidFire(_:))
        )
        frameDisplayLinkTarget = target
        frameDisplayLink = displayLink
        displayLink.add(to: .main, forMode: .common)

        let activeGeneration = frameAnimationGeneration
        let hardDeadline = frameAnimationDuration + 0.08
        frameAnimationWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 60_000_000)
            } catch {
                return
            }
            guard let self,
                  self.frameAnimationGeneration == activeGeneration,
                  self.frameDisplayLink != nil
            else {
                return
            }
            guard self.frameAnimationDidAdvance else {
                self.finishFrameAnimation()
                return
            }

            let remaining = max(0, hardDeadline - 0.06)
            do {
                try await Task.sleep(
                    nanoseconds: UInt64((remaining * 1_000_000_000).rounded())
                )
            } catch {
                return
            }
            guard self.frameAnimationGeneration == activeGeneration,
                  self.frameDisplayLink != nil
            else {
                return
            }
            self.finishFrameAnimation()
        }
    }

    private func advanceFrameAnimation(at timestamp: TimeInterval) {
        guard let window else {
            cancelFrameAnimation()
            return
        }
        frameAnimationDidAdvance = true

        let linearProgress = min(
            1,
            max(0, (timestamp - frameAnimationStartedAt) / frameAnimationDuration)
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
        let nextAlpha = frameAnimationStartAlpha
            + (frameAnimationTargetAlpha - frameAnimationStartAlpha) * easedProgress
        let visuallySettled = linearProgress >= 0.8
            && Self.framesMatch(nextFrame, frameAnimationTargetFrame)
            && abs(nextAlpha - frameAnimationTargetAlpha) <= 0.002

        if linearProgress >= 1 || visuallySettled {
            finishFrameAnimation()
            return
        }

        if !Self.framesMatch(window.frame, nextFrame) {
            applyPinnedWindowFrame(
                nextFrame,
                display: false,
                synchronizeContent: false
            )
        }
        if abs(window.alphaValue - nextAlpha) > 0.001 {
            window.alphaValue = nextAlpha
        }
    }

    private func finishFrameAnimation() {
        guard let window else {
            cancelFrameAnimation()
            return
        }
        let completion = frameAnimationCompletion
        frameDisplayLink?.invalidate()
        frameDisplayLink = nil
        frameDisplayLinkTarget = nil
        frameAnimationWatchdogTask?.cancel()
        frameAnimationWatchdogTask = nil
        frameAnimationCompletion = nil
        applyPinnedWindowFrame(
            frameAnimationTargetFrame,
            display: true
        )
        window.alphaValue = frameAnimationTargetAlpha
        completion?()
    }

    private func cancelFrameAnimation() {
        frameDisplayLink?.invalidate()
        frameDisplayLink = nil
        frameDisplayLinkTarget = nil
        frameAnimationWatchdogTask?.cancel()
        frameAnimationWatchdogTask = nil
        frameAnimationCompletion = nil
    }

    private static func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= 0.5
            && abs(lhs.origin.y - rhs.origin.y) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5
            && abs(lhs.height - rhs.height) <= 0.5
    }

    private static func panelAnimationProgress(_ progress: Double) -> CGFloat {
        let x1 = PanelMetrics.transitionX1
        let y1 = PanelMetrics.transitionY1
        let x2 = PanelMetrics.transitionX2
        let y2 = PanelMetrics.transitionY2
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
        guard let window else { return }
        updateClosedPanelHeight(for: window.screen ?? NSScreen.main)
        if isPanelHidden {
            cancelFrameAnimation()
            applyPinnedWindowFrame(hiddenAnchorFrame(), display: false)
            window.alphaValue = 0
            window.orderOut(nil)
        } else {
            applyPinnedWindowFrame(targetFrame(for: targetPresentation), display: true)
        }
    }

    private func updateClosedPanelHeight(for screen: NSScreen?) {
        let scale = max(1, window?.backingScaleFactor ?? screen?.backingScaleFactor ?? 1)
        let nextHeight = Self.pixelAligned(PanelMetrics.closedHeight(for: screen), scale: scale)
        if abs(closedPanelHeight - nextHeight) > 0.25 {
            closedPanelHeight = nextHeight
        }
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

        let curveCheckpoints: [(Double, CGFloat)] = [
            (0, 0),
            (0.25, 0.698_242_905),
            (0.5, 0.914_569_220),
            (0.75, 0.985_256_531),
            (1, 1),
        ]
        guard curveCheckpoints.allSatisfy({ progress, expected in
            abs(Self.panelAnimationProgress(progress) - expected) <= 0.000_001
        }) else {
            throw SmokeError("Panel motion must use cubic-bezier(0.165, 0.84, 0.44, 1).")
        }
        let curveSamples = (0 ... 40).map {
            Self.panelAnimationProgress(Double($0) / 40)
        }
        guard zip(curveSamples, curveSamples.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            throw SmokeError("Panel motion curve must remain monotonic.")
        }

        let expandedContour = PanelContourShape().path(
            in: CGRect(x: 0, y: 0, width: PanelMetrics.expandedWidth, height: 348)
        )
        let quarterCircleY = PanelMetrics.expandedRampWidth * (1 - 1 / sqrt(2))
        let quarterCircleX = PanelMetrics.expandedRampWidth / sqrt(2)
        guard expandedContour.contains(CGPoint(x: 10, y: 1)),
              expandedContour.contains(CGPoint(x: 1, y: 0.01)),
              expandedContour.contains(
                  CGPoint(x: PanelMetrics.expandedWidth - 1, y: 0.01)
              ),
              !expandedContour.contains(
                  CGPoint(x: quarterCircleX - 0.5, y: quarterCircleY)
              ),
              expandedContour.contains(
                  CGPoint(x: quarterCircleX + 0.5, y: quarterCircleY)
              ),
              !expandedContour.contains(CGPoint(x: 2, y: 36)),
              expandedContour.contains(CGPoint(x: 18, y: 36)),
              expandedContour.contains(CGPoint(x: PanelMetrics.expandedWidth - 10, y: 1)),
              !expandedContour.contains(CGPoint(x: PanelMetrics.expandedWidth - 2, y: 36)),
              expandedContour.contains(CGPoint(x: PanelMetrics.expandedWidth - 18, y: 36)),
              ThreadMode.plan.symbol == "lightbulb"
        else {
            throw SmokeError("Expected symmetric tangent quarter-circle ramps and the lightbulb plan glyph.")
        }

        for width in [1.0, 16.0, 32.0, PanelMetrics.compactWidth, PanelMetrics.expandedWidth] {
            let rect = CGRect(x: 0, y: 0, width: width, height: 48)
            let bounds = PanelContourShape().path(in: rect).boundingRect
            guard bounds.minX >= rect.minX - 0.01,
                  bounds.maxX <= rect.maxX + 0.01,
                  bounds.minY <= rect.minY,
                  bounds.maxY <= rect.maxY + 0.01
            else {
                throw SmokeError("Panel contour crossed itself while revealing at width \(width).")
            }
        }

        let openingRects = [
            CGRect(x: 0, y: 0, width: 230, height: 48),
            CGRect(
                x: 0,
                y: 0,
                width: compactSize.width,
                height: compactSize.height
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
                guard let window = self.window,
                      let screen = window.screen ?? NSScreen.main
                else {
                    throw SmokeError("Window or screen is unavailable.")
                }
                let screenFrame = screen.frame

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

                let expectedClosedHeight = PanelMetrics.closedHeight(for: screen)
                guard abs(collapsedFrame.height - expectedClosedHeight) <= 0.5,
                      abs(collapsedFrame.height - self.closedPanelHeight) <= 0.5,
                      abs(collapsedFrame.width - PanelMetrics.notchWidth) <= 0.5
                else {
                    throw SmokeError(
                        "Expected the collapsed panel to match the menu bar height. "
                            + "frame=\(collapsedFrame) expectedHeight=\(expectedClosedHeight)"
                    )
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

                // Keep these frame probes read-only. Rasterizing several screenshots on the
                // main run loop stalls SwiftUI's reveal transaction and changes the motion
                // being measured.
                for delay in [0.016, 0.045, 0.080] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard abs(window.frame.maxY - screenFrame.maxY) <= 0.01
                        else {
                            self.failSmoke(
                                "Panel detached at \(Int(delay * 1_000))ms during opening."
                            )
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
                          frame.width <= expectedExpandedSize.width + 0.5,
                          frame.height > collapsedFrame.height + 16,
                          frame.height <= expectedExpandedSize.height + 0.5,
                          abs(frame.maxY - screenFrame.maxY) <= 0.01,
                          (window.contentView as? PanelHostingView)?.renderedContourHasTopRamps() == true,
                          (window.contentView as? PanelHostingView)?.renderedTransitionHasVisibleContent(
                              centerExclusionWidth: PanelMetrics.notchWidth
                          ) == true
                    else {
                        self.failSmoke("Open animation lost its pinned frame or rendered ramps: \(frame).")
                        return
                    }
                    _ = try? self.capturePNG(named: "iagent-native-panel-opening.png")
                }

                // The intermediate raster capture above is intentionally exhaustive and can
                // briefly pause the smoke process's main run loop. Give the frame timer room
                // to settle after that diagnostic-only work.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
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

                guard self.todoComposerIsFocused else {
                    throw SmokeError("Expected Todo to open with its composer focused.")
                }
                let todoInputAutoFocusedURL = try self.capturePNG(
                    named: "iagent-todo-input-auto-focused.png"
                )
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
                let todoInputRefocusedURL = try self.capturePNG(
                    named: "iagent-todo-input-refocused.png"
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
                        notes: "Keep the release link here.\n\n- [ ] Confirm the archive",
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

                let detailTodoID = self.todos[2].id
                self.openTodo(detailTodoID)
                try await Task.sleep(for: .milliseconds(380))
                guard case let .todoDetail(openedTodoID) = self.contentMode,
                      openedTodoID == detailTodoID,
                      self.selectedTodoID == detailTodoID,
                      self.todoEditorTitle == "Archive the finished task",
                      self.todoEditorNotes.contains("Confirm the archive"),
                      let contentView = window.contentView,
                      let todoTextView = self.markdownEditorTextView(in: contentView),
                      todoTextView.string.contains("Confirm the archive"),
                      window.firstResponder === todoTextView,
                      abs(window.frame.height - self.expandedSize.height) <= 2
                else {
                    throw SmokeError("Expected the todo detail route to mount and focus its note-style editor.")
                }
                let todoDetailURL = try self.capturePNG(named: "iagent-todo-detail.png")

                self.todoEditorTitle = "Archive the release task"
                self.todoEditorNotes += "\n\nOwner: Platon"
                var persistedDetailTodo: LocalTodo?
                for _ in 0 ..< 80 {
                    try await Task.sleep(for: .milliseconds(25))
                    persistedDetailTodo = try self.todoStore.load().first { $0.id == detailTodoID }
                    if persistedDetailTodo?.title == "Archive the release task",
                       persistedDetailTodo?.notes?.contains("Owner: Platon") == true,
                       self.todoSaveState == .saved
                    {
                        break
                    }
                }
                guard persistedDetailTodo?.title == "Archive the release task",
                      persistedDetailTodo?.notes?.contains("Owner: Platon") == true,
                      self.todoSaveState == .saved,
                      self.handleKeyCode(53),
                      self.contentMode == .todo
                else {
                    throw SmokeError("Expected todo details to autosave and Escape to return to the todo list.")
                }
                try await Task.sleep(for: .milliseconds(300))

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

                self.editorBody = "First\nSecond"
                try await Task.sleep(for: .milliseconds(140))
                noteTextView.setSelectedRange(NSRange(location: 0, length: 12))
                NoteEditorFormatting.applyOrderedList()
                try await Task.sleep(for: .milliseconds(180))
                guard self.editorBody == "1. First\n1. Second",
                      noteTextView.selectedRange() == NSRange(location: 3, length: 15)
                else {
                    throw SmokeError("Expected numbered-list formatting to apply to every selected line.")
                }
                NoteEditorFormatting.applyOrderedList()
                try await Task.sleep(for: .milliseconds(180))
                guard self.editorBody == "First\nSecond",
                      noteTextView.selectedRange() == NSRange(location: 0, length: 12)
                else {
                    throw SmokeError(
                        "Expected a second numbered-list action to remove list formatting. "
                            + "body=\(self.editorBody.debugDescription) selection=\(noteTextView.selectedRange())"
                    )
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
                      self.editorTitle.isEmpty,
                      autosaved.title == "Untitled note",
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

                self.showNotes()
                try await Task.sleep(for: .milliseconds(220))
                guard self.contentMode == .notes,
                      self.panelTitle == "Notes",
                      self.notes.contains(where: { $0.id == saved.id })
                else {
                    throw SmokeError("Expected the Notes destination to list saved Markdown notes.")
                }
                let notesListURL = try self.capturePNG(named: "iagent-notes-list.png")

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
                let hostingView = window.contentView as? PanelHostingView
                let hasClosingRamps = hostingView?.renderedContourHasTopRamps() == true
                let hasClosingContent = hostingView?.renderedTransitionHasVisibleContent(
                    centerExclusionWidth: PanelMetrics.notchWidth
                ) == true
                _ = try? self.capturePNG(named: "iagent-native-panel-closing.png")
                guard frame.width > self.compactSize.width + 2,
                      frame.width < PanelMetrics.expandedWidth - 2,
                      frame.height > self.compactSize.height,
                      frame.height < restoredHomeFrame.height - 16,
                      self.expanded,
                      self.compactVisible,
                      abs(frame.maxY - screenFrame.maxY) <= 0.01,
                      hasClosingRamps,
                      hasClosingContent
                else {
                    throw SmokeError(
                        "Compact animation lost its pinned frame, rendered ramps, or content: "
                            + "frame=\(frame) compact=\(self.compactVisible) "
                            + "ramps=\(hasClosingRamps) content=\(hasClosingContent)."
                    )
                }

                try await Task.sleep(for: .milliseconds(340))
                let finalFrame = window.frame
                guard !self.expanded,
                      self.compactVisible,
                      self.contentMode == preservedCompactMode,
                      abs(finalFrame.width - self.compactSize.width) <= 2,
                      abs(finalFrame.height - self.compactSize.height) <= 2,
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
                      meetingNote.body.contains("## Summary"),
                      meetingNote.body.contains("## Transcript"),
                      meetingNote.body.contains("### Meeting"),
                      meetingNote.body.contains("### You"),
                      meetingNote.body.contains("revised milestones"),
                      Set(self.meetingCapture.transcriptSegments.map(\.source)) == [.meeting, .microphone],
                      FileManager.default.fileExists(atPath: meetingNote.fileURL.path)
                else {
                    throw SmokeError("Expected stopping capture to open the completed local meeting note.")
                }
                try await Task.sleep(for: .milliseconds(300))
                let meetingTranscribingURL = try self.capturePNG(
                    named: "iagent-meeting-summary-transcribing.png"
                )
                try await Task.sleep(for: .milliseconds(220))
                let meetingGeneratingURL = try self.capturePNG(
                    named: "iagent-meeting-summary-generating.png"
                )

                try await Task.sleep(for: .milliseconds(360))
                let meetingRevealURL = try self.capturePNG(
                    named: "iagent-meeting-summary-reveal.png"
                )

                for _ in 0 ..< 180
                    where self.meetingSummaryState != .ready
                {
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard self.meetingSummaryState == .ready,
                      self.editorBody.contains("## Meeting overview"),
                      self.editorBody.contains("## Next steps")
                else {
                    throw SmokeError("Expected the local meeting summary to finish and remain editable.")
                }
                try await Task.sleep(for: .milliseconds(260))
                let meetingNoteURL = try self.capturePNG(named: "iagent-meeting-summary.png")

                self.selectedMeetingNoteTab = .transcript
                try await Task.sleep(for: .milliseconds(220))
                guard self.meetingTranscriptSegments.count == 4,
                      self.selectedMeetingNoteTab == .transcript
                else {
                    throw SmokeError("Expected the Transcript tab to preserve both captured audio sources.")
                }
                let meetingTranscriptURL = try self.capturePNG(
                    named: "iagent-meeting-transcript.png"
                )

                self.showHome()
                self.setCompact(source: "smoke-meeting-reset", animated: false)

                self.openFromCompactSurface()
                try await Task.sleep(for: .milliseconds(100))
                let openingFrame = window.frame
                guard self.expanded,
                      !self.compactVisible,
                      openingFrame.width > self.compactSize.width + 2,
                      openingFrame.width < PanelMetrics.expandedWidth - 2,
                      openingFrame.height > self.compactSize.height,
                      openingFrame.height < self.expandedSize.height,
                      abs(openingFrame.maxY - screenFrame.maxY) <= 0.01,
                      (window.contentView as? PanelHostingView)?.renderedContourHasTopRamps() == true,
                      (window.contentView as? PanelHostingView)?.renderedTransitionHasVisibleContent(
                          centerExclusionWidth: PanelMetrics.notchWidth
                      ) == true
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

                func isCenteredAndTopPinned(_ frame: NSRect) -> Bool {
                    abs(frame.midX - screenFrame.midX) <= 0.5
                        && abs(frame.maxY - screenFrame.maxY) <= 0.5
                }

                @MainActor
                func isAtHiddenAnchor(_ frame: NSRect) -> Bool {
                    abs(frame.width - 1) <= 0.01
                }

                // Reverse a hide in flight. Retargeting must preserve the exact current
                // geometry and stale hide completions must never order the panel out.
                self.togglePanelVisibility()
                try await Task.sleep(for: .milliseconds(80))
                let interruptedHideFrame = window.frame
                guard self.isPanelHidden,
                      interruptedHideFrame.width > 0,
                      interruptedHideFrame.width < self.compactSize.width,
                      isCenteredAndTopPinned(interruptedHideFrame)
                else {
                    throw SmokeError("Option-M did not begin a centered compact-to-notch collapse.")
                }
                self.togglePanelVisibility()
                let reversalFrame = window.frame
                guard abs(reversalFrame.width - interruptedHideFrame.width) <= 1,
                      !self.isPanelHidden
                else {
                    throw SmokeError("Reversing Option-M restarted instead of retargeting current geometry.")
                }
                try await Task.sleep(for: .milliseconds(330))
                guard window.isVisible,
                      !self.isPanelHidden,
                      !self.expanded,
                      self.compactVisible,
                      abs(window.frame.width - self.compactSize.width) <= 1,
                      isCenteredAndTopPinned(window.frame)
                else {
                    throw SmokeError("Interrupted Option-M did not settle back to compact.")
                }

                // A completed hide collapses to one AppKit point at the notch before ordering out.
                self.togglePanelVisibility()
                try await Task.sleep(for: .milliseconds(330))
                guard self.isPanelHidden,
                      !window.isVisible,
                      window.alphaValue <= 0.001,
                      isAtHiddenAnchor(window.frame),
                      isCenteredAndTopPinned(window.frame)
                else {
                    throw SmokeError("Option-M did not finish at the centered one-point notch anchor.")
                }

                // Option-M restores the last visible state directly from the hidden anchor.
                self.togglePanelVisibility()
                guard window.isVisible,
                      !self.isPanelHidden,
                      !self.expanded,
                      self.compactVisible,
                      isAtHiddenAnchor(window.frame)
                else {
                    throw SmokeError("Hidden Option-M flashed a settled compact frame before revealing.")
                }
                try await Task.sleep(for: .milliseconds(80))
                let compactRevealFrame = window.frame
                guard compactRevealFrame.width > 0,
                      compactRevealFrame.width < self.compactSize.width,
                      isCenteredAndTopPinned(compactRevealFrame)
                else {
                    throw SmokeError("Hidden Option-M did not reveal compact from the notch center.")
                }
                try await Task.sleep(for: .milliseconds(280))
                guard abs(window.frame.width - self.compactSize.width) <= 1 else {
                    throw SmokeError("Option-M compact restoration did not settle.")
                }

                // Preserve expanded state through a complete Option-M hide/show cycle.
                let preservedVisibilityMode = self.contentMode
                self.setExpanded(true, source: "smoke-visibility-expanded", animated: false)
                let visibilityExpandedSize = self.expandedSize
                self.togglePanelVisibility()
                try await Task.sleep(for: .milliseconds(330))
                guard self.isPanelHidden,
                      !window.isVisible,
                      isAtHiddenAnchor(window.frame)
                else {
                    throw SmokeError("Expanded Option-M did not collapse completely.")
                }
                self.togglePanelVisibility()
                guard self.expanded,
                      !self.compactVisible,
                      self.contentVisible,
                      self.contentMode == preservedVisibilityMode,
                      isAtHiddenAnchor(window.frame)
                else {
                    throw SmokeError("Option-M did not restore expanded content directly from the notch anchor.")
                }
                try await Task.sleep(for: .milliseconds(360))
                guard abs(window.frame.width - visibilityExpandedSize.width) <= 1,
                      abs(window.frame.height - visibilityExpandedSize.height) <= 1,
                      isCenteredAndTopPinned(window.frame)
                else {
                    throw SmokeError("Option-M expanded restoration did not settle.")
                }

                // Reproduce the reported path: hide compact, then use Option-Space. The
                // expanded surface must be mounted while the window is still at the hidden anchor.
                self.setCompact(source: "smoke-option-space-hidden", animated: false)
                self.togglePanelVisibility()
                try await Task.sleep(for: .milliseconds(330))
                self.toggleFromGlobalHotKey()
                guard self.expanded,
                      !self.compactVisible,
                      self.contentVisible,
                      window.isVisible,
                      isAtHiddenAnchor(window.frame)
                else {
                    throw SmokeError("Hidden Option-Space flashed compact before mounting expanded.")
                }
                try await Task.sleep(for: .milliseconds(80))
                let optionSpaceRevealFrame = window.frame
                guard optionSpaceRevealFrame.width > 0,
                      optionSpaceRevealFrame.width < PanelMetrics.expandedWidth,
                      optionSpaceRevealFrame.height > self.closedPanelHeight,
                      optionSpaceRevealFrame.height < self.expandedSize.height,
                      isCenteredAndTopPinned(optionSpaceRevealFrame)
                else {
                    throw SmokeError("Hidden Option-Space did not animate out of the notch.")
                }
                try await Task.sleep(for: .milliseconds(280))
                guard self.expanded,
                      !self.isPanelHidden,
                      abs(window.frame.width - self.expandedSize.width) <= 1,
                      abs(window.frame.height - self.expandedSize.height) <= 1
                else {
                    throw SmokeError("Hidden Option-Space did not settle expanded.")
                }
                self.setCompact(source: "smoke-finish", animated: false)

                print("[smoke] nativeNotch=\(Int(collapsedFrame.width))x\(Int(collapsedFrame.height)) top=\(Int(collapsedFrame.maxY))")
                print("[smoke] visibilityMotion=compact/expanded/interrupt/option-space one-point-anchor")
                print("[smoke] nativeExpanded=\(Int(expandedFrame.width))x\(Int(expandedFrame.height)) top=\(Int(expandedFrame.maxY)) source=\(self.lastOpenSource) wheelEvent=\(wheelEventReachedHandler)")
                print("[smoke] dynamicHeights=threads:\(Int(restoredThreadFrame.height)) home:\(Int(homeFrame.height)) calendar:\(Int(calendarFrame.height)) create:\(Int(createFrame.height)) todo:\(Int(todoFrame.height)) focus:\(Int(focusFrame.height)) note:\(Int(noteFrame.height))")
                print("[smoke] realRootThreads=\(self.threads.count) activity24h=\(self.activityThreads.count) projects=\(self.projectSections.count) running=\(self.activeCount) keyboard=up/down/enter/escape database=\(self.databasePath)")
                print("[smoke] pauseTranscript=\(accumulatedSpeech.text)")
                print("[smoke] localNote=\(saved.fileURL.path)")
                print("[smoke] collapsedScreenshot=\(collapsedURL.path)")
                print("[smoke] compactScreenshot=\(compactURL.path)")
                print("[smoke] meetingErrorScreenshot=\(meetingErrorURL.path)")
                print("[smoke] meetingListeningScreenshot=\(meetingListeningURL.path)")
                print("[smoke] meetingTranscribingScreenshot=\(meetingTranscribingURL.path)")
                print("[smoke] meetingGeneratingScreenshot=\(meetingGeneratingURL.path)")
                print("[smoke] meetingRevealScreenshot=\(meetingRevealURL.path)")
                print("[smoke] meetingNoteScreenshot=\(meetingNoteURL.path)")
                print("[smoke] meetingTranscriptScreenshot=\(meetingTranscriptURL.path)")
                print("[smoke] openingScreenshot=\(openingURL.path)")
                print("[smoke] expandedScreenshot=\(expandedURL.path)")
                print("[smoke] projectRowsScreenshot=\(projectRowsURL.path)")
                print("[smoke] dynamicResizeScreenshot=\(dynamicResizeURL.path)")
                print("[smoke] createScreenshot=\(createURL.path)")
                print("[smoke] standaloneMeetingScreenshot=\(standaloneMeetingURL.path)")
                print("[smoke] createBottomScreenshot=\(createBottomURL.path)")
                print("[smoke] todoInputAutoFocusedScreenshot=\(todoInputAutoFocusedURL.path)")
                print("[smoke] todoInputRefocusedScreenshot=\(todoInputRefocusedURL.path)")
                print("[smoke] todoInputFocusedScreenshot=\(todoInputFocusedURL.path)")
                print("[smoke] todoAddTransitionScreenshot=\(todoAddTransitionURL.path)")
                print("[smoke] todoAddSettledScreenshot=\(todoAddSettledURL.path)")
                print("[smoke] todoPinchScreenshot=\(todoPinchURL.path)")
                print("[smoke] todoReleaseScreenshot=\(todoReleaseURL.path)")
                print("[smoke] todoPullScreenshot=\(todoPullURL.path)")
                print("[smoke] todoStrikeScreenshot=\(todoStrikeURL.path)")
                print("[smoke] todoFadeScreenshot=\(todoFadeURL.path)")
                print("[smoke] todoScreenshot=\(todoURL.path)")
                print("[smoke] todoDetailScreenshot=\(todoDetailURL.path)")
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
                print("[smoke] notesListScreenshot=\(notesListURL.path)")
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
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .allowsHitTesting(false)

                if controller.expanded {
                    ExpandedPanel(controller: controller)
                        .frame(
                            width: controller.expandedSize.width,
                            height: controller.expandedSize.height,
                            alignment: .top
                        )
                        .position(
                            x: geometry.size.width / 2,
                            y: controller.expandedSize.height / 2
                        )
                        .transition(.opacity)
                }

                CompactPanel(controller: controller)
                    .frame(width: controller.compactSize.width, height: controller.compactSize.height)
                    .position(
                        x: geometry.size.width / 2,
                        y: controller.compactSize.height / 2
                    )
                    .opacity(controller.compactVisible ? 1 : 0)
                    .allowsHitTesting(controller.compactVisible)
                    .accessibilityHidden(!controller.compactVisible)
                    .zIndex(1)

                NotchTrigger(controller: controller)
                    .frame(width: controller.notchSize.width, height: controller.notchSize.height)
                    .position(
                        x: geometry.size.width / 2,
                        y: controller.notchSize.height / 2
                    )
                    .opacity(notchVisible ? 1 : 0)
                    .allowsHitTesting(notchVisible)
                    .accessibilityHidden(!notchVisible)
                    .zIndex(1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var notchVisible: Bool {
        !controller.compactVisible && (!controller.expanded || !controller.contentVisible)
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
        .frame(width: controller.compactSize.width, height: controller.compactSize.height)
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

                compactMessagesButton

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

            HStack(spacing: compactEventActionSpacing) {
                if let event = controller.compactCalendarEvent {
                    compactEvent(event)
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(spacing: compactIconActionSpacing) {
                    Button {
                        controller.showCreationMenu()
                        controller.setExpanded(true, source: "compact-create")
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(HeaderIconButtonStyle(isActive: false, size: compactControlHeight))
                    .help("Create")

                    Button {
                        controller.setExpanded(true, source: "compact-expand")
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(HeaderIconButtonStyle(isActive: false, size: compactControlHeight))
                    .help("Expand panel")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, PanelMetrics.expandedRampWidth + 20)
        .padding(.trailing, compactActionTrailingInset)
        .frame(height: controller.closedPanelHeight)
    }

    private var meetingStatus: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(meetingStatusLabel)
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
            .frame(width: compactSideWidth, height: controller.closedPanelHeight)
            .clipped()

            Color.clear
                .frame(width: PanelMetrics.notchWidth)
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
                    .frame(width: 52, height: 18)

                Button {
                    if meetingCapture.isPreparing {
                        controller.cancelMeetingCapturePreparation()
                    } else if meetingCapture.canStop {
                        controller.stopMeetingCapture()
                    } else {
                        controller.dismissMeetingCaptureFailure()
                    }
                } label: {
                    meetingStatusActionIcon
                }
                .buttonStyle(HeaderIconButtonStyle(isActive: false, size: compactControlHeight))
                .disabled(meetingCapture.state == .stopping)
                .help(meetingStatusActionHelp)
            }
            .padding(.leading, 8)
            .padding(.trailing, PanelMetrics.expandedRampWidth + 10)
            .frame(width: compactSideWidth, height: controller.closedPanelHeight)
        }
        .frame(width: PanelMetrics.compactWidth)
        .frame(height: controller.closedPanelHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(meetingStatusAccessibilityLabel)
    }

    private var meetingStatusLabel: String {
        switch meetingCapture.state {
        case .preparing: "PREP"
        case .listening: meetingCapture.latestSource.compactLabel.uppercased()
        case .stopping: "SAVE"
        case .failed: "ERROR"
        case .idle: "IDLE"
        }
    }

    @ViewBuilder
    private var meetingStatusActionIcon: some View {
        switch meetingCapture.state {
        case .preparing:
            ProgressView()
                .controlSize(.mini)
                .tint(.white.opacity(0.62))
                .frame(width: 14, height: 14)
        case .listening:
            Circle()
                .fill(Color.agentCoral)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.28), lineWidth: 0.5)
                }
                .frame(width: 14, height: 14)
        case .stopping:
            ProgressView()
                .controlSize(.mini)
                .tint(.white.opacity(0.62))
                .frame(width: 14, height: 14)
        case .failed, .idle:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 14, height: 14)
        }
    }

    private var meetingStatusActionHelp: String {
        switch meetingCapture.state {
        case .preparing: "Cancel meeting recorder setup"
        case .listening: "Stop and open meeting note"
        case .stopping: "Finishing meeting note"
        case .failed: "Dismiss recording error"
        case .idle: "Meeting recorder"
        }
    }

    private var meetingStatusAccessibilityLabel: String {
        switch meetingCapture.state {
        case .preparing:
            "Preparing to record \(meetingCapture.currentEvent?.title ?? "meeting")"
        case .listening:
            "Recording \(meetingCapture.currentEvent?.title ?? "meeting")"
        case .stopping:
            "Finishing meeting recording"
        case .failed:
            "Meeting recording error"
        case .idle:
            "Meeting recorder"
        }
    }

    private var compactSideWidth: CGFloat {
        (PanelMetrics.compactWidth - PanelMetrics.notchWidth) / 2
    }

    private var compactControlHeight: CGFloat {
        min(28, max(20, controller.closedPanelHeight - 4))
    }

    private var compactActionButtonInset: CGFloat {
        (compactControlHeight - 14) / 2
    }

    // Equalize visible glyph gaps while preserving full 28pt button targets.
    private var compactActionVisibleGap: CGFloat { 21 }

    private var compactEventActionSpacing: CGFloat {
        max(0, compactActionVisibleGap - compactActionButtonInset)
    }

    private var compactIconActionSpacing: CGFloat {
        max(0, compactActionVisibleGap - 2 * compactActionButtonInset)
    }

    private var compactActionTrailingInset: CGFloat {
        PanelMetrics.expandedRampWidth + 20 - compactActionButtonInset
    }

    private func compactEvent(_ event: CalendarEventItem) -> some View {
        let timeText = compactEventTimeText(event)

        return HStack(spacing: 1) {
            if !event.isAllDay {
                Button {
                    controller.startMeetingCapture(event)
                } label: {
                    Circle()
                        .fill(Color.agentCoral)
                        .frame(width: 7, height: 7)
                        .frame(width: 12, height: compactControlHeight)
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
                    timeText,
                    fontSize: timeText.count > 5 ? 9 : 10,
                    weight: .medium,
                    color: .white.opacity(0.44),
                    alignment: .trailing,
                    lineHeight: 14
                )
                .frame(height: compactControlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(event.title)
        }
    }

    private func compactEventTimeText(_ event: CalendarEventItem) -> String {
        guard !event.isAllDay else { return "All" }

        let hourFormat = DateFormatter.dateFormat(
            fromTemplate: "j",
            options: 0,
            locale: .current
        ) ?? ""
        guard hourFormat.contains("a") else { return event.timeText() }

        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.hour, .minute],
            from: event.startDate
        )
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let compactHour = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d%@", compactHour, minute, hour < 12 ? "a" : "p")
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
            .frame(height: compactControlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var compactMessagesButton: some View {
        let unread = controller.unreadMessageConversationCount
        return compactMetric(
            count: unread,
            help: unread == 0 ? "Messages — all read" : "Messages — \(unread) unread",
            action: {
                controller.showMessages()
                controller.setExpanded(true, source: "compact-messages")
            }
        ) {
            MessageCircleIcon(size: 13, color: .white.opacity(0.76))
                .frame(width: 14, height: 14)
        }
        .accessibilityLabel("Messages")
        .accessibilityValue(unread == 0 ? "All read" : "\(unread) unread")
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
        .frame(width: PanelMetrics.notchWidth, height: controller.closedPanelHeight)
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

                ZStack(alignment: .top) {
                    panelContent
                        .id(controller.contentMode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.opacity.animation(screenTransitionAnimation))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.leading, PanelMetrics.expandedRampWidth)
            .padding(.trailing, PanelMetrics.expandedRampWidth)
            .opacity(controller.contentVisible ? 1 : 0)

            CameraDot()
                .frame(width: 11, height: 11)
                .padding(.top, 5)
                .opacity(controller.contentVisible ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var screenTransitionAnimation: Animation {
        .timingCurve(
            PanelMetrics.transitionX1,
            PanelMetrics.transitionY1,
            PanelMetrics.transitionX2,
            PanelMetrics.transitionY2,
            duration: PanelMetrics.contentTransitionDuration
        )
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
        case .notes:
            NotesListView(controller: controller)
        case .messages:
            MessageInboxView(
                controller: controller,
                filter: controller.messageInboxFilter
            )
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
        case .todoDetail:
            TodoDetailView(controller: controller)
        case .calendar:
            CalendarDayView(controller: controller)
        }
    }

    private var header: some View {
        PanelPageHeader(
            title: controller.panelTitle,
            titleRole: headerTitleRole,
            placement: controller.contentMode == .home ? .root : .navigation,
            onBack: headerBackAction,
            backHelp: controller.navigationBackHelp
        ) {
            if controller.contentMode == .messages {
                messageHeaderFilterButton(
                    filter: .awaitingReply,
                    count: controller.awaitingReplyConversationCount,
                    label: "awaiting",
                    color: .agentAmber
                )

                messageHeaderFilterButton(
                    filter: .unread,
                    count: controller.unreadMessageConversationCount,
                    label: controller.unreadMessageConversationCount == 0 ? "all read" : "unread",
                    color: .agentCoral,
                    showsCount: controller.unreadMessageConversationCount > 0
                )

                Button {
                    controller.syncNow()
                } label: {
                    MessageSyncHealthView(
                        isSyncing: controller.isMessageInboxSyncing,
                        status: controller.cloudSyncStatus,
                        access: controller.messageProviderAccess
                    )
                }
                .buttonStyle(.plain)
                .panelTooltip(text: controller.cloudSyncHelpText)
                .accessibilityLabel("Sync messages. \(controller.cloudSyncHelpText)")
            } else {
                Button {
                    controller.syncNow()
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "icloud")

                        Circle()
                            .fill(syncStatusColor)
                            .frame(width: 5, height: 5)
                            .overlay {
                                Circle().stroke(Color.black.opacity(0.7), lineWidth: 1)
                            }
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(HeaderIconButtonStyle(isActive: false))
                .help(controller.cloudSyncHelpText)
                .accessibilityLabel(controller.cloudSyncHelpText)
            }
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

            if controller.contentMode == .notes {
                Button {
                    controller.openNewNote(source: "notes-header")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(HeaderIconButtonStyle(isActive: false))
                .help("New note")
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
    }

    private var headerBackAction: (() -> Void)? {
        guard controller.contentMode != .home,
              !(controller.contentMode == .messages
                && controller.selectedMessageConversationID != nil)
        else {
            return nil
        }

        return {
            if controller.contentMode == .messages {
                controller.navigateBackFromMessages()
            } else {
                controller.navigateBack()
            }
        }
    }

    private var headerTitleRole: PanelPageTitleRole {
        switch controller.contentMode {
        case .home:
            .home
        case .messages:
            .messages
        default:
            .page
        }
    }

    private func messageHeaderFilterButton(
        filter: MessageInboxFilter,
        count: Int,
        label: String,
        color: Color,
        showsCount: Bool = true
    ) -> some View {
        let isActive = controller.messageInboxFilter == filter
        return Button {
            controller.toggleMessageInboxFilter(filter)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(count > 0 ? color : Color.white.opacity(0.24))
                    .frame(width: 6, height: 6)

                Text(showsCount ? "\(count) \(label)" : label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(isActive ? 0.72 : 0.52))
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(
                isActive ? Color.white.opacity(0.07) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isActive ? "Show all messages" : "Show \(label) messages")
        .accessibilityLabel(
            filter == .awaitingReply
                ? "\(count) conversations awaiting your reply"
                : "\(count) unread conversations"
        )
        .accessibilityValue(isActive ? "Selected" : "Not selected")
    }

    private var syncStatusColor: Color {
        switch controller.cloudSyncStatus.phase {
        case .idle:
            controller.cloudSyncPendingRecordCount == 0 ? .agentGreen : .agentAmber
        case .syncing:
            .agentBlue
        case .offline:
            .white.opacity(0.34)
        case .accountUnavailable:
            .agentAmber
        case .failed:
            .agentCoral
        }
    }

    private var headerTitleFont: Font {
        if controller.contentMode == .home {
            return .system(size: 10, weight: .semibold)
        }
        return .system(size: 12, weight: .semibold)
    }

    private var headerTitleColor: Color {
        controller.contentMode == .home ? .white.opacity(0.56) : .white.opacity(0.96)
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
            .padding(.horizontal, PanelPageLayout.contentInset)
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
        .padding(.horizontal, PanelPageLayout.contentInset)
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
        .padding(
            .leading,
            placement == .project ? 50 : PanelPageLayout.contentInset
        )
        .padding(.trailing, PanelPageLayout.contentInset)
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
        let widthRange = PanelMetrics.expandedWidth - PanelMetrics.notchWidth
        let expansion = min(
            1,
            max(0, (rect.width - PanelMetrics.notchWidth) / widthRange)
        )
        let rampRadius = min(
            PanelMetrics.expandedRampWidth,
            PanelMetrics.expandedRampDepth,
            rect.width / 2,
            rect.height / 2
        )
        let bottomRadius = min(
            20 + 4 * expansion,
            rect.width / 2,
            max(0, rect.height - rampRadius)
        )
        let maskTopY = rect.minY - PanelMetrics.topMaskOverscan
        let curveTopY = rect.minY
        let rampBottomY = curveTopY + rampRadius
        let leftBodyX = rect.minX + rampRadius
        let rightBodyX = rect.maxX - rampRadius
        // Standard cubic approximation for a circle quadrant (maximum error < 0.03%).
        let quarterCircleKappa: CGFloat = 0.552_284_749_8
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: maskTopY))
        path.addLine(to: CGPoint(x: rect.maxX, y: maskTopY))
        path.addLine(to: CGPoint(x: rect.maxX, y: curveTopY))

        path.addCurve(
            to: CGPoint(x: rightBodyX, y: rampBottomY),
            control1: CGPoint(
                x: rect.maxX - rampRadius * quarterCircleKappa,
                y: curveTopY
            ),
            control2: CGPoint(
                x: rightBodyX,
                y: rampBottomY - rampRadius * quarterCircleKappa
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
        path.addLine(to: CGPoint(x: leftBodyX, y: rampBottomY))

        path.addCurve(
            to: CGPoint(x: rect.minX, y: curveTopY),
            control1: CGPoint(
                x: leftBodyX,
                y: rampBottomY - rampRadius * quarterCircleKappa
            ),
            control2: CGPoint(
                x: rect.minX + rampRadius * quarterCircleKappa,
                y: curveTopY
            )
        )
        path.addLine(to: CGPoint(x: rect.minX, y: maskTopY))

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
    private var controller: PanelController!
    private var panelWindow: PanelWindow?
    private var screenObserver: NSObjectProtocol?
    private var globalNotchMonitor: Any?
    private var keyboardMonitor: Any?
    private var panelHotKey: GlobalHotKey?
    private var dictationHotKey: GlobalHotKey?
    private var newNoteHotKey: GlobalHotKey?
    private var visibilityHotKey: GlobalHotKey?
    private var automaticTerminationDisabled = false
    private var terminationTask: Task<Void, Never>?
    private var pendingArtifactLinks: [URL] = []

    private static let automaticTerminationReason =
        "iAgent global shortcuts must remain available while its panel is hidden."

    func application(_: NSApplication, open urls: [URL]) {
        guard let controller else {
            pendingArtifactLinks.append(contentsOf: urls)
            return
        }
        for url in urls {
            controller.openArtifactLink(url)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        let isSmokeTest = CommandLine.arguments.contains("--smoke-test")
        let isCalendarLiveTest = CommandLine.arguments.contains("--calendar-live-test")
        let isVisibilityLifecycleTest = CommandLine.arguments.contains(
            "--visibility-lifecycle-test"
        )
        if deferToExistingInstanceIfNeeded(
            isTestRun: isSmokeTest || isCalendarLiveTest || isVisibilityLifecycleTest
        ) {
            return
        }
        ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
        automaticTerminationDisabled = true
        NSApp.setActivationPolicy(isCalendarLiveTest ? .regular : .accessory)
        if !isSmokeTest && !isCalendarLiveTest && !isVisibilityLifecycleTest {
            SandboxAccessManager.shared.prepareForLaunch()
        }
        controller = PanelController()
        if isCalendarLiveTest {
            NSApp.activate(ignoringOtherApps: true)
        }

        let panel = PanelWindow(
            contentRect: controller.targetFrame(expanded: false),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panelWindow = panel

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
        panel.isReleasedWhenClosed = false

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
        if !pendingArtifactLinks.isEmpty {
            let links = pendingArtifactLinks
            pendingArtifactLinks.removeAll()
            for url in links {
                controller.openArtifactLink(url)
            }
        }

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
            controller?.togglePanelVisibility()
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

        if !isSmokeTest && !isCalendarLiveTest && !isVisibilityLifecycleTest {
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
        } else if isVisibilityLifecycleTest {
            runVisibilityLifecycleTest(expectedPanelIdentifier: ObjectIdentifier(panel))
        }
    }

    private func runVisibilityLifecycleTest(expectedPanelIdentifier: ObjectIdentifier) {
        controller.setCompact(source: "visibility-lifecycle-setup", animated: false)
        let screenFrame = (panelWindow?.screen ?? NSScreen.main)?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        Task { @MainActor [weak self] in
            guard let self else {
                fputs("Visibility lifecycle failed: AppDelegate was released.\n", stderr)
                exit(1)
            }

            @MainActor
            func panel(_ phase: String) throws -> PanelWindow {
                guard let panel = self.panelWindow,
                      ObjectIdentifier(panel) == expectedPanelIdentifier,
                      self.controller.window === panel
                else {
                    throw SmokeError("Panel ownership was lost during \(phase).")
                }
                return panel
            }

            func isPinned(_ frame: NSRect) -> Bool {
                abs(frame.midX - screenFrame.midX) <= 0.5
                    && abs(frame.maxY - screenFrame.maxY) <= 0.5
            }

            @MainActor
            func isAnchor(_ panel: PanelWindow) -> Bool {
                abs(panel.frame.width - 1) <= 0.01
            }

            do {
                self.controller.togglePanelVisibility()
                try await Task.sleep(for: .milliseconds(360))
                do {
                    let hiddenPanel = try panel("compact hide")
                    guard self.controller.isPanelHidden,
                          !hiddenPanel.isVisible,
                          hiddenPanel.alphaValue <= 0.001,
                          hiddenPanel.ignoresMouseEvents,
                          isAnchor(hiddenPanel),
                          isPinned(hiddenPanel.frame)
                    else {
                        throw SmokeError(
                            "Compact did not finish hidden at the notch anchor: "
                                + "hidden=\(self.controller.isPanelHidden) "
                                + "visible=\(hiddenPanel.isVisible) "
                                + "alpha=\(hiddenPanel.alphaValue) "
                                + "ignoresMouse=\(hiddenPanel.ignoresMouseEvents) "
                                + "frame=\(hiddenPanel.frame) scale=\(hiddenPanel.backingScaleFactor)."
                        )
                    }
                }

                // Leave the production-style panel fully ordered out long enough to expose
                // weak-window and automatic-termination regressions before the second press.
                try await Task.sleep(for: .milliseconds(850))
                _ = try panel("compact hidden dwell")

                self.controller.togglePanelVisibility()
                do {
                    let revealSeed = try panel("compact restore seed")
                    guard !self.controller.isPanelHidden,
                          revealSeed.isVisible,
                          revealSeed.alphaValue >= 0.999,
                          !revealSeed.ignoresMouseEvents,
                          isAnchor(revealSeed),
                          isPinned(revealSeed.frame)
                    else {
                        throw SmokeError("Second Option-M did not order in the compact reveal seed.")
                    }
                }

                try await Task.sleep(for: .milliseconds(80))
                do {
                    let revealingPanel = try panel("compact reveal")
                    guard revealingPanel.frame.width > 1,
                          revealingPanel.frame.width < self.controller.compactSize.width,
                          isPinned(revealingPanel.frame)
                    else {
                        throw SmokeError("Compact restore did not animate outward from the notch.")
                    }
                }

                try await Task.sleep(for: .milliseconds(290))
                do {
                    let restoredPanel = try panel("compact settle")
                    guard restoredPanel.isVisible,
                          !self.controller.isPanelHidden,
                          !self.controller.expanded,
                          self.controller.compactVisible,
                          abs(restoredPanel.frame.width - self.controller.compactSize.width) <= 1,
                          restoredPanel.alphaValue >= 0.999
                    else {
                        throw SmokeError("Second Option-M did not restore compact state.")
                    }
                }

                self.controller.setExpanded(
                    true,
                    source: "visibility-lifecycle-expanded",
                    animated: false
                )
                self.controller.togglePanelVisibility()
                try await Task.sleep(for: .milliseconds(360))
                do {
                    let hiddenPanel = try panel("expanded hide")
                    guard self.controller.isPanelHidden,
                          !hiddenPanel.isVisible,
                          isAnchor(hiddenPanel)
                    else {
                        throw SmokeError("Expanded state did not finish hidden at the notch anchor.")
                    }
                }

                self.controller.togglePanelVisibility()
                do {
                    let revealSeed = try panel("expanded restore seed")
                    guard self.controller.expanded,
                          self.controller.contentVisible,
                          revealSeed.isVisible,
                          isAnchor(revealSeed)
                    else {
                        throw SmokeError("Second Option-M did not preserve expanded state.")
                    }
                }

                try await Task.sleep(for: .milliseconds(370))
                do {
                    let restoredPanel = try panel("expanded settle")
                    guard !self.controller.isPanelHidden,
                          self.controller.expanded,
                          restoredPanel.isVisible,
                          abs(restoredPanel.frame.width - self.controller.expandedSize.width) <= 1,
                          abs(restoredPanel.frame.height - self.controller.expandedSize.height) <= 1,
                          restoredPanel.alphaValue >= 0.999
                    else {
                        throw SmokeError("Second Option-M did not restore expanded geometry.")
                    }
                }

                print(
                    "[visibility-lifecycle] option-m=compact+expanded "
                        + "ownership=retained hiddenDwell=850ms anchor=one-point"
                )
                NSApp.terminate(nil)
            } catch {
                fputs("Visibility lifecycle failed: \(error)\n", stderr)
                fflush(stderr)
                exit(1)
            }
        }
    }

    private func deferToExistingInstanceIfNeeded(isTestRun: Bool) -> Bool {
        guard !isTestRun,
              let bundleIdentifier = Bundle.main.bundleIdentifier
        else {
            return false
        }

        let runningInstances = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).filter { !$0.isTerminated }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let keeper = runningInstances.min(by: { lhs, rhs in
            let lhsDate = lhs.launchDate ?? .distantFuture
            let rhsDate = rhs.launchDate ?? .distantFuture
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.processIdentifier < rhs.processIdentifier
        }),
            keeper.processIdentifier != currentProcessIdentifier
        else {
            return false
        }

        keeper.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.meetingCaptureNeedsFinalization else {
            return .terminateNow
        }
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task { @MainActor [weak self] in
            let canTerminate = await controller.prepareMeetingCaptureForTermination()
            self?.terminationTask = nil
            NSApp.reply(toApplicationShouldTerminate: canTerminate)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        terminationTask?.cancel()
        terminationTask = nil
        controller?.stopThreadUpdates()
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

        panelWindow?.orderOut(nil)
        panelWindow = nil
        if automaticTerminationDisabled {
            ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
            automaticTerminationDisabled = false
        }
    }
}

@main
struct IAgentPanelApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

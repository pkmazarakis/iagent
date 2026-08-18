import Foundation
import SwiftUI
import UIKit
import WidgetKit
import iAgentActions
import iAgentCore

private final class MobileAssistantActionForegroundGate: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false
  private var generation: UInt64 = 0

  func update(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard active != value else { return }
    active = value
    generation &+= 1
  }

  func isActive() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return active
  }

  func authority() -> AssistantActionForegroundAuthority {
    AssistantActionForegroundAuthority(
      currentGeneration: { [weak self] in
        self?.currentGeneration() ?? UInt64.max
      },
      withActiveAuthorization: { [weak self] expectedGeneration, operation in
        guard let self else {
          throw AssistantActionBrokerError.appNotForeground
        }
        try self.withActiveAuthorization(
          expectedGeneration: expectedGeneration,
          operation: operation
        )
      }
    )
  }

  private func currentGeneration() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }

  private func withActiveAuthorization(
    expectedGeneration: UInt64,
    operation: () throws -> Void
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard active, generation == expectedGeneration else {
      throw AssistantActionBrokerError.appNotForeground
    }
    // Keep the foreground gate locked across the local action write. A transition to background
    // waits for this operation, so it cannot revoke authority between validation and persistence.
    try operation()
  }
}

struct MobileHomeUnreadMessageItem: Identifiable, Equatable {
  let conversationID: String
  let contactName: String
  let participantID: String
  let latestUnreadMessage: SyncedMessage

  var id: String { conversationID }

  var previewText: String {
    let collapsed = latestUnreadMessage.body
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return collapsed.isEmpty ? "Message" : collapsed
  }
}

struct MobileHomeUnreadMessageSummary: Equatable {
  let contactItems: [MobileHomeUnreadMessageItem]
  let remainingUnreadMessageCount: Int
}

enum MobileMessageInboxFilter: String, CaseIterable, Equatable, Sendable {
  case all
  case awaitingReply
  case unread

  func toggled(with target: Self) -> Self {
    self == target ? .all : target
  }
}

private struct MobileMessageInboxProjection {
  let conversations: [SyncedMessageConversation]
  let unreadConversationIDs: Set<String>
  let awaitingReplyConversationIDs: Set<String>
}

@MainActor
final class MobileAppModel: ObservableObject {
  enum Tab: Hashable {
    case today
    case codex
    case notes
    case todos
  }

  @Published var selectedTab: Tab = .today
  @Published private(set) var snapshot = IAgentDataSnapshot()
  @Published private(set) var syncStatus = IAgentCloudSyncStatus()
  @Published private(set) var hasLoadedInitialSnapshot = false
  @Published var isRecorderPresented = false
  @Published var isCalendarPresented = false
  @Published var isSettingsPresented = false
  @Published var isMessagesPresented = false
  @Published var calendarEventToPresentID: String?
  @Published var selectedCalendarDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
  @Published var isNoteEditorPresented = false
  @Published var messageConversationToPresent: String?
  @Published var activeMeetingTitle = "Meeting notes"
  @Published var activeCalendarEventID: String?
  @Published var lastRecordedNote: SyncedNote?
  @Published private(set) var isFinalizingRecording = false
  @Published private(set) var pendingMeetingNote: SyncedNote?
  @Published private(set) var completingTodoIDs = Set<UUID>()
  @Published private(set) var fadingTodoIDs = Set<UUID>()
  @Published private(set) var showsPhoneCalendarEvents = false
  @Published var deepLinkDestination: MobileDeepLinkDestination?
  @Published var navigationNotice: String?
  @Published private(set) var shouldAutoStartRecorder = true
  @Published private(set) var isPriorityLiveActivityEnabled = false
  @Published private(set) var isPriorityLiveActivityChanging = false
  @Published private(set) var priorityLiveActivitySummary = "Off"

  let calendar = MobileCalendarService()
  let recorder = MobileMeetingRecorder()
  let todoDictation = MobileMeetingRecorder()

  private let localStore: IAgentLocalSyncStore
  private let assistantActionForegroundGate: MobileAssistantActionForegroundGate
  let assistantActionRuntime: AssistantActionRuntime
  private let widgetProjectionStore: IAgentWidgetProjectionStore?
  private let priorityLiveActivityController = PriorityLiveActivityController()
  private var cloud: IAgentCloudSyncEngine?
  private let cloudStateURL: URL?
  private let fixtureMode: Bool
  private var refreshLoop: Task<Void, Never>?
  private var storeChangesTask: Task<Void, Never>?
  private var statusChangesTask: Task<Void, Never>?
  private var todoCompletionTasks: [UUID: Task<Void, Never>] = [:]
  private var recordingStartedAt: Date?
  private var meetingSummaryAnimationIDs = Set<UUID>()
  private var automaticMeetingSummaryIDs = Set<UUID>()
  private var fixtureMigrationBlockMessage: String?
  private var lastWidgetProjection: IAgentWidgetProjection?
  private var pendingDeepLink: IAgentDeepLink?
  private var didFinishInitialLoad = false
  private static let priorityLiveActivityPreferenceKey =
    "iagent.priority-live-activity.opt-in.v1"

  init() {
    let actionForegroundGate = MobileAssistantActionForegroundGate()
    assistantActionForegroundGate = actionForegroundGate

    let arguments = CommandLine.arguments
    #if DEBUG
    let defaultsToFixtures = !arguments.contains("--live-sync")
    #else
    let defaultsToFixtures = false
    #endif

    fixtureMode = arguments.contains("--ui-testing")
      || ProcessInfo.processInfo.environment["IAGENT_FIXTURES"] == "1"
      || defaultsToFixtures
    showsPhoneCalendarEvents = UserDefaults.standard.bool(
      forKey: "iagent.calendar.include-phone-events.v1"
    )
    let priorityLiveActivityEnabled = UserDefaults.standard.bool(
      forKey: Self.priorityLiveActivityPreferenceKey
    )
    isPriorityLiveActivityEnabled = priorityLiveActivityEnabled
    priorityLiveActivitySummary = priorityLiveActivityEnabled
      ? "Watching for priority changes"
      : "Off"

    if let routeIndex = arguments.firstIndex(of: "--start-tab"),
       arguments.indices.contains(routeIndex + 1) {
      switch arguments[routeIndex + 1] {
      case "codex": selectedTab = .codex
      case "messages":
        selectedTab = .today
        isMessagesPresented = true
      case "notes": selectedTab = .notes
      case "todos": selectedTab = .todos
      case "todo-composer": selectedTab = .todos
      case "recorder": isRecorderPresented = true
      case "calendar":
        selectedTab = .today
        isCalendarPresented = true
      case "settings":
        selectedTab = .today
        isSettingsPresented = true
      case "note-editor":
        selectedTab = .notes
        isNoteEditorPresented = true
      default: selectedTab = .today
      }
    }

    #if DEBUG
    if let conversationIndex = arguments.firstIndex(of: "--start-conversation"),
       arguments.indices.contains(conversationIndex + 1)
    {
      selectedTab = .today
      isMessagesPresented = true
      messageConversationToPresent = arguments[conversationIndex + 1]
    }
    #endif

    // Build 31 could encounter an unreadable legacy replica at the original path after an
    // update. The store correctly refuses to overwrite data it cannot preserve, but that
    // must not turn into a permanent local-write outage. A new app-private generation gets
    // a fresh CloudKit token and performs a complete private-zone fetch on first launch.
    let storeIdentifier = fixtureMode ? "iAgentMobileFixtures" : "iAgentMobile-v2"
    let storeURL = IAgentLocalSyncStore.defaultFileURL(appIdentifier: storeIdentifier)
    localStore = IAgentLocalSyncStore(fileURL: storeURL)
    let actionSourceDeviceID: String
    if let identifier = UIDevice.current.identifierForVendor?.uuidString {
      actionSourceDeviceID = identifier
    } else {
      actionSourceDeviceID = "iphone"
    }
    assistantActionRuntime = AssistantActionRuntime(
      localStore: localStore,
      sourceDeviceID: actionSourceDeviceID,
      persistenceDirectory: storeURL.deletingLastPathComponent(),
      isAppForeground: { actionForegroundGate.isActive() },
      foregroundAuthority: actionForegroundGate.authority()
    )
    widgetProjectionStore = IAgentWidgetProjectionStore.appGroupStore()

    if fixtureMode {
      cloud = nil
      cloudStateURL = nil
    } else {
      // Construct the engine only after legacy fixture migration has had a chance to reset its
      // serialized change token. Loading the old token first can leave an empty replica forever.
      cloud = nil
      cloudStateURL = storeURL.deletingLastPathComponent().appendingPathComponent("cloud-state.json")
    }
  }

  deinit {
    refreshLoop?.cancel()
    storeChangesTask?.cancel()
    statusChangesTask?.cancel()
    todoCompletionTasks.values.forEach { $0.cancel() }
  }

  var firstName: String? {
    if fixtureMode { return "Platon" }
    let deviceOwner = UIDevice.current.name
      .replacingOccurrences(of: "’s iPhone", with: "")
      .replacingOccurrences(of: "'s iPhone", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ["iPhone", "This iPhone"].contains(deviceOwner) ? nil : deviceOwner
  }

  var isUsingPreviewData: Bool {
    fixtureMode
  }

  func updateAssistantActionForeground(_ isForeground: Bool) {
    assistantActionForegroundGate.update(isForeground)
  }

  func refreshAfterAssistantActionCommit() async {
    await reload()
    if fixtureMigrationBlockMessage == nil {
      await cloud?.pushLocalChanges()
    }
    await reloadStatus()
  }

  var todayEvents: [SyncedCalendarEvent] {
    calendarEvents(on: Date())
  }

  var selectedCalendarEvents: [SyncedCalendarEvent] {
    calendarEvents(on: selectedCalendarDate)
  }

  var selectedPhoneCalendarEvents: [SyncedCalendarEvent] {
    guard showsPhoneCalendarEvents else { return [] }
    return phoneCalendarEvents(on: selectedCalendarDate)
  }

  var syncPendingCount: Int {
    snapshot.pendingRecordNames.union(snapshot.pendingDeletionRecordNames).count
  }

  var lastSuccessfulSyncAt: Date? {
    [syncStatus.lastSuccessfulSyncAt, snapshot.lastSuccessfulSyncAt]
      .compactMap { $0 }
      .max()
  }

  var syncEnvironmentName: String {
    if fixtureMode { return "Preview · isolated" }
    #if DEBUG
    return "Development"
    #else
    return "Production"
    #endif
  }

  var hasDesktopSnapshot: Bool {
    snapshot.desktopSnapshot != nil
  }

  var isDesktopSnapshotFresh: Bool {
    snapshot.desktopSnapshot?.isFresh() == true
  }

  var syncHealthTitle: String {
    switch syncStatus.phase {
    case .syncing: "Syncing"
    case .offline: "Offline"
    case .accountUnavailable: "iCloud unavailable"
    case .failed: "Sync needs attention"
    case .idle:
      if syncPendingCount > 0 { "Waiting to upload" }
      else if lastSuccessfulSyncAt != nil { "Synced" }
      else { "Not synced yet" }
    }
  }

  var syncHealthDetail: String {
    switch syncStatus.phase {
    case .syncing:
      return "Checking iCloud and exchanging changes."
    case .offline:
      return "Reconnect to the internet, then try Sync now."
    case .accountUnavailable:
      return "Sign in to the same iCloud account used by your Mac."
    case .failed:
      return syncStatus.message ?? "Open Sync details and try again."
    case .idle:
      if syncPendingCount > 0 {
        return "\(syncPendingCount) local \(syncPendingCount == 1 ? "change is" : "changes are") waiting for iCloud."
      }
      if snapshot.desktopSnapshot == nil {
        return "No desktop snapshot has reached this iPhone yet."
      }
      return "Your local replica is up to date."
    }
  }

  var activeThreads: [SyncedCodexThread] {
    snapshot.codexThreads.filter { $0.state.isActive && $0.deletedAt == nil }
  }

  var recentThreads: [SyncedCodexThread] {
    snapshot.codexThreads.filter { !$0.state.isActive && $0.deletedAt == nil }
  }

  var openTodos: [SyncedTodo] {
    snapshot.todos
      .filter { !$0.isCompleted && $0.deletedAt == nil }
      .sorted { $0.createdAt > $1.createdAt }
  }

  var displayedOpenTodos: [SyncedTodo] {
    snapshot.todos
      .filter {
        $0.deletedAt == nil
          && (!$0.isCompleted || completingTodoIDs.contains($0.id))
      }
      .sorted { $0.createdAt > $1.createdAt }
  }

  var completedTodos: [SyncedTodo] {
    snapshot.todos
      .filter {
        $0.isCompleted
          && $0.deletedAt == nil
          && !completingTodoIDs.contains($0.id)
      }
      .sorted {
        ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt)
      }
  }

  var availableTodoCalendars: [String] {
    var seen = Set<String>()
    return (calendar.calendarNames + snapshot.todoLists.sorted { $0.order < $1.order }.map(\.name))
      .compactMap { name in
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard seen.insert(key).inserted else { return nil }
        return trimmed
      }
  }

  var visibleNotes: [SyncedNote] {
    snapshot.notes.filter { $0.deletedAt == nil }
  }

  var visibleConversations: [SyncedMessageConversation] {
    visibleConversations(referenceDate: Date())
  }

  var unreadConversationCount: Int {
    messageInboxProjection(referenceDate: Date()).unreadConversationIDs.count
  }

  var awaitingReplyConversationCount: Int {
    messageInboxProjection(referenceDate: Date()).awaitingReplyConversationIDs.count
  }

  var latestMessageRelayState: SyncedMessageRelayState? {
    snapshot.messageRelayStates
      .filter { $0.deletedAt == nil }
      .max {
        $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt < $1.updatedAt
      }
  }

  func visibleConversations(referenceDate: Date) -> [SyncedMessageConversation] {
    messageInboxProjection(referenceDate: referenceDate).conversations
  }

  func filteredConversations(
    filter: MobileMessageInboxFilter,
    referenceDate: Date = Date()
  ) -> [SyncedMessageConversation] {
    let projection = messageInboxProjection(referenceDate: referenceDate)
    return projection.conversations.filter { conversation in
      switch filter {
      case .all:
        true
      case .awaitingReply:
        projection.awaitingReplyConversationIDs.contains(conversation.id)
      case .unread:
        projection.unreadConversationIDs.contains(conversation.id)
      }
    }
  }

  func messages(
    for conversationID: String,
    referenceDate: Date = Date()
  ) -> [SyncedMessage] {
    eligibleMessages(referenceDate: referenceDate)
      .filter { $0.conversationID == conversationID }
  }

  func latestMessage(
    for conversationID: String,
    referenceDate: Date = Date()
  ) -> SyncedMessage? {
    messages(for: conversationID, referenceDate: referenceDate).last
  }

  func unreadCount(
    for conversationID: String,
    referenceDate: Date = Date()
  ) -> Int {
    unreadMessages(for: conversationID, referenceDate: referenceDate).count
  }

  func unreadMessages(
    for conversationID: String,
    referenceDate: Date = Date()
  ) -> [SyncedMessage] {
    let readCursor = messageReadCursor(for: conversationID)

    return messages(for: conversationID, referenceDate: referenceDate).filter { message in
      guard !message.isFromMe, message.sourceReadAt == nil else { return false }
      return message.sentAt > readCursor.date
        || message.sentAt == readCursor.date && message.id > readCursor.messageID
    }
  }

  func homeUnreadMessageSummary(
    referenceDate: Date = Date(),
    contactLimit: Int = 2
  ) -> MobileHomeUnreadMessageSummary {
    let conversations = visibleConversations(referenceDate: referenceDate)
    let unreadByConversation = Dictionary(
      uniqueKeysWithValues: conversations.map { conversation in
        (
          conversation.id,
          unreadMessages(for: conversation.id, referenceDate: referenceDate)
        )
      }
    )

    let contactItems = conversations.compactMap { conversation -> MobileHomeUnreadMessageItem? in
      guard let latestUnreadMessage = unreadByConversation[conversation.id]?.last,
            let participant = homeContactParticipant(
              for: conversation,
              latestUnreadMessage: latestUnreadMessage
            )
      else { return nil }

      let contactName = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !contactName.isEmpty else { return nil }
      return MobileHomeUnreadMessageItem(
        conversationID: conversation.id,
        contactName: contactName,
        participantID: participant.id,
        latestUnreadMessage: latestUnreadMessage
      )
    }
    .sorted { left, right in
      let leftMessage = left.latestUnreadMessage
      let rightMessage = right.latestUnreadMessage
      if leftMessage.sentAt != rightMessage.sentAt {
        return leftMessage.sentAt > rightMessage.sentAt
      }
      if left.conversationID != right.conversationID {
        return left.conversationID < right.conversationID
      }
      return leftMessage.id < rightMessage.id
    }

    let visibleContactItems = Array(contactItems.prefix(max(0, contactLimit)))
    let representedConversationIDs = Set(visibleContactItems.map(\.conversationID))
    let remainingUnreadMessageCount = unreadByConversation.reduce(into: 0) {
      count, entry in
      guard !representedConversationIDs.contains(entry.key) else { return }
      count += entry.value.count
    }

    return MobileHomeUnreadMessageSummary(
      contactItems: visibleContactItems,
      remainingUnreadMessageCount: remainingUnreadMessageCount
    )
  }

  func homeContactParticipant(
    for conversation: SyncedMessageConversation,
    latestUnreadMessage: SyncedMessage
  ) -> SyncedMessageParticipant? {
    guard !conversation.isGroup,
          conversation.participants.count == 1,
          let participant = conversation.participants.first,
          participant.isContactNameResolved == true,
          latestUnreadMessage.conversationID == conversation.id,
          latestUnreadMessage.senderID == participant.id,
          !latestUnreadMessage.isFromMe,
          !participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return participant
  }

  func isAwaitingReply(
    _ conversation: SyncedMessageConversation,
    referenceDate: Date = Date()
  ) -> Bool {
    guard conversation.deletedAt == nil,
          !conversation.isGroup,
          let awaitingReplyMessageID = conversation.awaitingReplyMessageID,
          let message = messages(
            for: conversation.id,
            referenceDate: referenceDate
          ).first(where: { $0.id == awaitingReplyMessageID })
    else { return false }
    return !message.isFromMe && message.deletedAt == nil
  }

  func presentMessages(conversationID: String? = nil) {
    messageConversationToPresent = conversationID
    isMessagesPresented = true
  }

  private func messageReadCursor(
    for conversationID: String
  ) -> (date: Date, messageID: String) {
    var readCursor: (date: Date, messageID: String) = (.distantPast, "")
    for state in snapshot.messageReadStates
    where state.id == conversationID && state.deletedAt == nil {
      let candidate = (
        date: state.readThroughDate ?? .distantPast,
        messageID: state.readThroughMessageID ?? ""
      )
      if candidate.date > readCursor.date
        || candidate.date == readCursor.date && candidate.messageID > readCursor.messageID
      {
        readCursor = candidate
      }
    }
    return readCursor
  }

  func markConversationRead(
    _ conversationID: String,
    referenceDate: Date = Date()
  ) async {
    let visibleMessages = messages(for: conversationID, referenceDate: referenceDate)
    guard let latestMessage = visibleMessages.last,
          visibleMessages.contains(where: { !$0.isFromMe })
    else { return }

    let existing = snapshot.messageReadStates
      .filter { $0.id == conversationID && $0.deletedAt == nil }
      .max { $0.updatedAt < $1.updatedAt }
    let existingCursor = (
      existing?.readThroughDate ?? .distantPast,
      existing?.readThroughMessageID ?? ""
    )
    let candidateCursor = (latestMessage.sentAt, latestMessage.id)
    let latestKnownDate = max(
      existing?.latestKnownMessageDate ?? .distantPast,
      latestMessage.sentAt
    )
    guard candidateCursor > existingCursor
      || latestKnownDate > (existing?.latestKnownMessageDate ?? .distantPast)
    else { return }

    let nextCursor = candidateCursor >= existingCursor ? candidateCursor : existingCursor
    let state = SyncedMessageReadState(
      id: conversationID,
      readThroughMessageID: nextCursor.1,
      readThroughDate: nextCursor.0,
      latestKnownMessageDate: latestKnownDate,
      updatedAt: Date(),
      sourceDeviceID: UIDevice.current.identifierForVendor?.uuidString ?? "iphone"
    )
    _ = await save(.messageReadState(state))
  }

  /// One catalog powers every mobile authoring surface. Include EventKit
  /// results immediately instead of waiting for their next sync round trip.
  var artifactMentions: [ArtifactMention] {
    let now = Date()
    let calendar = Calendar.autoupdatingCurrent
    let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
    let end = calendar.date(byAdding: .day, value: 90, to: now) ?? now
    return ArtifactMentionCatalog.make(
      snapshot: snapshot,
      calendarEvents: self.calendar.permittedEvents(from: start, to: end)
    )
  }

  func todo(id: UUID) -> SyncedTodo? {
    snapshot.todos.first { $0.id == id && $0.deletedAt == nil }
  }

  func note(id: UUID) -> SyncedNote? {
    snapshot.notes.first { $0.id == id && $0.deletedAt == nil }
  }

  func meetingSession(for noteID: UUID) -> SyncedMeetingSession? {
    snapshot.meetings.first { $0.noteID == noteID && $0.deletedAt == nil }
  }

  func calendarEvent(id: String?) -> SyncedCalendarEvent? {
    guard let id else { return nil }
    return activeCalendarEvent(
      matching: id,
      in: snapshot.calendarEvents + calendar.events
    )
  }

  private func activeCalendarEvent(
    matching id: String,
    in candidates: [SyncedCalendarEvent]
  ) -> SyncedCalendarEvent? {
    candidates.first { $0.deletedAt == nil && $0.id == id }
      ?? candidates.first { $0.deletedAt == nil && $0.sourceIdentifier == id }
  }

  func calendarEvents(on date: Date) -> [SyncedCalendarEvent] {
    events(snapshot.calendarEvents, on: date)
  }

  func phoneCalendarEvents(on date: Date) -> [SyncedCalendarEvent] {
    let phoneOnly = calendar.events.filter { phoneEvent in
      phoneEvent.deletedAt == nil
        && !snapshot.calendarEvents.contains(where: { synced in
          synced.deletedAt == nil && calendarEventsMatch(synced, phoneEvent)
        })
    }
    return events(phoneOnly, on: date)
  }

  func setShowsPhoneCalendarEvents(_ isEnabled: Bool) {
    showsPhoneCalendarEvents = isEnabled
    UserDefaults.standard.set(isEnabled, forKey: "iagent.calendar.include-phone-events.v1")
  }

  func setPriorityLiveActivityEnabled(_ isEnabled: Bool) async {
    guard !isPriorityLiveActivityChanging,
          isPriorityLiveActivityEnabled != isEnabled
    else { return }

    isPriorityLiveActivityChanging = true
    defer { isPriorityLiveActivityChanging = false }

    if isEnabled, !priorityLiveActivityController.activitiesAreEnabled {
      priorityLiveActivitySummary = "Unavailable in iOS Settings"
      navigationNotice = "Live Activities are turned off for iAgent in iOS Settings."
      return
    }

    isPriorityLiveActivityEnabled = isEnabled
    UserDefaults.standard.set(isEnabled, forKey: Self.priorityLiveActivityPreferenceKey)

    if isEnabled {
      await refreshPriorityLiveActivity()
    } else {
      _ = await priorityLiveActivityController.endAll(immediately: true)
      priorityLiveActivitySummary = "Off"
    }
  }

  func isPhoneOnlyCalendarEvent(_ event: SyncedCalendarEvent) -> Bool {
    calendar.events.contains(where: { $0.id == event.id })
      && !snapshot.calendarEvents.contains(where: { calendarEventsMatch($0, event) })
  }

  private func events(
    _ source: [SyncedCalendarEvent],
    on date: Date
  ) -> [SyncedCalendarEvent] {
    let systemCalendar = Calendar.autoupdatingCurrent
    let start = systemCalendar.startOfDay(for: date)
    guard let end = systemCalendar.date(byAdding: .day, value: 1, to: start) else { return [] }

    return source
      .filter { $0.deletedAt == nil }
      .filter { $0.startDate < end && $0.endDate > start }
      .sorted { lhs, rhs in
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        return lhs.startDate < rhs.startDate
      }
  }

  func selectCalendarDate(_ date: Date) {
    selectedCalendarDate = Calendar.autoupdatingCurrent.startOfDay(for: date)
    calendar.refresh(referenceDate: selectedCalendarDate)
  }

  func start() async {
    defer {
      didFinishInitialLoad = true
      hasLoadedInitialSnapshot = true
      resolvePendingDeepLink()
    }
    startSyncObservers()

    if fixtureMode {
      try? await localStore.replaceForTesting(
        with: MobileFixtureData.payloads(
          includesLongTodoList: CommandLine.arguments.contains("--long-todo-list-fixture"),
          includesLongNoteList: CommandLine.arguments.contains("--long-note-list-fixture"),
          includesPriorityLiveActivityItems: CommandLine.arguments.contains(
            "--priority-live-activity-multiple-fixture"
          )
        )
      )
      syncStatus = IAgentCloudSyncStatus(
        phase: .idle,
        lastSuccessfulSyncAt: Date(),
        message: "Preview data"
      )
    } else {
      guard let cloudStateURL else { return }
      switch await LegacyMobileFixtureMigration.run(
        store: localStore,
        cloudStateURL: cloudStateURL
      ) {
      case .ready, .quarantined:
        break
      case .blocked(let message):
        fixtureMigrationBlockMessage = message
        snapshot = await localStore.snapshot()
        publishWidgetProjectionIfNeeded(snapshot)
        await refreshPriorityLiveActivity()
        syncStatus = IAgentCloudSyncStatus(phase: .failed, message: message)
        startRefreshLoop()
        return
      }

      cloud = IAgentCloudSyncEngine(
        store: localStore,
        containerIdentifier: "iCloud.com.platon.iagent",
        stateFileURL: cloudStateURL
      )

      async let calendarAccess: Void = calendar.requestAccessAndRefresh(
        referenceDate: selectedCalendarDate
      )
      async let cloudStart: Void = cloud?.start() ?? ()
      _ = await (calendarAccess, cloudStart)
    }

    await reload()
    startRefreshLoop()
  }

  func refresh() async {
    calendar.refresh(referenceDate: selectedCalendarDate)
    _ = await enforceMessageRetention()
    if let fixtureMigrationBlockMessage {
      snapshot = await localStore.snapshot()
      publishWidgetProjectionIfNeeded(snapshot)
      await refreshPriorityLiveActivity()
      syncStatus = IAgentCloudSyncStatus(
        phase: .failed,
        message: fixtureMigrationBlockMessage
      )
      return
    }
    await cloud?.synchronize()
    await reload()
  }

  func open(_ url: URL) {
    UIApplication.shared.open(url)
  }

  func handleDeepLink(_ url: URL) {
    guard let route = IAgentDeepLink(url: url) else {
      navigationNotice = "That iAgent link isn't supported."
      return
    }
    pendingDeepLink = route
    resolvePendingDeepLink()
  }

  @discardableResult
  func createTodo(
    title: String,
    notes: String? = nil,
    listName: String? = nil,
    dueDate: Date? = nil
  ) async -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let hasNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    let todo = SyncedTodo(
      title: trimmed,
      notes: hasNotes ? notes : nil,
      dueDate: dueDate,
      listName: listName
    )
    return await save(.todo(todo))
  }

  @discardableResult
  func updateTodo(id: UUID, title: String, notes: String?) async -> Bool {
    guard var updated = todo(id: id) else { return false }
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else { return false }

    let hasNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    updated.title = trimmedTitle
    updated.notes = hasNotes ? notes : nil
    updated.updatedAt = Date()
    return await save(.todo(updated))
  }

  func toggleTodo(id: UUID) async {
    guard var updated = todo(id: id) else { return }
    let now = Date()

    if updated.isCompleted {
      todoCompletionTasks[id]?.cancel()
      todoCompletionTasks[id] = nil
      updated.isCompleted = false
      updated.completedAt = nil
      updated.updatedAt = now
      replaceTodoInSnapshot(updated)
      withAnimation(.easeOut(duration: 0.16)) {
        completingTodoIDs.remove(id)
        fadingTodoIDs.remove(id)
      }
      await persistTodo(id: id)
      return
    }

    updated.isCompleted = true
    updated.completedAt = now
    updated.updatedAt = now
    replaceTodoInSnapshot(updated)
    completingTodoIDs.insert(id)
    fadingTodoIDs.remove(id)
    scheduleTodoCompletionTransfer(id: id)
    await persistTodo(id: id)
  }

  func toggleStar(id: UUID) async {
    guard var updated = todo(id: id) else { return }
    updated.isStarred.toggle()
    updated.updatedAt = Date()
    replaceTodoInSnapshot(updated)
    await persistTodo(id: id)
  }

  func deleteTodo(id: UUID) async {
    guard var updated = todo(id: id) else { return }
    todoCompletionTasks[id]?.cancel()
    todoCompletionTasks[id] = nil
    updated.deletedAt = Date()
    updated.updatedAt = Date()
    replaceTodoInSnapshot(updated)
    withAnimation(PanelTheme.quick) {
      completingTodoIDs.remove(id)
      fadingTodoIDs.remove(id)
    }
    await save(.todo(updated))
  }

  func createTodoList(named name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !snapshot.todoLists.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
    else { return }
    let list = SyncedTodoList(name: trimmed, order: snapshot.todoLists.count)
    await save(.todoList(list))
  }

  @discardableResult
  func saveNote(
    id: UUID? = nil,
    title: String,
    body: String,
    kind: SyncedNoteKind = .note
  ) async -> SyncedNote {
    let existing = id.flatMap { noteID in snapshot.notes.first(where: { $0.id == noteID }) }
    let now = Date()
    let note = SyncedNote(
      id: existing?.id ?? UUID(),
      kind: kind,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled note",
      body: body,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      sourceDeviceID: existing?.sourceDeviceID ?? UIDevice.current.identifierForVendor?.uuidString ?? "iphone",
      relativeFilePath: existing?.relativeFilePath
    )
    var payloads: [IAgentSyncPayload] = [.note(note)]
    if kind == .meeting, var meeting = meetingSession(for: note.id) {
      // The linked meeting index follows only the explicit title field. Body and summary edits
      // never participate in title selection.
      meeting.title = note.title
      meeting.updatedAt = now
      payloads.append(.meetingSession(meeting))
    }
    await save(payloads)
    return note
  }

  func deleteNote(_ note: SyncedNote) async {
    let payloads = IAgentSyncPayload.cascadingNoteDeletion(
      note: note,
      linkedMeetings: snapshot.meetings,
      at: Date()
    )
    do {
      try await localStore.upsertLocal(payloads)
      await reload()
      if fixtureMigrationBlockMessage == nil {
        await cloud?.pushLocalChanges()
      }
      await reloadStatus()
    } catch {
      syncStatus = IAgentCloudSyncStatus(phase: .failed, message: error.localizedDescription)
    }
  }

  /// Persists a locally generated Markdown summary without replacing the transcript or
  /// any legacy metadata that shares the meeting-note document.
  @discardableResult
  func saveMeetingSummary(
    noteID: UUID,
    summary: String,
    expectedBody: String? = nil
  ) async -> Bool {
    guard var note = note(id: noteID), note.kind == .meeting else { return false }
    if let expectedBody, note.body != expectedBody { return false }
    let now = Date()
    let content = MeetingNoteContent(markdown: note.body)
    note.body = content.markdown(replacingSummary: summary)
    note.updatedAt = now

    var payloads: [IAgentSyncPayload] = [.note(note)]
    if var meeting = meetingSession(for: noteID) {
      meeting.summaryGeneratedAt = now
      meeting.updatedAt = now
      payloads.append(.meetingSession(meeting))
    }

    do {
      try await localStore.upsertLocal(payloads)
      await reload()
      if fixtureMigrationBlockMessage == nil {
        await cloud?.pushLocalChanges()
      }
      await reloadStatus()
      return true
    } catch {
      syncStatus = IAgentCloudSyncStatus(phase: .failed, message: error.localizedDescription)
      return false
    }
  }

  func presentRecorder(
    title: String = "Meeting notes",
    calendarEventID: String? = nil,
    automaticallyStarts: Bool = true
  ) {
    activeMeetingTitle = title
    activeCalendarEventID = calendarEventID
    lastRecordedNote = nil
    pendingMeetingNote = nil
    shouldAutoStartRecorder = automaticallyStarts
    isRecorderPresented = true
  }

  func startRecording() async {
    guard await recorder.start() else { return }
    recordingStartedAt = Date()
  }

  func finishRecording() async {
    guard !isFinalizingRecording else { return }
    isFinalizingRecording = true
    defer { isFinalizingRecording = false }

    let transcript = await recorder.stop()
    let startedAt = recordingStartedAt ?? Date().addingTimeInterval(-recorder.elapsed)
    let now = Date()
    let formattedTranscript = transcript.nonEmpty ?? "_No speech was recognized._"
    // Capture is always committed transcript-first. A summary is optional and can only be
    // generated later by Apple's on-device Foundation Models when this phone supports it.
    let body = MeetingNoteContent(transcript: formattedTranscript).markdown
    let segments: [SyncedTranscriptSegment] = transcript.isEmpty
      ? []
      : [
        SyncedTranscriptSegment(
          source: .microphone,
          text: transcript,
          startOffset: 0,
          endOffset: max(0, recorder.elapsed)
        )
      ]
    let note = SyncedNote(
      kind: .meeting,
      title: activeMeetingTitle,
      body: body,
      createdAt: startedAt,
      updatedAt: now,
      sourceDeviceID: UIDevice.current.identifierForVendor?.uuidString ?? "iphone"
    )
    let meeting = SyncedMeetingSession(
      noteID: note.id,
      title: activeMeetingTitle,
      calendarEventID: activeCalendarEventID,
      sourceDeviceID: note.sourceDeviceID,
      state: .completed,
      startedAt: startedAt,
      endedAt: now,
      updatedAt: now,
      transcriptSegments: segments,
      summaryGeneratedAt: nil
    )

    do {
      try await localStore.upsertLocal([.note(note), .meetingSession(meeting)])
      await reload()
      let savedNote = self.note(id: note.id) ?? note
      lastRecordedNote = savedNote
      pendingMeetingNote = savedNote
      automaticMeetingSummaryIDs.insert(note.id)
      recordingStartedAt = nil
      selectedTab = .notes
      recorder.reset()
      isRecorderPresented = false

      if fixtureMigrationBlockMessage == nil {
        await cloud?.pushLocalChanges()
      }
    } catch {
      syncStatus = IAgentCloudSyncStatus(phase: .failed, message: error.localizedDescription)
    }
  }

  func dismissRecorder() {
    guard !recorder.isRecording,
          !recorder.isStarting,
          !recorder.isStopping,
          !recorder.hasRecoverableRecording,
          !isFinalizingRecording
    else { return }
    recorder.reset()
    recordingStartedAt = nil
    isRecorderPresented = false
  }

  func openLastRecordedNote() {
    guard let note = lastRecordedNote else { return }
    pendingMeetingNote = self.note(id: note.id) ?? note
    selectedTab = .notes
    dismissRecorder()
  }

  func consumePendingMeetingNote() -> SyncedNote? {
    defer { pendingMeetingNote = nil }
    guard let pendingMeetingNote else { return nil }
    return note(id: pendingMeetingNote.id) ?? pendingMeetingNote
  }

  func consumeMeetingSummaryAnimation(for noteID: UUID) -> Bool {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--animate-meeting-summary") {
      return true
    }
    #endif
    return meetingSummaryAnimationIDs.remove(noteID) != nil
  }

  /// A newly captured meeting gets one automatic on-device summary opportunity. The
  /// intent is consumed even when this phone is ineligible so later note openings never
  /// unexpectedly start a model request.
  func consumeAutomaticMeetingSummary(for noteID: UUID) -> Bool {
    automaticMeetingSummaryIDs.remove(noteID) != nil
  }

  private func calendarEventsMatch(
    _ lhs: SyncedCalendarEvent,
    _ rhs: SyncedCalendarEvent
  ) -> Bool {
    lhs.isSameOccurrence(as: rhs)
  }

  private func replaceTodoInSnapshot(_ todo: SyncedTodo) {
    var next = snapshot
    if let index = next.todos.firstIndex(where: { $0.id == todo.id }) {
      next.todos[index] = todo
    } else {
      next.todos.append(todo)
    }
    snapshot = next
  }

  private func persistTodo(id: UUID) async {
    guard let latest = snapshot.todos.first(where: { $0.id == id }) else { return }
    await save(.todo(latest))
  }

  private func scheduleTodoCompletionTransfer(id: UUID) {
    todoCompletionTasks[id]?.cancel()
    todoCompletionTasks[id] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(2_550))
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
    }
  }

  @discardableResult
  private func save(_ payload: IAgentSyncPayload) async -> Bool {
    await save([payload])
  }

  @discardableResult
  private func save(_ payloads: [IAgentSyncPayload]) async -> Bool {
    do {
      try await localStore.upsertLocal(payloads)
      await reload()
      if fixtureMigrationBlockMessage == nil {
        await cloud?.pushLocalChanges()
      }
      await reloadStatus()
      return true
    } catch {
      syncStatus = IAgentCloudSyncStatus(phase: .failed, message: error.localizedDescription)
      return false
    }
  }

  private func reload() async {
    let previousSnapshot = snapshot
    _ = await enforceMessageRetention()
    let nextSnapshot = await localStore.snapshot()
    snapshot = nextSnapshot
    hasLoadedInitialSnapshot = true
    publishWidgetProjectionIfNeeded(nextSnapshot)
    if !priorityProjectionMatches(previousSnapshot, nextSnapshot) {
      await refreshPriorityLiveActivity()
    }
    await reloadStatus()
    resolvePendingDeepLink()
  }

  private func messageInboxProjection(
    referenceDate: Date
  ) -> MobileMessageInboxProjection {
    let eligible = eligibleMessages(referenceDate: referenceDate)
    let messagesByConversation = Dictionary(grouping: eligible, by: \.conversationID)
    let messageByID = eligible.reduce(into: [String: SyncedMessage]()) { index, message in
      index[message.id] = message
    }

    var readCursorByConversation: [String: (date: Date, messageID: String)] = [:]
    for state in snapshot.messageReadStates where state.deletedAt == nil {
      let candidate = (
        date: state.readThroughDate ?? .distantPast,
        messageID: state.readThroughMessageID ?? ""
      )
      let current = readCursorByConversation[state.id] ?? (.distantPast, "")
      if candidate.date > current.date
        || candidate.date == current.date && candidate.messageID > current.messageID
      {
        readCursorByConversation[state.id] = candidate
      }
    }

    let conversations = snapshot.messageConversations.filter {
      $0.deletedAt == nil && !(messagesByConversation[$0.id]?.isEmpty ?? true)
    }
    var unreadConversationIDs = Set<String>()
    var awaitingReplyConversationIDs = Set<String>()

    for conversation in conversations {
      let cursor = readCursorByConversation[conversation.id] ?? (.distantPast, "")
      let hasUnread = messagesByConversation[conversation.id, default: []].contains { message in
        guard !message.isFromMe, message.sourceReadAt == nil else { return false }
        return message.sentAt > cursor.date
          || message.sentAt == cursor.date && message.id > cursor.messageID
      }
      if hasUnread { unreadConversationIDs.insert(conversation.id) }

      if !conversation.isGroup,
         let awaitingReplyMessageID = conversation.awaitingReplyMessageID,
         let message = messageByID[awaitingReplyMessageID],
         message.conversationID == conversation.id,
         !message.isFromMe
      {
        awaitingReplyConversationIDs.insert(conversation.id)
      }
    }

    let orderedConversations = conversations.sorted { left, right in
      func priority(_ conversationID: String) -> Int {
        if unreadConversationIDs.contains(conversationID) { return 0 }
        if awaitingReplyConversationIDs.contains(conversationID) { return 1 }
        return 2
      }

      let leftPriority = priority(left.id)
      let rightPriority = priority(right.id)
      if leftPriority != rightPriority { return leftPriority < rightPriority }

      let leftDate = messagesByConversation[left.id]?.last?.sentAt ?? .distantPast
      let rightDate = messagesByConversation[right.id]?.last?.sentAt ?? .distantPast
      if leftDate != rightDate { return leftDate > rightDate }
      return left.id > right.id
    }

    return MobileMessageInboxProjection(
      conversations: orderedConversations,
      unreadConversationIDs: unreadConversationIDs,
      awaitingReplyConversationIDs: awaitingReplyConversationIDs
    )
  }

  private func eligibleMessages(referenceDate: Date) -> [SyncedMessage] {
    snapshot.messages
      .filter {
        $0.deletedAt == nil
          && MessageSyncWindow.includes(date: $0.sentAt, referenceDate: referenceDate)
      }
      .sorted {
        $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt
      }
  }

  @discardableResult
  private func enforceMessageRetention(referenceDate: Date = Date()) async -> Bool {
    do {
      _ = try await localStore.enforceMessageRetention(referenceDate: referenceDate)
      return true
    } catch {
      syncStatus = IAgentCloudSyncStatus(
        phase: .failed,
        lastSuccessfulSyncAt: syncStatus.lastSuccessfulSyncAt,
        pendingRecordCount: syncPendingCount,
        message: error.localizedDescription
      )
      return false
    }
  }

  private func priorityProjectionMatches(
    _ left: IAgentDataSnapshot,
    _ right: IAgentDataSnapshot
  ) -> Bool {
    left.todos == right.todos
      && left.codexThreads == right.codexThreads
      && left.calendarEvents == right.calendarEvents
      && left.desktopSnapshot == right.desktopSnapshot
  }

  private func refreshPriorityLiveActivity(now: Date = Date()) async {
    let systemCalendar = Calendar.autoupdatingCurrent
    let calendarEnd = systemCalendar.date(byAdding: .day, value: 1, to: now)
      ?? now.addingTimeInterval(24 * 60 * 60)
    let result = await priorityLiveActivityController.refresh(
      snapshot: snapshot,
      supplementalCalendarEvents: calendar.permittedEvents(from: now, to: calendarEnd),
      userHasOptedIn: isPriorityLiveActivityEnabled,
      allowStart: UIApplication.shared.applicationState == .active,
      now: now,
      calendar: systemCalendar
    )

    guard isPriorityLiveActivityEnabled else {
      priorityLiveActivitySummary = "Off"
      return
    }

    switch result.result {
    case .unavailable:
      priorityLiveActivitySummary = "Unavailable in iOS Settings"
    case .noFocus, .ended:
      priorityLiveActivitySummary = "Watching · nothing urgent"
    case .started, .updated, .unchanged:
      let count = result.items.count
      priorityLiveActivitySummary = count == 1 ? "1 urgent item" : "\(count) urgent items"
    }
  }

  private func publishWidgetProjectionIfNeeded(_ current: IAgentDataSnapshot) {
    guard let widgetProjectionStore else { return }
    let now = Date()
    let systemCalendar = Calendar.autoupdatingCurrent
    let today = systemCalendar.startOfDay(for: now)
    let searchEnd = systemCalendar.date(byAdding: .day, value: 31, to: today) ?? now
    let phoneCalendarEvents = calendar.permittedEvents(from: today, to: searchEnd)
    let projection = IAgentWidgetProjection.make(
      from: current,
      generatedAt: now,
      calendar: systemCalendar,
      supplementalCalendarEvents: phoneCalendarEvents
    )
    guard lastWidgetProjection.map({ !widgetContentMatches($0, projection) }) ?? true else {
      return
    }

    do {
      try widgetProjectionStore.save(projection)
      lastWidgetProjection = projection
      [
        IAgentWidgetConstants.todosKind,
        IAgentWidgetConstants.notesKind,
        IAgentWidgetConstants.codexKind,
        IAgentWidgetConstants.lockScreenOverviewKind,
        IAgentWidgetConstants.lockScreenNextMeetingKind,
        IAgentWidgetConstants.lockScreenCodexKind,
        IAgentWidgetConstants.lockScreenCalendarKind,
        IAgentWidgetConstants.lockScreenTodosKind,
        IAgentWidgetConstants.lockScreenNotesKind,
      ].forEach { WidgetCenter.shared.reloadTimelines(ofKind: $0) }
    } catch {
      // Widget projection failure must never interfere with the primary local store.
    }
  }

  private func widgetContentMatches(
    _ left: IAgentWidgetProjection,
    _ right: IAgentWidgetProjection
  ) -> Bool {
    left.version == right.version
      && left.lastSuccessfulSyncAt == right.lastSuccessfulSyncAt
      && left.openTodoCount == right.openTodoCount
      && left.activeCodexCount == right.activeCodexCount
      && left.codexAttentionCount == right.codexAttentionCount
      && left.todayCalendarEventCount == right.todayCalendarEventCount
      && left.noteCount == right.noteCount
      && left.nextMeeting == right.nextMeeting
      && left.todos == right.todos
      && left.notes == right.notes
      && left.codexTasks == right.codexTasks
  }

  private func resolvePendingDeepLink() {
    guard didFinishInitialLoad, let route = pendingDeepLink else { return }
    pendingDeepLink = nil

    switch route {
    case .todos:
      selectedTab = .todos
    case .createTodo:
      selectedTab = .todos
      deepLinkDestination = .todoDraft
    case .todo(let id):
      selectedTab = .todos
      guard let todo = todo(id: id) else {
        navigationNotice = "This todo is no longer available."
        return
      }
      deepLinkDestination = .todo(todo)
    case .notes:
      selectedTab = .notes
    case .createNote:
      selectedTab = .notes
      deepLinkDestination = .note(nil)
    case .note(let id):
      selectedTab = .notes
      guard let note = note(id: id) else {
        navigationNotice = "This note is no longer available."
        return
      }
      deepLinkDestination = .note(note)
    case .notePath(let path):
      selectedTab = .notes
      guard let note = snapshot.notes.first(where: {
        $0.deletedAt == nil && $0.relativeFilePath == path
      }) else {
        navigationNotice = "This note is no longer available."
        return
      }
      deepLinkDestination = .note(note)
    case .calendar:
      selectedTab = .today
      selectedCalendarDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
      calendar.refresh(referenceDate: selectedCalendarDate)
      calendarEventToPresentID = nil
      isCalendarPresented = true
    case .calendarEvent(let id):
      let systemCalendar = Calendar.autoupdatingCurrent
      let now = Date()
      let rangeStart = systemCalendar.date(byAdding: .day, value: -30, to: now) ?? now
      let rangeEnd = systemCalendar.date(byAdding: .day, value: 90, to: now) ?? now
      let candidates = snapshot.calendarEvents
        + calendar.events
        + calendar.permittedEvents(from: rangeStart, to: rangeEnd)
      guard let event = activeCalendarEvent(matching: id, in: candidates) else {
        navigationNotice = "This calendar event is no longer available."
        return
      }
      selectedTab = .today
      selectedCalendarDate = systemCalendar.startOfDay(for: event.startDate)
      calendar.refresh(referenceDate: selectedCalendarDate)
      calendarEventToPresentID = event.id
      isCalendarPresented = true
    case .meetingReady:
      presentRecorder(automaticallyStarts: false)
    case .codex:
      selectedTab = .codex
    case .createCodexRequest:
      selectedTab = .codex
      deepLinkDestination = .codexDraft
    case .codexThread(let id):
      selectedTab = .codex
      guard let task = snapshot.codexThreads.first(where: { $0.id == id && $0.deletedAt == nil }) else {
        navigationNotice = "This Codex task is no longer available."
        return
      }
      deepLinkDestination = .codex(task)
    }
  }

  private func reloadStatus() async {
    if let fixtureMigrationBlockMessage {
      syncStatus = IAgentCloudSyncStatus(
        phase: .failed,
        message: fixtureMigrationBlockMessage
      )
      return
    }
    if let cloud {
      syncStatus = await cloud.status()
    }
  }

  private func startRefreshLoop() {
    refreshLoop?.cancel()
    refreshLoop = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard let self else { return }
        await reload()
      }
    }
  }

  private func startSyncObservers() {
    if storeChangesTask == nil {
      storeChangesTask = Task { @MainActor [weak self] in
        for await _ in NotificationCenter.default.notifications(
          named: .iAgentSyncStoreDidChange
        ) {
          guard let self else { return }
          await self.reload()
        }
      }
    }

    if statusChangesTask == nil {
      statusChangesTask = Task { @MainActor [weak self] in
        for await _ in NotificationCenter.default.notifications(
          named: .iAgentSyncStatusDidChange
        ) {
          guard let self else { return }
          await self.reloadStatus()
        }
      }
    }
  }
}

private enum LegacyMobileFixtureMigrationResult {
  case ready
  case quarantined
  case blocked(String)
}

private enum LegacyMobileFixtureMigration {
  private static let completionKey = "iagent.fixture-store-migration.v2.completed"
  private static let previousCompletionKey = "iagent.fixture-store-migration.v1.completed"

  static func run(
    store: IAgentLocalSyncStore,
    cloudStateURL: URL
  ) async -> LegacyMobileFixtureMigrationResult {
    guard !UserDefaults.standard.bool(forKey: completionKey) else { return .ready }

    let payloads = await store.allPayloads()
    guard let fixtureRecordNames = exactFixtureRecordNames(in: payloads) else {
      if containsFixtureMarkers(in: payloads) {
        return .blocked(
          "Preview records are mixed with personal data. They were left untouched; use Sync details before uploading."
        )
      }
      // v1 removed exact fixture rows but retained CKSyncEngine's old change token. Reset that
      // token once so already-migrated installs also perform a complete private-zone fetch.
      if UserDefaults.standard.bool(forKey: previousCompletionKey),
         FileManager.default.fileExists(atPath: cloudStateURL.path) {
        do {
          let storeURL = await store.fileURL
          try IAgentLegacySyncStateQuarantine.archiveReplicaAndResetCloudState(
            storeURL: storeURL,
            cloudStateURL: cloudStateURL,
            requireStore: false
          )
        } catch {
          return .blocked(
            "The previous sync token could not be reset safely: \(error.localizedDescription)"
          )
        }
      }
      UserDefaults.standard.set(true, forKey: completionKey)
      return .ready
    }

    do {
      let storeURL = await store.fileURL
      try IAgentLegacySyncStateQuarantine.archiveReplicaAndResetCloudState(
        storeURL: storeURL,
        cloudStateURL: cloudStateURL
      )
      let discarded = try await store.discardUntrackedLocalRecords(named: fixtureRecordNames)
      guard discarded == fixtureRecordNames else {
        return .blocked(
          "Preview records have sync history, so they were not removed automatically. The original store was quarantined."
        )
      }
      UserDefaults.standard.set(true, forKey: completionKey)
      return .quarantined
    } catch {
      return .blocked(
        "Preview data could not be quarantined safely: \(error.localizedDescription)"
      )
    }
  }

  private static func exactFixtureRecordNames(
    in payloads: [IAgentSyncPayload]
  ) -> Set<String>? {
    let events = payloads.compactMap { payload -> SyncedCalendarEvent? in
      guard case let .calendarEvent(value) = payload else { return nil }
      return value
    }
    let threads = payloads.compactMap { payload -> SyncedCodexThread? in
      guard case let .codexThread(value) = payload else { return nil }
      return value
    }
    let todos = payloads.compactMap { payload -> SyncedTodo? in
      guard case let .todo(value) = payload else { return nil }
      return value
    }
    let notes = payloads.compactMap { payload -> SyncedNote? in
      guard case let .note(value) = payload else { return nil }
      return value
    }
    let meetings = payloads.compactMap { payload -> SyncedMeetingSession? in
      guard case let .meetingSession(value) = payload else { return nil }
      return value
    }
    let lists = payloads.compactMap { payload -> SyncedTodoList? in
      guard case let .todoList(value) = payload else { return nil }
      return value
    }
    let desktops = payloads.compactMap { payload -> SyncedDesktopSnapshot? in
      guard case let .desktopSnapshot(value) = payload else { return nil }
      return value
    }

    let legacyEventIDs: Set<String> = [
      "fixture-design-sync",
      "fixture-product-review",
      "fixture-dinner",
    ]
    let expandedEventIDs = legacyEventIDs.union([
      "fixture-roadmap-workshop",
      "fixture-travel-day",
    ])
    let eventIDs = Set(events.map(\.id))
    let usesExpandedFixture = eventIDs == expandedEventIDs

    guard events.count == (usesExpandedFixture ? 5 : 3),
          eventIDs == legacyEventIDs || usesExpandedFixture,
          threads.count == 3,
          Set(threads.map(\.id)) == ["fixture-thread-1", "fixture-thread-2", "fixture-thread-3"],
          todos.count == 3,
          Set(todos.map(\.title)) == [
            "Send the mobile sync brief",
            "Book the flight",
            "Review meeting notes",
          ],
          notes.count == 2,
          Set(notes.map(\.title)) == ["Mobile companion principles", "Design sync"],
          notes.allSatisfy({ $0.sourceDeviceID == "fixture-mac" }),
          lists.count == 2,
          Set(lists.map { $0.name.lowercased() }) == ["work", "personal"],
          desktops.count == 1,
          desktops.first?.id == "fixture-desktop",
          meetings.count == (usesExpandedFixture ? 1 : 0),
          meetings.allSatisfy({ $0.sourceDeviceID == "fixture-mac" }),
          payloads.count == events.count + threads.count + todos.count
            + notes.count + meetings.count + lists.count + desktops.count
    else {
      return nil
    }

    return Set(payloads.map(\.recordName))
  }

  private static func containsFixtureMarkers(in payloads: [IAgentSyncPayload]) -> Bool {
    payloads.contains { payload in
      switch payload {
      case .calendarEvent(let event):
        event.id.hasPrefix("fixture-")
      case .codexThread(let thread):
        thread.id.hasPrefix("fixture-")
      case .desktopSnapshot(let snapshot):
        snapshot.id == "fixture-desktop"
      case .note(let note):
        note.sourceDeviceID == "fixture-mac"
      case .meetingSession(let meeting):
        meeting.sourceDeviceID == "fixture-mac"
      case .messageConversation(let conversation):
        conversation.id.hasPrefix("fixture-")
      case .message(let message):
        message.id.hasPrefix("fixture-")
      case .messageReadState(let state):
        state.id.hasPrefix("fixture-")
      case .messageRelayState(let state):
        state.id.hasPrefix("fixture-")
      case .todo, .todoList:
        false
      }
    }
  }

}

private enum MobileFixtureData {
  static func payloads(
    referenceDate: Date = Date(),
    includesLongTodoList: Bool = false,
    includesLongNoteList: Bool = false,
    includesPriorityLiveActivityItems: Bool = false
  ) -> [IAgentSyncPayload] {
    let calendar = Calendar.autoupdatingCurrent
    let startOfDay = calendar.startOfDay(for: referenceDate)
    func today(_ hour: Int, _ minute: Int = 0) -> Date {
      calendar.date(byAdding: .minute, value: hour * 60 + minute, to: startOfDay) ?? referenceDate
    }

    func day(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
      let date = calendar.date(byAdding: .day, value: offset, to: startOfDay) ?? startOfDay
      return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: date) ?? date
    }

    let events = [
      SyncedCalendarEvent(
        id: "fixture-design-sync",
        title: "Design sync",
        startDate: today(10),
        endDate: today(10, 45),
        isAllDay: false,
        calendarTitle: "Work",
        location: "Studio",
        notes: "Review the latest mobile interaction pass and open questions.",
        calendarColorHex: "#3A9DFF",
        linkURLs: [URL(string: "https://meet.google.com/abc-defg-hij")!],
        updatedAt: referenceDate
      ),
      SyncedCalendarEvent(
        id: "fixture-product-review",
        title: "Product review",
        startDate: today(13, 30),
        endDate: today(14, 15),
        isAllDay: false,
        calendarTitle: "Work",
        location: nil,
        notes: "Confirm the release scope and owners.",
        calendarColorHex: "#3A9DFF",
        linkURLs: [],
        updatedAt: referenceDate
      ),
      SyncedCalendarEvent(
        id: "fixture-dinner",
        title: "Dinner with Maya",
        startDate: today(18, 30),
        endDate: today(20),
        isAllDay: false,
        calendarTitle: "Home",
        location: "Bar Iris",
        calendarColorHex: "#7664FF",
        linkURLs: [],
        updatedAt: referenceDate
      ),
      SyncedCalendarEvent(
        id: "fixture-roadmap-workshop",
        title: "Roadmap workshop",
        startDate: day(1, 11),
        endDate: day(1, 12, 30),
        isAllDay: false,
        calendarTitle: "Work",
        location: "Project room",
        notes: "Bring the prioritization notes and Q4 dependency map.",
        calendarColorHex: "#3A9DFF",
        linkURLs: [],
        updatedAt: referenceDate
      ),
      SyncedCalendarEvent(
        id: "fixture-travel-day",
        title: "Travel day",
        startDate: day(2, 0),
        endDate: day(3, 0),
        isAllDay: true,
        calendarTitle: "Personal",
        location: "Athens",
        calendarColorHex: "#FFBD40",
        linkURLs: [],
        updatedAt: referenceDate
      )
    ]

    let threads = [
      SyncedCodexThread(
        id: "fixture-thread-1",
        projectName: "iagent",
        title: "Build mobile companion",
        activity: "Wiring the private CloudKit sync layer",
        activityHistory: [
          SyncedCodexActivity(
            id: "fixture-thread-1-activity-1",
            text: "Mapped the panel's local data into shared sync records",
            occurredAt: referenceDate.addingTimeInterval(-900)
          ),
          SyncedCodexActivity(
            id: "fixture-thread-1-activity-2",
            text: "Wiring the private CloudKit sync layer",
            occurredAt: referenceDate.addingTimeInterval(-120)
          ),
        ],
        state: .running,
        modes: [.plan],
        createdAt: referenceDate.addingTimeInterval(-2_400),
        updatedAt: referenceDate.addingTimeInterval(-120)
      ),
      SyncedCodexThread(
        id: "fixture-thread-2",
        projectName: "pagi",
        title: "Refine ingestion pipeline",
        activity: "Waiting for approval on the migration",
        activityHistory: [
          SyncedCodexActivity(
            id: "fixture-thread-2-activity-1",
            text: "Prepared the migration and paused before applying it",
            occurredAt: referenceDate.addingTimeInterval(-480)
          )
        ],
        state: .needsApproval,
        modes: [.goal],
        createdAt: referenceDate.addingTimeInterval(-7_200),
        updatedAt: referenceDate.addingTimeInterval(-480)
      ),
      SyncedCodexThread(
        id: "fixture-thread-3",
        projectName: "timeline",
        title: "Document release flow",
        activity: "The release guide is ready",
        state: .completed,
        modes: [],
        createdAt: referenceDate.addingTimeInterval(-86_400),
        updatedAt: referenceDate.addingTimeInterval(-3_600)
      )
    ]

    let maya = SyncedMessageParticipant(
      id: "fixture-contact-maya",
      displayName: "Maya Chen",
      isContactNameResolved: true
    )
    let alex = SyncedMessageParticipant(
      id: "fixture-contact-alex",
      displayName: "Alex Rivera",
      isContactNameResolved: true
    )
    let jordan = SyncedMessageParticipant(
      id: "fixture-contact-jordan",
      displayName: "Jordan Lee",
      isContactNameResolved: true
    )
    let mayaMessages = [
      SyncedMessage(
        id: "fixture-message-maya-1",
        conversationID: "fixture-conversation-maya",
        senderID: maya.id,
        senderDisplayName: maya.displayName,
        isFromMe: false,
        body: "Are we still on for dinner tonight?",
        sentAt: referenceDate.addingTimeInterval(-1_800),
        updatedAt: referenceDate.addingTimeInterval(-1_800)
      ),
      SyncedMessage(
        id: "fixture-message-maya-2",
        conversationID: "fixture-conversation-maya",
        isFromMe: true,
        body: "Absolutely — 7:30 still works for me.",
        sentAt: referenceDate.addingTimeInterval(-1_200),
        updatedAt: referenceDate.addingTimeInterval(-1_200)
      ),
      SyncedMessage(
        id: "fixture-message-maya-3",
        conversationID: "fixture-conversation-maya",
        senderID: maya.id,
        senderDisplayName: maya.displayName,
        isFromMe: false,
        body: "Perfect. I booked the table by the window.",
        sentAt: referenceDate.addingTimeInterval(-360),
        updatedAt: referenceDate.addingTimeInterval(-360)
      ),
    ]

    let alexMessages = [
      SyncedMessage(
        id: "fixture-message-alex-1",
        conversationID: "fixture-conversation-alex",
        senderID: alex.id,
        senderDisplayName: alex.displayName,
        isFromMe: false,
        body: "The latest build looks great on my phone.",
        sentAt: referenceDate.addingTimeInterval(-4_200),
        updatedAt: referenceDate.addingTimeInterval(-4_200)
      ),
      SyncedMessage(
        id: "fixture-message-alex-2",
        conversationID: "fixture-conversation-alex",
        isFromMe: true,
        body: "Nice — thank you for checking it.",
        sentAt: referenceDate.addingTimeInterval(-2_700),
        updatedAt: referenceDate.addingTimeInterval(-2_700)
      ),
      SyncedMessage(
        id: "fixture-message-alex-3",
        conversationID: "fixture-conversation-alex",
        senderID: alex.id,
        senderDisplayName: alex.displayName,
        isFromMe: false,
        body: "One more thought when you have a minute.",
        sentAt: referenceDate.addingTimeInterval(-2_100),
        sourceReadAt: referenceDate.addingTimeInterval(-2_000),
        updatedAt: referenceDate.addingTimeInterval(-2_000)
      ),
    ]

    let groupMessages = [
      SyncedMessage(
        id: "fixture-message-group-1",
        conversationID: "fixture-conversation-group",
        senderID: alex.id,
        senderDisplayName: alex.displayName,
        isFromMe: false,
        body: "I shared the weekend itinerary.",
        sentAt: referenceDate.addingTimeInterval(-10_800),
        updatedAt: referenceDate.addingTimeInterval(-10_800)
      ),
      SyncedMessage(
        id: "fixture-message-group-2",
        conversationID: "fixture-conversation-group",
        isFromMe: true,
        body: "The morning train looks best.",
        sentAt: referenceDate.addingTimeInterval(-9_000),
        updatedAt: referenceDate.addingTimeInterval(-9_000)
      ),
      SyncedMessage(
        id: "fixture-message-group-3",
        conversationID: "fixture-conversation-group",
        senderID: jordan.id,
        senderDisplayName: jordan.displayName,
        isFromMe: false,
        body: "Agreed. I can grab the tickets now.",
        sentAt: referenceDate.addingTimeInterval(-7_200),
        updatedAt: referenceDate.addingTimeInterval(-7_200)
      ),
    ]

    let conversations = [
      SyncedMessageConversation(
        id: "fixture-conversation-maya",
        displayName: maya.displayName,
        participants: [maya],
        isGroup: false,
        serviceName: "iMessage",
        latestMessageID: mayaMessages.last!.id,
        latestMessageDate: mayaMessages.last!.sentAt,
        latestPreview: mayaMessages.last!.body,
        awaitingReplyMessageID: mayaMessages.last!.id,
        updatedAt: mayaMessages.last!.updatedAt
      ),
      SyncedMessageConversation(
        id: "fixture-conversation-alex",
        displayName: alex.displayName,
        participants: [alex],
        isGroup: false,
        serviceName: "iMessage",
        latestMessageID: alexMessages.last!.id,
        latestMessageDate: alexMessages.last!.sentAt,
        latestPreview: alexMessages.last!.body,
        awaitingReplyMessageID: alexMessages.last!.id,
        updatedAt: alexMessages.last!.updatedAt
      ),
      SyncedMessageConversation(
        id: "fixture-conversation-group",
        displayName: "Weekend crew",
        participants: [alex, jordan],
        isGroup: true,
        serviceName: "iMessage",
        latestMessageID: groupMessages.last!.id,
        latestMessageDate: groupMessages.last!.sentAt,
        latestPreview: groupMessages.last!.body,
        updatedAt: groupMessages.last!.updatedAt
      ),
    ]

    let messageReadStates = [
      SyncedMessageReadState(
        id: "fixture-conversation-maya",
        readThroughMessageID: mayaMessages.first!.id,
        readThroughDate: mayaMessages.first!.sentAt,
        latestKnownMessageDate: mayaMessages.last!.sentAt,
        updatedAt: mayaMessages.first!.sentAt,
        sourceDeviceID: "fixture-iphone"
      ),
      SyncedMessageReadState(
        id: "fixture-conversation-alex",
        readThroughMessageID: alexMessages.last!.id,
        readThroughDate: alexMessages.last!.sentAt,
        latestKnownMessageDate: alexMessages.last!.sentAt,
        updatedAt: alexMessages.last!.sentAt,
        sourceDeviceID: "fixture-iphone"
      ),
    ]
    let messages = mayaMessages + alexMessages + groupMessages
    let messageRelayState = SyncedMessageRelayState(
      id: "fixture-message-relay",
      phase: .available,
      detail: "Preview data from the local mock provider.",
      updatedAt: referenceDate
    )

    var todos = [
      SyncedTodo(
        title: "Send the mobile sync brief",
        isCompleted: true,
        isStarred: true,
        dueDate: today(17),
        listName: "work",
        completedAt: referenceDate.addingTimeInterval(-600),
        createdAt: referenceDate.addingTimeInterval(-5_400),
        updatedAt: referenceDate.addingTimeInterval(-600)
      ),
      SyncedTodo(
        title: "Book the flight",
        notes: """
        **Trip:** Athens to San Francisco

        - Compare flexible fares
        - [ ] Confirm passport details
        """,
        listName: "personal",
        createdAt: referenceDate.addingTimeInterval(-3_600)
      ),
      SyncedTodo(
        title: "Review meeting notes",
        isCompleted: true,
        dueDate: today(20),
        listName: "work",
        completedAt: referenceDate.addingTimeInterval(-900),
        createdAt: referenceDate.addingTimeInterval(-1_800),
        updatedAt: referenceDate.addingTimeInterval(-900)
      )
    ]

    if includesLongTodoList {
      todos.append(contentsOf: (1 ... 12).map { index in
        SyncedTodo(
          title: "Scroll fixture task \(index)",
          listName: index.isMultiple(of: 2) ? "work" : "personal",
          createdAt: referenceDate.addingTimeInterval(TimeInterval(-index * 90))
        )
      })
    }

    #if DEBUG
    if includesPriorityLiveActivityItems {
      let titles = [
        "Add bug bash",
        "Send release brief",
        "Review launch checklist",
        "Confirm rollout owners",
        "Check release notes",
        "Update support brief",
        "Prepare launch report",
      ]
      todos.append(contentsOf: titles.enumerated().map { index, title in
        SyncedTodo(
          title: title,
          dueDate: referenceDate.addingTimeInterval(TimeInterval((index + 1) * 10 * 60)),
          listName: "work",
          createdAt: referenceDate.addingTimeInterval(TimeInterval(-(index + 1) * 15 * 60))
        )
      })
    }
    #endif

    let meetingTranscript = """
    We reviewed the mobile interaction pass and agreed to keep the first release focused on fast capture and reliable local sync.
    Maya proposed a simpler two-tab meeting note so the summary stays separate from the full transcript.
    Maya will share the revised interaction spec by Friday. Jordan will validate call-audio attribution on the Mac capture path.
    """
    let meetingSummary = """
    ### Product direction

    - Keep the first mobile release focused on fast capture and reliable local sync.
    - Separate the concise meeting summary from the complete transcript.

    ### Decisions

    - Use a two-tab meeting note with Summary and Transcript views.
    - Preserve visible source labels for microphone and call audio.

    ### Next steps

    - Maya will share the revised interaction spec by Friday.
    - Jordan will validate call-audio attribution on the Mac capture path.
    """
    let fixtureMeetingNote = SyncedNote(
      kind: .meeting,
      title: "Design sync",
      body: MeetingNoteContent(summary: meetingSummary, transcript: meetingTranscript).markdown,
      createdAt: referenceDate.addingTimeInterval(-172_800),
      updatedAt: referenceDate.addingTimeInterval(-86_000),
      sourceDeviceID: "fixture-mac"
    )

    var notes = [
      SyncedNote(
        title: "Mobile companion principles",
        body: "# Mobile companion principles\n\nLocal first. Calm hierarchy. Always make sync state legible.",
        createdAt: referenceDate.addingTimeInterval(-86_400),
        updatedAt: referenceDate.addingTimeInterval(-900),
        sourceDeviceID: "fixture-mac"
      ),
      fixtureMeetingNote,
    ]

    if includesLongNoteList {
      var scrollFixtures: [SyncedNote] = []
      for index in 1 ... 18 {
        let createdOffset = TimeInterval(-index * 180)
        let updatedOffset = TimeInterval(-index * 120)
        let note = SyncedNote(
          title: "Scrollable note fixture \(index)",
          body: "Fixture content for validating vertical drawer scrolling.",
          createdAt: referenceDate.addingTimeInterval(createdOffset),
          updatedAt: referenceDate.addingTimeInterval(updatedOffset),
          sourceDeviceID: "fixture-mac"
        )
        scrollFixtures.append(note)
      }
      notes.append(contentsOf: scrollFixtures)
    }

    let meetings = [
      SyncedMeetingSession(
        noteID: fixtureMeetingNote.id,
        title: fixtureMeetingNote.title,
        calendarEventID: "fixture-design-sync",
        sourceDeviceID: fixtureMeetingNote.sourceDeviceID,
        state: .completed,
        startedAt: fixtureMeetingNote.createdAt,
        endedAt: fixtureMeetingNote.createdAt.addingTimeInterval(42 * 60),
        updatedAt: fixtureMeetingNote.updatedAt,
        transcriptSegments: [
          SyncedTranscriptSegment(
            source: .meetingAudio,
            text: "We reviewed the mobile interaction pass and agreed to keep the first release focused on fast capture and reliable local sync.",
            startOffset: 3,
            endOffset: 18
          ),
          SyncedTranscriptSegment(
            source: .microphone,
            text: "Maya proposed a simpler two-tab meeting note so the summary stays separate from the full transcript.",
            startOffset: 19,
            endOffset: 31
          ),
          SyncedTranscriptSegment(
            source: .meetingAudio,
            text: "Maya will share the revised interaction spec by Friday. Jordan will validate call-audio attribution on the Mac capture path.",
            startOffset: 33,
            endOffset: 47
          ),
        ],
        summaryGeneratedAt: fixtureMeetingNote.updatedAt
      )
    ]

    let lists = [
      SyncedTodoList(name: "work", order: 0),
      SyncedTodoList(name: "personal", order: 1)
    ]
    let desktop = SyncedDesktopSnapshot(
      id: "fixture-desktop",
      deviceName: "Platon's MacBook Pro",
      activeCodexCount: threads.filter(\.state.isActive).count,
      openTodoCount: todos.count,
      projectOrder: ["iagent", "pagi", "timeline"],
      generatedAt: referenceDate,
      appVersion: "0.1"
    )

    var payloads: [IAgentSyncPayload] = []
    payloads.append(contentsOf: events.map { .calendarEvent($0) })
    payloads.append(contentsOf: threads.map { .codexThread($0) })
    payloads.append(contentsOf: conversations.map { .messageConversation($0) })
    payloads.append(contentsOf: messages.map { .message($0) })
    payloads.append(contentsOf: messageReadStates.map { .messageReadState($0) })
    payloads.append(.messageRelayState(messageRelayState))
    payloads.append(contentsOf: todos.map { .todo($0) })
    payloads.append(contentsOf: notes.map { .note($0) })
    payloads.append(contentsOf: meetings.map { .meetingSession($0) })
    payloads.append(contentsOf: lists.map { .todoList($0) })
    payloads.append(.desktopSnapshot(desktop))
    return payloads
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}

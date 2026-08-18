import Foundation

public enum IAgentEntityKind: String, Codable, CaseIterable, Hashable, Sendable {
  case note
  case todo
  case todoList
  case meetingSession
  case codexThread
  case calendarEvent
  case desktopSnapshot
  case messageConversation
  case message
  case messageReadState
  case messageRelayState
}

public struct MessageSyncWindow: Sendable, Equatable {
  public static let duration: TimeInterval = 14 * 24 * 60 * 60

  public init() {}

  public static func cutoff(referenceDate: Date = Date()) -> Date {
    referenceDate.addingTimeInterval(-duration)
  }

  public static func includes(
    date: Date,
    referenceDate: Date = Date()
  ) -> Bool {
    date >= cutoff(referenceDate: referenceDate)
  }
}

public enum SyncedCodexState: String, Codable, Sendable, CaseIterable {
  case running
  case waitingForInput
  case needsApproval
  case completed
  case failed

  public var isActive: Bool {
    switch self {
    case .running, .waitingForInput, .needsApproval: true
    case .completed, .failed: false
    }
  }
}

public enum SyncedThreadMode: String, Codable, Sendable, CaseIterable {
  case plan
  case goal
  case voice
}

public enum SyncedCodexAvailability: String, Codable, Sendable, CaseIterable {
  case available
  case unavailable
}

public struct SyncedCodexActivity: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var text: String
  public var occurredAt: Date

  public init(id: String, text: String, occurredAt: Date) {
    self.id = id
    self.text = text
    self.occurredAt = occurredAt
  }
}

/// A bounded excerpt from output the user could see in the Codex task. Hidden
/// reasoning and tool payloads must never be represented by this type.
public struct SyncedCodexOutputExcerpt: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var text: String
  public var occurredAt: Date

  public init(id: String, text: String, occurredAt: Date) {
    self.id = id
    self.text = text
    self.occurredAt = occurredAt
  }
}

public struct SyncedCodexThread: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  /// An opaque, path-free identity that lets clients group the same local workspace.
  public var workspaceID: String?
  public var projectName: String?
  public var title: String
  public var activity: String
  public var activityHistory: [SyncedCodexActivity]?
  public var visibleOutputs: [SyncedCodexOutputExcerpt]?
  public var state: SyncedCodexState
  public var modes: [SyncedThreadMode]
  public var createdAt: Date
  /// The task's source timestamp from Codex. This remains stable during sync reconciliation.
  public var updatedAt: Date
  public var deletedAt: Date?
  /// Sync ordering metadata. Optional so records written by older iAgent versions still decode.
  public var reconciledAt: Date?
  /// Limits authoritative deletion to the Mac that actually observed this task.
  public var sourceDeviceID: String?

  public init(
    id: String,
    workspaceID: String? = nil,
    projectName: String?,
    title: String,
    activity: String,
    activityHistory: [SyncedCodexActivity]? = nil,
    visibleOutputs: [SyncedCodexOutputExcerpt]? = nil,
    state: SyncedCodexState,
    modes: [SyncedThreadMode],
    createdAt: Date,
    updatedAt: Date,
    deletedAt: Date? = nil,
    reconciledAt: Date? = nil,
    sourceDeviceID: String? = nil
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.projectName = projectName
    self.title = title
    self.activity = activity
    self.activityHistory = activityHistory
    self.visibleOutputs = visibleOutputs
    self.state = state
    self.modes = modes
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.reconciledAt = reconciledAt
    self.sourceDeviceID = sourceDeviceID
  }

  public var syncVersionAt: Date {
    reconciledAt ?? updatedAt
  }
}

public struct SyncedCalendarEvent: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var sourceIdentifier: String?
  public var title: String
  public var startDate: Date
  public var endDate: Date
  public var isAllDay: Bool
  public var calendarTitle: String
  public var location: String?
  public var notes: String?
  public var calendarColorHex: String?
  public var linkURLs: [URL]
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: String,
    sourceIdentifier: String? = nil,
    title: String,
    startDate: Date,
    endDate: Date,
    isAllDay: Bool,
    calendarTitle: String,
    location: String?,
    notes: String? = nil,
    calendarColorHex: String? = nil,
    linkURLs: [URL],
    updatedAt: Date,
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.sourceIdentifier = sourceIdentifier
    self.title = title
    self.startDate = startDate
    self.endDate = endDate
    self.isAllDay = isAllDay
    self.calendarTitle = calendarTitle
    self.location = location
    self.notes = notes
    self.calendarColorHex = calendarColorHex
    self.linkURLs = linkURLs
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }

  /// Returns true when two device replicas describe the same calendar occurrence.
  ///
  /// Recurring EventKit events commonly reuse one external identifier across every
  /// occurrence. The occurrence interval therefore remains part of the identity,
  /// even when both records expose the same source identifier.
  public func isSameOccurrence(
    as other: SyncedCalendarEvent,
    timeTolerance: TimeInterval = 1
  ) -> Bool {
    guard isAllDay == other.isAllDay,
          abs(startDate.timeIntervalSince(other.startDate)) <= timeTolerance,
          abs(endDate.timeIntervalSince(other.endDate)) <= timeTolerance
    else {
      return false
    }

    let leftSource = sourceIdentifier?.normalizedCalendarIdentity
    let rightSource = other.sourceIdentifier?.normalizedCalendarIdentity
    if let leftSource, !leftSource.isEmpty,
       let rightSource, !rightSource.isEmpty,
       leftSource == rightSource {
      return true
    }

    return title.normalizedCalendarIdentity == other.title.normalizedCalendarIdentity
      && calendarTitle.normalizedCalendarIdentity == other.calendarTitle.normalizedCalendarIdentity
  }
}

private extension String {
  var normalizedCalendarIdentity: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}

public struct SyncedTodo: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public var title: String
  public var notes: String?
  public var isCompleted: Bool
  public var isStarred: Bool
  public var dueDate: Date?
  public var listName: String?
  public var completedAt: Date?
  public var createdAt: Date
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: UUID = UUID(),
    title: String,
    notes: String? = nil,
    isCompleted: Bool = false,
    isStarred: Bool = false,
    dueDate: Date? = nil,
    listName: String? = nil,
    completedAt: Date? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.notes = notes
    self.isCompleted = isCompleted
    self.isStarred = isStarred
    self.dueDate = dueDate
    self.listName = listName
    self.completedAt = completedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }
}

public struct SyncedTodoList: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public var name: String
  public var order: Int
  public var createdAt: Date
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: UUID = UUID(),
    name: String,
    order: Int,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.order = order
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }
}

public enum SyncedNoteKind: String, Codable, Sendable {
  case note
  case meeting
}

public struct SyncedNote: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public var kind: SyncedNoteKind
  public var title: String
  public var body: String
  public var createdAt: Date
  public var updatedAt: Date
  public var deletedAt: Date?
  public var sourceDeviceID: String
  public var relativeFilePath: String?

  public init(
    id: UUID = UUID(),
    kind: SyncedNoteKind = .note,
    title: String,
    body: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    deletedAt: Date? = nil,
    sourceDeviceID: String,
    relativeFilePath: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.sourceDeviceID = sourceDeviceID
    self.relativeFilePath = relativeFilePath
  }
}

public enum SyncedMeetingState: String, Codable, Sendable {
  case recording
  case completed
  case failed
}

public enum SyncedTranscriptSource: String, Codable, Sendable {
  case microphone
  case meetingAudio
  case unknown
}

public struct SyncedTranscriptSegment: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public var source: SyncedTranscriptSource
  public var text: String
  public var startOffset: TimeInterval?
  public var endOffset: TimeInterval?

  public init(
    id: UUID = UUID(),
    source: SyncedTranscriptSource,
    text: String,
    startOffset: TimeInterval? = nil,
    endOffset: TimeInterval? = nil
  ) {
    self.id = id
    self.source = source
    self.text = text
    self.startOffset = startOffset
    self.endOffset = endOffset
  }
}

public struct SyncedMeetingSession: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public var noteID: UUID
  public var title: String
  public var calendarEventID: String?
  public var sourceDeviceID: String
  public var state: SyncedMeetingState
  public var startedAt: Date
  public var endedAt: Date?
  public var updatedAt: Date
  public var deletedAt: Date?
  public var transcriptSegments: [SyncedTranscriptSegment]?
  public var summaryGeneratedAt: Date?

  public init(
    id: UUID = UUID(),
    noteID: UUID,
    title: String,
    calendarEventID: String? = nil,
    sourceDeviceID: String,
    state: SyncedMeetingState,
    startedAt: Date = Date(),
    endedAt: Date? = nil,
    updatedAt: Date = Date(),
    deletedAt: Date? = nil,
    transcriptSegments: [SyncedTranscriptSegment]? = nil,
    summaryGeneratedAt: Date? = nil
  ) {
    self.id = id
    self.noteID = noteID
    self.title = title
    self.calendarEventID = calendarEventID
    self.sourceDeviceID = sourceDeviceID
    self.state = state
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.transcriptSegments = transcriptSegments
    self.summaryGeneratedAt = summaryGeneratedAt
  }
}

public struct SyncedDesktopSnapshot: Codable, Identifiable, Sendable, Equatable {
  /// How often an open desktop should republish an otherwise unchanged snapshot.
  public static let heartbeatInterval: TimeInterval = 60
  /// A heartbeat older than this no longer proves that the desktop is running.
  public static let freshnessTimeout: TimeInterval = 120

  public let id: String
  public var deviceName: String
  public var activeCodexCount: Int
  /// `nil` means the desktop could not safely read its canonical todo source.
  public var openTodoCount: Int?
  /// `false` means `openTodoCount` is the last known value while the canonical source is unavailable.
  public var todoCountIsAuthoritative: Bool?
  public var projectOrder: [String]
  /// The content-version timestamp. This only changes when the snapshot values change.
  public var generatedAt: Date
  /// The bounded liveness heartbeat. Older payloads decode with this absent.
  public var lastSeenAt: Date?
  public var appVersion: String
  public var deletedAt: Date?
  /// Nil represents a snapshot written before Codex discovery health was synced.
  public var codexAvailability: SyncedCodexAvailability?
  public var codexLastObservedAt: Date?

  public var freshnessDate: Date {
    max(generatedAt, lastSeenAt ?? generatedAt)
  }

  public func isFresh(at date: Date = Date()) -> Bool {
    date.timeIntervalSince(freshnessDate) < Self.freshnessTimeout
  }

  public var hasAuthoritativeTodoCount: Bool {
    todoCountIsAuthoritative ?? true
  }

  public init(
    id: String,
    deviceName: String,
    activeCodexCount: Int,
    openTodoCount: Int?,
    todoCountIsAuthoritative: Bool? = true,
    projectOrder: [String],
    generatedAt: Date,
    lastSeenAt: Date? = nil,
    appVersion: String,
    deletedAt: Date? = nil,
    codexAvailability: SyncedCodexAvailability? = nil,
    codexLastObservedAt: Date? = nil
  ) {
    self.id = id
    self.deviceName = deviceName
    self.activeCodexCount = activeCodexCount
    self.openTodoCount = openTodoCount
    self.todoCountIsAuthoritative = todoCountIsAuthoritative
    self.projectOrder = projectOrder
    self.generatedAt = generatedAt
    self.lastSeenAt = lastSeenAt
    self.appVersion = appVersion
    self.deletedAt = deletedAt
    self.codexAvailability = codexAvailability
    self.codexLastObservedAt = codexLastObservedAt
  }
}

public struct SyncedMessageParticipant: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var displayName: String
  public var isContactNameResolved: Bool?
  public var replyAddress: String?

  public init(
    id: String,
    displayName: String,
    isContactNameResolved: Bool? = nil,
    replyAddress: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.isContactNameResolved = isContactNameResolved
    self.replyAddress = replyAddress
  }
}

public struct SyncedMessageConversation: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var displayName: String
  public var participants: [SyncedMessageParticipant]
  public var isGroup: Bool
  public var serviceName: String?
  public var latestMessageID: String
  public var latestMessageDate: Date
  public var latestPreview: String
  public var awaitingReplyMessageID: String?
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: String,
    displayName: String,
    participants: [SyncedMessageParticipant],
    isGroup: Bool,
    serviceName: String? = nil,
    latestMessageID: String,
    latestMessageDate: Date,
    latestPreview: String,
    awaitingReplyMessageID: String? = nil,
    updatedAt: Date,
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.participants = participants
    self.isGroup = isGroup
    self.serviceName = serviceName
    self.latestMessageID = latestMessageID
    self.latestMessageDate = latestMessageDate
    self.latestPreview = latestPreview
    self.awaitingReplyMessageID = awaitingReplyMessageID
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }
}

public struct SyncedMessage: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var conversationID: String
  public var senderID: String?
  public var senderDisplayName: String?
  public var isFromMe: Bool
  public var body: String
  public var sentAt: Date
  public var sourceReadAt: Date?
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: String,
    conversationID: String,
    senderID: String? = nil,
    senderDisplayName: String? = nil,
    isFromMe: Bool,
    body: String,
    sentAt: Date,
    sourceReadAt: Date? = nil,
    updatedAt: Date,
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.conversationID = conversationID
    self.senderID = senderID
    self.senderDisplayName = senderDisplayName
    self.isFromMe = isFromMe
    self.body = body
    self.sentAt = sentAt
    self.sourceReadAt = sourceReadAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }
}

public struct SyncedMessageReadState: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var readThroughMessageID: String?
  public var readThroughDate: Date?
  public var latestKnownMessageDate: Date
  public var updatedAt: Date
  public var sourceDeviceID: String
  public var deletedAt: Date?

  public init(
    id: String,
    readThroughMessageID: String? = nil,
    readThroughDate: Date? = nil,
    latestKnownMessageDate: Date,
    updatedAt: Date,
    sourceDeviceID: String,
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.readThroughMessageID = readThroughMessageID
    self.readThroughDate = readThroughDate
    self.latestKnownMessageDate = latestKnownMessageDate
    self.updatedAt = updatedAt
    self.sourceDeviceID = sourceDeviceID
    self.deletedAt = deletedAt
  }
}

public enum SyncedMessageRelayPhase: String, Codable, Sendable, CaseIterable {
  case loading
  case available
  case permissionRequired
  case disabled
  case failed
}

public struct SyncedMessageRelayState: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var phase: SyncedMessageRelayPhase
  public var detail: String?
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: String,
    phase: SyncedMessageRelayPhase,
    detail: String? = nil,
    updatedAt: Date,
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.phase = phase
    self.detail = detail
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }
}

public enum IAgentSyncPayload: Codable, Sendable, Equatable {
  case note(SyncedNote)
  case todo(SyncedTodo)
  case todoList(SyncedTodoList)
  case meetingSession(SyncedMeetingSession)
  case codexThread(SyncedCodexThread)
  case calendarEvent(SyncedCalendarEvent)
  case desktopSnapshot(SyncedDesktopSnapshot)
  case messageConversation(SyncedMessageConversation)
  case message(SyncedMessage)
  case messageReadState(SyncedMessageReadState)
  case messageRelayState(SyncedMessageRelayState)

  public var kind: IAgentEntityKind {
    switch self {
    case .note: .note
    case .todo: .todo
    case .todoList: .todoList
    case .meetingSession: .meetingSession
    case .codexThread: .codexThread
    case .calendarEvent: .calendarEvent
    case .desktopSnapshot: .desktopSnapshot
    case .messageConversation: .messageConversation
    case .message: .message
    case .messageReadState: .messageReadState
    case .messageRelayState: .messageRelayState
    }
  }

  public var id: String {
    switch self {
    case let .note(value): value.id.uuidString.lowercased()
    case let .todo(value): value.id.uuidString.lowercased()
    case let .todoList(value): value.id.uuidString.lowercased()
    case let .meetingSession(value): value.id.uuidString.lowercased()
    case let .codexThread(value): value.id
    case let .calendarEvent(value): value.id
    case let .desktopSnapshot(value): value.id
    case let .messageConversation(value): value.id
    case let .message(value): value.id
    case let .messageReadState(value): value.id
    case let .messageRelayState(value): value.id
    }
  }

  public var recordName: String {
    "\(kind.rawValue)_\(id)"
  }

  public var updatedAt: Date {
    switch self {
    case let .note(value): value.updatedAt
    case let .todo(value): value.updatedAt
    case let .todoList(value): value.updatedAt
    case let .meetingSession(value): value.updatedAt
    case let .codexThread(value): value.syncVersionAt
    case let .calendarEvent(value): value.updatedAt
    case let .desktopSnapshot(value): value.freshnessDate
    case let .messageConversation(value): value.updatedAt
    case let .message(value): value.updatedAt
    case let .messageReadState(value): value.updatedAt
    case let .messageRelayState(value): value.updatedAt
    }
  }

  public var deletedAt: Date? {
    switch self {
    case let .note(value): value.deletedAt
    case let .todo(value): value.deletedAt
    case let .todoList(value): value.deletedAt
    case let .meetingSession(value): value.deletedAt
    case let .codexThread(value): value.deletedAt
    case let .calendarEvent(value): value.deletedAt
    case let .desktopSnapshot(value): value.deletedAt
    case let .messageConversation(value): value.deletedAt
    case let .message(value): value.deletedAt
    case let .messageReadState(value): value.deletedAt
    case let .messageRelayState(value): value.deletedAt
    }
  }

  public func deleting(at date: Date = Date()) -> IAgentSyncPayload {
    switch self {
    case .note(var value):
      value.deletedAt = date
      value.updatedAt = date
      return .note(value)
    case .todo(var value):
      value.deletedAt = date
      value.updatedAt = date
      return .todo(value)
    case .todoList(var value):
      value.deletedAt = date
      value.updatedAt = date
      return .todoList(value)
    case .meetingSession(var value):
      value.deletedAt = date
      value.updatedAt = date
      return .meetingSession(value)
    case .codexThread(var value):
      value.deletedAt = date
      value.reconciledAt = date
      return .codexThread(value)
    case .calendarEvent(var value):
      value.deletedAt = date
      value.updatedAt = date
      return .calendarEvent(value)
    case .desktopSnapshot(var value):
      value.deletedAt = date
      value.generatedAt = date
      value.lastSeenAt = date
      return .desktopSnapshot(value)
    case .messageConversation(var value):
      value.deletedAt = date
      value.updatedAt = date
      return .messageConversation(value)
    case .message(var value):
      value.deletedAt = date
      value.updatedAt = date
      return .message(value)
    case .messageReadState(var value):
      value.deletedAt = date
      value.updatedAt = date
      return .messageReadState(value)
    case .messageRelayState(var value):
      value.deletedAt = date
      value.updatedAt = date
      return .messageRelayState(value)
    }
  }

  /// Tombstones a note and every active meeting session that owns transcript data for it.
  public static func cascadingNoteDeletion(
    note: SyncedNote,
    linkedMeetings: [SyncedMeetingSession],
    at date: Date = Date()
  ) -> [IAgentSyncPayload] {
    var noteTombstone = note
    noteTombstone.deletedAt = date
    noteTombstone.updatedAt = date

    let meetingTombstones = linkedMeetings.compactMap { meeting -> IAgentSyncPayload? in
      guard meeting.noteID == note.id, meeting.deletedAt == nil else { return nil }
      return IAgentSyncPayload.meetingSession(meeting).deleting(at: date)
    }
    return [.note(noteTombstone)] + meetingTombstones
  }
}

public struct IAgentDataSnapshot: Sendable, Equatable {
  public var notes: [SyncedNote]
  public var todos: [SyncedTodo]
  public var todoLists: [SyncedTodoList]
  public var meetings: [SyncedMeetingSession]
  public var codexThreads: [SyncedCodexThread]
  public var calendarEvents: [SyncedCalendarEvent]
  public var desktopSnapshot: SyncedDesktopSnapshot?
  public var messageConversations: [SyncedMessageConversation]
  public var messages: [SyncedMessage]
  public var messageReadStates: [SyncedMessageReadState]
  public var messageRelayStates: [SyncedMessageRelayState]
  public var pendingRecordNames: Set<String>
  public var pendingDeletionRecordNames: Set<String>
  public var lastSuccessfulSyncAt: Date?

  public init(
    notes: [SyncedNote] = [],
    todos: [SyncedTodo] = [],
    todoLists: [SyncedTodoList] = [],
    meetings: [SyncedMeetingSession] = [],
    codexThreads: [SyncedCodexThread] = [],
    calendarEvents: [SyncedCalendarEvent] = [],
    desktopSnapshot: SyncedDesktopSnapshot? = nil,
    messageConversations: [SyncedMessageConversation] = [],
    messages: [SyncedMessage] = [],
    messageReadStates: [SyncedMessageReadState] = [],
    messageRelayStates: [SyncedMessageRelayState] = [],
    pendingRecordNames: Set<String> = [],
    pendingDeletionRecordNames: Set<String> = [],
    lastSuccessfulSyncAt: Date? = nil
  ) {
    self.notes = notes
    self.todos = todos
    self.todoLists = todoLists
    self.meetings = meetings
    self.codexThreads = codexThreads
    self.calendarEvents = calendarEvents
    self.desktopSnapshot = desktopSnapshot
    self.messageConversations = messageConversations
    self.messages = messages
    self.messageReadStates = messageReadStates
    self.messageRelayStates = messageRelayStates
    self.pendingRecordNames = pendingRecordNames
    self.pendingDeletionRecordNames = pendingDeletionRecordNames
    self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
  }
}

public struct IAgentLocalSyncDiagnostics: Sendable, Equatable {
  public var totalRecordCount: Int
  public var activeRecordCount: Int
  public var tombstoneRecordCount: Int
  public var activeRecordCountsByKind: [IAgentEntityKind: Int]
  public var pendingRecordCount: Int
  public var pendingRecordNames: [String]
  public var oldestPendingRecordUpdatedAt: Date?
  public var lastSuccessfulSyncAt: Date?
  public var malformedRecordNames: [String]

  public init(
    totalRecordCount: Int = 0,
    activeRecordCount: Int = 0,
    tombstoneRecordCount: Int = 0,
    activeRecordCountsByKind: [IAgentEntityKind: Int] = [:],
    pendingRecordCount: Int = 0,
    pendingRecordNames: [String] = [],
    oldestPendingRecordUpdatedAt: Date? = nil,
    lastSuccessfulSyncAt: Date? = nil,
    malformedRecordNames: [String] = []
  ) {
    self.totalRecordCount = totalRecordCount
    self.activeRecordCount = activeRecordCount
    self.tombstoneRecordCount = tombstoneRecordCount
    self.activeRecordCountsByKind = activeRecordCountsByKind
    self.pendingRecordCount = pendingRecordCount
    self.pendingRecordNames = pendingRecordNames
    self.oldestPendingRecordUpdatedAt = oldestPendingRecordUpdatedAt
    self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    self.malformedRecordNames = malformedRecordNames
  }
}

public extension Notification.Name {
  static let iAgentSyncStoreDidChange = Notification.Name("iAgentSyncStoreDidChange")
  static let iAgentSyncStatusDidChange = Notification.Name("iAgentSyncStatusDidChange")
}

import Foundation

public enum IAgentEntityKind: String, Codable, CaseIterable, Sendable {
  case note
  case todo
  case todoList
  case meetingSession
  case codexThread
  case calendarEvent
  case desktopSnapshot
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

public struct SyncedCodexThread: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var projectName: String?
  public var title: String
  public var activity: String
  public var state: SyncedCodexState
  public var modes: [SyncedThreadMode]
  public var createdAt: Date
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: String,
    projectName: String?,
    title: String,
    activity: String,
    state: SyncedCodexState,
    modes: [SyncedThreadMode],
    createdAt: Date,
    updatedAt: Date,
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.projectName = projectName
    self.title = title
    self.activity = activity
    self.state = state
    self.modes = modes
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }
}

public struct SyncedCalendarEvent: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var title: String
  public var startDate: Date
  public var endDate: Date
  public var isAllDay: Bool
  public var calendarTitle: String
  public var location: String?
  public var linkURLs: [URL]
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: String,
    title: String,
    startDate: Date,
    endDate: Date,
    isAllDay: Bool,
    calendarTitle: String,
    location: String?,
    linkURLs: [URL],
    updatedAt: Date,
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.startDate = startDate
    self.endDate = endDate
    self.isAllDay = isAllDay
    self.calendarTitle = calendarTitle
    self.location = location
    self.linkURLs = linkURLs
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }
}

public struct SyncedTodo: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public var title: String
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
    deletedAt: Date? = nil
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
  }
}

public struct SyncedDesktopSnapshot: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var deviceName: String
  public var activeCodexCount: Int
  public var openTodoCount: Int
  public var projectOrder: [String]
  public var generatedAt: Date
  public var appVersion: String
  public var deletedAt: Date?

  public init(
    id: String,
    deviceName: String,
    activeCodexCount: Int,
    openTodoCount: Int,
    projectOrder: [String],
    generatedAt: Date,
    appVersion: String,
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.deviceName = deviceName
    self.activeCodexCount = activeCodexCount
    self.openTodoCount = openTodoCount
    self.projectOrder = projectOrder
    self.generatedAt = generatedAt
    self.appVersion = appVersion
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

  public var kind: IAgentEntityKind {
    switch self {
    case .note: .note
    case .todo: .todo
    case .todoList: .todoList
    case .meetingSession: .meetingSession
    case .codexThread: .codexThread
    case .calendarEvent: .calendarEvent
    case .desktopSnapshot: .desktopSnapshot
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
    case let .codexThread(value): value.updatedAt
    case let .calendarEvent(value): value.updatedAt
    case let .desktopSnapshot(value): value.generatedAt
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
      value.updatedAt = date
      return .codexThread(value)
    case .calendarEvent(var value):
      value.deletedAt = date
      value.updatedAt = date
      return .calendarEvent(value)
    case .desktopSnapshot(var value):
      value.deletedAt = date
      value.generatedAt = date
      return .desktopSnapshot(value)
    }
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
  public var pendingRecordNames: Set<String>
  public var lastSuccessfulSyncAt: Date?

  public init(
    notes: [SyncedNote] = [],
    todos: [SyncedTodo] = [],
    todoLists: [SyncedTodoList] = [],
    meetings: [SyncedMeetingSession] = [],
    codexThreads: [SyncedCodexThread] = [],
    calendarEvents: [SyncedCalendarEvent] = [],
    desktopSnapshot: SyncedDesktopSnapshot? = nil,
    pendingRecordNames: Set<String> = [],
    lastSuccessfulSyncAt: Date? = nil
  ) {
    self.notes = notes
    self.todos = todos
    self.todoLists = todoLists
    self.meetings = meetings
    self.codexThreads = codexThreads
    self.calendarEvents = calendarEvents
    self.desktopSnapshot = desktopSnapshot
    self.pendingRecordNames = pendingRecordNames
    self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
  }
}

public extension Notification.Name {
  static let iAgentSyncStoreDidChange = Notification.Name("iAgentSyncStoreDidChange")
  static let iAgentSyncStatusDidChange = Notification.Name("iAgentSyncStatusDidChange")
}

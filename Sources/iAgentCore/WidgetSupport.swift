import Foundation

public enum IAgentWidgetConstants {
  public static let appGroupIdentifier = "group.com.platon.iagent"
  public static let projectionFilename = "WidgetProjectionV1.json"

  public static let todosKind = "iAgentTodos"
  public static let notesKind = "iAgentNotes"
  public static let codexKind = "iAgentCodex"
  public static let createKind = "iAgentCreate"

  public static let lockScreenOverviewKind = "iAgentLockScreenOverview"
  public static let lockScreenNextMeetingKind = "iAgentLockScreenNextMeeting"
  public static let lockScreenCodexKind = "iAgentLockScreenCodex"
  public static let lockScreenCalendarKind = "iAgentLockScreenCalendar"
  public static let lockScreenTodosKind = "iAgentLockScreenTodos"
  public static let lockScreenNotesKind = "iAgentLockScreenNotes"
}

public enum IAgentDeepLink: Sendable, Equatable {
  case todos
  case createTodo
  case todo(UUID)
  case notes
  case createNote
  case note(UUID)
  case calendar
  case meetingReady
  case codex
  case createCodexRequest
  case codexThread(String)

  public init?(url: URL) {
    guard url.scheme?.lowercased() == "iagent",
          url.user == nil,
          url.password == nil,
          url.port == nil,
          url.query == nil,
          url.fragment == nil,
          let host = url.host?.lowercased()
    else { return nil }

    let components = url.pathComponents.filter { $0 != "/" }
    switch host {
    case "todos":
      if components.isEmpty {
        self = .todos
      } else if components == ["create"] {
        self = .createTodo
      } else if components.count == 1, let id = UUID(uuidString: components[0]) {
        self = .todo(id)
      } else {
        return nil
      }
    case "notes":
      if components.isEmpty {
        self = .notes
      } else if components == ["create"] {
        self = .createNote
      } else if components.count == 1, let id = UUID(uuidString: components[0]) {
        self = .note(id)
      } else {
        return nil
      }
    case "meetings":
      guard components == ["record"] else { return nil }
      self = .meetingReady
    case "calendar":
      guard components.isEmpty else { return nil }
      self = .calendar
    case "codex":
      if components.isEmpty {
        self = .codex
      } else if components == ["create"] {
        self = .createCodexRequest
      } else if components.count == 1, Self.isSafeOpaqueIdentifier(components[0]) {
        self = .codexThread(components[0])
      } else {
        return nil
      }
    default:
      return nil
    }
  }

  public var url: URL {
    let value: String
    switch self {
    case .todos: value = "iagent://todos"
    case .createTodo: value = "iagent://todos/create"
    case .todo(let id): value = "iagent://todos/\(id.uuidString.lowercased())"
    case .notes: value = "iagent://notes"
    case .createNote: value = "iagent://notes/create"
    case .note(let id): value = "iagent://notes/\(id.uuidString.lowercased())"
    case .calendar: value = "iagent://calendar"
    case .meetingReady: value = "iagent://meetings/record"
    case .codex: value = "iagent://codex"
    case .createCodexRequest: value = "iagent://codex/create"
    case .codexThread(let id):
      var allowed = CharacterSet.alphanumerics
      allowed.insert(charactersIn: "-._~:")
      let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
      value = "iagent://codex/\(encoded)"
    }
    return URL(string: value)!
  }

  static func isSafeOpaqueIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
    return value.unicodeScalars.allSatisfy(allowed.contains)
  }
}

public struct IAgentWidgetProjection: Codable, Sendable, Equatable {
  public static let schemaVersion = 1
  public static let maximumItemsPerSection = 8

  public struct Todo: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let isStarred: Bool
    public let dueDate: Date?
    public let listName: String?

    public init(id: UUID, title: String, isStarred: Bool, dueDate: Date?, listName: String?) {
      self.id = id
      self.title = title
      self.isStarred = isStarred
      self.dueDate = dueDate
      self.listName = listName
    }
  }

  public struct Note: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let isMeeting: Bool
    public let updatedAt: Date

    public init(id: UUID, title: String, isMeeting: Bool, updatedAt: Date) {
      self.id = id
      self.title = title
      self.isMeeting = isMeeting
      self.updatedAt = updatedAt
    }
  }

  public enum CodexState: String, Codable, Sendable, Equatable {
    case running
    case waitingForInput
    case needsApproval
    case completed
    case failed

    init(_ state: SyncedCodexState) {
      self = switch state {
      case .running: .running
      case .waitingForInput: .waitingForInput
      case .needsApproval: .needsApproval
      case .completed: .completed
      case .failed: .failed
      }
    }
  }

  public struct CodexTask: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let projectName: String?
    public let state: CodexState
    public let startedAt: Date?
    public let updatedAt: Date

    public init(
      id: String,
      title: String,
      projectName: String?,
      state: CodexState,
      startedAt: Date? = nil,
      updatedAt: Date
    ) {
      self.id = id
      self.title = title
      self.projectName = projectName
      self.state = state
      self.startedAt = startedAt
      self.updatedAt = updatedAt
    }
  }

  /// The only calendar detail projected onto the Lock Screen. Event notes,
  /// locations, links, calendar names, and identifiers deliberately stay in-app.
  public struct NextMeeting: Codable, Sendable, Equatable {
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool

    public init(title: String, start: Date, end: Date, isAllDay: Bool) {
      self.title = title
      self.start = start
      self.end = end
      self.isAllDay = isAllDay
    }
  }

  public let version: Int
  public let generatedAt: Date
  public let lastSuccessfulSyncAt: Date?
  public let openTodoCount: Int
  public let activeCodexCount: Int
  public let codexAttentionCount: Int
  public let todayCalendarEventCount: Int
  public let noteCount: Int
  public let nextMeeting: NextMeeting?
  public let todos: [Todo]
  public let notes: [Note]
  public let codexTasks: [CodexTask]

  public init(
    version: Int = schemaVersion,
    generatedAt: Date,
    lastSuccessfulSyncAt: Date?,
    openTodoCount: Int,
    activeCodexCount: Int,
    codexAttentionCount: Int,
    todayCalendarEventCount: Int = 0,
    noteCount: Int? = nil,
    nextMeeting: NextMeeting? = nil,
    todos: [Todo],
    notes: [Note],
    codexTasks: [CodexTask]
  ) {
    self.version = version
    self.generatedAt = generatedAt
    self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    self.openTodoCount = openTodoCount
    self.activeCodexCount = activeCodexCount
    self.codexAttentionCount = codexAttentionCount
    self.todayCalendarEventCount = max(0, todayCalendarEventCount)
    self.noteCount = max(0, noteCount ?? notes.count)
    self.nextMeeting = nextMeeting
    self.todos = Array(todos.prefix(Self.maximumItemsPerSection))
    self.notes = Array(notes.prefix(Self.maximumItemsPerSection))
    self.codexTasks = Array(codexTasks.prefix(Self.maximumItemsPerSection))
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case generatedAt
    case lastSuccessfulSyncAt
    case openTodoCount
    case activeCodexCount
    case codexAttentionCount
    case todayCalendarEventCount
    case noteCount
    case nextMeeting
    case todos
    case notes
    case codexTasks
  }

  /// New Lock Screen summary fields intentionally decode with safe defaults so
  /// an already-written V1 projection remains usable after an app update.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedNotes = try container.decode([Note].self, forKey: .notes)

    self.init(
      version: try container.decode(Int.self, forKey: .version),
      generatedAt: try container.decode(Date.self, forKey: .generatedAt),
      lastSuccessfulSyncAt: try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulSyncAt),
      openTodoCount: try container.decode(Int.self, forKey: .openTodoCount),
      activeCodexCount: try container.decode(Int.self, forKey: .activeCodexCount),
      codexAttentionCount: try container.decode(Int.self, forKey: .codexAttentionCount),
      todayCalendarEventCount: try container.decodeIfPresent(
        Int.self,
        forKey: .todayCalendarEventCount
      ) ?? 0,
      noteCount: try container.decodeIfPresent(Int.self, forKey: .noteCount) ?? decodedNotes.count,
      nextMeeting: try container.decodeIfPresent(NextMeeting.self, forKey: .nextMeeting),
      todos: try container.decode([Todo].self, forKey: .todos),
      notes: decodedNotes,
      codexTasks: try container.decode([CodexTask].self, forKey: .codexTasks)
    )
  }

  public static func make(
    from snapshot: IAgentDataSnapshot,
    generatedAt: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent,
    supplementalCalendarEvents: [SyncedCalendarEvent] = []
  ) -> IAgentWidgetProjection {
    let openTodos = snapshot.todos
      .filter { !$0.isCompleted && $0.deletedAt == nil }
      .sorted(by: todoSort)
    let visibleNotes = snapshot.notes
      .filter { $0.deletedAt == nil }
      .sorted { $0.updatedAt > $1.updatedAt }
    let visibleTasks = snapshot.codexThreads
      .filter { $0.deletedAt == nil && IAgentDeepLink.isSafeOpaqueIdentifier($0.id) }
      .sorted(by: codexSort)
    let activeTasks = visibleTasks.filter(\.state.isActive)
    let calendarEvents = coalescedCalendarEvents(
      snapshot.calendarEvents + supplementalCalendarEvents
    )
    let dayStart = calendar.startOfDay(for: generatedAt)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? generatedAt
    let todayCalendarEvents = calendarEvents.filter {
      $0.deletedAt == nil && $0.startDate < dayEnd && $0.endDate > dayStart
    }
    let nextCalendarEvent = calendarEvents
      .filter { $0.deletedAt == nil && !$0.isAllDay && $0.endDate > generatedAt }
      .sorted { lhs, rhs in
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        return lhs.endDate < rhs.endDate
      }
      .first

    return IAgentWidgetProjection(
      generatedAt: generatedAt,
      lastSuccessfulSyncAt: snapshot.lastSuccessfulSyncAt,
      openTodoCount: openTodos.count,
      activeCodexCount: activeTasks.count,
      codexAttentionCount: activeTasks.filter {
        $0.state == .needsApproval || $0.state == .waitingForInput
      }.count,
      todayCalendarEventCount: todayCalendarEvents.count,
      noteCount: visibleNotes.count,
      nextMeeting: nextCalendarEvent.map {
        NextMeeting(
          title: sanitized($0.title, fallback: "Untitled event", maximumLength: 80),
          start: $0.startDate,
          end: $0.endDate,
          isAllDay: $0.isAllDay
        )
      },
      todos: openTodos.map {
        Todo(
          id: $0.id,
          title: sanitized($0.title, fallback: "Untitled todo"),
          isStarred: $0.isStarred,
          dueDate: $0.dueDate,
          listName: sanitizedOptional($0.listName, maximumLength: 40)
        )
      },
      notes: visibleNotes.map {
        Note(
          id: $0.id,
          title: sanitized($0.title, fallback: "Untitled note"),
          isMeeting: $0.kind == .meeting,
          updatedAt: $0.updatedAt
        )
      },
      codexTasks: visibleTasks.map {
        CodexTask(
          id: $0.id,
          title: sanitized($0.title, fallback: "Untitled task"),
          projectName: sanitizedProjectName($0.projectName),
          state: CodexState($0.state),
          startedAt: $0.createdAt,
          updatedAt: $0.updatedAt
        )
      }
    )
  }

  public static func empty(at date: Date = Date()) -> IAgentWidgetProjection {
    IAgentWidgetProjection(
      generatedAt: date,
      lastSuccessfulSyncAt: nil,
      openTodoCount: 0,
      activeCodexCount: 0,
      codexAttentionCount: 0,
      todayCalendarEventCount: 0,
      noteCount: 0,
      nextMeeting: nil,
      todos: [],
      notes: [],
      codexTasks: []
    )
  }

  private static func todoSort(_ lhs: SyncedTodo, _ rhs: SyncedTodo) -> Bool {
    if lhs.isStarred != rhs.isStarred { return lhs.isStarred }
    switch (lhs.dueDate, rhs.dueDate) {
    case let (.some(left), .some(right)) where left != right: return left < right
    case (.some, .none): return true
    case (.none, .some): return false
    default: return lhs.createdAt > rhs.createdAt
    }
  }

  private static func codexSort(_ lhs: SyncedCodexThread, _ rhs: SyncedCodexThread) -> Bool {
    let leftRank = codexRank(lhs.state)
    let rightRank = codexRank(rhs.state)
    return leftRank == rightRank ? lhs.updatedAt > rhs.updatedAt : leftRank < rightRank
  }

  private static func coalescedCalendarEvents(
    _ events: [SyncedCalendarEvent]
  ) -> [SyncedCalendarEvent] {
    var result: [SyncedCalendarEvent] = []
    for event in events where event.deletedAt == nil {
      guard let existingIndex = result.firstIndex(where: { $0.isSameOccurrence(as: event) }) else {
        result.append(event)
        continue
      }
      if event.updatedAt > result[existingIndex].updatedAt {
        result[existingIndex] = event
      }
    }
    return result
  }

  private static func codexRank(_ state: SyncedCodexState) -> Int {
    switch state {
    case .needsApproval, .waitingForInput: 0
    case .running: 1
    case .failed: 2
    case .completed: 3
    }
  }

  private static func sanitized(
    _ value: String,
    fallback: String,
    maximumLength: Int = 120
  ) -> String {
    let cleaned = value
      .unicodeScalars
      .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
      .joined()
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    let bounded = String(cleaned.prefix(maximumLength))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return bounded.isEmpty ? fallback : bounded
  }

  private static func sanitizedOptional(
    _ value: String?,
    maximumLength: Int
  ) -> String? {
    guard let value else { return nil }
    let result = sanitized(value, fallback: "", maximumLength: maximumLength)
    return result.isEmpty ? nil : result
  }

  private static func sanitizedProjectName(_ value: String?) -> String? {
    guard let value = sanitizedOptional(value, maximumLength: 512) else { return nil }
    let leaf = value
      .split(whereSeparator: { $0 == "/" || $0 == "\\" })
      .last
      .map(String.init)
    guard let leaf, leaf != ".", leaf != ".." else { return nil }
    return sanitizedOptional(leaf, maximumLength: 48)
  }
}

public struct IAgentWidgetProjectionStore: Sendable {
  public enum StoreError: Error, Equatable {
    case incompatibleVersion(Int)
  }

  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func appGroupStore(
    fileManager: FileManager = .default
  ) -> IAgentWidgetProjectionStore? {
    guard let container = fileManager.containerURL(
      forSecurityApplicationGroupIdentifier: IAgentWidgetConstants.appGroupIdentifier
    ) else { return nil }
    return IAgentWidgetProjectionStore(
      fileURL: container.appendingPathComponent(IAgentWidgetConstants.projectionFilename)
    )
  }

  public func load() throws -> IAgentWidgetProjection {
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let projection = try decoder.decode(IAgentWidgetProjection.self, from: data)
    guard projection.version == IAgentWidgetProjection.schemaVersion else {
      throw StoreError.incompatibleVersion(projection.version)
    }
    return projection
  }

  public func save(_ projection: IAgentWidgetProjection) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(projection).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}

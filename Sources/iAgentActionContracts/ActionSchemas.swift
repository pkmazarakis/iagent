import Foundation

public enum AssistantActionCapability: String, Codable, CaseIterable, Sendable {
  case createTodo
  case createNote
  case draftCalendarEvent
  case requestCodexTask

  public var settingsTitle: String {
    switch self {
    case .createTodo: "Create todos"
    case .createNote: "Create notes"
    case .draftCalendarEvent: "Draft calendar events"
    case .requestCodexTask: "Prepare Codex requests"
    }
  }

  public var settingsExplanation: String {
    "Lets iAgent prepare a review card. Committing it still requires your current explicit confirmation."
  }

  public var defaultScopeID: String {
    switch self {
    case .createTodo: "todos:local"
    case .createNote: "notes:local"
    case .draftCalendarEvent: "calendar:native-editor"
    case .requestCodexTask: "codex:handoff"
    }
  }
}

public struct AssistantActionCapabilityRule: Codable, Equatable, Sendable {
  public var mayPrepare: Bool
  public var allowedScopeIDs: Set<String>

  public init(mayPrepare: Bool = false, allowedScopeIDs: Set<String> = []) {
    self.mayPrepare = mayPrepare
    self.allowedScopeIDs = allowedScopeIDs
  }
}

public struct AssistantActionCapabilityPolicy: Codable, Equatable, Sendable {
  public var rules: [AssistantActionCapability: AssistantActionCapabilityRule]

  public init(
    rules: [AssistantActionCapability: AssistantActionCapabilityRule] = [:]
  ) {
    self.rules = Dictionary(
      uniqueKeysWithValues: AssistantActionCapability.allCases.map { capability in
        (capability, rules[capability] ?? AssistantActionCapabilityRule())
      }
    )
  }

  public static let allDisabled = AssistantActionCapabilityPolicy()

  /// The preparation policy used when no saved user preference exists.
  ///
  /// This exposes proposal tools only. It does not grant commit authority: the broker still
  /// requires a current, single-use confirmation, permission checks, and target revalidation.
  public static let allPreparationEnabled: AssistantActionCapabilityPolicy = {
    var policy = AssistantActionCapabilityPolicy.allDisabled
    for capability in AssistantActionCapability.allCases {
      policy.setPreparationEnabled(true, for: capability)
    }
    return policy
  }()

  public func allowsPreparation(
    capability: AssistantActionCapability,
    scopeID: String
  ) -> Bool {
    guard let rule = rules[capability], rule.mayPrepare else { return false }
    return rule.allowedScopeIDs.contains(scopeID)
  }

  public mutating func setPreparationEnabled(
    _ enabled: Bool,
    for capability: AssistantActionCapability,
    scopeIDs: Set<String>? = nil
  ) {
    let scopes = scopeIDs
      ?? (enabled ? [capability.defaultScopeID] : [])
    rules[capability] = AssistantActionCapabilityRule(
      mayPrepare: enabled,
      allowedScopeIDs: scopes
    )
  }
}

public struct AssistantActionScope: Codable, Equatable, Hashable, Sendable {
  public let id: String
  public let displayName: String

  public init(id: String, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

public struct AssistantActionDateTime: Codable, Equatable, Sendable {
  public let instant: Date
  public let rfc3339: String
  public let timeZoneID: String

  public init(instant: Date, rfc3339: String, timeZoneID: String) {
    self.instant = instant
    self.rfc3339 = rfc3339
    self.timeZoneID = timeZoneID
  }
}

public struct CreateTodoActionPayload: Codable, Equatable, Sendable {
  public let title: String
  public let dueAt: AssistantActionDateTime?
  public let listName: String?

  public init(
    title: String,
    dueAt: AssistantActionDateTime?,
    listName: String?
  ) {
    self.title = title
    self.dueAt = dueAt
    self.listName = listName
  }
}

public struct CreateNoteActionPayload: Codable, Equatable, Sendable {
  public let title: String
  public let body: String

  public init(title: String, body: String) {
    self.title = title
    self.body = body
  }
}

public struct CalendarEventDraftActionPayload: Codable, Equatable, Sendable {
  public let title: String
  public let start: AssistantActionDateTime
  public let end: AssistantActionDateTime
  public let isAllDay: Bool
  public let calendarIdentifier: String?
  public let location: String?
  public let notes: String?

  public init(
    title: String,
    start: AssistantActionDateTime,
    end: AssistantActionDateTime,
    isAllDay: Bool,
    calendarIdentifier: String?,
    location: String?,
    notes: String?
  ) {
    self.title = title
    self.start = start
    self.end = end
    self.isAllDay = isAllDay
    self.calendarIdentifier = calendarIdentifier
    self.location = location
    self.notes = notes
  }
}

public struct CodexTaskRequestActionPayload: Codable, Equatable, Sendable {
  public let prompt: String
  public let workspaceIdentifier: String?

  public init(prompt: String, workspaceIdentifier: String?) {
    self.prompt = prompt
    self.workspaceIdentifier = workspaceIdentifier
  }
}

public enum AssistantActionPayload: Equatable, Sendable {
  case createTodo(CreateTodoActionPayload)
  case createNote(CreateNoteActionPayload)
  case calendarDraft(CalendarEventDraftActionPayload)
  case codexTaskRequest(CodexTaskRequestActionPayload)

  public var capability: AssistantActionCapability {
    switch self {
    case .createTodo: .createTodo
    case .createNote: .createNote
    case .calendarDraft: .draftCalendarEvent
    case .codexTaskRequest: .requestCodexTask
    }
  }
}

extension AssistantActionPayload: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case value
  }

  private enum PayloadType: String, Codable {
    case createTodo
    case createNote
    case calendarDraft
    case codexTaskRequest
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(PayloadType.self, forKey: .type) {
    case .createTodo:
      self = .createTodo(try container.decode(CreateTodoActionPayload.self, forKey: .value))
    case .createNote:
      self = .createNote(try container.decode(CreateNoteActionPayload.self, forKey: .value))
    case .calendarDraft:
      self = .calendarDraft(
        try container.decode(CalendarEventDraftActionPayload.self, forKey: .value)
      )
    case .codexTaskRequest:
      self = .codexTaskRequest(
        try container.decode(CodexTaskRequestActionPayload.self, forKey: .value)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .createTodo(value):
      try container.encode(PayloadType.createTodo, forKey: .type)
      try container.encode(value, forKey: .value)
    case let .createNote(value):
      try container.encode(PayloadType.createNote, forKey: .type)
      try container.encode(value, forKey: .value)
    case let .calendarDraft(value):
      try container.encode(PayloadType.calendarDraft, forKey: .type)
      try container.encode(value, forKey: .value)
    case let .codexTaskRequest(value):
      try container.encode(PayloadType.codexTaskRequest, forKey: .type)
      try container.encode(value, forKey: .value)
    }
  }
}

public struct AssistantActionReviewField: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let label: String
  public let before: String
  public let after: String

  public init(id: String, label: String, before: String, after: String) {
    self.id = id
    self.label = label
    self.before = before
    self.after = after
  }
}

public struct AssistantActionReviewCard: Codable, Equatable, Sendable {
  public let title: String
  public let explanation: String
  public let primaryVerb: String
  public let cancelVerb: String
  public let fields: [AssistantActionReviewField]
  public let canonicalPayloadJSON: String
  public let requiresNativeHandoff: Bool

  public init(
    title: String,
    explanation: String,
    primaryVerb: String,
    cancelVerb: String = "Cancel",
    fields: [AssistantActionReviewField],
    canonicalPayloadJSON: String,
    requiresNativeHandoff: Bool
  ) {
    self.title = title
    self.explanation = explanation
    self.primaryVerb = primaryVerb
    self.cancelVerb = cancelVerb
    self.fields = fields
    self.canonicalPayloadJSON = canonicalPayloadJSON
    self.requiresNativeHandoff = requiresNativeHandoff
  }
}

public enum AssistantActionAuthorizationOrigin: String, Codable, Sendable {
  case currentUserMessage
  case storedContent
  case modelInference
}

public struct AssistantActionProvenance: Codable, Equatable, Sendable {
  public let conversationID: String
  public let turnID: String
  public let currentUserMessageID: String
  public let toolCallID: String

  public init(
    conversationID: String,
    turnID: String,
    currentUserMessageID: String,
    toolCallID: String
  ) {
    self.conversationID = conversationID
    self.turnID = turnID
    self.currentUserMessageID = currentUserMessageID
    self.toolCallID = toolCallID
  }
}

public struct AssistantActionIntent: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let schemaVersion: Int
  public let proposalDigest: String
  public let capability: AssistantActionCapability
  public let scope: AssistantActionScope
  public let payload: AssistantActionPayload
  public let review: AssistantActionReviewCard
  public let provenance: AssistantActionProvenance
  public let createdAt: Date
  public let expiresAt: Date

  package init(
    id: String,
    schemaVersion: Int = 1,
    proposalDigest: String,
    capability: AssistantActionCapability,
    scope: AssistantActionScope,
    payload: AssistantActionPayload,
    review: AssistantActionReviewCard,
    provenance: AssistantActionProvenance,
    createdAt: Date,
    expiresAt: Date
  ) {
    self.id = id
    self.schemaVersion = schemaVersion
    self.proposalDigest = proposalDigest
    self.capability = capability
    self.scope = scope
    self.payload = payload
    self.review = review
    self.provenance = provenance
    self.createdAt = createdAt
    self.expiresAt = expiresAt
  }
}

public struct AssistantProposalToolDefinition: Equatable, Sendable {
  public let name: String
  public let description: String
  public let strict: Bool
  public let parametersJSON: String

  public init(name: String, description: String, strict: Bool, parametersJSON: String) {
    self.name = name
    self.description = description
    self.strict = strict
    self.parametersJSON = parametersJSON
  }
}

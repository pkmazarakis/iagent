@preconcurrency import CloudKit
import Foundation

public enum AskChatRole: String, Codable, Sendable, Equatable {
  case user
  case assistant
}

public enum AskChatMessageState: String, Codable, Sendable, Equatable {
  case completed
  case interrupted
}

/// A stable reference to the exact source revision used for a grounded answer.
public struct AskChatCitation: Codable, Identifiable, Sendable, Equatable, Hashable {
  public let id: String
  public var sourceKind: String
  public var entityID: String
  public var revision: String
  public var anchor: String?
  public var retrievedAt: Date

  public init(
    id: String,
    sourceKind: String,
    entityID: String,
    revision: String,
    anchor: String? = nil,
    retrievedAt: Date
  ) {
    self.id = id
    self.sourceKind = sourceKind
    self.entityID = entityID
    self.revision = revision
    self.anchor = anchor
    self.retrievedAt = retrievedAt
  }
}

/// A compact, historical rendering fallback. Live source rows are always rebuilt from
/// the current local replica; this snapshot is used only when the source changed or vanished.
public struct AskChatSourceSnapshot: Codable, Identifiable, Sendable, Equatable, Hashable {
  public let id: String
  public var sourceKind: String
  public var title: String
  public var metadata: String?
  public var excerpt: String?
  public var citation: AskChatCitation

  public init(
    id: String,
    sourceKind: String,
    title: String,
    metadata: String? = nil,
    excerpt: String? = nil,
    citation: AskChatCitation
  ) {
    self.id = id
    self.sourceKind = sourceKind
    self.title = title
    self.metadata = metadata
    self.excerpt = excerpt
    self.citation = citation
  }
}

public struct AskChatMessage: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public var role: AskChatRole
  public var text: String
  public var createdAt: Date
  public var contextAsOf: Date?
  /// The user-facing route that produced an assistant response (`free`, `fast`, or `pro`).
  /// Optional so conversations written before per-response route metadata still decode.
  public var modelTier: String?
  public var state: AskChatMessageState
  public var citations: [AskChatCitation]
  public var sourceSnapshots: [AskChatSourceSnapshot]

  public init(
    id: UUID = UUID(),
    role: AskChatRole,
    text: String,
    createdAt: Date = Date(),
    contextAsOf: Date? = nil,
    modelTier: String? = nil,
    state: AskChatMessageState = .completed,
    citations: [AskChatCitation] = [],
    sourceSnapshots: [AskChatSourceSnapshot] = []
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.createdAt = createdAt
    self.contextAsOf = contextAsOf
    self.modelTier = modelTier
    self.state = state
    self.citations = citations
    self.sourceSnapshots = sourceSnapshots
  }
}

public struct AskChatConversation: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var messages: [AskChatMessage]
  public var deletedAt: Date?

  public init(
    id: UUID = UUID(),
    title: String = "New chat",
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    messages: [AskChatMessage] = [],
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.messages = messages
    self.deletedAt = deletedAt
  }
}

public struct AskChatHistoryStatus: Sendable, Equatable {
  public enum Phase: String, Sendable {
    case idle
    case syncing
    case offline
    case accountUnavailable
    case failed
  }

  public var phase: Phase
  public var lastSuccessfulSyncAt: Date?
  public var message: String?

  public init(
    phase: Phase = .idle,
    lastSuccessfulSyncAt: Date? = nil,
    message: String? = nil
  ) {
    self.phase = phase
    self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    self.message = message
  }
}

private struct PersistedAskChatHistory: Codable, Sendable {
  var conversations: [UUID: AskChatConversation] = [:]
  var pendingConversationIDs: Set<UUID> = []
  var lastSuccessfulSyncAt: Date?
}

public actor AskChatHistoryStore {
  public let fileURL: URL
  private var state: PersistedAskChatHistory

  public init(fileURL: URL) {
    self.fileURL = fileURL
    self.state = Self.load(from: fileURL)
  }

  public static func defaultFileURL(appIdentifier: String) -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return
      base
      .appendingPathComponent(appIdentifier, isDirectory: true)
      .appendingPathComponent("ask-chat-history.json")
  }

  public func conversations(includingDeleted: Bool = false) -> [AskChatConversation] {
    state.conversations.values
      .filter { includingDeleted || $0.deletedAt == nil }
      .sorted {
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  public func conversation(id: UUID) -> AskChatConversation? {
    state.conversations[id]
  }

  @discardableResult
  public func createConversation(
    title: String = "New chat",
    at date: Date = Date()
  ) throws -> AskChatConversation {
    let conversation = AskChatConversation(
      title: Self.boundedTitle(title),
      createdAt: date,
      updatedAt: date
    )
    state.conversations[conversation.id] = conversation
    state.pendingConversationIDs.insert(conversation.id)
    try persist()
    return conversation
  }

  @discardableResult
  public func append(
    _ message: AskChatMessage,
    to conversationID: UUID,
    title: String? = nil
  ) throws -> AskChatConversation? {
    guard var conversation = state.conversations[conversationID], conversation.deletedAt == nil
    else {
      return nil
    }
    let bounded = Self.boundedMessage(message)
    if !conversation.messages.contains(where: { $0.id == bounded.id }) {
      conversation.messages.append(bounded)
    }
    conversation.messages = Array(
      conversation.messages
        .sorted {
          $0.createdAt == $1.createdAt
            ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        .suffix(Self.maximumMessagesPerConversation)
    )
    if let title {
      conversation.title = Self.boundedTitle(title)
    } else if conversation.title == "New chat", bounded.role == .user {
      conversation.title = Self.boundedTitle(bounded.text)
    }
    conversation.updatedAt = max(conversation.updatedAt, bounded.createdAt)
    state.conversations[conversationID] = conversation
    state.pendingConversationIDs.insert(conversationID)
    try persist()
    return conversation
  }

  public func deleteConversation(id: UUID, at date: Date = Date()) throws {
    guard var conversation = state.conversations[id] else { return }
    conversation.deletedAt = date
    conversation.updatedAt = max(conversation.updatedAt, date)
    state.conversations[id] = conversation
    state.pendingConversationIDs.insert(id)
    try persist()
  }

  public func clear(at date: Date = Date()) throws {
    for id in state.conversations.keys {
      guard var conversation = state.conversations[id], conversation.deletedAt == nil else {
        continue
      }
      conversation.deletedAt = date
      conversation.updatedAt = max(conversation.updatedAt, date)
      state.conversations[id] = conversation
      state.pendingConversationIDs.insert(id)
    }
    try persist()
  }

  public func pendingConversations() -> [AskChatConversation] {
    state.pendingConversationIDs.compactMap { state.conversations[$0] }
  }

  /// Merges immutable messages by ID. A tombstone always wins; otherwise the newer
  /// conversation metadata wins while the message union prevents concurrent device loss.
  @discardableResult
  public func mergeRemote(_ remote: AskChatConversation) throws -> AskChatConversation {
    let boundedRemote = Self.boundedConversation(remote)
    guard let local = state.conversations[remote.id] else {
      state.conversations[remote.id] = boundedRemote
      state.pendingConversationIDs.remove(remote.id)
      try persist()
      return boundedRemote
    }

    let merged = Self.merge(local: local, remote: boundedRemote)
    state.conversations[remote.id] = merged
    if merged != boundedRemote {
      state.pendingConversationIDs.insert(remote.id)
    } else {
      state.pendingConversationIDs.remove(remote.id)
    }
    try persist()
    return merged
  }

  public func markSynced(
    conversationID: UUID,
    expectedUpdatedAt: Date,
    at date: Date = Date()
  ) throws {
    if state.conversations[conversationID]?.updatedAt == expectedUpdatedAt {
      state.pendingConversationIDs.remove(conversationID)
    }
    state.lastSuccessfulSyncAt = date
    try persist()
  }

  public func lastSuccessfulSyncAt() -> Date? {
    state.lastSuccessfulSyncAt
  }

  private static func merge(
    local: AskChatConversation,
    remote: AskChatConversation
  ) -> AskChatConversation {
    if let localDeletion = local.deletedAt, let remoteDeletion = remote.deletedAt {
      return localDeletion >= remoteDeletion ? local : remote
    }
    if local.deletedAt != nil { return local }
    if remote.deletedAt != nil { return remote }

    let newer = local.updatedAt >= remote.updatedAt ? local : remote
    var messagesByID = Dictionary(uniqueKeysWithValues: remote.messages.map { ($0.id, $0) })
    for message in local.messages {
      if let other = messagesByID[message.id] {
        messagesByID[message.id] = message.createdAt >= other.createdAt ? message : other
      } else {
        messagesByID[message.id] = message
      }
    }
    var merged = newer
    merged.messages = Array(
      messagesByID.values
        .sorted {
          $0.createdAt == $1.createdAt
            ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        .suffix(maximumMessagesPerConversation)
    )
    merged.createdAt = min(local.createdAt, remote.createdAt)
    merged.updatedAt = max(local.updatedAt, remote.updatedAt)
    return boundedConversation(merged)
  }

  private static func boundedConversation(_ value: AskChatConversation) -> AskChatConversation {
    var result = value
    result.title = boundedTitle(result.title)
    let boundedMessages = result.messages.map { boundedMessage($0) }
    let sortedMessages = boundedMessages.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    result.messages = Array(sortedMessages.suffix(maximumMessagesPerConversation))
    return result
  }

  private static func boundedMessage(_ value: AskChatMessage) -> AskChatMessage {
    var result = value
    result.text = bounded(value.text, maximum: 12_000)
    result.modelTier = value.modelTier.map { bounded($0, maximum: 40) }
    result.citations = Array(value.citations.prefix(20))
    result.sourceSnapshots = Array(value.sourceSnapshots.prefix(10)).map { snapshot in
      var next = snapshot
      next.title = bounded(snapshot.title, maximum: 240)
      next.metadata = snapshot.metadata.map { bounded($0, maximum: 400) }
      next.excerpt = snapshot.excerpt.map { bounded($0, maximum: 1_200) }
      return next
    }
    return result
  }

  private static func boundedTitle(_ value: String) -> String {
    let collapsed =
      value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return bounded(collapsed.isEmpty ? "New chat" : collapsed, maximum: 80)
  }

  private static func bounded(_ value: String, maximum: Int) -> String {
    guard value.count > maximum else { return value }
    let end = value.index(value.startIndex, offsetBy: maximum - 1)
    return String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  private static let maximumMessagesPerConversation = 80

  private static func load(from fileURL: URL) -> PersistedAskChatHistory {
    guard let data = try? Data(contentsOf: fileURL) else { return PersistedAskChatHistory() }
    return (try? decoder.decode(PersistedAskChatHistory.self, from: data))
      ?? PersistedAskChatHistory()
  }

  private func persist() throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try Self.encoder.encode(state)
    #if os(iOS)
    let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    #else
    // Complete file protection is an iOS data-protection class and can fail with EPERM on macOS.
    let writeOptions: Data.WritingOptions = [.atomic]
    #endif
    try data.write(to: fileURL, options: writeOptions)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

/// Separate private-zone sync keeps chat schema isolated from older iAgent source clients.
/// Only the encrypted payload is required to reconstruct a conversation.
public actor AskChatHistoryCloudSyncEngine {
  public static let zoneName = "AskIAgentChatHistory"
  public static let recordType = "AskChatConversation"

  private let store: AskChatHistoryStore
  private let container: CKContainer
  private let database: CKDatabase
  private let zoneID: CKRecordZone.ID
  private var currentStatus = AskChatHistoryStatus()

  public init(
    store: AskChatHistoryStore,
    containerIdentifier: String,
    zoneName: String = AskChatHistoryCloudSyncEngine.zoneName
  ) {
    self.store = store
    self.container = CKContainer(identifier: containerIdentifier)
    self.database = container.privateCloudDatabase
    self.zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
  }

  public func status() -> AskChatHistoryStatus {
    currentStatus
  }

  public func synchronize() async {
    currentStatus = AskChatHistoryStatus(phase: .syncing)
    do {
      let accountStatus = try await container.accountStatus()
      guard accountStatus == .available else {
        currentStatus = AskChatHistoryStatus(
          phase: .accountUnavailable,
          lastSuccessfulSyncAt: await store.lastSuccessfulSyncAt(),
          message: "Sign in to iCloud to sync Ask iAgent history."
        )
        return
      }

      try await ensureZone()
      for remote in try await fetchAllConversations() {
        _ = try await store.mergeRemote(remote)
      }
      try await uploadPendingConversations()
      let completedAt = Date()
      currentStatus = AskChatHistoryStatus(
        phase: .idle,
        lastSuccessfulSyncAt: completedAt
      )
    } catch {
      currentStatus = AskChatHistoryStatus(
        phase: Self.phase(for: error),
        lastSuccessfulSyncAt: await store.lastSuccessfulSyncAt(),
        message: error.localizedDescription
      )
    }
  }

  private func ensureZone() async throws {
    let zone = CKRecordZone(zoneID: zoneID)
    let result = try await database.modifyRecordZones(saving: [zone], deleting: [])
    if case .failure(let error)? = result.saveResults[zoneID] {
      throw error
    }
  }

  private func fetchAllConversations() async throws -> [AskChatConversation] {
    let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
    var page = try await database.records(
      matching: query,
      inZoneWith: zoneID,
      desiredKeys: ["payload"],
      resultsLimit: CKQueryOperation.maximumResults
    )
    var values = try Self.decode(page.matchResults)

    while let cursor = page.queryCursor {
      page = try await database.records(
        continuingMatchFrom: cursor,
        desiredKeys: ["payload"],
        resultsLimit: CKQueryOperation.maximumResults
      )
      values.append(contentsOf: try Self.decode(page.matchResults))
    }
    return values
  }

  private func uploadPendingConversations() async throws {
    let pending = await store.pendingConversations()
    guard !pending.isEmpty else { return }

    let records = try pending.map { conversation -> CKRecord in
      let recordID = CKRecord.ID(
        recordName: "conversation_\(conversation.id.uuidString.lowercased())",
        zoneID: zoneID
      )
      let record = CKRecord(recordType: Self.recordType, recordID: recordID)
      let payload = try Self.encoder.encode(conversation)
      record.encryptedValues.setObject(payload as NSData, forKey: "payload")
      record["updatedAt"] = conversation.updatedAt as NSDate
      record["schemaVersion"] = 1 as NSNumber
      if let deletedAt = conversation.deletedAt {
        record["deletedAt"] = deletedAt as NSDate
      }
      return record
    }

    let result = try await database.modifyRecords(
      saving: records,
      deleting: [],
      savePolicy: .changedKeys,
      atomically: false
    )
    let byRecordName = Dictionary(
      uniqueKeysWithValues: pending.map {
        ("conversation_\($0.id.uuidString.lowercased())", $0)
      })

    var firstError: Error?
    for (recordID, saveResult) in result.saveResults {
      guard let conversation = byRecordName[recordID.recordName] else { continue }
      switch saveResult {
      case .success:
        try await store.markSynced(
          conversationID: conversation.id,
          expectedUpdatedAt: conversation.updatedAt
        )
      case .failure(let error):
        firstError = firstError ?? error
      }
    }
    if let firstError { throw firstError }
  }

  private static func decode(
    _ matches: [(CKRecord.ID, Result<CKRecord, Error>)]
  ) throws -> [AskChatConversation] {
    var conversations: [AskChatConversation] = []
    for (_, result) in matches {
      let record = try result.get()
      guard record.recordType == Self.recordType,
        let data = record.encryptedValues.object(forKey: "payload") as? Data
      else { continue }
      conversations.append(try decoder.decode(AskChatConversation.self, from: data))
    }
    return conversations
  }

  private static func phase(for error: Error) -> AskChatHistoryStatus.Phase {
    guard let cloudError = error as? CKError else { return .failed }
    switch cloudError.code {
    case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited:
      return .offline
    case .notAuthenticated, .permissionFailure:
      return .accountUnavailable
    default:
      return .failed
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

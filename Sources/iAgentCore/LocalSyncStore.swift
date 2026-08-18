import CryptoKit
import Foundation

private struct PersistedSyncState: Codable, Sendable {
  var records: [String: IAgentSyncPayload] = [:]
  var baseRecords: [String: IAgentSyncPayload] = [:]
  var pendingRecordNames: Set<String> = []
  var pendingDeletionRecordNames: Set<String> = []
  var cloudSystemFields: [String: Data] = [:]
  var lastSuccessfulSyncAt: Date?
  var malformedRecordNames: Set<String> = []
  var cloudAccountFingerprint: String?
  var malformedRecordNamesFoundWhileDecoding: Set<String> = []

  private enum CodingKeys: String, CodingKey {
    case records
    case baseRecords
    case pendingRecordNames
    case pendingDeletionRecordNames
    case cloudSystemFields
    case lastSuccessfulSyncAt
    case malformedRecordNames
    case cloudAccountFingerprint
  }

  init(
    records: [String: IAgentSyncPayload] = [:],
    baseRecords: [String: IAgentSyncPayload] = [:],
    pendingRecordNames: Set<String> = [],
    pendingDeletionRecordNames: Set<String> = [],
    cloudSystemFields: [String: Data] = [:],
    lastSuccessfulSyncAt: Date? = nil,
    malformedRecordNames: Set<String> = [],
    cloudAccountFingerprint: String? = nil,
    malformedRecordNamesFoundWhileDecoding: Set<String> = []
  ) {
    self.records = records
    self.baseRecords = baseRecords
    self.pendingRecordNames = pendingRecordNames
    self.pendingDeletionRecordNames = pendingDeletionRecordNames
    self.cloudSystemFields = cloudSystemFields
    self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    self.malformedRecordNames = malformedRecordNames
    self.cloudAccountFingerprint = cloudAccountFingerprint
    self.malformedRecordNamesFoundWhileDecoding = malformedRecordNamesFoundWhileDecoding
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedRecords = (try? container.decode(LossyPayloadDictionary.self, forKey: .records))
      ?? LossyPayloadDictionary(values: [:], malformedRecordNames: ["<records>"])
    let decodedBaseRecords = (try? container.decode(LossyPayloadDictionary.self, forKey: .baseRecords))
      ?? LossyPayloadDictionary()

    records = decodedRecords.values
    baseRecords = decodedBaseRecords.values
    pendingRecordNames = (try? container.decode(Set<String>.self, forKey: .pendingRecordNames)) ?? []
    pendingRecordNames.formIntersection(records.keys)
    pendingDeletionRecordNames =
      (try? container.decode(Set<String>.self, forKey: .pendingDeletionRecordNames)) ?? []
    pendingRecordNames.subtract(pendingDeletionRecordNames)
    cloudSystemFields = (try? container.decode([String: Data].self, forKey: .cloudSystemFields)) ?? [:]
    lastSuccessfulSyncAt = try? container.decodeIfPresent(Date.self, forKey: .lastSuccessfulSyncAt)
    let persistedMalformedRecordNames =
      (try? container.decode(Set<String>.self, forKey: .malformedRecordNames)) ?? []
    malformedRecordNamesFoundWhileDecoding = decodedRecords.malformedRecordNames
      .union(decodedBaseRecords.malformedRecordNames)
    malformedRecordNames = malformedRecordNamesFoundWhileDecoding
      .union(persistedMalformedRecordNames)
    cloudAccountFingerprint = try? container.decodeIfPresent(
      String.self,
      forKey: .cloudAccountFingerprint
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(LossyPayloadDictionary(values: records), forKey: .records)
    try container.encode(LossyPayloadDictionary(values: baseRecords), forKey: .baseRecords)
    try container.encode(pendingRecordNames, forKey: .pendingRecordNames)
    try container.encode(pendingDeletionRecordNames, forKey: .pendingDeletionRecordNames)
    try container.encode(cloudSystemFields, forKey: .cloudSystemFields)
    try container.encodeIfPresent(lastSuccessfulSyncAt, forKey: .lastSuccessfulSyncAt)
    try container.encode(malformedRecordNames, forKey: .malformedRecordNames)
    try container.encodeIfPresent(cloudAccountFingerprint, forKey: .cloudAccountFingerprint)
  }
}

private struct LossyPayloadDictionary: Codable, Sendable {
  var values: [String: IAgentSyncPayload] = [:]
  var malformedRecordNames: Set<String> = []

  init(
    values: [String: IAgentSyncPayload] = [:],
    malformedRecordNames: Set<String> = []
  ) {
    self.values = values
    self.malformedRecordNames = malformedRecordNames
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: StringCodingKey.self)
    for key in container.allKeys {
      do {
        values[key.stringValue] = try container.decode(IAgentSyncPayload.self, forKey: key)
      } catch {
        malformedRecordNames.insert(key.stringValue)
      }
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: StringCodingKey.self)
    for (recordName, payload) in values {
      try container.encode(payload, forKey: StringCodingKey(recordName))
    }
  }
}

private struct StringCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }

  init(_ stringValue: String) {
    self.stringValue = stringValue
  }

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    return nil
  }
}

public enum IAgentCloudAccountBindingTransition: Equatable, Sendable {
  case unchanged
  case boundExistingState
  case quarantinedUnboundCloudState(quarantineURL: URL)
  case restoredAccountState
  case switchedAccounts(quarantineURL: URL)

  var requiresCloudStateReset: Bool {
    self != .unchanged
  }

  var quarantineReason: String {
    switch self {
    case .unchanged: "unchanged-account"
    case .boundExistingState: "first-account-binding"
    case .quarantinedUnboundCloudState: "unbound-cloud-history"
    case .restoredAccountState: "restored-account-binding"
    case .switchedAccounts: "account-switch"
    }
  }
}

public enum IAgentLocalSyncStoreError: Error, LocalizedError, Sendable {
  case cloudAccountMismatch
  case invalidSentPayloadIdentity
  case corruptStoreCouldNotBePreserved(String)
  case actionTargetChanged(String)
  case actionIdempotencyConflict

  public var errorDescription: String? {
    switch self {
    case .cloudAccountMismatch:
      "Cloud sync was stopped because the local store belongs to a different iCloud account."
    case .invalidSentPayloadIdentity:
      "CloudKit acknowledged a payload whose identity does not match the queued record."
    case let .corruptStoreCouldNotBePreserved(message):
      "The damaged sync store could not be preserved safely: \(message)"
    case let .actionTargetChanged(message):
      "The action target changed: \(message)"
    case .actionIdempotencyConflict:
      "The action's idempotency slot contains different data."
    }
  }
}

struct IAgentCloudUploadMaterial: Sendable {
  var payload: IAgentSyncPayload
  var cloudSystemFields: Data?
}

public struct IAgentSentRecord: Sendable, Equatable {
  public let recordName: String
  public let sentPayload: IAgentSyncPayload
  public let cloudSystemFields: Data?

  public init(
    recordName: String,
    sentPayload: IAgentSyncPayload,
    cloudSystemFields: Data?
  ) {
    self.recordName = recordName
    self.sentPayload = sentPayload
    self.cloudSystemFields = cloudSystemFields
  }
}

public struct IAgentFetchedRecord: Sendable, Equatable {
  public let payload: IAgentSyncPayload
  public let cloudSystemFields: Data?

  public init(payload: IAgentSyncPayload, cloudSystemFields: Data?) {
    self.payload = payload
    self.cloudSystemFields = cloudSystemFields
  }
}

public enum IAgentMessageProjectionRole: Sendable {
  case cloudReplica
  case localAuthority
}

public struct IAgentPendingCloudChanges: Sendable, Equatable {
  public let saveRecordNames: [String]
  public let deletionRecordNames: [String]

  public init(saveRecordNames: [String], deletionRecordNames: [String]) {
    self.saveRecordNames = saveRecordNames
    self.deletionRecordNames = deletionRecordNames
  }
}

public actor IAgentLocalSyncStore {
  public let fileURL: URL
  private let messageProjectionRole: IAgentMessageProjectionRole
  private var state: PersistedSyncState
  private let corruptStoreQuarantineURL: URL?
  private let persistenceBlocker: String?

  public init(
    fileURL: URL,
    messageProjectionRole: IAgentMessageProjectionRole = .cloudReplica
  ) {
    self.fileURL = fileURL
    self.messageProjectionRole = messageProjectionRole
    let loaded = Self.loadState(from: fileURL)
    var loadedState = loaded.state
    let removedRedundantPendingSaves = Self.removeRedundantPendingMessageProjectionSaves(
      from: &loadedState
    )
    let retentionChanged = Self.enforceMessageRetention(
      on: &loadedState,
      referenceDate: Date()
    ).changed
    state = loadedState
    corruptStoreQuarantineURL = loaded.quarantineURL
    persistenceBlocker = loaded.persistenceBlocker
    if loaded.persistenceBlocker == nil,
       removedRedundantPendingSaves || retentionChanged {
      try? Self.persist(loadedState, to: fileURL)
    }
  }

  public static func defaultFileURL(appIdentifier: String) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent(appIdentifier, isDirectory: true)
      .appendingPathComponent("sync-store.json")
  }

  public func quarantinedCorruptStoreURL() -> URL? {
    corruptStoreQuarantineURL
  }

  @discardableResult
  public func bind(toCloudAccount fingerprint: String) throws -> IAgentCloudAccountBindingTransition {
    guard !fingerprint.isEmpty else {
      throw IAgentLocalSyncStoreError.cloudAccountMismatch
    }
    if state.cloudAccountFingerprint == fingerprint {
      return .unchanged
    }

    let transition: IAgentCloudAccountBindingTransition
    if state.cloudAccountFingerprint != nil {
      let quarantineURL = try quarantineCurrentState(reason: "account-switch")
      state = try loadAccountVault(for: fingerprint)
        ?? PersistedSyncState(cloudAccountFingerprint: fingerprint)
      transition = .switchedAccounts(quarantineURL: quarantineURL)
    } else if stateHasUnboundCloudHistory {
      let quarantineURL = try quarantineCurrentState(reason: "unbound-cloud-history")
      state = try loadAccountVault(for: fingerprint)
        ?? PersistedSyncState(cloudAccountFingerprint: fingerprint)
      transition = .quarantinedUnboundCloudState(quarantineURL: quarantineURL)
    } else if currentStateIsEmpty,
              let restoredState = try loadAccountVault(for: fingerprint)
    {
      state = restoredState
      transition = .restoredAccountState
    } else {
      state.cloudAccountFingerprint = fingerprint
      transition = .boundExistingState
    }
    _ = Self.removeRedundantPendingMessageProjectionSaves(from: &state)
    _ = Self.enforceMessageRetention(on: &state, referenceDate: Date())
    try persistAndNotify()
    return transition
  }

  @discardableResult
  public func quarantineForCloudAccountSignOut() throws -> URL? {
    guard state.cloudAccountFingerprint != nil else { return nil }
    let quarantineURL = try quarantineCurrentState(reason: "account-sign-out")
    state = PersistedSyncState()
    try persistAndNotify()
    return quarantineURL
  }

  public func pendingRecordNames(forCloudAccount fingerprint: String) throws -> [String] {
    try requireCloudAccount(fingerprint)
    return state.pendingRecordNames.sorted()
  }

  public func pendingDeletionRecordNames(
    forCloudAccount fingerprint: String
  ) throws -> [String] {
    try requireCloudAccount(fingerprint)
    return state.pendingDeletionRecordNames.sorted()
  }

  public func pendingCloudChanges(
    forCloudAccount fingerprint: String
  ) throws -> IAgentPendingCloudChanges {
    try requireCloudAccount(fingerprint)
    return IAgentPendingCloudChanges(
      saveRecordNames: state.pendingRecordNames
        .subtracting(state.pendingDeletionRecordNames)
        .sorted(),
      deletionRecordNames: state.pendingDeletionRecordNames.sorted()
    )
  }

  func cloudUploadMaterial(
    for recordName: String,
    cloudAccountFingerprint: String
  ) throws -> IAgentCloudUploadMaterial? {
    try requireCloudAccount(cloudAccountFingerprint)
    guard !state.pendingDeletionRecordNames.contains(recordName) else { return nil }
    guard let payload = state.records[recordName] else { return nil }
    return IAgentCloudUploadMaterial(
      payload: payload,
      cloudSystemFields: state.cloudSystemFields[recordName]
    )
  }

  public func snapshot(referenceDate: Date = Date()) -> IAgentDataSnapshot {
    let payloads = state.records.values.filter { $0.deletedAt == nil }
    let notes = payloads.compactMap(\.noteValue).sorted {
      $0.updatedAt == $1.updatedAt
        ? $0.id.uuidString < $1.id.uuidString
        : $0.updatedAt > $1.updatedAt
    }
    let todos = payloads.compactMap(\.todoValue).sorted {
      $0.createdAt == $1.createdAt
        ? $0.id.uuidString < $1.id.uuidString
        : $0.createdAt > $1.createdAt
    }
    let todoLists = payloads.compactMap(\.todoListValue).sorted {
      if $0.order != $1.order { return $0.order < $1.order }
      let nameComparison = $0.name.localizedCaseInsensitiveCompare($1.name)
      return nameComparison == .orderedSame
        ? $0.id.uuidString < $1.id.uuidString
        : nameComparison == .orderedAscending
    }
    let meetings = payloads.compactMap(\.meetingValue).sorted {
      $0.startedAt == $1.startedAt
        ? $0.id.uuidString < $1.id.uuidString
        : $0.startedAt > $1.startedAt
    }
    let codexThreads = payloads.compactMap(\.codexValue).sorted {
      $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
    }
    let calendarEvents = payloads.compactMap(\.calendarValue).sorted {
      $0.startDate == $1.startDate ? $0.id < $1.id : $0.startDate < $1.startDate
    }
    let desktopSnapshot = payloads.compactMap(\.desktopValue).max {
      $0.freshnessDate < $1.freshnessDate
    }
    let messages: [SyncedMessage] = payloads.compactMap(\.messageValue).filter {
      MessageSyncWindow.includes(date: $0.sentAt, referenceDate: referenceDate)
    }.sorted {
      if $0.sentAt == $1.sentAt { return $0.id < $1.id }
      return $0.sentAt < $1.sentAt
    }
    let retainedConversationIDs = Set(messages.map(\.conversationID))
    let persistedMessageConversations = payloads.compactMap(\.messageConversationValue).filter {
      retainedConversationIDs.contains($0.id)
    }
    let persistedConversationIDs = Set(persistedMessageConversations.map(\.id))
    // Older relay snapshots could retain messages while omitting their
    // conversation summaries. Keep those messages visible locally instead of
    // presenting a misleading empty inbox. The next authoritative Mac scan
    // replaces these display-only fallbacks with source-authored summaries.
    let recoveredMessageConversations = Dictionary(grouping: messages) { $0.conversationID }
      .compactMap { conversationID, conversationMessages -> SyncedMessageConversation? in
        guard !persistedConversationIDs.contains(conversationID),
              let latest = conversationMessages.last
        else { return nil }
        let participantName = latest.senderDisplayName?.trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        let displayName = participantName.flatMap { $0.isEmpty ? nil : $0 }
          ?? latest.senderID
          ?? "Message"
        let participants = latest.senderID.map {
          [SyncedMessageParticipant(id: $0, displayName: displayName)]
        } ?? []
        return SyncedMessageConversation(
          id: conversationID,
          displayName: displayName,
          participants: participants,
          isGroup: false,
          latestMessageID: latest.id,
          latestMessageDate: latest.sentAt,
          latestPreview: latest.body,
          updatedAt: latest.updatedAt
        )
      }
    let messageConversations = (persistedMessageConversations + recoveredMessageConversations).sorted {
      if $0.latestMessageDate == $1.latestMessageDate { return $0.id < $1.id }
      return $0.latestMessageDate > $1.latestMessageDate
    }
    let messageReadStates = payloads.compactMap(\.messageReadStateValue).filter {
      retainedConversationIDs.contains($0.id)
    }.sorted { $0.id < $1.id }
    let messageRelayStates = payloads.compactMap(\.messageRelayStateValue).sorted {
      if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
      return $0.updatedAt > $1.updatedAt
    }
    return IAgentDataSnapshot(
      notes: notes,
      todos: todos,
      todoLists: todoLists,
      meetings: meetings,
      codexThreads: codexThreads,
      calendarEvents: calendarEvents,
      desktopSnapshot: desktopSnapshot,
      messageConversations: messageConversations,
      messages: messages,
      messageReadStates: messageReadStates,
      messageRelayStates: messageRelayStates,
      pendingRecordNames: state.pendingRecordNames,
      pendingDeletionRecordNames: state.pendingDeletionRecordNames,
      lastSuccessfulSyncAt: state.lastSuccessfulSyncAt
    )
  }

  public func diagnostics() -> IAgentLocalSyncDiagnostics {
    let activePayloads = state.records.values.filter { $0.deletedAt == nil }
    let pendingNames = state.pendingRecordNames
      .union(state.pendingDeletionRecordNames)
      .sorted()
    var activeCountsByKind: [IAgentEntityKind: Int] = [:]
    for payload in activePayloads {
      activeCountsByKind[payload.kind, default: 0] += 1
    }

    return IAgentLocalSyncDiagnostics(
      totalRecordCount: state.records.count,
      activeRecordCount: activePayloads.count,
      tombstoneRecordCount: state.records.count - activePayloads.count,
      activeRecordCountsByKind: activeCountsByKind,
      pendingRecordCount: pendingNames.count,
      pendingRecordNames: pendingNames,
      oldestPendingRecordUpdatedAt: pendingNames.compactMap { state.records[$0]?.updatedAt }.min(),
      lastSuccessfulSyncAt: state.lastSuccessfulSyncAt,
      malformedRecordNames: state.malformedRecordNames.sorted()
    )
  }

  @discardableResult
  public func upsertLocal(_ payload: IAgentSyncPayload) throws -> String {
    let previousState = state
    do {
      let referenceDate = Date()
      if Self.requiresPhysicalMessageDeletion(payload, referenceDate: referenceDate) {
        Self.removeAndQueueDeletion(recordName: payload.recordName, from: &state)
      } else {
        if let base = state.baseRecords[payload.recordName],
           try Self.canonicallyEqual(payload, base)
        {
          state.records[payload.recordName] = base
          state.pendingRecordNames.remove(payload.recordName)
        } else {
          state.records[payload.recordName] = payload
          state.pendingRecordNames.insert(payload.recordName)
        }
        state.pendingDeletionRecordNames.remove(payload.recordName)
      }
      if payload.kind == .messageConversation
        || payload.kind == .message
        || payload.kind == .messageReadState {
        _ = Self.enforceMessageRetention(on: &state, referenceDate: referenceDate)
      }
      try persistAndNotify()
    } catch {
      state = previousState
      throw error
    }
    return payload.recordName
  }

  @discardableResult
  public func upsertLocal(_ payloads: [IAgentSyncPayload]) throws -> [String] {
    let previousState = state
    var names: [String] = []
    do {
      let referenceDate = Date()
      for payload in payloads {
        if Self.requiresPhysicalMessageDeletion(payload, referenceDate: referenceDate) {
          Self.removeAndQueueDeletion(recordName: payload.recordName, from: &state)
        } else {
          if let base = state.baseRecords[payload.recordName],
             try Self.canonicallyEqual(payload, base)
          {
            state.records[payload.recordName] = base
            state.pendingRecordNames.remove(payload.recordName)
          } else {
            state.records[payload.recordName] = payload
            state.pendingRecordNames.insert(payload.recordName)
          }
          state.pendingDeletionRecordNames.remove(payload.recordName)
        }
        names.append(payload.recordName)
      }
      _ = Self.enforceMessageRetention(on: &state, referenceDate: referenceDate)
      try persistAndNotify()
    } catch {
      state = previousState
      throw error
    }
    return names
  }

  /// Atomically stages only payloads that still differ from the current local
  /// state at the JSON precision used by the CloudKit transport.
  @discardableResult
  public func stageLocalChanges(_ payloads: [IAgentSyncPayload]) throws -> Bool {
    let previousState = state
    var changed = false
    do {
      let referenceDate = Date()
      for payload in payloads {
        let recordName = payload.recordName
        if Self.requiresPhysicalMessageDeletion(payload, referenceDate: referenceDate) {
          let alreadyQueued = state.records[recordName] == nil
            && state.baseRecords[recordName] == nil
            && !state.pendingRecordNames.contains(recordName)
            && state.pendingDeletionRecordNames.contains(recordName)
            && state.cloudSystemFields[recordName] == nil
          if !alreadyQueued {
            Self.removeAndQueueDeletion(recordName: recordName, from: &state)
            changed = true
          }
          continue
        }

        if let existing = state.records[recordName],
           Self.messageProjectionIsTransportEquivalent(existing, payload),
           !state.pendingDeletionRecordNames.contains(recordName) {
          if state.pendingRecordNames.contains(recordName),
             let base = state.baseRecords[recordName],
             Self.messageProjectionIsTransportEquivalent(existing, base) {
            state.pendingRecordNames.remove(recordName)
            changed = true
          }
          continue
        }

        state.records[recordName] = payload
        state.pendingRecordNames.insert(recordName)
        state.pendingDeletionRecordNames.remove(recordName)
        changed = true
      }

      let retention = Self.enforceMessageRetention(on: &state, referenceDate: referenceDate)
      changed = changed || retention.changed
      if changed {
        try persistAndNotify()
      }
      return changed
    } catch {
      state = previousState
      throw error
    }
  }

  /// Atomically revalidates an action's named to-do list and deterministic idempotency slot, then
  /// persists the new to-do. This closes the gap between a broker revalidation await and mutation:
  /// a list deleted/renamed in that interval cannot receive an orphaned action-created to-do.
  @discardableResult
  public func upsertActionTodo(
    _ todo: SyncedTodo,
    expectedListName: String?,
    identity: AssistantActionExecutionIdentity,
    authorization: AssistantActionExecutionAuthorization
  ) throws -> String {
    let payload = IAgentSyncPayload.todo(todo)
    // An exact deterministic record is durable evidence that this action already inserted the
    // to-do. Recover that success before checking a target that may legitimately have changed
    // after the write but before its audit receipt was persisted.
    if let existing = state.records[payload.recordName] {
      guard try Self.canonicallyEqual(existing, payload) else {
        throw IAgentLocalSyncStoreError.actionIdempotencyConflict
      }
    } else {
      if let expectedListName {
        let matches = state.records.values.compactMap(\.todoListValue).filter {
          $0.deletedAt == nil
            && $0.name.caseInsensitiveCompare(expectedListName) == .orderedSame
        }
        guard matches.count == 1 else {
          throw IAgentLocalSyncStoreError.actionTargetChanged(
            matches.isEmpty
              ? "the selected to-do list no longer exists"
              : "the selected to-do list is no longer unique"
          )
        }
      }
    }

    try authorization.performAuthorizedMutation(for: identity) {
      // Recheck the slot within the authorized critical section. The store actor cannot interleave
      // while acquiring authority locks, but keeping this check here makes the mutation boundary
      // self-contained and preserves exact replay semantics.
      if let existing = state.records[payload.recordName] {
        guard try Self.canonicallyEqual(existing, payload) else {
          throw IAgentLocalSyncStoreError.actionIdempotencyConflict
        }
        return
      }
      let previousState = state
      do {
        state.records[payload.recordName] = payload
        state.pendingRecordNames.insert(payload.recordName)
        try persistAndNotify()
      } catch {
        state = previousState
        throw error
      }
    }
    return payload.recordName
  }

  /// Atomically compares an action's deterministic note slot and persists the note only when that
  /// slot is still empty. An identical existing payload is an idempotent replay; different data is
  /// a stale-target conflict and must never be overwritten.
  @discardableResult
  public func upsertActionNote(
    _ note: SyncedNote,
    identity: AssistantActionExecutionIdentity,
    authorization: AssistantActionExecutionAuthorization
  ) throws -> String {
    let payload = IAgentSyncPayload.note(note)
    if let existing = state.records[payload.recordName] {
      guard try Self.canonicallyEqual(existing, payload) else {
        throw IAgentLocalSyncStoreError.actionIdempotencyConflict
      }
    }

    try authorization.performAuthorizedMutation(for: identity) {
      if let existing = state.records[payload.recordName] {
        guard try Self.canonicallyEqual(existing, payload) else {
          throw IAgentLocalSyncStoreError.actionIdempotencyConflict
        }
        return
      }
      let previousState = state
      do {
        state.records[payload.recordName] = payload
        state.pendingRecordNames.insert(payload.recordName)
        try persistAndNotify()
      } catch {
        state = previousState
        throw error
      }
    }
    return payload.recordName
  }

  /// Reconciles an action's deterministic local slot without changing actor or durable state.
  ///
  /// An exact payload proves that a prior local execution reached durable storage even when the
  /// process terminated before its broker receipt was written. An occupied-but-different slot is
  /// not proof of this action and fails closed rather than being overwritten or reported as a
  /// success.
  public func reconcileActionPayload(_ expected: IAgentSyncPayload) throws -> Bool {
    guard let existing = state.records[expected.recordName] else { return false }
    guard try Self.canonicallyEqual(existing, expected) else {
      throw IAgentLocalSyncStoreError.actionIdempotencyConflict
    }
    return true
  }

  public func payload(for recordName: String) -> IAgentSyncPayload? {
    guard let payload = state.records[recordName] else { return nil }
    if let message = payload.messageValue,
       !MessageSyncWindow.includes(date: message.sentAt, referenceDate: Date()) {
      return nil
    }
    if payload.kind == .messageConversation || payload.kind == .messageReadState {
      let hasRetainedMessage = state.records.values.contains { candidate in
        guard candidate.deletedAt == nil,
              let message = candidate.messageValue,
              message.conversationID == payload.id
        else { return false }
        return MessageSyncWindow.includes(date: message.sentAt, referenceDate: Date())
      }
      guard hasRetainedMessage else { return nil }
    }
    return payload
  }

  public func allPayloads(referenceDate: Date = Date()) -> [IAgentSyncPayload] {
    let retainedConversationIDs = Set(state.records.values.compactMap { payload -> String? in
      guard payload.deletedAt == nil,
            let message = payload.messageValue,
            MessageSyncWindow.includes(date: message.sentAt, referenceDate: referenceDate)
      else { return nil }
      return message.conversationID
    })
    return state.records.values.filter { payload in
      if let message = payload.messageValue {
        return MessageSyncWindow.includes(date: message.sentAt, referenceDate: referenceDate)
      }
      if payload.kind == .messageConversation || payload.kind == .messageReadState {
        return retainedConversationIDs.contains(payload.id)
      }
      return true
    }
  }

  /// Removes records that were injected locally without ever being queued or observed in CloudKit.
  /// This is intentionally narrower than deletion and is suitable for cleaning known fixture IDs.
  @discardableResult
  public func discardUntrackedLocalRecords(named recordNames: Set<String>) throws -> Set<String> {
    var discarded: Set<String> = []
    for recordName in recordNames {
      guard state.records[recordName] != nil,
            !state.pendingRecordNames.contains(recordName),
            !state.pendingDeletionRecordNames.contains(recordName),
            state.baseRecords[recordName] == nil,
            state.cloudSystemFields[recordName] == nil
      else { continue }

      state.records.removeValue(forKey: recordName)
      state.malformedRecordNames.remove(recordName)
      discarded.insert(recordName)
    }

    if !discarded.isEmpty {
      try persistAndNotify()
    }
    return discarded
  }

  public func pendingRecordNames() -> [String] {
    state.pendingRecordNames.sorted()
  }

  public func pendingDeletionRecordNames() -> [String] {
    state.pendingDeletionRecordNames.sorted()
  }

  public func cloudSystemFields(for recordName: String) -> Data? {
    state.cloudSystemFields[recordName]
  }

  @discardableResult
  public func mergeRemote(
    _ remote: IAgentSyncPayload,
    cloudSystemFields: Data?,
    cloudAccountFingerprint: String? = nil
  ) throws -> [String] {
    if let cloudAccountFingerprint {
      try requireCloudAccount(cloudAccountFingerprint)
    }
    let previousState = state
    do {
      let name = remote.recordName
      let referenceDate = Date()

      // A local physical deletion remains authoritative until CloudKit acknowledges
      // that exact delete. A concurrent fetch must not resurrect the record.
      if state.pendingDeletionRecordNames.contains(name) {
        return []
      }
      if Self.requiresPhysicalMessageDeletion(remote, referenceDate: referenceDate) {
        Self.removeAndQueueDeletion(recordName: name, from: &state)
        _ = Self.enforceMessageRetention(on: &state, referenceDate: referenceDate)
        try persistAndNotify()
        return []
      }

      let local = state.records[name]
      let base = state.baseRecords[name]
      var newlyPending: [String] = []
      if let local,
         state.pendingRecordNames.contains(name)
           || Self.isMessageReadStatePair(local, remote)
           || isLocallyAuthoritativeMessageProjectionPair(local, remote) {
        let merge = merge(local: local, remote: remote, base: base)
        state.records[name] = merge.primary
        if remoteAcknowledges(merge.primary, remote: remote) {
          state.pendingRecordNames.remove(name)
        } else {
          state.pendingRecordNames.insert(name)
          newlyPending.append(name)
        }

        if let conflict = merge.conflictCopy {
          state.records[conflict.recordName] = conflict
          state.pendingRecordNames.insert(conflict.recordName)
          newlyPending.append(conflict.recordName)
        }
      } else {
        state.records[name] = remote
        state.pendingRecordNames.remove(name)
      }

      state.baseRecords[name] = remote
      if let cloudSystemFields {
        state.cloudSystemFields[name] = cloudSystemFields
      }
      _ = Self.enforceMessageRetention(on: &state, referenceDate: referenceDate)
      try persistAndNotify()
      return newlyPending
    } catch {
      state = previousState
      throw error
    }
  }

  /// Applies one CloudKit change batch as a single durable transaction. Remote
  /// deletions preserve a newer unsent local save, while locally queued physical
  /// deletions cannot be cancelled by stale fetched records.
  @discardableResult
  public func applyRemoteChanges(
    _ fetchedRecords: [IAgentFetchedRecord],
    deletedRecordNames: [String],
    cloudAccountFingerprint: String? = nil,
    referenceDate: Date = Date()
  ) throws -> [String] {
    if let cloudAccountFingerprint {
      try requireCloudAccount(cloudAccountFingerprint)
    }
    let previousState = state
    do {
      var newlyPending: [String] = []
      var newlyPendingNames = Set<String>()

      func appendPending(_ recordName: String) {
        if newlyPendingNames.insert(recordName).inserted {
          newlyPending.append(recordName)
        }
      }

      for fetchedRecord in fetchedRecords {
        let remote = fetchedRecord.payload
        let name = remote.recordName
        if state.pendingDeletionRecordNames.contains(name) {
          continue
        }
        if Self.requiresPhysicalMessageDeletion(remote, referenceDate: referenceDate) {
          Self.removeAndQueueDeletion(recordName: name, from: &state)
          continue
        }

        let local = state.records[name]
        let base = state.baseRecords[name]
        if let local,
           state.pendingRecordNames.contains(name)
             || Self.isMessageReadStatePair(local, remote)
             || isLocallyAuthoritativeMessageProjectionPair(local, remote) {
          let merge = merge(local: local, remote: remote, base: base)
          state.records[name] = merge.primary
          if remoteAcknowledges(merge.primary, remote: remote) {
            state.pendingRecordNames.remove(name)
          } else {
            state.pendingRecordNames.insert(name)
            appendPending(name)
          }

          if let conflict = merge.conflictCopy {
            state.records[conflict.recordName] = conflict
            state.pendingRecordNames.insert(conflict.recordName)
            appendPending(conflict.recordName)
          }
        } else {
          state.records[name] = remote
          state.pendingRecordNames.remove(name)
        }

        state.baseRecords[name] = remote
        if let cloudSystemFields = fetchedRecord.cloudSystemFields {
          state.cloudSystemFields[name] = cloudSystemFields
        }
      }

      for recordName in Set(deletedRecordNames) {
        if state.pendingRecordNames.contains(recordName),
           state.records[recordName] != nil,
           !state.pendingDeletionRecordNames.contains(recordName) {
          // Recreate an unsent local edit after its former server record vanished.
          state.baseRecords.removeValue(forKey: recordName)
          state.cloudSystemFields.removeValue(forKey: recordName)
          appendPending(recordName)
        } else {
          Self.removeCompletely(recordName: recordName, from: &state)
        }
      }

      let retention = Self.enforceMessageRetention(on: &state, referenceDate: referenceDate)
      if !fetchedRecords.isEmpty || !deletedRecordNames.isEmpty || retention.changed {
        try persistAndNotify()
      }
      return newlyPending
    } catch {
      state = previousState
      throw error
    }
  }

  public func deleteLocal(recordName: String) throws {
    let previousState = state
    do {
      Self.removeAndQueueDeletion(recordName: recordName, from: &state)
      _ = Self.enforceMessageRetention(on: &state, referenceDate: Date())
      try persistAndNotify()
    } catch {
      state = previousState
      throw error
    }
  }

  public func removeRemote(
    recordName: String,
    cloudAccountFingerprint: String? = nil
  ) throws {
    if let cloudAccountFingerprint {
      try requireCloudAccount(cloudAccountFingerprint)
    }
    let previousState = state
    do {
      if state.pendingRecordNames.contains(recordName),
         state.records[recordName] != nil,
         !state.pendingDeletionRecordNames.contains(recordName) {
        // A physical CloudKit deletion has no timestamp to compare with an unsent local edit.
        // Preserve the local version and clear its former server ancestry so the next send
        // recreates the record instead of silently losing local work.
        state.baseRecords.removeValue(forKey: recordName)
        state.cloudSystemFields.removeValue(forKey: recordName)
      } else {
        Self.removeCompletely(recordName: recordName, from: &state)
      }
      _ = Self.enforceMessageRetention(on: &state, referenceDate: Date())
      try persistAndNotify()
    } catch {
      state = previousState
      throw error
    }
  }

  public func markSent(
    recordName: String,
    sentPayload: IAgentSyncPayload,
    cloudSystemFields: Data?,
    cloudAccountFingerprint: String? = nil,
    at date: Date = Date()
  ) throws {
    try markSent(
      [IAgentSentRecord(
        recordName: recordName,
        sentPayload: sentPayload,
        cloudSystemFields: cloudSystemFields
      )],
      cloudAccountFingerprint: cloudAccountFingerprint,
      at: date
    )
  }

  public func markSent(
    _ sentRecords: [IAgentSentRecord],
    cloudAccountFingerprint: String? = nil,
    at date: Date = Date()
  ) throws {
    if let cloudAccountFingerprint {
      try requireCloudAccount(cloudAccountFingerprint)
    }
    guard sentRecords.allSatisfy({ $0.sentPayload.recordName == $0.recordName }) else {
      throw IAgentLocalSyncStoreError.invalidSentPayloadIdentity
    }
    guard !sentRecords.isEmpty else { return }
    let previousState = state
    do {
      for sentRecord in sentRecords {
        let recordName = sentRecord.recordName
        let sentPayload = sentRecord.sentPayload
        if !state.pendingDeletionRecordNames.contains(recordName) {
          state.baseRecords[recordName] = sentPayload
          if let currentPayload = state.records[recordName],
             try Self.canonicallyEqual(currentPayload, sentPayload) {
            // Keep the locally stored projection byte-for-byte aligned with the
            // payload CloudKit actually acknowledged after canonical Date encoding.
            // A genuinely newer in-flight edit fails this comparison and remains
            // untouched and pending.
            state.records[recordName] = sentPayload
            state.pendingRecordNames.remove(recordName)
          } else if let currentPayload = state.records[recordName],
                    Self.messageProjectionIsTransportEquivalent(currentPayload, sentPayload) {
            // Compare the payload that was actually uploaded. A real edit made while
            // the request was in flight stays pending; timestamp-only projection drift
            // does not create an endless upload loop.
            state.pendingRecordNames.remove(recordName)
          }
          if let cloudSystemFields = sentRecord.cloudSystemFields {
            state.cloudSystemFields[recordName] = cloudSystemFields
          }
        }
      }
      state.lastSuccessfulSyncAt = date
      try persistAndNotify()
    } catch {
      state = previousState
      throw error
    }
  }

  public func acknowledgeDeletion(
    recordName: String,
    cloudAccountFingerprint: String? = nil,
    at date: Date = Date()
  ) throws {
    if let cloudAccountFingerprint {
      try requireCloudAccount(cloudAccountFingerprint)
    }
    guard state.pendingDeletionRecordNames.contains(recordName) else { return }
    let previousState = state
    do {
      Self.removeCompletely(recordName: recordName, from: &state)
      state.lastSuccessfulSyncAt = date
      try persistAndNotify()
    } catch {
      state = previousState
      throw error
    }
  }

  public func requeueDeletion(
    recordName: String,
    cloudAccountFingerprint: String? = nil
  ) throws {
    if let cloudAccountFingerprint {
      try requireCloudAccount(cloudAccountFingerprint)
    }
    guard state.pendingDeletionRecordNames.contains(recordName) else { return }
    let previousState = state
    do {
      Self.removeAndQueueDeletion(recordName: recordName, from: &state)
      try persistAndNotify()
    } catch {
      state = previousState
      throw error
    }
  }

  @discardableResult
  public func enforceMessageRetention(
    referenceDate: Date = Date(),
    cloudAccountFingerprint: String? = nil
  ) throws -> [String] {
    if let cloudAccountFingerprint {
      try requireCloudAccount(cloudAccountFingerprint)
    }
    let previousState = state
    do {
      let result = Self.enforceMessageRetention(on: &state, referenceDate: referenceDate)
      if result.changed {
        try persistAndNotify()
      }
      return result.deletedRecordNames.sorted()
    } catch {
      state = previousState
      throw error
    }
  }

  public func markSyncSuccessful(
    at date: Date = Date(),
    cloudAccountFingerprint: String? = nil
  ) throws {
    if let cloudAccountFingerprint {
      try requireCloudAccount(cloudAccountFingerprint)
    }
    state.lastSuccessfulSyncAt = date
    try persistAndNotify()
  }

  public func replaceForTesting(
    with payloads: [IAgentSyncPayload],
    lastSuccessfulSyncAt: Date? = nil
  ) throws {
    state = PersistedSyncState(
      records: Dictionary(uniqueKeysWithValues: payloads.map { ($0.recordName, $0) }),
      baseRecords: [:],
      pendingRecordNames: [],
      pendingDeletionRecordNames: [],
      cloudSystemFields: [:],
      lastSuccessfulSyncAt: lastSuccessfulSyncAt
    )
    _ = Self.enforceMessageRetention(on: &state, referenceDate: Date())
    try persistAndNotify()
  }

  private func requireCloudAccount(_ fingerprint: String) throws {
    guard state.cloudAccountFingerprint == fingerprint else {
      throw IAgentLocalSyncStoreError.cloudAccountMismatch
    }
  }

  private static func canonicallyEqual(
    _ lhs: IAgentSyncPayload,
    _ rhs: IAgentSyncPayload
  ) throws -> Bool {
    try JSONEncoder.iAgent.encode(lhs) == JSONEncoder.iAgent.encode(rhs)
  }

  private static func persist(_ state: PersistedSyncState, to fileURL: URL) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder.iAgent.encode(state)
    try data.write(to: fileURL, options: .atomic)
  }

  private static func isMessageReadStatePair(
    _ lhs: IAgentSyncPayload,
    _ rhs: IAgentSyncPayload
  ) -> Bool {
    guard case .messageReadState = lhs,
          case .messageReadState = rhs
    else { return false }
    return true
  }

  private func isLocallyAuthoritativeMessageProjectionPair(
    _ lhs: IAgentSyncPayload,
    _ rhs: IAgentSyncPayload
  ) -> Bool {
    guard messageProjectionRole == .localAuthority else { return false }
    switch (lhs, rhs) {
    case (.messageConversation, .messageConversation), (.message, .message):
      return true
    default:
      return false
    }
  }

  private func remoteAcknowledges(
    _ primary: IAgentSyncPayload,
    remote: IAgentSyncPayload
  ) -> Bool {
    primary == remote || Self.messageProjectionIsTransportEquivalent(primary, remote)
  }

  private static func removeAndQueueDeletion(
    recordName: String,
    from state: inout PersistedSyncState
  ) {
    state.records.removeValue(forKey: recordName)
    state.baseRecords.removeValue(forKey: recordName)
    state.pendingRecordNames.remove(recordName)
    state.pendingDeletionRecordNames.insert(recordName)
    state.cloudSystemFields.removeValue(forKey: recordName)
    state.malformedRecordNames.remove(recordName)
  }

  private static func removeCompletely(
    recordName: String,
    from state: inout PersistedSyncState
  ) {
    state.records.removeValue(forKey: recordName)
    state.baseRecords.removeValue(forKey: recordName)
    state.pendingRecordNames.remove(recordName)
    state.pendingDeletionRecordNames.remove(recordName)
    state.cloudSystemFields.removeValue(forKey: recordName)
    state.malformedRecordNames.remove(recordName)
  }

  /// Repairs pending projection saves produced by older exact-Date comparisons.
  /// The comparison matches JSON/CloudKit transport precision while treating only
  /// provider-independent synchronization metadata as insignificant.
  private static func removeRedundantPendingMessageProjectionSaves(
    from state: inout PersistedSyncState
  ) -> Bool {
    let redundantNames = state.pendingRecordNames.filter { recordName in
      guard let record = state.records[recordName],
            (record.kind == .message
              || record.kind == .messageConversation
              || record.kind == .messageReadState),
            let base = state.baseRecords[recordName],
            messageProjectionIsTransportEquivalent(record, base),
            !state.pendingDeletionRecordNames.contains(recordName)
      else { return false }
      return true
    }
    guard !redundantNames.isEmpty else { return false }
    state.pendingRecordNames.subtract(redundantNames)
    return true
  }

  private static func messageProjectionIsTransportEquivalent(
    _ lhs: IAgentSyncPayload,
    _ rhs: IAgentSyncPayload
  ) -> Bool {
    guard lhs.recordName == rhs.recordName,
          let normalizedLHS = normalizedMessageProjectionForTransportComparison(lhs),
          let normalizedRHS = normalizedMessageProjectionForTransportComparison(rhs),
          let lhsData = try? JSONEncoder.iAgent.encode(normalizedLHS),
          let rhsData = try? JSONEncoder.iAgent.encode(normalizedRHS)
    else { return lhs == rhs }
    return lhsData == rhsData
  }

  private static func normalizedMessageProjectionForTransportComparison(
    _ payload: IAgentSyncPayload
  ) -> IAgentSyncPayload? {
    let comparisonTimestamp = Date(timeIntervalSince1970: 0)
    switch payload {
    case .messageConversation(var conversation):
      conversation.updatedAt = comparisonTimestamp
      return .messageConversation(conversation)
    case .message(var message):
      message.updatedAt = comparisonTimestamp
      return .message(message)
    case .messageReadState(var readState):
      readState.updatedAt = comparisonTimestamp
      readState.sourceDeviceID = ""
      return .messageReadState(readState)
    default:
      return nil
    }
  }

  private static func requiresPhysicalMessageDeletion(
    _ payload: IAgentSyncPayload,
    referenceDate: Date
  ) -> Bool {
    if let message = payload.messageValue {
      return message.deletedAt != nil
        || !MessageSyncWindow.includes(date: message.sentAt, referenceDate: referenceDate)
    }
    switch payload {
    case let .messageConversation(value):
      return value.deletedAt != nil
    case let .messageReadState(value):
      return value.deletedAt != nil
    case let .messageRelayState(value):
      return value.deletedAt != nil
    default:
      return false
    }
  }

  private static func enforceMessageRetention(
    on state: inout PersistedSyncState,
    referenceDate: Date
  ) -> (changed: Bool, deletedRecordNames: Set<String>) {
    var candidates = Set<String>()
    var sanitized = false

    for (recordName, payload) in state.records
      where requiresPhysicalMessageDeletion(payload, referenceDate: referenceDate) {
      candidates.insert(recordName)
    }
    for (recordName, payload) in state.baseRecords
      where requiresPhysicalMessageDeletion(payload, referenceDate: referenceDate) {
      candidates.insert(recordName)
    }
    for recordName in candidates {
      removeAndQueueDeletion(recordName: recordName, from: &state)
    }

    let retainedMessages = state.records.values.compactMap { payload -> SyncedMessage? in
      guard payload.deletedAt == nil,
            let message = payload.messageValue,
            MessageSyncWindow.includes(date: message.sentAt, referenceDate: referenceDate)
      else { return nil }
      return message
    }
    let retainedMessagesByConversation = Dictionary(
      grouping: retainedMessages,
      by: \.conversationID
    ).mapValues { $0.sorted(by: messageIsOrderedBefore) }
    let retainedConversationIDs = Set(retainedMessagesByConversation.keys)

    for (recordName, payload) in state.records
      where (payload.kind == .messageConversation || payload.kind == .messageReadState)
        && !retainedConversationIDs.contains(payload.id) {
      candidates.insert(recordName)
    }
    for (recordName, payload) in state.baseRecords
      where (payload.kind == .messageConversation || payload.kind == .messageReadState)
        && !retainedConversationIDs.contains(payload.id) {
      candidates.insert(recordName)
    }

    for (recordName, payload) in Array(state.records) {
      guard !candidates.contains(recordName),
            let messages = retainedMessagesByConversation[payload.id],
            !messages.isEmpty
      else { continue }

      switch payload {
      case let .messageConversation(value):
        let next = sanitizedConversation(
          value,
          retainedMessages: messages,
          referenceDate: referenceDate
        )
        let nextPayload = IAgentSyncPayload.messageConversation(next)
        if !messageProjectionIsTransportEquivalent(payload, nextPayload) {
          state.records[recordName] = nextPayload
          state.pendingRecordNames.insert(recordName)
          state.pendingDeletionRecordNames.remove(recordName)
          sanitized = true
        }
      case let .messageReadState(value):
        let next = sanitizedReadState(
          value,
          retainedMessages: messages,
          referenceDate: referenceDate
        )
        let nextPayload = IAgentSyncPayload.messageReadState(next)
        if !messageProjectionIsTransportEquivalent(payload, nextPayload) {
          state.records[recordName] = nextPayload
          state.pendingRecordNames.insert(recordName)
          state.pendingDeletionRecordNames.remove(recordName)
          sanitized = true
        }
      default:
        break
      }
    }

    // Base records represent acknowledged server state. If that state still carries
    // a preview or read cursor outside the retention window, scrub the local copy of
    // the ancestry instead of rewriting it to unsent content. The repaired projection
    // remains pending until CloudKit acknowledges that exact payload.
    for (recordName, payload) in Array(state.baseRecords) {
      guard !candidates.contains(recordName),
            let messages = retainedMessagesByConversation[payload.id],
            !messages.isEmpty
      else { continue }

      let needsScrub: Bool
      switch payload {
      case let .messageConversation(value):
        let next = IAgentSyncPayload.messageConversation(
          sanitizedConversation(
            value,
            retainedMessages: messages,
            referenceDate: referenceDate
          )
        )
        needsScrub = !messageProjectionIsTransportEquivalent(payload, next)
      case let .messageReadState(value):
        let next = IAgentSyncPayload.messageReadState(
          sanitizedReadState(
            value,
            retainedMessages: messages,
            referenceDate: referenceDate
          )
        )
        needsScrub = !messageProjectionIsTransportEquivalent(payload, next)
      default:
        needsScrub = false
      }
      if needsScrub {
        state.baseRecords.removeValue(forKey: recordName)
        state.cloudSystemFields.removeValue(forKey: recordName)
        if state.records[recordName] != nil {
          state.pendingRecordNames.insert(recordName)
        }
        sanitized = true
      }
    }

    for recordName in candidates {
      removeAndQueueDeletion(recordName: recordName, from: &state)
    }
    return (!candidates.isEmpty || sanitized, candidates)
  }

  private static func messageIsOrderedBefore(
    _ lhs: SyncedMessage,
    _ rhs: SyncedMessage
  ) -> Bool {
    if lhs.sentAt == rhs.sentAt { return lhs.id < rhs.id }
    return lhs.sentAt < rhs.sentAt
  }

  private static func sanitizedConversation(
    _ conversation: SyncedMessageConversation,
    retainedMessages: [SyncedMessage],
    referenceDate: Date
  ) -> SyncedMessageConversation {
    guard let latestMessage = retainedMessages.last else { return conversation }
    let retainedMessageIDs = Set(retainedMessages.map(\.id))
    let retainedAwaitingReplyMessageID = conversation.awaitingReplyMessageID.flatMap {
      retainedMessageIDs.contains($0) ? $0 : nil
    }
    guard conversation.latestMessageID != latestMessage.id
      || conversation.latestMessageDate != latestMessage.sentAt
      || conversation.latestPreview != latestMessage.body
      || conversation.awaitingReplyMessageID != retainedAwaitingReplyMessageID
    else { return conversation }

    var next = conversation
    next.latestMessageID = latestMessage.id
    next.latestMessageDate = latestMessage.sentAt
    next.latestPreview = latestMessage.body
    next.awaitingReplyMessageID = retainedAwaitingReplyMessageID
    next.updatedAt = max(conversation.updatedAt, referenceDate)
    return next
  }

  private static func sanitizedReadState(
    _ readState: SyncedMessageReadState,
    retainedMessages: [SyncedMessage],
    referenceDate: Date
  ) -> SyncedMessageReadState {
    guard let latestMessage = retainedMessages.last else { return readState }

    let readThroughMessage: SyncedMessage?
    if let readThroughMessageID = readState.readThroughMessageID,
       let exact = retainedMessages.first(where: { $0.id == readThroughMessageID }) {
      readThroughMessage = exact
    } else if let readThroughDate = readState.readThroughDate {
      readThroughMessage = retainedMessages.last { message in
        if message.sentAt != readThroughDate {
          return message.sentAt < readThroughDate
        }
        guard let readThroughMessageID = readState.readThroughMessageID else {
          return true
        }
        return message.id <= readThroughMessageID
      }
    } else {
      readThroughMessage = nil
    }

    let nextReadThroughID = readThroughMessage?.id
    let nextReadThroughDate = readThroughMessage?.sentAt
    guard readState.readThroughMessageID != nextReadThroughID
      || readState.readThroughDate != nextReadThroughDate
      || readState.latestKnownMessageDate != latestMessage.sentAt
    else { return readState }

    var next = readState
    next.readThroughMessageID = nextReadThroughID
    next.readThroughDate = nextReadThroughDate
    next.latestKnownMessageDate = latestMessage.sentAt
    next.updatedAt = max(readState.updatedAt, referenceDate)
    return next
  }

  private var currentStateIsEmpty: Bool {
    state.records.isEmpty
      && state.baseRecords.isEmpty
      && state.pendingRecordNames.isEmpty
      && state.pendingDeletionRecordNames.isEmpty
      && state.cloudSystemFields.isEmpty
      && state.lastSuccessfulSyncAt == nil
      && state.malformedRecordNames.isEmpty
  }

  private var stateHasUnboundCloudHistory: Bool {
    state.cloudAccountFingerprint == nil
      && (!state.baseRecords.isEmpty
        || !state.pendingDeletionRecordNames.isEmpty
        || !state.cloudSystemFields.isEmpty
        || state.lastSuccessfulSyncAt != nil)
  }

  private func quarantineCurrentState(reason: String) throws -> URL {
    if let persistenceBlocker {
      throw IAgentLocalSyncStoreError.corruptStoreCouldNotBePreserved(persistenceBlocker)
    }
    let directory = fileURL.deletingLastPathComponent()
      .appendingPathComponent("AccountQuarantine", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(
      "sync-store-\(reason)-\(UUID().uuidString.lowercased()).json"
    )
    let data = try JSONEncoder.iAgent.encode(state)
    if let fingerprint = state.cloudAccountFingerprint {
      let vaultURL = accountVaultURL(for: fingerprint)
      try FileManager.default.createDirectory(
        at: vaultURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: vaultURL, options: .atomic)
    }
    try data.write(to: destination, options: .atomic)
    return destination
  }

  private func loadAccountVault(for fingerprint: String) throws -> PersistedSyncState? {
    let vaultURL = accountVaultURL(for: fingerprint)
    guard FileManager.default.fileExists(atPath: vaultURL.path) else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: vaultURL)
    } catch {
      throw IAgentLocalSyncStoreError.corruptStoreCouldNotBePreserved(
        error.localizedDescription
      )
    }

    do {
      let restoredState = try JSONDecoder.iAgent.decode(PersistedSyncState.self, from: data)
      guard restoredState.cloudAccountFingerprint == fingerprint,
            restoredState.malformedRecordNamesFoundWhileDecoding.isEmpty
      else {
        throw IAgentLocalSyncStoreError.cloudAccountMismatch
      }
      return restoredState
    } catch {
      do {
        _ = try Self.preserveCorruptStore(data, sourceURL: vaultURL)
      } catch {
        throw IAgentLocalSyncStoreError.corruptStoreCouldNotBePreserved(
          error.localizedDescription
        )
      }
      throw error
    }
  }

  private func accountVaultURL(for fingerprint: String) -> URL {
    let safeName = SHA256.hash(data: Data(fingerprint.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return fileURL.deletingLastPathComponent()
      .appendingPathComponent("AccountStores", isDirectory: true)
      .appendingPathComponent("sync-store-\(safeName).json")
  }

  private func persistAndNotify() throws {
    if let persistenceBlocker {
      throw IAgentLocalSyncStoreError.corruptStoreCouldNotBePreserved(persistenceBlocker)
    }
    try Self.persist(state, to: fileURL)
    NotificationCenter.default.post(name: .iAgentSyncStoreDidChange, object: nil)
  }

  private static func loadState(
    from fileURL: URL
  ) -> (state: PersistedSyncState, quarantineURL: URL?, persistenceBlocker: String?) {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return (PersistedSyncState(), nil, nil)
      }
      return (
        PersistedSyncState(malformedRecordNames: ["<sync-store>"]),
        nil,
        error.localizedDescription
      )
    }

    let decodedState: PersistedSyncState
    do {
      decodedState = try JSONDecoder.iAgent.decode(PersistedSyncState.self, from: data)
    } catch {
      let state = PersistedSyncState(
        malformedRecordNames: ["<sync-store>"],
        malformedRecordNamesFoundWhileDecoding: ["<sync-store>"]
      )
      do {
        let quarantineURL = try preserveCorruptStore(data, sourceURL: fileURL)
        return (state, quarantineURL, nil)
      } catch {
        return (state, nil, error.localizedDescription)
      }
    }

    guard !decodedState.malformedRecordNamesFoundWhileDecoding.isEmpty else {
      return (decodedState, nil, nil)
    }
    do {
      let quarantineURL = try preserveCorruptStore(data, sourceURL: fileURL)
      return (decodedState, quarantineURL, nil)
    } catch {
      return (decodedState, nil, error.localizedDescription)
    }
  }

  private static func preserveCorruptStore(_ data: Data, sourceURL: URL) throws -> URL {
    let directory = sourceURL.deletingLastPathComponent()
      .appendingPathComponent("SyncStoreQuarantine", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let digest = SHA256.hash(data: data).prefix(12)
      .map { String(format: "%02x", $0) }
      .joined()
    let destination = directory.appendingPathComponent("sync-store-corrupt-\(digest).json")
    if FileManager.default.fileExists(atPath: destination.path) {
      return destination
    }
    try data.write(to: destination, options: .atomic)
    return destination
  }

  private func merge(
    local: IAgentSyncPayload,
    remote: IAgentSyncPayload,
    base: IAgentSyncPayload?
  ) -> (primary: IAgentSyncPayload, conflictCopy: IAgentSyncPayload?) {
    switch (local, remote, base) {
    case let (
      .messageConversation(localConversation),
      .messageConversation(remoteConversation),
      _
    ) where messageProjectionRole == .localAuthority:
      var primary = localConversation
      primary.updatedAt = max(localConversation.updatedAt, remoteConversation.updatedAt)
      return (.messageConversation(primary), nil)

    case let (.message(localMessage), .message(remoteMessage), _)
      where messageProjectionRole == .localAuthority:
      var primary = localMessage
      primary.updatedAt = max(localMessage.updatedAt, remoteMessage.updatedAt)
      return (.message(primary), nil)

    case let (
      .messageReadState(localReadState),
      .messageReadState(remoteReadState),
      _
    ):
      return (
        .messageReadState(
          mergeMessageReadState(local: localReadState, remote: remoteReadState)
        ),
        nil
      )

    case let (.desktopSnapshot(localSnapshot), .desktopSnapshot(remoteSnapshot), _):
      var winner: SyncedDesktopSnapshot
      if localSnapshot.generatedAt != remoteSnapshot.generatedAt {
        winner = localSnapshot.generatedAt > remoteSnapshot.generatedAt
          ? localSnapshot
          : remoteSnapshot
      } else {
        winner = shouldPrefer(local, over: remote) ? localSnapshot : remoteSnapshot
      }
      let localLastSeenAt = localSnapshot.lastSeenAt ?? localSnapshot.generatedAt
      let remoteLastSeenAt = remoteSnapshot.lastSeenAt ?? remoteSnapshot.generatedAt
      winner.lastSeenAt = max(localLastSeenAt, remoteLastSeenAt)
      return (.desktopSnapshot(winner), nil)

    case let (.todo(localTodo), .todo(remoteTodo), .some(.todo(baseTodo))):
      return (
        .todo(mergeTodo(
          local: localTodo,
          remote: remoteTodo,
          base: baseTodo,
          preferLocal: shouldPrefer(local, over: remote)
        )),
        nil
      )

    case let (.note(localNote), .note(remoteNote), .some(.note(baseNote))):
      let localChangedBody = localNote.body != baseNote.body
      let remoteChangedBody = remoteNote.body != baseNote.body
      if localChangedBody, remoteChangedBody, localNote.body != remoteNote.body {
        let preferLocal = shouldPrefer(local, over: remote)
        let primary = mergeNote(
          local: localNote,
          remote: remoteNote,
          base: baseNote,
          preferLocal: preferLocal
        )
        let losingVersion = preferLocal ? remoteNote : localNote
        let stamp = ISO8601DateFormatter().string(from: losingVersion.updatedAt)
        let conflict = SyncedNote(
          id: deterministicConflictID(for: losingVersion),
          kind: losingVersion.kind,
          title: "\(losingVersion.title) (Conflict \(stamp))",
          body: losingVersion.body,
          createdAt: losingVersion.createdAt,
          updatedAt: max(localNote.updatedAt, remoteNote.updatedAt),
          sourceDeviceID: losingVersion.sourceDeviceID
        )
        return (.note(primary), .note(conflict))
      }
      return (
        .note(mergeNote(
          local: localNote,
          remote: remoteNote,
          base: baseNote,
          preferLocal: shouldPrefer(local, over: remote)
        )),
        nil
      )

    default:
      return (shouldPrefer(local, over: remote) ? local : remote, nil)
    }
  }

  private func mergeMessageReadState(
    local: SyncedMessageReadState,
    remote: SyncedMessageReadState
  ) -> SyncedMessageReadState {
    let cursorSource: SyncedMessageReadState
    switch Self.compareReadCursor(local, remote) {
    case .orderedDescending:
      cursorSource = local
    case .orderedAscending:
      cursorSource = remote
    case .orderedSame:
      cursorSource = local.updatedAt >= remote.updatedAt ? local : remote
    }

    let metadataSource = local.updatedAt >= remote.updatedAt ? local : remote
    return SyncedMessageReadState(
      id: local.id,
      readThroughMessageID: cursorSource.readThroughMessageID,
      readThroughDate: cursorSource.readThroughDate,
      latestKnownMessageDate: max(local.latestKnownMessageDate, remote.latestKnownMessageDate),
      updatedAt: max(local.updatedAt, remote.updatedAt),
      sourceDeviceID: cursorSource.sourceDeviceID,
      deletedAt: metadataSource.deletedAt
    )
  }

  private static func compareReadCursor(
    _ lhs: SyncedMessageReadState,
    _ rhs: SyncedMessageReadState
  ) -> ComparisonResult {
    switch (lhs.readThroughDate, rhs.readThroughDate) {
    case let (left?, right?) where left < right:
      return .orderedAscending
    case let (left?, right?) where left > right:
      return .orderedDescending
    case (nil, .some):
      return .orderedAscending
    case (.some, nil):
      return .orderedDescending
    default:
      let leftID = lhs.readThroughMessageID ?? ""
      let rightID = rhs.readThroughMessageID ?? ""
      return leftID.compare(rightID)
    }
  }

  private func mergeTodo(
    local: SyncedTodo,
    remote: SyncedTodo,
    base: SyncedTodo,
    preferLocal: Bool
  ) -> SyncedTodo {
    SyncedTodo(
      id: local.id,
      title: mergeField(base: base.title, local: local.title, remote: remote.title, preferLocal: preferLocal),
      notes: mergeField(base: base.notes, local: local.notes, remote: remote.notes, preferLocal: preferLocal),
      isCompleted: mergeField(base: base.isCompleted, local: local.isCompleted, remote: remote.isCompleted, preferLocal: preferLocal),
      isStarred: mergeField(base: base.isStarred, local: local.isStarred, remote: remote.isStarred, preferLocal: preferLocal),
      dueDate: mergeField(base: base.dueDate, local: local.dueDate, remote: remote.dueDate, preferLocal: preferLocal),
      listName: mergeField(base: base.listName, local: local.listName, remote: remote.listName, preferLocal: preferLocal),
      completedAt: mergeField(base: base.completedAt, local: local.completedAt, remote: remote.completedAt, preferLocal: preferLocal),
      createdAt: min(local.createdAt, remote.createdAt),
      updatedAt: max(local.updatedAt, remote.updatedAt),
      deletedAt: mergeField(base: base.deletedAt, local: local.deletedAt, remote: remote.deletedAt, preferLocal: preferLocal)
    )
  }

  private func mergeNote(
    local: SyncedNote,
    remote: SyncedNote,
    base: SyncedNote,
    preferLocal: Bool
  ) -> SyncedNote {
    // Keep the preferred record's identity and metadata, but merge the two editor fields
    // independently. A body-only save must not roll back a concurrent title edit (or vice versa).
    // Divergent dual-body edits are handled above and still produce a conflict copy.
    var merged = preferLocal ? local : remote
    merged.title = mergeField(
      base: base.title,
      local: local.title,
      remote: remote.title,
      preferLocal: preferLocal
    )
    merged.body = mergeField(
      base: base.body,
      local: local.body,
      remote: remote.body,
      preferLocal: preferLocal
    )
    return merged
  }

  private func shouldPrefer(
    _ local: IAgentSyncPayload,
    over remote: IAgentSyncPayload
  ) -> Bool {
    if local.updatedAt != remote.updatedAt {
      return local.updatedAt > remote.updatedAt
    }

    guard let localData = try? JSONEncoder.iAgent.encode(local),
          let remoteData = try? JSONEncoder.iAgent.encode(remote),
          localData != remoteData
    else { return true }
    return remoteData.lexicographicallyPrecedes(localData)
  }

  private func deterministicConflictID(for note: SyncedNote) -> UUID {
    let payload = (try? JSONEncoder.iAgent.encode(IAgentSyncPayload.note(note))) ?? Data()
    var bytes = Array(SHA256.hash(data: payload).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  private func mergeField<Value: Equatable>(
    base: Value,
    local: Value,
    remote: Value,
    preferLocal: Bool
  ) -> Value {
    if local == base { return remote }
    if remote == base { return local }
    if local == remote { return local }
    return preferLocal ? local : remote
  }
}

private extension IAgentSyncPayload {
  var noteValue: SyncedNote? {
    guard case let .note(value) = self else { return nil }
    return value
  }

  var todoValue: SyncedTodo? {
    guard case let .todo(value) = self else { return nil }
    return value
  }

  var todoListValue: SyncedTodoList? {
    guard case let .todoList(value) = self else { return nil }
    return value
  }

  var meetingValue: SyncedMeetingSession? {
    guard case let .meetingSession(value) = self else { return nil }
    return value
  }

  var codexValue: SyncedCodexThread? {
    guard case let .codexThread(value) = self else { return nil }
    return value
  }

  var calendarValue: SyncedCalendarEvent? {
    guard case let .calendarEvent(value) = self else { return nil }
    return value
  }

  var desktopValue: SyncedDesktopSnapshot? {
    guard case let .desktopSnapshot(value) = self else { return nil }
    return value
  }

  var messageConversationValue: SyncedMessageConversation? {
    guard case let .messageConversation(value) = self else { return nil }
    return value
  }

  var messageValue: SyncedMessage? {
    guard case let .message(value) = self else { return nil }
    return value
  }

  var messageReadStateValue: SyncedMessageReadState? {
    guard case let .messageReadState(value) = self else { return nil }
    return value
  }

  var messageRelayStateValue: SyncedMessageRelayState? {
    guard case let .messageRelayState(value) = self else { return nil }
    return value
  }
}

extension JSONEncoder {
  static var iAgent: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  static var iAgent: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

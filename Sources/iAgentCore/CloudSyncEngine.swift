import CloudKit
import CryptoKit
import Foundation

public enum IAgentCloudSyncPhase: String, Codable, Sendable {
  case idle
  case syncing
  case offline
  case accountUnavailable
  case failed
}

public struct IAgentCloudSyncStatus: Codable, Sendable, Equatable {
  public var phase: IAgentCloudSyncPhase
  public var lastSuccessfulSyncAt: Date?
  public var lastAttemptedSyncAt: Date?
  public var pendingRecordCount: Int
  public var message: String?

  public init(
    phase: IAgentCloudSyncPhase = .idle,
    lastSuccessfulSyncAt: Date? = nil,
    lastAttemptedSyncAt: Date? = nil,
    pendingRecordCount: Int = 0,
    message: String? = nil
  ) {
    self.phase = phase
    self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    self.lastAttemptedSyncAt = lastAttemptedSyncAt
    self.pendingRecordCount = pendingRecordCount
    self.message = message
  }
}

struct IAgentSyncPayloadDecodeCandidate: Sendable {
  var recordName: String
  var data: Data
}

struct IAgentDecodedSyncPayload: Sendable, Equatable {
  var recordName: String
  var payload: IAgentSyncPayload
}

struct IAgentSyncPayloadDecodeFailure: Sendable, Equatable {
  var recordName: String
  var reason: String
}

struct IAgentSyncPayloadDecodeBatch: Sendable, Equatable {
  var decoded: [IAgentDecodedSyncPayload]
  var failures: [IAgentSyncPayloadDecodeFailure]
}

enum IAgentSyncPayloadBatchDecoder {
  static func decode(_ candidates: [IAgentSyncPayloadDecodeCandidate]) -> IAgentSyncPayloadDecodeBatch {
    var decoded: [IAgentDecodedSyncPayload] = []
    var failures: [IAgentSyncPayloadDecodeFailure] = []

    for candidate in candidates {
      do {
        let payload = try JSONDecoder.iAgent.decode(IAgentSyncPayload.self, from: candidate.data)
        guard payload.recordName == candidate.recordName else {
          failures.append(IAgentSyncPayloadDecodeFailure(
            recordName: candidate.recordName,
            reason: "The encrypted payload identity does not match its CloudKit record."
          ))
          continue
        }
        decoded.append(IAgentDecodedSyncPayload(
          recordName: candidate.recordName,
          payload: payload
        ))
      } catch {
        failures.append(IAgentSyncPayloadDecodeFailure(
          recordName: candidate.recordName,
          reason: "The encrypted payload could not be decoded."
        ))
      }
    }

    return IAgentSyncPayloadDecodeBatch(decoded: decoded, failures: failures)
  }
}

private actor CloudSyncStatusState {
  private var value = IAgentCloudSyncStatus()

  func read() -> IAgentCloudSyncStatus {
    value
  }

  func update(
    phase: IAgentCloudSyncPhase,
    lastSuccessfulSyncAt: Date? = nil,
    lastAttemptedSyncAt: Date? = nil,
    message: String? = nil
  ) {
    value = IAgentCloudSyncStatus(
      phase: phase,
      lastSuccessfulSyncAt: lastSuccessfulSyncAt ?? value.lastSuccessfulSyncAt,
      lastAttemptedSyncAt: lastAttemptedSyncAt ?? value.lastAttemptedSyncAt,
      pendingRecordCount: value.pendingRecordCount,
      message: message
    )
  }
}

actor IAgentCloudSyncSingleFlight {
  private var inFlight: Task<Void, Never>?
  private var hasPendingIntent = false
  private var pendingFetchesRemoteChanges = false

  func run(
    fetchesRemoteChanges: Bool,
    operation: @escaping @Sendable (Bool) async -> Void
  ) async {
    if let inFlight {
      hasPendingIntent = true
      pendingFetchesRemoteChanges = pendingFetchesRemoteChanges || fetchesRemoteChanges
      await inFlight.value
      return
    }

    let task = Task { [weak self] in
      var shouldFetch = fetchesRemoteChanges
      while let self {
        await operation(shouldFetch)
        guard let nextIntent = await self.takePendingIntentOrFinish() else { return }
        shouldFetch = nextIntent
      }
    }
    inFlight = task
    await task.value
  }

  private func takePendingIntentOrFinish() -> Bool? {
    guard hasPendingIntent else {
      inFlight = nil
      return nil
    }
    let nextIntent = pendingFetchesRemoteChanges
    hasPendingIntent = false
    pendingFetchesRemoteChanges = false
    return nextIntent
  }

  func pendingIntentCountForTesting() -> Int {
    hasPendingIntent ? 1 : 0
  }
}

private actor CloudAccountSessionState {
  private var fingerprint: String?
  private var preparedFingerprint: String?

  func activate(_ fingerprint: String) {
    self.fingerprint = fingerprint
  }

  func deactivate() {
    fingerprint = nil
  }

  func requiresPreparation(for fingerprint: String) -> Bool {
    preparedFingerprint != fingerprint
  }

  func markPrepared(_ fingerprint: String) {
    preparedFingerprint = fingerprint
  }

  func reset() {
    fingerprint = nil
    preparedFingerprint = nil
  }

  func read() -> String? {
    fingerprint
  }
}

public final class IAgentCloudSyncEngine: CKSyncEngineDelegate, @unchecked Sendable {
  public static let defaultZoneName = "iAgentPrivate-v1"
  public static let defaultRecordType = "IAgentEntity"

  public let store: IAgentLocalSyncStore
  public let containerIdentifier: String
  public let stateFileURL: URL

  private let zoneID: CKRecordZone.ID
  private let recordType: CKRecord.RecordType
  private let container: CKContainer
  private let statusState = CloudSyncStatusState()
  private let accountSessionState = CloudAccountSessionState()
  private let singleFlight = IAgentCloudSyncSingleFlight()
  private var engine: CKSyncEngine!

  private var stateBindingFileURL: URL {
    stateFileURL.deletingLastPathComponent()
      .appendingPathComponent("\(stateFileURL.lastPathComponent).account")
  }

  public init(
    store: IAgentLocalSyncStore,
    containerIdentifier: String,
    stateFileURL: URL,
    zoneName: String = IAgentCloudSyncEngine.defaultZoneName,
    recordType: CKRecord.RecordType = IAgentCloudSyncEngine.defaultRecordType
  ) {
    self.store = store
    self.containerIdentifier = containerIdentifier
    self.stateFileURL = stateFileURL
    self.zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    self.recordType = recordType

    let container = CKContainer(identifier: containerIdentifier)
    self.container = container
    let configuration = CKSyncEngine.Configuration(
      database: container.privateCloudDatabase,
      stateSerialization: nil,
      delegate: self
    )
    engine = CKSyncEngine(configuration)
  }

  public func status() async -> IAgentCloudSyncStatus {
    var status = await statusState.read()
    let diagnostics = await store.diagnostics()
    status.pendingRecordCount = diagnostics.pendingRecordCount
    if status.lastSuccessfulSyncAt == nil {
      status.lastSuccessfulSyncAt = diagnostics.lastSuccessfulSyncAt
    }
    return status
  }

  public func start() async {
    await synchronize()
  }

  public func synchronize() async {
    await singleFlight.run(fetchesRemoteChanges: true) { [weak self] shouldFetch in
      await self?.performSynchronization(fetchesRemoteChanges: shouldFetch)
    }
  }

  public func pushLocalChanges() async {
    await singleFlight.run(fetchesRemoteChanges: false) { [weak self] shouldFetch in
      await self?.performSynchronization(fetchesRemoteChanges: shouldFetch)
    }
  }

  private func performSynchronization(fetchesRemoteChanges: Bool) async {
    await setStatus(.syncing, lastAttemptedSyncAt: Date())
    do {
      guard let accountFingerprint = try await prepareCurrentCloudAccount() else { return }

      try await store.enforceMessageRetention(
        cloudAccountFingerprint: accountFingerprint
      )
      await enqueueZoneIfNeeded()
      await enqueuePendingLocalChanges()
      if fetchesRemoteChanges {
        try await engine.fetchChanges()
        try await store.enforceMessageRetention(
          cloudAccountFingerprint: accountFingerprint
        )
        await enqueuePendingLocalChanges()
      }
      try await engine.sendChanges()
      guard await currentAttemptCanSucceed() else { return }
      let completedAt = Date()
      try await store.markSyncSuccessful(
        at: completedAt,
        cloudAccountFingerprint: accountFingerprint
      )
      await setStatus(.idle, lastSuccessfulSyncAt: completedAt)
    } catch {
      await setStatus(Self.phase(for: error), message: error.localizedDescription)
    }
  }

  public func stop() async {
    await engine.cancelOperations()
  }

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    guard syncEngine === engine else { return }

    do {
      switch event {
      case let .stateUpdate(update):
        if let accountFingerprint = await accountSessionState.read() {
          try Self.persist(update.stateSerialization, to: stateFileURL)
          try Self.persistAccountFingerprint(
            accountFingerprint,
            to: stateBindingFileURL
          )
        }

      case let .fetchedRecordZoneChanges(changes):
        try await applyFetchedChanges(changes, syncEngine: syncEngine)

      case let .sentRecordZoneChanges(changes):
        try await applySentChanges(changes, syncEngine: syncEngine)

      case let .sentDatabaseChanges(changes):
        if let failure = changes.failedZoneSaves.first {
          await setStatus(.failed, message: failure.error.localizedDescription)
        }

      case .didFetchChanges, .didSendChanges:
        if await currentAttemptCanSucceed() {
          await setStatus(.idle)
        }

      case let .accountChange(change):
        switch change.changeType {
        case .signIn:
          await setStatus(.idle, message: "iCloud is available. Sync to load this account.")
        case .signOut:
          try await quarantineForCloudAccountChange(syncEngine: syncEngine)
          await setStatus(
            .accountUnavailable,
            message: "Sign in to iCloud to sync this device. Previous account data was safely quarantined."
          )
        case .switchAccounts:
          try await quarantineForCloudAccountChange(syncEngine: syncEngine)
          await setStatus(
            .accountUnavailable,
            message: "The iCloud account changed. Previous account data was safely quarantined."
          )
        @unknown default:
          try await quarantineForCloudAccountChange(syncEngine: syncEngine)
          await setStatus(.accountUnavailable, message: "The iCloud account changed.")
        }

      default:
        break
      }
    } catch {
      await setStatus(Self.phase(for: error), message: error.localizedDescription)
    }
  }

  public func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    guard syncEngine === engine else { return nil }
    let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter {
      context.options.scope.contains($0)
    }

    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { [weak self] recordID in
      guard let self else { return nil }
      return await self.recordToSave(for: recordID)
    }
  }

  private func enqueueZoneIfNeeded() async {
    let zone = CKRecordZone(zoneID: zoneID)
    let change = CKSyncEngine.PendingDatabaseChange.saveZone(zone)
    if !engine.state.pendingDatabaseChanges.contains(change) {
      engine.state.add(pendingDatabaseChanges: [change])
    }
  }

  private func enqueuePendingLocalChanges() async {
    guard let accountFingerprint = await accountSessionState.read() else { return }
    let pending: IAgentPendingCloudChanges
    do {
      pending = try await store.pendingCloudChanges(forCloudAccount: accountFingerprint)
    } catch {
      await setStatus(.accountUnavailable, message: error.localizedDescription)
      return
    }

    let saveNames = Set(pending.saveRecordNames)
    let deletionNames = Set(pending.deletionRecordNames)
    let current = engine.state.pendingRecordZoneChanges
    let obsolete = current.filter { change in
      switch change {
      case let .saveRecord(recordID):
        recordID.zoneID == zoneID && !saveNames.contains(recordID.recordName)
      case let .deleteRecord(recordID):
        recordID.zoneID == zoneID && !deletionNames.contains(recordID.recordName)
      @unknown default:
        false
      }
    }
    if !obsolete.isEmpty {
      engine.state.remove(pendingRecordZoneChanges: obsolete)
    }

    let existing = Set(engine.state.pendingRecordZoneChanges.compactMap(Self.recordID))
    let saveChanges = saveNames.compactMap { name -> CKSyncEngine.PendingRecordZoneChange? in
      let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)
      guard !existing.contains(recordID) else { return nil }
      return .saveRecord(recordID)
    }
    let existingWithSaves = existing.union(saveChanges.compactMap(Self.recordID))
    let deleteChanges = deletionNames.compactMap { name -> CKSyncEngine.PendingRecordZoneChange? in
      let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)
      guard !existingWithSaves.contains(recordID) else { return nil }
      return .deleteRecord(recordID)
    }
    let changes = saveChanges + deleteChanges
    if !changes.isEmpty {
      engine.state.add(pendingRecordZoneChanges: changes)
    }
  }

  private func recordToSave(for recordID: CKRecord.ID) async -> CKRecord? {
    do {
      guard let accountFingerprint = await accountSessionState.read() else { return nil }
      guard let material = try await store.cloudUploadMaterial(
        for: recordID.recordName,
        cloudAccountFingerprint: accountFingerprint
      ) else {
        await setStatus(.failed, message: "A queued local record is missing from the sync store.")
        return nil
      }
      let payload = material.payload
      let record: CKRecord
      if let fields = material.cloudSystemFields,
         let restored = Self.restoreRecord(from: fields)
      {
        record = restored
      } else {
        record = CKRecord(recordType: recordType, recordID: recordID)
      }

      let payloadData = try JSONEncoder.iAgent.encode(payload)
      record.encryptedValues.setObject(payloadData as NSData, forKey: "payload")
      record["kind"] = payload.kind.rawValue as NSString
      record["schemaVersion"] = 1 as NSNumber
      record["updatedAt"] = payload.updatedAt as NSDate
      if let deletedAt = payload.deletedAt {
        record["deletedAt"] = deletedAt as NSDate
      } else {
        record["deletedAt"] = nil
      }
      return record
    } catch {
      await setStatus(.failed, message: error.localizedDescription)
      return nil
    }
  }

  private func applyFetchedChanges(
    _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
    syncEngine: CKSyncEngine
  ) async throws {
    guard let accountFingerprint = await accountSessionState.read() else { return }
    var recordsByName: [String: CKRecord] = [:]
    var candidates: [IAgentSyncPayloadDecodeCandidate] = []
    var issueCount = 0

    for modification in changes.modifications {
      let record = modification.record
      guard record.recordType == recordType else { continue }
      let recordName = record.recordID.recordName
      recordsByName[recordName] = record
      guard let payloadData = record.encryptedValues.object(forKey: "payload") as? Data else {
        issueCount += 1
        continue
      }
      candidates.append(IAgentSyncPayloadDecodeCandidate(
        recordName: recordName,
        data: payloadData
      ))
    }

    let decodedBatch = IAgentSyncPayloadBatchDecoder.decode(candidates)
    issueCount += decodedBatch.failures.count
    let fetchedRecords = decodedBatch.decoded.compactMap { decoded -> IAgentFetchedRecord? in
      guard let record = recordsByName[decoded.recordName] else { return nil }
      return IAgentFetchedRecord(
        payload: decoded.payload,
        cloudSystemFields: Self.systemFields(for: record)
      )
    }
    let deletedRecordNames = changes.deletions.compactMap { deletion in
      deletion.recordID.zoneID == zoneID ? deletion.recordID.recordName : nil
    }
    _ = try await store.applyRemoteChanges(
      fetchedRecords,
      deletedRecordNames: deletedRecordNames,
      cloudAccountFingerprint: accountFingerprint
    )
    try await store.enforceMessageRetention(
      cloudAccountFingerprint: accountFingerprint
    )
    await enqueuePendingLocalChanges()

    if issueCount > 0 {
      await setStatus(.failed, message: Self.recordProcessingMessage(
        operation: "download",
        issueCount: issueCount
      ))
    }
  }

  private func applySentChanges(
    _ changes: CKSyncEngine.Event.SentRecordZoneChanges,
    syncEngine: CKSyncEngine
  ) async throws {
    guard let accountFingerprint = await accountSessionState.read() else { return }
    var issueCount = 0
    var savedRecordsByName: [String: CKRecord] = [:]
    var sentCandidates: [IAgentSyncPayloadDecodeCandidate] = []
    for record in changes.savedRecords where record.recordType == recordType {
      let recordName = record.recordID.recordName
      savedRecordsByName[recordName] = record
      guard let payloadData = record.encryptedValues.object(forKey: "payload") as? Data else {
        issueCount += 1
        continue
      }
      sentCandidates.append(IAgentSyncPayloadDecodeCandidate(
        recordName: recordName,
        data: payloadData
      ))
    }
    let sentBatch = IAgentSyncPayloadBatchDecoder.decode(sentCandidates)
    issueCount += sentBatch.failures.count
    let sentRecords = sentBatch.decoded.compactMap { decoded -> IAgentSentRecord? in
      guard let record = savedRecordsByName[decoded.recordName] else { return nil }
      return IAgentSentRecord(
        recordName: decoded.recordName,
        sentPayload: decoded.payload,
        cloudSystemFields: Self.systemFields(for: record)
      )
    }
    if !sentRecords.isEmpty {
      try await store.markSent(
        sentRecords,
        cloudAccountFingerprint: accountFingerprint
      )
    }

    var firstCloudFailure: CKError?
    for recordID in changes.deletedRecordIDs where recordID.zoneID == zoneID {
      try await store.acknowledgeDeletion(
        recordName: recordID.recordName,
        cloudAccountFingerprint: accountFingerprint
      )
    }

    for (recordID, error) in changes.failedRecordDeletes where recordID.zoneID == zoneID {
      if error.code == .unknownItem {
        try await store.acknowledgeDeletion(
          recordName: recordID.recordName,
          cloudAccountFingerprint: accountFingerprint
        )
        syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
      } else {
        if firstCloudFailure == nil {
          firstCloudFailure = error
        }
        try await store.requeueDeletion(
          recordName: recordID.recordName,
          cloudAccountFingerprint: accountFingerprint
        )
      }
    }

    for failure in changes.failedRecordSaves {
      if firstCloudFailure == nil {
        firstCloudFailure = failure.error
      }
      var mergedServerRecord = false
      if failure.error.code == .serverRecordChanged,
         let serverRecord = failure.error.serverRecord,
         let payloadData = serverRecord.encryptedValues.object(forKey: "payload") as? Data
      {
        let decoded = IAgentSyncPayloadBatchDecoder.decode([
          IAgentSyncPayloadDecodeCandidate(
            recordName: serverRecord.recordID.recordName,
            data: payloadData
          )
        ])
        if let payload = decoded.decoded.first?.payload {
          do {
            _ = try await store.mergeRemote(
              payload,
              cloudSystemFields: Self.systemFields(for: serverRecord),
              cloudAccountFingerprint: accountFingerprint
            )
            mergedServerRecord = true
          } catch {
            issueCount += 1
          }
        } else {
          issueCount += max(1, decoded.failures.count)
        }
      }

      if !mergedServerRecord {
        // The store remains authoritative about whether this ID is still a save,
        // a delete, or was superseded while the request was in flight. The final
        // reconciliation below recreates only the still-desired change.
      }
    }

    try await store.enforceMessageRetention(
      cloudAccountFingerprint: accountFingerprint
    )
    await enqueuePendingLocalChanges()

    if issueCount > 0 {
      await setStatus(.failed, message: Self.recordProcessingMessage(
        operation: "upload",
        issueCount: issueCount
      ))
    } else if let firstCloudFailure {
      await setStatus(
        Self.phase(for: firstCloudFailure),
        message: firstCloudFailure.localizedDescription
      )
    }
  }

  private func prepareCurrentCloudAccount() async throws -> String? {
    let accountStatus = try await container.accountStatus()
    guard accountStatus == .available else {
      if accountStatus == .noAccount {
        try await quarantineForCloudAccountChange(syncEngine: engine)
      }
      await setStatus(.accountUnavailable, message: Self.accountMessage(for: accountStatus))
      return nil
    }

    let userRecordID = try await container.userRecordID()
    let accountFingerprint = Self.accountFingerprint(for: userRecordID)
    await accountSessionState.deactivate()
    let transition = try await store.bind(toCloudAccount: accountFingerprint)
    if await accountSessionState.requiresPreparation(for: accountFingerprint)
        || transition.requiresCloudStateReset
    {
      await engine.cancelOperations()
      let persistedStateMatchesAccount =
        Self.loadAccountFingerprint(from: stateBindingFileURL) == accountFingerprint
      let stateSerialization: CKSyncEngine.State.Serialization?
      if transition == .unchanged, persistedStateMatchesAccount {
        stateSerialization = Self.loadStateSerialization(from: stateFileURL)
      } else {
        try Self.quarantineCloudStateFiles(
          stateFileURL: stateFileURL,
          bindingFileURL: stateBindingFileURL,
          reason: transition.quarantineReason
        )
        stateSerialization = nil
      }
      engine = makeEngine(stateSerialization: stateSerialization)
      await accountSessionState.markPrepared(accountFingerprint)
    }
    await accountSessionState.activate(accountFingerprint)
    return accountFingerprint
  }

  private func quarantineForCloudAccountChange(syncEngine: CKSyncEngine) async throws {
    guard syncEngine === engine else { return }
    await accountSessionState.reset()
    _ = try await store.quarantineForCloudAccountSignOut()
    try Self.quarantineCloudStateFiles(
      stateFileURL: stateFileURL,
      bindingFileURL: stateBindingFileURL,
      reason: "account-change"
    )
  }

  private func makeEngine(
    stateSerialization: CKSyncEngine.State.Serialization?
  ) -> CKSyncEngine {
    let configuration = CKSyncEngine.Configuration(
      database: container.privateCloudDatabase,
      stateSerialization: stateSerialization,
      delegate: self
    )
    return CKSyncEngine(configuration)
  }

  private func setStatus(
    _ phase: IAgentCloudSyncPhase,
    lastSuccessfulSyncAt: Date? = nil,
    lastAttemptedSyncAt: Date? = nil,
    message: String? = nil
  ) async {
    await statusState.update(
      phase: phase,
      lastSuccessfulSyncAt: lastSuccessfulSyncAt,
      lastAttemptedSyncAt: lastAttemptedSyncAt,
      message: message
    )
    NotificationCenter.default.post(name: .iAgentSyncStatusDidChange, object: nil)
  }

  private func currentAttemptCanSucceed() async -> Bool {
    switch await statusState.read().phase {
    case .syncing, .idle:
      true
    case .offline, .accountUnavailable, .failed:
      false
    }
  }

  private static func systemFields(for record: CKRecord) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  private static func restoreRecord(from data: Data) -> CKRecord? {
    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    unarchiver.requiresSecureCoding = true
    defer { unarchiver.finishDecoding() }
    return CKRecord(coder: unarchiver)
  }

  private static func recordID(
    _ change: CKSyncEngine.PendingRecordZoneChange
  ) -> CKRecord.ID? {
    switch change {
    case let .saveRecord(recordID), let .deleteRecord(recordID):
      recordID
    @unknown default:
      nil
    }
  }

  private static func loadStateSerialization(from fileURL: URL) -> CKSyncEngine.State.Serialization? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
  }

  private static func persist(
    _ serialization: CKSyncEngine.State.Serialization,
    to fileURL: URL
  ) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(serialization).write(to: fileURL, options: .atomic)
  }

  private static func persistAccountFingerprint(_ fingerprint: String, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(fingerprint.utf8).write(to: fileURL, options: .atomic)
  }

  private static func loadAccountFingerprint(from fileURL: URL) -> String? {
    guard let data = try? Data(contentsOf: fileURL),
          let fingerprint = String(data: data, encoding: .utf8),
          !fingerprint.isEmpty
    else { return nil }
    return fingerprint
  }

  private static func quarantineCloudStateFiles(
    stateFileURL: URL,
    bindingFileURL: URL,
    reason: String
  ) throws {
    guard FileManager.default.fileExists(atPath: stateFileURL.path)
            || FileManager.default.fileExists(atPath: bindingFileURL.path)
    else { return }
    let directory = stateFileURL.deletingLastPathComponent()
      .appendingPathComponent("CloudStateQuarantine", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let identifier = UUID().uuidString.lowercased()
    if FileManager.default.fileExists(atPath: stateFileURL.path) {
      let destination = directory.appendingPathComponent(
        "cloud-state-\(reason)-\(identifier).json"
      )
      try FileManager.default.moveItem(at: stateFileURL, to: destination)
    }
    if FileManager.default.fileExists(atPath: bindingFileURL.path) {
      let destination = directory.appendingPathComponent(
        "cloud-state-\(reason)-\(identifier).account"
      )
      try FileManager.default.moveItem(at: bindingFileURL, to: destination)
    }
  }

  private static func accountFingerprint(for recordID: CKRecord.ID) -> String {
    SHA256.hash(data: Data(recordID.recordName.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func phase(for error: Error) -> IAgentCloudSyncPhase {
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

  private static func recordProcessingMessage(operation: String, issueCount: Int) -> String {
    let noun = issueCount == 1 ? "record" : "records"
    return "CloudKit skipped \(issueCount) \(noun) during \(operation). Other records were still processed."
  }

  private static func accountMessage(for status: CKAccountStatus) -> String {
    switch status {
    case .available: "iCloud is available."
    case .couldNotDetermine: "iCloud account status could not be determined."
    case .noAccount: "Sign in to iCloud to sync this device."
    case .restricted: "iCloud access is restricted on this device."
    case .temporarilyUnavailable: "iCloud is temporarily unavailable."
    @unknown default: "iCloud is unavailable."
    }
  }
}

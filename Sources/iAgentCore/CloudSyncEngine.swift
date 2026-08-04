import CloudKit
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
  public var message: String?

  public init(
    phase: IAgentCloudSyncPhase = .idle,
    lastSuccessfulSyncAt: Date? = nil,
    message: String? = nil
  ) {
    self.phase = phase
    self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    self.message = message
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
    message: String? = nil
  ) {
    value = IAgentCloudSyncStatus(
      phase: phase,
      lastSuccessfulSyncAt: lastSuccessfulSyncAt ?? value.lastSuccessfulSyncAt,
      message: message
    )
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
  private let statusState = CloudSyncStatusState()
  private var engine: CKSyncEngine!

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
    let serialization = Self.loadStateSerialization(from: stateFileURL)
    let configuration = CKSyncEngine.Configuration(
      database: container.privateCloudDatabase,
      stateSerialization: serialization,
      delegate: self
    )
    engine = CKSyncEngine(configuration)
  }

  public func status() async -> IAgentCloudSyncStatus {
    await statusState.read()
  }

  public func start() async {
    await synchronize()
  }

  public func synchronize() async {
    await setStatus(.syncing)
    do {
      let accountStatus = try await CKContainer(identifier: containerIdentifier).accountStatus()
      guard accountStatus == .available else {
        await setStatus(.accountUnavailable, message: Self.accountMessage(for: accountStatus))
        return
      }

      await enqueueZoneIfNeeded()
      await enqueuePendingLocalChanges()
      try await engine.fetchChanges()
      await enqueuePendingLocalChanges()
      try await engine.sendChanges()
      try await store.markSyncSuccessful()
      await setStatus(.idle, lastSuccessfulSyncAt: Date())
    } catch {
      await setStatus(Self.phase(for: error), message: error.localizedDescription)
    }
  }

  public func pushLocalChanges() async {
    await setStatus(.syncing)
    do {
      await enqueueZoneIfNeeded()
      await enqueuePendingLocalChanges()
      try await engine.sendChanges()
      await setStatus(.idle, lastSuccessfulSyncAt: Date())
    } catch {
      await setStatus(Self.phase(for: error), message: error.localizedDescription)
    }
  }

  public func stop() async {
    await engine.cancelOperations()
  }

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    do {
      switch event {
      case let .stateUpdate(update):
        try Self.persist(update.stateSerialization, to: stateFileURL)

      case let .fetchedRecordZoneChanges(changes):
        try await applyFetchedChanges(changes, syncEngine: syncEngine)

      case let .sentRecordZoneChanges(changes):
        try await applySentChanges(changes, syncEngine: syncEngine)

      case let .sentDatabaseChanges(changes):
        if let failure = changes.failedZoneSaves.first {
          await setStatus(.failed, message: failure.error.localizedDescription)
        }

      case .didFetchChanges, .didSendChanges:
        try await store.markSyncSuccessful()
        await setStatus(.idle, lastSuccessfulSyncAt: Date())

      case let .accountChange(change):
        switch change.changeType {
        case .signIn:
          await setStatus(.idle)
        case .signOut, .switchAccounts:
          await setStatus(.accountUnavailable, message: "Sign in to iCloud to sync this device.")
        @unknown default:
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
    let names = await store.pendingRecordNames()
    let existing = Set(engine.state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
      switch change {
      case let .saveRecord(recordID), let .deleteRecord(recordID): recordID
      @unknown default: nil
      }
    })

    let changes = names.compactMap { name -> CKSyncEngine.PendingRecordZoneChange? in
      let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)
      guard !existing.contains(recordID) else { return nil }
      return .saveRecord(recordID)
    }
    if !changes.isEmpty {
      engine.state.add(pendingRecordZoneChanges: changes)
    }
  }

  private func recordToSave(for recordID: CKRecord.ID) async -> CKRecord? {
    guard let payload = await store.payload(for: recordID.recordName) else { return nil }

    do {
      let record: CKRecord
      if let fields = await store.cloudSystemFields(for: recordID.recordName),
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
    for modification in changes.modifications {
      let record = modification.record
      guard record.recordType == recordType,
            let payloadData = record.encryptedValues.object(forKey: "payload") as? Data
      else { continue }

      let payload = try JSONDecoder.iAgent.decode(IAgentSyncPayload.self, from: payloadData)
      let newPending = try await store.mergeRemote(
        payload,
        cloudSystemFields: Self.systemFields(for: record)
      )
      let pendingChanges = newPending.map {
        CKSyncEngine.PendingRecordZoneChange.saveRecord(
          CKRecord.ID(recordName: $0, zoneID: zoneID)
        )
      }
      if !pendingChanges.isEmpty {
        syncEngine.state.add(pendingRecordZoneChanges: pendingChanges)
      }
    }

    for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
      try await store.removeRemote(recordName: deletion.recordID.recordName)
    }
  }

  private func applySentChanges(
    _ changes: CKSyncEngine.Event.SentRecordZoneChanges,
    syncEngine: CKSyncEngine
  ) async throws {
    for record in changes.savedRecords where record.recordType == recordType {
      try await store.markSent(
        recordName: record.recordID.recordName,
        cloudSystemFields: Self.systemFields(for: record)
      )
    }

    for failure in changes.failedRecordSaves {
      if failure.error.code == .serverRecordChanged,
         let serverRecord = failure.error.serverRecord,
         let payloadData = serverRecord.encryptedValues.object(forKey: "payload") as? Data
      {
        let payload = try JSONDecoder.iAgent.decode(IAgentSyncPayload.self, from: payloadData)
        let newPending = try await store.mergeRemote(
          payload,
          cloudSystemFields: Self.systemFields(for: serverRecord)
        )
        let mergedNames = newPending.isEmpty ? [serverRecord.recordID.recordName] : newPending
        syncEngine.state.add(pendingRecordZoneChanges: mergedNames.map {
          .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID))
        })
      } else {
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
      }
      await setStatus(Self.phase(for: failure.error), message: failure.error.localizedDescription)
    }
  }

  private func setStatus(
    _ phase: IAgentCloudSyncPhase,
    lastSuccessfulSyncAt: Date? = nil,
    message: String? = nil
  ) async {
    await statusState.update(
      phase: phase,
      lastSuccessfulSyncAt: lastSuccessfulSyncAt,
      message: message
    )
    NotificationCenter.default.post(name: .iAgentSyncStatusDidChange, object: nil)
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

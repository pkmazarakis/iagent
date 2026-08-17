import Foundation
import XCTest
@testable import iAgentActionContracts
@testable import iAgentActions
@testable import iAgentCore

final class SyncCoreTests: XCTestCase {
  func testConcurrentTodoEditsConvergeAndClearPendingChanges() async throws {
    let root = temporaryDirectory(named: "todo-convergence")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeA = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("a.json"))
    let storeB = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("b.json"))
    let id = try XCTUnwrap(UUID(uuidString: "26EB27D3-8E71-4D37-B43A-47C928E3876B"))
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let editedAt = createdAt.addingTimeInterval(60)
    let base = SyncedTodo(
      id: id,
      title: "Prepare launch",
      isCompleted: false,
      createdAt: createdAt,
      updatedAt: createdAt
    )

    try await storeA.mergeRemote(.todo(base), cloudSystemFields: nil)
    try await storeB.mergeRemote(.todo(base), cloudSystemFields: nil)

    var editA = base
    editA.title = "Prepare production launch"
    editA.updatedAt = editedAt
    var editB = base
    editB.isCompleted = true
    editB.completedAt = editedAt
    editB.updatedAt = editedAt
    try await storeA.upsertLocal(.todo(editA))
    try await storeB.upsertLocal(.todo(editB))

    let outboundAValue = await storeA.payload(for: IAgentSyncPayload.todo(base).recordName)
    let outboundBValue = await storeB.payload(for: IAgentSyncPayload.todo(base).recordName)
    let outboundA = try XCTUnwrap(outboundAValue)
    let outboundB = try XCTUnwrap(outboundBValue)
    try await storeA.mergeRemote(outboundB, cloudSystemFields: nil)
    try await storeB.mergeRemote(outboundA, cloudSystemFields: nil)

    let mergedAValue = await storeA.payload(for: outboundA.recordName)
    let mergedBValue = await storeB.payload(for: outboundB.recordName)
    let mergedA = try XCTUnwrap(mergedAValue)
    let mergedB = try XCTUnwrap(mergedBValue)
    XCTAssertEqual(mergedA, mergedB)
    guard case let .todo(convergedTodo) = mergedA else {
      return XCTFail("Expected a todo payload")
    }
    XCTAssertEqual(convergedTodo.title, "Prepare production launch")
    XCTAssertTrue(convergedTodo.isCompleted)
    XCTAssertEqual(convergedTodo.completedAt, editedAt)

    try await storeA.mergeRemote(mergedB, cloudSystemFields: nil)
    try await storeB.mergeRemote(mergedA, cloudSystemFields: nil)
    let pendingA = await storeA.pendingRecordNames()
    let pendingB = await storeB.pendingRecordNames()
    XCTAssertEqual(pendingA, [])
    XCTAssertEqual(pendingB, [])
  }

  func testConcurrentNoteConflictProducesTheSamePrimaryAndConflictCopy() async throws {
    let root = temporaryDirectory(named: "note-convergence")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeA = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("a.json"))
    let storeB = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("b.json"))
    let noteID = try XCTUnwrap(UUID(uuidString: "10F6F28F-E988-4B6E-A99B-D12D4B3ACD12"))
    let createdAt = Date(timeIntervalSince1970: 1_700_100_000)
    let editedAt = createdAt.addingTimeInterval(90)
    let base = SyncedNote(
      id: noteID,
      title: "Roadmap",
      body: "Initial outline",
      createdAt: createdAt,
      updatedAt: createdAt,
      sourceDeviceID: "desktop"
    )
    try await storeA.mergeRemote(.note(base), cloudSystemFields: nil)
    try await storeB.mergeRemote(.note(base), cloudSystemFields: nil)

    var editA = base
    editA.body = "Desktop revision"
    editA.updatedAt = editedAt
    editA.sourceDeviceID = "desktop"
    var editB = base
    editB.body = "Mobile revision"
    editB.updatedAt = editedAt
    editB.sourceDeviceID = "mobile"
    try await storeA.upsertLocal(.note(editA))
    try await storeB.upsertLocal(.note(editB))

    let outboundAValue = await storeA.payload(for: IAgentSyncPayload.note(base).recordName)
    let outboundBValue = await storeB.payload(for: IAgentSyncPayload.note(base).recordName)
    let outboundA = try XCTUnwrap(outboundAValue)
    let outboundB = try XCTUnwrap(outboundBValue)
    try await storeA.mergeRemote(outboundB, cloudSystemFields: nil)
    try await storeB.mergeRemote(outboundA, cloudSystemFields: nil)

    let allRecordsA = await storeA.allPayloads()
    let allRecordsB = await storeB.allPayloads()
    let recordsA = allRecordsA.sorted { $0.recordName < $1.recordName }
    let recordsB = allRecordsB.sorted { $0.recordName < $1.recordName }
    XCTAssertEqual(recordsA, recordsB)
    XCTAssertEqual(recordsA.count, 2)
    XCTAssertEqual(Set(recordsA.map(\.recordName)).count, 2)
  }

  func testCorruptLocalRecordDoesNotDiscardValidRecords() async throws {
    let root = temporaryDirectory(named: "lossy-local-decode")
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("sync-store.json")
    let originalStore = IAgentLocalSyncStore(fileURL: fileURL)
    let valid = SyncedTodo(
      id: try XCTUnwrap(UUID(uuidString: "330525D9-DC21-4223-BB65-C13ED21E50F1")),
      title: "Keep this",
      createdAt: Date(timeIntervalSince1970: 1_700_200_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
    )
    let malformed = SyncedTodo(
      id: try XCTUnwrap(UUID(uuidString: "7860312A-9D37-4D6F-9D47-0B0217268711")),
      title: "Corrupt this",
      createdAt: Date(timeIntervalSince1970: 1_700_200_100),
      updatedAt: Date(timeIntervalSince1970: 1_700_200_100)
    )
    try await originalStore.upsertLocal([.todo(valid), .todo(malformed)])

    let encoded = try Data(contentsOf: fileURL)
    var rootObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var records = try XCTUnwrap(rootObject["records"] as? [String: Any])
    let malformedName = IAgentSyncPayload.todo(malformed).recordName
    records[malformedName] = ["invalid": true]
    rootObject["records"] = records
    let corrupted = try JSONSerialization.data(withJSONObject: rootObject, options: [.sortedKeys])
    try corrupted.write(to: fileURL, options: .atomic)

    let recoveredStore = IAgentLocalSyncStore(fileURL: fileURL)
    let snapshot = await recoveredStore.snapshot()
    let diagnostics = await recoveredStore.diagnostics()
    XCTAssertEqual(snapshot.todos.map(\.id), [valid.id])
    XCTAssertEqual(snapshot.pendingRecordNames, [IAgentSyncPayload.todo(valid).recordName])
    XCTAssertEqual(diagnostics.malformedRecordNames, [malformedName])
  }

  func testFixtureMigrationOnlyDiscardsUntrackedRecords() async throws {
    let root = temporaryDirectory(named: "fixture-migration")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let fixture = SyncedTodo(title: "Fixture")
    let pending = SyncedTodo(title: "Pending user todo")
    let cloudBacked = SyncedTodo(title: "Cloud-backed todo")
    try await store.replaceForTesting(with: [.todo(fixture)])
    try await store.upsertLocal(.todo(pending))
    try await store.mergeRemote(.todo(cloudBacked), cloudSystemFields: nil)

    let candidates = Set([fixture, pending, cloudBacked].map {
      IAgentSyncPayload.todo($0).recordName
    })
    let discarded = try await store.discardUntrackedLocalRecords(named: candidates)

    XCTAssertEqual(discarded, [IAgentSyncPayload.todo(fixture).recordName])
    let remainingPayloads = await store.allPayloads()
    let remaining = Set(remainingPayloads.map(\.recordName))
    XCTAssertEqual(remaining, Set([
      IAgentSyncPayload.todo(pending).recordName,
      IAgentSyncPayload.todo(cloudBacked).recordName
    ]))
    let diagnostics = await store.diagnostics()
    XCTAssertEqual(diagnostics.pendingRecordCount, 1)
    XCTAssertNil(diagnostics.lastSuccessfulSyncAt)
  }

  func testPhysicalRemoteDeletionDoesNotDiscardAnUnsentLocalEdit() async throws {
    let root = temporaryDirectory(named: "remote-deletion-conflict")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let createdAt = Date(timeIntervalSince1970: 1_700_250_000)
    var todo = SyncedTodo(
      title: "Original",
      createdAt: createdAt,
      updatedAt: createdAt
    )
    try await store.mergeRemote(.todo(todo), cloudSystemFields: Data([1, 2, 3]))
    todo.title = "Local edit"
    todo.updatedAt = createdAt.addingTimeInterval(10)
    let payload = IAgentSyncPayload.todo(todo)
    try await store.upsertLocal(payload)

    try await store.removeRemote(recordName: payload.recordName)

    let retained = await store.payload(for: payload.recordName)
    let pendingNames = await store.pendingRecordNames()
    let systemFields = await store.cloudSystemFields(for: payload.recordName)
    XCTAssertEqual(retained, payload)
    XCTAssertEqual(pendingNames, [payload.recordName])
    XCTAssertNil(systemFields)
  }

  func testDiagnosticsReportCountsPendingAgeAndLastSuccess() async throws {
    let root = temporaryDirectory(named: "diagnostics")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let oldestDate = Date(timeIntervalSince1970: 1_700_300_000)
    let sentDate = oldestDate.addingTimeInterval(300)
    let pending = SyncedTodo(title: "Pending", createdAt: oldestDate, updatedAt: oldestDate)
    let tombstone = IAgentSyncPayload.note(SyncedNote(
      title: "Deleted",
      body: "",
      createdAt: oldestDate,
      updatedAt: oldestDate,
      sourceDeviceID: "test"
    )).deleting(at: oldestDate)
    try await store.upsertLocal([.todo(pending), tombstone])

    var diagnostics = await store.diagnostics()
    XCTAssertEqual(diagnostics.totalRecordCount, 2)
    XCTAssertEqual(diagnostics.activeRecordCount, 1)
    XCTAssertEqual(diagnostics.tombstoneRecordCount, 1)
    XCTAssertEqual(diagnostics.activeRecordCountsByKind, [.todo: 1])
    XCTAssertEqual(diagnostics.pendingRecordCount, 2)
    XCTAssertEqual(diagnostics.oldestPendingRecordUpdatedAt, oldestDate)

    try await store.markSent(
      recordName: IAgentSyncPayload.todo(pending).recordName,
      sentPayload: .todo(pending),
      cloudSystemFields: nil,
      at: sentDate
    )
    diagnostics = await store.diagnostics()
    XCTAssertEqual(diagnostics.pendingRecordCount, 1)
    XCTAssertEqual(diagnostics.lastSuccessfulSyncAt, sentDate)
  }

  func testCloudPayloadBatchDecoderContinuesAfterMalformedAndMismatchedRecords() throws {
    let todo = SyncedTodo(
      id: try XCTUnwrap(UUID(uuidString: "0D53CB53-2EFF-4423-A293-AB115757DB02")),
      title: "Decode me",
      createdAt: Date(timeIntervalSince1970: 1_700_400_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_400_000)
    )
    let payload = IAgentSyncPayload.todo(todo)
    let data = try JSONEncoder.iAgent.encode(payload)
    let result = IAgentSyncPayloadBatchDecoder.decode([
      IAgentSyncPayloadDecodeCandidate(recordName: "todo_malformed", data: Data("not-json".utf8)),
      IAgentSyncPayloadDecodeCandidate(recordName: payload.recordName, data: data),
      IAgentSyncPayloadDecodeCandidate(recordName: "todo_wrong-identity", data: data)
    ])

    XCTAssertEqual(result.decoded, [IAgentDecodedSyncPayload(
      recordName: payload.recordName,
      payload: payload
    )])
    XCTAssertEqual(result.failures.map(\.recordName), ["todo_malformed", "todo_wrong-identity"])
  }

  func testMarkSentKeepsNewerLocalEditPendingWhenOlderPayloadFinishesSaving() async throws {
    let root = temporaryDirectory(named: "mark-sent-race")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let createdAt = Date(timeIntervalSince1970: 1_700_500_000)
    var todo = SyncedTodo(
      title: "Original title",
      createdAt: createdAt,
      updatedAt: createdAt
    )
    let payloadThatStartedSaving = IAgentSyncPayload.todo(todo)
    try await store.upsertLocal(payloadThatStartedSaving)

    todo.title = "Edited while CloudKit was saving"
    todo.updatedAt = createdAt.addingTimeInterval(1)
    let newerPayload = IAgentSyncPayload.todo(todo)
    try await store.upsertLocal(newerPayload)

    try await store.markSent(
      recordName: payloadThatStartedSaving.recordName,
      sentPayload: payloadThatStartedSaving,
      cloudSystemFields: Data([4, 5, 6])
    )

    var retainedPayload = await store.payload(for: newerPayload.recordName)
    var pendingNames = await store.pendingRecordNames()
    XCTAssertEqual(retainedPayload, newerPayload)
    XCTAssertEqual(pendingNames, [newerPayload.recordName])

    try await store.mergeRemote(payloadThatStartedSaving, cloudSystemFields: Data([4, 5, 6]))
    retainedPayload = await store.payload(for: newerPayload.recordName)
    pendingNames = await store.pendingRecordNames()
    XCTAssertEqual(retainedPayload, newerPayload)
    XCTAssertEqual(pendingNames, [newerPayload.recordName])

    try await store.markSent(
      recordName: newerPayload.recordName,
      sentPayload: newerPayload,
      cloudSystemFields: Data([7, 8, 9])
    )
    pendingNames = await store.pendingRecordNames()
    XCTAssertEqual(pendingNames, [])
  }

  func testMarkSentClearsPendingAfterCanonicalDateNormalization() async throws {
    let directory = temporaryDirectory(named: "canonical-ack")
    let store = IAgentLocalSyncStore(
      fileURL: directory.appendingPathComponent("sync-store.json")
    )
    let preciseDate = Date(timeIntervalSince1970: 1_750_000_000.123_456)
    let local = IAgentSyncPayload.note(
      SyncedNote(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000099")!,
        title: "Canonical acknowledgement",
        body: "The content did not change.",
        createdAt: preciseDate,
        updatedAt: preciseDate,
        sourceDeviceID: "mac"
      )
    )
    _ = try await store.upsertLocal(local)

    let uploadedData = try JSONEncoder.iAgent.encode(local)
    let acknowledged = try JSONDecoder.iAgent.decode(
      IAgentSyncPayload.self,
      from: uploadedData
    )
    try await store.markSent(
      recordName: local.recordName,
      sentPayload: acknowledged,
      cloudSystemFields: Data("system-fields".utf8)
    )

    let diagnostics = await store.diagnostics()
    let storedPayload = await store.payload(for: local.recordName)
    XCTAssertEqual(diagnostics.pendingRecordCount, 0)
    XCTAssertEqual(storedPayload, acknowledged)
  }

  func testCanonicalOnlyRestagingDoesNotRequeueAcknowledgedPayload() async throws {
    let directory = temporaryDirectory(named: "canonical-restage")
    let store = IAgentLocalSyncStore(
      fileURL: directory.appendingPathComponent("sync-store.json")
    )
    let preciseDate = Date(timeIntervalSince1970: 1_750_000_000.654_321)
    let local = IAgentSyncPayload.codexThread(
      SyncedCodexThread(
        id: "thread-canonical-restage",
        projectName: "iAgent",
        title: "Stable thread",
        activity: "Waiting",
        state: .running,
        modes: [.plan],
        createdAt: preciseDate,
        updatedAt: preciseDate
      )
    )
    _ = try await store.upsertLocal(local)
    let uploadedData = try JSONEncoder.iAgent.encode(local)
    let acknowledged = try JSONDecoder.iAgent.decode(
      IAgentSyncPayload.self,
      from: uploadedData
    )
    try await store.markSent(
      recordName: local.recordName,
      sentPayload: acknowledged,
      cloudSystemFields: Data("system-fields".utf8)
    )

    _ = try await store.upsertLocal(local)

    let diagnostics = await store.diagnostics()
    let storedPayload = await store.payload(for: local.recordName)
    XCTAssertEqual(diagnostics.pendingRecordCount, 0)
    XCTAssertEqual(storedPayload, acknowledged)
  }

  func testCloudAccountSwitchQuarantinesOldDataAndRejectsStaleCallbacks() async throws {
    let root = temporaryDirectory(named: "account-switch")
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("sync-store.json")
    let initialStore = IAgentLocalSyncStore(fileURL: fileURL)
    let oldTodo = SyncedTodo(title: "Private account A todo")
    let oldPayload = IAgentSyncPayload.todo(oldTodo)
    try await initialStore.upsertLocal(oldPayload)
    let initialBinding = try await initialStore.bind(toCloudAccount: "account-a")
    XCTAssertEqual(initialBinding, .boundExistingState)

    let store = IAgentLocalSyncStore(fileURL: fileURL)
    let transition = try await store.bind(toCloudAccount: "account-b")
    guard case let .switchedAccounts(quarantineURL) = transition else {
      return XCTFail("Expected the previous account store to be quarantined")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
    let quarantinedText = String(decoding: try Data(contentsOf: quarantineURL), as: UTF8.self)
    XCTAssertTrue(quarantinedText.contains("Private account A todo"))
    var snapshot = await store.snapshot()
    var pendingNames = try await store.pendingRecordNames(forCloudAccount: "account-b")
    XCTAssertEqual(snapshot, IAgentDataSnapshot())
    XCTAssertEqual(pendingNames, [])

    do {
      _ = try await store.mergeRemote(
        oldPayload,
        cloudSystemFields: nil,
        cloudAccountFingerprint: "account-a"
      )
      XCTFail("A stale callback from account A must not mutate account B's store")
    } catch let error as IAgentLocalSyncStoreError {
      guard case .cloudAccountMismatch = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    snapshot = await store.snapshot()
    XCTAssertEqual(snapshot, IAgentDataSnapshot())

    let accountBTodo = IAgentSyncPayload.todo(SyncedTodo(title: "Account B todo"))
    try await store.upsertLocal(accountBTodo)
    let signOutQuarantine = try await store.quarantineForCloudAccountSignOut()
    XCTAssertNotNil(signOutQuarantine)
    snapshot = await store.snapshot()
    pendingNames = await store.pendingRecordNames()
    XCTAssertEqual(snapshot, IAgentDataSnapshot())
    XCTAssertEqual(pendingNames, [])

    let restoredBinding = try await store.bind(toCloudAccount: "account-b")
    XCTAssertEqual(restoredBinding, .restoredAccountState)
    snapshot = await store.snapshot()
    pendingNames = await store.pendingRecordNames()
    XCTAssertEqual(snapshot.todos.map(\.title), ["Account B todo"])
    XCTAssertEqual(pendingNames, [accountBTodo.recordName])
  }

  func testCorruptRawStoreIsPreservedBeforeLossyStateCanBePersisted() async throws {
    let root = temporaryDirectory(named: "corrupt-store-quarantine")
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("sync-store.json")
    let seedStore = IAgentLocalSyncStore(fileURL: fileURL)
    let validPayload = IAgentSyncPayload.todo(SyncedTodo(title: "Valid record"))
    let corruptPayload = IAgentSyncPayload.todo(SyncedTodo(title: "Corrupt record"))
    try await seedStore.upsertLocal([validPayload, corruptPayload])

    var rootObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    var records = try XCTUnwrap(rootObject["records"] as? [String: Any])
    records[corruptPayload.recordName] = ["invalid": true]
    rootObject["records"] = records
    let corruptRawData = try JSONSerialization.data(withJSONObject: rootObject, options: [.sortedKeys])
    try corruptRawData.write(to: fileURL, options: .atomic)

    let recoveredStore = IAgentLocalSyncStore(fileURL: fileURL)
    let possibleQuarantineURL = await recoveredStore.quarantinedCorruptStoreURL()
    let quarantineURL = try XCTUnwrap(possibleQuarantineURL)
    XCTAssertEqual(try Data(contentsOf: quarantineURL), corruptRawData)

    try await recoveredStore.upsertLocal(.todo(SyncedTodo(title: "New valid record")))
    XCTAssertEqual(try Data(contentsOf: quarantineURL), corruptRawData)
    let reloadedStore = IAgentLocalSyncStore(fileURL: fileURL)
    let malformedRecordNames = await reloadedStore.diagnostics().malformedRecordNames
    XCTAssertEqual(malformedRecordNames, [corruptPayload.recordName])
  }

  func testFirstAccountBindingQuarantinesUnboundStoreWithCloudHistory() async throws {
    let root = temporaryDirectory(named: "legacy-unbound-account")
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("sync-store.json")
    let legacyStore = IAgentLocalSyncStore(fileURL: fileURL)
    let oldCloudPayload = IAgentSyncPayload.todo(SyncedTodo(title: "Old account cloud data"))
    try await legacyStore.mergeRemote(
      oldCloudPayload,
      cloudSystemFields: Data([1, 2, 3])
    )

    let relaunchedStore = IAgentLocalSyncStore(fileURL: fileURL)
    let transition = try await relaunchedStore.bind(toCloudAccount: "new-account")
    guard case let .quarantinedUnboundCloudState(quarantineURL) = transition else {
      return XCTFail("Legacy cloud-derived data must not be assigned to an unverified account")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
    let snapshot = await relaunchedStore.snapshot()
    let pendingNames = try await relaunchedStore.pendingRecordNames(
      forCloudAccount: "new-account"
    )
    XCTAssertEqual(snapshot, IAgentDataSnapshot())
    XCTAssertEqual(pendingNames, [])
  }

  func testSingleFlightRerunsAndUpgradesPendingSyncIntent() async {
    let coordinator = IAgentCloudSyncSingleFlight()
    let probe = SyncIntentProbe()

    let first = Task {
      await coordinator.run(fetchesRemoteChanges: false) { shouldFetch in
        await probe.perform(shouldFetch: shouldFetch)
      }
    }
    await probe.waitUntilStarted(count: 1)

    let second = Task {
      await coordinator.run(fetchesRemoteChanges: true) { shouldFetch in
        await probe.perform(shouldFetch: shouldFetch)
      }
    }
    await probe.waitUntilIntentWasQueued(coordinator: coordinator)
    await probe.releaseNext()
    await probe.waitUntilStarted(count: 2)
    await probe.releaseNext()

    await first.value
    await second.value
    let fetchIntents = await probe.fetchIntents()
    let maximumConcurrentOperations = await probe.maximumConcurrentOperations()
    XCTAssertEqual(fetchIntents, [false, true])
    XCTAssertEqual(maximumConcurrentOperations, 1)
  }

  func testCascadingNoteDeletionTombstonesOnlyLinkedActiveMeetings() {
    let note = SyncedNote(title: "Recorded call", body: "Notes", sourceDeviceID: "iphone")
    let linked = SyncedMeetingSession(
      noteID: note.id,
      title: note.title,
      sourceDeviceID: "iphone",
      state: .completed
    )
    let unrelated = SyncedMeetingSession(
      noteID: UUID(),
      title: "Other call",
      sourceDeviceID: "iphone",
      state: .completed
    )
    let alreadyDeleted = SyncedMeetingSession(
      id: UUID(),
      noteID: note.id,
      title: note.title,
      sourceDeviceID: "iphone",
      state: .completed,
      deletedAt: Date(timeIntervalSince1970: 10)
    )
    let deletionDate = Date(timeIntervalSince1970: 20)

    let tombstones = IAgentSyncPayload.cascadingNoteDeletion(
      note: note,
      linkedMeetings: [linked, unrelated, alreadyDeleted],
      at: deletionDate
    )

    XCTAssertEqual(tombstones.count, 2)
    XCTAssertEqual(tombstones.first?.deletedAt, deletionDate)
    let meetingPayload = tombstones.last
    XCTAssertEqual(meetingPayload?.recordName, IAgentSyncPayload.meetingSession(linked).recordName)
    XCTAssertEqual(meetingPayload?.deletedAt, deletionDate)
  }

  func testLegacyReplicaResetArchivesStateBeforeRemovingChangeToken() throws {
    let root = temporaryDirectory(named: "legacy-state-reset")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let storeURL = root.appendingPathComponent("sync-store.json")
    let cloudStateURL = root.appendingPathComponent("cloud-state.json")
    let storeData = Data("store-sentinel".utf8)
    let stateData = Data("state-sentinel".utf8)
    try storeData.write(to: storeURL)
    try stateData.write(to: cloudStateURL)

    let quarantine = try IAgentLegacySyncStateQuarantine.archiveReplicaAndResetCloudState(
      storeURL: storeURL,
      cloudStateURL: cloudStateURL
    )

    XCTAssertEqual(try Data(contentsOf: storeURL), storeData)
    XCTAssertFalse(FileManager.default.fileExists(atPath: cloudStateURL.path))
    XCTAssertEqual(
      try Data(contentsOf: quarantine.appendingPathComponent("sync-store.json")),
      storeData
    )
    XCTAssertEqual(
      try Data(contentsOf: quarantine.appendingPathComponent("cloud-state.json")),
      stateData
    )
  }

  func testDesktopSnapshotMergeKeepsNewestContentAndNewestHeartbeat() async throws {
    let root = temporaryDirectory(named: "desktop-snapshot-merge")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let contentDate = Date(timeIntervalSince1970: 300)
    let local = SyncedDesktopSnapshot(
      id: "desktop",
      deviceName: "Mac",
      activeCodexCount: 4,
      openTodoCount: 2,
      projectOrder: ["new-content"],
      generatedAt: contentDate,
      lastSeenAt: Date(timeIntervalSince1970: 310),
      appVersion: "0.1"
    )
    let remote = SyncedDesktopSnapshot(
      id: "desktop",
      deviceName: "Mac",
      activeCodexCount: 1,
      openTodoCount: 9,
      projectOrder: ["stale-content"],
      generatedAt: Date(timeIntervalSince1970: 200),
      lastSeenAt: Date(timeIntervalSince1970: 400),
      appVersion: "0.1"
    )

    try await store.upsertLocal(.desktopSnapshot(local))
    _ = try await store.mergeRemote(.desktopSnapshot(remote), cloudSystemFields: nil)
    let snapshot = await store.snapshot()
    let merged = try XCTUnwrap(snapshot.desktopSnapshot)

    XCTAssertEqual(merged.generatedAt, contentDate)
    XCTAssertEqual(merged.activeCodexCount, 4)
    XCTAssertEqual(merged.projectOrder, ["new-content"])
    XCTAssertEqual(merged.lastSeenAt, Date(timeIntervalSince1970: 400))
  }

  func testFailedLocalUpsertsDoNotPublishUnpersistedState() async throws {
    let root = temporaryDirectory(named: "failed-local-upsert")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blockedParent = root.appendingPathComponent("not-a-directory")
    try Data("occupied".utf8).write(to: blockedParent)
    let store = IAgentLocalSyncStore(
      fileURL: blockedParent.appendingPathComponent("sync-store.json")
    )
    let todo = SyncedTodo(title: "Must remain absent")
    let note = SyncedNote(
      title: "Also absent",
      body: "This batch must roll back too.",
      sourceDeviceID: "tests"
    )

    do {
      try await store.upsertLocal(.todo(todo))
      XCTFail("Writing through a non-directory parent should fail.")
    } catch {
      // Expected: a failed durable write must not leak the attempted mutation through actor memory.
    }

    let snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.todos.isEmpty)
    XCTAssertTrue(snapshot.pendingRecordNames.isEmpty)
    let payload = await store.payload(for: IAgentSyncPayload.todo(todo).recordName)
    XCTAssertNil(payload)

    do {
      try await store.upsertLocal([.todo(todo), .note(note)])
      XCTFail("A failed batch write should not publish any member of the batch.")
    } catch {
      // Expected: batch mutation is atomic with respect to both disk and actor-visible state.
    }

    let batchSnapshot = await store.snapshot()
    XCTAssertTrue(batchSnapshot.todos.isEmpty)
    XCTAssertTrue(batchSnapshot.notes.isEmpty)
    XCTAssertTrue(batchSnapshot.pendingRecordNames.isEmpty)
  }

  func testActionTodoInsertFailsAtomicallyWhenReviewedListWasDeletedOrRenamed() async throws {
    let root = temporaryDirectory(named: "action-todo-target")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let list = SyncedTodoList(name: "Work", order: 0)
    try await store.upsertLocal(.todoList(list))
    let actionTodo = SyncedTodo(title: "Review launch", listName: "Work")

    var renamed = list
    renamed.name = "Archive"
    renamed.updatedAt = list.updatedAt.addingTimeInterval(1)
    try await store.upsertLocal(.todoList(renamed))

    do {
      let identity = actionExecutionIdentity(label: "renamed-list")
      _ = try await store.upsertActionTodo(
        actionTodo,
        expectedListName: "Work",
        identity: identity,
        authorization: actionExecutionAuthorization(for: identity)
      )
      XCTFail("A renamed list must not receive the reviewed action to-do.")
    } catch {
      guard case let IAgentLocalSyncStoreError.actionTargetChanged(detail) = error else {
        return XCTFail("Expected stale action target, got \(error)")
      }
      XCTAssertTrue(detail.contains("no longer exists"))
    }
    var snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.todos.isEmpty)

    var deleted = renamed
    deleted.name = "Work"
    deleted.deletedAt = renamed.updatedAt.addingTimeInterval(1)
    deleted.updatedAt = deleted.deletedAt!
    try await store.upsertLocal(.todoList(deleted))

    do {
      let identity = actionExecutionIdentity(label: "deleted-list")
      _ = try await store.upsertActionTodo(
        actionTodo,
        expectedListName: "Work",
        identity: identity,
        authorization: actionExecutionAuthorization(for: identity)
      )
      XCTFail("A deleted list must not receive the reviewed action to-do.")
    } catch {
      guard case IAgentLocalSyncStoreError.actionTargetChanged = error else {
        return XCTFail("Expected deleted-list rejection, got \(error)")
      }
    }
    snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.todos.isEmpty)
  }

  func testActionTodoExactReplaySurvivesListRenameAfterDurableInsert() async throws {
    let root = temporaryDirectory(named: "action-todo-replay-after-rename")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    var list = SyncedTodoList(name: "Work", order: 0)
    try await store.upsertLocal(.todoList(list))
    let actionTodo = SyncedTodo(title: "Review launch", listName: "Work")
    let identity = actionExecutionIdentity(label: "todo-replay")
    _ = try await store.upsertActionTodo(
      actionTodo,
      expectedListName: "Work",
      identity: identity,
      authorization: actionExecutionAuthorization(for: identity)
    )

    list.name = "Archive"
    list.updatedAt = list.updatedAt.addingTimeInterval(1)
    try await store.upsertLocal(.todoList(list))

    _ = try await store.upsertActionTodo(
      actionTodo,
      expectedListName: "Work",
      identity: identity,
      authorization: actionExecutionAuthorization(for: identity)
    )
    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.todos, [actionTodo])
  }

  func testActionTodoInsertRollsBackWhenPersistenceFails() async throws {
    let root = temporaryDirectory(named: "action-todo-persistence")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blockedParent = root.appendingPathComponent("not-a-directory")
    try Data("occupied".utf8).write(to: blockedParent)
    let store = IAgentLocalSyncStore(
      fileURL: blockedParent.appendingPathComponent("sync-store.json")
    )
    let todo = SyncedTodo(title: "Must remain absent")

    do {
      let identity = actionExecutionIdentity(label: "todo-persistence")
      _ = try await store.upsertActionTodo(
        todo,
        expectedListName: nil,
        identity: identity,
        authorization: actionExecutionAuthorization(for: identity)
      )
      XCTFail("The action to-do write should fail through a non-directory parent.")
    } catch {
      // Expected: actor-visible state rolls back with the failed durable write.
    }

    let snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.todos.isEmpty)
    XCTAssertTrue(snapshot.pendingRecordNames.isEmpty)
  }

  func testActionNoteInsertIsIdempotentAndRejectsAChangedDeterministicSlot() async throws {
    let root = temporaryDirectory(named: "action-note-slot")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let identifier = try XCTUnwrap(
      UUID(uuidString: "9463BD53-372C-4016-898A-647EC585E7E5")
    )
    let reviewed = SyncedNote(
      id: identifier,
      title: "Bull case",
      body: "Reviewed body",
      sourceDeviceID: "actions"
    )

    let firstIdentity = actionExecutionIdentity(label: "note-first")
    _ = try await store.upsertActionNote(
      reviewed,
      identity: firstIdentity,
      authorization: actionExecutionAuthorization(for: firstIdentity)
    )
    let replayIdentity = actionExecutionIdentity(label: "note-replay")
    _ = try await store.upsertActionNote(
      reviewed,
      identity: replayIdentity,
      authorization: actionExecutionAuthorization(for: replayIdentity)
    )
    var snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.notes, [reviewed])

    var changed = reviewed
    changed.body = "Changed after action revalidation"
    changed.updatedAt = reviewed.updatedAt.addingTimeInterval(1)
    try await store.upsertLocal(.note(changed))

    do {
      let conflictIdentity = actionExecutionIdentity(label: "note-conflict")
      _ = try await store.upsertActionNote(
        reviewed,
        identity: conflictIdentity,
        authorization: actionExecutionAuthorization(for: conflictIdentity)
      )
      XCTFail("A changed deterministic note slot must not be overwritten.")
    } catch {
      guard case IAgentLocalSyncStoreError.actionIdempotencyConflict = error else {
        return XCTFail("Expected an idempotency conflict, got \(error)")
      }
    }
    snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.notes, [changed])
  }

  func testActionNoteExecutorFailsClosedWhenSlotChangesAfterRevalidation() async throws {
    let root = temporaryDirectory(named: "action-note-executor-race")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let executor = LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "actions")
    let createdAt = Date(timeIntervalSince1970: 1_786_370_000)
    let digest = String(repeating: "a", count: 64)
    let identifier = try XCTUnwrap(
      UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    )
    let payload = CreateNoteActionPayload(title: "Reviewed title", body: "Reviewed body")
    let intent = AssistantActionIntent(
      id: "intent-action-note-race",
      proposalDigest: digest,
      capability: .createNote,
      scope: AssistantActionScope(id: "notes:local", displayName: "Notes"),
      payload: .createNote(payload),
      review: AssistantActionReviewCard(
        title: "Create note",
        explanation: "Review this note.",
        primaryVerb: "Create note",
        fields: [],
        canonicalPayloadJSON: "{}",
        requiresNativeHandoff: false
      ),
      provenance: AssistantActionProvenance(
        conversationID: "conversation",
        turnID: "turn",
        currentUserMessageID: "message",
        toolCallID: "tool-call"
      ),
      createdAt: createdAt,
      expiresAt: createdAt.addingTimeInterval(300)
    )

    try await executor.revalidate(intent)
    let intervening = SyncedNote(
      id: identifier,
      title: "Intervening edit",
      body: "Must not be overwritten.",
      createdAt: createdAt,
      updatedAt: createdAt.addingTimeInterval(1),
      sourceDeviceID: "user"
    )
    try await store.upsertLocal(.note(intervening))

    do {
      _ = try await executor.execute(
        intent,
        authorization: actionExecutionAuthorization(for: intent)
      )
      XCTFail("The executor must reject a deterministic slot changed after revalidation.")
    } catch {
      guard case AssistantActionBrokerError.staleTarget = error else {
        return XCTFail("Expected a stale-target broker error, got \(error)")
      }
    }
    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.notes, [intervening])
  }

  func testActionNoteInsertRollsBackWhenPersistenceFails() async throws {
    let root = temporaryDirectory(named: "action-note-persistence")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blockedParent = root.appendingPathComponent("not-a-directory")
    try Data("occupied".utf8).write(to: blockedParent)
    let store = IAgentLocalSyncStore(
      fileURL: blockedParent.appendingPathComponent("sync-store.json")
    )
    let note = SyncedNote(
      title: "Must remain absent",
      body: "The durable write fails.",
      sourceDeviceID: "actions"
    )

    do {
      let identity = actionExecutionIdentity(label: "note-persistence")
      _ = try await store.upsertActionNote(
        note,
        identity: identity,
        authorization: actionExecutionAuthorization(for: identity)
      )
      XCTFail("The action note write should fail through a non-directory parent.")
    } catch {
      // Expected: actor-visible state rolls back with the failed durable write.
    }

    let snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.notes.isEmpty)
    XCTAssertTrue(snapshot.pendingRecordNames.isEmpty)
  }

  func testActionNoteExecutorDoesNotMutateAfterForegroundAuthorizationRevoked() async throws {
    let root = temporaryDirectory(named: "action-note-foreground-revocation")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let executor = LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "actions")
    let intent = actionNoteIntent(label: "foreground-revocation")
    let gate = TestActionForegroundGate(active: true)
    let authority = gate.authority()
    let capability = FixedAssistantActionCapabilityProvider(policy: .allPreparationEnabled)
    let authorization = actionExecutionAuthorization(
      for: intent,
      foregroundAuthority: authority,
      foregroundGeneration: authority.currentGeneration(),
      capabilityGeneration: capability.preparationAuthorizationGeneration(),
      withCapabilityAuthorization: { expectedGeneration, operation in
        try capability.withPreparationAuthorization(
          expectedGeneration: expectedGeneration,
          capability: intent.capability,
          scopeID: intent.scope.id,
          operation: operation
        )
      }
    )

    // Model the app entering the background during the final executor actor hop. The token was
    // minted while active, but its generation must fail immediately at the store mutation edge.
    gate.update(false)

    do {
      _ = try await executor.execute(intent, authorization: authorization)
      XCTFail("A foreground authorization revoked before mutation must fail closed.")
    } catch {
      XCTAssertEqual(error as? AssistantActionBrokerError, .appNotForeground)
    }
    let snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.notes.isEmpty)
    XCTAssertTrue(snapshot.pendingRecordNames.isEmpty)
  }

  func testActionNoteExecutorDoesNotMutateAfterCapabilityAuthorizationRevoked() async throws {
    let root = temporaryDirectory(named: "action-note-capability-revocation")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let executor = LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "actions")
    let intent = actionNoteIntent(label: "capability-revocation")
    let capability = AssistantActionCapabilityStore(
      fileURL: root.appendingPathComponent("assistant-action-capabilities.json")
    )
    let foregroundGate = TestActionForegroundGate(active: true)
    let foreground = foregroundGate.authority()
    let authorization = actionExecutionAuthorization(
      for: intent,
      foregroundAuthority: foreground,
      foregroundGeneration: foreground.currentGeneration(),
      capabilityGeneration: capability.preparationAuthorizationGeneration(),
      withCapabilityAuthorization: { expectedGeneration, operation in
        try capability.withPreparationAuthorization(
          expectedGeneration: expectedGeneration,
          capability: intent.capability,
          scopeID: intent.scope.id,
          operation: operation
        )
      }
    )

    // The token retains the old generation. A persisted capability change publishes a new
    // generation under the same lock used by the mutation wrapper, leaving no validation/write
    // interleaving window.
    try await capability.setPreparationEnabled(false, for: .createNote)

    do {
      _ = try await executor.execute(intent, authorization: authorization)
      XCTFail("A capability revoked before mutation must fail closed.")
    } catch {
      XCTAssertEqual(error as? AssistantActionBrokerError, .capabilityDisabled)
    }
    let snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.notes.isEmpty)
    XCTAssertTrue(snapshot.pendingRecordNames.isEmpty)
  }

  func testActionNoteExecutorDoesNotMutateWhenCancelledAtAuthorizationBoundary() async throws {
    let root = temporaryDirectory(named: "action-note-cancelled-final-hop")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentLocalSyncStore(fileURL: root.appendingPathComponent("sync-store.json"))
    let executor = LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "actions")
    let intent = actionNoteIntent(label: "cancelled-final-hop")
    let foregroundGate = TestActionForegroundGate(active: true)
    let foreground = foregroundGate.authority()
    let boundary = BlockingActionAuthorizationBoundary()
    let authorization = actionExecutionAuthorization(
      for: intent,
      foregroundAuthority: foreground,
      foregroundGeneration: foreground.currentGeneration(),
      capabilityGeneration: 0,
      withCapabilityAuthorization: { expectedGeneration, operation in
        guard expectedGeneration == 0 else {
          throw AssistantActionExecutionAuthorizationError.bindingMismatch
        }
        try boundary.authorize(operation)
      }
    )

    let execution = Task {
      try await executor.execute(intent, authorization: authorization)
    }
    let reachedBoundary = await boundary.waitUntilAuthorizationStarted()
    XCTAssertTrue(reachedBoundary, "Execution should reach the final authorization boundary.")
    execution.cancel()
    boundary.release()

    do {
      _ = try await execution.value
      XCTFail("Cancellation before token consumption must fail without a local mutation.")
    } catch is CancellationError {
      // Expected: the cancellation is checked under both authority locks before token consumption.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    let snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.notes.isEmpty)
    XCTAssertTrue(snapshot.pendingRecordNames.isEmpty)
  }

  func testActionExecutorReconcilesExactDurableTodoAndNoteWithoutAnotherWrite() async throws {
    let root = temporaryDirectory(named: "action-local-reconciliation")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("sync-store.json")
    let store = IAgentLocalSyncStore(fileURL: storeURL)
    let executor = LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "actions")
    var reviewedList = SyncedTodoList(name: "Work", order: 0)
    try await store.upsertLocal(.todoList(reviewedList))
    let todoIntent = actionTodoIntent(label: "reconcile-todo")
    let noteIntent = actionNoteIntent(label: "reconcile-note")

    let todoResult = try await executor.execute(
      todoIntent,
      authorization: actionExecutionAuthorization(for: todoIntent)
    )
    let noteResult = try await executor.execute(
      noteIntent,
      authorization: actionExecutionAuthorization(for: noteIntent)
    )
    // Durable action truth wins over a target renamed after the write. Recovery must not rerun
    // current target validation because it only verifies the exact already-written record.
    reviewedList.name = "Archive"
    reviewedList.updatedAt = reviewedList.updatedAt.addingTimeInterval(1)
    try await store.upsertLocal(.todoList(reviewedList))
    let dataBeforeReconciliation = try Data(contentsOf: storeURL)
    let snapshotBeforeReconciliation = await store.snapshot()

    let reconciledTodo = try await executor.reconcileCommittedResult(todoIntent)
    let reconciledNote = try await executor.reconcileCommittedResult(noteIntent)

    XCTAssertEqual(reconciledTodo, todoResult)
    XCTAssertEqual(reconciledNote, noteResult)
    XCTAssertEqual(try Data(contentsOf: storeURL), dataBeforeReconciliation)
    let snapshotAfterReconciliation = await store.snapshot()
    XCTAssertEqual(snapshotAfterReconciliation.todos, snapshotBeforeReconciliation.todos)
    XCTAssertEqual(snapshotAfterReconciliation.notes, snapshotBeforeReconciliation.notes)
    XCTAssertEqual(
      snapshotAfterReconciliation.pendingRecordNames,
      snapshotBeforeReconciliation.pendingRecordNames
    )
  }

  func testActionExecutorReconciliationReturnsNilForAbsentOrNativeAction() async throws {
    let root = temporaryDirectory(named: "action-local-reconciliation-absent")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("sync-store.json")
    let store = IAgentLocalSyncStore(fileURL: storeURL)
    let executor = LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "actions")

    let absent = try await executor.reconcileCommittedResult(
      actionNoteIntent(label: "reconcile-absent")
    )
    let native = try await executor.reconcileCommittedResult(
      actionCodexIntent(label: "reconcile-native")
    )

    XCTAssertNil(absent)
    XCTAssertNil(native)
    XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    let snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.todos.isEmpty)
    XCTAssertTrue(snapshot.notes.isEmpty)
    XCTAssertTrue(snapshot.pendingRecordNames.isEmpty)
  }

  func testActionExecutorReconciliationRejectsMismatchedSlotWithoutMutation() async throws {
    let root = temporaryDirectory(named: "action-local-reconciliation-conflict")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("sync-store.json")
    let store = IAgentLocalSyncStore(fileURL: storeURL)
    let executor = LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "actions")
    let intent = actionNoteIntent(label: "reconcile-conflict")
    let conflicting = SyncedNote(
      id: try XCTUnwrap(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")),
      title: "User-owned content",
      body: "This must not be mistaken for the reviewed action payload.",
      createdAt: intent.createdAt,
      updatedAt: intent.createdAt,
      sourceDeviceID: "user"
    )
    try await store.upsertLocal(.note(conflicting))
    let dataBeforeReconciliation = try Data(contentsOf: storeURL)

    do {
      _ = try await executor.reconcileCommittedResult(intent)
      XCTFail("A different payload in the deterministic slot must not be reported as committed.")
    } catch {
      guard case AssistantActionBrokerError.staleTarget = error else {
        return XCTFail("Expected a stale deterministic slot, got \(error)")
      }
    }

    XCTAssertEqual(try Data(contentsOf: storeURL), dataBeforeReconciliation)
    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.notes, [conflicting])
  }

  func testCapabilityPersistenceFailureDoesNotPublishPolicyOrAuthorizationGeneration() async throws {
    let root = temporaryDirectory(named: "action-capability-persistence")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blockedParent = root.appendingPathComponent("not-a-directory")
    try Data("occupied".utf8).write(to: blockedParent)
    let capability = AssistantActionCapabilityStore(
      fileURL: blockedParent.appendingPathComponent("assistant-action-capabilities.json")
    )
    let initialGeneration = capability.preparationAuthorizationGeneration()

    do {
      try await capability.setPreparationEnabled(false, for: .createNote)
      XCTFail("Writing capability policy through a non-directory parent should fail.")
    } catch {
      // Expected: neither actor policy nor its synchronous authorization mirror may advance.
    }

    let policy = await capability.currentPolicy()
    XCTAssertTrue(policy.allowsPreparation(capability: .createNote, scopeID: "notes:local"))
    XCTAssertEqual(capability.preparationAuthorizationGeneration(), initialGeneration)
    var didAuthorize = false
    try capability.withPreparationAuthorization(
      expectedGeneration: initialGeneration,
      capability: .createNote,
      scopeID: "notes:local"
    ) {
      didAuthorize = true
    }
    XCTAssertTrue(didAuthorize)
  }

  private func temporaryDirectory(named name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-\(name)-\(UUID().uuidString)", isDirectory: true)
  }

  private func actionExecutionIdentity(label: String) -> AssistantActionExecutionIdentity {
    AssistantActionExecutionIdentity(
      intentID: "intent-\(label)",
      proposalDigest: "digest-\(label)",
      capabilityID: "test-action",
      scopeID: "test:local"
    )
  }

  private func actionExecutionAuthorization(
    for intent: AssistantActionIntent
  ) -> AssistantActionExecutionAuthorization {
    let identity = AssistantActionExecutionIdentity(
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      capabilityID: intent.capability.rawValue,
      scopeID: intent.scope.id
    )
    return actionExecutionAuthorization(
      for: identity,
      proposalExpiresAt: intent.expiresAt,
      confirmationExpiresAt: intent.expiresAt
    )
  }

  private func actionExecutionAuthorization(
    for intent: AssistantActionIntent,
    foregroundAuthority: AssistantActionForegroundAuthority,
    foregroundGeneration: UInt64,
    capabilityGeneration: UInt64,
    withCapabilityAuthorization: @escaping (
      _ expectedGeneration: UInt64,
      _ operation: () throws -> Void
    ) throws -> Void
  ) -> AssistantActionExecutionAuthorization {
    let identity = AssistantActionExecutionIdentity(
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      capabilityID: intent.capability.rawValue,
      scopeID: intent.scope.id
    )
    return AssistantActionExecutionAuthorization(
      binding: .init(
        identity: identity,
        proposalExpiresAt: intent.expiresAt,
        confirmationExpiresAt: intent.expiresAt
      ),
      now: { intent.createdAt.addingTimeInterval(1) },
      foregroundAuthority: foregroundAuthority,
      foregroundGeneration: foregroundGeneration,
      capabilityGeneration: capabilityGeneration,
      withCapabilityAuthorization: withCapabilityAuthorization
    )
  }

  private func actionNoteIntent(label: String) -> AssistantActionIntent {
    let createdAt = Date(timeIntervalSince1970: 1_786_370_000)
    let digest = String(repeating: label == "foreground-revocation" ? "b" : "c", count: 64)
    return AssistantActionIntent(
      id: "intent-action-note-\(label)",
      proposalDigest: digest,
      capability: .createNote,
      scope: AssistantActionScope(id: "notes:local", displayName: "Notes"),
      payload: .createNote(
        CreateNoteActionPayload(title: "Reviewed title", body: "Reviewed body")
      ),
      review: AssistantActionReviewCard(
        title: "Create note",
        explanation: "Review this note.",
        primaryVerb: "Create note",
        fields: [],
        canonicalPayloadJSON: "{}",
        requiresNativeHandoff: false
      ),
      provenance: AssistantActionProvenance(
        conversationID: "conversation",
        turnID: "turn",
        currentUserMessageID: "message",
        toolCallID: "tool-call-\(label)"
      ),
      createdAt: createdAt,
      expiresAt: createdAt.addingTimeInterval(300)
    )
  }

  private func actionTodoIntent(label: String) -> AssistantActionIntent {
    let createdAt = Date(timeIntervalSince1970: 1_786_370_000)
    return AssistantActionIntent(
      id: "intent-action-todo-\(label)",
      proposalDigest: String(repeating: "d", count: 64),
      capability: .createTodo,
      scope: AssistantActionScope(id: "todos:local", displayName: "Todos"),
      payload: .createTodo(
        CreateTodoActionPayload(title: "Reviewed to-do", dueAt: nil, listName: "Work")
      ),
      review: AssistantActionReviewCard(
        title: "Create to-do",
        explanation: "Review this to-do.",
        primaryVerb: "Create to-do",
        fields: [],
        canonicalPayloadJSON: "{}",
        requiresNativeHandoff: false
      ),
      provenance: AssistantActionProvenance(
        conversationID: "conversation",
        turnID: "turn",
        currentUserMessageID: "message",
        toolCallID: "tool-call-\(label)"
      ),
      createdAt: createdAt,
      expiresAt: createdAt.addingTimeInterval(300)
    )
  }

  private func actionCodexIntent(label: String) -> AssistantActionIntent {
    let createdAt = Date(timeIntervalSince1970: 1_786_370_000)
    return AssistantActionIntent(
      id: "intent-action-codex-\(label)",
      proposalDigest: String(repeating: "e", count: 64),
      capability: .requestCodexTask,
      scope: AssistantActionScope(id: "codex:handoff", displayName: "Codex handoff"),
      payload: .codexTaskRequest(
        CodexTaskRequestActionPayload(prompt: "Review request", workspaceIdentifier: nil)
      ),
      review: AssistantActionReviewCard(
        title: "Prepare Codex request",
        explanation: "Review this request.",
        primaryVerb: "Continue",
        fields: [],
        canonicalPayloadJSON: "{}",
        requiresNativeHandoff: true
      ),
      provenance: AssistantActionProvenance(
        conversationID: "conversation",
        turnID: "turn",
        currentUserMessageID: "message",
        toolCallID: "tool-call-\(label)"
      ),
      createdAt: createdAt,
      expiresAt: createdAt.addingTimeInterval(300)
    )
  }

  private func actionExecutionAuthorization(
    for identity: AssistantActionExecutionIdentity,
    proposalExpiresAt: Date = Date(timeIntervalSince1970: 100),
    confirmationExpiresAt: Date = Date(timeIntervalSince1970: 100)
  ) -> AssistantActionExecutionAuthorization {
    let foreground = AssistantActionForegroundAuthority(
      currentGeneration: { 0 },
      withActiveAuthorization: { expectedGeneration, operation in
        guard expectedGeneration == 0 else {
          throw AssistantActionExecutionAuthorizationError.bindingMismatch
        }
        try operation()
      }
    )
    return AssistantActionExecutionAuthorization(
      binding: .init(
        identity: identity,
        proposalExpiresAt: proposalExpiresAt,
        confirmationExpiresAt: confirmationExpiresAt
      ),
      now: { Date(timeIntervalSince1970: 1) },
      foregroundAuthority: foreground,
      foregroundGeneration: 0,
      capabilityGeneration: 0,
      withCapabilityAuthorization: { expectedGeneration, operation in
        guard expectedGeneration == 0 else {
          throw AssistantActionExecutionAuthorizationError.bindingMismatch
        }
        try operation()
      }
    )
  }
}

private final class TestActionForegroundGate: @unchecked Sendable {
  private let lock = NSLock()
  private var active: Bool
  private var generation: UInt64 = 0

  init(active: Bool) {
    self.active = active
  }

  func update(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard active != value else { return }
    active = value
    generation &+= 1
  }

  func authority() -> AssistantActionForegroundAuthority {
    AssistantActionForegroundAuthority(
      currentGeneration: { [self] in currentGeneration() },
      withActiveAuthorization: { [self] expectedGeneration, operation in
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.active, self.generation == expectedGeneration else {
          throw AssistantActionBrokerError.appNotForeground
        }
        try operation()
      }
    )
  }

  private func currentGeneration() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }
}

private enum BlockingActionAuthorizationBoundaryError: Error {
  case timedOut
}

private final class BlockingActionAuthorizationBoundary: @unchecked Sendable {
  private let started = DispatchSemaphore(value: 0)
  private let continuation = DispatchSemaphore(value: 0)

  func authorize(_ operation: () throws -> Void) throws {
    started.signal()
    guard continuation.wait(timeout: .now() + 5) == .success else {
      throw BlockingActionAuthorizationBoundaryError.timedOut
    }
    try operation()
  }

  func waitUntilAuthorizationStarted() async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        continuation.resume(returning: started.wait(timeout: .now() + 5) == .success)
      }
    }
  }

  func release() {
    continuation.signal()
  }
}

private actor SyncIntentProbe {
  private var intents: [Bool] = []
  private var activeOperations = 0
  private var maximumActiveOperations = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func perform(shouldFetch: Bool) async {
    intents.append(shouldFetch)
    activeOperations += 1
    maximumActiveOperations = max(maximumActiveOperations, activeOperations)
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
    activeOperations -= 1
  }

  func waitUntilStarted(count: Int) async {
    while intents.count < count {
      await Task.yield()
    }
  }

  func waitUntilIntentWasQueued(coordinator: IAgentCloudSyncSingleFlight) async {
    while await coordinator.pendingIntentCountForTesting() == 0 {
      await Task.yield()
    }
  }

  func releaseNext() {
    guard !continuations.isEmpty else { return }
    continuations.removeFirst().resume()
  }

  func fetchIntents() -> [Bool] {
    intents
  }

  func maximumConcurrentOperations() -> Int {
    maximumActiveOperations
  }
}

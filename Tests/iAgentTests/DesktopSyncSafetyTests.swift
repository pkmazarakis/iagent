import Foundation
import XCTest
import iAgentCore
@testable import iAgentPanel

final class DesktopSyncSafetyTests: XCTestCase {
  private func input(
    todos: [LocalTodo] = [],
    todosAreAuthoritative: Bool = true
  ) -> DesktopSyncInput {
    DesktopSyncInput(
      threads: [],
      calendarEvents: [],
      todos: todos,
      todoListNames: [],
      projectOrder: [],
      todosAreAuthoritative: todosAreAuthoritative
    )
  }

  func testDatalessTodoFileIsNeitherReadAsEmptyNorOverwritten() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-dataless-todo-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let original = Data("[{\"sentinel\":true}]".utf8)
    let todoURL = root.appendingPathComponent("todos.json")
    try original.write(to: todoURL)
    let store = LocalTodoStore(rootURL: root) { url in
      url.lastPathComponent == "todos.json"
    }

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(
        error as? LocalTodoStoreError,
        .contentUnavailable(fileName: "todos.json")
      )
    }
    XCTAssertThrowsError(try store.save([])) { error in
      XCTAssertEqual(
        error as? LocalTodoStoreError,
        .contentUnavailable(fileName: "todos.json")
      )
    }
    XCTAssertEqual(try Data(contentsOf: todoURL), original)
  }

  func testMalformedTodoFileIsReportedInsteadOfBecomingAnEmptyList() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-malformed-todo-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: root.appendingPathComponent("todos.json"))

    XCTAssertThrowsError(try LocalTodoStore(rootURL: root).load()) { error in
      guard case let .unreadable(fileName, _) = error as? LocalTodoStoreError else {
        return XCTFail("Expected an unreadable todo source, got \(error)")
      }
      XCTAssertEqual(fileName, "todos.json")
    }
  }

  func testUnavailableTodoSourceDoesNotPublishEmptyOrChangeSnapshotCount() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-unavailable-todo-sync-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documents = LocalDocumentStore(rootURL: root)
    let coordinator = DesktopSyncCoordinator(documentStore: documents, smokeTest: true)
    let todo = LocalTodo(
      id: UUID(),
      title: "Keep this todo",
      isCompleted: false,
      createdAt: Date()
    )
    _ = await coordinator.synchronize(
      input: DesktopSyncInput(
        threads: [],
        calendarEvents: [],
        todos: [todo],
        todoListNames: [],
        projectOrder: []
      ),
      fetchRemote: false
    )

    _ = await coordinator.synchronize(
      input: DesktopSyncInput(
        threads: [],
        calendarEvents: [],
        todos: [],
        todoListNames: [],
        projectOrder: [],
        todosAreAuthoritative: false
      ),
      fetchRemote: false
    )

    let mirror = IAgentLocalSyncStore(
      fileURL: root.appendingPathComponent(".sync/sync-store.json")
    )
    let snapshot = await mirror.snapshot()
    XCTAssertEqual(snapshot.todos.map(\.id), [todo.id])
    XCTAssertEqual(snapshot.desktopSnapshot?.openTodoCount, 1)
    XCTAssertFalse(snapshot.desktopSnapshot?.hasAuthoritativeTodoCount ?? true)
  }

  func testUnavailableTodoSourceCanDisplayRemoteTodosWithoutLosingLocalChanges() {
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    let openID = UUID()
    let completedID = UUID()
    let removedID = UUID()
    let open = LocalTodo(
      id: openID,
      title: "Remote open",
      isCompleted: false,
      createdAt: createdAt,
      updatedAt: createdAt
    )
    let completed = LocalTodo(
      id: completedID,
      title: "Remote completed",
      isCompleted: true,
      completedAt: createdAt.addingTimeInterval(10),
      createdAt: createdAt.addingTimeInterval(-10),
      updatedAt: createdAt.addingTimeInterval(10)
    )
    let removed = LocalTodo(
      id: removedID,
      title: "Removed remotely",
      isCompleted: false,
      createdAt: createdAt.addingTimeInterval(-20),
      updatedAt: createdAt
    )

    let initial = DesktopTodoReconciler.merge(
      remote: [open, completed],
      captured: [],
      current: []
    )
    XCTAssertEqual(initial.filter { !$0.isCompleted }.map(\.id), [openID])
    XCTAssertEqual(initial.filter(\.isCompleted).map(\.id), [completedID])

    var locallyCompleted = open
    locallyCompleted.isCompleted = true
    locallyCompleted.completedAt = createdAt.addingTimeInterval(30)
    locallyCompleted.updatedAt = createdAt.addingTimeInterval(30)
    let reconciled = DesktopTodoReconciler.merge(
      remote: [open, completed],
      captured: [open, completed, removed],
      current: [locallyCompleted, completed]
    )
    XCTAssertEqual(Set(reconciled.map(\.id)), Set([openID, completedID]))
    XCTAssertTrue(reconciled.first { $0.id == openID }?.isCompleted == true)
    XCTAssertEqual(
      reconciled.first { $0.id == openID }?.completedAt,
      locallyCompleted.completedAt
    )
  }

  func testMetadataMigrationCopiesLegacyFilesWithoutOverwritingDestination() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-sync-metadata-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documentRoot = root.appendingPathComponent("Documents", isDirectory: true)
    let legacy = documentRoot.appendingPathComponent(".sync", isDirectory: true)
    let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try "legacy-device".write(
      to: legacy.appendingPathComponent("device-id.txt"),
      atomically: true,
      encoding: .utf8
    )
    try Data("{\"entries\":{}}".utf8).write(
      to: legacy.appendingPathComponent("note-index.json")
    )

    let first = DesktopSyncStoragePaths.prepare(
      documentRootURL: documentRoot,
      smokeTest: false,
      applicationSupportDirectoryURL: applicationSupport
    )
    XCTAssertNil(first.migrationWarning)
    XCTAssertEqual(first.metadataDirectoryURL, applicationSupport)
    XCTAssertEqual(
      try String(
        contentsOf: applicationSupport.appendingPathComponent("device-id.txt"),
        encoding: .utf8
      ),
      "legacy-device"
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("device-id.txt").path))

    try "destination-device".write(
      to: applicationSupport.appendingPathComponent("device-id.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "changed-legacy-device".write(
      to: legacy.appendingPathComponent("device-id.txt"),
      atomically: true,
      encoding: .utf8
    )
    _ = DesktopSyncStoragePaths.prepare(
      documentRootURL: documentRoot,
      smokeTest: false,
      applicationSupportDirectoryURL: applicationSupport
    )
    XCTAssertEqual(
      try String(
        contentsOf: applicationSupport.appendingPathComponent("device-id.txt"),
        encoding: .utf8
      ),
      "destination-device"
    )
  }

  func testProductionCloudKitPreflightRequiresExactEnvironmentContainerAndTeam() {
    let production = DesktopCloudSyncEntitlements(
      cloudServices: ["CloudKit"],
      containerIdentifiers: [DesktopCloudSyncPreflight.expectedContainerIdentifier],
      containerEnvironment: "Production",
      teamIdentifier: DesktopCloudSyncPreflight.expectedTeamIdentifier,
      applicationIdentifier: "625CGY297X.com.platon.iagent-panel",
      pushEnvironment: "production"
    )
    XCTAssertTrue(
      DesktopCloudSyncPreflight.evaluate(
        entitlements: production,
        smokeTest: false
      ).isAvailable
    )

    var development = production
    development.containerEnvironment = "Development"
    let developmentResult = DesktopCloudSyncPreflight.evaluate(
      entitlements: development,
      smokeTest: false
    )
    XCTAssertFalse(developmentResult.isAvailable)
    XCTAssertTrue(developmentResult.message.contains("TestFlight uses Production"))

    var wrongTeam = production
    wrongTeam.teamIdentifier = "WRONGTEAM"
    let wrongTeamResult = DesktopCloudSyncPreflight.evaluate(
      entitlements: wrongTeam,
      smokeTest: false
    )
    XCTAssertFalse(wrongTeamResult.isAvailable)
    XCTAssertTrue(wrongTeamResult.message.contains(DesktopCloudSyncPreflight.expectedTeamIdentifier))
  }

  func testDesktopHeartbeatAdvancesWithoutChangingContentVersion() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-heartbeat-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = DesktopSyncCoordinator(
      documentStore: LocalDocumentStore(rootURL: root),
      smokeTest: true
    )
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    _ = await coordinator.synchronize(
      input: input(),
      fetchRemote: false,
      referenceDate: start
    )
    let storeURL = root.appendingPathComponent(".sync/sync-store.json")
    let initialSnapshot = await IAgentLocalSyncStore(fileURL: storeURL).snapshot()
    let initial = try XCTUnwrap(initialSnapshot.desktopSnapshot)

    _ = await coordinator.synchronize(
      input: input(),
      fetchRemote: false,
      referenceDate: start.addingTimeInterval(30)
    )
    let beforeDeadlineSnapshot = await IAgentLocalSyncStore(fileURL: storeURL).snapshot()
    let beforeDeadline = try XCTUnwrap(beforeDeadlineSnapshot.desktopSnapshot)
    XCTAssertEqual(beforeDeadline.generatedAt, initial.generatedAt)
    XCTAssertEqual(beforeDeadline.lastSeenAt, initial.lastSeenAt)

    _ = await coordinator.synchronize(
      input: input(),
      fetchRemote: false,
      referenceDate: start.addingTimeInterval(61)
    )
    let heartbeatSnapshot = await IAgentLocalSyncStore(fileURL: storeURL).snapshot()
    let heartbeat = try XCTUnwrap(heartbeatSnapshot.desktopSnapshot)
    XCTAssertEqual(heartbeat.generatedAt, initial.generatedAt)
    XCTAssertEqual(heartbeat.lastSeenAt, start.addingTimeInterval(61))
    XCTAssertTrue(heartbeat.isFresh(at: start.addingTimeInterval(180)))
    XCTAssertFalse(heartbeat.isFresh(at: start.addingTimeInterval(182)))
  }

  func testDesktopSnapshotPublishesWhenTodoSourceIsUnknown() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-unknown-todo-snapshot-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = DesktopSyncCoordinator(
      documentStore: LocalDocumentStore(rootURL: root),
      smokeTest: true
    )

    _ = await coordinator.synchronize(
      input: input(todosAreAuthoritative: false),
      fetchRemote: false
    )
    let mirror = IAgentLocalSyncStore(fileURL: root.appendingPathComponent(".sync/sync-store.json"))
    let snapshot = await mirror.snapshot()
    let desktop = try XCTUnwrap(snapshot.desktopSnapshot)
    XCTAssertNil(desktop.openTodoCount)
    XCTAssertFalse(desktop.hasAuthoritativeTodoCount)
    XCTAssertNotNil(desktop.lastSeenAt)
  }

  func testUnavailableMarkdownPreservesItsRecordAndDoesNotBlockOtherUpdates() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-unavailable-note-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let documents = LocalDocumentStore(rootURL: root)
    let unavailable = try documents.save(
      kind: .note,
      title: "Cloud placeholder",
      body: "Keep this record"
    )
    let available = try documents.save(
      kind: .note,
      title: "Available note",
      body: "Version one"
    )
    let initialCoordinator = DesktopSyncCoordinator(documentStore: documents, smokeTest: true)
    _ = await initialCoordinator.synchronize(input: input(), fetchRemote: false)

    try "# Available note\n\nVersion two\n".write(
      to: available.fileURL,
      atomically: true,
      encoding: .utf8
    )
    let coordinator = DesktopSyncCoordinator(
      documentStore: documents,
      smokeTest: true,
      noteRequiresDownload: { $0.standardizedFileURL == unavailable.fileURL.standardizedFileURL }
    )
    let state = await coordinator.synchronize(input: input(), fetchRemote: false)

    let mirror = IAgentLocalSyncStore(fileURL: root.appendingPathComponent(".sync/sync-store.json"))
    let payloads = await mirror.allPayloads()
    let placeholder = payloads.compactMap { payload -> SyncedNote? in
      guard case let .note(note) = payload, note.title == "Cloud placeholder" else { return nil }
      return note
    }.first
    let updated = payloads.compactMap { payload -> SyncedNote? in
      guard case let .note(note) = payload, note.title == "Available note" else { return nil }
      return note
    }.first
    XCTAssertNil(placeholder?.deletedAt)
    XCTAssertEqual(placeholder?.body, "Keep this record\n")
    XCTAssertEqual(updated?.body, "Version two\n")
    XCTAssertTrue(state.status.message?.contains("Markdown note is unavailable") == true)
  }
}

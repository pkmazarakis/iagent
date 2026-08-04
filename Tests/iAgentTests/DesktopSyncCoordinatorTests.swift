import Foundation
import XCTest
import iAgentCore
@testable import iAgentPanel

final class DesktopSyncCoordinatorTests: XCTestCase {
  func testOfflineDesktopBridgeImportsMobileWritesAndTracksDeletion() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-sync-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documents = LocalDocumentStore(rootURL: root)
    let note = try documents.save(
      kind: .note,
      title: "Desktop note",
      body: "A local-first note."
    )
    let localTodo = LocalTodo(
      id: UUID(),
      title: "Desktop todo",
      isCompleted: false,
      createdAt: Date().addingTimeInterval(-60)
    )
    let coordinator = DesktopSyncCoordinator(documentStore: documents, smokeTest: true)
    let initialInput = DesktopSyncInput(
      threads: [
        AgentThread(
          id: "thread-1",
          projectName: "iagent",
          workspacePath: root.path,
          title: "Build companion",
          activity: "Testing sync",
          state: .running,
          modes: [.plan],
          elapsed: "1m",
          createdAt: Date().addingTimeInterval(-120),
          updatedAt: Date()
        )
      ],
      calendarEvents: [],
      todos: [localTodo],
      todoListNames: ["work"],
      projectOrder: ["workspace:\(root.path)"]
    )

    let initialState = await coordinator.synchronize(input: initialInput, fetchRemote: true)
    XCTAssertEqual(initialState.todos.map(\.id), [localTodo.id])

    let remoteTodo = SyncedTodo(
      title: "Mobile todo",
      listName: "personal",
      createdAt: Date(),
      updatedAt: Date()
    )
    let remoteNote = SyncedNote(
      title: "Mobile note",
      body: "Written while away from the Mac.",
      sourceDeviceID: "iphone-test"
    )
    try await coordinator.mergeRemoteForTesting([
      .todo(remoteTodo),
      .note(remoteNote),
      .todoList(SyncedTodoList(name: "personal", order: 1))
    ])

    let importedState = await coordinator.synchronize(input: initialInput, fetchRemote: false)
    XCTAssertEqual(Set(importedState.todos.map(\.id)), Set([localTodo.id, remoteTodo.id]))
    XCTAssertTrue(importedState.todoListNames.contains("personal"))

    let noteFiles = try FileManager.default.contentsOfDirectory(
      at: documents.folderURL(for: .note),
      includingPropertiesForKeys: nil
    )
    let mobileFile = try XCTUnwrap(noteFiles.first { url in
      (try? String(contentsOf: url, encoding: .utf8).contains("Written while away")) == true
    })
    XCTAssertTrue(FileManager.default.fileExists(atPath: note.fileURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: mobileFile.path))

    let appliedInput = DesktopSyncInput(
      threads: initialInput.threads,
      calendarEvents: initialInput.calendarEvents,
      todos: importedState.todos,
      todoListNames: importedState.todoListNames,
      projectOrder: initialInput.projectOrder
    )
    _ = await coordinator.synchronize(input: appliedInput, fetchRemote: false)

    let deletedInput = DesktopSyncInput(
      threads: initialInput.threads,
      calendarEvents: initialInput.calendarEvents,
      todos: [localTodo],
      todoListNames: importedState.todoListNames,
      projectOrder: initialInput.projectOrder
    )
    let deletedState = await coordinator.synchronize(input: deletedInput, fetchRemote: false)
    XCTAssertEqual(deletedState.todos.map(\.id), [localTodo.id])

    let mirror = IAgentLocalSyncStore(
      fileURL: root.appendingPathComponent(".sync/sync-store.json")
    )
    let allPayloads = await mirror.allPayloads()
    let tombstone = allPayloads.first { $0.recordName == IAgentSyncPayload.todo(remoteTodo).recordName }
    XCTAssertNotNil(tombstone?.deletedAt)
  }
}

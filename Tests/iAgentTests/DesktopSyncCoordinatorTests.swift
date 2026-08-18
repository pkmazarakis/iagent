import Foundation
import XCTest
import iAgentCore
@testable import iAgentPanel

final class DesktopSyncCoordinatorTests: XCTestCase {
  private func emptyInput() -> DesktopSyncInput {
    DesktopSyncInput(
      threads: [],
      calendarEvents: [],
      todos: [],
      todoListNames: [],
      projectOrder: []
    )
  }

  func testSmokeCoordinatorExposesPreflightCloudSyncStatus() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-current-sync-status-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = DesktopSyncCoordinator(
      documentStore: LocalDocumentStore(rootURL: root),
      smokeTest: true
    )
    let status = await coordinator.currentCloudSyncStatus()

    XCTAssertEqual(status.phase, .offline)
    XCTAssertTrue(status.message?.contains("disabled during smoke tests") == true)
  }

  func testMacProviderCorrectsNewerGenericCloudProjectionWithoutTimestampRegression() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-message-authority-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = DesktopSyncCoordinator(
      documentStore: LocalDocumentStore(rootURL: root),
      smokeTest: true
    )
    let sentAt = Date().addingTimeInterval(-60)
    let cloudUpdatedAt = sentAt.addingTimeInterval(30)
    let messageID = "message-authority"
    let conversationID = "conversation-authority"
    let participantID = "participant-authority"
    let genericMessage = SyncedMessage(
      id: messageID,
      conversationID: conversationID,
      senderID: participantID,
      senderDisplayName: "Contact",
      isFromMe: false,
      body: "Message",
      sentAt: sentAt,
      updatedAt: cloudUpdatedAt
    )
    let genericConversation = SyncedMessageConversation(
      id: conversationID,
      displayName: "Conversation",
      participants: [
        SyncedMessageParticipant(id: participantID, displayName: "Contact")
      ],
      isGroup: false,
      serviceName: "iMessage",
      latestMessageID: messageID,
      latestMessageDate: sentAt,
      latestPreview: genericMessage.body,
      updatedAt: cloudUpdatedAt
    )
    try await coordinator.mergeRemoteForTesting([
      .messageConversation(genericConversation),
      .message(genericMessage),
    ])

    let decodedMessage = SyncedMessage(
      id: messageID,
      conversationID: conversationID,
      senderID: participantID,
      senderDisplayName: "Maya",
      isFromMe: false,
      body: "Decoded body",
      sentAt: sentAt,
      updatedAt: sentAt
    )
    let namedConversation = SyncedMessageConversation(
      id: conversationID,
      displayName: "Maya",
      participants: [
        SyncedMessageParticipant(id: participantID, displayName: "Maya")
      ],
      isGroup: false,
      serviceName: "iMessage",
      latestMessageID: messageID,
      latestMessageDate: sentAt,
      latestPreview: decodedMessage.body,
      updatedAt: sentAt
    )
    let corrected = await coordinator.ingestMessageBatch(
      MessageProviderBatch(
        conversations: [namedConversation],
        messages: [decodedMessage],
        isFullSnapshot: false
      )
    )

    XCTAssertEqual(corrected.messageConversations.first?.displayName, "Maya")
    XCTAssertEqual(corrected.messageConversations.first?.latestPreview, "Decoded body")
    XCTAssertEqual(corrected.messageConversations.first?.updatedAt, cloudUpdatedAt)
    XCTAssertEqual(corrected.messages.first?.body, "Decoded body")
    XCTAssertEqual(corrected.messages.first?.updatedAt, cloudUpdatedAt)

    try await coordinator.mergeRemoteForTesting([
      .messageConversation(genericConversation),
      .message(genericMessage),
    ])
    let afterStaleFetch = await coordinator.ingestMessageBatch(
      MessageProviderBatch(isFullSnapshot: false)
    )
    XCTAssertEqual(afterStaleFetch.messageConversations.first?.displayName, "Maya")
    XCTAssertEqual(afterStaleFetch.messages.first?.body, "Decoded body")
  }

  func testProviderRestageAfterNewerTransportEquivalentCloudProjectionIsNoOp() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "iagent-message-transport-equivalence-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = DesktopSyncCoordinator(
      documentStore: LocalDocumentStore(rootURL: root),
      smokeTest: true
    )
    let wholeSeconds = floor(Date().timeIntervalSince1970) - 60
    let sentAt = Date(timeIntervalSince1970: wholeSeconds + 0.75)
    let message = SyncedMessage(
      id: "message-transport-equivalent",
      conversationID: "conversation-transport-equivalent",
      senderID: "participant-transport-equivalent",
      senderDisplayName: "Maya",
      isFromMe: false,
      body: "Decoded body",
      sentAt: sentAt,
      updatedAt: sentAt
    )
    let conversation = SyncedMessageConversation(
      id: message.conversationID,
      displayName: "Maya",
      participants: [
        SyncedMessageParticipant(
          id: "participant-transport-equivalent",
          displayName: "Maya"
        )
      ],
      isGroup: false,
      serviceName: "iMessage",
      latestMessageID: message.id,
      latestMessageDate: sentAt,
      latestPreview: message.body,
      awaitingReplyMessageID: message.id,
      updatedAt: sentAt
    )

    var cloudMessage = try transported(message)
    cloudMessage.updatedAt = sentAt.addingTimeInterval(30)
    var cloudConversation = try transported(conversation)
    cloudConversation.updatedAt = cloudMessage.updatedAt
    try await coordinator.mergeRemoteForTesting([
      .messageConversation(cloudConversation),
      .message(cloudMessage),
    ])

    let batch = MessageProviderBatch(
      conversations: [conversation],
      messages: [message],
      isFullSnapshot: false
    )
    _ = await coordinator.ingestMessageBatch(batch)
    let firstPending = await coordinator.pendingRecordNamesForTesting()
    _ = await coordinator.ingestMessageBatch(batch)
    let secondPending = await coordinator.pendingRecordNamesForTesting()

    XCTAssertTrue(firstPending.isEmpty)
    XCTAssertTrue(secondPending.isEmpty)
  }

  func testReplyAddressProjectionAndRevocationRestageCachedConversation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-message-reply-scrub-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = DesktopSyncCoordinator(
      documentStore: LocalDocumentStore(rootURL: root),
      smokeTest: true
    )
    let sentAt = Date().addingTimeInterval(-60)
    let message = SyncedMessage(
      id: "message-reply-scrub",
      conversationID: "conversation-reply-scrub",
      senderID: "opaque-participant",
      senderDisplayName: "Avery",
      isFromMe: false,
      body: "Hello",
      sentAt: sentAt,
      updatedAt: sentAt
    )
    let conversation = SyncedMessageConversation(
      id: message.conversationID,
      displayName: "Avery",
      participants: [
        SyncedMessageParticipant(
          id: "opaque-participant",
          displayName: "Avery",
          isContactNameResolved: true
        )
      ],
      isGroup: false,
      serviceName: "iMessage",
      latestMessageID: message.id,
      latestMessageDate: sentAt,
      latestPreview: message.body,
      updatedAt: sentAt
    )

    let projected = await coordinator.ingestMessageBatch(
      MessageProviderBatch(
        conversations: [conversation],
        messages: [message],
        isFullSnapshot: false
      )
    )
    let projectedConversation = try XCTUnwrap(projected.messageConversations.first)
    try await coordinator.mergeRemoteForTesting([
      .messageConversation(projectedConversation),
      .message(message),
    ])
    let pendingAfterAcknowledgement = await coordinator.pendingRecordNamesForTesting()
    XCTAssertTrue(pendingAfterAcknowledgement.isEmpty)

    var replyEnabledConversation = projectedConversation
    replyEnabledConversation.participants[0].replyAddress = "+15551234567"
    let replyEnabled = await coordinator.ingestMessageBatch(
      MessageProviderBatch(
        conversations: [replyEnabledConversation],
        messages: [message],
        isFullSnapshot: false
      )
    )
    let replyEnabledProjection = try XCTUnwrap(replyEnabled.messageConversations.first)
    XCTAssertEqual(
      replyEnabledProjection.participants.first?.replyAddress,
      "+15551234567"
    )
    XCTAssertEqual(replyEnabledProjection.updatedAt, projectedConversation.updatedAt)
    let pendingAfterReplyProjection = await coordinator.pendingRecordNamesForTesting()
    XCTAssertEqual(
      pendingAfterReplyProjection,
      [IAgentSyncPayload.messageConversation(replyEnabledProjection).recordName]
    )
    try await coordinator.mergeRemoteForTesting([
      .messageConversation(replyEnabledProjection),
      .message(message),
    ])
    let storeURL = root.appendingPathComponent(".sync/sync-store.json")
    let persistedBeforeScrub = try Data(contentsOf: storeURL)
    XCTAssertTrue(
      String(data: persistedBeforeScrub, encoding: .utf8)?.contains("+15551234567") == true
    )

    let scrubbed = await coordinator.scrubMessageReplyAddresses()
    let scrubbedConversation = try XCTUnwrap(scrubbed.messageConversations.first)
    XCTAssertNil(scrubbedConversation.participants.first?.replyAddress)
    XCTAssertEqual(scrubbedConversation.participants.first?.id, "opaque-participant")
    XCTAssertEqual(scrubbedConversation.updatedAt, replyEnabledProjection.updatedAt)
    let pendingAfterScrub = await coordinator.pendingRecordNamesForTesting()
    XCTAssertEqual(
      pendingAfterScrub,
      [IAgentSyncPayload.messageConversation(scrubbedConversation).recordName]
    )

    let persistedAfterScrub = try Data(contentsOf: storeURL)
    XCTAssertFalse(
      String(data: persistedAfterScrub, encoding: .utf8)?.contains("+15551234567") == true
    )

    let restartedStore = IAgentLocalSyncStore(
      fileURL: storeURL,
      messageProjectionRole: .localAuthority
    )
    let pendingAfterRestart = await restartedStore.pendingRecordNames()
    XCTAssertEqual(
      pendingAfterRestart,
      [IAgentSyncPayload.messageConversation(scrubbedConversation).recordName]
    )
    let restartedPayload = await restartedStore.payload(
      for: IAgentSyncPayload.messageConversation(scrubbedConversation).recordName
    )
    guard let restartedPayload else {
      XCTFail("Expected the scrubbed conversation after restart")
      return
    }
    guard case let .messageConversation(restartedConversation) = restartedPayload else {
      XCTFail("Expected a message conversation after restart")
      return
    }
    XCTAssertNil(restartedConversation.participants.first?.replyAddress)
  }

  func testMessageIngestEnforcesRollingRetentionAndQueuesPhysicalDeletion() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-message-retention-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = DesktopSyncCoordinator(
      documentStore: LocalDocumentStore(rootURL: root),
      smokeTest: true
    )
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let staleMessage = SyncedMessage(
      id: "stale-message",
      conversationID: "stale-conversation",
      isFromMe: false,
      body: "Outside the rolling window",
      sentAt: MessageSyncWindow.cutoff(referenceDate: now).addingTimeInterval(-1),
      updatedAt: now.addingTimeInterval(-1)
    )
    let freshMessage = SyncedMessage(
      id: "fresh-message",
      conversationID: "fresh-conversation",
      isFromMe: false,
      body: "Inside the rolling window",
      sentAt: now.addingTimeInterval(-60),
      updatedAt: now.addingTimeInterval(-60)
    )
    func conversation(for message: SyncedMessage) -> SyncedMessageConversation {
      SyncedMessageConversation(
        id: message.conversationID,
        displayName: message.conversationID,
        participants: [],
        isGroup: false,
        latestMessageID: message.id,
        latestMessageDate: message.sentAt,
        latestPreview: message.body,
        updatedAt: message.updatedAt
      )
    }

    _ = await coordinator.ingestMessageBatch(
      MessageProviderBatch(
        conversations: [conversation(for: staleMessage)],
        messages: [staleMessage],
        isFullSnapshot: true
      ),
      referenceDate: staleMessage.sentAt.addingTimeInterval(60)
    )
    let state = await coordinator.ingestMessageBatch(
      MessageProviderBatch(
        conversations: [conversation(for: freshMessage)],
        messages: [freshMessage],
        isFullSnapshot: false
      ),
      referenceDate: now
    )

    XCTAssertEqual(state.messages.map(\.id), [freshMessage.id])
    XCTAssertEqual(state.messageConversations.map(\.id), [freshMessage.conversationID])
    let mirror = IAgentLocalSyncStore(
      fileURL: root.appendingPathComponent(".sync/sync-store.json")
    )
    let snapshot = await mirror.snapshot(referenceDate: now)
    XCTAssertTrue(snapshot.pendingDeletionRecordNames.contains(
      IAgentSyncPayload.message(staleMessage).recordName
    ))
  }

  func testFullMessageSnapshotDeletesRowsMissingFromProvider() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-message-full-delete-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = DesktopSyncCoordinator(
      documentStore: LocalDocumentStore(rootURL: root),
      smokeTest: true
    )
    let now = Date()
    let message = SyncedMessage(
      id: "removed-message",
      conversationID: "removed-conversation",
      isFromMe: false,
      body: "Removed from Messages",
      sentAt: now.addingTimeInterval(-60),
      updatedAt: now.addingTimeInterval(-60)
    )
    let conversation = SyncedMessageConversation(
      id: message.conversationID,
      displayName: "Removed contact",
      participants: [],
      isGroup: false,
      latestMessageID: message.id,
      latestMessageDate: message.sentAt,
      latestPreview: message.body,
      updatedAt: message.updatedAt
    )
    _ = await coordinator.ingestMessageBatch(
      MessageProviderBatch(
        conversations: [conversation],
        messages: [message],
        isFullSnapshot: true
      ),
      referenceDate: now
    )
    let deleted = await coordinator.ingestMessageBatch(
      MessageProviderBatch(isFullSnapshot: true),
      referenceDate: now
    )

    XCTAssertTrue(deleted.messages.isEmpty)
    XCTAssertTrue(deleted.messageConversations.isEmpty)
    let mirror = IAgentLocalSyncStore(
      fileURL: root.appendingPathComponent(".sync/sync-store.json")
    )
    let snapshot = await mirror.snapshot(referenceDate: now)
    XCTAssertTrue(snapshot.pendingDeletionRecordNames.contains(
      IAgentSyncPayload.message(message).recordName
    ))
    XCTAssertTrue(snapshot.pendingDeletionRecordNames.contains(
      IAgentSyncPayload.messageConversation(conversation).recordName
    ))
  }

  func testCodexSyncPublishesOnlyVisibleAgentOutput() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-visible-codex-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let coordinator = DesktopSyncCoordinator(
      documentStore: LocalDocumentStore(rootURL: root),
      smokeTest: true
    )
    _ = await coordinator.synchronize(
      input: DesktopSyncInput(
        threads: [
          AgentThread(
            id: "thread-visible-output",
            projectName: "iagent",
            workspacePath: root.path,
            title: "Ground the assistant",
            activity: "hidden reasoning must stay local",
            activityHistory: [
              AgentThreadActivity(
                id: "reasoning-1",
                text: "hidden reasoning must stay local",
                occurredAt: now
              )
            ],
            visibleOutputs: [
              AgentThreadVisibleOutput(
                id: "visible-1",
                text: "The grounded answer shown to the user.",
                occurredAt: now
              )
            ],
            state: .completed,
            modes: [],
            elapsed: "1s",
            createdAt: now.addingTimeInterval(-1),
            updatedAt: now
          )
        ],
        calendarEvents: [],
        todos: [],
        todoListNames: [],
        projectOrder: []
      ),
      fetchRemote: false
    )

    let mirror = IAgentLocalSyncStore(
      fileURL: root.appendingPathComponent(".sync/sync-store.json")
    )
    let snapshot = await mirror.snapshot()
    let thread = try XCTUnwrap(snapshot.codexThreads.first)
    XCTAssertEqual(thread.activity, "The grounded answer shown to the user.")
    XCTAssertEqual(thread.visibleOutputs?.map(\.text), ["The grounded answer shown to the user."])
    XCTAssertFalse((thread.activityHistory ?? []).contains {
      $0.text.contains("hidden reasoning")
    })
  }

  func testAuthoritativeCalendarEventRevivesAnOlderTombstone() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-calendar-revival-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documents = LocalDocumentStore(rootURL: root)
    let coordinator = DesktopSyncCoordinator(documentStore: documents, smokeTest: true)
    let originalUpdate = Date().addingTimeInterval(-3_600)
    let start = Date().addingTimeInterval(3_600)
    let event = CalendarEventItem(
      id: "calendar-event-revival",
      sourceIdentifier: "external-calendar-event-revival",
      title: "Roadmap workshop",
      startDate: start,
      endDate: start.addingTimeInterval(3_600),
      isAllDay: false,
      calendarTitle: "Work",
      location: "Project room",
      notes: "Bring the dependency map.",
      tint: .fallback,
      updatedAt: originalUpdate
    )

    func input(calendarEvents: [CalendarEventItem]) -> DesktopSyncInput {
      DesktopSyncInput(
        threads: [],
        calendarEvents: calendarEvents,
        todos: [],
        todoListNames: [],
        projectOrder: []
      )
    }

    _ = await coordinator.synchronize(input: input(calendarEvents: [event]), fetchRemote: false)
    _ = await coordinator.synchronize(input: input(calendarEvents: []), fetchRemote: false)
    _ = await coordinator.synchronize(input: input(calendarEvents: [event]), fetchRemote: false)

    let mirror = IAgentLocalSyncStore(
      fileURL: root.appendingPathComponent(".sync/sync-store.json")
    )
    let restored = await mirror.snapshot().calendarEvents.first { $0.id == event.id }
    XCTAssertNotNil(restored)
    XCTAssertNil(restored?.deletedAt)
    XCTAssertGreaterThan(restored?.updatedAt ?? .distantPast, originalUpdate)
  }

  func testTodoMutationPersistsWhenCanonicalListIsUnavailable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-todo-mutation-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = DesktopSyncCoordinator(
      documentStore: LocalDocumentStore(rootURL: root),
      smokeTest: true
    )
    let original = LocalTodo(
      id: UUID(),
      title: "Clickable desktop todo",
      isCompleted: false,
      createdAt: Date().addingTimeInterval(-60)
    )
    try await coordinator.mergeRemoteForTesting([.todo(SyncedTodo(
      id: original.id,
      title: original.title,
      isCompleted: false,
      createdAt: original.createdAt,
      updatedAt: original.updatedAt
    ))])

    var completed = original
    completed.isCompleted = true
    completed.completedAt = Date()
    completed.updatedAt = completed.completedAt ?? Date()
    let state = await coordinator.publishTodoMutation(completed)

    XCTAssertEqual(state.todos.first(where: { $0.id == original.id })?.isCompleted, true)
    let restartedStore = IAgentLocalSyncStore(
      fileURL: root.appendingPathComponent(".sync/sync-store.json")
    )
    let persisted = await restartedStore.snapshot().todos.first { $0.id == original.id }
    XCTAssertEqual(persisted?.isCompleted, true)
    XCTAssertEqual(
      try XCTUnwrap(persisted?.completedAt).timeIntervalSince1970,
      try XCTUnwrap(completed.completedAt).timeIntervalSince1970,
      accuracy: 1
    )
  }

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
    XCTAssertEqual(initialState.noteCount, 1)

    let remoteTodo = SyncedTodo(
      title: "Mobile todo",
      notes: "Bring the release checklist.",
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
    XCTAssertEqual(importedState.noteCount, 2)
    XCTAssertTrue(importedState.todoListNames.contains("personal"))
    XCTAssertEqual(
      importedState.todos.first(where: { $0.id == remoteTodo.id })?.notes,
      "Bring the release checklist."
    )

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

  func testRemoteNoteNeverOverwritesAnOccupiedUnindexedPath() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-note-collision-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documents = LocalDocumentStore(rootURL: root)
    let occupiedURL = documents.folderURL(for: .note).appendingPathComponent("shared.md")
    try FileManager.default.createDirectory(
      at: occupiedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let canonicalSource = "# Canonical Mac note\n\nNever overwrite this.\n"
    try canonicalSource.write(to: occupiedURL, atomically: true, encoding: .utf8)

    let coordinator = DesktopSyncCoordinator(documentStore: documents, smokeTest: true)
    let remote = SyncedNote(
      title: "Remote note",
      body: "Remote body",
      createdAt: Date().addingTimeInterval(-60),
      updatedAt: Date().addingTimeInterval(60),
      sourceDeviceID: "iphone",
      relativeFilePath: "Notes/shared.md"
    )
    try await coordinator.mergeRemoteForTesting([.note(remote)])
    _ = await coordinator.synchronize(input: emptyInput(), fetchRemote: false)

    XCTAssertEqual(try String(contentsOf: occupiedURL, encoding: .utf8), canonicalSource)
    let noteFiles = (FileManager.default.enumerator(
      at: documents.folderURL(for: .note),
      includingPropertiesForKeys: nil
    )?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "md" }
    XCTAssertEqual(noteFiles.count, 2)
    XCTAssertTrue(noteFiles.contains { url in
      url != occupiedURL
        && (try? String(contentsOf: url, encoding: .utf8).contains("Remote body")) == true
    })
  }

  func testRemoteTombstoneMovesUnchangedCanonicalNoteToRecoveryQuarantine() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-note-quarantine-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documents = LocalDocumentStore(rootURL: root)
    let document = try documents.save(
      kind: .note,
      title: "Keep recoverable",
      body: "Canonical body"
    )
    let coordinator = DesktopSyncCoordinator(documentStore: documents, smokeTest: true)
    _ = await coordinator.synchronize(input: emptyInput(), fetchRemote: false)

    let mirror = IAgentLocalSyncStore(fileURL: root.appendingPathComponent(".sync/sync-store.json"))
    let initialSnapshot = await mirror.snapshot()
    let synced = try XCTUnwrap(initialSnapshot.notes.first { $0.title == "Keep recoverable" })
    try await coordinator.mergeRemoteForTesting([
      IAgentSyncPayload.note(synced).deleting(at: Date().addingTimeInterval(60))
    ])
    let state = await coordinator.synchronize(input: emptyInput(), fetchRemote: false)

    XCTAssertFalse(FileManager.default.fileExists(atPath: document.fileURL.path))
    XCTAssertEqual(state.noteCount, 0)
    let quarantine = root.appendingPathComponent(".sync/NoteQuarantine", isDirectory: true)
    let quarantinedFiles = (FileManager.default.enumerator(
      at: quarantine,
      includingPropertiesForKeys: nil
    )?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "md" }
    XCTAssertEqual(quarantinedFiles.count, 1)
    XCTAssertTrue(
      try String(contentsOf: XCTUnwrap(quarantinedFiles.first), encoding: .utf8)
        .contains("Canonical body")
    )
  }

  func testDocumentCountIncludesOnlyVisibleMarkdownFilesForRequestedKind() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-document-count-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documents = LocalDocumentStore(rootURL: root)
    _ = try documents.save(kind: .note, title: "First note", body: "One")
    _ = try documents.save(kind: .note, title: "Second note", body: "Two")
    _ = try documents.save(kind: .page, title: "A page", body: "Not a note")

    let notesDirectory = documents.folderURL(for: .note)
    try "ignored".write(
      to: notesDirectory.appendingPathComponent("ignored.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "hidden".write(
      to: notesDirectory.appendingPathComponent(".hidden.md"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createDirectory(
      at: notesDirectory.appendingPathComponent("directory.md", isDirectory: true),
      withIntermediateDirectories: true
    )

    XCTAssertEqual(documents.documentCount(for: .note), 2)
    XCTAssertEqual(documents.documentCount(for: .page), 1)
  }

  func testRemoteTombstonePreservesDivergentCanonicalNoteAsRecoveredRecord() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-note-recovery-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documents = LocalDocumentStore(rootURL: root)
    let document = try documents.save(kind: .note, title: "Concurrent note", body: "Original")
    let coordinator = DesktopSyncCoordinator(documentStore: documents, smokeTest: true)
    _ = await coordinator.synchronize(input: emptyInput(), fetchRemote: false)
    let storeURL = root.appendingPathComponent(".sync/sync-store.json")
    let initialSnapshot = await IAgentLocalSyncStore(fileURL: storeURL).snapshot()
    let original = try XCTUnwrap(initialSnapshot.notes.first { $0.title == "Concurrent note" })

    try "# Concurrent note\n\nLocal work must survive.\n".write(
      to: document.fileURL,
      atomically: true,
      encoding: .utf8
    )
    try await coordinator.mergeRemoteForTesting([
      IAgentSyncPayload.note(original).deleting(at: Date().addingTimeInterval(60))
    ])
    _ = await coordinator.synchronize(input: emptyInput(), fetchRemote: false)

    XCTAssertTrue(FileManager.default.fileExists(atPath: document.fileURL.path))
    XCTAssertTrue(
      try String(contentsOf: document.fileURL, encoding: .utf8).contains("Local work must survive")
    )
    let finalPayloads = await IAgentLocalSyncStore(fileURL: storeURL).allPayloads()
    let originalPayload = finalPayloads.first {
      $0.recordName == IAgentSyncPayload.note(original).recordName
    }
    let recovered = finalPayloads.compactMap { payload -> SyncedNote? in
      guard case let .note(note) = payload,
            note.id != original.id,
            note.deletedAt == nil,
            note.body.contains("Local work must survive")
      else { return nil }
      return note
    }.first
    XCTAssertNotNil(originalPayload?.deletedAt)
    XCTAssertNotNil(recovered)
  }

  func testDesktopNoteDeletionAlsoTombstonesLinkedMeetingTranscript() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-meeting-cascade-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documents = LocalDocumentStore(rootURL: root)
    let document = try documents.save(kind: .note, title: "Recorded sync", body: "Transcript")
    let coordinator = DesktopSyncCoordinator(documentStore: documents, smokeTest: true)
    _ = await coordinator.synchronize(input: emptyInput(), fetchRemote: false)

    let mirror = IAgentLocalSyncStore(fileURL: root.appendingPathComponent(".sync/sync-store.json"))
    let initialSnapshot = await mirror.snapshot()
    let note = try XCTUnwrap(initialSnapshot.notes.first { $0.title == "Recorded sync" })
    let meeting = SyncedMeetingSession(
      noteID: note.id,
      title: note.title,
      sourceDeviceID: "mac",
      state: .completed,
      transcriptSegments: [SyncedTranscriptSegment(source: .microphone, text: "Transcript")]
    )
    try await coordinator.mergeRemoteForTesting([.meetingSession(meeting)])
    try FileManager.default.removeItem(at: document.fileURL)
    _ = await coordinator.synchronize(input: emptyInput(), fetchRemote: false)

    let finalMirror = IAgentLocalSyncStore(
      fileURL: root.appendingPathComponent(".sync/sync-store.json")
    )
    let payloads = await finalMirror.allPayloads()
    let deletedNote = payloads.first { $0.recordName == IAgentSyncPayload.note(note).recordName }
    let deletedMeeting = payloads.first {
      $0.recordName == IAgentSyncPayload.meetingSession(meeting).recordName
    }
    XCTAssertNotNil(deletedNote?.deletedAt)
    XCTAssertNotNil(deletedMeeting?.deletedAt)
  }
}

private func transported<Value: Codable>(_ value: Value) throws -> Value {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.outputFormatting = [.sortedKeys]
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(Value.self, from: encoder.encode(value))
}

import Foundation
import XCTest
import iAgentCore

final class MessageSyncStoreTests: XCTestCase {
  func testMessageSyncWindowIncludesExactCutoffAndExcludesOlderDate() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let cutoff = MessageSyncWindow.cutoff(referenceDate: referenceDate)

    XCTAssertEqual(MessageSyncWindow.duration, 14 * 24 * 60 * 60)
    XCTAssertTrue(MessageSyncWindow.includes(date: cutoff, referenceDate: referenceDate))
    XCTAssertFalse(
      MessageSyncWindow.includes(
        date: cutoff.addingTimeInterval(-1),
        referenceDate: referenceDate
      )
    )
  }

  func testPayloadIdentityIsStableAcrossMessageEntityKinds() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let conversation = makeConversation(now: now)
    let message = makeMessage(now: now)
    let readState = makeReadState(now: now)
    let relayState = SyncedMessageRelayState(
      id: "mac-relay",
      phase: .available,
      detail: "Local relay",
      updatedAt: now
    )

    XCTAssertEqual(
      IAgentSyncPayload.messageConversation(conversation).recordName,
      "messageConversation_conversation-1"
    )
    XCTAssertEqual(IAgentSyncPayload.message(message).recordName, "message_message-1")
    XCTAssertEqual(
      IAgentSyncPayload.messageReadState(readState).recordName,
      "messageReadState_conversation-1"
    )
    XCTAssertEqual(
      IAgentSyncPayload.messageRelayState(relayState).recordName,
      "messageRelayState_mac-relay"
    )

    let deleted = IAgentSyncPayload.message(message).deleting(at: now.addingTimeInterval(1))
    XCTAssertEqual(deleted.recordName, "message_message-1")
    XCTAssertEqual(deleted.deletedAt, now.addingTimeInterval(1))
  }

  func testRetentionPhysicallyRemovesPersistedBodyAndQueuesCloudDeletions() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = Date()
    let message = makeMessage(
      body: "secret-expired-message-body",
      now: now.addingTimeInterval(-10 * 24 * 60 * 60)
    )
    let conversation = makeConversation(
      now: message.sentAt,
      preview: "secret-expired-message-body"
    )
    let readState = makeReadState(now: message.sentAt)
    let relayState = SyncedMessageRelayState(
      id: "mac-relay",
      phase: .available,
      detail: "Local relay",
      updatedAt: message.sentAt
    )
    try await fixture.store.upsertLocal([
      .messageConversation(conversation),
      .message(message),
      .messageReadState(readState),
      .messageRelayState(relayState),
    ])

    XCTAssertTrue(
      try String(contentsOf: fixture.fileURL, encoding: .utf8)
        .contains("secret-expired-message-body")
    )

    let expiredReferenceDate = now.addingTimeInterval(5 * 24 * 60 * 60)
    let deletedNames = Set(
      try await fixture.store.enforceMessageRetention(referenceDate: expiredReferenceDate)
    )
    let expectedNames: Set<String> = [
      IAgentSyncPayload.message(message).recordName,
      IAgentSyncPayload.messageConversation(conversation).recordName,
      IAgentSyncPayload.messageReadState(readState).recordName,
    ]
    XCTAssertEqual(deletedNames, expectedNames)
    let pendingDeletionNames = await fixture.store.pendingDeletionRecordNames()
    let pendingSaveNames = await fixture.store.pendingRecordNames()
    XCTAssertEqual(Set(pendingDeletionNames), expectedNames)
    XCTAssertEqual(pendingSaveNames, [IAgentSyncPayload.messageRelayState(relayState).recordName])

    let persisted = try String(contentsOf: fixture.fileURL, encoding: .utf8)
    XCTAssertFalse(persisted.contains("secret-expired-message-body"))
    let snapshot = await fixture.store.snapshot(referenceDate: expiredReferenceDate)
    XCTAssertTrue(snapshot.messages.isEmpty)
    XCTAssertTrue(snapshot.messageConversations.isEmpty)
    XCTAssertTrue(snapshot.messageReadStates.isEmpty)
    XCTAssertEqual(snapshot.messageRelayStates.map(\.id), [relayState.id])
  }

  func testDeleteLocalPhysicallyRemovesRemoteBaseAndSystemFields() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let payload = IAgentSyncPayload.message(makeMessage(now: freshDate()))
    _ = try await fixture.store.mergeRemote(payload, cloudSystemFields: Data([1, 2, 3]))
    try await fixture.store.deleteLocal(recordName: payload.recordName)

    let storedPayload = await fixture.store.payload(for: payload.recordName)
    let systemFields = await fixture.store.cloudSystemFields(for: payload.recordName)
    let pendingSaveNames = await fixture.store.pendingRecordNames()
    let pendingDeletionNames = await fixture.store.pendingDeletionRecordNames()
    XCTAssertNil(storedPayload)
    XCTAssertNil(systemFields)
    XCTAssertFalse(pendingSaveNames.contains(payload.recordName))
    XCTAssertTrue(pendingDeletionNames.contains(payload.recordName))
  }

  func testStaleRemoteMessageIsRejectedAndOrphanConversationIsRemoved() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let staleDate = Date().addingTimeInterval(-(MessageSyncWindow.duration + 3_600))
    let conversation = makeConversation(now: staleDate, preview: "stale-secret")
    let message = makeMessage(body: "stale-secret", now: staleDate)
    try await fixture.store.upsertLocal(.messageConversation(conversation))

    let newlyPending = try await fixture.store.mergeRemote(
      .message(message),
      cloudSystemFields: Data([4, 5, 6])
    )

    XCTAssertTrue(newlyPending.isEmpty)
    let storedMessage = await fixture.store.payload(
      for: IAgentSyncPayload.message(message).recordName
    )
    let storedConversation = await fixture.store.payload(
      for: IAgentSyncPayload.messageConversation(conversation).recordName
    )
    let pendingDeletionNames = await fixture.store.pendingDeletionRecordNames()
    XCTAssertNil(storedMessage)
    XCTAssertNil(storedConversation)
    XCTAssertEqual(
      Set(pendingDeletionNames),
      Set([
        IAgentSyncPayload.message(message).recordName,
        IAgentSyncPayload.messageConversation(conversation).recordName,
      ])
    )
    XCTAssertFalse(
      try String(contentsOf: fixture.fileURL, encoding: .utf8).contains("stale-secret")
    )
  }

  func testDeletingLastRetainedMessageRemovesConversationAndReadState() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let conversation = makeConversation(now: now)
    let message = makeMessage(now: now)
    let readState = makeReadState(now: now)
    try await fixture.store.upsertLocal([
      .messageConversation(conversation),
      .message(message),
      .messageReadState(readState),
    ])

    try await fixture.store.deleteLocal(recordName: IAgentSyncPayload.message(message).recordName)

    let snapshot = await fixture.store.snapshot(referenceDate: now)
    XCTAssertTrue(snapshot.messages.isEmpty)
    XCTAssertTrue(snapshot.messageConversations.isEmpty)
    XCTAssertTrue(snapshot.messageReadStates.isEmpty)
    let pendingDeletionNames = await fixture.store.pendingDeletionRecordNames()
    XCTAssertEqual(
      Set(pendingDeletionNames),
      Set([
        IAgentSyncPayload.message(message).recordName,
        IAgentSyncPayload.messageConversation(conversation).recordName,
        IAgentSyncPayload.messageReadState(readState).recordName,
      ])
    )
  }

  func testDeletingLatestMessageRebuildsPersistedConversationSummaryAndReadCursor() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let olderMessage = makeMessage(
      id: "message-older",
      body: "remaining-message-body",
      now: now.addingTimeInterval(-60)
    )
    let latestMessage = makeMessage(
      id: "message-latest",
      body: "deleted-latest-secret",
      now: now
    )
    let conversation = makeConversation(
      now: latestMessage.sentAt,
      preview: latestMessage.body,
      latestMessageID: latestMessage.id
    )
    let readState = SyncedMessageReadState(
      id: conversation.id,
      readThroughMessageID: latestMessage.id,
      readThroughDate: latestMessage.sentAt,
      latestKnownMessageDate: latestMessage.sentAt,
      updatedAt: now,
      sourceDeviceID: "mac"
    )
    let remotePayloads: [IAgentSyncPayload] = [
      IAgentSyncPayload.messageConversation(conversation),
      .message(olderMessage),
      .message(latestMessage),
      .messageReadState(readState),
    ]
    _ = try await fixture.store.applyRemoteChanges(
      remotePayloads.map {
        IAgentFetchedRecord(payload: $0, cloudSystemFields: Data([7, 8, 9]))
      },
      deletedRecordNames: [],
      referenceDate: now
    )

    try await fixture.store.deleteLocal(
      recordName: IAgentSyncPayload.message(latestMessage).recordName
    )

    let snapshot = await fixture.store.snapshot(referenceDate: now)
    XCTAssertEqual(snapshot.messages.map(\.id), [olderMessage.id])
    XCTAssertEqual(snapshot.messageConversations.first?.latestMessageID, olderMessage.id)
    XCTAssertEqual(snapshot.messageConversations.first?.latestMessageDate, olderMessage.sentAt)
    XCTAssertEqual(snapshot.messageConversations.first?.latestPreview, olderMessage.body)
    XCTAssertEqual(snapshot.messageReadStates.first?.readThroughMessageID, olderMessage.id)
    XCTAssertEqual(snapshot.messageReadStates.first?.readThroughDate, olderMessage.sentAt)
    XCTAssertEqual(snapshot.messageReadStates.first?.latestKnownMessageDate, olderMessage.sentAt)

    let persisted = try String(contentsOf: fixture.fileURL, encoding: .utf8)
    XCTAssertFalse(persisted.contains("deleted-latest-secret"))
    XCTAssertTrue(persisted.contains("remaining-message-body"))
  }

  func testDeletingAwaitingReplyMessageClearsConversationReference() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let awaitingMessage = makeMessage(
      id: "message-awaiting",
      body: "unanswered inbound",
      now: now.addingTimeInterval(-60)
    )
    let latestMessage = makeMessage(
      id: "message-latest",
      body: "non-text summary placeholder",
      now: now
    )
    let conversation = makeConversation(
      now: latestMessage.sentAt,
      preview: latestMessage.body,
      latestMessageID: latestMessage.id,
      awaitingReplyMessageID: awaitingMessage.id
    )
    let remotePayloads: [IAgentSyncPayload] = [
      IAgentSyncPayload.messageConversation(conversation),
      .message(awaitingMessage),
      .message(latestMessage),
    ]
    _ = try await fixture.store.applyRemoteChanges(
      remotePayloads.map {
        IAgentFetchedRecord(payload: $0, cloudSystemFields: Data([1]))
      },
      deletedRecordNames: [],
      referenceDate: now
    )

    try await fixture.store.deleteLocal(
      recordName: IAgentSyncPayload.message(awaitingMessage).recordName
    )

    let snapshot = await fixture.store.snapshot(referenceDate: now)
    XCTAssertEqual(snapshot.messageConversations.first?.latestMessageID, latestMessage.id)
    XCTAssertNil(snapshot.messageConversations.first?.awaitingReplyMessageID)
    let reloadedStore = IAgentLocalSyncStore(fileURL: fixture.fileURL)
    let reloadedSnapshot = await reloadedStore.snapshot(referenceDate: now)
    XCTAssertNil(reloadedSnapshot.messageConversations.first?.awaitingReplyMessageID)
  }

  func testMessageTombstoneBecomesPhysicalDeletionWithoutPersistingBody() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let message = makeMessage(body: "body-that-must-be-removed", now: now)
    let payload = IAgentSyncPayload.message(message)
    try await fixture.store.upsertLocal(payload)
    try await fixture.store.upsertLocal(payload.deleting(at: now.addingTimeInterval(1)))

    let remoteMessage = makeMessage(
      id: "remote-tombstone",
      body: "remote-body-that-must-be-removed",
      now: now
    )
    let remotePayload = IAgentSyncPayload.message(remoteMessage)
      .deleting(at: now.addingTimeInterval(1))
    _ = try await fixture.store.mergeRemote(remotePayload, cloudSystemFields: Data([1]))

    let storedPayload = await fixture.store.payload(for: payload.recordName)
    let pendingDeletionNames = await fixture.store.pendingDeletionRecordNames()
    XCTAssertNil(storedPayload)
    XCTAssertTrue(pendingDeletionNames.contains(payload.recordName))
    XCTAssertTrue(pendingDeletionNames.contains(remotePayload.recordName))
    let persisted = try String(contentsOf: fixture.fileURL, encoding: .utf8)
    XCTAssertFalse(persisted.contains("body-that-must-be-removed"))
    XCTAssertFalse(persisted.contains("remote-body-that-must-be-removed"))
  }

  func testReadStateMergeNeverRegressesWithoutPendingLocalWrite() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let earlierMessage = makeMessage(id: "message-a", now: now.addingTimeInterval(-40))
    let laterMessage = makeMessage(id: "message-z", now: now.addingTimeInterval(-10))
    let conversation = makeConversation(now: laterMessage.sentAt, latestMessageID: laterMessage.id)
    try await fixture.store.upsertLocal([
      .messageConversation(conversation),
      .message(earlierMessage),
      .message(laterMessage),
    ])

    let local = SyncedMessageReadState(
      id: conversation.id,
      readThroughMessageID: laterMessage.id,
      readThroughDate: laterMessage.sentAt,
      latestKnownMessageDate: laterMessage.sentAt,
      updatedAt: now,
      sourceDeviceID: "iphone"
    )
    let localPayload = IAgentSyncPayload.messageReadState(local)
    try await fixture.store.upsertLocal(localPayload)
    try await fixture.store.markSent(
      recordName: localPayload.recordName,
      sentPayload: localPayload,
      cloudSystemFields: nil
    )

    let remote = SyncedMessageReadState(
      id: conversation.id,
      readThroughMessageID: earlierMessage.id,
      readThroughDate: earlierMessage.sentAt,
      latestKnownMessageDate: now.addingTimeInterval(30),
      updatedAt: now.addingTimeInterval(60),
      sourceDeviceID: "mac"
    )
    let pending = try await fixture.store.mergeRemote(
      .messageReadState(remote),
      cloudSystemFields: nil
    )
    try await fixture.store.enforceMessageRetention(referenceDate: now)

    guard case let .messageReadState(merged)? = await fixture.store.payload(
      for: localPayload.recordName
    ) else {
      return XCTFail("Expected a merged message read state")
    }
    XCTAssertEqual(merged.readThroughDate, laterMessage.sentAt)
    XCTAssertEqual(merged.readThroughMessageID, laterMessage.id)
    XCTAssertEqual(merged.sourceDeviceID, "iphone")
    XCTAssertEqual(merged.latestKnownMessageDate, laterMessage.sentAt)
    XCTAssertEqual(merged.updatedAt, remote.updatedAt)
    XCTAssertEqual(pending, [localPayload.recordName])
  }

  func testLocalMessageAuthorityRejectsRemoteProjectionRegressionAfterAcknowledgement() async throws {
    let fixture = makeStoreFixture(messageProjectionRole: .localAuthority)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let decodedMessage = makeMessage(body: "Decoded body", now: now)
    let namedConversation = SyncedMessageConversation(
      id: "conversation-1",
      displayName: "Maya",
      participants: [
        SyncedMessageParticipant(id: "participant-1", displayName: "Maya")
      ],
      isGroup: false,
      serviceName: "iMessage",
      latestMessageID: decodedMessage.id,
      latestMessageDate: decodedMessage.sentAt,
      latestPreview: decodedMessage.body,
      updatedAt: now
    )
    let localPayloads: [IAgentSyncPayload] = [
      .messageConversation(namedConversation),
      .message(decodedMessage),
    ]
    try await fixture.store.upsertLocal(localPayloads)
    try await fixture.store.markSent(
      localPayloads.map { sentRecord($0, cloudSystemFields: Data([1])) },
      at: now
    )
    let pendingAfterAcknowledgement = await fixture.store.pendingRecordNames()
    XCTAssertTrue(pendingAfterAcknowledgement.isEmpty)

    var genericConversation = namedConversation
    genericConversation.displayName = "Conversation"
    genericConversation.participants = [
      SyncedMessageParticipant(id: "participant-1", displayName: "Contact")
    ]
    genericConversation.latestPreview = "Message"
    var placeholderMessage = decodedMessage
    placeholderMessage.body = "Message"

    let staleRemote: [IAgentFetchedRecord] = [
      .init(payload: .messageConversation(genericConversation), cloudSystemFields: Data([2])),
      .init(payload: .message(placeholderMessage), cloudSystemFields: Data([3])),
    ]
    let newlyPending = try await fixture.store.applyRemoteChanges(
      staleRemote,
      deletedRecordNames: [],
      referenceDate: now
    )

    let snapshot = await fixture.store.snapshot(referenceDate: now)
    XCTAssertEqual(snapshot.messageConversations.first?.displayName, "Maya")
    XCTAssertEqual(snapshot.messageConversations.first?.latestPreview, "Decoded body")
    XCTAssertEqual(snapshot.messages.first?.body, "Decoded body")
    XCTAssertEqual(Set(newlyPending), Set(localPayloads.map(\.recordName)))
    let pendingAfterRegression = await fixture.store.pendingRecordNames()
    XCTAssertEqual(
      Set(pendingAfterRegression),
      Set(localPayloads.map(\.recordName))
    )
  }

  func testLocalMessageAuthorityAcknowledgesRepeatedTransportEquivalentFractionalFetch() async throws {
    let fixture = makeStoreFixture(messageProjectionRole: .localAuthority)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let wholeSeconds = floor(Date().timeIntervalSince1970) - 120
    let sentAt = Date(timeIntervalSince1970: wholeSeconds + 0.875)
    let message = makeMessage(id: "message-fractional", body: "Decoded body", now: sentAt)
    let conversation = makeConversation(
      now: sentAt,
      preview: message.body,
      latestMessageID: message.id,
      awaitingReplyMessageID: message.id
    )
    let localPayloads: [IAgentSyncPayload] = [
      .messageConversation(conversation),
      .message(message),
    ]
    try await fixture.store.upsertLocal(localPayloads)
    try await fixture.store.markSent(localPayloads.map { sentRecord($0) }, at: sentAt)

    var remoteMessage = try transported(message)
    remoteMessage.updatedAt = sentAt.addingTimeInterval(60)
    var remoteConversation = try transported(conversation)
    remoteConversation.updatedAt = remoteMessage.updatedAt
    let fetched = [
      IAgentFetchedRecord(
        payload: .messageConversation(remoteConversation),
        cloudSystemFields: nil
      ),
      IAgentFetchedRecord(payload: .message(remoteMessage), cloudSystemFields: nil),
    ]

    let firstPending = try await fixture.store.applyRemoteChanges(
      fetched,
      deletedRecordNames: [],
      referenceDate: sentAt
    )
    let secondPending = try await fixture.store.applyRemoteChanges(
      fetched,
      deletedRecordNames: [],
      referenceDate: sentAt
    )

    XCTAssertTrue(firstPending.isEmpty)
    XCTAssertTrue(secondPending.isEmpty)
    let pendingRecordNames = await fixture.store.pendingRecordNames()
    XCTAssertEqual(pendingRecordNames, [])
    let snapshot = await fixture.store.snapshot(referenceDate: sentAt)
    XCTAssertEqual(snapshot.messages.first?.sentAt, message.sentAt)
    XCTAssertEqual(snapshot.messages.first?.updatedAt, remoteMessage.updatedAt)
    XCTAssertEqual(snapshot.messageConversations.first?.awaitingReplyMessageID, message.id)
    XCTAssertEqual(snapshot.messageConversations.first?.updatedAt, remoteConversation.updatedAt)
  }

  func testLocalMessageAuthorityQueuesGenuineProviderProjectionDifferenceOnce() async throws {
    let fixture = makeStoreFixture(messageProjectionRole: .localAuthority)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let message = makeMessage(id: "message-source", body: "Decoded body", now: now)
    let conversation = makeConversation(
      now: now,
      preview: message.body,
      latestMessageID: message.id,
      awaitingReplyMessageID: message.id
    )
    let localPayloads: [IAgentSyncPayload] = [
      .messageConversation(conversation),
      .message(message),
    ]
    try await fixture.store.upsertLocal(localPayloads)
    try await fixture.store.markSent(localPayloads.map { sentRecord($0) })

    var remoteMessage = try transported(message)
    remoteMessage.body = "Message"
    remoteMessage.updatedAt = now.addingTimeInterval(30)
    var remoteConversation = try transported(conversation)
    remoteConversation.displayName = "Conversation"
    remoteConversation.latestPreview = remoteMessage.body
    remoteConversation.awaitingReplyMessageID = nil
    remoteConversation.updatedAt = remoteMessage.updatedAt
    let fetched = [
      IAgentFetchedRecord(
        payload: .messageConversation(remoteConversation),
        cloudSystemFields: nil
      ),
      IAgentFetchedRecord(payload: .message(remoteMessage), cloudSystemFields: nil),
    ]

    _ = try await fixture.store.applyRemoteChanges(
      fetched,
      deletedRecordNames: [],
      referenceDate: now
    )
    _ = try await fixture.store.applyRemoteChanges(
      fetched,
      deletedRecordNames: [],
      referenceDate: now
    )

    let pendingRecordNames = await fixture.store.pendingRecordNames()
    XCTAssertEqual(
      Set(pendingRecordNames),
      Set(localPayloads.map(\.recordName))
    )
    let snapshot = await fixture.store.snapshot(referenceDate: now)
    XCTAssertEqual(snapshot.messages.first?.body, message.body)
    XCTAssertEqual(snapshot.messageConversations.first?.displayName, conversation.displayName)
    XCTAssertEqual(snapshot.messageConversations.first?.awaitingReplyMessageID, message.id)
    XCTAssertEqual(snapshot.messages.first?.updatedAt, remoteMessage.updatedAt)
  }

  func testReadCursorAcknowledgesTransportEquivalentFractionalDateAndSourceMetadata() async throws {
    let fixture = makeStoreFixture(messageProjectionRole: .localAuthority)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let wholeSeconds = floor(Date().timeIntervalSince1970) - 60
    let sentAt = Date(timeIntervalSince1970: wholeSeconds + 0.625)
    let message = makeMessage(id: "message-read", now: sentAt)
    let conversation = makeConversation(now: sentAt, latestMessageID: message.id)
    let localReadState = SyncedMessageReadState(
      id: conversation.id,
      readThroughMessageID: message.id,
      readThroughDate: sentAt,
      latestKnownMessageDate: sentAt,
      updatedAt: sentAt,
      sourceDeviceID: "mac"
    )
    let initialPayloads: [IAgentSyncPayload] = [
      .messageConversation(conversation),
      .message(message),
      .messageReadState(localReadState),
    ]
    try await fixture.store.upsertLocal(initialPayloads)
    try await fixture.store.markSent(initialPayloads.map { sentRecord($0) })

    var remoteReadState = try transported(localReadState)
    remoteReadState.updatedAt = sentAt.addingTimeInterval(30)
    remoteReadState.sourceDeviceID = "iphone"
    let fetched = [
      IAgentFetchedRecord(
        payload: .messageReadState(remoteReadState),
        cloudSystemFields: nil
      )
    ]
    let firstPending = try await fixture.store.applyRemoteChanges(
      fetched,
      deletedRecordNames: [],
      referenceDate: sentAt
    )
    let secondPending = try await fixture.store.applyRemoteChanges(
      fetched,
      deletedRecordNames: [],
      referenceDate: sentAt
    )

    XCTAssertTrue(firstPending.isEmpty)
    XCTAssertTrue(secondPending.isEmpty)
    let pendingRecordNames = await fixture.store.pendingRecordNames()
    XCTAssertEqual(pendingRecordNames, [])
    let snapshot = await fixture.store.snapshot(referenceDate: sentAt)
    XCTAssertEqual(snapshot.messageReadStates.first?.readThroughMessageID, message.id)
    XCTAssertEqual(snapshot.messageReadStates.first?.updatedAt, remoteReadState.updatedAt)
  }

  func testLocalMessageAuthorityDoesNotChangeReadStateReconciliation() async throws {
    let fixture = makeStoreFixture(messageProjectionRole: .localAuthority)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let earlier = makeMessage(id: "message-a", now: now.addingTimeInterval(-60))
    let later = makeMessage(id: "message-z", now: now)
    let conversation = makeConversation(now: now, latestMessageID: later.id)
    let localReadState = SyncedMessageReadState(
      id: conversation.id,
      readThroughMessageID: earlier.id,
      readThroughDate: earlier.sentAt,
      latestKnownMessageDate: later.sentAt,
      updatedAt: now,
      sourceDeviceID: "mac"
    )
    try await fixture.store.upsertLocal([
      .messageConversation(conversation),
      .message(earlier),
      .message(later),
      .messageReadState(localReadState),
    ])
    let localPayload = IAgentSyncPayload.messageReadState(localReadState)
    try await fixture.store.markSent(
      recordName: localPayload.recordName,
      sentPayload: localPayload,
      cloudSystemFields: nil
    )

    let remoteReadState = SyncedMessageReadState(
      id: conversation.id,
      readThroughMessageID: later.id,
      readThroughDate: later.sentAt,
      latestKnownMessageDate: later.sentAt,
      updatedAt: now.addingTimeInterval(1),
      sourceDeviceID: "iphone"
    )
    _ = try await fixture.store.mergeRemote(
      .messageReadState(remoteReadState),
      cloudSystemFields: nil
    )

    let snapshot = await fixture.store.snapshot(referenceDate: now)
    XCTAssertEqual(snapshot.messageReadStates, [remoteReadState])
  }

  func testSentRecordBatchPersistsOnceAndAcknowledgesEveryRecord() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let messagePayloads = (0..<200).map { index in
      IAgentSyncPayload.message(
        makeMessage(
          id: "message-\(index)",
          body: "Body \(index)",
          now: now.addingTimeInterval(Double(index - 199))
        )
      )
    }
    let payloads = [IAgentSyncPayload.messageConversation(
      makeConversation(now: now, preview: "Body 199", latestMessageID: "message-199")
    )] + messagePayloads
    try await fixture.store.upsertLocal(payloads)

    let notificationCount = NotificationCounter()
    let observer = NotificationCenter.default.addObserver(
      forName: .iAgentSyncStoreDidChange,
      object: nil,
      queue: nil
    ) { _ in
      notificationCount.increment()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    let sentRecords = payloads.enumerated().map { index, payload in
      sentRecord(payload, cloudSystemFields: Data([UInt8(index % 255)]))
    }
    try await fixture.store.markSent(sentRecords, at: now)

    let pendingRecordNames = await fixture.store.pendingRecordNames()
    let lastSystemFields = await fixture.store.cloudSystemFields(
      for: payloads.last!.recordName
    )
    XCTAssertEqual(notificationCount.value, 1)
    XCTAssertEqual(pendingRecordNames, [])
    XCTAssertEqual(lastSystemFields, Data([UInt8((payloads.count - 1) % 255)]))
  }

  func testFetchedRecordBatchMergesAndDeletesWithOnePersistence() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let removedRelay = SyncedMessageRelayState(
      id: "removed-relay",
      phase: .available,
      updatedAt: now.addingTimeInterval(-60)
    )
    let removedRelayPayload = IAgentSyncPayload.messageRelayState(removedRelay)
    try await fixture.store.upsertLocal(removedRelayPayload)
    try await fixture.store.markSent(
      recordName: removedRelayPayload.recordName,
      sentPayload: removedRelayPayload,
      cloudSystemFields: Data([0])
    )

    let messages = (0..<200).map { index in
      makeMessage(
        id: "message-\(index)",
        body: "Body \(index)",
        now: now.addingTimeInterval(Double(index - 199))
      )
    }
    let conversation = makeConversation(
      now: now,
      preview: "Body 199",
      latestMessageID: "message-199"
    )
    let readState = SyncedMessageReadState(
      id: conversation.id,
      readThroughMessageID: "message-150",
      readThroughDate: messages[150].sentAt,
      latestKnownMessageDate: now,
      updatedAt: now,
      sourceDeviceID: "remote-mac"
    )
    let remotePayloads = [IAgentSyncPayload.messageConversation(conversation)]
      + messages.map(IAgentSyncPayload.message)
      + [IAgentSyncPayload.messageReadState(readState)]
    let fetchedRecords = remotePayloads.enumerated().map { index, payload in
      IAgentFetchedRecord(
        payload: payload,
        cloudSystemFields: Data([UInt8(index % 255)])
      )
    }

    let notificationCount = NotificationCounter()
    let observer = NotificationCenter.default.addObserver(
      forName: .iAgentSyncStoreDidChange,
      object: nil,
      queue: nil
    ) { _ in
      notificationCount.increment()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    let newlyPending = try await fixture.store.applyRemoteChanges(
      fetchedRecords,
      deletedRecordNames: [removedRelayPayload.recordName],
      referenceDate: now
    )

    let snapshot = await fixture.store.snapshot(referenceDate: now)
    let pendingRecordNames = await fixture.store.pendingRecordNames()
    let pendingDeletionNames = await fixture.store.pendingDeletionRecordNames()
    let removedRelayAfterMerge = await fixture.store.payload(
      for: removedRelayPayload.recordName
    )
    let lastSystemFields = await fixture.store.cloudSystemFields(
      for: remotePayloads.last!.recordName
    )
    XCTAssertEqual(notificationCount.value, 1)
    XCTAssertTrue(newlyPending.isEmpty)
    XCTAssertTrue(pendingRecordNames.isEmpty)
    XCTAssertTrue(pendingDeletionNames.isEmpty)
    XCTAssertNil(removedRelayAfterMerge)
    XCTAssertEqual(snapshot.messages.count, messages.count)
    XCTAssertEqual(snapshot.messageConversations, [conversation])
    XCTAssertEqual(snapshot.messageReadStates, [readState])
    XCTAssertEqual(lastSystemFields, Data([UInt8((remotePayloads.count - 1) % 255)]))
  }

  func testPersistedStateMigratesWhenPendingDeletionFieldIsMissing() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let conversation = makeConversation(now: now)
    let message = makeMessage(now: now)
    try await fixture.store.upsertLocal([
      .messageConversation(conversation),
      .message(message),
    ])

    let encoded = try Data(contentsOf: fixture.fileURL)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "pendingDeletionRecordNames")
    let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try legacyData.write(to: fixture.fileURL, options: .atomic)

    let migratedStore = IAgentLocalSyncStore(fileURL: fixture.fileURL)
    let pendingDeletionNames = await migratedStore.pendingDeletionRecordNames()
    XCTAssertTrue(pendingDeletionNames.isEmpty)
    let snapshot = await migratedStore.snapshot(referenceDate: now)
    XCTAssertEqual(snapshot.messages.map(\.id), [message.id])
    XCTAssertEqual(snapshot.messageConversations.map(\.id), [conversation.id])
  }

  func testAtomicLocalStagingDoesNotRequeueAnAcknowledgedIdenticalMessage() async throws {
    let fixture = makeStoreFixture(messageProjectionRole: .localAuthority)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let payload = IAgentSyncPayload.message(makeMessage(now: freshDate()))
    _ = try await fixture.store.mergeRemote(payload, cloudSystemFields: Data([1, 2, 3]))

    let changed = try await fixture.store.stageLocalChanges([payload])

    XCTAssertFalse(changed)
    let pendingRecordNames = await fixture.store.pendingRecordNames()
    XCTAssertTrue(pendingRecordNames.isEmpty)
  }

  func testStoreLoadRemovesLegacyPendingMessageAndConversationMatchingCloudBase() async throws {
    let fixture = makeStoreFixture(messageProjectionRole: .localAuthority)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let message = makeMessage(now: now)
    let conversation = makeConversation(now: now, latestMessageID: message.id)
    let payloads: [IAgentSyncPayload] = [
      .message(message),
      .messageConversation(conversation),
    ]
    _ = try await fixture.store.applyRemoteChanges(
      payloads.map {
        IAgentFetchedRecord(payload: $0, cloudSystemFields: Data([4, 5, 6]))
      },
      deletedRecordNames: [],
      referenceDate: now
    )

    let encoded = try Data(contentsOf: fixture.fileURL)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["pendingRecordNames"] = payloads.map(\.recordName)
    let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try legacyData.write(to: fixture.fileURL, options: .atomic)

    let migratedStore = IAgentLocalSyncStore(
      fileURL: fixture.fileURL,
      messageProjectionRole: .localAuthority
    )
    let pendingRecordNames = await migratedStore.pendingRecordNames()
    XCTAssertTrue(pendingRecordNames.isEmpty)
    for payload in payloads {
      let storedPayload = await migratedStore.payload(for: payload.recordName)
      XCTAssertEqual(storedPayload, try transported(payload))
    }
  }

  func testBatchedAcknowledgementPreservesEditMadeWhileUploadWasInFlight() async throws {
    let fixture = makeStoreFixture(messageProjectionRole: .localAuthority)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let original = IAgentSyncPayload.message(
      makeMessage(body: "body sent to CloudKit", now: now)
    )
    try await fixture.store.upsertLocal(original)

    var editedMessage = makeMessage(body: "body sent to CloudKit", now: now)
    editedMessage.body = "edit made during upload"
    editedMessage.updatedAt = now.addingTimeInterval(10)
    let edited = IAgentSyncPayload.message(editedMessage)
    try await fixture.store.upsertLocal(edited)

    try await fixture.store.markSent([
      sentRecord(original, cloudSystemFields: Data([9, 9, 9]))
    ])

    let stored = await fixture.store.payload(for: edited.recordName)
    let pending = await fixture.store.pendingRecordNames()
    XCTAssertEqual(stored, edited)
    XCTAssertEqual(pending, [edited.recordName])

    let reloadedStore = IAgentLocalSyncStore(
      fileURL: fixture.fileURL,
      messageProjectionRole: .localAuthority
    )
    let reloadedPayload = await reloadedStore.payload(for: edited.recordName)
    let reloadedPending = await reloadedStore.pendingRecordNames()
    XCTAssertEqual(reloadedPayload, edited)
    XCTAssertEqual(reloadedPending, [edited.recordName])
  }

  func testRemoteDeletionPreservesNewerUnsentLocalEdit() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let remote = IAgentSyncPayload.message(makeMessage(body: "server body", now: now))
    _ = try await fixture.store.mergeRemote(remote, cloudSystemFields: Data([1, 2]))

    var editedMessage = makeMessage(body: "server body", now: now)
    editedMessage.body = "unsent local edit"
    editedMessage.updatedAt = now.addingTimeInterval(15)
    let edited = IAgentSyncPayload.message(editedMessage)
    try await fixture.store.upsertLocal(edited)

    let newlyPending = try await fixture.store.applyRemoteChanges(
      [],
      deletedRecordNames: [remote.recordName],
      referenceDate: now
    )

    let storedPayload = await fixture.store.payload(for: remote.recordName)
    let pendingRecordNames = await fixture.store.pendingRecordNames()
    let pendingDeletionNames = await fixture.store.pendingDeletionRecordNames()
    let cloudSystemFields = await fixture.store.cloudSystemFields(for: remote.recordName)
    XCTAssertEqual(storedPayload, edited)
    XCTAssertEqual(pendingRecordNames, [remote.recordName])
    XCTAssertTrue(pendingDeletionNames.isEmpty)
    XCTAssertNil(cloudSystemFields)
    XCTAssertEqual(newlyPending, [remote.recordName])
  }

  func testPendingPhysicalDeletionRejectsConcurrentRemoteSave() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let payload = IAgentSyncPayload.message(makeMessage(body: "delete me", now: now))
    _ = try await fixture.store.mergeRemote(payload, cloudSystemFields: Data([1]))
    try await fixture.store.deleteLocal(recordName: payload.recordName)

    var staleRemoteMessage = makeMessage(body: "delete me", now: now)
    staleRemoteMessage.body = "stale server resurrection"
    staleRemoteMessage.updatedAt = now.addingTimeInterval(30)
    let staleRemote = IAgentSyncPayload.message(staleRemoteMessage)
    let newlyPending = try await fixture.store.applyRemoteChanges(
      [IAgentFetchedRecord(payload: staleRemote, cloudSystemFields: Data([2]))],
      deletedRecordNames: [],
      referenceDate: now
    )

    XCTAssertTrue(newlyPending.isEmpty)
    let storedPayload = await fixture.store.payload(for: payload.recordName)
    let pendingRecordNames = await fixture.store.pendingRecordNames()
    let pendingDeletionNames = await fixture.store.pendingDeletionRecordNames()
    XCTAssertNil(storedPayload)
    XCTAssertTrue(pendingRecordNames.isEmpty)
    XCTAssertEqual(pendingDeletionNames, [payload.recordName])
    let persisted = try String(contentsOf: fixture.fileURL, encoding: .utf8)
    XCTAssertFalse(persisted.contains("stale server resurrection"))
  }

  func testStaleDeleteAcknowledgementAndFailureDoNotEraseRestagedProjection() async throws {
    let fixture = makeStoreFixture(messageProjectionRole: .localAuthority)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let original = IAgentSyncPayload.message(makeMessage(body: "old projection", now: now))
    _ = try await fixture.store.mergeRemote(original, cloudSystemFields: Data([1]))
    try await fixture.store.deleteLocal(recordName: original.recordName)

    var replacementMessage = makeMessage(body: "old projection", now: now)
    replacementMessage.body = "restaged projection"
    replacementMessage.updatedAt = now.addingTimeInterval(20)
    let replacement = IAgentSyncPayload.message(replacementMessage)
    try await fixture.store.upsertLocal(replacement)

    // These callbacks belong to the obsolete delete request. Once the record was
    // restaged, neither the old success nor old failure may mutate it.
    try await fixture.store.acknowledgeDeletion(recordName: replacement.recordName)
    try await fixture.store.requeueDeletion(recordName: replacement.recordName)

    let storedPayload = await fixture.store.payload(for: replacement.recordName)
    let pendingRecordNames = await fixture.store.pendingRecordNames()
    let pendingDeletionNames = await fixture.store.pendingDeletionRecordNames()
    XCTAssertEqual(storedPayload, replacement)
    XCTAssertEqual(pendingRecordNames, [replacement.recordName])
    XCTAssertTrue(pendingDeletionNames.isEmpty)
  }

  func testRetentionRepairStaysPendingAcrossReloadUntilExactAcknowledgement() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let now = freshDate()
    let olderMessage = makeMessage(
      id: "message-retained",
      body: "retained body",
      now: now.addingTimeInterval(-120)
    )
    let latestMessage = makeMessage(
      id: "message-to-delete",
      body: "secret body removed by retention repair",
      now: now.addingTimeInterval(-60)
    )
    let conversation = makeConversation(
      now: latestMessage.sentAt,
      preview: latestMessage.body,
      latestMessageID: latestMessage.id
    )
    let readState = SyncedMessageReadState(
      id: conversation.id,
      readThroughMessageID: latestMessage.id,
      readThroughDate: latestMessage.sentAt,
      latestKnownMessageDate: latestMessage.sentAt,
      updatedAt: now,
      sourceDeviceID: "mac"
    )
    let remotePayloads: [IAgentSyncPayload] = [
      .message(olderMessage),
      .message(latestMessage),
      .messageConversation(conversation),
      .messageReadState(readState),
    ]
    _ = try await fixture.store.applyRemoteChanges(
      remotePayloads.map {
        IAgentFetchedRecord(payload: $0, cloudSystemFields: Data([4, 2]))
      },
      deletedRecordNames: [],
      referenceDate: now
    )

    try await fixture.store.deleteLocal(
      recordName: IAgentSyncPayload.message(latestMessage).recordName
    )

    let conversationName = IAgentSyncPayload.messageConversation(conversation).recordName
    let readStateName = IAgentSyncPayload.messageReadState(readState).recordName
    let storedConversation = await fixture.store.payload(for: conversationName)
    let storedReadState = await fixture.store.payload(for: readStateName)
    let repairedConversation = try XCTUnwrap(storedConversation)
    let repairedReadState = try XCTUnwrap(storedReadState)
    let pendingAfterRepair = await fixture.store.pendingRecordNames()
    let conversationSystemFields = await fixture.store.cloudSystemFields(
      for: conversationName
    )
    let readStateSystemFields = await fixture.store.cloudSystemFields(for: readStateName)
    XCTAssertEqual(
      Set(pendingAfterRepair),
      Set([conversationName, readStateName])
    )
    XCTAssertNil(conversationSystemFields)
    XCTAssertNil(readStateSystemFields)
    XCTAssertFalse(
      try String(contentsOf: fixture.fileURL, encoding: .utf8)
        .contains("secret body removed by retention repair")
    )

    let reloadedStore = IAgentLocalSyncStore(fileURL: fixture.fileURL)
    let reloadedPending = await reloadedStore.pendingRecordNames()
    let reloadedConversation = await reloadedStore.payload(for: conversationName)
    let reloadedReadState = await reloadedStore.payload(for: readStateName)
    XCTAssertEqual(
      Set(reloadedPending),
      Set([conversationName, readStateName])
    )
    XCTAssertEqual(reloadedConversation, try transported(repairedConversation))
    XCTAssertEqual(reloadedReadState, try transported(repairedReadState))

    try await reloadedStore.markSent([
      sentRecord(repairedConversation, cloudSystemFields: Data([8])),
      sentRecord(repairedReadState, cloudSystemFields: Data([9])),
    ])
    let pendingAfterAcknowledgement = await reloadedStore.pendingRecordNames()
    XCTAssertTrue(pendingAfterAcknowledgement.isEmpty)
    XCTAssertFalse(
      try String(contentsOf: fixture.fileURL, encoding: .utf8)
        .contains("secret body removed by retention repair")
    )
  }

  func testPendingDiagnosticsIncludePhysicalDeletions() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let payload = IAgentSyncPayload.messageRelayState(
      SyncedMessageRelayState(
        id: "relay-to-delete",
        phase: .available,
        detail: "relay detail",
        updatedAt: freshDate()
      )
    )
    _ = try await fixture.store.mergeRemote(payload, cloudSystemFields: Data([1]))
    try await fixture.store.deleteLocal(recordName: payload.recordName)

    let diagnostics = await fixture.store.diagnostics()
    XCTAssertEqual(diagnostics.pendingRecordCount, 1)
    XCTAssertEqual(diagnostics.pendingRecordNames, [payload.recordName])
    XCTAssertNil(diagnostics.oldestPendingRecordUpdatedAt)
  }

  func testAllMessagePayloadKindsRoundTripThroughCodable() throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let payloads: [IAgentSyncPayload] = [
      .messageConversation(makeConversation(now: now)),
      .message(makeMessage(now: now)),
      .messageReadState(makeReadState(now: now)),
      .messageRelayState(
        SyncedMessageRelayState(
          id: "relay-round-trip",
          phase: .permissionRequired,
          detail: "Full Disk Access required",
          updatedAt: now
        )
      ),
    ]

    XCTAssertEqual(try transported(payloads), payloads)
    XCTAssertEqual(
      Set(payloads.map(\.kind)),
      Set([.messageConversation, .message, .messageReadState, .messageRelayState])
    )
  }

  func testAccountBoundPendingCloudChangesKeepSavesAndDeletesDisjointAcrossReload() async throws {
    let fixture = makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let account = "test-account-fingerprint"
    _ = try await fixture.store.bind(toCloudAccount: account)
    let payload = IAgentSyncPayload.messageRelayState(
      SyncedMessageRelayState(
        id: "account-relay",
        phase: .available,
        updatedAt: freshDate()
      )
    )
    try await fixture.store.upsertLocal(payload)

    let saves = try await fixture.store.pendingCloudChanges(forCloudAccount: account)
    XCTAssertEqual(saves.saveRecordNames, [payload.recordName])
    XCTAssertTrue(saves.deletionRecordNames.isEmpty)

    try await fixture.store.deleteLocal(recordName: payload.recordName)
    let deletions = try await fixture.store.pendingCloudChanges(forCloudAccount: account)
    XCTAssertTrue(deletions.saveRecordNames.isEmpty)
    XCTAssertEqual(deletions.deletionRecordNames, [payload.recordName])

    let reloadedStore = IAgentLocalSyncStore(fileURL: fixture.fileURL)
    let reloaded = try await reloadedStore.pendingCloudChanges(forCloudAccount: account)
    XCTAssertTrue(reloaded.saveRecordNames.isEmpty)
    XCTAssertEqual(reloaded.deletionRecordNames, [payload.recordName])
  }

  private func makeStoreFixture(
    messageProjectionRole: IAgentMessageProjectionRole = .cloudReplica
  ) -> (
    rootURL: URL,
    fileURL: URL,
    store: IAgentLocalSyncStore
  ) {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-message-sync-\(UUID().uuidString)", isDirectory: true)
    let fileURL = rootURL.appendingPathComponent("sync-store.json")
    return (
      rootURL,
      fileURL,
      IAgentLocalSyncStore(
        fileURL: fileURL,
        messageProjectionRole: messageProjectionRole
      )
    )
  }

  private func freshDate() -> Date {
    Date(
      timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 120
    )
  }

  private func makeConversation(
    now: Date,
    preview: String = "Hello",
    latestMessageID: String = "message-1",
    awaitingReplyMessageID: String? = nil
  ) -> SyncedMessageConversation {
    SyncedMessageConversation(
      id: "conversation-1",
      displayName: "Maya",
      participants: [SyncedMessageParticipant(id: "participant-1", displayName: "Maya")],
      isGroup: false,
      serviceName: "iMessage",
      latestMessageID: latestMessageID,
      latestMessageDate: now,
      latestPreview: preview,
      awaitingReplyMessageID: awaitingReplyMessageID,
      updatedAt: now
    )
  }

  private func makeMessage(
    id: String = "message-1",
    body: String = "Hello",
    now: Date
  ) -> SyncedMessage {
    SyncedMessage(
      id: id,
      conversationID: "conversation-1",
      senderID: "participant-1",
      senderDisplayName: "Maya",
      isFromMe: false,
      body: body,
      sentAt: now,
      updatedAt: now
    )
  }

  private func makeReadState(now: Date) -> SyncedMessageReadState {
    SyncedMessageReadState(
      id: "conversation-1",
      readThroughMessageID: "message-1",
      readThroughDate: now,
      latestKnownMessageDate: now,
      updatedAt: now,
      sourceDeviceID: "mac"
    )
  }

  private func sentRecord(
    _ payload: IAgentSyncPayload,
    cloudSystemFields: Data? = nil
  ) -> IAgentSentRecord {
    IAgentSentRecord(
      recordName: payload.recordName,
      sentPayload: payload,
      cloudSystemFields: cloudSystemFields
    )
  }

  private func transported<Value: Codable>(_ value: Value) throws -> Value {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Value.self, from: encoder.encode(value))
  }
}

private final class NotificationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}

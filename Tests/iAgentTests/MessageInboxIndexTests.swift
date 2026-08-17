import Foundation
import XCTest
import iAgentCore

@testable import iAgentPanel

final class MessageInboxIndexTests: XCTestCase {
  func testIndexGroupsSortsAndAppliesFreshRollingCutoff() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let cutoff = MessageSyncWindow.cutoff(referenceDate: referenceDate)
    let messages = [
      makeMessage(id: "newer", conversationID: "one", sentAt: referenceDate),
      makeMessage(id: "other", conversationID: "two", sentAt: referenceDate),
      makeMessage(id: "expired", conversationID: "one", sentAt: cutoff.addingTimeInterval(-1)),
      makeMessage(id: "cutoff", conversationID: "one", sentAt: cutoff),
      makeMessage(
        id: "deleted",
        conversationID: "one",
        sentAt: referenceDate,
        deletedAt: referenceDate
      ),
    ]
    let index = MessageInboxIndex(messages: messages)

    XCTAssertEqual(
      index.retainedMessages(for: "one", referenceDate: referenceDate).map(\.id),
      ["cutoff", "newer"]
    )
    XCTAssertEqual(
      index.retainedMessages(for: "two", referenceDate: referenceDate).map(\.id),
      ["other"]
    )
    XCTAssertTrue(index.hasRetainedMessages(for: "one", referenceDate: referenceDate))

    let advancedDate = referenceDate.addingTimeInterval(1)
    XCTAssertEqual(
      index.retainedMessages(for: "one", referenceDate: advancedDate).map(\.id),
      ["newer"]
    )
  }

  func testUnreadCountUsesConversationIndexAndUpdatedReadCursor() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let first = makeMessage(
      id: "first",
      conversationID: "one",
      sentAt: referenceDate.addingTimeInterval(-3)
    )
    let second = makeMessage(
      id: "second",
      conversationID: "one",
      sentAt: referenceDate.addingTimeInterval(-2)
    )
    let outgoing = makeMessage(
      id: "outgoing",
      conversationID: "one",
      sentAt: referenceDate.addingTimeInterval(-1),
      isFromMe: true
    )
    let sourceRead = makeMessage(
      id: "source-read",
      conversationID: "one",
      sentAt: referenceDate,
      sourceReadAt: referenceDate
    )
    let unrelated = (0..<1_000).map { index in
      makeMessage(
        id: "other-\(index)",
        conversationID: "two",
        sentAt: referenceDate.addingTimeInterval(TimeInterval(-index))
      )
    }
    var index = MessageInboxIndex(
      messages: [sourceRead, outgoing, second, first] + unrelated,
      readStates: [
        makeReadState(
          conversationID: "one",
          through: first,
          referenceDate: referenceDate
        )
      ]
    )

    XCTAssertEqual(index.unreadCount(for: "one", referenceDate: referenceDate), 1)
    XCTAssertEqual(index.unreadCount(for: "two", referenceDate: referenceDate), 1_000)

    index.replaceReadStates([
      makeReadState(
        conversationID: "one",
        through: second,
        referenceDate: referenceDate
      )
    ])
    XCTAssertEqual(index.unreadCount(for: "one", referenceDate: referenceDate), 0)
  }

  func testVisibleConversationOrderKeepsUnreadFirstThenNewestAndUpdatesAfterRead() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let olderUnread = makeMessage(
      id: "older-unread",
      conversationID: "older",
      sentAt: referenceDate.addingTimeInterval(-120)
    )
    let newerRead = makeMessage(
      id: "newer-read",
      conversationID: "newer",
      sentAt: referenceDate.addingTimeInterval(-30),
      sourceReadAt: referenceDate
    )
    let newestUnread = makeMessage(
      id: "newest-unread",
      conversationID: "newest",
      sentAt: referenceDate.addingTimeInterval(-10)
    )
    let conversations = [
      makeConversation(id: "newer", latest: newerRead),
      makeConversation(id: "older", latest: olderUnread),
      makeConversation(id: "newest", latest: newestUnread),
    ]
    var index = MessageInboxIndex(messages: [newerRead, olderUnread, newestUnread])

    XCTAssertEqual(
      index.orderedVisibleConversations(
        conversations,
        referenceDate: referenceDate
      ).map(\.id),
      ["newest", "older", "newer"]
    )

    index.replaceReadStates([
      makeReadState(
        conversationID: "newest",
        through: newestUnread,
        referenceDate: referenceDate
      ),
      makeReadState(
        conversationID: "older",
        through: olderUnread,
        referenceDate: referenceDate
      ),
    ])
    XCTAssertEqual(
      index.orderedVisibleConversations(
        conversations,
        referenceDate: referenceDate
      ).map(\.id),
      ["newest", "newer", "older"]
    )
  }

  func testConversationSearchMatchesDisplayNameAndLatestRetainedPreviewWithoutReordering() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let firstMessage = makeMessage(
      id: "first-message",
      conversationID: "first",
      body: "Launch update",
      sentAt: referenceDate.addingTimeInterval(-30)
    )
    let secondMessage = makeMessage(
      id: "second-message",
      conversationID: "second",
      body: "Dinner tonight",
      sentAt: referenceDate.addingTimeInterval(-10)
    )
    var first = makeConversation(id: "first", latest: firstMessage)
    first.displayName = "José Alvarez"
    var second = makeConversation(id: "second", latest: secondMessage)
    second.displayName = "Maya"
    let ordered = [second, first]
    let index = MessageInboxIndex(messages: [firstMessage, secondMessage])

    XCTAssertEqual(
      index.filteredConversations(
        ordered,
        query: "jose",
        referenceDate: referenceDate
      ).map(\.id),
      ["first"]
    )
    XCTAssertEqual(
      index.filteredConversations(
        ordered,
        query: "LAUNCH",
        referenceDate: referenceDate
      ).map(\.id),
      ["first"]
    )
    XCTAssertEqual(
      index.filteredConversations(
        ordered,
        query: "  ",
        referenceDate: referenceDate
      ).map(\.id),
      ["second", "first"]
    )
  }

  func testConversationFiltersPreserveOrderAndUseCanonicalReplyAndUnreadSignals() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let awaitingMessage = makeMessage(
      id: "awaiting-message",
      conversationID: "awaiting",
      body: "Need your answer",
      sentAt: referenceDate.addingTimeInterval(-30),
      sourceReadAt: referenceDate
    )
    let unreadMessage = makeMessage(
      id: "unread-message",
      conversationID: "unread",
      body: "Fresh update",
      sentAt: referenceDate.addingTimeInterval(-10)
    )
    let readMessage = makeMessage(
      id: "read-message",
      conversationID: "read",
      body: "Already handled",
      sentAt: referenceDate.addingTimeInterval(-20),
      sourceReadAt: referenceDate
    )
    let ordered = [
      makeConversation(id: "unread", latest: unreadMessage),
      makeConversation(
        id: "awaiting",
        latest: awaitingMessage,
        awaitingReplyMessageID: awaitingMessage.id
      ),
      makeConversation(id: "read", latest: readMessage),
    ]
    let index = MessageInboxIndex(
      messages: [awaitingMessage, unreadMessage, readMessage]
    )

    XCTAssertEqual(MessageInboxFilter.allCases, [.all, .awaitingReply, .unread])
    XCTAssertEqual(
      index.filteredConversations(
        ordered,
        query: "",
        filter: .all,
        referenceDate: referenceDate
      ).map(\.id),
      ["unread", "awaiting", "read"]
    )
    XCTAssertEqual(
      index.filteredConversations(
        ordered,
        query: "",
        filter: .awaitingReply,
        referenceDate: referenceDate
      ).map(\.id),
      ["awaiting"]
    )
    XCTAssertEqual(
      index.filteredConversations(
        ordered,
        query: "fresh",
        filter: .unread,
        referenceDate: referenceDate
      ).map(\.id),
      ["unread"]
    )
    XCTAssertTrue(
      index.filteredConversations(
        ordered,
        query: "handled",
        filter: .unread,
        referenceDate: referenceDate
      ).isEmpty
    )
  }

  func testProviderAuthoredInboundMarkerAwaitsMyReplyWhenExactMessageIsRetained() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let inbound = makeMessage(
      id: "inbound",
      conversationID: "one",
      body: "Provider-approved text",
      sentAt: referenceDate
    )
    let conversation = makeConversation(
      id: "one",
      latest: inbound,
      awaitingReplyMessageID: inbound.id
    )
    let index = MessageInboxIndex(messages: [inbound])

    XCTAssertTrue(
      index.isAwaitingMyReply(for: conversation, referenceDate: referenceDate)
    )
  }

  func testMissingOrCrossConversationReplyMarkerDoesNotAwaitMyReply() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let inbound = makeMessage(
      id: "inbound",
      conversationID: "other",
      sentAt: referenceDate
    )
    let missing = makeConversation(
      id: "one",
      latest: inbound,
      awaitingReplyMessageID: "missing"
    )
    let crossConversation = makeConversation(
      id: "one",
      latest: inbound,
      awaitingReplyMessageID: inbound.id
    )
    let index = MessageInboxIndex(messages: [inbound])

    XCTAssertFalse(
      index.isAwaitingMyReply(for: missing, referenceDate: referenceDate)
    )
    XCTAssertFalse(
      index.isAwaitingMyReply(
        for: crossConversation,
        referenceDate: referenceDate
      )
    )
  }

  func testOutgoingOrDeletedReferencedMessageDoesNotAwaitMyReply() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let outgoing = makeMessage(
      id: "outgoing",
      conversationID: "one",
      sentAt: referenceDate,
      isFromMe: true
    )
    let deletedInbound = makeMessage(
      id: "deleted-inbound",
      conversationID: "one",
      sentAt: referenceDate,
      deletedAt: referenceDate
    )
    let outgoingConversation = makeConversation(
      id: "one",
      latest: outgoing,
      awaitingReplyMessageID: outgoing.id
    )
    let deletedConversation = makeConversation(
      id: "one",
      latest: deletedInbound,
      awaitingReplyMessageID: deletedInbound.id
    )
    let index = MessageInboxIndex(messages: [outgoing, deletedInbound])

    XCTAssertFalse(
      index.isAwaitingMyReply(
        for: outgoingConversation,
        referenceDate: referenceDate
      )
    )
    XCTAssertFalse(
      index.isAwaitingMyReply(
        for: deletedConversation,
        referenceDate: referenceDate
      )
    )
  }

  func testReplyMarkerUsesInclusiveExactRollingCutoff() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let cutoff = MessageSyncWindow.cutoff(referenceDate: referenceDate)
    let expired = makeMessage(
      id: "expired",
      conversationID: "expired",
      sentAt: cutoff.addingTimeInterval(-0.001)
    )
    let atCutoff = makeMessage(
      id: "at-cutoff",
      conversationID: "at-cutoff",
      sentAt: cutoff
    )
    let expiredConversation = makeConversation(
      id: "expired",
      latest: expired,
      awaitingReplyMessageID: expired.id
    )
    let cutoffConversation = makeConversation(
      id: "at-cutoff",
      latest: atCutoff,
      awaitingReplyMessageID: atCutoff.id
    )
    let index = MessageInboxIndex(messages: [expired, atCutoff])

    XCTAssertFalse(
      index.isAwaitingMyReply(
        for: expiredConversation,
        referenceDate: referenceDate
      )
    )
    XCTAssertTrue(
      index.isAwaitingMyReply(
        for: cutoffConversation,
        referenceDate: referenceDate
      )
    )
  }

  func testReplyStateIsIndependentOfReadCursorAndSourceReadState() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let inbound = makeMessage(
      id: "inbound",
      conversationID: "one",
      sentAt: referenceDate,
      sourceReadAt: referenceDate
    )
    let conversation = makeConversation(
      id: "one",
      latest: inbound,
      awaitingReplyMessageID: inbound.id
    )
    var index = MessageInboxIndex(
      messages: [inbound],
      readStates: [
        makeReadState(
          conversationID: "one",
          through: inbound,
          referenceDate: referenceDate
        )
      ]
    )

    XCTAssertTrue(
      index.isAwaitingMyReply(for: conversation, referenceDate: referenceDate)
    )
    index.replaceReadStates([])
    XCTAssertTrue(
      index.isAwaitingMyReply(for: conversation, referenceDate: referenceDate)
    )
  }

  func testGroupConversationNeverAwaitsMyReplyEvenWithAValidInboundMarker() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let inbound = makeMessage(
      id: "group-inbound",
      conversationID: "group",
      sentAt: referenceDate
    )
    let group = makeConversation(
      id: "group",
      latest: inbound,
      isGroup: true,
      awaitingReplyMessageID: inbound.id
    )
    let index = MessageInboxIndex(messages: [inbound])

    XCTAssertFalse(
      index.isAwaitingMyReply(for: group, referenceDate: referenceDate)
    )
  }

  func testAwaitingMyReplyAggregateIncludesDirectConversationsOnly() {
    let referenceDate = Date(timeIntervalSince1970: 2_000_000)
    let visibleInbound = makeMessage(
      id: "visible-inbound",
      conversationID: "visible",
      sentAt: referenceDate
    )
    let deletedInbound = makeMessage(
      id: "deleted-inbound",
      conversationID: "deleted",
      sentAt: referenceDate
    )
    var deletedConversation = makeConversation(
      id: "deleted",
      latest: deletedInbound,
      awaitingReplyMessageID: deletedInbound.id
    )
    deletedConversation.deletedAt = referenceDate
    let orphanConversation = makeConversation(
      id: "orphan",
      latest: visibleInbound,
      awaitingReplyMessageID: "missing"
    )
    let groupInbound = makeMessage(
      id: "group-inbound",
      conversationID: "group",
      sentAt: referenceDate
    )
    let groupConversation = makeConversation(
      id: "group",
      latest: groupInbound,
      isGroup: true,
      awaitingReplyMessageID: groupInbound.id
    )
    let conversations = [
      makeConversation(
        id: "visible",
        latest: visibleInbound,
        awaitingReplyMessageID: visibleInbound.id
      ),
      deletedConversation,
      orphanConversation,
      groupConversation,
    ]
    let index = MessageInboxIndex(
      messages: [visibleInbound, deletedInbound, groupInbound]
    )

    XCTAssertEqual(
      index.awaitingMyReplyCount(
        for: conversations,
        referenceDate: referenceDate
      ),
      1
    )
  }

  private func makeMessage(
    id: String,
    conversationID: String,
    body: String = "",
    sentAt: Date,
    isFromMe: Bool = false,
    sourceReadAt: Date? = nil,
    deletedAt: Date? = nil
  ) -> SyncedMessage {
    SyncedMessage(
      id: id,
      conversationID: conversationID,
      isFromMe: isFromMe,
      body: body,
      sentAt: sentAt,
      sourceReadAt: sourceReadAt,
      updatedAt: sentAt,
      deletedAt: deletedAt
    )
  }

  private func makeReadState(
    conversationID: String,
    through message: SyncedMessage,
    referenceDate: Date
  ) -> SyncedMessageReadState {
    SyncedMessageReadState(
      id: conversationID,
      readThroughMessageID: message.id,
      readThroughDate: message.sentAt,
      latestKnownMessageDate: referenceDate,
      updatedAt: referenceDate,
      sourceDeviceID: "test"
    )
  }

  private func makeConversation(
    id: String,
    latest message: SyncedMessage,
    isGroup: Bool = false,
    awaitingReplyMessageID: String? = nil
  ) -> SyncedMessageConversation {
    var conversation = SyncedMessageConversation(
      id: id,
      displayName: id.capitalized,
      participants: [],
      isGroup: isGroup,
      latestMessageID: message.id,
      latestMessageDate: message.sentAt,
      latestPreview: message.body,
      updatedAt: message.updatedAt
    )
    conversation.awaitingReplyMessageID = awaitingReplyMessageID
    return conversation
  }
}

import Foundation
import iAgentCore

enum MessageInboxFilter: String, CaseIterable, Equatable, Sendable {
  case all
  case awaitingReply
  case unread
}

/// Pre-indexes the local inbox snapshot so SwiftUI accessors only inspect the
/// selected conversation instead of rescanning every retained message.
struct MessageInboxIndex {
  private struct ReadCursor {
    let date: Date
    let messageID: String
  }

  private var messagesByConversation: [String: [SyncedMessage]] = [:]
  private var messageByID: [String: SyncedMessage] = [:]
  private var readCursorByConversation: [String: ReadCursor] = [:]

  init(
    messages: [SyncedMessage] = [],
    readStates: [SyncedMessageReadState] = []
  ) {
    replaceMessages(messages)
    replaceReadStates(readStates)
  }

  mutating func replaceMessages(_ messages: [SyncedMessage]) {
    let retained = messages.filter { $0.deletedAt == nil }
    messagesByConversation = Dictionary(
      grouping: retained,
      by: \.conversationID
    ).mapValues { values in
      values.sorted { ($0.sentAt, $0.id) < ($1.sentAt, $1.id) }
    }
    messageByID = retained.reduce(into: [:]) { index, message in
      index[message.id] = message
    }
  }

  mutating func replaceReadStates(_ readStates: [SyncedMessageReadState]) {
    var cursors: [String: ReadCursor] = [:]
    for state in readStates where state.deletedAt == nil && cursors[state.id] == nil {
      cursors[state.id] = ReadCursor(
        date: state.readThroughDate ?? .distantPast,
        messageID: state.readThroughMessageID ?? ""
      )
    }
    readCursorByConversation = cursors
  }

  func hasRetainedMessages(
    for conversationID: String,
    referenceDate: Date
  ) -> Bool {
    guard let latest = messagesByConversation[conversationID]?.last else { return false }
    return MessageSyncWindow.includes(date: latest.sentAt, referenceDate: referenceDate)
  }

  func retainedMessages(
    for conversationID: String,
    referenceDate: Date
  ) -> [SyncedMessage] {
    guard let values = messagesByConversation[conversationID] else { return [] }
    let start = retainedStartIndex(in: values, referenceDate: referenceDate)
    guard start < values.endIndex else { return [] }
    return Array(values[start...])
  }

  func unreadCount(
    for conversationID: String,
    referenceDate: Date
  ) -> Int {
    guard let values = messagesByConversation[conversationID] else { return 0 }
    let start = retainedStartIndex(in: values, referenceDate: referenceDate)
    guard start < values.endIndex else { return 0 }

    let cursor = readCursorByConversation[conversationID]
      ?? ReadCursor(date: .distantPast, messageID: "")
    return values[start...].reduce(into: 0) { count, message in
      guard !message.isFromMe, message.sourceReadAt == nil else { return }
      if (message.sentAt, message.id) > (cursor.date, cursor.messageID) {
        count += 1
      }
    }
  }

  /// Validates the provider-authored reply marker against the current retained
  /// snapshot. The provider owns message-kind semantics; this layer never
  /// guesses from message bodies, participant identity, or source read state.
  /// Group conversations are deliberately excluded from this v1 signal.
  func isAwaitingMyReply(
    for conversation: SyncedMessageConversation,
    referenceDate: Date
  ) -> Bool {
    guard !conversation.isGroup,
          conversation.deletedAt == nil,
          let messageID = conversation.awaitingReplyMessageID,
          let message = messageByID[messageID],
          message.conversationID == conversation.id,
          !message.isFromMe
    else { return false }
    return MessageSyncWindow.includes(
      date: message.sentAt,
      referenceDate: referenceDate
    )
  }

  /// Computes the header aggregate from the same retained data used by each
  /// row. Deleted conversation summaries are excluded, and read cursors are
  /// intentionally irrelevant to reply state.
  func awaitingMyReplyCount(
    for conversations: [SyncedMessageConversation],
    referenceDate: Date
  ) -> Int {
    conversations.reduce(into: 0) { count, conversation in
      guard isAwaitingMyReply(
        for: conversation,
        referenceDate: referenceDate
      )
      else { return }
      count += 1
    }
  }

  func orderedVisibleConversations(
    _ conversations: [SyncedMessageConversation],
    referenceDate: Date
  ) -> [SyncedMessageConversation] {
    let cutoff = MessageSyncWindow.cutoff(referenceDate: referenceDate)
    let retained = conversations.filter {
      $0.deletedAt == nil
        && $0.latestMessageDate >= cutoff
        && hasRetainedMessages(for: $0.id, referenceDate: referenceDate)
    }
    let unreadByID = Dictionary(uniqueKeysWithValues: retained.map {
      (
        $0.id,
        unreadCount(for: $0.id, referenceDate: referenceDate) > 0
      )
    })
    return retained.sorted { left, right in
      let leftUnread = unreadByID[left.id] ?? false
      let rightUnread = unreadByID[right.id] ?? false
      if leftUnread != rightUnread {
        return leftUnread
      }
      return (left.latestMessageDate, left.id) > (right.latestMessageDate, right.id)
    }
  }

  /// Filters an already ordered conversation list without changing its order.
  /// Search stays local and ephemeral; callers never persist or log the query.
  func filteredConversations(
    _ conversations: [SyncedMessageConversation],
    query: String,
    filter: MessageInboxFilter = .all,
    referenceDate: Date
  ) -> [SyncedMessageConversation] {
    let needle = normalizedSearchText(query)
    return conversations.filter { conversation in
      guard matches(filter, conversation: conversation, referenceDate: referenceDate) else {
        return false
      }
      guard !needle.isEmpty else { return true }
      if normalizedSearchText(conversation.displayName).contains(needle) {
        return true
      }
      guard let latest = retainedMessages(
        for: conversation.id,
        referenceDate: referenceDate
      ).last else { return false }
      return normalizedSearchText(latest.body).contains(needle)
    }
  }

  private func matches(
    _ filter: MessageInboxFilter,
    conversation: SyncedMessageConversation,
    referenceDate: Date
  ) -> Bool {
    switch filter {
    case .all:
      true
    case .awaitingReply:
      isAwaitingMyReply(for: conversation, referenceDate: referenceDate)
    case .unread:
      unreadCount(for: conversation.id, referenceDate: referenceDate) > 0
    }
  }

  private func retainedStartIndex(
    in values: [SyncedMessage],
    referenceDate: Date
  ) -> Int {
    let cutoff = MessageSyncWindow.cutoff(referenceDate: referenceDate)
    var lowerBound = values.startIndex
    var upperBound = values.endIndex
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if values[middle].sentAt < cutoff {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    return lowerBound
  }

  private func normalizedSearchText(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: .current
      )
  }
}

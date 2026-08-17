import SwiftUI
import iAgentCore

struct MessagesMobileView: View {
  @ObservedObject var model: MobileAppModel
  @State private var selectedConversation: MessageConversationRoute?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.38) {
        hero
      } drawer: {
        inbox
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .sheet(item: $selectedConversation) { route in
      MessagesHistorySheet(model: model, conversationID: route.id)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(PanelTheme.sheet)
        .preferredColorScheme(.dark)
    }
    .task {
      guard selectedConversation == nil,
            let conversationID = model.messageConversationToPresent
      else { return }
      selectedConversation = MessageConversationRoute(id: conversationID)
      model.messageConversationToPresent = nil
    }
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 0) {
      JoiBackButton { dismiss() }

      JoiPageMasthead(
        title: "Messages",
        metric: "\(model.unreadConversationCount)",
        metricLabel: model.unreadConversationCount == 0 ? "all read" : "unread",
        accent: PanelTheme.blue
      )
      .padding(.top, 22)
      .accessibilityLabel("\(model.unreadConversationCount) unread conversations")

      messageBriefing
        .font(.system(size: 20, weight: .semibold))
        .lineSpacing(3)
        .padding(.top, 30)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, PanelTheme.horizontalPadding)
    .padding(.top, 14)
  }

  private var messageBriefing: Text {
    let unreadCount = model.unreadConversationCount
    return Text("Your private inbox stays close. ")
      .foregroundStyle(PanelTheme.secondary)
      + Text(
        unreadCount == 0
          ? "You're all caught up"
          : "\(unreadCount) \(unreadCount == 1 ? "conversation" : "conversations") unread"
      )
      .foregroundStyle(PanelTheme.primary)
      + Text(" from the last 14 days.")
      .foregroundStyle(PanelTheme.secondary)
  }

  private var inbox: some View {
    LazyVStack(spacing: 0) {
      if !model.hasLoadedInitialSnapshot {
        MessagesLoadingState(message: "Loading private messages…")
          .padding(.top, 24)
      } else if model.visibleConversations.isEmpty {
        emptyState
      } else {
        if let issue = cachedSyncIssue {
          MessagesStatusBanner(issue: issue) {
            Task { await model.refresh() }
          }
          JoiDottedDivider()
        }

        JoiSectionHeader(title: "Last 14 days", count: model.visibleConversations.count)

        ForEach(Array(model.visibleConversations.enumerated()), id: \.element.id) { index, conversation in
          if let latestMessage = model.latestMessage(for: conversation.id) {
            let unreadCount = model.unreadCount(for: conversation.id)
            let isAwaitingReply = model.isAwaitingReply(conversation)
            JoiDrawerButton(action: {
              selectedConversation = MessageConversationRoute(id: conversation.id)
            }) {
              JoiMessageConversationRow(
                conversation: conversation,
                latestMessage: latestMessage,
                unreadCount: unreadCount,
                isAwaitingReply: isAwaitingReply
              )
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(conversation.displayName)
            .accessibilityValue(
              "\(messageStatusAccessibility(unreadCount, isAwaitingReply: isAwaitingReply)). "
                + "\(messagePreview(latestMessage.body)). "
                + latestMessage.sentAt.formatted(date: .abbreviated, time: .shortened)
            )
            .accessibilityHint("Opens recent message history")

            if index < model.visibleConversations.count - 1 {
              JoiDottedDivider(inset: 80)
            }
          }
        }
      }
    }
    .padding(.bottom, 96)
  }

  @ViewBuilder
  private var emptyState: some View {
    if let relayState = model.latestMessageRelayState {
      switch relayState.phase {
      case .loading:
        MessagesLoadingState(
          message: relayState.detail ?? "Your Mac is checking for recent messages…"
        )
        .padding(.top, 24)
      case .permissionRequired:
        EmptyPanelState(
          symbol: "lock",
          title: "Messages access needed on Mac",
          detail: relayState.detail
            ?? "Open the compatible Mac companion that provides this relay and review its Messages access."
        )
        .padding(.top, 24)
      case .disabled:
        EmptyPanelState(
          symbol: "message.slash",
          title: "Message sync is off",
          detail: relayState.detail
            ?? "Enable the private Messages provider in the compatible Mac companion."
        )
        .padding(.top, 24)
      case .failed:
        EmptyPanelState(
          symbol: "exclamationmark.bubble",
          title: "Mac message sync failed",
          detail: relayState.detail
            ?? "Open the Mac companion that provides this relay and retry its Messages provider."
        )
        .padding(.top, 24)
      case .available:
        cloudEmptyState
      }
    } else {
      cloudEmptyState
    }
  }

  @ViewBuilder
  private var cloudEmptyState: some View {
    switch model.syncStatus.phase {
    case .syncing:
      MessagesLoadingState(message: "Loading private messages…")
        .padding(.top, 24)
    case .accountUnavailable:
      EmptyPanelState(
        symbol: "person.crop.circle.badge.exclamationmark",
        title: "iCloud unavailable",
        detail: model.syncStatus.message
          ?? "Sign in to iCloud to receive read-only message projections from a compatible Mac relay."
      )
      .padding(.top, 24)
    case .failed:
      EmptyPanelState(
        symbol: "exclamationmark.bubble",
        title: "Messages could not sync",
        detail: model.syncStatus.message
          ?? "Try again when iCloud and the compatible Mac relay are available."
      )
      .padding(.top, 24)
    case .offline:
      EmptyPanelState(
        symbol: "wifi.slash",
        title: "No cached messages",
        detail: "Reconnect to receive read-only message history from a compatible Mac relay."
      )
      .padding(.top, 24)
    case .idle:
      EmptyPanelState(
        symbol: "message",
        title: "Message relay not connected",
        detail: "This read-only tab displays the last 14 days after a compatible Mac companion relays them through private iCloud. It never reads Messages directly on iPhone."
      )
      .padding(.top, 24)
    }
  }

  private var cachedSyncIssue: MessagesSyncIssue? {
    if let relayState = model.latestMessageRelayState {
      switch relayState.phase {
      case .loading:
        return MessagesSyncIssue(
          symbol: "arrow.triangle.2.circlepath",
          message: relayState.detail ?? "Your Mac is refreshing messages. Showing cached conversations.",
          color: PanelTheme.blue
        )
      case .permissionRequired:
        return MessagesSyncIssue(
          symbol: "lock",
          message: relayState.detail ?? "Messages access is needed on your Mac. Showing cached conversations.",
          color: PanelTheme.amber
        )
      case .disabled:
        return MessagesSyncIssue(
          symbol: "message.slash",
          message: relayState.detail ?? "Message sync is off on your Mac. Showing cached conversations.",
          color: PanelTheme.secondary
        )
      case .failed:
        return MessagesSyncIssue(
          symbol: "exclamationmark.bubble",
          message: relayState.detail ?? "The Mac message provider failed. Showing cached conversations.",
          color: PanelTheme.coral
        )
      case .available:
        break
      }
    }

    switch model.syncStatus.phase {
    case .accountUnavailable:
      return MessagesSyncIssue(
        symbol: "person.crop.circle.badge.exclamationmark",
        message: model.syncStatus.message ?? "iCloud is unavailable. Showing cached messages.",
        color: PanelTheme.coral
      )
    case .failed:
      return MessagesSyncIssue(
        symbol: "exclamationmark.icloud",
        message: model.syncStatus.message ?? "Sync failed. Showing cached messages.",
        color: PanelTheme.coral
      )
    case .offline:
      return MessagesSyncIssue(
        symbol: "wifi.slash",
        message: "Offline. Showing cached messages.",
        color: PanelTheme.secondary
      )
    case .idle, .syncing:
      return nil
    }
  }

  private func messagePreview(_ body: String) -> String {
    let collapsed = body
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return collapsed.isEmpty ? "Message" : collapsed
  }

  private func messageStatusAccessibility(
    _ unreadCount: Int,
    isAwaitingReply: Bool
  ) -> String {
    if unreadCount > 0, isAwaitingReply {
      return "\(unreadCount) unread, awaiting your reply"
    }
    if unreadCount > 0 { return "\(unreadCount) unread" }
    if isAwaitingReply { return "Awaiting your reply" }
    return "Read"
  }
}

private struct MessageConversationRoute: Identifiable {
  let id: String
}

private struct JoiMessageConversationRow: View {
  let conversation: SyncedMessageConversation
  let latestMessage: SyncedMessage
  let unreadCount: Int
  let isAwaitingReply: Bool

  private var isUnread: Bool { unreadCount > 0 }
  private var attentionColor: Color? {
    if isUnread { return PanelTheme.coral }
    if isAwaitingReply { return PanelTheme.amber }
    return nil
  }

  var body: some View {
    HStack(spacing: 14) {
      JoiMessageAvatar(conversation: conversation, size: 42)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 7) {
          Text(conversation.displayName)
            .font(.system(size: 16, weight: isUnread ? .bold : .semibold))
            .foregroundStyle(isUnread ? PanelTheme.primary : PanelTheme.secondary)
            .lineLimit(1)

          if let attentionColor {
            Circle()
              .fill(attentionColor)
              .frame(width: 7, height: 7)
              .accessibilityHidden(true)
          }
        }

        Text(preview)
          .font(.system(size: 12, weight: isUnread ? .semibold : .medium))
          .foregroundStyle(isUnread ? PanelTheme.secondary : PanelTheme.tertiary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(latestMessage.sentAt.compactRelative())
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(isUnread ? PanelTheme.primary : PanelTheme.secondary)
        .monospacedDigit()
        .frame(minWidth: 42, alignment: .trailing)
    }
    .padding(.horizontal, 24)
    .frame(minHeight: 72)
    .contentShape(Rectangle())
  }

  private var preview: String {
    let collapsed = latestMessage.body
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    let content = collapsed.isEmpty ? "Message" : collapsed
    return latestMessage.isFromMe ? "You: \(content)" : content
  }
}

struct JoiMessageAvatar: View {
  let displayName: String
  let identity: String
  let size: CGFloat

  init(conversation: SyncedMessageConversation, size: CGFloat) {
    displayName = conversation.displayName
    identity = conversation.id
    self.size = size
  }

  init(displayName: String, identity: String, size: CGFloat) {
    self.displayName = displayName
    self.identity = identity
    self.size = size
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(monogramColor)

      Text(initials)
        .font(.system(size: size * 0.32, weight: .bold))
        .foregroundStyle(PanelTheme.primary)
    }
    .frame(width: size, height: size)
    .overlay {
      Circle().stroke(PanelTheme.strongBorder, lineWidth: 1)
    }
    .accessibilityHidden(true)
  }

  private var initials: String {
    let value = displayName
      .split(whereSeparator: \.isWhitespace)
      .prefix(2)
      .compactMap(\.first)
      .map(String.init)
      .joined()
      .uppercased()
    return value.isEmpty ? "?" : value
  }

  private var monogramColor: Color {
    let palette = [
      PanelTheme.blue,
      PanelTheme.violet,
      PanelTheme.green,
      PanelTheme.amber,
      PanelTheme.coral,
    ]
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in identity.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return palette[Int(hash % UInt64(palette.count))].opacity(0.28)
  }
}

private struct MessagesHistorySheet: View {
  @ObservedObject var model: MobileAppModel
  let conversationID: String

  @Environment(\.dismiss) private var dismiss

  private var conversation: SyncedMessageConversation? {
    guard !model.messages(for: conversationID).isEmpty else { return nil }
    return model.snapshot.messageConversations.first {
      $0.id == conversationID && $0.deletedAt == nil
    }
  }

  private var recentMessages: [SyncedMessage] {
    model.messages(for: conversationID)
  }

  private var latestMessageID: String? { recentMessages.last?.id }
  private var latestIncomingMessageID: String? {
    recentMessages.last(where: { !$0.isFromMe })?.id
  }

  var body: some View {
    Group {
      if let conversation {
        VStack(spacing: 0) {
          header(conversation)
          JoiDottedDivider(inset: 20)
          history(conversation)
        }
      } else {
        VStack(spacing: 0) {
          closeOnlyHeader
          EmptyPanelState(
            symbol: "clock.arrow.circlepath",
            title: "Conversation unavailable",
            detail: "Only messages from the rolling last 14 days are kept."
          )
          Spacer()
        }
      }
    }
    .background(PanelTheme.sheet.ignoresSafeArea())
    .task(id: latestIncomingMessageID) {
      guard latestIncomingMessageID != nil else { return }
      await model.markConversationRead(conversationID)
    }
  }

  private func header(_ conversation: SyncedMessageConversation) -> some View {
    HStack(spacing: 12) {
      JoiMessageAvatar(conversation: conversation, size: 40)

      VStack(alignment: .leading, spacing: 3) {
        Text(conversation.displayName)
          .font(.system(size: 17, weight: .bold))
          .foregroundStyle(PanelTheme.primary)
          .lineLimit(1)

        Text(conversation.serviceName.map { "\($0) · Last 14 days" } ?? "Last 14 days")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(PanelTheme.tertiary)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      closeButton
    }
    .padding(.horizontal, 20)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .frame(minHeight: 68)
  }

  private var closeOnlyHeader: some View {
    HStack {
      Spacer()
      closeButton
    }
    .padding(.horizontal, 20)
    .padding(.top, 10)
    .frame(height: 58)
  }

  private var closeButton: some View {
    Button { dismiss() } label: {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(PanelTheme.primary)
        .frame(width: 38, height: 38)
        .background(PanelTheme.surface, in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Close message history")
  }

  private func history(_ conversation: SyncedMessageConversation) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(recentMessages) { message in
            MessageBubble(message: message, isGroup: conversation.isGroup)
              .id(message.id)
          }

          Color.clear
            .frame(height: 6)
            .id("messages-latest-anchor")
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 24)
      }
      .scrollIndicators(.hidden)
      .defaultScrollAnchor(.bottom)
      .onAppear {
        proxy.scrollTo("messages-latest-anchor", anchor: .bottom)
      }
      .onChange(of: latestMessageID) { _, _ in
        withAnimation(PanelTheme.quick) {
          proxy.scrollTo("messages-latest-anchor", anchor: .bottom)
        }
      }
    }
  }
}

private struct MessageBubble: View {
  let message: SyncedMessage
  let isGroup: Bool

  var body: some View {
    HStack(alignment: .bottom, spacing: 10) {
      if message.isFromMe { Spacer(minLength: 44) }

      VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 5) {
        if isGroup, !message.isFromMe, let senderName = message.senderDisplayName {
          Text(senderName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(PanelTheme.tertiary)
            .padding(.horizontal, 4)
        }

        Text(messageBody)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(PanelTheme.primary)
          .lineSpacing(3)
          .textSelection(.enabled)
          .padding(.horizontal, 13)
          .padding(.vertical, 10)
          .background(
            message.isFromMe ? PanelTheme.blue.opacity(0.78) : PanelTheme.raisedSurface,
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
          )

        Text(timestamp)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(PanelTheme.tertiary)
          .padding(.horizontal, 4)
      }
      .frame(maxWidth: 290, alignment: message.isFromMe ? .trailing : .leading)

      if !message.isFromMe { Spacer(minLength: 44) }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(message.isFromMe ? "You" : (message.senderDisplayName ?? "Incoming message"))
    .accessibilityValue(
      "\(messageBody). \(message.sentAt.formatted(date: .abbreviated, time: .shortened))"
    )
  }

  private var messageBody: String {
    let trimmed = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Message" : trimmed
  }

  private var timestamp: String {
    if Calendar.autoupdatingCurrent.isDateInToday(message.sentAt) {
      return message.sentAt.formatted(date: .omitted, time: .shortened)
    }
    return message.sentAt.formatted(date: .abbreviated, time: .shortened)
  }
}

private struct MessagesLoadingState: View {
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
        .tint(PanelTheme.secondary)
      Text(message)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 170)
  }
}

private struct MessagesSyncIssue {
  let symbol: String
  let message: String
  let color: Color
}

private struct MessagesStatusBanner: View {
  let issue: MessagesSyncIssue
  let retry: () -> Void

  var body: some View {
    JoiDrawerButton(action: retry) {
      HStack(spacing: 12) {
        Image(systemName: issue.symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(issue.color)

        Text(issue.message)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(PanelTheme.secondary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text("Retry")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(PanelTheme.primary)
      }
      .padding(.horizontal, 24)
      .frame(minHeight: 52)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(issue.message) Retry sync")
  }
}

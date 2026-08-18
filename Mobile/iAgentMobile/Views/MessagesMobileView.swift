import SwiftUI
import iAgentCore

struct MessagesMobileView: View {
  @ObservedObject var model: MobileAppModel
  private let replyTransport: any MobileMessageReplyTransport
  @State private var selectedConversation: MessageConversationRoute?
  @State private var filter: MobileMessageInboxFilter = .all
  @Environment(\.dismiss) private var dismiss

  init(
    model: MobileAppModel,
    replyTransport: (any MobileMessageReplyTransport)? = nil
  ) {
    self.model = model
    self.replyTransport = replyTransport ?? SystemMobileMessageReplyTransport()
  }

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.44) {
        hero
      } drawer: {
        inbox
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .sheet(item: $selectedConversation) { route in
      MessagesHistorySheet(
        model: model,
        conversationID: route.id,
        replyTransport: replyTransport
      )
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

      messageFilters
        .padding(.top, 14)
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

  private var messageFilters: some View {
    HStack(spacing: 10) {
      messageFilterButton(
        filter: .awaitingReply,
        count: model.awaitingReplyConversationCount,
        label: "awaiting",
        color: PanelTheme.amber
      )

      messageFilterButton(
        filter: .unread,
        count: model.unreadConversationCount,
        label: "unread",
        color: PanelTheme.coral
      )
    }
  }

  private func messageFilterButton(
    filter targetFilter: MobileMessageInboxFilter,
    count: Int,
    label: String,
    color: Color
  ) -> some View {
    let isActive = filter == targetFilter
    return Button {
      withAnimation(PanelTheme.quick) {
        filter = filter.toggled(with: targetFilter)
      }
    } label: {
      HStack(spacing: 7) {
        Circle()
          .fill(count > 0 ? color : PanelTheme.tertiary)
          .frame(width: 8, height: 8)

        Text("\(count) \(label)")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(isActive ? PanelTheme.primary : PanelTheme.secondary)
          .monospacedDigit()
      }
      .padding(.horizontal, 10)
      .frame(minHeight: 44)
      .background(
        isActive ? PanelTheme.surface : Color.clear,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      targetFilter == .awaitingReply
        ? "\(count) conversations awaiting your reply"
        : "\(count) unread conversations"
    )
    .accessibilityValue(isActive ? "Selected" : "Not selected")
    .accessibilityHint(isActive ? "Shows all recent conversations" : "Filters the message list")
  }

  private var inbox: some View {
    let conversations = model.filteredConversations(filter: filter)
    return LazyVStack(spacing: 0) {
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

        if conversations.isEmpty {
          filteredEmptyState
        } else {
          JoiSectionHeader(title: "Last 14 days", count: conversations.count)

          ForEach(Array(conversations.enumerated()), id: \.element.id) { index, conversation in
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

              if index < conversations.count - 1 {
                JoiDottedDivider(inset: 80)
              }
            }
          }
        }
      }
    }
    .padding(.bottom, 96)
  }

  @ViewBuilder
  private var filteredEmptyState: some View {
    switch filter {
    case .all:
      EmptyView()
    case .awaitingReply:
      EmptyPanelState(
        symbol: "checkmark.bubble",
        title: "No replies waiting",
        detail: "Nothing from the last 14 days is waiting for your reply. Tap Awaiting again to show every conversation."
      )
      .padding(.top, 24)
    case .unread:
      EmptyPanelState(
        symbol: "checkmark.message",
        title: "No unread messages",
        detail: "You're all caught up. Tap Unread again to show every conversation."
      )
      .padding(.top, 24)
    }
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

enum MobileMessageAvatarTone: Equatable {
  case group
  case knownDirect
  case unresolvedDirect
}

func mobileMessageAvatarTone(
  for conversation: SyncedMessageConversation
) -> MobileMessageAvatarTone {
  if conversation.isGroup { return .group }

  let genericNames = Set(["contact", "unknown", "unknown contact"])
  let displayName = conversation.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  if genericNames.contains(displayName.lowercased()) || messageNameIsRawIdentifier(displayName) {
    return .unresolvedDirect
  }

  let hasUnresolvedParticipant = conversation.participants.contains { participant in
    let name = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return participant.isContactNameResolved == false
      || genericNames.contains(name.lowercased())
      || messageNameIsRawIdentifier(name)
  }
  return hasUnresolvedParticipant ? .unresolvedDirect : .knownDirect
}

private func messageNameIsRawIdentifier(_ rawValue: String) -> Bool {
  var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !value.isEmpty, value.utf8.count <= 1_024 else { return false }
  if let decoded = value.removingPercentEncoding { value = decoded }

  let schemes = ["mailto:", "tel:", "sms:", "imessage:", "facetime:", "phone:", "email:"]
  let chatPrefixes = ["imessage;-;", "sms;-;"]
  for _ in 0..<2 {
    let folded = value.lowercased()
    if let prefix = chatPrefixes.first(where: { folded.hasPrefix($0) }) {
      value.removeFirst(prefix.count)
      continue
    }
    if let scheme = schemes.first(where: { folded.hasPrefix($0) }) {
      value.removeFirst(scheme.count)
      while value.hasPrefix("/") { value.removeFirst() }
      continue
    }
    break
  }

  if let delimiter = value.firstIndex(where: { $0 == "?" || $0 == "#" || $0 == ";" }) {
    value = String(value[..<delimiter])
  }
  value = value.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.hasPrefix("<"), value.hasSuffix(">"), value.count > 2 {
    value.removeFirst()
    value.removeLast()
  }

  if value.contains("@") {
    let components = value.split(separator: "@", omittingEmptySubsequences: false)
    return components.count == 2 && !components[0].isEmpty && !components[1].isEmpty
  }

  var digits = value.compactMap(\.wholeNumberValue).map(String.init).joined()
  if digits.hasPrefix("00") { digits.removeFirst(2) }
  return (3...32).contains(digits.count)
}

struct JoiMessageAvatar: View {
  let displayName: String
  let tone: MobileMessageAvatarTone
  let size: CGFloat

  init(conversation: SyncedMessageConversation, size: CGFloat) {
    displayName = conversation.displayName
    tone = mobileMessageAvatarTone(for: conversation)
    self.size = size
  }

  init(displayName: String, identity _: String, size: CGFloat) {
    self.displayName = displayName
    tone = .knownDirect
    self.size = size
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(avatarColor.opacity(0.22))

      Text(initials)
        .font(.system(size: size * 0.32, weight: .bold))
        .foregroundStyle(avatarColor)
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

  private var avatarColor: Color {
    switch tone {
    case .group:
      PanelTheme.green
    case .knownDirect:
      PanelTheme.blue
    case .unresolvedDirect:
      PanelTheme.amber
    }
  }
}

private struct MessagesHistorySheet: View {
  @ObservedObject var model: MobileAppModel
  let conversationID: String
  let replyTransport: any MobileMessageReplyTransport

  @Environment(\.dismiss) private var dismiss
  @State private var draftBody = ""
  @State private var selectedRecipientIDs = Set<String>()
  @State private var composeRoute: MobileMessageComposeRoute?
  @State private var replyAlert: MobileMessageReplyAlert?
  @State private var replyTransportEnabled = MessageReplyPreferences.isEnabled(in: .standard)

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
          JoiDottedDivider(inset: 20)
          replyComposer(conversation)
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
    .fullScreenCover(item: $composeRoute) { route in
      MobileMessageReplyComposer(
        request: route.request,
        transport: replyTransport,
        onCompletion: finishCompose
      )
      .ignoresSafeArea()
    }
    .alert(item: $replyAlert) { alert in
      switch alert {
      case .enable:
        Alert(
          title: Text("Enable reply handoff?"),
          message: Text(
            "This setting applies to every eligible one-to-one conversation in your rolling 14-day Messages inbox. iAgent can prepare a phone number and draft only when your Mac has separately opted in to share validated reply addresses through your private iCloud data. Apple's composer appears for review, and you choose whether to Send."
          ),
          primaryButton: .cancel(),
          secondaryButton: .default(Text("Enable")) {
            MessageReplyPreferences.setEnabled(true, in: .standard)
            replyTransportEnabled = true
            if let conversation {
              reconcileRecipientSelection(for: conversation)
            }
          }
        )
      case let .notice(title, message):
        Alert(
          title: Text(title),
          message: Text(message),
          dismissButton: .default(Text("OK"))
        )
      }
    }
    .task(id: latestIncomingMessageID) {
      guard latestIncomingMessageID != nil else { return }
      await model.markConversationRead(conversationID)
    }
    .onAppear {
      if let conversation {
        reconcileRecipientSelection(for: conversation)
      }
    }
    .onChange(of: conversation?.participants ?? []) { _, _ in
      if let conversation {
        reconcileRecipientSelection(for: conversation)
      }
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

  @ViewBuilder
  private func replyComposer(_ conversation: SyncedMessageConversation) -> some View {
    if conversation.isGroup {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "person.2.slash")
          Text("Group replies are not available yet")
            .fontWeight(.semibold)
          Spacer(minLength: 12)
          if replyTransportEnabled {
            Button("Turn off") { setReplyTransportEnabled(false) }
          }
        }
        .font(.system(size: 12))
        .foregroundStyle(PanelTheme.secondary)

        Text("Phase 1 supports one-to-one conversations only. This group stays read only.")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(PanelTheme.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    } else if !replyTransportEnabled {
      HStack(spacing: 12) {
        Label("Read-only inbox", systemImage: "lock")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(PanelTheme.secondary)

        Spacer(minLength: 12)

        Button("Enable replies") {
          replyAlert = .enable
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(PanelTheme.blue)
        .frame(minHeight: 44)
        .accessibilityHint("Explains the user-confirmed Apple Messages handoff")
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 8)
    } else if eligibleRecipients(for: conversation).isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "person.crop.circle.badge.exclamationmark")
          Text("Recipient unavailable")
            .fontWeight(.semibold)
          Spacer(minLength: 12)
          Button("Turn off") { setReplyTransportEnabled(false) }
        }
        .font(.system(size: 12))
        .foregroundStyle(PanelTheme.secondary)

        Text(
          "Enable reply handoff on the Mac that provides Messages, then sync again. iPhone replies require a validated phone number; names, email handles, and IDs are never guessed."
        )
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(PanelTheme.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    } else {
      VStack(spacing: 8) {
        HStack(spacing: 10) {
          recipientMenu(conversation)

          TextField("Write a reply", text: $draftBody, axis: .vertical)
            .lineLimit(1...4)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(PanelTheme.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(PanelTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 14))
            .onChange(of: draftBody) { _, value in
              guard value.count > MessageReplyRequest.maximumBodyCharacterCount else { return }
              draftBody = String(value.prefix(MessageReplyRequest.maximumBodyCharacterCount))
            }

          Button(action: { openSystemComposer(for: conversation) }) {
            Image(systemName: "arrow.up")
              .font(.system(size: 14, weight: .bold))
              .foregroundStyle(canOpenComposer(for: conversation) ? Color.white : PanelTheme.tertiary)
              .frame(width: 42, height: 42)
              .background(
                canOpenComposer(for: conversation) ? PanelTheme.blue : PanelTheme.surface,
                in: Circle()
              )
          }
          .buttonStyle(.plain)
          .disabled(!canOpenComposer(for: conversation))
          .accessibilityLabel("Review reply in Messages")
          .accessibilityHint("Opens Apple's composer; Send still requires your confirmation")
        }

        HStack {
          Text("Apple's composer always asks you to review and Send.")
          Spacer(minLength: 12)
          Button("Turn off") { setReplyTransportEnabled(false) }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(PanelTheme.tertiary)
      }
      .padding(.horizontal, 18)
      .padding(.top, 10)
      .padding(.bottom, 12)
    }
  }

  private func recipientMenu(_ conversation: SyncedMessageConversation) -> some View {
    let recipients = eligibleRecipients(for: conversation)
    return Menu {
      ForEach(recipients) { recipient in
        Button {
          selectedRecipientIDs = selectedRecipientIDs.contains(recipient.id)
            ? Set<String>()
            : Set([recipient.id])
        } label: {
          Label(
            recipient.displayName,
            systemImage: selectedRecipientIDs.contains(recipient.id)
              ? "checkmark.circle.fill"
              : "circle"
          )
        }
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text("TO")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(PanelTheme.tertiary)
        Text(recipientSummary(in: recipients))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(PanelTheme.secondary)
          .lineLimit(1)
      }
      .frame(width: 78, alignment: .leading)
      .frame(minHeight: 42, alignment: .leading)
      .contentShape(Rectangle())
    }
    .accessibilityLabel("Reply recipients")
    .accessibilityValue(recipientSummary(in: recipients))
  }

  private func eligibleRecipients(
    for conversation: SyncedMessageConversation
  ) -> [MessageReplyRecipient] {
    guard !conversation.isGroup else { return [] }
    return conversation.participants
      .compactMap(MessageReplyRecipient.init(participant:))
      .filter { $0.address.kind == .phone }
  }

  private func selectedRecipients(
    for conversation: SyncedMessageConversation
  ) -> [MessageReplyRecipient] {
    eligibleRecipients(for: conversation).filter { selectedRecipientIDs.contains($0.id) }
  }

  private func recipientSummary(in recipients: [MessageReplyRecipient]) -> String {
    let selected = recipients.filter { selectedRecipientIDs.contains($0.id) }
    if selected.isEmpty { return "Choose" }
    return selected[0].displayName
  }

  private func reconcileRecipientSelection(for conversation: SyncedMessageConversation) {
    let validIDs = Set(eligibleRecipients(for: conversation).map(\.id))
    selectedRecipientIDs.formIntersection(validIDs)
    if selectedRecipientIDs.count != 1 {
      selectedRecipientIDs = eligibleRecipients(for: conversation).first
        .map { Set([$0.id]) } ?? Set<String>()
    }
  }

  private func canOpenComposer(for conversation: SyncedMessageConversation) -> Bool {
    !conversation.isGroup
      && replyTransport.canSendText()
      && selectedRecipients(for: conversation).count == 1
      && !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func openSystemComposer(for conversation: SyncedMessageConversation) {
    do {
      let request = try MessageReplyRequest(
        recipients: selectedRecipients(for: conversation),
        body: draftBody
      )
      composeRoute = MobileMessageComposeRoute(request: request)
    } catch {
      replyAlert = .notice(
        title: "Cannot prepare reply",
        message: error.localizedDescription
      )
    }
  }

  private func finishCompose(_ completion: MessageReplyCompletion) {
    composeRoute = nil
    switch completion {
    case .cancelled:
      break
    case .sendRequested:
      draftBody = ""
      replyAlert = .notice(
        title: "Send requested",
        message: "You confirmed Send in Apple's composer. Messages handles delivery; iAgent cannot verify it."
      )
    case .failed(let detail):
      replyAlert = .notice(title: "Messages could not continue", message: detail)
    }
  }

  private func setReplyTransportEnabled(_ enabled: Bool) {
    MessageReplyPreferences.setEnabled(enabled, in: .standard)
    replyTransportEnabled = enabled
    if !enabled {
      draftBody = ""
      composeRoute = nil
    }
  }
}

private struct MobileMessageComposeRoute: Identifiable {
  let id = UUID()
  let request: MessageReplyRequest
}

private enum MobileMessageReplyAlert: Identifiable {
  case enable
  case notice(title: String, message: String)

  var id: String {
    switch self {
    case .enable:
      "enable"
    case let .notice(title, message):
      "notice:\(title):\(message)"
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

import AppKit
import SwiftUI
import iAgentCore

enum MessageInboxLayout {
    static let searchAccessorySize: CGFloat = 24
    static let searchVerticalInset: CGFloat = 8
    static let searchRowHeight: CGFloat = searchAccessorySize + searchVerticalInset * 2
    static let searchFontSize: CGFloat = 12
    static let metadataGap: CGFloat = 20
    static let metadataWidth: CGFloat = 90
    static let relativeTimeWidth: CGFloat = 22
}

enum MessageAvatarTone: Equatable {
    case group
    case knownDirect
    case unresolvedDirect
}

func messageAvatarTone(for conversation: SyncedMessageConversation) -> MessageAvatarTone {
    if conversation.isGroup {
        return .group
    }
    let genericNames = Set(["contact", "unknown", "unknown contact"])
    let displayName = conversation.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let participantIsUnresolved = conversation.participants.contains { participant in
        let name = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return MessageContactIdentifier.normalized(name) != nil
            || genericNames.contains(name.lowercased())
    }
    if MessageContactIdentifier.normalized(displayName) != nil
        || genericNames.contains(displayName.lowercased())
        || participantIsUnresolved
    {
        return .unresolvedDirect
    }
    return .knownDirect
}

func messageFullDiskAccessSettingsURL() -> URL? {
    URL(
        string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )
}

struct MessageInboxView: View {
    @ObservedObject var controller: PanelController
    var filter: MessageInboxFilter = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let selectedConversation {
                MessageConversationPage(
                    controller: controller,
                    conversation: selectedConversation,
                    messages: controller.retainedMessages(for: selectedConversation.id),
                    replyTransport: AppStoreMessagesHandoffTransport()
                )
            } else if controller.visibleMessageConversations.isEmpty {
                availabilityState
            } else {
                conversationList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .timingCurve(0.2, 0, 0, 1, duration: 0.16),
            value: controller.selectedMessageConversationID
        )
    }

    private var conversationList: some View {
        VStack(spacing: 0) {
            messageSearchRow

            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)

            if filteredConversations.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                    Text(emptyConversationLabel)
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.38))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("No matching message conversations")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredConversations) { conversation in
                            MessageConversationRow(
                                conversation: conversation,
                                latestMessage: controller.retainedMessages(for: conversation.id).last,
                                unreadCount: controller.unreadCount(for: conversation.id),
                                isAwaitingReply: controller.isAwaitingReply(for: conversation),
                                referenceDate: controller.referenceNow
                            ) {
                                controller.selectMessageConversation(conversation.id)
                            }

                            Rectangle()
                                .fill(.white.opacity(0.065))
                                .frame(height: 1)
                                .padding(.leading, 60)
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                            Text("Rolling 14 days · private sync")
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.vertical, 12)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var messageSearchRow: some View {
        HStack(spacing: 0) {
            TextField("Search messages", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: MessageInboxLayout.searchFontSize, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
                .focused($searchFocused)
                .accessibilityLabel("Search messages")

            Group {
                if searchText.isEmpty {
                    Color.clear
                } else {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .help("Clear message search")
                    .accessibilityLabel("Clear message search")
                }
            }
            .frame(
                width: MessageInboxLayout.searchAccessorySize,
                height: MessageInboxLayout.searchAccessorySize
            )
        }
        .padding(.horizontal, PanelPageLayout.contentInset)
        .padding(.vertical, MessageInboxLayout.searchVerticalInset)
        .frame(height: MessageInboxLayout.searchRowHeight)
        .background(ExpandedPanelBackground())
    }

    private var filteredConversations: [SyncedMessageConversation] {
        controller.filteredMessageConversations(matching: searchText, filter: filter)
    }

    private var emptyConversationLabel: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching conversations"
        }
        switch filter {
        case .all:
            return "No recent conversations"
        case .awaitingReply:
            return "No conversations awaiting your reply"
        case .unread:
            return "No unread conversations"
        }
    }

    @ViewBuilder
    private var availabilityState: some View {
        if controller.isMessageInboxSyncing {
            MessageAvailabilityView(
                symbol: "message",
                title: "Loading messages",
                detail: "Syncing the private inbox on this Mac.",
                showsProgress: true
            )
        } else {
            switch controller.messageProviderAccess {
            case .loading:
                MessageAvailabilityView(
                    symbol: "message",
                    title: "Loading messages",
                    detail: "Checking the private inbox on this Mac.",
                    showsProgress: true
                )
            case .authorized:
                MessageAvailabilityView(
                    symbol: "message",
                    title: "No recent messages",
                    detail: "Conversations from the last 14 days will appear here."
                )
            case let .permissionRequired(detail):
                MessageAvailabilityView(
                    symbol: "lock.shield",
                    title: "Messages access is off",
                    detail: detail,
                    actionTitle: controller.messageAccessRecoveryActionTitle,
                    action: controller.recoverLocalMessagesAccess
                )
            case let .disabled(detail):
                MessageAvailabilityView(
                    symbol: "message.badge",
                    title: "Messages source is off",
                    detail: detail,
                    actionTitle: "Connect Messages",
                    action: controller.connectLocalMessages
                )
            case let .failed(detail):
                MessageAvailabilityView(
                    symbol: "exclamationmark.triangle",
                    title: "Messages unavailable",
                    detail: detail
                )
            }
        }
    }

    private var selectedConversation: SyncedMessageConversation? {
        guard let selectedID = controller.selectedMessageConversationID else { return nil }
        return controller.visibleMessageConversations.first { $0.id == selectedID }
    }

}

private struct MessageConversationRow: View {
    let conversation: SyncedMessageConversation
    let latestMessage: SyncedMessage?
    let unreadCount: Int
    let isAwaitingReply: Bool
    let referenceDate: Date
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MessageAvatarView(conversation: conversation, size: 26)

                HStack(spacing: 6) {
                    Text(conversation.displayName)
                        .font(.system(size: 11.5, weight: unreadCount > 0 ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(unreadCount > 0 ? 0.95 : 0.76))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(2)

                    Text("·")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.24))
                        .accessibilityHidden(true)

                    Text(preview)
                        .font(.system(size: 10.5, weight: unreadCount > 0 ? .medium : .regular))
                        .foregroundStyle(.white.opacity(unreadCount > 0 ? 0.56 : 0.38))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: MessageInboxLayout.metadataGap) {
                    stateMarker(isVisible: isAwaitingReply, color: .agentAmber)
                    stateMarker(isVisible: unreadCount > 0, color: .agentCoral)

                    Text(relativeTime)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(unreadCount > 0 ? 0.58 : 0.34))
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: MessageInboxLayout.relativeTimeWidth, alignment: .leading)
                }
                .frame(width: MessageInboxLayout.metadataWidth, alignment: .trailing)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, PanelPageLayout.contentInset)
            .frame(height: 50)
            .contentShape(Rectangle())
            .background(.white.opacity(hovering ? 0.03 : 0))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(conversation.displayName)
        .accessibilityValue(
            accessibilityValue
        )
        .accessibilityHint("Open read-only message history")
    }

    private func stateMarker(isVisible: Bool, color: Color) -> some View {
        Circle()
            .fill(isVisible ? color : .clear)
            .frame(width: 6, height: 6)
    }

    private var preview: String {
        guard let latestMessage else { return conversation.latestPreview }
        let body = latestMessage.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = latestMessage.isFromMe ? "You: " : ""
        return prefix + (body.isEmpty ? "Message" : body)
    }

    private var accessibilityValue: String {
        var states: [String] = []
        states.append(unreadCount == 0 ? "Read" : "\(unreadCount) source unread")
        if isAwaitingReply {
            states.append("Awaiting your reply")
        }
        states.append(preview)
        return states.joined(separator: ". ")
    }

    private var relativeTime: String {
        let date = latestMessage?.sentAt ?? conversation.latestMessageDate
        let elapsed = max(0, referenceDate.timeIntervalSince(date))
        if elapsed < 60 { return "now" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h" }
        return "\(Int(elapsed / 86_400))d"
    }
}

private struct MessageConversationPage: View {
    @ObservedObject var controller: PanelController
    let conversation: SyncedMessageConversation
    let messages: [SyncedMessage]
    @State private var replyTransport: any MacMessageReplyTransport
    @State private var draftBody = ""
    @State private var selectedRecipientIDs = Set<String>()
    @State private var pendingRequest: MessageReplyRequest?
    @State private var replyAlert: MacMessageReplyAlert?

    init(
        controller: PanelController,
        conversation: SyncedMessageConversation,
        messages: [SyncedMessage],
        replyTransport: any MacMessageReplyTransport
    ) {
        self.controller = controller
        self.conversation = conversation
        self.messages = messages
        _replyTransport = State(initialValue: replyTransport)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelPageHeader(
                title: "Back to Messages",
                titleRole: .messages,
                placement: .navigation,
                onBack: controller.closeMessageConversation,
                backHelp: "Back to Messages",
                focusesBackOnAppear: true,
                titleActsAsBackLabel: true
            ) {
                Text(
                    conversation.isGroup
                        ? "Read only"
                        : controller.messageReplyTransportEnabled ? "Messages handoff" : "Read only"
                )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }

            HStack(spacing: 10) {
                MessageAvatarView(conversation: conversation, size: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)

                    Text("Messages from the last 14 days")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.36))
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, PanelPageLayout.contentInset)
            .frame(height: 50)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.055))
                    .frame(height: 1)
            }

            MessageConversationHistory(
                conversation: conversation,
                messages: messages
            )

            Rectangle()
                .fill(.white.opacity(0.055))
                .frame(height: 1)

            replyComposer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation with \(conversation.displayName)")
        .onAppear(perform: reconcileRecipientSelection)
        .onChange(of: eligibleRecipients.map(\.id)) {
            reconcileRecipientSelection()
        }
        .alert(item: $replyAlert) { alert in
            switch alert {
            case .enable:
                Alert(
                    title: Text("Enable Messages handoff?"),
                    message: Text(
                        "This setting applies to every eligible one-to-one conversation in your rolling 14-day Messages inbox. iAgent will include validated recipient addresses in your private iCloud message projection so replies can also be prepared on iPhone. Every draft is handed to Apple's Messages UI for review; iAgent never presses Send or confirms delivery."
                    ),
                    primaryButton: .cancel(),
                    secondaryButton: .default(Text("Enable")) {
                        controller.setMessageReplyTransportEnabled(true)
                    }
                )
            case .confirm:
                Alert(
                    title: Text("Open in Messages?"),
                    message: Text(
                        "The selected recipient and this draft will be handed to macOS. If Messages opens, review them there; iAgent will not press Send and cannot verify that the compose window opened, the message was sent, or delivered."
                    ),
                    primaryButton: .cancel {
                        pendingRequest = nil
                    },
                    secondaryButton: .default(Text("Open Messages")) {
                        beginConfirmedHandoff()
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
    }

    @ViewBuilder
    private var replyComposer: some View {
        if conversation.isGroup {
            HStack(spacing: 9) {
                Image(systemName: "person.2.slash")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Group replies are not available yet")
                        .fontWeight(.semibold)
                    Text("Phase 1 supports one-to-one conversations only. This group stays read only.")
                        .foregroundStyle(.white.opacity(0.3))
                }

                Spacer(minLength: 10)

                if controller.messageReplyTransportEnabled {
                    Button("Turn off") { setReplyTransportEnabled(false) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.agentBlue)
                }
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
            .padding(.horizontal, PanelPageLayout.contentInset)
            .frame(minHeight: 50)
        } else if !controller.messageReplyTransportEnabled {
            HStack(spacing: 10) {
                Label("Read-only inbox", systemImage: "lock")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))

                Spacer(minLength: 12)

                Button("Enable replies") {
                    replyAlert = .enable
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.agentBlue)
                .frame(minHeight: 36)
                .accessibilityHint("Explains the public, user-confirmed Messages handoff")
            }
            .padding(.horizontal, PanelPageLayout.contentInset)
            .frame(minHeight: 48)
        } else if eligibleRecipients.isEmpty {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                Text(
                    controller.isMessageInboxSyncing
                        ? "Refreshing reply recipients…"
                        : "No validated reply recipient is available."
                )
                .lineLimit(2)

                Spacer(minLength: 10)

                Button("Turn off") { setReplyTransportEnabled(false) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.agentBlue)
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
            .padding(.horizontal, PanelPageLayout.contentInset)
            .frame(minHeight: 50)
        } else {
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    recipientMenu

                    TextField("Write a reply", text: $draftBody, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            .white.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .onChange(of: draftBody) {
                            guard draftBody.count > MessageReplyRequest.maximumBodyCharacterCount
                            else { return }
                            draftBody = String(
                                draftBody.prefix(MessageReplyRequest.maximumBodyCharacterCount)
                            )
                        }

                    Button {
                        prepareHandoffConfirmation()
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(
                                canPrepareHandoff
                                    ? Color.agentBlue.opacity(0.2)
                                    : Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        canPrepareHandoff ? Color.agentBlue : Color.white.opacity(0.24)
                    )
                    .disabled(!canPrepareHandoff)
                    .help("Review in Messages")
                    .accessibilityLabel("Review reply in Messages")
                    .accessibilityHint(
                        "Confirms the handoff before opening Apple's Messages compose UI"
                    )
                }

                HStack {
                    Text("No background send · Messages asks you to review")
                    Spacer(minLength: 10)
                    Button("Turn off") { setReplyTransportEnabled(false) }
                        .buttonStyle(.plain)
                }
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.28))
            }
            .padding(.horizontal, PanelPageLayout.contentInset)
            .padding(.vertical, 8)
        }
    }

    private var recipientMenu: some View {
        Menu {
            ForEach(eligibleRecipients) { recipient in
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
            VStack(alignment: .leading, spacing: 1) {
                Text("TO")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.26))
                Text(recipientSummary)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            .frame(width: 82, height: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Reply recipients")
        .accessibilityValue(recipientSummary)
    }

    private var eligibleRecipients: [MessageReplyRecipient] {
        guard !conversation.isGroup else { return [] }
        conversation.participants.compactMap(MessageReplyRecipient.init(participant:))
    }

    private var selectedRecipients: [MessageReplyRecipient] {
        eligibleRecipients.filter { selectedRecipientIDs.contains($0.id) }
    }

    private var recipientSummary: String {
        if selectedRecipients.isEmpty { return "Choose" }
        return selectedRecipients[0].displayName
    }

    private var canPrepareHandoff: Bool {
        !conversation.isGroup
            && selectedRecipients.count == 1
            && !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reconcileRecipientSelection() {
        let validIDs = Set(eligibleRecipients.map(\.id))
        selectedRecipientIDs.formIntersection(validIDs)
        if selectedRecipientIDs.count != 1 {
            selectedRecipientIDs = eligibleRecipients.first.map { Set([$0.id]) }
                ?? Set<String>()
        }
    }

    private func prepareHandoffConfirmation() {
        do {
            pendingRequest = try MessageReplyRequest(
                recipients: selectedRecipients,
                body: draftBody
            )
            replyAlert = .confirm
        } catch {
            replyAlert = .notice(
                title: "Cannot prepare handoff",
                message: error.localizedDescription
            )
        }
    }

    private func beginConfirmedHandoff() {
        guard let request = pendingRequest else { return }
        defer { pendingRequest = nil }
        do {
            _ = try replyTransport.beginUserConfirmedHandoff(request)
            replyAlert = .notice(
                title: "Messages handoff requested",
                message: "macOS received the handoff request. If Messages opens, review the recipient and draft there, then choose whether to Send. iAgent cannot confirm that the compose window opened, the message was sent, or delivered."
            )
        } catch {
            replyAlert = .notice(
                title: "Messages handoff unavailable",
                message: error.localizedDescription
            )
        }
    }

    private func setReplyTransportEnabled(_ enabled: Bool) {
        controller.setMessageReplyTransportEnabled(enabled)
        if !enabled {
            draftBody = ""
            pendingRequest = nil
        }
    }
}

private enum MacMessageReplyAlert: Identifiable {
    case enable
    case confirm
    case notice(title: String, message: String)

    var id: String {
        switch self {
        case .enable:
            "enable"
        case .confirm:
            "confirm"
        case let .notice(title, message):
            "notice:\(title):\(message)"
        }
    }
}

private struct MessageConversationHistory: View {
    let conversation: SyncedMessageConversation
    let messages: [SyncedMessage]

    var body: some View {
        Group {
            if messages.isEmpty {
                Text("No recent message history")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 8) {
                            ForEach(messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, PanelPageLayout.contentInset)
                        .padding(.vertical, 12)
                    }
                    .scrollIndicators(.automatic)
                    .onAppear {
                        scrollToLatest(using: proxy)
                    }
                    .onChange(of: messages.last?.id) {
                        scrollToLatest(using: proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation history with \(conversation.displayName)")
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard let latestMessageID = messages.last?.id else { return }
        proxy.scrollTo(latestMessageID, anchor: .bottom)
    }

    private func messageBubble(_ message: SyncedMessage) -> some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 56) }

            VStack(alignment: .leading, spacing: 3) {
                if conversation.isGroup,
                   !message.isFromMe,
                   let sender = message.senderDisplayName,
                   !sender.isEmpty
                {
                    Text(sender)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Text(message.body.isEmpty ? "Message" : message.body)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)

                Text(message.sentAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                message.isFromMe
                    ? Color.agentBlue.opacity(0.16)
                    : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            if !message.isFromMe { Spacer(minLength: 56) }
        }
    }
}

struct MessageSyncHealthView: View {
    let isSyncing: Bool
    let status: IAgentCloudSyncStatus
    let access: MessageProviderAccessState

    var body: some View {
        ZStack {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            if isSyncing, isHealthy {
                Circle()
                    .stroke(statusColor.opacity(0.34), lineWidth: 1)
                    .frame(width: 11, height: 11)
            }
        }
        .frame(width: 22, height: 28)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusLabel)
        .animation(.easeOut(duration: 0.14), value: statusColor)
    }

    private var statusColor: Color {
        switch access {
        case .failed: return .agentCoral
        case .permissionRequired: return .agentAmber
        case .disabled: return .white.opacity(0.28)
        case .loading: return .agentAmber.opacity(0.78)
        case .authorized: break
        }
        switch status.phase {
        case .idle, .syncing: return .agentGreen
        case .offline, .accountUnavailable: return .agentAmber
        case .failed: return .agentCoral
        }
    }

    private var statusLabel: String {
        switch access {
        case .loading: return "Checking Messages sync access"
        case .permissionRequired: return "Messages sync needs Full Disk Access"
        case .disabled: return "Messages sync is disconnected"
        case .failed: return "Messages source failed"
        case .authorized: break
        }
        if isSyncing { return "Messages sync is active and healthy" }
        switch status.phase {
        case .idle: return "Messages sync is healthy and current"
        case .syncing: return "Messages sync is active and healthy"
        case .offline: return "Messages sync is offline"
        case .accountUnavailable: return "iCloud account unavailable"
        case .failed: return "Messages sync failed"
        }
    }

    private var isHealthy: Bool {
        guard access == .authorized else { return false }
        return status.phase == .idle || status.phase == .syncing
    }
}

private struct MessageAvatarView: View {
    let conversation: SyncedMessageConversation
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(avatarColor.opacity(0.22))
            Text(initials)
                .font(.system(size: size * 0.31, weight: .semibold, design: .rounded))
                .foregroundStyle(avatarColor.opacity(0.94))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(0.11), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = conversation.displayName.split(whereSeparator: { $0.isWhitespace })
        if parts.count > 1 {
            return (
                String(parts[0].prefix(1)) + String(parts[parts.count - 1].prefix(1))
            ).uppercased()
        }
        return String(conversation.displayName.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        switch messageAvatarTone(for: conversation) {
        case .group:
            .agentGreen
        case .knownDirect:
            .agentBlue
        case .unresolvedDirect:
            .agentAmber
        }
    }
}

private struct MessageAvailabilityView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let symbol: String
    let title: String
    let detail: String
    var showsProgress = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            if showsProgress {
                if reduceMotion {
                    Circle()
                        .fill(Color.agentBlue.opacity(0.82))
                        .frame(width: 7, height: 7)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.65))
                }
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white.opacity(0.34))
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))

            Text(detail)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 330)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.agentBlue)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import AppKit
import SwiftUI
import iAgentCore

enum MessageInboxLayout {
    static let sidebarWidth: CGFloat = 268
    static let conversationRowHeight: CGFloat = 58
    static let detailHeaderHeight: CGFloat = 46
    static let composerHeight: CGFloat = 38
    static let composerActionSize: CGFloat = 28
    static let detailRevealDuration: TimeInterval = 0.22
    static let searchAccessorySize: CGFloat = 24
    static let searchVerticalInset: CGFloat = 8
    static let searchRowHeight: CGFloat = searchAccessorySize + searchVerticalInset * 2
    static let searchFontSize: CGFloat = 12
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
            if controller.visibleMessageConversations.isEmpty,
               selectedConversation == nil
            {
                availabilityState
            } else {
                splitInbox
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var splitInbox: some View {
        HStack(spacing: 0) {
            conversationList
                .frame(width: MessageInboxLayout.sidebarWidth)
                .background(Color.white.opacity(0.012))
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(.white.opacity(0.075))
                        .frame(width: 1)
                }

            ZStack {
                Color.clear

                if let selectedConversation {
                    MessageConversationPage(
                        controller: controller,
                        conversation: selectedConversation,
                        messages: controller.retainedMessages(for: selectedConversation.id),
                        replyTransport: DirectMessagesReplyTransport()
                    )
                    .id(selectedConversation.id)
                    .transition(detailTransition)
                } else {
                    conversationPlaceholder
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .animation(detailAnimation, value: controller.selectedMessageConversationID)
    }

    private var conversationPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "message")
                .font(.system(size: 16, weight: .medium))
            Text("Select a conversation")
                .font(.system(size: 11.5, weight: .semibold))
            Text("Your inbox stays visible while you read and reply.")
                .font(.system(size: 9.5, weight: .regular))
        }
        .foregroundStyle(.white.opacity(0.34))
        .multilineTextAlignment(.center)
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    private var detailAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .timingCurve(
                0.2,
                0.8,
                0.2,
                1,
                duration: MessageInboxLayout.detailRevealDuration
            )
    }

    private var detailTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .modifier(
            active: MessageDetailRevealModifier(opacity: 0, horizontalOffset: 6),
            identity: MessageDetailRevealModifier(opacity: 1, horizontalOffset: 0)
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
                                isSelected: controller.selectedMessageConversationID == conversation.id,
                                referenceDate: controller.referenceNow
                            ) {
                                controller.selectMessageConversation(conversation.id)
                            }

                            Rectangle()
                                .fill(.white.opacity(0.065))
                                .frame(height: 1)
                                .padding(.leading, 54)
                                .padding(.trailing, 8)
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
        return controller.messageConversationForDisplay(selectedID)
    }

}

private struct MessageConversationRow: View {
    let conversation: SyncedMessageConversation
    let latestMessage: SyncedMessage?
    let unreadCount: Int
    let isAwaitingReply: Bool
    let isSelected: Bool
    let referenceDate: Date
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MessageAvatarView(conversation: conversation, size: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(conversation.displayName)
                            .font(
                                .system(
                                    size: 11.5,
                                    weight: unreadCount > 0 ? .semibold : .medium
                                )
                            )
                            .foregroundStyle(.white.opacity(unreadCount > 0 ? 0.95 : 0.78))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)

                        Spacer(minLength: 4)

                        Text(relativeTime)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(unreadCount > 0 ? 0.58 : 0.34))
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    HStack(spacing: 5) {
                        Text(preview)
                            .font(
                                .system(
                                    size: 10,
                                    weight: unreadCount > 0 ? .medium : .regular
                                )
                            )
                            .foregroundStyle(.white.opacity(unreadCount > 0 ? 0.58 : 0.4))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 2)

                        stateMarker(isVisible: isAwaitingReply, color: .agentAmber)
                        stateMarker(isVisible: unreadCount > 0, color: .agentCoral)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(height: MessageInboxLayout.conversationRowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(
                Color.white.opacity(isSelected ? 0.085 : (hovering ? 0.035 : 0)),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(conversation.displayName)
        .accessibilityValue(
            accessibilityValue
        )
        .accessibilityHint("Show this conversation alongside the inbox")
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

private struct MessageDetailRevealModifier: ViewModifier {
    let opacity: Double
    let horizontalOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(x: horizontalOffset)
    }
}

private struct MessageConversationPage: View {
    @ObservedObject var controller: PanelController
    let conversation: SyncedMessageConversation
    let messages: [SyncedMessage]
    @State private var replyTransport: any MacMessageReplyTransport
    @StateObject private var replyDictation: SpeechDictationService
    @FocusState private var replyFieldFocused: Bool
    @State private var draftBody = ""
    @State private var selectedRecipientIDs = Set<String>()
    @State private var resolvedRecipients: [MessageReplyRecipient] = []
    @State private var isResolvingRecipient = false
    @State private var isSendingReply = false
    @State private var isStartingReplyDictation = false
    @State private var retryAfterMessagesAccess = false
    @State private var recipientResolutionTask: Task<Void, Never>?
    @State private var pendingFallbackRequest: MessageReplyRequest?
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
        _replyDictation = StateObject(wrappedValue: SpeechDictationService())
        _draftBody = State(initialValue: controller.messageReplyDraft(for: conversation.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MessageAvatarView(conversation: conversation, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)

                    Text(conversation.isGroup ? "Group conversation · Read only" : "Last 14 days")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.36))
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 14)
            .frame(height: MessageInboxLayout.detailHeaderHeight)
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
        .onChange(of: replyDictation.transcript) { _, transcript in
            guard replyDictation.isRecording else { return }
            draftBody = String(
                transcript.prefix(MessageReplyRequest.maximumBodyCharacterCount)
            )
        }
        .onChange(of: replyDictation.errorMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            isStartingReplyDictation = false
            replyAlert = .notice(title: "Voice input unavailable", message: message)
        }
        .onChange(of: controller.messageProviderAccess) {
            guard retryAfterMessagesAccess else { return }
            switch controller.messageProviderAccess {
            case .authorized:
                retryAfterMessagesAccess = false
                isResolvingRecipient = false
                beginRecipientResolution()
            case let .permissionRequired(message):
                retryAfterMessagesAccess = false
                isResolvingRecipient = false
                replyAlert = .accessRequired(accessPrompt(message))
            case let .disabled(message):
                retryAfterMessagesAccess = false
                isResolvingRecipient = false
                replyAlert = .connectRequired(accessPrompt(message))
            case let .failed(message):
                retryAfterMessagesAccess = false
                isResolvingRecipient = false
                replyAlert = .notice(title: "Messages unavailable", message: message)
            case .loading:
                break
            }
        }
        .onDisappear {
            recipientResolutionTask?.cancel()
            recipientResolutionTask = nil
            replyDictation.cancel()
            isStartingReplyDictation = false
        }
        .alert(item: $replyAlert) { alert in
            switch alert {
            case let .connectRequired(message):
                Alert(
                    title: Text("Connect Messages to reply?"),
                    message: Text(message),
                    primaryButton: .cancel(),
                    secondaryButton: .default(Text("Connect Messages")) {
                        retryAfterMessagesAccess = true
                        controller.connectLocalMessages()
                    }
                )
            case let .accessRequired(message):
                Alert(
                    title: Text("Allow Messages access to reply?"),
                    message: Text(message),
                    primaryButton: .cancel(),
                    secondaryButton: .default(
                        Text(controller.messageAccessRecoveryActionTitle)
                    ) {
                        retryAfterMessagesAccess = true
                        controller.recoverLocalMessagesAccess()
                    }
                )
            case let .fallbackRequired(message):
                Alert(
                    title: Text("Open in Messages?"),
                    message: Text(
                        "\(message)\n\nYour draft stays in iAgent. Opening Messages is a separate fallback and will not send automatically."
                    ),
                    primaryButton: .cancel {
                        pendingFallbackRequest = nil
                    },
                    secondaryButton: .default(Text("Open Messages")) {
                        beginConfirmedFallback()
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
            HStack(spacing: 8) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 11, weight: .medium))

                Text("Group replies are not available yet")
                    .fontWeight(.medium)

                Spacer(minLength: 10)
            }
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(.white.opacity(0.36))
            .padding(.horizontal, 12)
            .frame(height: MessageInboxLayout.composerHeight)
            .background(
                Color.white.opacity(0.035),
                in: RoundedRectangle(
                    cornerRadius: MessageInboxLayout.composerHeight / 2,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: MessageInboxLayout.composerHeight / 2,
                    style: .continuous
                )
                .stroke(.white.opacity(0.055), lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Group replies are not available. Phase 1 supports one-to-one conversations only."
            )
        } else {
            HStack(spacing: 2) {
                TextField(replyPlaceholder, text: $draftBody, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.94))
                    .focused($replyFieldFocused)
                    .padding(.leading, 12)
                    .frame(height: MessageInboxLayout.composerHeight)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            return .handled
                        }
                        guard keyPress.modifiers.intersection([.command, .control, .option]).isEmpty
                        else { return .ignored }
                        if canAttemptSend {
                            attemptSend()
                        }
                        return .handled
                    }
                    .onChange(of: draftBody) {
                        guard draftBody.count > MessageReplyRequest.maximumBodyCharacterCount
                        else { return }
                        draftBody = String(
                            draftBody.prefix(MessageReplyRequest.maximumBodyCharacterCount)
                        )
                    }
                    .onChange(of: draftBody) { _, draft in
                        controller.storeMessageReplyDraft(draft, for: conversation.id)
                    }
                    .accessibilityLabel("Message")
                    .accessibilityHint("Press Return to send.")

                Button(action: performReplyAction) {
                    ZStack {
                        if replyActionIsBusy {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.72)
                                .tint(.white.opacity(0.9))
                        } else if hasReplyDraft {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: replyDictation.isRecording ? "mic.fill" : "mic")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(
                                    replyDictation.isRecording
                                        ? Color.agentAmber
                                        : Color.white.opacity(0.42)
                                )
                        }
                    }
                    .frame(
                        width: MessageInboxLayout.composerActionSize,
                        height: MessageInboxLayout.composerActionSize
                    )
                    .background(
                        hasReplyDraft ? Color.agentBlue : Color.clear,
                        in: Circle()
                    )
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(replyActionIsBusy)
                .help(hasReplyDraft ? "Send message" : "Dictate a reply")
                .accessibilityLabel(
                    hasReplyDraft ? "Send message" : "Dictate a reply"
                )
                .accessibilityHint(
                    hasReplyDraft
                        ? "Sends this reply through Messages"
                        : "Starts microphone dictation for this reply"
                )
                .opacity(replyActionIsBusy ? 0.78 : 1)
                .padding(.trailing, 5)
            }
            .frame(height: MessageInboxLayout.composerHeight)
            .background(
                Color.white.opacity(0.06),
                in: RoundedRectangle(
                    cornerRadius: MessageInboxLayout.composerHeight / 2,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: MessageInboxLayout.composerHeight / 2,
                    style: .continuous
                )
                    .stroke(.white.opacity(replyFieldFocused ? 0.13 : 0.07), lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.15), value: hasReplyDraft)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var eligibleRecipients: [MessageReplyRecipient] {
        guard !conversation.isGroup else { return [] }
        let projected = conversation.participants.compactMap(
            MessageReplyRecipient.init(participant:)
        )
        var seenIDs = Set<String>()
        return (projected + resolvedRecipients).filter { seenIDs.insert($0.id).inserted }
    }

    private var selectedRecipients: [MessageReplyRecipient] {
        eligibleRecipients.filter { selectedRecipientIDs.contains($0.id) }
    }

    private var hasReplyDraft: Bool {
        !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var replyPlaceholder: String {
        switch MacMessageReplyService(serviceName: conversation.serviceName) {
        case .iMessage:
            "iMessage"
        case .sms:
            "Text Message"
        }
    }

    private var replyActionIsBusy: Bool {
        isResolvingRecipient || isSendingReply || isStartingReplyDictation
    }

    private var canAttemptSend: Bool {
        !conversation.isGroup
            && hasReplyDraft
            && !replyActionIsBusy
    }

    private func reconcileRecipientSelection() {
        let validIDs = Set(eligibleRecipients.map(\.id))
        selectedRecipientIDs.formIntersection(validIDs)
        if selectedRecipientIDs.count != 1 {
            selectedRecipientIDs = eligibleRecipients.first.map { Set([$0.id]) }
                ?? Set<String>()
        }
    }

    private func performReplyAction() {
        if hasReplyDraft {
            attemptSend()
        } else {
            toggleReplyDictation()
        }
    }

    private func toggleReplyDictation() {
        if replyDictation.isRecording {
            let transcript = replyDictation.stop()
            if !transcript.isEmpty {
                draftBody = String(
                    transcript.prefix(MessageReplyRequest.maximumBodyCharacterCount)
                )
            }
            replyFieldFocused = true
            return
        }

        guard !controller.meetingCapture.isActive,
              !controller.dictation.isRecording,
              !controller.isStartingDictation
        else {
            replyAlert = .notice(
                title: "Microphone in use",
                message: "Finish the active recording before dictating a message."
            )
            return
        }

        isStartingReplyDictation = true
        replyFieldFocused = false
        Task { @MainActor in
            do {
                try await replyDictation.start()
                isStartingReplyDictation = false
            } catch {
                isStartingReplyDictation = false
                replyDictation.cancel()
                replyAlert = .notice(
                    title: "Voice input unavailable",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func attemptSend() {
        if replyDictation.isRecording {
            let transcript = replyDictation.stop()
            if !transcript.isEmpty {
                draftBody = String(
                    transcript.prefix(MessageReplyRequest.maximumBodyCharacterCount)
                )
            }
        }
        guard canAttemptSend else { return }
        beginRecipientResolution()
    }

    private func beginRecipientResolution() {
        guard !conversation.isGroup else { return }
        if selectedRecipients.count == 1 {
            beginDirectSend()
            return
        }

        switch controller.messageProviderAccess {
        case let .disabled(message):
            replyAlert = .connectRequired(accessPrompt(message))
            return
        case let .permissionRequired(message):
            replyAlert = .accessRequired(accessPrompt(message))
            return
        case let .failed(message):
            replyAlert = .notice(title: "Messages unavailable", message: message)
            return
        case .loading:
            retryAfterMessagesAccess = true
            isResolvingRecipient = true
            return
        case .authorized:
            break
        }

        recipientResolutionTask?.cancel()
        isResolvingRecipient = true
        let conversationID = conversation.id
        recipientResolutionTask = Task { @MainActor in
            do {
                let recipients = try await controller.resolveMessageReplyRecipients(
                    for: conversationID
                )
                try Task.checkCancellation()
                resolvedRecipients = recipients
                reconcileRecipientSelection()
                isResolvingRecipient = false
                recipientResolutionTask = nil
                if selectedRecipients.count == 1 {
                    beginDirectSend()
                } else {
                    presentRecipientResolutionIssue()
                }
            } catch is CancellationError {
                isResolvingRecipient = false
                recipientResolutionTask = nil
            } catch {
                isResolvingRecipient = false
                recipientResolutionTask = nil
                presentRecipientResolutionIssue(fallback: error.localizedDescription)
            }
        }
    }

    private func presentRecipientResolutionIssue(fallback: String? = nil) {
        switch controller.messageProviderAccess {
        case let .disabled(message):
            replyAlert = .connectRequired(accessPrompt(message))
        case let .permissionRequired(message):
            replyAlert = .accessRequired(accessPrompt(message))
        case let .failed(message):
            replyAlert = .notice(title: "Messages unavailable", message: message)
        case .loading, .authorized:
            replyAlert = .notice(
                title: "Recipient unavailable",
                message: fallback
                    ?? "iAgent could not confirm a safe reply address for this conversation. Your draft is still here."
            )
        }
    }

    private func accessPrompt(_ detail: String) -> String {
        "\(detail)\n\nYour draft stays here while iAgent remains open. If macOS requires a relaunch after you change Full Disk Access, copy the draft first, then retry after relaunch."
    }

    private func beginDirectSend() {
        let request: MessageReplyRequest
        do {
            request = try MessageReplyRequest(
                recipients: selectedRecipients,
                body: draftBody
            )
        } catch {
            replyAlert = .notice(
                title: "Cannot send message",
                message: error.localizedDescription
            )
            return
        }

        guard controller.beginMessageReplySend(for: conversation.id) else { return }
        isSendingReply = true
        let conversationID = conversation.id
        let service = MacMessageReplyService(serviceName: conversation.serviceName)
        Task { @MainActor in
            defer {
                isSendingReply = false
                controller.finishMessageReplySend(for: conversationID)
            }
            do {
                let result = try await replyTransport.sendUserInitiated(
                    request,
                    service: service
                )
                switch result {
                case .sent:
                    if draftBody == request.body {
                        draftBody = ""
                    }
                case let .outcomeUncertain(message):
                    replyAlert = .notice(
                        title: "Check Messages before retrying",
                        message: message
                    )
                case let .fallbackRequired(message):
                    pendingFallbackRequest = request
                    replyAlert = .fallbackRequired(message)
                }
            } catch {
                replyAlert = .notice(
                    title: "Message not sent",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func beginConfirmedFallback() {
        guard let request = pendingFallbackRequest else { return }
        defer { pendingFallbackRequest = nil }
        do {
            _ = try replyTransport.beginUserConfirmedFallback(request)
        } catch {
            replyAlert = .notice(
                title: "Messages fallback unavailable",
                message: error.localizedDescription
            )
        }
    }

}

private enum MacMessageReplyAlert: Identifiable {
    case connectRequired(String)
    case accessRequired(String)
    case fallbackRequired(String)
    case notice(title: String, message: String)

    var id: String {
        switch self {
        case let .connectRequired(message):
            "connect:\(message)"
        case let .accessRequired(message):
            "access:\(message)"
        case let .fallbackRequired(message):
            "fallback:\(message)"
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

import AVFoundation
import SwiftUI
import UIKit
import iAgentActionContracts
import iAgentActions
import iAgentCore

// MARK: - Presentation contract

/// UI-only state for Ask iAgent. The retrieval and Foundation Models layers map
/// their authoritative records into this value before presentation, keeping this
/// screen read-only by construction.
struct AskIAgentUIPresentation: Equatable {
  var title = "Ask iAgent"
  var availability: AskIAgentUIAvailability = .available
  var turns: [AskIAgentUITurn] = []
  var history: [AskIAgentUIHistoryItem] = []
  var historyStatusMessage: String?
  var partialDataNotice: String?
  var inputValidationMessage: String?
  var isResponding = false
  var canSend = true
}

enum AskIAgentUIAvailability: Equatable {
  case available
  case remoteRelayNotConfigured
  case requiresNewerOS
  case deviceNotEligible
  case appleIntelligenceDisabled
  case modelPreparing
  case unsupportedLanguage(String?)
  case temporarilyUnavailable(String?)
}

struct AskIAgentUITurn: Identifiable, Equatable {
  let id: UUID
  let prompt: String
  var modelTier: AskIAgentModelTier
  var phase: AskIAgentUITurnPhase
  var priorWorkTraces: [AskIAgentWorkTrace]
  var activeSearchResult: AskIAgentUISearchResult?
  var suppressesActiveWorkTrace: Bool
  var answerBlocks: [AskIAgentUIAnswerBlock]
  var sources: [AskIAgentUISource]
  var suggestions: [String]

  init(
    id: UUID = UUID(),
    prompt: String,
    modelTier: AskIAgentModelTier = .free,
    phase: AskIAgentUITurnPhase,
    priorWorkTraces: [AskIAgentWorkTrace] = [],
    activeSearchResult: AskIAgentUISearchResult? = nil,
    suppressesActiveWorkTrace: Bool = false,
    answerBlocks: [AskIAgentUIAnswerBlock] = [],
    sources: [AskIAgentUISource] = [],
    suggestions: [String] = []
  ) {
    self.id = id
    self.prompt = prompt
    self.modelTier = modelTier
    self.phase = phase
    self.priorWorkTraces = priorWorkTraces
    self.activeSearchResult = activeSearchResult
    self.suppressesActiveWorkTrace = suppressesActiveWorkTrace
    self.answerBlocks = answerBlocks
    self.sources = sources
    self.suggestions = suggestions
  }
}

struct AskIAgentUISearchResult: Identifiable, Equatable {
  let kind: AskIAgentUISource.Kind
  let totalCount: Int
  let titles: [String]

  var id: String { kind.rawValue }

  var label: String {
    switch kind {
    case .todo: "Looking through \(totalCount) \(totalCount == 1 ? "to-do" : "to-dos")"
    case .calendar:
      "Reading \(totalCount) calendar \(totalCount == 1 ? "event" : "events")"
    case .note: "Searching \(totalCount) \(totalCount == 1 ? "note" : "notes")"
    case .meeting:
      "Checking \(totalCount) meeting \(totalCount == 1 ? "record" : "records")"
    case .codex: "Reviewing \(totalCount) Codex \(totalCount == 1 ? "task" : "tasks")"
    }
  }
}

struct AskIAgentUIAnswerBlock: Identifiable, Equatable {
  let id: UUID
  let text: String
  let isLead: Bool
  var citations: [AskIAgentUICitationMarker] = []
}

struct AskIAgentUICitationMarker: Identifiable, Equatable {
  let marker: Int
  let sourceID: String
  let sourceTitle: String

  var id: String { "\(marker):\(sourceID)" }
}

enum AskIAgentUITurnPhase: Equatable {
  case working(label: String, detail: String?)
  case completed(elapsed: Duration, contextAsOf: Date?, sourceCount: Int)
  case failed(message: String, canRetry: Bool)
  case interrupted(canRetry: Bool)
  case cancelled

  var isCompleted: Bool {
    if case .completed = self { return true }
    return false
  }
}

struct AskIAgentUISource: Identifiable, Equatable {
  enum Kind: String, CaseIterable, Equatable {
    case todo
    case calendar
    case note
    case codex
    case meeting
  }

  enum Freshness: Equatable {
    case current
    case updated
    case unavailable
  }

  let id: String
  let kind: Kind
  let title: String
  let metadata: String
  var preview: String?
  var detailRows: [AskIAgentUIDetailRow]
  var citationNumber: Int?
  var freshness: Freshness

  init(
    id: String,
    kind: Kind,
    title: String,
    metadata: String,
    preview: String? = nil,
    detailRows: [AskIAgentUIDetailRow] = [],
    citationNumber: Int? = nil,
    freshness: Freshness = .current
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.metadata = metadata
    self.preview = preview
    self.detailRows = detailRows
    self.citationNumber = citationNumber
    self.freshness = freshness
  }
}

struct AskIAgentUIDetailRow: Identifiable, Equatable {
  let id: String
  let label: String
  let value: String

  init(id: String? = nil, label: String, value: String) {
    self.id = id ?? label
    self.label = label
    self.value = value
  }
}

struct AskIAgentUIHistoryItem: Identifiable, Equatable {
  let id: UUID
  let title: String
  let excerpt: String
  let updatedAt: Date
  var isCurrent = false
}

private struct AskIAgentUIMentionItem: Identifiable, Equatable {
  let id: String
  let kind: AskIAgentUISource.Kind
  let title: String
  let metadata: String
  let searchableText: String
  let sortDate: Date
  let isCompleted: Bool

  var promptReference: String {
    "\(kind.promptReferenceLabel) “\(title)”"
  }
}

private struct AskIAgentMentionQuery {
  let range: Range<String.Index>
  let text: String

  init?(input: String) {
    guard let atIndex = input.lastIndex(of: "@") else { return nil }
    if atIndex != input.startIndex {
      let previous = input[input.index(before: atIndex)]
      guard previous.isWhitespace || "([{".contains(previous) else { return nil }
    }

    let valueStart = input.index(after: atIndex)
    let value = input[valueStart...]
    guard value.count <= 80, !value.contains(where: \.isNewline) else { return nil }

    range = atIndex..<input.endIndex
    text = String(value)
  }
}

private struct AskIAgentWorkingSnapshot: Equatable {
  let id: UUID
  let trace: AskIAgentWorkTrace
  let detail: String?
}

enum AskIAgentNativeActionHandoff: Identifiable {
  case calendar(
    intentID: String,
    proposalDigest: String,
    draft: CalendarEventDraftActionPayload
  )
  case codex(
    intentID: String,
    proposalDigest: String,
    request: CodexTaskRequestActionPayload
  )

  var id: String {
    switch self {
    case .calendar(let intentID, _, _), .codex(let intentID, _, _): intentID
    }
  }

  static func resolve(
    intent: AssistantActionIntent?,
    receipt: AssistantActionReceipt
  ) -> AskIAgentNativeActionHandoff? {
    guard receipt.disposition == .nativeHandoffRequired,
      let intent,
      intent.id == receipt.intentID,
      intent.proposalDigest == receipt.proposalDigest,
      intent.review.requiresNativeHandoff
    else { return nil }

    switch intent.payload {
    case .calendarDraft(let draft):
      return .calendar(
        intentID: intent.id,
        proposalDigest: intent.proposalDigest,
        draft: draft
      )
    case .codexTaskRequest(let request):
      return .codex(
        intentID: intent.id,
        proposalDigest: intent.proposalDigest,
        request: request
      )
    case .createTodo, .createNote:
      return nil
    }
  }
}

private enum AskIAgentNativeFinalizationRetry {
  case calendar(
    intentID: String,
    proposalDigest: String,
    outcome: AssistantCalendarEventEditor.Outcome
  )
  case codex(
    intentID: String,
    proposalDigest: String,
    outcome: AssistantCodexRequestHandoffView.Outcome
  )

  var intentID: String {
    switch self {
    case .calendar(let intentID, _, _), .codex(let intentID, _, _): intentID
    }
  }
}

enum AskIAgentWorkTrace: Equatable, Identifiable {
  case status(String)
  case search(AskIAgentUISearchResult)

  var id: String {
    switch self {
    case .status(let label): "status:\(label)"
    case .search(let result): "search:\(result.kind.rawValue)"
    }
  }
}

private extension Collection where Element == AskIAgentWorkTrace {
  /// Produces the truthful, stable UI projection of the model's audit trail.
  /// Empty scans remain available to the grounding layer but never become rows.
  /// Repeated positive scans update their existing source-kind row in place.
  var askIAgentVisibleTraces: [AskIAgentWorkTrace] {
    var visible: [AskIAgentWorkTrace] = []
    var indexByID: [String: Int] = [:]

    for trace in self {
      if case .search(let result) = trace, result.totalCount <= 0 {
        continue
      }

      if let index = indexByID[trace.id] {
        visible[index] = trace
      } else {
        indexByID[trace.id] = visible.count
        visible.append(trace)
      }
    }

    return visible
  }
}

// MARK: - Screen

/// Concrete feature entry point used by `MobileRootView`. It owns a single
/// on-device agent session while reading source snapshots from `MobileAppModel`.
struct AskIAgentView: View {
  @ObservedObject private var model: MobileAppModel
  @StateObject private var agent: AskIAgentModel
  @StateObject private var chatHistory: AskIAgentHistoryModel
  @ObservedObject private var actionCards: AssistantActionCardModel
  private let actionRuntime: AssistantActionRuntime
  private let initialPrompt: String?
  let onDismiss: () -> Void

  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @State private var didSubmitDebugPrompt = false
  @State private var didPrepareInitialPrompt = false
  @State private var initialPromptRequest: AskIAgentInitialPromptRequest?
  @State private var nativeActionHandoff: AskIAgentNativeActionHandoff?
  @State private var nativeFinalizationRetry: AskIAgentNativeFinalizationRetry?

  init(
    model: MobileAppModel,
    agentModel: AskIAgentModel? = nil,
    initialPrompt: String? = nil,
    onDismiss: @escaping () -> Void
  ) {
    self.model = model
    let actionRuntime = model.assistantActionRuntime
    // The capability store resolves persisted preferences synchronously at app-model startup.
    // Seed the chat model from that snapshot before the view becomes interactive so an immediate
    // first send cannot observe the fail-closed placeholder while the async refresh is pending.
    let resolvedAgent = agentModel ?? AskIAgentModel(
      actionCapabilityPolicy: actionRuntime.capabilityStore.initialPolicy
    )
    _agent = StateObject(wrappedValue: resolvedAgent)
    _chatHistory = StateObject(
      wrappedValue: AskIAgentHistoryModel(chatModel: resolvedAgent)
    )
    _actionCards = ObservedObject(wrappedValue: actionRuntime.cards)
    self.actionRuntime = actionRuntime
    let trimmedPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.initialPrompt = trimmedPrompt?.isEmpty == false ? trimmedPrompt : nil
    self.onDismiss = onDismiss
  }

  var body: some View {
    AskIAgentScreen(
      presentation: uiPresentation,
      mentionItems: mentionItems,
      input: $agent.currentInput,
      modelTier: $agent.selectedModelTier,
      actionIntent: actionCards.intent,
      actionReceipt: actionCards.receipt,
      actionIsWorking: actionCards.isWorking,
      actionErrorMessage: actionCards.errorMessage,
      initialPromptRequest: initialPromptRequest,
      onDismiss: onDismiss,
      onSend: submit,
      onCancel: agent.cancel,
      onNewChat: chatHistory.startNewChat,
      onOpenConversation: { id in
        Task { await chatHistory.selectConversation(id: id) }
      },
      onDeleteConversation: { id in
        Task { await chatHistory.deleteConversation(id: id) }
      },
      onClearHistory: {
        Task { await chatHistory.clearHistory() }
      },
      onRetryAvailability: agent.refreshAvailability,
      onOpenSettings: openAppleIntelligenceSettings,
      onRetryTurn: retryTurn,
      onConfirmAction: confirmActionFromReviewCard,
      onCancelAction: {
        Task { await actionCards.cancel() }
      }
    )
    .onAppear {
      model.updateAssistantActionForeground(true)
      agent.refreshAvailability()
    }
    .onDisappear { model.updateAssistantActionForeground(false) }
    .onChange(of: agent.proposedActionIntent?.id) { _, _ in
      guard let intent = agent.proposedActionIntent else { return }
      Task { await actionCards.present(intent) }
    }
    .onChange(of: scenePhase) { _, phase in
      model.updateAssistantActionForeground(phase == .active)
      guard phase == .active else { return }
      agent.refreshAvailability()
      Task { await chatHistory.synchronize() }
    }
    .sheet(item: $nativeActionHandoff) { handoff in
      nativeActionHandoffView(handoff)
        .interactiveDismissDisabled()
    }
    .task {
      await prepareActionHarness()
      if initialPrompt != nil {
        // Voice handoff should feel continuous: publish protected local history and stage the
        // transcript without waiting for a best-effort CloudKit merge. History still reconciles
        // in the background, while the staged request continues through the screen's ordinary
        // availability, privacy-consent, and one-shot submission path.
        await chatHistory.load(synchronize: false)
        prepareInitialPromptIfNeeded()
        Task { await chatHistory.synchronize() }
      } else {
        // Preserve the existing launch behavior for manually opened Ask iAgent sessions.
        await chatHistory.load()
        await submitDebugPromptIfRequested()
      }
    }
  }

  private func prepareActionHarness() async {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("--ask-iagent-v2-action-note-disabled") {
        try? await actionRuntime.capabilityStore.replaceForTesting(with: .allDisabled)
      } else if arguments.contains("--ask-iagent-v2-action-note") {
        await actionRuntime.settings.setEnabled(true, capability: .createNote)
      }
    #endif
    let policy = await actionRuntime.capabilityStore.currentPolicy()
    agent.configureActionCapabilityPolicy(policy)
    await actionCards.restoreMostRecentPendingReview()
  }

  private func confirmActionFromReviewCard() {
    Task {
      guard let result = await actionCards.confirmFromCurrentUserGesture() else { return }
      switch result.receipt.disposition {
      case .committedLocally:
        await model.refreshAfterAssistantActionCommit()
      case .nativeHandoffRequired:
        nativeFinalizationRetry = nil
        nativeActionHandoff = AskIAgentNativeActionHandoff.resolve(
          intent: result.intent,
          receipt: result.receipt
        )
      case .handoffCompleted, .handoffCancelled:
        break
      }
    }
  }

  @ViewBuilder
  private func nativeActionHandoffView(_ handoff: AskIAgentNativeActionHandoff) -> some View {
    if let retry = nativeFinalizationRetry, retry.intentID == handoff.id {
      nativeFinalizationRecoveryView(retry)
    } else {
      nativeActionHandoffContent(handoff)
    }
  }

  @ViewBuilder
  private func nativeActionHandoffContent(_ handoff: AskIAgentNativeActionHandoff) -> some View {
    switch handoff {
    case .calendar(let intentID, let proposalDigest, let draft):
      AssistantCalendarEventEditor(
        draft: draft,
        eventStore: actionRuntime.calendarHandoff.eventStore
      ) { outcome in
        Task {
          let didFinish = await actionCards.finishCalendarHandoff(
            intentID: intentID,
            proposalDigest: proposalDigest,
            outcome: outcome
          )
          if didFinish, nativeActionHandoff?.id == intentID {
            nativeFinalizationRetry = nil
            nativeActionHandoff = nil
          } else if !didFinish {
            nativeFinalizationRetry = .calendar(
              intentID: intentID,
              proposalDigest: proposalDigest,
              outcome: outcome
            )
          }
        }
      }

    case .codex(let intentID, let proposalDigest, let request):
      AssistantCodexRequestHandoffView(request: request) { outcome in
        Task {
          let didFinish = await actionCards.finishCodexHandoff(
            intentID: intentID,
            proposalDigest: proposalDigest,
            outcome: outcome
          )
          if didFinish, nativeActionHandoff?.id == intentID {
            nativeFinalizationRetry = nil
            nativeActionHandoff = nil
          } else if !didFinish {
            nativeFinalizationRetry = .codex(
              intentID: intentID,
              proposalDigest: proposalDigest,
              outcome: outcome
            )
          }
        }
      }
    }
  }

  private func nativeFinalizationRecoveryView(
    _ retry: AskIAgentNativeFinalizationRetry
  ) -> some View {
    NavigationStack {
      ContentUnavailableView(
        "Finish recording the handoff",
        systemImage: "exclamationmark.arrow.triangle.2.circlepath",
        description: Text(
          actionCards.errorMessage
            ?? "The external handoff finished, but iAgent could not save its final status. Retry saves that same outcome without repeating the handoff."
        )
      )
      .safeAreaInset(edge: .bottom) {
        Button {
          retryNativeFinalization(retry)
        } label: {
          if actionCards.isWorking {
            ProgressView()
              .frame(maxWidth: .infinity)
          } else {
            Text("Retry final status")
              .frame(maxWidth: .infinity)
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(actionCards.isWorking)
        .padding()
      }
    }
    .interactiveDismissDisabled()
  }

  private func retryNativeFinalization(_ retry: AskIAgentNativeFinalizationRetry) {
    Task {
      let didFinish: Bool
      switch retry {
      case let .calendar(intentID, proposalDigest, outcome):
        didFinish = await actionCards.finishCalendarHandoff(
          intentID: intentID,
          proposalDigest: proposalDigest,
          outcome: outcome
        )
      case let .codex(intentID, proposalDigest, outcome):
        didFinish = await actionCards.finishCodexHandoff(
          intentID: intentID,
          proposalDigest: proposalDigest,
          outcome: outcome
        )
      }
      guard didFinish, nativeActionHandoff?.id == retry.intentID else { return }
      nativeFinalizationRetry = nil
      nativeActionHandoff = nil
    }
  }

  /// Publishes the voice handoff after durable local history has loaded. The screen owns the actual
  /// send so this request still passes through its normal privacy-consent and availability checks
  /// rather than calling the model directly; best-effort cloud reconciliation runs independently.
  private func prepareInitialPromptIfNeeded() {
    guard !didPrepareInitialPrompt, let initialPrompt else { return }
    didPrepareInitialPrompt = true
    initialPromptRequest = AskIAgentInitialPromptRequest(prompt: initialPrompt)
  }

  private var uiPresentation: AskIAgentUIPresentation {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("--ask-iagent-working")
        || arguments.contains("--ask-iagent-completed")
        || arguments.contains("--ask-iagent-follow-up")
        || arguments.contains("--ask-iagent-calendar-collapsed")
        || arguments.contains("--ask-iagent-multi-tool-calendar")
        || arguments.contains("--ask-iagent-multi-tool-todo")
        || arguments.contains("--ask-iagent-multi-tool-grounding")
        || arguments.contains("--ask-iagent-multi-tool-completed")
        || arguments.contains("--ask-iagent-truthful-progress")
        || arguments.contains("--ask-iagent-ineligible")
        || arguments.contains("--ask-iagent-disabled")
        || arguments.contains("--ask-iagent-preparing")
      {
        return AskIAgentUIDebugFixtures.presentation(arguments: arguments)
      }
    #endif

    return AskIAgentUIPresentation(
      title: agent.conversationTitle,
      availability: agent.availability.uiAvailability,
      turns: uiTurns,
      history: uiHistory,
      historyStatusMessage: historyStatusMessage,
      partialDataNotice: partialDataNotice,
      inputValidationMessage: agent.inputValidationMessage,
      isResponding: agent.state.isWorking,
      canSend: agent.canChatWithSelectedModel
    )
  }

  private var mentionItems: [AskIAgentUIMentionItem] {
    let now = Date()
    let calendar = Calendar.autoupdatingCurrent
    let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
    let end = calendar.date(byAdding: .day, value: 90, to: now) ?? now
    var combined = model.snapshot
    combined.calendarEvents.append(contentsOf: model.calendar.permittedEvents(from: start, to: end))

    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(data: combined, contextAsOf: now)
    )
    let supportedKinds: Set<AskSourceKind> = [.todo, .note, .calendar, .meeting, .codex]

    return corpus.documents.compactMap { document -> AskIAgentUIMentionItem? in
      guard supportedKinds.contains(document.source.kind) else { return nil }
      return AskIAgentUIMentionItem(
        id: document.id,
        kind: document.source.kind.uiKind,
        title: document.title,
        metadata: mentionMetadata(for: document),
        searchableText: ([document.title, document.text] + Array(document.metadata.values))
          .joined(separator: " "),
        sortDate: document.facets.dueDate
          ?? document.facets.temporalRange?.start
          ?? document.updatedAt,
        isCompleted: document.facets.status == .completed
      )
    }
  }

  private func mentionMetadata(for document: AskKnowledgeDocument) -> String {
    switch document.source.kind {
    case .todo:
      if document.facets.status == .completed { return "Completed" }
      return [
        document.metadata["list"],
        document.facets.dueDate.map {
          "Due \($0.formatted(date: .abbreviated, time: .omitted))"
        },
      ].compactMap { $0 }.joined(separator: " · ").nonEmptyMentionValue ?? "To-do"

    case .calendar:
      guard let range = document.facets.temporalRange else {
        return document.metadata["calendar"] ?? "Event"
      }
      let isAllDay = document.metadata["allDay"] == "true"
      let date = range.start.formatted(date: .abbreviated, time: .omitted)
      let time =
        isAllDay
        ? "All day"
        : range.start.formatted(date: .omitted, time: .shortened)
      return "\(date) · \(time)"

    case .note:
      return "Updated \(document.updatedAt.formatted(date: .abbreviated, time: .omitted))"

    case .meeting:
      let date = document.facets.temporalRange?.start ?? document.updatedAt
      return date.formatted(date: .abbreviated, time: .omitted)

    case .codex:
      return "Codex"
    }
  }

  private var uiTurns: [AskIAgentUITurn] {
    var turns: [AskIAgentUITurn] = []
    let messages = agent.history
    let unansweredUserIDs = messages.enumerated().compactMap { index, message -> UUID? in
      guard message.role == .user else { return nil }
      let following = messages.dropFirst(index + 1)
      return following.first?.role == .assistant ? nil : message.id
    }
    let latestUnansweredUserID = unansweredUserIDs.last
    let latestUserID = messages.last(where: { $0.role == .user })?.id

    for (index, message) in messages.enumerated() where message.role == .user {
      let following = messages.dropFirst(index + 1)
      let assistant = following.first { $0.role == .assistant }
      let nextUserComesFirst = following.first?.role == .user
      let resolvedAssistant = nextUserComesFirst ? nil : assistant

      if let answer = resolvedAssistant?.answer {
        var turn = uiTurn(user: message, answer: answer)
        if message.id == latestUserID {
          turn.priorWorkTraces = agent.workStages.compactMap(\.uiWorkTrace)
        }
        turns.append(turn)
      } else {
        turns.append(
          AskIAgentUITurn(
            id: message.id,
            prompt: message.content,
            phase:
              message.id == latestUnansweredUserID
              ? uiPhaseForLatestTurn
              : .interrupted(canRetry: false),
            priorWorkTraces:
              message.id == latestUnansweredUserID
              ? agent.workStages.dropLast().compactMap(\.uiWorkTrace)
              : [],
            activeSearchResult:
              message.id == latestUnansweredUserID ? activeUISearchResult : nil,
            suppressesActiveWorkTrace:
              message.id == latestUnansweredUserID && suppressesActiveWorkTrace
          )
        )
      }
    }
    return turns
  }

  private var activeUISearchResult: AskIAgentUISearchResult? {
    guard case .working(.searchedSource(let scan)) = agent.state else { return nil }
    guard scan.totalCount > 0 else { return nil }
    return scan.uiSearchResult
  }

  /// A completed empty lane is useful to grounding coverage but is not useful
  /// user-facing activity. Keep it in the model while withholding only its
  /// presentation; a later positive scan for the same lane will enter normally.
  private var suppressesActiveWorkTrace: Bool {
    guard case .working(.searchedSource(let scan)) = agent.state else { return false }
    return scan.totalCount <= 0
  }

  private var uiPhaseForLatestTurn: AskIAgentUITurnPhase {
    switch agent.state {
    case .idle:
      .working(label: AskIAgentWorkStage.thinking.message, detail: nil)
    case .working(let stage):
      .working(label: stage.message, detail: stage.uiDetail)
    case .completed(let answer):
      .completed(
        elapsed: .milliseconds(Int64((answer.elapsed * 1_000).rounded())),
        contextAsOf: answer.contextAsOf,
        sourceCount: answer.sourceCount
      )
    case .failed(let failure):
      .failed(message: failure.message, canRetry: failure.isRetryable)
    case .interrupted:
      .interrupted(canRetry: true)
    case .cancelled:
      .cancelled
    }
  }

  private func uiTurn(user: AskIAgentMessage, answer: AskIAgentAnswer) -> AskIAgentUITurn {
    let markers = answer.claims
      .flatMap(\.citations)
      .reduce(into: [String: Int]()) { result, citation in
        result[citation.source.id] = min(
          result[citation.source.id] ?? citation.marker, citation.marker)
      }
    let sources = answer.sources.map {
      $0.uiSource(
        citationNumber: markers[$0.id],
        freshness: sourceFreshness($0)
      )
    }

    return AskIAgentUITurn(
      id: user.id,
      prompt: user.content,
      modelTier: answer.modelTier,
      phase: .completed(
        elapsed: .milliseconds(Int64((answer.elapsed * 1_000).rounded())),
        contextAsOf: answer.contextAsOf,
        sourceCount: answer.sourceCount
      ),
      answerBlocks: groundedBlocks(answer),
      sources: sources,
      suggestions: followUpSuggestions(for: user.content, sources: sources)
    )
  }

  private func groundedBlocks(_ answer: AskIAgentAnswer) -> [AskIAgentUIAnswerBlock] {
    answer.claims.enumerated().map { index, claim in
      var seenSourceIDs = Set<String>()
      let citations = claim.citations
        .sorted { lhs, rhs in
          if lhs.marker != rhs.marker { return lhs.marker < rhs.marker }
          return lhs.source.title.localizedCaseInsensitiveCompare(rhs.source.title)
            == .orderedAscending
        }
        .compactMap { citation -> AskIAgentUICitationMarker? in
          guard seenSourceIDs.insert(citation.source.id).inserted else { return nil }
          return AskIAgentUICitationMarker(
            marker: citation.marker,
            sourceID: citation.source.id,
            sourceTitle: citation.source.title
          )
        }
      return AskIAgentUIAnswerBlock(
        id: claim.id,
        text: claim.text,
        isLead: index == 0,
        citations: citations
      )
    }
  }

  private func followUpSuggestions(
    for prompt: String,
    sources: [AskIAgentUISource]
  ) -> [String] {
    guard !sources.isEmpty else { return [] }
    let normalized = prompt.lowercased()
    if normalized.contains("plan") || normalized.contains("priorit")
      || normalized.contains("focus") || normalized.contains("my day")
    {
      return ["Why this order?", "Which of these can I defer?"]
    }
    if sources.contains(where: { $0.kind == .calendar }) {
      return ["Where do I have free time?", "What should I do first?"]
    }
    if sources.contains(where: { $0.kind == .meeting }) {
      return ["What decisions were made?", "What action items are mine?"]
    }
    return ["Which of these matters most?", "What should I do next with these?"]
  }

  private func sourceFreshness(_ source: AskIAgentSourceResult) -> AskIAgentUISource.Freshness {
    guard source.isHistoricalSnapshot else { return .current }
    guard let currentRevision = currentRevision(for: source) else { return .unavailable }
    return abs(currentRevision.timeIntervalSince(source.updatedAt)) < 1 ? .current : .updated
  }

  private func currentRevision(for source: AskIAgentSourceResult) -> Date? {
    switch source.kind {
    case .todo:
      guard let id = UUID(uuidString: source.sourceID) else { return nil }
      return model.snapshot.todos.first { $0.id == id && $0.deletedAt == nil }?.updatedAt
    case .calendar:
      if let synced = model.snapshot.calendarEvents.first(where: {
        $0.id == source.sourceID && $0.deletedAt == nil
      }) {
        return synced.updatedAt
      }
      let now = Date()
      let calendar = Calendar.autoupdatingCurrent
      let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
      let end = calendar.date(byAdding: .day, value: 90, to: now) ?? now
      return model.calendar.permittedEvents(from: start, to: end)
        .first { $0.id == source.sourceID }?.updatedAt
    case .note:
      guard let id = UUID(uuidString: source.sourceID) else { return nil }
      return model.snapshot.notes.first { $0.id == id && $0.deletedAt == nil }?.updatedAt
    case .meeting:
      guard let id = UUID(uuidString: source.sourceID) else { return nil }
      return model.snapshot.meetings.first { $0.id == id && $0.deletedAt == nil }?.updatedAt
    case .codex:
      return model.snapshot.codexThreads.first {
        $0.id == source.sourceID && $0.deletedAt == nil
      }?.updatedAt
    }
  }

  private var uiHistory: [AskIAgentUIHistoryItem] {
    chatHistory.conversations.map { conversation in
      let last = conversation.messages.last
      return AskIAgentUIHistoryItem(
        id: conversation.id,
        title: conversation.title,
        excerpt: last?.text ?? "New chat",
        updatedAt: conversation.updatedAt,
        isCurrent: conversation.id == chatHistory.currentConversationID
      )
    }
  }

  private var partialDataNotice: String? {
    switch model.calendar.accessState {
    case .denied:
      return "Calendar access is off, so this answer may be incomplete."
    case .failed:
      return "Calendar data could not be refreshed, so this answer may be incomplete."
    case .idle, .granted:
      break
    }

    switch model.syncStatus.phase {
    case .offline:
      return "iCloud is offline. Ask iAgent is using the local data already on this iPhone."
    case .accountUnavailable, .failed:
      return "Some synced iAgent data may be unavailable."
    case .idle, .syncing:
      return nil
    }
  }

  private var historyStatusMessage: String? {
    switch chatHistory.syncStatus.phase {
    case .idle:
      return nil
    case .syncing:
      return "Syncing chat history privately with iCloud…"
    case .offline:
      return "Saved on this iPhone. History will sync when you’re back online."
    case .accountUnavailable:
      return "Saved on this iPhone. Sign in to iCloud to sync chat history."
    case .failed:
      return "Saved on this iPhone. iCloud history sync needs attention."
    }
  }

  @discardableResult
  private func submit() -> Bool {
    let now = Date()
    let calendarSnapshot = askIAgentCalendarSnapshot(at: now)
    return agent.submit(
      snapshot: model.snapshot,
      phoneEvents: calendarSnapshot.events,
      calendarCoverage: calendarSnapshot.coverage,
      now: now
    )
  }

  private func retryTurn(_ id: UUID) {
    let now = Date()
    let calendarSnapshot = askIAgentCalendarSnapshot(at: now)
    _ = agent.retry(
      userMessageID: id,
      snapshot: model.snapshot,
      phoneEvents: calendarSnapshot.events,
      calendarCoverage: calendarSnapshot.coverage,
      now: now
    )
  }

  /// Submit and retry deliberately share the same prompt-independent EventKit capture policy.
  /// The returned value is copied into the turn actor before any model-selected reads begin.
  private func askIAgentCalendarSnapshot(
    at referenceDate: Date
  ) -> MobileCalendarService.AskIAgentSnapshot {
    model.calendar.askIAgentSnapshot(
      referenceDate: referenceDate,
      calendar: .autoupdatingCurrent
    )
  }

  private func openAppleIntelligenceSettings() {
    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
    openURL(settingsURL)
  }

  private func submitDebugPromptIfRequested() async {
    #if DEBUG
      guard !didSubmitDebugPrompt,
        ProcessInfo.processInfo.arguments.contains("--ask-iagent-demo-prompt")
      else { return }
      didSubmitDebugPrompt = true

      // Give the isolated UI-test replica a moment to finish loading before the
      // turn pins its immutable snapshot. This path is never active in release.
      for _ in 0..<20 {
        if !model.snapshot.todos.isEmpty || !model.snapshot.calendarEvents.isEmpty
          || !model.snapshot.notes.isEmpty || !model.snapshot.codexThreads.isEmpty
        {
          break
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard !Task.isCancelled else { return }
      if ProcessInfo.processInfo.arguments.contains("--ask-iagent-v2-action-note")
        || ProcessInfo.processInfo.arguments.contains("--ask-iagent-v2-action-note-disabled")
      {
        agent.currentInput = "Create a note titled Trip plan with the body Book the ferry."
      } else if ProcessInfo.processInfo.arguments.contains("--ask-iagent-v2-last-meeting") {
        agent.currentInput = "Summarize my last meeting."
      } else {
        agent.currentInput = "What should I focus on today?"
      }
      _ = submit()

      if ProcessInfo.processInfo.arguments.contains("--ask-iagent-auto-cancel") {
        try? await Task.sleep(for: .milliseconds(750))
        guard !Task.isCancelled else { return }
        agent.cancel()
      }
    #endif
  }
}

private struct AskIAgentInitialPromptRequest: Identifiable, Equatable {
  let id = UUID()
  let prompt: String
}

private struct AskIAgentScreen: View {
  let presentation: AskIAgentUIPresentation
  let mentionItems: [AskIAgentUIMentionItem]
  @Binding var input: String
  @Binding var modelTier: AskIAgentModelTier
  let actionIntent: AssistantActionIntent?
  let actionReceipt: AssistantActionReceipt?
  let actionIsWorking: Bool
  let actionErrorMessage: String?
  let initialPromptRequest: AskIAgentInitialPromptRequest?
  let onDismiss: () -> Void
  let onSend: () -> Bool
  let onCancel: () -> Void
  let onNewChat: () -> Void
  let onOpenConversation: (UUID) -> Void
  let onDeleteConversation: (UUID) -> Void
  let onClearHistory: () -> Void
  let onRetryAvailability: () -> Void
  let onOpenSettings: () -> Void
  let onRetryTurn: (UUID) -> Void
  let onConfirmAction: () -> Void
  let onCancelAction: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @StateObject private var dictation = MobileMeetingRecorder()
  @StateObject private var speechReader = AskIAgentSpeechReader()
  @FocusState private var inputIsFocused: Bool
  @Namespace private var composerNamespace
  @State private var isHistoryPresented = false
  @State private var selectedSource: AskIAgentUISource?
  @State private var expandedCompletionIDs = Set<UUID>()
  @State private var revealedTurnIDs = Set<UUID>()
  @State private var knownCompletedTurnIDs = Set<UUID>()
  @State private var completedWorkTraces: [UUID: [AskIAgentWorkTrace]] = [:]
  @State private var currentWorkTraces: [UUID: AskIAgentWorkTrace] = [:]
  @State private var workNarrations: [UUID: String] = [:]
  @State private var didInitializeCompletedTurns = false
  @State private var streamRevision = 0
  @State private var isNearConversationBottom = true
  @State private var copiedTurnID: UUID?
  @State private var showsContextPicker = false
  @State private var showsRemotePrivacyConfirmation = false
  @State private var isSubmissionPending = false
  @State private var dictationBase = ""
  @State private var dictationError: String?
  @State private var pendingInitialPromptRequest: AskIAgentInitialPromptRequest?
  @State private var didInitiateInitialPromptSubmission = false
  @AppStorage("ask-iagent.remote-data-consent") private var hasRemoteDataConsent = false

  init(
    presentation: AskIAgentUIPresentation,
    mentionItems: [AskIAgentUIMentionItem] = [],
    input: Binding<String>,
    modelTier: Binding<AskIAgentModelTier>,
    actionIntent: AssistantActionIntent? = nil,
    actionReceipt: AssistantActionReceipt? = nil,
    actionIsWorking: Bool = false,
    actionErrorMessage: String? = nil,
    initialPromptRequest: AskIAgentInitialPromptRequest? = nil,
    onDismiss: @escaping () -> Void,
    onSend: @escaping () -> Bool,
    onCancel: @escaping () -> Void,
    onNewChat: @escaping () -> Void,
    onOpenConversation: @escaping (UUID) -> Void,
    onDeleteConversation: @escaping (UUID) -> Void,
    onClearHistory: @escaping () -> Void,
    onRetryAvailability: @escaping () -> Void,
    onOpenSettings: @escaping () -> Void,
    onRetryTurn: @escaping (UUID) -> Void,
    onConfirmAction: @escaping () -> Void = {},
    onCancelAction: @escaping () -> Void = {}
  ) {
    self.presentation = presentation
    self.mentionItems = mentionItems
    _input = input
    _modelTier = modelTier
    self.actionIntent = actionIntent
    self.actionReceipt = actionReceipt
    self.actionIsWorking = actionIsWorking
    self.actionErrorMessage = actionErrorMessage
    self.initialPromptRequest = initialPromptRequest
    self.onDismiss = onDismiss
    self.onSend = onSend
    self.onCancel = onCancel
    self.onNewChat = onNewChat
    self.onOpenConversation = onOpenConversation
    self.onDeleteConversation = onDeleteConversation
    self.onClearHistory = onClearHistory
    self.onRetryAvailability = onRetryAvailability
    self.onOpenSettings = onOpenSettings
    self.onRetryTurn = onRetryTurn
    self.onConfirmAction = onConfirmAction
    self.onCancelAction = onCancelAction
  }

  var body: some View {
    PanelScreen {
      VStack(spacing: 0) {
        header

        if presentation.availability == .available {
          conversation
        } else {
          availabilityState
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if presentation.availability == .available {
          composer
        }
      }
    }
    .tint(PanelTheme.primary)
    .sheet(isPresented: $isHistoryPresented) {
      AskIAgentHistorySheet(
        items: presentation.history,
        statusMessage: presentation.historyStatusMessage,
        onOpen: { id in
          isHistoryPresented = false
          isSubmissionPending = false
          onOpenConversation(id)
        },
        onDelete: onDeleteConversation,
        onClear: onClearHistory
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(PanelTheme.sheet)
    }
    .sheet(item: $selectedSource) { source in
      AskIAgentSourcePreview(source: source)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(PanelTheme.sheet)
    }
    .alert("Use OpenAI for this answer?", isPresented: $showsRemotePrivacyConfirmation) {
      Button("Cancel", role: .cancel) {
        isSubmissionPending = false
        // Privacy cancellation intentionally consumes an automatic voice handoff. Keep the
        // staged text in the composer so the user can edit or submit it explicitly later.
        pendingInitialPromptRequest = nil
      }
      Button("Continue") {
        hasRemoteDataConsent = true
        submitAfterPrivacyCheck()
      }
    } message: {
      Text(
        "Your question and the relevant iAgent records found on this iPhone will be sent through your configured private relay to OpenAI. Ask iAgent remains read-only."
      )
    }
    .alert("Dictation unavailable", isPresented: dictationErrorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(dictationError ?? "Please try again.")
    }
    .onAppear {
      initializeCompletedTurnsIfNeeded()
      seedPresentedWorkTraces()
      captureWorkingSnapshots(workingSnapshots)
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ask-iagent-expand-completion") {
          expandedCompletionIDs.formUnion(completedTurnIDs)
        }
        if ProcessInfo.processInfo.arguments.contains("--ask-iagent-open-first-citation"),
          let turn = presentation.turns.first,
          let citation = turn.answerBlocks.first?.citations.first,
          let source = turn.sources.first(where: { $0.id == citation.sourceID })
        {
          selectedSource = source
        }
        if ProcessInfo.processInfo.arguments.contains("--ask-iagent-mention-picker") {
          input = "@"
          inputIsFocused = true
        } else if ProcessInfo.processInfo.arguments.contains("--ask-iagent-focus-composer") {
          inputIsFocused = true
        }
      #endif
    }
    .onChange(of: completedTurnIDs) { _, ids in
      registerCompletedTurns(ids)
    }
    .onChange(of: presentation.isResponding) { _, isResponding in
      // Once the model owns the turn, its published state keeps controls disabled.
      if isResponding { isSubmissionPending = false }
    }
    .task(id: initialPromptRequest?.id) {
      await stageInitialPromptIfNeeded()
    }
    .onChange(of: presentation.canSend) { _, canSend in
      guard canSend else { return }
      attemptPendingInitialPromptSubmission()
    }
    .onChange(of: workingSnapshots) { _, snapshots in
      withAnimation(reduceMotion ? nil : PanelTheme.quick) {
        captureWorkingSnapshots(snapshots)
      }
    }
    .onChange(of: dictation.transcript) { _, transcript in
      guard dictation.isRecording, !transcript.isEmpty else { return }
      applyDictationTranscript(transcript)
    }
    .onDisappear {
      isSubmissionPending = false
      dictation.reset()
      speechReader.stop()
    }
  }

  @ViewBuilder
  private var header: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          closeButton
          Spacer(minLength: 12)
          headerActions
        }

        Text(presentation.title)
          .font(.title2.bold())
          .foregroundStyle(PanelTheme.primary)
          .lineLimit(2)
          .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
          }
      }
      .padding(.horizontal, PanelTheme.horizontalPadding)
      .padding(.top, 10)
      .padding(.bottom, 18)
    } else {
      ZStack {
        Text(presentation.title)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(PanelTheme.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.78)
          .padding(.horizontal, 112)
          // A title is navigation context, not transitional content. Updating
          // it in-place prevents old and new glyphs from crossfading on top of
          // each other during the voice handoff.
          .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
          }

        HStack(spacing: 12) {
          closeButton
          Spacer(minLength: 12)
          headerActions
        }
      }
      .padding(.horizontal, 18)
      .padding(.top, 8)
      .padding(.bottom, 12)
    }
  }

  private var closeButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: 17, weight: .semibold))
        .frame(width: 48, height: 48)
        .contentShape(Circle())
    }
    .buttonStyle(AskIAgentRoundButtonStyle())
    .accessibilityLabel("Close Ask iAgent")
  }

  private var headerActions: some View {
    HStack(spacing: 0) {
      Button {
        isHistoryPresented = true
      } label: {
        Image(systemName: "clock.arrow.circlepath")
          .font(.system(size: 17, weight: .semibold))
          .frame(width: 44, height: 48)
      }
      .accessibilityLabel("Chat history")
      .accessibilityValue("\(presentation.history.count) conversations")
      .buttonStyle(AskIAgentHeaderActionStyle(edge: .leading))

      Button {
        isSubmissionPending = false
        onNewChat()
        showsContextPicker = false
        inputIsFocused = true
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 19, weight: .medium))
          .frame(width: 44, height: 48)
      }
      .accessibilityLabel("New chat")
      .buttonStyle(AskIAgentHeaderActionStyle(edge: .trailing))
    }
    .background(AskIAgentMaterial(cornerRadius: 24, shadowRadius: 10, shadowY: 5))
    .accessibilityElement(children: .contain)
  }

  private var conversation: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .bottomTrailing) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 32) {
            if actionIntent == nil, let actionErrorMessage {
              Label(actionErrorMessage, systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.red)
                .lineSpacing(2)
                .accessibilityLabel("Action recovery error. \(actionErrorMessage)")
            }

            if let partialDataNotice = presentation.partialDataNotice {
              partialDataBanner(partialDataNotice)
            }

            ForEach(presentation.turns) { turn in
              turnView(turn)
                .id(turn.id)
                .transition(
                  reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.985, anchor: .bottom))
                )
            }

            Color.clear
              .frame(height: 1)
              .id("ask-iagent-bottom")
          }
          .padding(.horizontal, 18)
          .padding(.top, 6)
          .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .simultaneousGesture(
          DragGesture(minimumDistance: 8)
            .onChanged { value in
              // A deliberate upward drag pauses auto-follow. Resuming is explicit via
              // the jump-to-latest button, avoiding a geometry/state feedback loop.
              if value.translation.height < -8, isNearConversationBottom {
                isNearConversationBottom = false
              }
            }
        )
        .onChange(of: presentation.turns.map(\.id)) { previous, current in
          guard current.count > previous.count, let newest = current.last else { return }
          isNearConversationBottom = true
          scrollToTurn(newest, proxy: proxy)
        }
        .onChange(of: presentation.turns.last?.phase) { _, _ in
          if isNearConversationBottom { scrollToBottom(proxy) }
        }
        .onChange(of: presentation.turns.last?.sources.count) { _, _ in
          if isNearConversationBottom { scrollToBottom(proxy) }
        }
        .onChange(of: streamRevision) { _, _ in
          if isNearConversationBottom { scrollToBottom(proxy, animated: false) }
        }
        .onChange(of: revealedTurnIDs) { _, _ in
          guard isNearConversationBottom else { return }
          Task { @MainActor in
            // The source/actions subtree is conditional on reveal completion. Waiting one turn
            // lets SwiftUI place its bottom anchor before auto-following it.
            await Task.yield()
            if isNearConversationBottom { scrollToBottom(proxy, animated: false) }
          }
        }
        .onChange(of: inputIsFocused) { _, focused in
          if focused && isNearConversationBottom { scrollToBottom(proxy) }
        }

        if presentation.turns.isEmpty
          && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !inputIsFocused
        {
          starterPrompts
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.bottom, 10)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        } else if !isNearConversationBottom, !presentation.turns.isEmpty {
          Button {
            scrollToBottom(proxy)
          } label: {
            Image(systemName: "arrow.down")
              .font(.system(size: 14, weight: .bold))
              .foregroundStyle(PanelTheme.primary)
              .frame(width: 42, height: 42)
              .background(AskIAgentMaterial(cornerRadius: 21, shadowRadius: 8, shadowY: 4))
          }
          .buttonStyle(AskIAgentComposerButtonStyle())
          .padding(.trailing, 18)
          .padding(.bottom, 8)
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
          .accessibilityLabel("Jump to latest answer")
        }
      }
    }
  }

  private func partialDataBanner(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle")
      .font(.footnote.weight(.semibold))
      .foregroundStyle(PanelTheme.amber)
      .lineSpacing(2)
      .padding(.top, 4)
      .accessibilityLabel("Partial data. \(message)")
  }

  private func turnView(_ turn: AskIAgentUITurn) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      userPromptView(turn)

      phaseView(turn)
        .padding(.top, 30)

      if !turn.answerBlocks.isEmpty {
        answerView(turn)
          .padding(.top, 12)
      }

      if turnContentIsReady(turn),
        turn.id == presentation.turns.last?.id,
        let actionIntent,
        actionIntent.provenance.currentUserMessageID == turn.id.uuidString.lowercased()
      {
        AssistantActionReviewView(
          intent: actionIntent,
          receipt: actionReceipt,
          isWorking: actionIsWorking,
          errorMessage: actionErrorMessage,
          onConfirm: onConfirmAction,
          onCancel: onCancelAction
        )
        .padding(.top, 20)
      }

      if turnContentIsReady(turn), !turn.sources.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("Sources")
            .font(.footnote.weight(.medium))
            .foregroundStyle(PanelTheme.secondary)

          AskIAgentSourceGroup(sources: turn.sources) { source in
            selectedSource = source
          }
        }
        .padding(.top, 26)
      }

      if turnContentIsReady(turn), !turn.answerBlocks.isEmpty {
        responseActions(turn)
          .padding(.top, 12)
          .transition(.opacity)
      }

      if turnContentIsReady(turn), !turn.suggestions.isEmpty {
        suggestionsView(turn.suggestions)
          .padding(.top, 24)
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func userPromptView(_ turn: AskIAgentUITurn) -> some View {
    HStack(alignment: .top, spacing: 0) {
      Spacer(minLength: 72)

      Text(turn.prompt)
        .font(.system(size: 17, weight: .regular))
        .foregroundStyle(PanelTheme.primary)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(
          PanelTheme.sheetRaised,
          in: RoundedRectangle(cornerRadius: 21, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 21, style: .continuous)
            .strokeBorder(PanelTheme.border, lineWidth: 0.5)
        }
        .textSelection(.enabled)
        .contextMenu {
          Button {
            UIPasteboard.general.string = turn.prompt
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }

          ShareLink(item: turn.prompt) {
            Label("Share", systemImage: "square.and.arrow.up")
          }
        } preview: {
          Text(turn.prompt)
            .font(.body)
            .padding(16)
            .frame(maxWidth: 280, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("You asked: \(turn.prompt)")
  }

  @ViewBuilder
  private func phaseView(_ turn: AskIAgentUITurn) -> some View {
    switch turn.phase {
    case .working(let label, let detail):
      let traces = renderedWorkTraces(for: turn)
      let activeTrace = activeWorkTrace(for: turn, label: label)
      VStack(alignment: .leading, spacing: 12) {
        if let narration = workNarrations[turn.id] ?? detail?.askIAgentNonEmptyText {
          Text(narration)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(PanelTheme.primary)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }

        if !traces.isEmpty || activeTrace != nil {
          AskIAgentWorkTraceGroup(
            traces: traces,
            activeTrace: activeTrace,
            reduceMotion: reduceMotion
          )
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
      }

    case .completed(let elapsed, let contextAsOf, let sourceCount):
      VStack(alignment: .leading, spacing: 9) {
        Button {
          toggleCompletionDetails(turn.id)
        } label: {
          HStack(spacing: 7) {
            Text("Worked for \(elapsed.askIAgentCompactDescription)")
              .font(.footnote.weight(.medium))
            Image(
              systemName: expandedCompletionIDs.contains(turn.id) ? "chevron.down" : "chevron.right"
            )
            .font(.caption2.bold())
          }
          .frame(minHeight: 34, alignment: .leading)
          .foregroundStyle(PanelTheme.secondary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Answer completed in \(elapsed.askIAgentCompactDescription)")
        .accessibilityValue(
          "\(sourceCount) sources. \(expandedCompletionIDs.contains(turn.id) ? "Expanded" : "Collapsed")"
        )
        .accessibilityHint("Shows the data freshness for this answer")

        VStack(alignment: .leading, spacing: 0) {
          if expandedCompletionIDs.contains(turn.id) {
            VStack(alignment: .leading, spacing: 10) {
              let traces = renderedWorkTraces(for: turn)
              if !traces.isEmpty {
                AskIAgentWorkTraceGroup(
                  traces: traces,
                  activeTrace: nil,
                  reduceMotion: reduceMotion
                )
              }

              Text(completionDetail(contextAsOf: contextAsOf, sourceCount: sourceCount))
                .font(.footnote.weight(.medium))
                .foregroundStyle(PanelTheme.tertiary)
            }
            .padding(.top, 1)
            .transition(
              reduceMotion
                ? .identity
                : .opacity.combined(with: .scale(scale: 0.985, anchor: .top))
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
      }

    case .failed(let message, let canRetry):
      VStack(alignment: .leading, spacing: 12) {
        Label(message, systemImage: "exclamationmark.circle")
          .font(.body.weight(.semibold))
          .foregroundStyle(PanelTheme.coral)

        if canRetry {
          Button("Try again") { onRetryTurn(turn.id) }
            .font(.body.weight(.bold))
            .foregroundStyle(PanelTheme.primary)
            .buttonStyle(.plain)
            .accessibilityHint("Retries this question")
        }
      }

    case .interrupted(let canRetry):
      VStack(alignment: .leading, spacing: 12) {
        Text("This answer didn’t finish.")
          .font(.body.weight(.semibold))
          .foregroundStyle(PanelTheme.secondary)

        if canRetry {
          Button("Try again") { onRetryTurn(turn.id) }
            .font(.body.weight(.bold))
            .foregroundStyle(PanelTheme.primary)
            .buttonStyle(.plain)
            .accessibilityHint("Retries this question")
        }
      }

    case .cancelled:
      Text("Stopped")
        .font(.body.weight(.semibold))
        .foregroundStyle(PanelTheme.secondary)
    }
  }

  private func renderedWorkTraces(for turn: AskIAgentUITurn) -> [AskIAgentWorkTrace] {
    if !turn.priorWorkTraces.isEmpty { return turn.priorWorkTraces.askIAgentVisibleTraces }
    return (completedWorkTraces[turn.id] ?? []).askIAgentVisibleTraces
  }

  private func activeWorkTrace(
    for turn: AskIAgentUITurn,
    label: String
  ) -> AskIAgentWorkTrace? {
    guard !turn.suppressesActiveWorkTrace else { return nil }
    if let result = turn.activeSearchResult, result.totalCount > 0 {
      return .search(result)
    }

    let status = label.askIAgentStatusText
    guard !status.isEmpty else { return nil }
    return .status(status)
  }

  private func suggestionsView(_ suggestions: [String]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Keep going")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(PanelTheme.secondary)

      ForEach(Array(suggestions.prefix(2).enumerated()), id: \.offset) { index, suggestion in
        Button {
          submitSuggestedFollowUp(suggestion)
        } label: {
          Text(suggestion)
            .font(.body)
            .foregroundStyle(PanelTheme.primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16)
            .background(PanelTheme.surface, in: Capsule())
            .overlay {
              Capsule().strokeBorder(PanelTheme.border, lineWidth: 0.75)
            }
        }
        .buttonStyle(AskIAgentSuggestionButtonStyle())
        .disabled(submissionIsBlocked)
        .accessibilityLabel("Ask follow-up: \(suggestion)")
        .accessibilityHint("Asks this follow-up")
        .accessibilityIdentifier("ask-iagent-follow-up-\(index)")
      }
    }
  }

  @ViewBuilder
  private func answerView(_ turn: AskIAgentUITurn) -> some View {
    let text = spokenAnswerText(turn)
    if isTurnStreaming(turn) {
      AskIAgentStreamingText(
        text: text,
        reduceMotion: reduceMotion,
        onProgress: {
          streamRevision &+= 1
        },
        onComplete: {
          revealedTurnIDs.insert(turn.id)
          // Sources, answer actions, and follow-ups enter only after the last streamed glyph.
          // Publish one final scroll revision after that layout exists so the disclosure footer
          // is not left underneath the composer.
          streamRevision &+= 1
        }
      )
      .id(turn.id)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(turn.answerBlocks.enumerated()), id: \.element.id) { index, block in
          AskIAgentMarkdownText(
            text: block.text,
            isLead: block.isLead,
            citations: block.citations
          ) { citation in
            guard let source = turn.sources.first(where: { $0.id == citation.sourceID })
            else { return }
            selectedSource = source
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, answerBlockSpacing(at: index, in: turn.answerBlocks))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func answerBlockSpacing(
    at index: Int,
    in blocks: [AskIAgentUIAnswerBlock]
  ) -> CGFloat {
    guard index > 0 else { return 0 }
    let current = blocks[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
    let previous = blocks[index - 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentIsListItem = current.hasPrefix("- ") || current.hasPrefix("* ")
    let previousIsListItem = previous.hasPrefix("- ") || previous.hasPrefix("* ")
    let previousIsHeading = previous.hasPrefix("#")
    if currentIsListItem && previousIsHeading { return 9 }
    if currentIsListItem && previousIsListItem { return 8 }
    if current.hasPrefix("#") { return 20 }
    return 14
  }

  private func responseActions(_ turn: AskIAgentUITurn) -> some View {
    let text = answerText(turn)
    let speechText = spokenAnswerText(turn)
    return HStack(spacing: 0) {
      Button {
        copyAnswer(text, turnID: turn.id)
      } label: {
        Image(systemName: copiedTurnID == turn.id ? "checkmark" : "doc.on.doc")
          .frame(width: 40, height: 40)
      }
      .accessibilityLabel(copiedTurnID == turn.id ? "Copied" : "Copy answer")

      Button {
        speechReader.toggle(turnID: turn.id, text: speechText)
      } label: {
        Image(
          systemName: speechReader.activeTurnID == turn.id
            ? "speaker.slash" : "speaker.wave.2"
        )
        .frame(width: 40, height: 40)
      }
      .accessibilityLabel(
        speechReader.activeTurnID == turn.id ? "Stop reading answer" : "Read answer aloud"
      )

      ShareLink(item: text) {
        Image(systemName: "square.and.arrow.up")
          .frame(width: 40, height: 40)
      }
      .accessibilityLabel("Share answer")

      Button {
        onRetryTurn(turn.id)
      } label: {
        Image(systemName: "arrow.clockwise")
          .frame(width: 40, height: 40)
      }
      .accessibilityLabel("Try this question again")

      Spacer(minLength: 12)

      Text(turn.modelTier.displayName)
        .font(.footnote.weight(.medium))
        .foregroundStyle(PanelTheme.tertiary)
        .accessibilityLabel("Answer tier: \(turn.modelTier.displayName)")
        .accessibilityIdentifier("ask-iagent-response-model")
    }
    .font(.system(size: 14, weight: .medium))
    .foregroundStyle(PanelTheme.secondary)
    .buttonStyle(AskIAgentResponseActionButtonStyle())
    .frame(maxWidth: .infinity)
  }

  private func answerText(_ turn: AskIAgentUITurn) -> String {
    turn.answerBlocks.map { block in
      let markers = block.citations.map { "[\($0.marker)]" }.joined(separator: " ")
      return markers.isEmpty ? block.text : block.text + " " + markers
    }
    .joined(separator: "\n\n")
  }

  private func spokenAnswerText(_ turn: AskIAgentUITurn) -> String {
    turn.answerBlocks.map(\.text).joined(separator: "\n\n")
  }

  private func isTurnStreaming(_ turn: AskIAgentUITurn) -> Bool {
    turn.phase.isCompleted
      && !turn.answerBlocks.isEmpty
      && !revealedTurnIDs.contains(turn.id)
  }

  private func turnContentIsReady(_ turn: AskIAgentUITurn) -> Bool {
    turn.phase.isCompleted && (!isTurnStreaming(turn) || turn.answerBlocks.isEmpty)
  }

  private func copyAnswer(_ text: String, turnID: UUID) {
    UIPasteboard.general.string = text
    copiedTurnID = turnID
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      if copiedTurnID == turnID { copiedTurnID = nil }
    }
  }

  private var composer: some View {
    VStack(spacing: 0) {
      LinearGradient(
        colors: [PanelTheme.canvas.opacity(0), PanelTheme.canvas],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 18)
      .allowsHitTesting(false)
      .accessibilityHidden(true)

      VStack(spacing: 10) {
        if showsMentionPicker {
          mentionPicker
            .padding(.horizontal, 16)
            .transition(
              reduceMotion
                ? .opacity
                : .opacity.combined(with: .move(edge: .bottom))
            )
        }

        Group {
          if composerIsExpanded {
            expandedComposer
          } else {
            compactComposer
          }
        }
        .background(
          AskIAgentMaterial(
            cornerRadius: composerIsExpanded ? 28 : 29,
            shadowRadius: 16,
            shadowY: 8
          )
        )
        .accessibilityIdentifier("ask-iagent-composer")
        .padding(.horizontal, composerIsExpanded ? 16 : 34)
        .animation(composerAnimation, value: composerIsExpanded)
      }
      .padding(.bottom, 10)
      .background(PanelTheme.canvas)
      .animation(reduceMotion ? nil : PanelTheme.quick, value: showsMentionPicker)
    }
  }

  private var expandedComposer: some View {
    VStack(alignment: .leading, spacing: 0) {
      composerTextField
        .frame(minHeight: 44, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 2)

      if let validationMessage = presentation.inputValidationMessage {
        Text(validationMessage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(PanelTheme.coral)
          .padding(.horizontal, 18)
          .padding(.vertical, 4)
          .accessibilityIdentifier("ask-iagent-input-validation")
      }

      HStack(spacing: 2) {
        contextMenuButton
          .matchedGeometryEffect(id: "ask-plus", in: composerNamespace)

        modelMenu

        Spacer(minLength: 8)

        dictationButton
          .matchedGeometryEffect(id: "ask-dictation", in: composerNamespace)

        sendButton
          .matchedGeometryEffect(id: "ask-send", in: composerNamespace)
      }
      .padding(.horizontal, 7)
      .padding(.bottom, 7)
    }
    .frame(minHeight: 88, alignment: .top)
  }

  private var compactComposer: some View {
    HStack(spacing: 2) {
      contextMenuButton
        .matchedGeometryEffect(id: "ask-plus", in: composerNamespace)

      composerTextField
        .padding(.leading, 4)

      dictationButton
        .matchedGeometryEffect(id: "ask-dictation", in: composerNamespace)

      sendButton
        .matchedGeometryEffect(id: "ask-send", in: composerNamespace)
    }
    .padding(.horizontal, 6)
    .frame(minHeight: 58)
  }

  private var composerTextField: some View {
    TextField(composerPlaceholder, text: $input, axis: .vertical)
      .font(.system(size: 17, weight: .regular))
      .foregroundStyle(PanelTheme.primary)
      .lineLimit(1...5)
      .focused($inputIsFocused)
      .submitLabel(.send)
      .onSubmit(submitIfPossible)
      .disabled(submissionIsBlocked)
      .accessibilityLabel("Ask iAgent")
      .accessibilityIdentifier("ask-iagent-input")
  }

  private var contextMenuButton: some View {
    Menu {
      Button {
        withAnimation(reduceMotion ? nil : PanelTheme.quick) {
          showsContextPicker.toggle()
        }
        inputIsFocused = true
      } label: {
        Label("Browse iAgent context", systemImage: "tray.full")
      }

      Button(action: beginMention) {
        Label("Mention a source", systemImage: "at")
      }
      .accessibilityIdentifier("ask-iagent-mention")
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 20, weight: .medium))
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .buttonStyle(AskIAgentComposerToolButtonStyle())
    .accessibilityLabel("Add iAgent context")
    .accessibilityHint("Shows todos, notes, events, meeting notes, and Codex tasks")
    .accessibilityIdentifier("ask-iagent-context")
  }

  private var modelMenu: some View {
    Menu {
      ForEach(AskIAgentModelTier.allCases) { tier in
        Button {
          modelTier = tier
          inputIsFocused = true
        } label: {
          Label(
            "\(tier.displayName) · \(tier.pickerDetail)",
            systemImage: tier == modelTier ? "checkmark" : "circle"
          )
        }
      }
    } label: {
      HStack(spacing: 4) {
        Text(modelTier.displayName)
          .font(.footnote.weight(.semibold))
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 8, weight: .bold))
      }
      .foregroundStyle(
        !presentation.canSend && modelTier.usesRemoteService
          ? PanelTheme.coral : PanelTheme.secondary
      )
      .frame(minWidth: 56, minHeight: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(AskIAgentModelMenuButtonStyle())
    .disabled(submissionIsBlocked)
    .accessibilityLabel("Answer model")
    .accessibilityValue("\(modelTier.displayName), \(modelTier.pickerDetail)")
    .accessibilityHint("Choose Free, Fast, or Pro")
    .accessibilityIdentifier("ask-iagent-model-menu")
  }

  private var dictationButton: some View {
    Button(action: toggleDictation) {
      ZStack {
        if dictation.isStarting || dictation.isStopping {
          ProgressView()
            .tint(PanelTheme.secondary)
            .scaleEffect(0.75)
        } else {
          Image(systemName: dictation.isRecording ? "waveform" : "mic")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(dictation.isRecording ? PanelTheme.coral : PanelTheme.secondary)
        }
      }
      .frame(width: 44, height: 44)
      .contentShape(Circle())
    }
    .buttonStyle(AskIAgentComposerToolButtonStyle())
    .disabled(dictation.isStarting || dictation.isStopping || presentation.isResponding)
    .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate a question")
    .accessibilityIdentifier("ask-iagent-dictation")
  }

  private var sendButton: some View {
    Button {
      if isUIResponding {
        stopResponse()
      } else {
        submitIfPossible()
      }
    } label: {
      Image(systemName: isUIResponding ? "stop.fill" : "arrow.up")
        .font(.system(size: isUIResponding ? 11 : 17, weight: .bold))
        .foregroundStyle(sendButtonForeground)
        .frame(width: 44, height: 44)
        .background(sendButtonBackground, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(AskIAgentComposerButtonStyle())
    .disabled(!isUIResponding && !canSubmit)
    .accessibilityLabel(isUIResponding ? "Stop response" : "Send")
    .accessibilityHint(
      isUIResponding
        ? "Stops the current answer"
        : "Sends this question to the selected model"
    )
    .accessibilityIdentifier("ask-iagent-send")
  }

  private var starterPrompts: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Self.newChatPrompts, id: \.self) { prompt in
        Button {
          input = prompt
          showsContextPicker = false
          inputIsFocused = true
        } label: {
          Text(prompt)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PanelTheme.secondary)
            .frame(minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16)
            .background(PanelTheme.surface, in: Capsule())
            .overlay {
              Capsule().strokeBorder(PanelTheme.border, lineWidth: 0.75)
            }
        }
        .buttonStyle(AskIAgentSuggestionButtonStyle())
        .accessibilityLabel("Suggested prompt: \(prompt)")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Suggested prompts")
    .accessibilityIdentifier("ask-iagent-suggested-prompts")
  }

  private var mentionPicker: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(mentionPickerTitle)
          .font(.footnote.weight(.bold))
          .foregroundStyle(PanelTheme.secondary)
          .lineLimit(1)

        Spacer(minLength: 8)

        if mentionQuery == nil {
          Button {
            withAnimation(reduceMotion ? nil : PanelTheme.quick) {
              showsContextPicker = false
            }
          } label: {
            Image(systemName: "xmark")
              .font(.caption.bold())
              .foregroundStyle(PanelTheme.tertiary)
              .frame(width: 32, height: 32)
              .contentShape(Circle())
          }
          .buttonStyle(AskIAgentComposerToolButtonStyle())
          .accessibilityLabel("Close context list")
        }
      }
      .padding(.leading, 16)
      .padding(.trailing, 8)
      .frame(height: 42)

      if matchingMentionItems.isEmpty {
        Text("No matching iAgent items")
          .font(.body)
          .foregroundStyle(PanelTheme.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .frame(height: 58)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          Text("SOURCES")
            .font(.caption.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(PanelTheme.tertiary)
            .padding(.horizontal, 16)
            .frame(height: 22, alignment: .bottomLeading)

          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(matchingMentionItems) { item in
                Button {
                  selectMention(item)
                } label: {
                  mentionRow(item)
                }
                .buttonStyle(AskIAgentMentionButtonStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                  "\(item.kind.mentionItemLabel), \(item.title), \(item.metadata)"
                )
                .accessibilityHint("Adds this item to the question")
              }
            }
            .padding(.bottom, 8)
          }
          .scrollIndicators(.hidden)
        }
      }
    }
    .frame(height: mentionPickerHeight)
    .background(AskIAgentMaterial(cornerRadius: 24))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("iAgent context results")
    .accessibilityIdentifier("ask-iagent-mention-picker")
  }

  private func mentionRow(_ item: AskIAgentUIMentionItem) -> some View {
    HStack(spacing: 12) {
      item.kind.mentionIcon
        .frame(width: 22, height: 22)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.body.weight(.semibold))
          .foregroundStyle(PanelTheme.primary)
          .lineLimit(1)

        Text("\(item.kind.mentionItemLabel.capitalized) · \(item.metadata)")
          .font(.caption.weight(.medium))
          .foregroundStyle(PanelTheme.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Image(systemName: "plus")
        .font(.caption.bold())
        .foregroundStyle(PanelTheme.tertiary)
    }
    .padding(.horizontal, 16)
    .frame(height: 48)
    .contentShape(Rectangle())
  }

  private var matchingMentionItems: [AskIAgentUIMentionItem] {
    let normalizedQuery = (mentionQuery?.text ?? "")
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let terms = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)

    let matches = mentionItems.filter { item in
      guard !terms.isEmpty else { return true }
      let haystack = item.searchableText.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      )
      return terms.allSatisfy(haystack.contains)
    }

    if terms.isEmpty {
      return AskIAgentUISource.Kind.mentionKindOrder.compactMap { kind in
        matches.filter { $0.kind == kind }.sorted(by: mentionItemComesFirst).first
      }
    }

    return Array(
      matches.sorted { lhs, rhs in
        let lhsKind = AskIAgentUISource.Kind.mentionKindOrder.firstIndex(of: lhs.kind) ?? .max
        let rhsKind = AskIAgentUISource.Kind.mentionKindOrder.firstIndex(of: rhs.kind) ?? .max
        if lhsKind != rhsKind { return lhsKind < rhsKind }
        return mentionItemComesFirst(lhs, rhs)
      }
      .prefix(8)
    )
  }

  private var mentionPickerHeight: CGFloat {
    let contentHeight = CGFloat(matchingMentionItems.count * 48 + 64)
    return min(256, max(100, contentHeight))
  }

  private var mentionPickerTitle: String {
    guard let query = mentionQuery else { return "Add iAgent context" }
    let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Mention iAgent context" : "Results for @\(trimmed)"
  }

  private var mentionQuery: AskIAgentMentionQuery? {
    AskIAgentMentionQuery(input: input)
  }

  private var showsMentionPicker: Bool {
    showsContextPicker || mentionQuery != nil
  }

  private func mentionItemComesFirst(
    _ lhs: AskIAgentUIMentionItem,
    _ rhs: AskIAgentUIMentionItem
  ) -> Bool {
    if lhs.kind == .todo, lhs.isCompleted != rhs.isCompleted {
      return !lhs.isCompleted
    }

    if lhs.kind == .calendar {
      let now = Date()
      let lhsIsUpcoming = lhs.sortDate >= now
      let rhsIsUpcoming = rhs.sortDate >= now
      if lhsIsUpcoming != rhsIsUpcoming { return lhsIsUpcoming }
      if lhsIsUpcoming { return lhs.sortDate < rhs.sortDate }
    }

    if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
  }

  private func beginMention() {
    guard mentionQuery == nil else {
      inputIsFocused = true
      return
    }
    let separator = input.last.map { $0.isWhitespace ? "" : " " } ?? ""
    input += "\(separator)@"
    showsContextPicker = false
    inputIsFocused = true
  }

  private func selectMention(_ item: AskIAgentUIMentionItem) {
    if let query = mentionQuery {
      input.replaceSubrange(query.range, with: item.promptReference)
    } else {
      let separator = input.last.map { $0.isWhitespace ? "" : " " } ?? ""
      input += "\(separator)\(item.promptReference)"
    }
    if input.last?.isWhitespace != true { input.append(" ") }
    showsContextPicker = false
    inputIsFocused = true
  }

  private var canSubmit: Bool {
    submissionInputsAreReady && !isSubmissionPending
  }

  private var submissionInputsAreReady: Bool {
    presentation.canSend
      && !isUIResponding
      && presentation.inputValidationMessage == nil
      && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var composerIsExpanded: Bool {
    presentation.turns.isEmpty
      || inputIsFocused
      || showsMentionPicker
      || dictation.isRecording
      || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var composerPlaceholder: String {
    presentation.turns.isEmpty ? "Ask iAgent…" : "Follow up"
  }

  private var composerAnimation: Animation? {
    reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1, blendDuration: 0)
  }

  private var activeStreamingTurnID: UUID? {
    presentation.turns.last(where: isTurnStreaming)?.id
  }

  private var isUIResponding: Bool {
    presentation.isResponding || activeStreamingTurnID != nil
  }

  private var submissionIsBlocked: Bool {
    isSubmissionPending || isUIResponding
  }

  private var sendButtonForeground: Color {
    if isUIResponding { return PanelTheme.primary }
    return canSubmit ? PanelTheme.canvas : PanelTheme.tertiary
  }

  private var sendButtonBackground: Color {
    if isUIResponding { return PanelTheme.selectedSurface }
    return canSubmit ? PanelTheme.primary : PanelTheme.surface
  }

  private func submitIfPossible() {
    guard canSubmit else { return }
    // Disable every submission surface synchronously; the parent presentation updates on the
    // following render pass and is too late to serialize rapid taps by itself.
    isSubmissionPending = true
    Task { @MainActor in
      if dictation.isRecording || dictation.isStopping {
        let transcript = await dictation.stop()
        applyDictationTranscript(transcript)
        dictation.reset()
      }
      guard submissionInputsAreReady else {
        isSubmissionPending = false
        if pendingInitialPromptRequest != nil {
          didInitiateInitialPromptSubmission = false
        }
        return
      }
      if modelTier.usesRemoteService, !hasRemoteDataConsent {
        showsRemotePrivacyConfirmation = true
        return
      }
      submitAfterPrivacyCheck()
    }
  }

  /// Stages an externally supplied transcript once, then enters through `submitIfPossible` so
  /// remote model tiers still show the existing privacy confirmation before any turn is appended.
  private func stageInitialPromptIfNeeded() async {
    guard !didInitiateInitialPromptSubmission,
      pendingInitialPromptRequest == nil,
      let initialPromptRequest
    else { return }

    pendingInitialPromptRequest = initialPromptRequest
    input = initialPromptRequest.prompt
    showsContextPicker = false
    inputIsFocused = false

    // The input binding is owned by the parent model. Yield once so its publication is visible to
    // the same readiness checks used by manual sends and suggested follow-ups. Keeping this work
    // in the view's `.task` makes dismissal cancel it instead of leaving a detached send behind.
    await Task.yield()
    guard !Task.isCancelled else { return }
    attemptPendingInitialPromptSubmission()
  }

  private func attemptPendingInitialPromptSubmission() {
    guard !didInitiateInitialPromptSubmission,
      pendingInitialPromptRequest != nil,
      submissionInputsAreReady
    else { return }

    didInitiateInitialPromptSubmission = true
    submitIfPossible()
  }

  private func submitAfterPrivacyCheck() {
    guard isSubmissionPending else { return }
    showsContextPicker = false
    inputIsFocused = false
    if onSend() {
      // Clear only after the model accepted the turn. Until then, availability changes can retry
      // the same staged request without ever appending the prompt twice.
      pendingInitialPromptRequest = nil
    } else {
      isSubmissionPending = false
      if pendingInitialPromptRequest != nil {
        didInitiateInitialPromptSubmission = false
      }
    }
  }

  private func submitSuggestedFollowUp(_ suggestion: String) {
    guard !submissionIsBlocked else { return }
    input = suggestion
    showsContextPicker = false
    inputIsFocused = false

    // Let the bound model publish the new text before evaluating `canSubmit`.
    Task { @MainActor in
      await Task.yield()
      submitIfPossible()
    }
  }

  private func stopResponse() {
    if presentation.isResponding {
      onCancel()
      return
    }
    if let activeStreamingTurnID {
      revealedTurnIDs.insert(activeStreamingTurnID)
    }
  }

  private func toggleDictation() {
    Task { @MainActor in
      if dictation.isRecording {
        let transcript = await dictation.stop()
        applyDictationTranscript(transcript)
        dictation.reset()
        inputIsFocused = true
        return
      }

      dictationBase = input
      inputIsFocused = false
      let started = await dictation.start()
      if !started {
        dictationError = dictation.errorMessage ?? "Speech recognition could not start."
      }
    }
  }

  private func applyDictationTranscript(_ transcript: String) {
    let resolved = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolved.isEmpty else { return }
    let separator =
      dictationBase.isEmpty || dictationBase.last?.isWhitespace == true
      ? "" : " "
    input = dictationBase + separator + resolved
  }

  private var dictationErrorBinding: Binding<Bool> {
    Binding(
      get: { dictationError != nil },
      set: { if !$0 { dictationError = nil } }
    )
  }

  private var completedTurnIDs: [UUID] {
    presentation.turns.compactMap { turn in
      turn.phase.isCompleted ? turn.id : nil
    }
  }

  private var workingSnapshots: [AskIAgentWorkingSnapshot] {
    presentation.turns.compactMap { turn in
      guard case .working(let label, let detail) = turn.phase else { return nil }
      guard let trace = activeWorkTrace(for: turn, label: label) else { return nil }
      return AskIAgentWorkingSnapshot(id: turn.id, trace: trace, detail: detail)
    }
  }

  private func initializeCompletedTurnsIfNeeded() {
    guard !didInitializeCompletedTurns else { return }
    didInitializeCompletedTurns = true
    let ids = Set(completedTurnIDs)
    knownCompletedTurnIDs = ids
    revealedTurnIDs.formUnion(ids)
  }

  private func seedPresentedWorkTraces() {
    for turn in presentation.turns where !turn.priorWorkTraces.isEmpty {
      completedWorkTraces[turn.id] = turn.priorWorkTraces.askIAgentVisibleTraces
    }
  }

  private func registerCompletedTurns(_ ids: [UUID]) {
    guard didInitializeCompletedTurns else {
      initializeCompletedTurnsIfNeeded()
      return
    }

    let next = Set(ids)
    let added = ids.filter { !knownCompletedTurnIDs.contains($0) }
    if added.count > 1 {
      revealedTurnIDs.formUnion(added.dropLast())
    }
    knownCompletedTurnIDs = next
    revealedTurnIDs.formIntersection(next)
  }

  private func captureWorkingSnapshots(_ snapshots: [AskIAgentWorkingSnapshot]) {
    let activeIDs = Set(snapshots.map(\.id))
    for (id, trace) in Array(currentWorkTraces) where !activeIDs.contains(id) {
      appendCompletedWorkTrace(trace, turnID: id)
      currentWorkTraces[id] = nil
    }

    for snapshot in snapshots {
      if let previous = currentWorkTraces[snapshot.id], previous != snapshot.trace {
        appendCompletedWorkTrace(previous, turnID: snapshot.id)
      }
      currentWorkTraces[snapshot.id] = snapshot.trace

      if workNarrations[snapshot.id] == nil,
        let detail = snapshot.detail?.askIAgentNonEmptyText
      {
        workNarrations[snapshot.id] = detail
      }
    }
  }

  private func appendCompletedWorkTrace(_ trace: AskIAgentWorkTrace, turnID: UUID) {
    var traces = completedWorkTraces[turnID] ?? []
    switch trace {
    case .status(let label):
      let cleaned = label.askIAgentStatusText
      guard cleaned.caseInsensitiveCompare("Thinking") != .orderedSame else { return }
      let normalized = AskIAgentWorkTrace.status(cleaned)
      guard traces.last != normalized, !traces.contains(normalized) else { return }
      traces.append(normalized)

    case .search(let result):
      guard result.totalCount > 0 else { return }
      let normalized = AskIAgentWorkTrace.search(result)
      if let index = traces.firstIndex(where: { existing in
        guard case .search(let saved) = existing else { return false }
        return saved.kind == result.kind
      }) {
        traces[index] = normalized
      } else {
        traces.append(normalized)
      }
    }
    completedWorkTraces[turnID] = traces
  }

  private static let newChatPrompts = [
    "Plan my day",
    "What needs my attention?",
    "Summarize my latest meeting",
  ]

  private var availabilityState: some View {
    let copy = presentation.availability.copy

    return ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Image(systemName: copy.symbol)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(copy.tint)
          .frame(width: 52, height: 52)
          .background(PanelTheme.surface, in: Circle())
          .accessibilityHidden(true)

        Text(copy.title)
          .font(.title2.bold())
          .foregroundStyle(PanelTheme.primary)
          .padding(.top, 24)

        Text(copy.detail)
          .font(.body)
          .foregroundStyle(PanelTheme.secondary)
          .lineSpacing(5)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 12)

        if let action = copy.action {
          Button {
            switch action {
            case .retry: onRetryAvailability()
            case .openSettings: onOpenSettings()
            }
          } label: {
            Text(action.label)
              .font(.body.weight(.bold))
              .foregroundStyle(PanelTheme.canvas)
              .frame(maxWidth: .infinity)
              .frame(minHeight: 50)
              .background(PanelTheme.primary, in: Capsule())
          }
          .buttonStyle(AskIAgentPrimaryButtonStyle())
          .padding(.top, 28)
        }

        Text(
          modelTier.usesRemoteService
            ? "Fast and Pro send only the question and retrieved context through your configured private relay."
            : "Free answers on this device and does not send your question to a remote AI service."
        )
          .font(.footnote.weight(.medium))
          .foregroundStyle(PanelTheme.secondary)
          .lineSpacing(2)
          .padding(.top, 28)
      }
      .frame(maxWidth: 440, alignment: .leading)
      .padding(.horizontal, PanelTheme.horizontalPadding)
      .padding(.top, 54)
      .padding(.bottom, 36)
    }
    .scrollIndicators(.hidden)
    .accessibilityElement(children: .contain)
  }

  private func toggleCompletionDetails(_ id: UUID) {
    withAnimation(reduceMotion ? nil : PanelTheme.disclosure) {
      if expandedCompletionIDs.contains(id) {
        expandedCompletionIDs.remove(id)
      } else {
        expandedCompletionIDs.insert(id)
      }
    }
  }

  private func completionDetail(contextAsOf: Date?, sourceCount: Int) -> String {
    let sourceLabel = "\(sourceCount) local \(sourceCount == 1 ? "source" : "sources")"
    guard let contextAsOf else { return sourceLabel }
    return
      "\(sourceLabel) · data as of \(contextAsOf.formatted(date: .abbreviated, time: .shortened))"
  }

  private func scrollToTurn(_ id: UUID, proxy: ScrollViewProxy) {
    let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.24)
    withAnimation(animation) {
      proxy.scrollTo(id, anchor: .top)
    }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
    if !isNearConversationBottom {
      isNearConversationBottom = true
    }
    let animation: Animation? = reduceMotion || !animated ? nil : .easeOut(duration: 0.22)
    withAnimation(animation) {
      proxy.scrollTo("ask-iagent-bottom", anchor: .bottom)
    }
  }
}

// MARK: - Source results

private struct AskIAgentSourceGroup: View {
  let sources: [AskIAgentUISource]
  let onSelect: (AskIAgentUISource) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsAll = false
  private let initialSourceLimit = 3

  private var visibleSources: [AskIAgentUISource] {
    showsAll ? sources : Array(sources.prefix(initialSourceLimit))
  }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(visibleSources.enumerated()), id: \.element.id) { index, source in
        Button {
          onSelect(source)
        } label: {
          sourceRow(source)
        }
        .buttonStyle(AskIAgentSourceButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.accessibilityLabel)
        .accessibilityHint("Shows a read-only source preview")

        if index < visibleSources.count - 1 {
          AskIAgentDottedDivider()
            .padding(.horizontal, 14)
        }
      }

      if sources.count > initialSourceLimit {
        Button {
          withAnimation(reduceMotion ? nil : PanelTheme.disclosure) { showsAll.toggle() }
        } label: {
          HStack {
            Text(
              showsAll
                ? "Show fewer"
                : "Show \(sources.count - initialSourceLimit) more"
            )
              .font(.footnote.weight(.bold))
              .foregroundStyle(PanelTheme.secondary)
            Spacer()
            Image(systemName: showsAll ? "chevron.up" : "chevron.down")
              .font(.caption2.bold())
              .foregroundStyle(PanelTheme.tertiary)
          }
          .padding(.horizontal, 17)
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(AskIAgentSourceButtonStyle())
        .accessibilityLabel(
          showsAll
            ? "Show fewer sources"
            : "Show \(sources.count - initialSourceLimit) more sources"
        )
        .accessibilityValue(showsAll ? "Expanded" : "Collapsed")
        .accessibilityHint(showsAll ? "Collapses the source list" : "Expands the source list")
      }
    }
    .background(
      PanelTheme.surface.opacity(0.72),
      in: RoundedRectangle(cornerRadius: 17, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(PanelTheme.border, lineWidth: 0.5)
    }
    .clipped()
    .onAppear {
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ask-iagent-expand-sources") {
          showsAll = true
        }
      #endif
    }
  }

  private func sourceRow(_ source: AskIAgentUISource) -> some View {
    HStack(spacing: 12) {
      source.neutralIcon
        .frame(width: 22, height: 22)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(source.title)
            .font(.body.weight(.semibold))
            .foregroundStyle(
              source.freshness == .unavailable ? PanelTheme.secondary : PanelTheme.primary
            )
            .lineLimit(1)

          if let citationNumber = source.citationNumber {
            Text("[\(citationNumber)]")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(PanelTheme.tertiary)
          }
        }

        if source.freshness != .current {
          Text(source.freshness.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(source.freshness == .updated ? PanelTheme.amber : PanelTheme.coral)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(source.metadata)
        .font(.caption.weight(.medium))
        .foregroundStyle(PanelTheme.tertiary)
        .monospacedDigit()
        .lineLimit(1)
        .multilineTextAlignment(.trailing)

      Image(systemName: "chevron.right")
        .font(.caption2.bold())
        .foregroundStyle(PanelTheme.tertiary)
    }
    .padding(.horizontal, 15)
    .frame(minHeight: 58)
    .contentShape(Rectangle())
  }
}

private struct AskIAgentSourcePreview: View {
  let source: AskIAgentUISource
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack(alignment: .top, spacing: 14) {
            source.icon
              .frame(width: 42, height: 42)
              .background(PanelTheme.surface, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
              Text(source.kind.label)
                .font(.caption.bold())
                .tracking(1.1)
                .foregroundStyle(source.kind.tint)
              Text(source.title)
                .font(.title3.bold())
                .foregroundStyle(PanelTheme.primary)
                .fixedSize(horizontal: false, vertical: true)
              Text(source.metadata)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PanelTheme.secondary)
            }
          }

          if source.freshness != .current {
            Label(source.freshness.previewLabel, systemImage: "clock.badge.exclamationmark")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(source.freshness == .updated ? PanelTheme.amber : PanelTheme.coral)
          }

          if let preview = source.preview, !preview.isEmpty {
            Text(preview)
              .font(.body)
              .foregroundStyle(PanelTheme.primary)
              .lineSpacing(5)
              .textSelection(.enabled)
          }

          if !source.detailRows.isEmpty {
            VStack(spacing: 0) {
              ForEach(Array(source.detailRows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                  Text(row.label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PanelTheme.secondary)
                  Spacer(minLength: 12)
                  Text(row.value)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(PanelTheme.primary)
                    .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if index < source.detailRows.count - 1 {
                  AskIAgentDottedDivider()
                    .padding(.horizontal, 16)
                }
              }
            }
            .background(
              PanelTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          }

          Text("This preview is read-only. Ask iAgent cannot change the source.")
            .font(.footnote.weight(.medium))
            .foregroundStyle(PanelTheme.tertiary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
      .scrollIndicators(.hidden)
      .background(PanelTheme.sheet)
      .navigationTitle("Source")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .fontWeight(.semibold)
        }
      }
    }
    .tint(PanelTheme.primary)
    .accessibilityIdentifier("ask-iagent-source-preview")
  }
}

// MARK: - History

private struct AskIAgentHistorySheet: View {
  let items: [AskIAgentUIHistoryItem]
  let statusMessage: String?
  let onOpen: (UUID) -> Void
  let onDelete: (UUID) -> Void
  let onClear: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var pendingDelete: AskIAgentUIHistoryItem?
  @State private var isClearConfirmationPresented = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let statusMessage {
          Label(statusMessage, systemImage: "icloud")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PanelTheme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(PanelTheme.surface)
        }

        Group {
          if items.isEmpty {
            ContentUnavailableView(
              "No chat history",
              systemImage: "bubble.left.and.bubble.right",
              description: Text("Conversations you keep will appear here.")
            )
            .foregroundStyle(PanelTheme.secondary)
          } else {
            List(items) { item in
              Button {
                onOpen(item.id)
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  HStack(spacing: 8) {
                    Text(item.title)
                      .font(.body.weight(.semibold))
                      .foregroundStyle(PanelTheme.primary)
                      .lineLimit(1)
                    if item.isCurrent {
                      Circle()
                        .fill(PanelTheme.amber)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Current chat")
                    }
                  }

                  Text(item.excerpt)
                    .font(.footnote)
                    .foregroundStyle(PanelTheme.secondary)
                    .lineLimit(2)

                  Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PanelTheme.tertiary)
                }
                .padding(.vertical, 5)
              }
              .buttonStyle(.plain)
              .listRowBackground(PanelTheme.sheet)
              .listRowSeparatorTint(PanelTheme.border)
              .accessibilityElement(children: .combine)
              .accessibilityAddTraits(.isButton)
              .accessibilityHint("Opens this conversation")
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                  pendingDelete = item
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
              .accessibilityAction(named: "Delete chat") { pendingDelete = item }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PanelTheme.sheet)
          }
        }
      }
      .navigationTitle("Chat history")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if !items.isEmpty {
            Button("Clear all", role: .destructive) {
              isClearConfirmationPresented = true
            }
            .fontWeight(.semibold)
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .fontWeight(.semibold)
        }
      }
    }
    .tint(PanelTheme.primary)
    .confirmationDialog(
      "Delete this chat?",
      isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingDelete
    ) { item in
      Button("Delete chat", role: .destructive) {
        pendingDelete = nil
        onDelete(item.id)
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: { _ in
      Text("This removes the conversation from this device and private iCloud history.")
    }
    .confirmationDialog(
      "Clear all chat history?",
      isPresented: $isClearConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Clear all", role: .destructive, action: onClear)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This cannot be undone and applies to devices using your private iCloud history.")
    }
    .accessibilityIdentifier("ask-iagent-history")
  }
}

// MARK: - Visual helpers

@MainActor
private final class AskIAgentSpeechReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
  @Published private(set) var activeTurnID: UUID?

  private let synthesizer = AVSpeechSynthesizer()

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func toggle(turnID: UUID, text: String) {
    if activeTurnID == turnID, synthesizer.isSpeaking {
      stop()
      return
    }

    synthesizer.stopSpeaking(at: .immediate)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: Locale.autoupdatingCurrent.identifier)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    activeTurnID = turnID
    synthesizer.speak(utterance)
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    activeTurnID = nil
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor [weak self] in self?.activeTurnID = nil }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor [weak self] in self?.activeTurnID = nil }
  }
}

private struct AskIAgentStreamingText: View {
  let text: String
  let reduceMotion: Bool
  let onProgress: () -> Void
  let onComplete: () -> Void

  @State private var visibleCharacterCount = 0

  private var document: AskIAgentMarkdownDocument {
    AskIAgentMarkdownDocument(markdown: text)
  }

  var body: some View {
    AskIAgentMarkdownDocumentView(
      document: document,
      visibleCharacterCount: visibleCharacterCount,
      softEdgeCount: reduceMotion ? 0 : 2
    )
      .transaction { transaction in
        transaction.animation = nil
      }
      .task(id: text) {
        await revealText()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(text)
      .accessibilityAddTraits(.updatesFrequently)
  }

  @MainActor
  private func revealText() async {
    let characters = document.displayCharacters
    guard !characters.isEmpty else {
      onComplete()
      return
    }

    if reduceMotion {
      visibleCharacterCount = characters.count
      onProgress()
      onComplete()
      return
    }

    visibleCharacterCount = 0
    while visibleCharacterCount < characters.count {
      guard !Task.isCancelled else { return }
      visibleCharacterCount = min(characters.count, visibleCharacterCount + 2)
      // Scroll following is deliberately slower than glyph reveal. Coalescing these
      // updates preserves the streaming cadence without forcing layout every few frames.
      if visibleCharacterCount.isMultiple(of: 16) || visibleCharacterCount == characters.count {
        onProgress()
      }

      let finalCharacter = characters[max(0, visibleCharacterCount - 1)]
      let delay: Duration
      if ".!?\n".contains(finalCharacter) {
        delay = .milliseconds(72)
      } else if ",;:".contains(finalCharacter) {
        delay = .milliseconds(42)
      } else {
        delay = .milliseconds(24)
      }

      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
    }

    onComplete()
  }
}

private struct AskIAgentMarkdownText: View {
  let text: String
  var isLead = false
  var citations: [AskIAgentUICitationMarker] = []
  var onCitationSelect: (AskIAgentUICitationMarker) -> Void = { _ in }

  var body: some View {
    let document = AskIAgentMarkdownDocument(markdown: text, citations: citations)
    AskIAgentMarkdownDocumentView(
      document: document,
      visibleCharacterCount: document.totalCharacterCount,
      softEdgeCount: 0,
      emphasizesLeadParagraph: isLead
    )
    .textSelection(.enabled)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(document.accessibilityText)
    .accessibilityHint(accessibilityHint)
    .accessibilityActions {
      ForEach(citations) { citation in
        Button("Open source \(citation.marker): \(citation.sourceTitle)") {
          onCitationSelect(citation)
        }
      }
    }
    .environment(\.openURL, OpenURLAction { url in
      if let citation = citation(for: url) {
        onCitationSelect(citation)
        return .handled
      }

      guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
      else { return .discarded }
      return .systemAction(url)
    })
  }

  private var accessibilityHint: Text {
    if citations.isEmpty {
      Text("")
    } else if citations.count == 1 {
      Text("Contains one source citation. Use the Source action to open it.")
    } else {
      Text("Contains \(citations.count) source citations. Use the Source actions to open them.")
    }
  }

  private func citation(for url: URL) -> AskIAgentUICitationMarker? {
    guard url.scheme?.lowercased() == AskIAgentMarkdownDocument.citationScheme,
      url.host?.lowercased() == AskIAgentMarkdownDocument.citationHost,
      let marker = Int(url.lastPathComponent)
    else { return nil }
    return citations.first { $0.marker == marker }
  }
}

/// A deliberately small, native Markdown surface for assistant prose. It accepts headings,
/// paragraphs, ordered/unordered lists, emphasis, and web links, while never evaluating HTML,
/// scripts, code blocks, or arbitrary URL schemes.
private struct AskIAgentMarkdownDocument {
  static let citationScheme = "iagent-source"
  static let citationHost = "citation"

  struct Block: Identifiable {
    enum Kind: Equatable {
      case heading(Int)
      case paragraph
      case unorderedItem
      case orderedItem(Int)
    }

    let id: Int
    let kind: Kind
    let content: AttributedString
    let characterOffset: Int

    var characterCount: Int { content.characters.count }
  }

  let blocks: [Block]
  let displayCharacters: [Character]
  let accessibilityText: String

  var totalCharacterCount: Int { displayCharacters.count }
  var plainText: String { accessibilityText }

  init(markdown: String, citations: [AskIAgentUICitationMarker] = []) {
    var parsed: [(Block.Kind, AttributedString)] = []
    var paragraphLines: [String] = []

    func flushParagraph() {
      guard !paragraphLines.isEmpty else { return }
      let paragraph = paragraphLines.joined(separator: " ")
      parsed.append((.paragraph, Self.inlineMarkdown(paragraph)))
      paragraphLines.removeAll(keepingCapacity: true)
    }

    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else {
        flushParagraph()
        continue
      }

      if let heading = Self.heading(in: trimmed) {
        flushParagraph()
        parsed.append((.heading(heading.level), Self.inlineMarkdown(heading.text)))
      } else if let item = Self.unorderedItem(in: trimmed) {
        flushParagraph()
        parsed.append((.unorderedItem, Self.inlineMarkdown(item)))
      } else if let item = Self.orderedItem(in: trimmed) {
        flushParagraph()
        parsed.append((.orderedItem(item.number), Self.inlineMarkdown(item.text)))
      } else {
        paragraphLines.append(trimmed)
      }
    }
    flushParagraph()

    if parsed.isEmpty, !markdown.isEmpty {
      parsed = [(.paragraph, Self.inlineMarkdown(markdown))]
    }

    accessibilityText = parsed
      .map { String($0.1.characters) }
      .joined(separator: "\n")

    if !citations.isEmpty, let lastIndex = parsed.indices.last {
      parsed[lastIndex].1 += Self.inlineCitations(citations)
    }

    var offset = 0
    blocks = parsed.enumerated().map { index, item in
      defer { offset += item.1.characters.count }
      return Block(id: index, kind: item.0, content: item.1, characterOffset: offset)
    }
    displayCharacters = blocks.flatMap { Array($0.content.characters) }
  }

  private static func heading(in line: String) -> (level: Int, text: String)? {
    let prefixCount = line.prefix(while: { $0 == "#" }).count
    guard (1...3).contains(prefixCount), line.dropFirst(prefixCount).first == " " else {
      return nil
    }
    let text = line.dropFirst(prefixCount + 1).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (prefixCount, text)
  }

  private static func unorderedItem(in line: String) -> String? {
    guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
    let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  private static func orderedItem(in line: String) -> (number: Int, text: String)? {
    guard let dot = line.firstIndex(of: "."), dot < line.endIndex else { return nil }
    let numberText = line[..<dot]
    guard !numberText.isEmpty, numberText.allSatisfy(\.isNumber),
      let number = Int(numberText), line.index(after: dot) < line.endIndex,
      line[line.index(after: dot)] == " "
    else { return nil }
    let text = line[line.index(dot, offsetBy: 2)...].trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (number, text)
  }

  private static func inlineMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    var attributed =
      (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    let unsafeLinkRanges = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
      guard let link = run.link,
        let scheme = link.scheme?.lowercased(),
        scheme != "https", scheme != "http"
      else { return nil }
      return run.range
    }
    for range in unsafeLinkRanges {
      attributed[range].link = nil
    }
    return attributed
  }

  private static func inlineCitations(
    _ citations: [AskIAgentUICitationMarker]
  ) -> AttributedString {
    var result = AttributedString()

    for citation in citations {
      result += AttributedString("\u{202F}")

      var marker = AttributedString("\(citation.marker)")
      marker.font = .caption2.weight(.semibold)
      marker.foregroundColor = PanelTheme.secondary
      marker.baselineOffset = 5
      marker.link = URL(
        string: "\(citationScheme)://\(citationHost)/\(citation.marker)"
      )
      result += marker
    }

    return result
  }
}

private struct AskIAgentMarkdownDocumentView: View {
  let document: AskIAgentMarkdownDocument
  let visibleCharacterCount: Int
  let softEdgeCount: Int
  var emphasizesLeadParagraph = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(document.blocks) { block in
        let visibleCount = visibleCount(for: block)
        if visibleCount > 0 {
          AskIAgentMarkdownBlockView(
            block: block,
            visibleCharacterCount: visibleCount,
            stableCharacterCount: stableCount(for: block, visibleCount: visibleCount),
            isLeadParagraph: emphasizesLeadParagraph && block.id == 0
          )
          .padding(.top, spacingBefore(block))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var clampedVisibleCount: Int {
    min(max(0, visibleCharacterCount), document.totalCharacterCount)
  }

  private var stableGlobalCount: Int {
    max(0, clampedVisibleCount - min(softEdgeCount, clampedVisibleCount))
  }

  private func visibleCount(for block: AskIAgentMarkdownDocument.Block) -> Int {
    min(block.characterCount, max(0, clampedVisibleCount - block.characterOffset))
  }

  private func stableCount(
    for block: AskIAgentMarkdownDocument.Block,
    visibleCount: Int
  ) -> Int {
    min(visibleCount, max(0, stableGlobalCount - block.characterOffset))
  }

  private func spacingBefore(_ block: AskIAgentMarkdownDocument.Block) -> CGFloat {
    guard block.id > 0 else { return 0 }
    let previous = document.blocks[block.id - 1].kind
    return switch (previous, block.kind) {
    case (.unorderedItem, .unorderedItem), (.orderedItem, .orderedItem): 8
    case (_, .heading): 20
    case (.heading, _): 9
    default: 14
    }
  }
}

private struct AskIAgentMarkdownBlockView: View {
  let block: AskIAgentMarkdownDocument.Block
  let visibleCharacterCount: Int
  let stableCharacterCount: Int
  let isLeadParagraph: Bool

  @ScaledMetric(relativeTo: .body) private var bulletSize = 4.25

  var body: some View {
    switch block.kind {
    case .heading(let level):
      styledText
        .font(headingFont(level))
        .lineSpacing(3)
    case .paragraph:
      styledText
        .font(.body.weight(isLeadParagraph ? .medium : .regular))
        .lineSpacing(4.5)
    case .unorderedItem:
      HStack(alignment: .firstTextBaseline, spacing: 11) {
        Circle()
          .fill(PanelTheme.secondary)
          .frame(width: bulletSize, height: bulletSize)
          .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[VerticalAlignment.center] }
          .accessibilityHidden(true)
        styledText
          .font(.body)
          .lineSpacing(4.5)
      }
      .padding(.leading, 5)
    case .orderedItem(let number):
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("\(number).")
          .font(.callout.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(PanelTheme.secondary)
          .frame(minWidth: 20, alignment: .trailing)
          .accessibilityHidden(true)
        styledText
          .font(.body)
          .lineSpacing(4.5)
      }
      .padding(.leading, 2)
    }
  }

  private var styledText: Text {
    let visible = min(visibleCharacterCount, block.characterCount)
    let stable = min(stableCharacterCount, visible)
    return textPrefix(stable).foregroundColor(PanelTheme.primary)
      + textRange(from: stable, count: visible - stable)
        .foregroundColor(PanelTheme.primary.opacity(0.52))
  }

  private func textPrefix(_ count: Int) -> Text {
    textRange(from: 0, count: count)
  }

  private func textRange(from offset: Int, count: Int) -> Text {
    guard count > 0 else { return Text("") }
    let characters = block.content.characters
    let lower = characters.index(characters.startIndex, offsetBy: offset)
    let upper = characters.index(lower, offsetBy: count)
    return Text(AttributedString(block.content[lower..<upper]))
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title3.bold()
    case 2: .headline
    default: .body.weight(.semibold)
    }
  }
}

private enum AskIAgentWorkSymbol {
  static func sourceSymbol(for text: String) -> String? {
    let normalized = text.lowercased()
    if normalized.contains("todo") { return "checkmark.square" }
    if normalized.contains("calendar") || normalized.contains("event") { return "calendar" }
    if normalized.contains("meeting") || normalized.contains("transcript") { return "waveform" }
    if normalized.contains("note") { return "note.text" }
    if normalized.contains("codex") || normalized.contains("thread") { return "sparkles" }
    return nil
  }

  static func traceSymbol(for text: String) -> String {
    if let source = sourceSymbol(for: text) { return source }
    let normalized = text.lowercased()
    if normalized.contains("write") || normalized.contains("answer") { return "pencil.line" }
    if normalized.contains("check") || normalized.contains("citation") { return "checkmark.shield" }
    if normalized.contains("read") || normalized.contains("ground") { return "book.closed" }
    return "magnifyingglass"
  }
}

private struct AskIAgentWorkTraceGroup: View {
  let traces: [AskIAgentWorkTrace]
  let activeTrace: AskIAgentWorkTrace?
  let reduceMotion: Bool

  private var rows: [AskIAgentWorkTrace] {
    (traces + (activeTrace.map { [$0] } ?? [])).askIAgentVisibleTraces
  }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(rows) { trace in
        row(trace, isActive: activeTrace?.id == trace.id)
          .transition(.opacity)

        if trace.id != rows.last?.id {
          AskIAgentSolidDivider()
            .padding(.leading, 38)
            .padding(.trailing, 14)
        }
      }
    }
    .animation(reduceMotion ? nil : PanelTheme.quick, value: rows)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      PanelTheme.surface.opacity(0.72),
      in: RoundedRectangle(cornerRadius: 15, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 15, style: .continuous)
        .strokeBorder(PanelTheme.border, lineWidth: 0.5)
    }
    .clipped()
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func row(_ trace: AskIAgentWorkTrace, isActive: Bool) -> some View {
    switch trace {
    case .status(let text):
      AskIAgentWorkTraceRow(text: text, isActive: isActive, reduceMotion: reduceMotion)
    case .search(let result):
      AskIAgentSearchTraceRow(
        result: result,
        isActive: isActive,
        reduceMotion: reduceMotion
      )
    }
  }
}

private struct AskIAgentWorkTraceRow: View {
  let text: String
  let isActive: Bool
  let reduceMotion: Bool

  var body: some View {
    AskIAgentWorkRow(
      symbol: symbol,
      text: text,
      isActive: isActive,
      reduceMotion: reduceMotion
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isActive ? "Working. \(text)" : text)
    .accessibilityAddTraits(isActive ? .updatesFrequently : .isStaticText)
    .accessibilityIdentifier(isActive ? "ask-iagent-work-status" : "ask-iagent-work-trace")
  }

  private var symbol: String {
    AskIAgentWorkSymbol.traceSymbol(for: text)
  }
}

private struct AskIAgentSearchTraceRow: View {
  let result: AskIAgentUISearchResult
  let isActive: Bool
  let reduceMotion: Bool
  @State private var isExpanded = false

  private var canExpand: Bool { result.totalCount > 0 && !result.titles.isEmpty }

  var body: some View {
    VStack(spacing: 0) {
      if canExpand {
        Button {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            isExpanded.toggle()
          }
        } label: {
          header(showsChevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(result.label)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides matching item titles" : "Shows matching item titles")
        .accessibilityIdentifier("ask-iagent-search-\(result.kind.rawValue)")
      } else {
        header(showsChevron: false)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(result.label)
      }

      if isExpanded, canExpand {
        AskIAgentSolidDivider()
          .padding(.leading, 38)
          .padding(.trailing, 14)

        VStack(spacing: 0) {
          ForEach(Array(result.titles.enumerated()), id: \.offset) { index, title in
            HStack(spacing: 0) {
              Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(PanelTheme.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

              Spacer(minLength: 8)
            }
            .padding(.leading, 38)
            .padding(.trailing, 14)
            .frame(minHeight: 42)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)

            if index < result.titles.count - 1 {
              AskIAgentSolidDivider()
                .padding(.leading, 38)
                .padding(.trailing, 14)
            }
          }
        }
        .transition(
          reduceMotion
            ? .identity
            : .opacity
        )
        .accessibilityElement(children: .contain)
      }
    }
    .onAppear {
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ask-iagent-expand-search-results") {
          isExpanded = true
        }
      #endif
    }
  }

  private func header(showsChevron: Bool) -> some View {
    AskIAgentWorkRow(
      symbol: result.kind.workSymbol,
      text: result.label,
      isActive: isActive,
      reduceMotion: reduceMotion,
      disclosure: showsChevron ? (isExpanded ? .expanded : .collapsed) : nil
    )
  }
}

private struct AskIAgentWorkRow: View {
  enum Disclosure {
    case collapsed
    case expanded

    var symbol: String {
      switch self {
      case .collapsed: "chevron.right"
      case .expanded: "chevron.down"
      }
    }
  }

  let symbol: String
  let text: String
  let isActive: Bool
  let reduceMotion: Bool
  var disclosure: Disclosure?

  var body: some View {
    HStack(alignment: .center, spacing: 9) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(PanelTheme.tertiary)
        .frame(width: 16, height: 16, alignment: .center)
        .accessibilityHidden(true)

      AskIAgentWorkRowLabel(
        text: text,
        isActive: isActive,
        reduceMotion: reduceMotion
      )

      if let disclosure {
        Spacer(minLength: 8)
        Image(systemName: disclosure.symbol)
          .font(.caption2.bold())
          .foregroundStyle(PanelTheme.tertiary)
          .frame(width: 16, height: 16, alignment: .center)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }
}

private struct AskIAgentWorkRowLabel: View {
  let text: String
  let isActive: Bool
  let reduceMotion: Bool

  @State private var highlightOffset: CGFloat = -160

  var body: some View {
    Group {
      if reduceMotion || !isActive {
        statusText.foregroundStyle(PanelTheme.secondary)
      } else {
        statusText
          .foregroundStyle(PanelTheme.secondary)
          .overlay(alignment: .leading) {
            GeometryReader { proxy in
              LinearGradient(
                colors: [.clear, PanelTheme.primary, .clear],
                startPoint: .leading,
                endPoint: .trailing
              )
              .frame(width: max(56, proxy.size.width * 0.46))
              .offset(x: highlightOffset)
              .onAppear {
                highlightOffset = -160
                withAnimation(PanelTheme.shimmer) {
                  highlightOffset = proxy.size.width + 160
                }
              }
            }
            .mask(statusText)
          }
      }
    }
    .frame(minHeight: 20, alignment: .center)
    .fixedSize(horizontal: false, vertical: true)
    .contentTransition(.opacity)
    .animation(reduceMotion ? nil : PanelTheme.quick, value: text)
  }

  private var statusText: Text {
    Text(text).font(.footnote.weight(.medium))
  }
}

private struct AskIAgentMaterial: View {
  let cornerRadius: CGFloat
  var shadowRadius: CGFloat = 14
  var shadowY: CGFloat = 8
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    ZStack {
      if reduceTransparency {
        shape.fill(PanelTheme.sheetRaised)
      } else {
        shape.fill(.ultraThinMaterial)
        shape.fill(Color.black.opacity(0.38))
      }

      shape.strokeBorder(PanelTheme.strongBorder, lineWidth: 0.75)
    }
    .shadow(color: .black.opacity(0.42), radius: shadowRadius, x: 0, y: shadowY)
  }
}

private struct AskIAgentDottedDivider: View {
  var body: some View {
    Canvas { context, size in
      var path = Path()
      path.move(to: CGPoint(x: 0, y: 0.5))
      path.addLine(to: CGPoint(x: size.width, y: 0.5))
      context.stroke(
        path,
        with: .color(PanelTheme.strongBorder),
        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 6])
      )
    }
    .frame(height: 1)
    .accessibilityHidden(true)
  }
}

private struct AskIAgentSolidDivider: View {
  var body: some View {
    Rectangle()
      .fill(PanelTheme.border)
      .frame(height: 0.5)
      .accessibilityHidden(true)
  }
}

private struct AskIAgentRoundButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(PanelTheme.primary)
      .background(
        configuration.isPressed ? PanelTheme.raisedSurface : PanelTheme.surface,
        in: Circle()
      )
      .overlay {
        Circle().strokeBorder(PanelTheme.border, lineWidth: 0.75)
      }
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct AskIAgentHeaderActionStyle: ButtonStyle {
  enum Edge {
    case leading
    case trailing
  }

  let edge: Edge

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(PanelTheme.primary)
      .background {
        if configuration.isPressed {
          UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? 27 : 0,
            bottomLeadingRadius: edge == .leading ? 27 : 0,
            bottomTrailingRadius: edge == .trailing ? 27 : 0,
            topTrailingRadius: edge == .trailing ? 27 : 0,
            style: .continuous
          )
          .fill(PanelTheme.raisedSurface)
        }
      }
      .opacity(configuration.isPressed ? 0.86 : 1)
  }
}

private struct AskIAgentSourceButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? PanelTheme.raisedSurface : Color.clear)
      .opacity(configuration.isPressed ? 0.9 : 1)
  }
}

private struct AskIAgentComposerButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.93 : 1)
      .opacity(configuration.isPressed ? 0.86 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct AskIAgentResponseActionButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.92 : 1)
      .opacity(configuration.isPressed ? 0.68 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct AskIAgentComposerToolButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(PanelTheme.primary)
      .background(
        configuration.isPressed ? PanelTheme.raisedSurface : Color.clear,
        in: Circle()
      )
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.94 : 1)
      .opacity(configuration.isPressed ? 0.86 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct AskIAgentModelMenuButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, 8)
      .background(
        configuration.isPressed ? PanelTheme.raisedSurface : PanelTheme.surface.opacity(0.72),
        in: Capsule()
      )
      .overlay {
        Capsule().strokeBorder(PanelTheme.border, lineWidth: 0.6)
      }
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
      .opacity(configuration.isPressed ? 0.86 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct AskIAgentSuggestionButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .clipShape(Capsule())
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct AskIAgentMentionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? PanelTheme.raisedSurface : Color.clear)
      .opacity(configuration.isPressed ? 0.88 : 1)
  }
}

private struct AskIAgentPrimaryButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
      .opacity(configuration.isPressed ? 0.88 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

extension AskIAgentAvailability {
  fileprivate var uiAvailability: AskIAgentUIAvailability {
    switch self {
    case .available: .available
    case .remoteRelayNotConfigured: .remoteRelayNotConfigured
    case .requiresIOS26: .requiresNewerOS
    case .deviceNotEligible: .deviceNotEligible
    case .appleIntelligenceDisabled: .appleIntelligenceDisabled
    case .modelNotReady: .modelPreparing
    case .unsupportedLocale: .unsupportedLanguage(nil)
    case .unknown: .temporarilyUnavailable(message)
    }
  }
}

extension AskIAgentWorkStage {
  fileprivate var uiDetail: String? {
    // The UI exposes observable retrieval activity, never hidden model reasoning.
    nil
  }

  fileprivate var uiWorkTrace: AskIAgentWorkTrace? {
    switch self {
    case .searchedSource(let scan):
      scan.totalCount > 0 ? .search(scan.uiSearchResult) : nil
    default:
      .status(message.askIAgentStatusText)
    }
  }
}

extension AskIAgentSourceKind {
  fileprivate var uiSearchResultKind: AskIAgentUISource.Kind { uiKind }

  fileprivate var uiKind: AskIAgentUISource.Kind {
    switch self {
    case .todo: .todo
    case .calendar: .calendar
    case .note: .note
    case .meeting: .meeting
    case .codex: .codex
    }
  }
}

extension AskIAgentSourceScan {
  fileprivate var uiSearchResult: AskIAgentUISearchResult {
    AskIAgentUISearchResult(
      kind: kind.uiSearchResultKind,
      totalCount: totalCount,
      titles: titles
    )
  }
}

extension AskIAgentUISource.Kind {
  fileprivate var workSymbol: String {
    switch self {
    case .todo: "checkmark.square"
    case .calendar: "calendar"
    case .note: "note.text"
    case .meeting: "waveform"
    case .codex: "sparkles"
    }
  }
}

extension AskSourceKind {
  fileprivate var uiKind: AskIAgentUISource.Kind {
    switch self {
    case .todo: .todo
    case .calendar: .calendar
    case .note: .note
    case .meeting: .meeting
    case .codex: .codex
    }
  }
}

extension AskIAgentSourceResult {
  fileprivate func uiSource(
    citationNumber: Int?,
    freshness: AskIAgentUISource.Freshness = .current
  ) -> AskIAgentUISource {
    AskIAgentUISource(
      id: id,
      kind: kind.uiKind,
      title: title,
      metadata: compactMetadata,
      preview: excerpt,
      detailRows: uiDetailRows,
      citationNumber: citationNumber,
      freshness: freshness
    )
  }

  fileprivate var compactMetadata: String {
    if kind == .codex, let status, !status.isEmpty { return status.lowercased() }
    if kind == .todo, let status, isCompleted { return status.lowercased() }
    if let subtitle, !subtitle.isEmpty { return subtitle }
    if let status, !status.isEmpty { return status }
    return updatedAt.formatted(date: .abbreviated, time: .omitted)
  }

  fileprivate var uiDetailRows: [AskIAgentUIDetailRow] {
    var rows: [AskIAgentUIDetailRow] = [
      .init(label: "Type", value: kind.displayName)
    ]
    if let subtitle, !subtitle.isEmpty {
      rows.append(.init(label: "Details", value: subtitle))
    }
    if let status, !status.isEmpty {
      rows.append(.init(label: "Status", value: status))
    }
    if let startDate {
      let value =
        isAllDay
        ? startDate.formatted(date: .abbreviated, time: .omitted)
        : startDate.formatted(date: .abbreviated, time: .shortened)
      rows.append(.init(label: kind == .todo ? "Due" : "Starts", value: value))
    }
    if let endDate, !isAllDay {
      rows.append(
        .init(label: "Ends", value: endDate.formatted(date: .abbreviated, time: .shortened)))
    }
    rows.append(
      .init(label: "Updated", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
    )
    return rows
  }
}

extension AskIAgentUISource.Kind {
  fileprivate static let mentionKindOrder: [Self] = [.todo, .note, .calendar, .meeting, .codex]

  fileprivate var label: String {
    switch self {
    case .todo: "TODO"
    case .calendar: "CALENDAR"
    case .note: "NOTE"
    case .codex: "CODEX"
    case .meeting: "MEETING"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .todo: PanelTheme.blue
    case .calendar, .meeting: PanelTheme.coral
    case .note: PanelTheme.violet
    case .codex: PanelTheme.green
    }
  }

  fileprivate var symbol: String {
    switch self {
    case .todo: "checkmark.square"
    case .calendar: "calendar"
    case .note: "note.text"
    case .codex: "sparkles"
    case .meeting: "waveform"
    }
  }

  fileprivate var mentionSectionTitle: String {
    switch self {
    case .todo: "TODOS"
    case .note: "NOTES"
    case .calendar: "EVENTS"
    case .meeting: "MEETING NOTES"
    case .codex: "CODEX"
    }
  }

  fileprivate var mentionItemLabel: String {
    switch self {
    case .todo: "todo"
    case .note: "note"
    case .calendar: "event"
    case .meeting: "meeting note"
    case .codex: "Codex task"
    }
  }

  fileprivate var promptReferenceLabel: String {
    switch self {
    case .todo: "todo"
    case .note: "note"
    case .calendar: "event"
    case .meeting: "meeting note"
    case .codex: "Codex task"
    }
  }

  @ViewBuilder
  fileprivate var mentionIcon: some View {
    if self == .codex {
      Image("CodexBlossom")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 18, height: 18)
        .foregroundStyle(tint)
    } else {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(tint)
    }
  }
}

extension AskIAgentUISource {
  @ViewBuilder
  fileprivate var icon: some View {
    if kind == .codex {
      Image("CodexBlossom")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 20, height: 20)
        .foregroundStyle(kind.tint)
    } else {
      Image(systemName: kind.symbol)
        .font(.system(size: 18, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(kind.tint)
    }
  }

  @ViewBuilder
  fileprivate var neutralIcon: some View {
    if kind == .codex {
      Image("CodexBlossom")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 18, height: 18)
        .foregroundStyle(PanelTheme.secondary)
    } else {
      Image(systemName: kind.symbol)
        .font(.system(size: 16, weight: .medium))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(PanelTheme.secondary)
    }
  }

  fileprivate var accessibilityLabel: String {
    var pieces = [kind.label.lowercased(), title, metadata]
    if let citationNumber { pieces.insert("Source \(citationNumber)", at: 0) }
    if freshness != .current { pieces.append(freshness.label) }
    return pieces.joined(separator: ", ")
  }
}

extension AskIAgentUISource.Freshness {
  fileprivate var label: String {
    switch self {
    case .current: "Current"
    case .updated: "Updated since answer"
    case .unavailable: "No longer available"
    }
  }

  fileprivate var previewLabel: String {
    switch self {
    case .current: "This source is current."
    case .updated: "This source has changed since the answer was created."
    case .unavailable: "This source is no longer available in iAgent."
    }
  }
}

extension AskIAgentUIAvailability {
  fileprivate struct Copy {
    enum Action {
      case retry
      case openSettings

      var label: String {
        switch self {
        case .retry: "Check again"
        case .openSettings: "Open Settings"
        }
      }
    }

    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let action: Action?
  }

  fileprivate var copy: Copy {
    switch self {
    case .available:
      Copy(
        symbol: "sparkles",
        tint: PanelTheme.amber,
        title: "Ask iAgent",
        detail: "Ask questions about the information already in iAgent.",
        action: nil
      )
    case .remoteRelayNotConfigured:
      Copy(
        symbol: "network.slash",
        tint: PanelTheme.coral,
        title: "Fast and Pro need a relay",
        detail:
          "Configure the private iAgent OpenAI relay, or choose Free to keep answering on this device.",
        action: nil
      )
    case .requiresNewerOS:
      Copy(
        symbol: "iphone.gen3",
        tint: PanelTheme.secondary,
        title: "iOS 26 is required",
        detail: "Ask iAgent uses Apple’s on-device Foundation Models and needs iOS 26 or later.",
        action: nil
      )
    case .deviceNotEligible:
      Copy(
        symbol: "iphone",
        tint: PanelTheme.secondary,
        title: "Not available on this iPhone",
        detail:
          "This device does not support the Apple Intelligence model required by Ask iAgent. Your existing iAgent data is unchanged.",
        action: nil
      )
    case .appleIntelligenceDisabled:
      Copy(
        symbol: "sparkles",
        tint: PanelTheme.amber,
        title: "Turn on Apple Intelligence",
        detail:
          "Enable Apple Intelligence in Settings, then return here to ask questions over your iAgent data.",
        action: .openSettings
      )
    case .modelPreparing:
      Copy(
        symbol: "arrow.down.circle",
        tint: PanelTheme.amber,
        title: "Apple Intelligence is preparing",
        detail:
          "The on-device model is not ready yet. Keep this iPhone connected to power and Wi-Fi, then check again.",
        action: .retry
      )
    case .unsupportedLanguage(let language):
      Copy(
        symbol: "character.bubble",
        tint: PanelTheme.secondary,
        title: "Language not supported",
        detail: language.map {
          "Ask iAgent does not currently support \($0). Change to a supported Apple Intelligence language and try again."
        }
          ?? "The current device language is not supported by the on-device model.",
        action: nil
      )
    case .temporarilyUnavailable(let message):
      Copy(
        symbol: "exclamationmark.circle",
        tint: PanelTheme.coral,
        title: "Ask iAgent is unavailable",
        detail: message
          ?? "The on-device model could not start. Your question is still here, so you can check again.",
        action: .retry
      )
    }
  }
}

extension Duration {
  fileprivate var askIAgentCompactDescription: String {
    let components = self.components
    let seconds = max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    if seconds < 1 { return "<1s" }
    if seconds < 10 { return "\(Int(seconds.rounded()))s" }
    return "\(Int(seconds.rounded(.down)))s"
  }
}

extension String {
  fileprivate var nonEmptyMentionValue: String? {
    isEmpty ? nil : self
  }

  fileprivate var askIAgentStatusText: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
  }

  fileprivate var askIAgentNonEmptyText: String? {
    let resolved = trimmingCharacters(in: .whitespacesAndNewlines)
    return resolved.isEmpty ? nil : resolved
  }
}

// MARK: - Debug fixtures

#if DEBUG
  enum AskIAgentUIDebugFixtures {
    static func presentation(arguments: [String] = ProcessInfo.processInfo.arguments)
      -> AskIAgentUIPresentation
    {
      if arguments.contains("--ask-iagent-ineligible") {
        return AskIAgentUIPresentation(availability: .deviceNotEligible)
      }
      if arguments.contains("--ask-iagent-disabled") {
        return AskIAgentUIPresentation(availability: .appleIntelligenceDisabled)
      }
      if arguments.contains("--ask-iagent-preparing") {
        return AskIAgentUIPresentation(availability: .modelPreparing)
      }
      if arguments.contains("--ask-iagent-multi-tool-completed") {
        return completed
      }
      if arguments.contains("--ask-iagent-truthful-progress") {
        return truthfulProgress
      }
      if arguments.contains("--ask-iagent-multi-tool-grounding") {
        return multiToolGrounding
      }
      if arguments.contains("--ask-iagent-multi-tool-todo") {
        return multiToolTodo
      }
      if arguments.contains("--ask-iagent-multi-tool-calendar")
        || arguments.contains("--ask-iagent-calendar-collapsed")
      {
        return working
      }
      if arguments.contains("--ask-iagent-completed") {
        return completed
      }
      if arguments.contains("--ask-iagent-follow-up") {
        return followUp
      }
      if arguments.contains("--ask-iagent-working") {
        return working
      }
      return AskIAgentUIPresentation()
    }

    static let calendarResult = AskIAgentUISearchResult(
      kind: .calendar,
      totalCount: 4,
      titles: [
        "Design review",
        "Product review",
        "Focus time",
        "Launch planning",
      ]
    )

    static let todoResult = AskIAgentUISearchResult(
      kind: .todo,
      totalCount: 3,
      titles: [
        "Finish TestFlight build",
        "Validate launch checklist",
        "Prepare product review notes",
      ]
    )

    static let truthfulProgress = AskIAgentUIPresentation(
      title: "Plan today’s priorities",
      turns: [
        AskIAgentUITurn(
          prompt: "What should I focus on today?",
          phase: .working(label: todoResult.label, detail: nil),
          priorWorkTraces: [
            .status("Preparing the local search index"),
            .search(
              AskIAgentUISearchResult(kind: .calendar, totalCount: 0, titles: [])
            ),
            .search(
              AskIAgentUISearchResult(
                kind: .todo,
                totalCount: 1,
                titles: ["Finish TestFlight build"]
              )
            ),
          ],
          activeSearchResult: todoResult
        )
      ],
      isResponding: true,
      canSend: false
    )

    static let fixtureSources: [AskIAgentUISource] = [
      AskIAgentUISource(
        id: "todo-testflight",
        kind: .todo,
        title: "Finish TestFlight build",
        metadata: "1:30 PM",
        preview: "Prepare and validate the next internal TestFlight build.",
        detailRows: [.init(label: "List", value: "Launch")],
        citationNumber: 1
      ),
      AskIAgentUISource(
        id: "event-product-review",
        kind: .calendar,
        title: "Product review",
        metadata: "3:00 PM",
        detailRows: [.init(label: "Calendar", value: "Work")],
        citationNumber: 2
      ),
      AskIAgentUISource(
        id: "note-launch-checklist",
        kind: .note,
        title: "Launch checklist",
        metadata: "today",
        preview: "Final validation steps for the mobile launch.",
        citationNumber: 3
      ),
      AskIAgentUISource(
        id: "codex-ask-architecture",
        kind: .codex,
        title: "Ask iAgent architecture",
        metadata: "running",
        preview: "Planning the local retrieval and grounding pipeline.",
        citationNumber: 4
      ),
      AskIAgentUISource(
        id: "meeting-mobile-launch",
        kind: .meeting,
        title: "Mobile launch review",
        metadata: "Aug 7",
        preview: "The team reviewed launch readiness and remaining validation work.",
        citationNumber: 5
      ),
    ]

    static func citation(_ marker: Int) -> AskIAgentUICitationMarker {
      guard let source = fixtureSources.first(where: { $0.citationNumber == marker }) else {
        preconditionFailure("Missing fixture source \(marker)")
      }
      return AskIAgentUICitationMarker(
        marker: marker,
        sourceID: source.id,
        sourceTitle: source.title
      )
    }

    static let working = AskIAgentUIPresentation(
      title: "Plan today’s priorities",
      turns: [
        AskIAgentUITurn(
          prompt: "What should I focus on today?",
          phase: .working(
            label: "Reading 4 calendar events",
            detail: nil
          ),
          activeSearchResult: calendarResult
        )
      ],
      isResponding: true,
      canSend: false
    )

    static let multiToolTodo = AskIAgentUIPresentation(
      title: "Plan today’s priorities",
      turns: [
        AskIAgentUITurn(
          prompt: "What should I focus on today?",
          phase: .working(label: todoResult.label, detail: nil),
          priorWorkTraces: [
            .search(calendarResult),
            .status("Comparing fixed commitments with open work"),
          ],
          activeSearchResult: todoResult
        )
      ],
      isResponding: true,
      canSend: false
    )

    static let multiToolGrounding = AskIAgentUIPresentation(
      title: "Plan today’s priorities",
      turns: [
        AskIAgentUITurn(
          prompt: "What should I focus on today?",
          phase: .working(label: "Writing the grounded plan", detail: nil),
          priorWorkTraces: [
            .search(calendarResult),
            .status("Comparing fixed commitments with open work"),
            .search(todoResult),
            .status("Checking source freshness and citations"),
          ]
        )
      ],
      isResponding: true,
      canSend: false
    )

    static let completed = AskIAgentUIPresentation(
      title: "Plan today’s priorities",
      turns: [
        AskIAgentUITurn(
          prompt: "What should I focus on today?",
          phase: .completed(elapsed: .seconds(3), contextAsOf: Date(), sourceCount: 5),
          priorWorkTraces: [
            .search(calendarResult),
            .status("Compared fixed commitments with open work"),
            .search(todoResult),
            .status("Checked source freshness and citations"),
          ],
          answerBlocks: [
            AskIAgentUIAnswerBlock(
              id: UUID(),
              text:
                "**Start with the TestFlight build.** It is the clearest priority before the 3:00 PM product review.",
              isLead: true,
              citations: [citation(1), citation(2)]
            ),
            AskIAgentUIAnswerBlock(
              id: UUID(),
              text: "### Then",
              isLead: false,
              citations: []
            ),
            AskIAgentUIAnswerBlock(
              id: UUID(),
              text: "- Use the launch checklist for final validation.",
              isLead: false,
              citations: [citation(3)]
            ),
            AskIAgentUIAnswerBlock(
              id: UUID(),
              text: "- Continue the Codex architecture task after the review.",
              isLead: false,
              citations: [citation(4)]
            ),
            AskIAgentUIAnswerBlock(
              id: UUID(),
              text: "- Bring the remaining launch questions to the mobile review.",
              isLead: false,
              citations: [citation(5)]
            ),
          ],
          sources: fixtureSources,
          suggestions: ["Show me the source notes."]
        )
      ],
      history: [
        AskIAgentUIHistoryItem(
          id: UUID(),
          title: "Plan today’s priorities",
          excerpt: "Finish the TestFlight build first…",
          updatedAt: Date(),
          isCurrent: true
        )
      ]
    )

    static let followUp = AskIAgentUIPresentation(
      title: "Plan today’s priorities",
      turns: [
        AskIAgentUITurn(
          prompt: "What should I focus on today?",
          phase: .completed(elapsed: .seconds(3), contextAsOf: Date(), sourceCount: 2),
          answerBlocks: [
            AskIAgentUIAnswerBlock(
              id: UUID(),
              text: "Start with the design sync, then protect time for the product review.",
              isLead: true
            )
          ],
          suggestions: ["Show me the supporting notes.", "What can wait until tomorrow?"]
        )
      ]
    )
  }

  private struct AskIAgentFixtureHost: View {
    @State private var input = ""
    @State private var modelTier: AskIAgentModelTier = .free
    let presentation: AskIAgentUIPresentation

    var body: some View {
      AskIAgentScreen(
        presentation: presentation,
        input: $input,
        modelTier: $modelTier,
        onDismiss: {},
        onSend: { false },
        onCancel: {},
        onNewChat: {},
        onOpenConversation: { _ in },
        onDeleteConversation: { _ in },
        onClearHistory: {},
        onRetryAvailability: {},
        onOpenSettings: {},
        onRetryTurn: { _ in }
      )
    }
  }

  #Preview("Completed") {
    AskIAgentFixtureHost(presentation: AskIAgentUIDebugFixtures.completed)
      .preferredColorScheme(.dark)
  }

  #Preview("Working") {
    AskIAgentFixtureHost(presentation: AskIAgentUIDebugFixtures.working)
      .preferredColorScheme(.dark)
  }

  #Preview("Truthful retrieval progress") {
    AskIAgentFixtureHost(presentation: AskIAgentUIDebugFixtures.truthfulProgress)
      .preferredColorScheme(.dark)
  }

  #Preview("Unavailable") {
    AskIAgentFixtureHost(
      presentation: AskIAgentUIPresentation(availability: .deviceNotEligible)
    )
    .preferredColorScheme(.dark)
  }
#endif

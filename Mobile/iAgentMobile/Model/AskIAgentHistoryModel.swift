import Combine
import Foundation
import iAgentCore

/// Main-actor bridge between the chat UI model and the durable, private Ask iAgent history store.
///
/// Source data is never written by this type. Chat messages are committed to the local protected
/// JSON store first; private CloudKit synchronization is best-effort and never blocks asking a
/// question. UI tests and fixture runs deliberately keep history local so they cannot touch a real
/// iCloud account.
@MainActor
final class AskIAgentHistoryModel: ObservableObject {
  @Published private(set) var conversations: [AskChatConversation] = []
  @Published private(set) var currentConversation: AskChatConversation?
  @Published private(set) var currentConversationID: UUID?
  @Published private(set) var currentMessages: [AskIAgentMessage] = []
  @Published private(set) var syncStatus = AskChatHistoryStatus()
  @Published private(set) var isLoaded = false

  let chatModel: AskIAgentModel

  private let store: AskChatHistoryStore
  private let cloudSyncEngine: AskChatHistoryCloudSyncEngine?
  private var historyObservation: AnyCancellable?
  private var writeTail: Task<Void, Never>?
  private var delayedSyncTask: Task<Void, Never>?

  /// Each live `AskIAgentModel` session gets an independent token. Keeping the token alongside a
  /// queued write means tapping New chat cannot accidentally attach an in-flight turn to the next
  /// conversation.
  private var activeSessionID = UUID()
  private var conversationIDBySession: [UUID: UUID] = [:]
  private var seenMessageIDsBySession: [UUID: Set<UUID>] = [:]

  init(
    chatModel: AskIAgentModel,
    store suppliedStore: AskChatHistoryStore? = nil,
    cloudSyncEngine suppliedCloudSyncEngine: AskChatHistoryCloudSyncEngine? = nil,
    cloudSyncEnabled: Bool? = nil,
    containerIdentifier: String = "iCloud.com.platon.iagent"
  ) {
    self.chatModel = chatModel

    let process = ProcessInfo.processInfo
    let isFixtureRun =
      process.arguments.contains("--ui-testing")
      || process.environment["IAGENT_FIXTURES"] != nil
    let appIdentifier =
      isFixtureRun
      ? "iAgentMobileFixtures"
      : (Bundle.main.bundleIdentifier ?? "iAgentMobile")
    let resolvedStore =
      suppliedStore
      ?? AskChatHistoryStore(
        fileURL: AskChatHistoryStore.defaultFileURL(appIdentifier: appIdentifier)
      )
    store = resolvedStore

    #if DEBUG && targetEnvironment(simulator)
      // An unsigned Debug Simulator build has no CloudKit entitlement. Constructing CKContainer
      // in that process traps before Ask iAgent renders, so keep history local for this test path.
      let canInitializeCloudKit = false
    #else
      let canInitializeCloudKit = true
    #endif
    let shouldEnableCloud = canInitializeCloudKit && !isFixtureRun && (cloudSyncEnabled ?? true)
    if shouldEnableCloud {
      cloudSyncEngine =
        suppliedCloudSyncEngine
        ?? AskChatHistoryCloudSyncEngine(
          store: resolvedStore,
          containerIdentifier: containerIdentifier
        )
    } else {
      cloudSyncEngine = nil
    }

    historyObservation = chatModel.$history
      .sink { [weak self] messages in
        self?.chatHistoryDidChange(messages)
      }
  }

  /// Publishes local history immediately, then optionally performs best-effort private iCloud sync.
  func load(synchronize shouldSynchronize: Bool = true) async {
    await refreshConversations(reloadCurrentConversation: false)
    syncStatus = AskChatHistoryStatus(
      phase: .idle,
      lastSuccessfulSyncAt: await store.lastSuccessfulSyncAt()
    )
    isLoaded = true

    if shouldSynchronize, cloudSyncEngine != nil {
      await synchronize()
    }
  }

  /// Flushes pending local writes and merges the separate private CloudKit chat zone.
  func synchronize() async {
    if let writeTail { await writeTail.value }
    guard let cloudSyncEngine else {
      syncStatus = AskChatHistoryStatus(
        phase: .idle,
        lastSuccessfulSyncAt: await store.lastSuccessfulSyncAt()
      )
      return
    }

    syncStatus = AskChatHistoryStatus(
      phase: .syncing,
      lastSuccessfulSyncAt: syncStatus.lastSuccessfulSyncAt
    )
    await cloudSyncEngine.synchronize()
    syncStatus = await cloudSyncEngine.status()
    await refreshConversations(reloadCurrentConversation: true)
  }

  /// Starts an unsaved conversation. A durable record is created lazily with its first message.
  func startNewChat() {
    activeSessionID = UUID()
    currentConversationID = nil
    currentConversation = nil
    currentMessages = []
    seenMessageIDsBySession[activeSessionID] = []
    chatModel.newChat()
  }

  /// Selects an existing conversation for display and appends future model messages to it.
  /// Persisted turns are reconstructed as the concrete DTOs consumed by `AskIAgentView`.
  func selectConversation(id: UUID) async {
    if let writeTail { await writeTail.value }
    guard let conversation = await store.conversation(id: id), conversation.deletedAt == nil else {
      await refreshConversations(reloadCurrentConversation: false)
      return
    }

    activeSessionID = UUID()
    conversationIDBySession[activeSessionID] = id
    let restoredMessages = conversation.messages.map(Self.uiMessage)
    seenMessageIDsBySession[activeSessionID] = Set(restoredMessages.map(\.id))
    chatModel.restoreConversation(restoredMessages)
    currentConversationID = id
    currentConversation = conversation
    currentMessages = restoredMessages
  }

  func deleteConversation(id: UUID) async {
    if let writeTail { await writeTail.value }
    do {
      try await store.deleteConversation(id: id)
      if currentConversationID == id { startNewChat() }
      await refreshConversations(reloadCurrentConversation: false)
      scheduleCloudSync()
    } catch {
      reportPersistenceFailure(error)
    }
  }

  func clearHistory() async {
    if let writeTail { await writeTail.value }
    do {
      try await store.clear()
      startNewChat()
      await refreshConversations(reloadCurrentConversation: false)
      scheduleCloudSync()
    } catch {
      reportPersistenceFailure(error)
    }
  }

  // MARK: - Local-first recording

  private func chatHistoryDidChange(_ messages: [AskIAgentMessage]) {
    let sessionID = activeSessionID
    var seen = seenMessageIDsBySession[sessionID, default: []]
    let appended = messages.filter { seen.insert($0.id).inserted }
    seenMessageIDsBySession[sessionID] = seen
    guard !appended.isEmpty else { return }

    // Optimistic display is safe because these are immutable, already-produced messages. The
    // protected local store remains authoritative and replaces this list after the write finishes.
    var displayedIDs = Set(currentMessages.map(\.id))
    currentMessages.append(contentsOf: appended.filter { displayedIDs.insert($0.id).inserted })

    let previousWrite = writeTail
    writeTail = Task { @MainActor [self] in
      if let previousWrite { await previousWrite.value }
      await persist(appended, for: sessionID)
    }
  }

  private func persist(_ messages: [AskIAgentMessage], for sessionID: UUID) async {
    do {
      var conversationID = conversationIDBySession[sessionID]
      if conversationID == nil {
        let firstPrompt = messages.first(where: { $0.role == .user })?.content ?? "New chat"
        let created = try await store.createConversation(
          title: firstPrompt,
          at: messages.first?.createdAt ?? Date()
        )
        conversationID = created.id
        conversationIDBySession[sessionID] = created.id
      }

      guard var resolvedID = conversationID else { return }
      for message in messages {
        let storedMessage = Self.persistedMessage(message)
        if try await store.append(storedMessage, to: resolvedID) == nil {
          // A remote tombstone may have won while a local response was being generated. Preserve
          // the new turn in a fresh conversation rather than resurrecting a deleted record.
          let replacement = try await store.createConversation(
            title: message.role == .user ? message.content : "New chat",
            at: message.createdAt
          )
          resolvedID = replacement.id
          conversationIDBySession[sessionID] = resolvedID
          _ = try await store.append(storedMessage, to: resolvedID)
        }
      }

      await refreshConversations(reloadCurrentConversation: false)
      if activeSessionID == sessionID,
        let updated = await store.conversation(id: resolvedID)
      {
        currentConversationID = resolvedID
        currentConversation = updated
        currentMessages = updated.messages.map(Self.uiMessage)
      }
      scheduleCloudSync()
    } catch {
      reportPersistenceFailure(error)
    }
  }

  private func refreshConversations(reloadCurrentConversation: Bool) async {
    conversations = await store.conversations()
    guard reloadCurrentConversation, let currentConversationID,
      let refreshed = await store.conversation(id: currentConversationID),
      refreshed.deletedAt == nil
    else { return }
    currentConversation = refreshed
    currentMessages = refreshed.messages.map(Self.uiMessage)
  }

  private func scheduleCloudSync() {
    guard cloudSyncEngine != nil else { return }
    delayedSyncTask?.cancel()
    delayedSyncTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(900))
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      await self.synchronize()
    }
  }

  private func reportPersistenceFailure(_ error: Error) {
    syncStatus = AskChatHistoryStatus(
      phase: .failed,
      lastSuccessfulSyncAt: syncStatus.lastSuccessfulSyncAt,
      message: "Chat history could not be saved: \(error.localizedDescription)"
    )
  }

  // MARK: - DTO conversion

  private static func persistedMessage(_ message: AskIAgentMessage) -> AskChatMessage {
    let role: AskChatRole = message.role == .user ? .user : .assistant
    guard let answer = message.answer else {
      return AskChatMessage(
        id: message.id,
        role: role,
        text: message.content,
        createdAt: message.createdAt
      )
    }

    var seenCitationIDs = Set<String>()
    let uiCitations = answer.claims
      .flatMap(\.citations)
      .filter { seenCitationIDs.insert($0.evidenceID).inserted }
      .prefix(20)
    let citations = uiCitations.map { citation in
      AskChatCitation(
        id: citation.evidenceID,
        sourceKind: citation.source.kind.rawValue,
        entityID: citation.source.sourceID,
        revision: citation.revision,
        anchor: citation.anchor,
        retrievedAt: citation.retrievedAt
      )
    }

    var seenSnapshotIDs = Set<String>()
    let snapshots = uiCitations.compactMap { citation -> AskChatSourceSnapshot? in
      guard seenSnapshotIDs.insert(citation.evidenceID).inserted else { return nil }
      let storedCitation = AskChatCitation(
        id: citation.evidenceID,
        sourceKind: citation.source.kind.rawValue,
        entityID: citation.source.sourceID,
        revision: citation.revision,
        anchor: citation.anchor,
        retrievedAt: citation.retrievedAt
      )
      let metadata = [citation.source.subtitle, citation.source.status]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
      return AskChatSourceSnapshot(
        id: citation.evidenceID,
        sourceKind: citation.source.kind.rawValue,
        title: bounded(citation.source.title, limit: 240),
        metadata: metadata.isEmpty ? nil : bounded(metadata, limit: 400),
        excerpt: citation.source.excerpt.map { bounded($0, limit: 1_200) },
        citation: storedCitation
      )
    }.prefix(10)

    return AskChatMessage(
      id: message.id,
      role: role,
      text: bounded(message.content, limit: 12_000),
      createdAt: message.createdAt,
      contextAsOf: answer.contextAsOf,
      modelTier: answer.modelTier.rawValue,
      state: .completed,
      citations: Array(citations),
      sourceSnapshots: Array(snapshots)
    )
  }

  private static func uiMessage(_ message: AskChatMessage) -> AskIAgentMessage {
    let role: AskIAgentMessage.Role = message.role == .user ? .user : .assistant
    guard message.role == .assistant, message.state == .completed else {
      return AskIAgentMessage(
        id: message.id,
        role: role,
        content: message.text,
        createdAt: message.createdAt
      )
    }

    let snapshotsByCitationID = Dictionary(
      message.sourceSnapshots.map { ($0.citation.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var sourceByID: [String: AskIAgentSourceResult] = [:]
    var citations: [AskIAgentCitation] = []

    for (index, citation) in message.citations.enumerated() {
      let snapshot = snapshotsByCitationID[citation.id]
      let kind = AskIAgentSourceKind(rawValue: citation.sourceKind) ?? .note
      let sourceID = "\(kind.rawValue):\(citation.entityID)"
      let revisionDate = TimeInterval(citation.revision).map {
        Date(timeIntervalSince1970: $0 / 1_000)
      }
      let source = AskIAgentSourceResult(
        id: sourceID,
        sourceID: citation.entityID,
        kind: kind,
        title: snapshot?.title ?? "Source unavailable",
        subtitle: snapshot?.metadata,
        status: nil,
        excerpt: snapshot?.excerpt,
        updatedAt: revisionDate ?? citation.retrievedAt,
        startDate: nil,
        endDate: nil,
        isAllDay: false,
        isCompleted: false,
        isStarred: false,
        isHistoricalSnapshot: true
      )
      sourceByID[source.id] = source
      citations.append(
        AskIAgentCitation(
          id: citation.id,
          marker: index + 1,
          evidenceID: citation.id,
          revision: citation.revision,
          anchor: citation.anchor,
          retrievedAt: citation.retrievedAt,
          source: source
        )
      )
    }

    let contextAsOf = message.contextAsOf ?? message.createdAt
    // Payloads written before this field have no recoverable per-response route. Keep them
    // readable with the legacy Free fallback; newly written responses round-trip the exact tier.
    let modelTier = message.modelTier.flatMap(AskIAgentModelTier.init(rawValue:)) ?? .free
    let answer = AskIAgentAnswer(
      id: message.id,
      modelTier: modelTier,
      claims: [
        AskIAgentAnswerClaim(
          id: message.id,
          text: message.text,
          citations: citations
        )
      ],
      sources: Array(sourceByID.values).sorted { lhs, rhs in
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
      },
      contextAsOf: contextAsOf,
      completedAt: message.createdAt,
      elapsed: 0
    )
    return AskIAgentMessage(
      id: message.id,
      role: role,
      content: message.text,
      createdAt: message.createdAt,
      answer: answer
    )
  }

  private static func bounded(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    let end = value.index(value.startIndex, offsetBy: max(0, limit - 1))
    return String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}

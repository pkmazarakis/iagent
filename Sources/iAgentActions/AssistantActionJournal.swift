import Foundation
import iAgentActionContracts

public enum AssistantActionReceiptDisposition: String, Codable, Equatable, Sendable {
  case committedLocally
  case nativeHandoffRequired
  case handoffCompleted
  case handoffCancelled
}

public struct AssistantActionReceipt: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let intentID: String
  public let proposalDigest: String
  public let capability: AssistantActionCapability
  public let disposition: AssistantActionReceiptDisposition
  public let entityIdentifier: String?
  public let revision: String?
  public let summary: String
  public let committedAt: Date
  public let idempotentReplay: Bool

  public init(
    id: String,
    intentID: String,
    proposalDigest: String,
    capability: AssistantActionCapability,
    disposition: AssistantActionReceiptDisposition,
    entityIdentifier: String?,
    revision: String?,
    summary: String,
    committedAt: Date,
    idempotentReplay: Bool = false
  ) {
    self.id = id
    self.intentID = intentID
    self.proposalDigest = proposalDigest
    self.capability = capability
    self.disposition = disposition
    self.entityIdentifier = entityIdentifier
    self.revision = revision
    self.summary = summary
    self.committedAt = committedAt
    self.idempotentReplay = idempotentReplay
  }

  func asReplay() -> AssistantActionReceipt {
    AssistantActionReceipt(
      id: id,
      intentID: intentID,
      proposalDigest: proposalDigest,
      capability: capability,
      disposition: disposition,
      entityIdentifier: entityIdentifier,
      revision: revision,
      summary: summary,
      committedAt: committedAt,
      idempotentReplay: true
    )
  }
}

public enum AssistantActionJournalEvent: String, Codable, Equatable, Sendable {
  case proposed
  case cancelled
  case confirmed
  case executionStarted
  case committed
  case handoffPresented
  case handoffCompleted
  case handoffCancelled
  case failed
}

public struct AssistantActionJournalEntry: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let intentID: String
  public let proposalDigest: String
  public let conversationID: String
  public let turnID: String
  public let capability: AssistantActionCapability
  public let scopeID: String
  public let event: AssistantActionJournalEvent
  public let timestamp: Date
  public let receiptID: String?
  public let targetRevision: String?
  public let errorCode: String?

  public init(
    id: UUID = UUID(),
    intent: AssistantActionIntent,
    event: AssistantActionJournalEvent,
    timestamp: Date,
    receiptID: String? = nil,
    targetRevision: String? = nil,
    errorCode: String? = nil
  ) {
    self.id = id
    intentID = intent.id
    proposalDigest = intent.proposalDigest
    conversationID = intent.provenance.conversationID
    turnID = intent.provenance.turnID
    capability = intent.capability
    scopeID = intent.scope.id
    self.event = event
    self.timestamp = timestamp
    self.receiptID = receiptID
    self.targetRevision = targetRevision
    self.errorCode = errorCode
  }
}

private struct PersistedAssistantActionJournal: Codable {
  var entries: [AssistantActionJournalEntry]
  var receipts: [String: AssistantActionReceipt]
  /// Cancellation is authorization state, not merely bounded audit history. Keep exact proposal
  /// tombstones outside the trimmed entry list so an old pending file can never become actionable
  /// again after enough unrelated actions rotate through the journal.
  var cancelledProposalDigests: [String: String]?
}

public enum AssistantActionJournalError: Error, Equatable, LocalizedError, Sendable {
  case unreadable

  public var errorDescription: String? {
    switch self {
    case .unreadable:
      "The action audit journal could not be read safely. No action was changed."
    }
  }
}

public actor AssistantActionJournal {
  typealias PersistenceWriter = @Sendable (Data, URL, Data.WritingOptions) throws -> Void

  public let fileURL: URL?
  private var entries: [AssistantActionJournalEntry]
  private var receipts: [String: AssistantActionReceipt]
  private var cancelledProposalDigests: [String: String]
  private let maximumEntries: Int
  private let loadFailure: AssistantActionJournalError?
  private let persistenceWriter: PersistenceWriter

  public init(fileURL: URL? = nil, maximumEntries: Int = 500) {
    self.init(
      fileURL: fileURL,
      maximumEntries: maximumEntries,
      persistenceWriter: { data, url, options in
        try data.write(to: url, options: options)
      }
    )
  }

  init(
    fileURL: URL? = nil,
    maximumEntries: Int = 500,
    persistenceWriter: @escaping PersistenceWriter
  ) {
    let boundedMaximumEntries = max(1, maximumEntries)
    self.fileURL = fileURL
    self.maximumEntries = boundedMaximumEntries
    self.persistenceWriter = persistenceWriter
    if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
      do {
        let data = try Data(contentsOf: fileURL)
        let saved = try Self.decoder.decode(PersistedAssistantActionJournal.self, from: data)
        entries = Array(saved.entries.suffix(boundedMaximumEntries))
        receipts = saved.receipts
        cancelledProposalDigests = saved.cancelledProposalDigests
          ?? Self.recoverCancellationTombstones(from: saved.entries, receipts: saved.receipts)
        loadFailure = nil
      } catch {
        // A present-but-unreadable journal must never be treated as an empty journal. Doing so
        // would erase the only durable idempotency evidence and could repeat a committed action.
        entries = []
        receipts = [:]
        cancelledProposalDigests = [:]
        loadFailure = .unreadable
      }
    } else {
      entries = []
      receipts = [:]
      cancelledProposalDigests = [:]
      loadFailure = nil
    }
  }

  public func append(_ entry: AssistantActionJournalEntry) throws {
    try ensureHealthy()
    var updatedEntries = entries
    updatedEntries.append(entry)
    var updatedCancellations = cancelledProposalDigests
    if entry.event == .cancelled {
      updatedCancellations[entry.intentID] = entry.proposalDigest
    }
    if updatedEntries.count > maximumEntries {
      updatedEntries.removeFirst(updatedEntries.count - maximumEntries)
    }
    try persist(
      entries: updatedEntries,
      receipts: receipts,
      cancelledProposalDigests: updatedCancellations
    )
    entries = updatedEntries
    cancelledProposalDigests = updatedCancellations
  }

  public func record(
    receipt: AssistantActionReceipt,
    intent: AssistantActionIntent,
    event: AssistantActionJournalEvent
  ) throws {
    try ensureHealthy()
    var updatedReceipts = receipts
    updatedReceipts[intent.id] = receipt
    var updatedEntries = entries
    updatedEntries.append(
      AssistantActionJournalEntry(
        intent: intent,
        event: event,
        timestamp: receipt.committedAt,
        receiptID: receipt.id,
        targetRevision: receipt.revision
      )
    )
    if updatedEntries.count > maximumEntries {
      updatedEntries.removeFirst(updatedEntries.count - maximumEntries)
    }
    try persist(
      entries: updatedEntries,
      receipts: updatedReceipts,
      cancelledProposalDigests: cancelledProposalDigests
    )
    receipts = updatedReceipts
    entries = updatedEntries
  }

  public func receipt(forIntentID intentID: String) throws -> AssistantActionReceipt? {
    try ensureHealthy()
    return receipts[intentID]
  }

  public func allEntries() throws -> [AssistantActionJournalEntry] {
    try ensureHealthy()
    return entries
  }

  public func latestEntry(
    forIntentID intentID: String,
    proposalDigest: String
  ) throws -> AssistantActionJournalEntry? {
    try ensureHealthy()
    return entries.last {
      $0.intentID == intentID && $0.proposalDigest == proposalDigest
    }
  }

  public func isCancelled(
    intentID: String,
    proposalDigest: String
  ) throws -> Bool {
    try ensureHealthy()
    return cancelledProposalDigests[intentID] == proposalDigest
  }

  private func ensureHealthy() throws {
    if let loadFailure { throw loadFailure }
  }

  private func persist(
    entries: [AssistantActionJournalEntry],
    receipts: [String: AssistantActionReceipt],
    cancelledProposalDigests: [String: String]
  ) throws {
    guard let fileURL else { return }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(
      PersistedAssistantActionJournal(
        entries: entries,
        receipts: receipts,
        cancelledProposalDigests: cancelledProposalDigests
      )
    )
    #if os(iOS)
    let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    #else
    // Complete file protection is an iOS data-protection class and can fail with EPERM on macOS.
    let writeOptions: Data.WritingOptions = [.atomic]
    #endif
    try persistenceWriter(data, fileURL, writeOptions)
  }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  private static func recoverCancellationTombstones(
    from entries: [AssistantActionJournalEntry],
    receipts: [String: AssistantActionReceipt]
  ) -> [String: String] {
    var recovered: [String: String] = [:]
    for entry in entries where entry.event == .cancelled {
      recovered[entry.intentID] = entry.proposalDigest
    }
    // A terminal receipt is stronger durable truth than an old cancellation audit entry.
    for intentID in receipts.keys {
      recovered.removeValue(forKey: intentID)
    }
    return recovered
  }
}

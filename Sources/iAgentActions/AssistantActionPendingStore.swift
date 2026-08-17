import Foundation
import iAgentActionContracts

private struct PersistedAssistantActionPendingReviews: Codable {
  let schemaVersion: Int
  let intents: [String: AssistantActionIntent]
}

public enum AssistantActionPendingStoreError: Error, Equatable, LocalizedError, Sendable {
  case unreadable

  public var errorDescription: String? {
    switch self {
    case .unreadable:
      "Saved action reviews could not be read safely. The file was preserved and no action was changed."
    }
  }
}

/// File-protected local storage for uncommitted review cards.
///
/// Storing an intent never confirms or executes it. Restored intents must still pass canonical
/// validation, capability checks, expiry checks, and a new single-use broker confirmation.
public actor AssistantActionPendingStore {
  public let fileURL: URL
  private var intents: [String: AssistantActionIntent]
  private let loadFailure: AssistantActionPendingStoreError?

  public init(fileURL: URL) {
    self.fileURL = fileURL
    if FileManager.default.fileExists(atPath: fileURL.path) {
      do {
        let data = try Data(contentsOf: fileURL)
        let saved = try Self.decoder.decode(
          PersistedAssistantActionPendingReviews.self,
          from: data
        )
        guard saved.schemaVersion == 1 else {
          throw AssistantActionPendingStoreError.unreadable
        }
        // Expiry is intentionally not part of canonical validation. A durable native-handoff
        // receipt can need its payload for truthful recovery after the proposal lifetime ends.
        for intent in saved.intents.values {
          try AssistantActionProposalValidator.validateCanonicalIntent(intent)
        }
        intents = saved.intents
        loadFailure = nil
      } catch {
        // A present-but-unreadable file may be the only copy of an unresolved native handoff's
        // payload. Treating it as an empty store would allow a semantically duplicate handoff and
        // overwrite the recovery evidence on the next proposal.
        intents = [:]
        loadFailure = .unreadable
      }
    } else {
      intents = [:]
      loadFailure = nil
    }
  }

  public func save(
    _ intent: AssistantActionIntent,
    now: Date = Date()
  ) throws {
    try ensureHealthy()
    try AssistantActionProposalValidator.validateCanonicalIntent(intent, now: now)
    guard intent.expiresAt > now else {
      throw AssistantActionBrokerError.intentExpired
    }
    var updated = intents
    updated[intent.id] = intent
    try persist(updated)
    intents = updated
  }

  public func remove(intentID: String) throws {
    try ensureHealthy()
    guard intents[intentID] != nil else { return }
    var updated = intents
    updated.removeValue(forKey: intentID)
    try persist(updated)
    intents = updated
  }

  public func mostRecentValidIntent(
    now: Date = Date()
  ) throws -> AssistantActionIntent? {
    try ensureHealthy()
    let valid = intents.filter { _, intent in
      guard intent.expiresAt > now else { return false }
      return (try? AssistantActionProposalValidator.validateCanonicalIntent(
        intent,
        now: now
      )) != nil
    }
    if valid.count != intents.count {
      try persist(valid)
      intents = valid
    }
    return valid.values.max { first, second in
      first.createdAt < second.createdAt
    }
  }

  public func allValidIntents(
    now: Date = Date()
  ) throws -> [AssistantActionIntent] {
    try ensureHealthy()
    _ = try mostRecentValidIntent(now: now)
    return intents.values.sorted { first, second in
      first.createdAt > second.createdAt
    }
  }

  /// Returns the most recent canonical payload without applying proposal expiry.
  ///
  /// This is only for receipt-first recovery. The broker still expires ordinary awaiting-review
  /// proposals, while durable native/terminal receipts remain reconcilable after a long restart.
  public func mostRecentRestorableIntent() throws -> AssistantActionIntent? {
    try ensureHealthy()
    return intents.values.max { first, second in
      first.createdAt < second.createdAt
    }
  }

  private func ensureHealthy() throws {
    if let loadFailure { throw loadFailure }
  }

  private func persist(_ intents: [String: AssistantActionIntent]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let value = PersistedAssistantActionPendingReviews(
      schemaVersion: 1,
      intents: intents
    )
    #if os(iOS)
    let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    #else
    // Complete file protection is an iOS data-protection class and can fail with EPERM on macOS.
    let writeOptions: Data.WritingOptions = [.atomic]
    #endif
    try Self.encoder.encode(value).write(to: fileURL, options: writeOptions)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }()
}

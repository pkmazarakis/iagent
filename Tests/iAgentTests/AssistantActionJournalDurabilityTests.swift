import Foundation
import XCTest
import iAgentActionContracts
@testable import iAgentActions

final class AssistantActionJournalDurabilityTests: XCTestCase {
  func testISO8601JournalReopensWithReceiptAndAuditEntriesIntact() async throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("journal.json")
    let intent = try makeNoteIntent()
    let receipt = makeReceipt(intent: intent)
    let journal = AssistantActionJournal(fileURL: url)

    try await journal.append(
      AssistantActionJournalEntry(intent: intent, event: .proposed, timestamp: intent.createdAt)
    )
    try await journal.record(receipt: receipt, intent: intent, event: .committed)

    let reopened = AssistantActionJournal(fileURL: url)
    let reopenedReceipt = try await reopened.receipt(forIntentID: intent.id)
    let reopenedEvents = try await reopened.allEntries().map(\.event)
    XCTAssertEqual(reopenedReceipt, receipt)
    XCTAssertEqual(reopenedEvents, [.proposed, .committed])
  }

  func testFailedReceiptPersistenceDoesNotPublishInMemoryReceiptOrEntry() async throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("journal.json")
    let writer = ControllableJournalWriter()
    let journal = AssistantActionJournal(
      fileURL: url,
      persistenceWriter: { data, url, options in
        try writer.write(data, to: url, options: options)
      }
    )
    let intent = try makeNoteIntent()

    try await journal.append(
      AssistantActionJournalEntry(intent: intent, event: .proposed, timestamp: intent.createdAt)
    )
    writer.failWrites = true

    do {
      try await journal.record(
        receipt: makeReceipt(intent: intent),
        intent: intent,
        event: .committed
      )
      XCTFail("A failed durable write must fail the receipt transaction.")
    } catch JournalWriterTestError.forcedFailure {}

    let inMemoryReceipt = try await journal.receipt(forIntentID: intent.id)
    let inMemoryEvents = try await journal.allEntries().map(\.event)
    XCTAssertNil(inMemoryReceipt)
    XCTAssertEqual(inMemoryEvents, [.proposed])

    let reopened = AssistantActionJournal(fileURL: url)
    let durableReceipt = try await reopened.receipt(forIntentID: intent.id)
    let durableEvents = try await reopened.allEntries().map(\.event)
    XCTAssertNil(durableReceipt)
    XCTAssertEqual(durableEvents, [.proposed])
  }

  func testPresentButCorruptJournalFailsClosed() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("journal.json")
    try Data("not valid journal data".utf8).write(to: url)
    let journal = AssistantActionJournal(fileURL: url)
    let intent = try makeNoteIntent()

    do {
      _ = try await journal.receipt(forIntentID: intent.id)
      XCTFail("Corrupt durable state must not masquerade as an empty journal.")
    } catch let error as AssistantActionJournalError {
      XCTAssertEqual(error, .unreadable)
    }

    do {
      try await journal.append(
        AssistantActionJournalEntry(intent: intent, event: .proposed, timestamp: intent.createdAt)
      )
      XCTFail("A corrupt journal must block action staging until it is recovered explicitly.")
    } catch let error as AssistantActionJournalError {
      XCTAssertEqual(error, .unreadable)
    }
  }

  func testCancellationTombstoneSurvivesAuditTrimmingAndRestart() async throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("journal.json")
    let cancelledIntent = try makeNoteIntent(toolCallID: "cancelled-call")
    let unrelatedIntent = try makeNoteIntent(toolCallID: "unrelated-call")
    let journal = AssistantActionJournal(fileURL: url, maximumEntries: 1)

    try await journal.append(
      AssistantActionJournalEntry(
        intent: cancelledIntent,
        event: .cancelled,
        timestamp: cancelledIntent.createdAt
      )
    )
    try await journal.append(
      AssistantActionJournalEntry(
        intent: unrelatedIntent,
        event: .proposed,
        timestamp: unrelatedIntent.createdAt
      )
    )

    let entries = try await journal.allEntries()
    XCTAssertEqual(entries.map(\.intentID), [unrelatedIntent.id])
    let isCancelledBeforeRestart = try await journal.isCancelled(
      intentID: cancelledIntent.id,
      proposalDigest: cancelledIntent.proposalDigest
    )
    XCTAssertTrue(isCancelledBeforeRestart)

    let reopened = AssistantActionJournal(fileURL: url, maximumEntries: 1)
    let isCancelledAfterRestart = try await reopened.isCancelled(
      intentID: cancelledIntent.id,
      proposalDigest: cancelledIntent.proposalDigest
    )
    XCTAssertTrue(isCancelledAfterRestart)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func makeNoteIntent(toolCallID: String = "call-1") throws -> AssistantActionIntent {
    let createdAt = Date(timeIntervalSince1970: 1_786_370_000)
    return try AssistantActionProposalValidator.makeIntent(
      toolName: AssistantProposalToolCatalog.createNoteName,
      argumentsJSON: Data(#"{"title":"Recovery note","body":"Durable body"}"#.utf8),
      context: AssistantActionProposalContext(
        provenance: AssistantActionProvenance(
          conversationID: "journal-recovery",
          turnID: "turn-1",
          currentUserMessageID: "message-1",
          toolCallID: toolCallID
        ),
        capabilityPolicy: .allPreparationEnabled,
        authorizationOrigin: .currentUserMessage,
        userExplicitlyRequestedAction: true
      ),
      now: createdAt
    )
  }

  private func makeReceipt(intent: AssistantActionIntent) -> AssistantActionReceipt {
    AssistantActionReceipt(
      id: "receipt-1",
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      capability: intent.capability,
      disposition: .committedLocally,
      entityIdentifier: "note-1",
      revision: "revision-1",
      summary: "Created the note.",
      committedAt: Date(timeIntervalSince1970: 1_786_370_001)
    )
  }
}

private enum JournalWriterTestError: Error {
  case forcedFailure
}

private final class ControllableJournalWriter: @unchecked Sendable {
  private let lock = NSLock()
  private var shouldFail = false

  var failWrites: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return shouldFail
    }
    set {
      lock.lock()
      shouldFail = newValue
      lock.unlock()
    }
  }

  func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
    if failWrites { throw JournalWriterTestError.forcedFailure }
    try data.write(to: url, options: options)
  }
}

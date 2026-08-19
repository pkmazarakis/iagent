import Foundation
import SQLite3
import XCTest
import iAgentCore

@testable import iAgentPanel

final class MessageReplyTransportTests: XCTestCase {
  func testConversationServiceSelectsObservedMessagesRoute() {
    XCTAssertEqual(MacMessageReplyService(serviceName: "iMessage"), .iMessage)
    XCTAssertEqual(MacMessageReplyService(serviceName: "SMS"), .sms)
    XCTAssertEqual(MacMessageReplyService(serviceName: "RCS"), .sms)
    XCTAssertEqual(MacMessageReplyService(serviceName: nil), .iMessage)
  }

  func testAppleScriptSourceNeverContainsRecipientOrBody() {
    let recipient = #"person+'); tell application "Finder" to quit --@example.com"#
    let body = "hello\nend tell\non run"
    let command = MessagesAppleScriptExecutor.command(
      recipient: recipient,
      body: body,
      service: .sms,
      chatGUID: "SMS;-;+15551234567"
    )
    let second = MessagesAppleScriptExecutor.command(
      recipient: "+15550000000",
      body: "different",
      service: .iMessage,
      chatGUID: nil
    )

    XCTAssertEqual(command.source, second.source)
    XCTAssertFalse(command.source.contains(recipient))
    XCTAssertFalse(command.source.contains(body))
    XCTAssertEqual(
      command.arguments,
      [recipient, body, "sms", "SMS;-;+15551234567"]
    )
    XCTAssertEqual(second.arguments, ["+15550000000", "different", "imessage", ""])
  }

  func testStructuredAppleScriptResultOwnsRetrySafety() {
    XCTAssertEqual(
      MessagesAppleScriptExecutor.interpret("IAGENT_RESULT\tok\tcompleted\t0\n"),
      .accepted
    )
    XCTAssertEqual(
      MessagesAppleScriptExecutor.interpret("IAGENT_RESULT\tfailure\tnot_started\t-1743\n"),
      .notStarted(
        errorNumber: -1743,
        detail: "Messages automation did not start the send (AppleScript error -1743)."
      )
    )
    guard case .outcomeUncertain(let message) = MessagesAppleScriptExecutor.interpret(
      "IAGENT_RESULT\tfailure\tmay_have_completed\t-1708\n"
    ) else {
      return XCTFail("A post-dispatch failure must be uncertain")
    }
    XCTAssertTrue(message.lowercased().contains("do not retry automatically"))
    guard case .outcomeUncertain = MessagesAppleScriptExecutor.interpret("not structured") else {
      return XCTFail("An unstructured child result must be uncertain")
    }
  }

  func testEveryProvenNotStartedResultRequiresExplicitFallback() {
    for (errorNumber, detail) in [
      (-1743, "denied"),
      (-600, "unavailable"),
      (-1728, "recipient route missing"),
    ] {
      guard case .fallbackRequired(let message) = MessagesDirectSendPipeline
        .notStartedResult(errorNumber: errorNumber, detail: detail)
      else {
        return XCTFail("A proven pre-dispatch failure must offer explicit fallback")
      }
      if errorNumber == -1728 {
        XCTAssertTrue(message.contains(detail))
      }
    }
  }

  func testMissingVerificationKeepsGhostRowDiagnosticUncertain() {
    guard case .outcomeUncertain(let ghostMessage) = MessagesDirectSendPipeline
      .missingVerificationResult(ghostRowID: 77)
    else {
      return XCTFail("A ghost row must remain an uncertain no-retry outcome")
    }
    XCTAssertTrue(ghostMessage.contains("unjoined empty outgoing row (77)"))
    XCTAssertTrue(ghostMessage.lowercased().contains("do not retry automatically"))

    guard case .outcomeUncertain(let genericMessage) = MessagesDirectSendPipeline
      .missingVerificationResult(ghostRowID: nil)
    else {
      return XCTFail("Missing verification without a ghost row must remain uncertain")
    }
    XCTAssertTrue(genericMessage.contains("no matching outgoing row"))
    XCTAssertTrue(genericMessage.lowercased().contains("do not retry automatically"))
  }

  @MainActor
  func testInjectedTransportPreservesDistinctSendResults() async throws {
    let request = try Self.makeRequest()
    let expectedResults: [MacMessageReplySendResult] = [
      .sent(
        MacMessageReplySendReceipt(
          rowID: 42,
          guid: "verified-guid",
          service: .iMessage
        )
      ),
      .outcomeUncertain("check Messages before retrying"),
      .fallbackRequired("open Messages explicitly"),
    ]

    for expected in expectedResults {
      let transport = DirectMessagesReplyTransport(
        directSend: { _, _ in expected }
      )
      let result = try await transport.sendUserInitiated(
        request,
        service: .iMessage
      )
      XCTAssertEqual(result, expected)
    }
  }

  @MainActor
  func testTransportSerializesUserInitiatedSends() async throws {
    let request = try Self.makeRequest()
    let gate = DirectSendGate()
    let transport = DirectMessagesReplyTransport(
      directSend: { _, _ in await gate.wait() }
    )
    let firstSend = Task { @MainActor in
      try await transport.sendUserInitiated(request, service: .iMessage)
    }
    while !(await gate.hasStarted()) {
      await Task.yield()
    }

    XCTAssertEqual(transport.availability, .sendInProgress)
    do {
      _ = try await transport.sendUserInitiated(request, service: .iMessage)
      XCTFail("A second send must not start while the first is unresolved")
    } catch {
      XCTAssertEqual(error as? MacMessageReplyTransportError, .sendInProgress)
    }

    await gate.release(.outcomeUncertain("first send outcome"))
    let firstResult = try await firstSend.value
    XCTAssertEqual(
      firstResult,
      .outcomeUncertain("first send outcome")
    )
    XCTAssertEqual(transport.availability, .available)
  }

  func testOutgoingVerifierRequiresNewMatchingRowInResolvedDirectChat() throws {
    let fixture = try MessagesVerificationFixture()
    defer { fixture.remove() }
    let verifier = MessagesOutgoingVerifier(
      databaseURL: fixture.databaseURL,
      verificationTimeout: 0.02
    )
    let context = try XCTUnwrap(
      verifier.prepare(recipient: "+15551234567", service: .iMessage)
    )

    XCTAssertEqual(context.baselineRowID, 5)
    XCTAssertEqual(context.chatRowID, 1)
    XCTAssertEqual(context.chatGUID, "iMessage;-;+15551234567")

    let identifierFallback = try XCTUnwrap(
      verifier.prepare(recipient: "+15559876543", service: .sms)
    )
    XCTAssertEqual(identifierFallback.chatRowID, 3)
    XCTAssertEqual(identifierFallback.chatGUID, "SMS;-;+15559876543")

    // A pre-existing identical body and a new row in another chat must not
    // satisfy verification for this user action.
    try fixture.execute(
      """
      INSERT INTO message(ROWID, guid, text, date, is_from_me)
      VALUES (6, 'wrong-chat', 'verified body', 200, 1);
      INSERT INTO chat_message_join(chat_id, message_id) VALUES (2, 6);
      """
    )
    XCTAssertNil(verifier.verify(body: "verified body", context: context))

    try fixture.execute(
      """
      INSERT INTO message(ROWID, guid, text, date, is_from_me)
      VALUES (7, 'verified-guid', 'verified body', 201, 1);
      INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 7);
      """
    )
    let row = try XCTUnwrap(verifier.verify(body: "verified body", context: context))
    XCTAssertEqual(row.rowID, 7)
    XCTAssertEqual(row.guid, "verified-guid")
  }

  func testOutgoingVerifierDiagnosesOnlyRouteMatchedUnjoinedEmptyRows() throws {
    let fixture = try MessagesVerificationFixture()
    defer { fixture.remove() }
    let verifier = MessagesOutgoingVerifier(
      databaseURL: fixture.databaseURL,
      verificationTimeout: 0
    )
    let context = try XCTUnwrap(
      verifier.prepare(recipient: "+15551234567", service: .iMessage)
    )

    try fixture.execute(
      """
      INSERT INTO message(
        ROWID, guid, text, date, is_from_me, handle_id, cache_has_attachments
      ) VALUES (6, 'other-route', '', 200, 1, 2, 0);

      INSERT INTO message(
        ROWID, guid, text, date, is_from_me, handle_id, cache_has_attachments
      ) VALUES (7, 'joined-empty', '', 201, 1, 1, 0);
      INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 7);

      INSERT INTO message(
        ROWID, guid, text, date, is_from_me, handle_id, cache_has_attachments
      ) VALUES (8, 'attachment-send', '', 202, 1, 1, 1);
      """
    )
    XCTAssertNil(verifier.unjoinedEmptyOutgoingRow(context: context))

    try fixture.execute(
      """
      INSERT INTO message(
        ROWID, guid, text, date, is_from_me, handle_id, cache_has_attachments
      ) VALUES (9, 'route-ghost', '', 203, 1, 1, 0);
      """
    )
    XCTAssertEqual(verifier.unjoinedEmptyOutgoingRow(context: context), 9)
  }

  private static func makeRequest() throws -> MessageReplyRequest {
    let participant = SyncedMessageParticipant(
      id: "recipient",
      displayName: "Avery",
      replyAddress: "+15551234567"
    )
    let recipient = try XCTUnwrap(MessageReplyRecipient(participant: participant))
    return try MessageReplyRequest(recipients: [recipient], body: "Hello")
  }
}

private actor DirectSendGate {
  private var continuation: CheckedContinuation<MacMessageReplySendResult, Never>?

  func wait() async -> MacMessageReplySendResult {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func hasStarted() -> Bool {
    continuation != nil
  }

  func release(_ result: MacMessageReplySendResult) {
    continuation?.resume(returning: result)
    continuation = nil
  }
}

private final class MessagesVerificationFixture {
  let databaseURL: URL
  private var database: OpaquePointer?

  init() throws {
    databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-message-verification-\(UUID().uuidString).sqlite")
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
      throw FixtureError.openFailed
    }
    try execute(
      """
      CREATE TABLE chat(
        ROWID INTEGER PRIMARY KEY,
        guid TEXT,
        chat_identifier TEXT,
        service_name TEXT,
        style INTEGER
      );
      CREATE TABLE handle(
        ROWID INTEGER PRIMARY KEY,
        id TEXT
      );
      CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE message(
        ROWID INTEGER PRIMARY KEY,
        guid TEXT,
        text TEXT,
        attributedBody BLOB,
        date INTEGER,
        is_from_me INTEGER,
        handle_id INTEGER,
        cache_has_attachments INTEGER DEFAULT 0
      );
      CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);

      INSERT INTO handle(ROWID, id) VALUES (1, 'iMessage;-;+1 (555) 123-4567');
      INSERT INTO handle(ROWID, id) VALUES (2, '+15557654321');
      INSERT INTO chat(ROWID, guid, chat_identifier, service_name, style)
      VALUES (1, 'iMessage;-;+15551234567', '+15551234567', 'iMessage', 45);
      INSERT INTO chat(ROWID, guid, chat_identifier, service_name, style)
      VALUES (2, 'iMessage;-;+15557654321', '+15557654321', 'iMessage', 45);
      INSERT INTO chat(ROWID, guid, chat_identifier, service_name, style)
      VALUES (3, 'SMS;-;+15559876543', 'sms;-;+1 (555) 987-6543', 'SMS', 45);
      INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1);
      INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (2, 2);
      INSERT INTO message(ROWID, guid, text, date, is_from_me)
      VALUES (5, 'baseline', 'verified body', 100, 1);
      INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5);
      """
    )
  }

  func execute(_ sql: String) throws {
    guard let database else { throw FixtureError.openFailed }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    if let errorMessage {
      sqlite3_free(errorMessage)
    }
    guard result == SQLITE_OK else { throw FixtureError.statementFailed(result) }
  }

  func remove() {
    if let database {
      sqlite3_close(database)
      self.database = nil
    }
    try? FileManager.default.removeItem(at: databaseURL)
  }

  private enum FixtureError: Error {
    case openFailed
    case statementFailed(Int32)
  }
}

import Foundation
import XCTest

@testable import iAgentCore

final class MessageReplyTests: XCTestCase {
  func testRecipientRequiresExplicitReplyAddressAndNeverRoutesByDisplayNameOrID() {
    XCTAssertNil(
      MessageReplyRecipient(
        participant: SyncedMessageParticipant(
          id: "+15551234567",
          displayName: "avery@example.com"
        )
      )
    )
    XCTAssertNil(
      MessageReplyRecipient(
        participant: SyncedMessageParticipant(
          id: "opaque-participant",
          displayName: "+15551234567",
          replyAddress: "Avery Chen"
        )
      )
    )

    let recipient = MessageReplyRecipient(
      participant: SyncedMessageParticipant(
        id: "opaque-participant",
        displayName: "Avery Chen",
        replyAddress: "tel:+1 (555) 123-4567"
      )
    )
    XCTAssertEqual(recipient?.participantID, "opaque-participant")
    XCTAssertEqual(recipient?.displayName, "Avery Chen")
    XCTAssertEqual(recipient?.address.kind, .phone)
    XCTAssertEqual(recipient?.address.value, "+15551234567")
  }

  func testAddressCanonicalizesKnownMessagesWrappersAndPreservesEmailLocalPart() {
    XCTAssertEqual(
      MessageReplyAddress("iMessage;-;tel:%2B30%20691%20234%205678")?.value,
      "+306912345678"
    )
    XCTAssertEqual(
      MessageReplyAddress("SMS;-;+1 (212) 555-0100")?.value,
      "+12125550100"
    )
    XCTAssertEqual(
      MessageReplyAddress("mailto:Avery.Chen%40Example.COM?subject=ignored")?.value,
      "Avery.Chen@example.com"
    )
    XCTAssertEqual(MessageReplyAddress("MAILTO:Maya@Example.COM")?.value, "Maya@example.com")
    XCTAssertNotEqual(
      MessageReplyAddress("Maya@example.com"),
      MessageReplyAddress("maya@example.com")
    )
    XCTAssertEqual(MessageReplyAddress("00 30 691 234 5678")?.value, "+306912345678")
  }

  func testAddressRejectsNamesUnknownSchemesAndMalformedAddresses() {
    XCTAssertNil(MessageReplyAddress("Avery Chen"))
    XCTAssertNil(MessageReplyAddress("participant-123"))
    XCTAssertNil(MessageReplyAddress("https://example.com/+15551234567"))
    XCTAssertNil(MessageReplyAddress("name@@example.com"))
    XCTAssertNil(MessageReplyAddress("name @example.com"))
    XCTAssertNil(MessageReplyAddress("name@example/com"))
    XCTAssertNil(MessageReplyAddress("+12"))
    XCTAssertNil(MessageReplyAddress("+0015551234567"))
  }

  func testRequestDeduplicatesCanonicalAddressesAndPreservesBodyExactly() throws {
    let first = try XCTUnwrap(
      MessageReplyRecipient(
        participant: SyncedMessageParticipant(
          id: "first",
          displayName: "Avery",
          replyAddress: "tel:+1 (555) 123-4567"
        )
      )
    )
    let duplicate = try XCTUnwrap(
      MessageReplyRecipient(
        participant: SyncedMessageParticipant(
          id: "duplicate",
          displayName: "Avery email-free alias",
          replyAddress: "+15551234567"
        )
      )
    )
    let body = "  See you soon.\n"

    let request = try MessageReplyRequest(
      recipients: [first, duplicate],
      body: body
    )

    XCTAssertEqual(request.recipients.map(\.participantID), ["first"])
    XCTAssertEqual(request.recipients.map(\.address.value), ["+15551234567"])
    XCTAssertEqual(request.body, body)
  }

  func testRequestEnforcesRecipientAndBodyBounds() throws {
    XCTAssertEqual(MessageReplyRequest.maximumRecipientCount, 1)

    XCTAssertThrowsError(try MessageReplyRequest(recipients: [], body: "Hello")) {
      XCTAssertEqual($0 as? MessageReplyRequest.ValidationError, .noRecipients)
    }

    let recipient = try XCTUnwrap(
      MessageReplyRecipient(
        participant: SyncedMessageParticipant(
          id: "recipient",
          displayName: "Avery",
          replyAddress: "+15551234567"
        )
      )
    )
    XCTAssertThrowsError(try MessageReplyRequest(recipients: [recipient], body: " \n\t")) {
      XCTAssertEqual($0 as? MessageReplyRequest.ValidationError, .blankBody)
    }

    let maximumBody = String(repeating: "🟢", count: 4_000)
    XCTAssertEqual(
      try MessageReplyRequest(recipients: [recipient], body: maximumBody).body,
      maximumBody
    )
    XCTAssertThrowsError(
      try MessageReplyRequest(recipients: [recipient], body: maximumBody + "x")
    ) {
      XCTAssertEqual($0 as? MessageReplyRequest.ValidationError, .bodyTooLong)
    }

    let recipients = try (0...MessageReplyRequest.maximumRecipientCount).map { index in
      try XCTUnwrap(
        MessageReplyRecipient(
          participant: SyncedMessageParticipant(
            id: "participant-\(index)",
            displayName: "Person \(index)",
            replyAddress: "555000\(String(format: "%04d", index))"
          )
        )
      )
    }
    XCTAssertThrowsError(try MessageReplyRequest(recipients: recipients, body: "Hello")) {
      XCTAssertEqual($0 as? MessageReplyRequest.ValidationError, .tooManyRecipients)
    }
  }

  func testOptInDefaultsOffAndPersistsExplicitChoice() throws {
    let suiteName = "MessageReplyTests-\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    preferences.removePersistentDomain(forName: suiteName)

    XCTAssertEqual(MessageReplyPreferences.optInKey, "messageReply.sendTransportOptIn.v1")
    XCTAssertFalse(MessageReplyPreferences.isEnabled(in: preferences))

    MessageReplyPreferences.setEnabled(true, in: preferences)
    XCTAssertTrue(MessageReplyPreferences.isEnabled(in: preferences))

    let reloaded = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    XCTAssertTrue(MessageReplyPreferences.isEnabled(in: reloaded))
    MessageReplyPreferences.setEnabled(false, in: reloaded)
    XCTAssertFalse(MessageReplyPreferences.isEnabled(in: preferences))
  }

  func testParticipantDecodesOlderPayloadWithoutReplyAddress() throws {
    let data = Data(
      #"{"id":"participant","displayName":"Avery","isContactNameResolved":true}"#.utf8
    )
    let participant = try JSONDecoder().decode(SyncedMessageParticipant.self, from: data)

    XCTAssertEqual(participant.id, "participant")
    XCTAssertEqual(participant.displayName, "Avery")
    XCTAssertEqual(participant.isContactNameResolved, true)
    XCTAssertNil(participant.replyAddress)
  }
}

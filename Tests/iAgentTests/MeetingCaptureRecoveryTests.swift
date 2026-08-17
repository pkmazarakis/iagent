import Foundation
import XCTest
@testable import iAgentPanel

final class MeetingCaptureRecoveryTests: XCTestCase {
  func testOnlyListeningStateCanStopCapture() {
    XCTAssertFalse(MeetingCaptureState.idle.canStop)
    XCTAssertFalse(MeetingCaptureState.preparing.canStop)
    XCTAssertTrue(MeetingCaptureState.listening.canStop)
    XCTAssertFalse(MeetingCaptureState.stopping.canStop)
    XCTAssertFalse(MeetingCaptureState.failed("Capture failed").canStop)
  }

  func testOnlyPreparingStateIsPreparing() {
    XCTAssertFalse(MeetingCaptureState.idle.isPreparing)
    XCTAssertTrue(MeetingCaptureState.preparing.isPreparing)
    XCTAssertFalse(MeetingCaptureState.listening.isPreparing)
    XCTAssertFalse(MeetingCaptureState.stopping.isPreparing)
    XCTAssertFalse(MeetingCaptureState.failed("Capture failed").isPreparing)
  }

  func testRecorderPrivacyUsageDescriptionsArePresent() throws {
    let infoPlistURL = repositoryRootURL
      .appendingPathComponent("Sources/iAgentPanel/Info.plist")
    let data = try Data(contentsOf: infoPlistURL)
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )

    for key in ["NSScreenCaptureUsageDescription", "NSAudioCaptureUsageDescription"] {
      let usageDescription = try XCTUnwrap(
        plist[key] as? String,
        "\(key) must be declared in Sources/iAgentPanel/Info.plist"
      )
      XCTAssertFalse(
        usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "\(key) must not be empty"
      )
    }
  }

  func testRepeatedRecognizerDisconnectsBackOffThenStopRestarting() {
    var policy = MeetingRecognitionRetryPolicy()

    XCTAssertEqual(
      policy.decision(errorDomain: "kAFAssistantErrorDomain", errorCode: 1101),
      .restart(after: 0.2)
    )
    XCTAssertEqual(
      policy.decision(errorDomain: "kAFAssistantErrorDomain", errorCode: 1101),
      .restart(after: 0.4)
    )
    XCTAssertEqual(
      policy.decision(errorDomain: "kAFAssistantErrorDomain", errorCode: 1101),
      .restart(after: 0.8)
    )
    XCTAssertEqual(
      policy.decision(errorDomain: "kAFAssistantErrorDomain", errorCode: 1101),
      .fail
    )
  }

  func testRecognizerRetryBudgetResetsAfterReceivingText() {
    var policy = MeetingRecognitionRetryPolicy()
    _ = policy.decision(errorDomain: "kAFAssistantErrorDomain", errorCode: 1101)
    _ = policy.decision(errorDomain: "kAFAssistantErrorDomain", errorCode: 1101)

    policy.receivedTranscript()

    XCTAssertEqual(
      policy.decision(errorDomain: "kAFAssistantErrorDomain", errorCode: 1101),
      .restart(after: 0.2)
    )
  }

  func testNoSpeechErrorDoesNotConsumeDisconnectRetryBudget() {
    var policy = MeetingRecognitionRetryPolicy()

    XCTAssertEqual(
      policy.decision(errorDomain: "kAFAssistantErrorDomain", errorCode: 1110),
      .restart(after: 0.2)
    )
    XCTAssertEqual(policy.consecutiveFailures, 0)
  }

  func testStopSnapshotCreatesTranscriptWhenNoCallbackWasPersisted() {
    let reconciled = MeetingTranscriptReconciler.reconcile(
      existing: [],
      snapshot: MeetingTranscriptionSnapshot(
        transcript: "The final words arrived while stopping.",
        pieces: [
          MeetingTranscriptionPiece(
            source: .microphone,
            text: "The final words arrived while stopping."
          ),
        ],
        errorMessage: nil
      ),
      fallbackSource: .meeting,
      fallbackStartedAt: 12
    )

    XCTAssertEqual(reconciled.count, 1)
    XCTAssertEqual(reconciled[0].source, .microphone)
    XCTAssertEqual(reconciled[0].text, "The final words arrived while stopping.")
    XCTAssertTrue(reconciled[0].isFinal)
  }

  func testStopSnapshotFinalizesPartialSegmentWithoutDuplicatingIt() {
    let existing = MeetingTranscriptSegment(
      source: .meeting,
      startedAt: 3,
      text: "We agreed to ship",
      isFinal: false
    )

    let reconciled = MeetingTranscriptReconciler.reconcile(
      existing: [existing],
      snapshot: MeetingTranscriptionSnapshot(
        transcript: "We agreed to ship on Friday.",
        pieces: [
          MeetingTranscriptionPiece(
            source: .meeting,
            text: "We agreed to ship on Friday."
          ),
        ],
        errorMessage: nil
      ),
      fallbackSource: .meeting,
      fallbackStartedAt: 9
    )

    XCTAssertEqual(reconciled.count, 1)
    XCTAssertEqual(reconciled[0].id, existing.id)
    XCTAssertEqual(reconciled[0].text, "We agreed to ship on Friday.")
    XCTAssertTrue(reconciled[0].isFinal)
  }

  func testTranscriptOnlySnapshotUsesCurrentSourceAsFallback() {
    let reconciled = MeetingTranscriptReconciler.reconcile(
      existing: [],
      snapshot: MeetingTranscriptionSnapshot(
        transcript: "Recovered transcript",
        pieces: [],
        errorMessage: nil
      ),
      fallbackSource: .microphone,
      fallbackStartedAt: 4
    )

    XCTAssertEqual(reconciled.map(\.source), [.microphone])
    XCTAssertEqual(reconciled.map(\.text), ["Recovered transcript"])
  }

  func testRepeatedUtterancesAreKeptAsSeparateSegments() {
    let reconciled = MeetingTranscriptReconciler.reconcile(
      existing: [],
      snapshot: MeetingTranscriptionSnapshot(
        transcript: "Yes. Yes.",
        pieces: [
          MeetingTranscriptionPiece(source: .meeting, text: "Yes."),
          MeetingTranscriptionPiece(source: .meeting, text: "Yes."),
        ],
        errorMessage: nil
      ),
      fallbackSource: .meeting,
      fallbackStartedAt: 2
    )

    XCTAssertEqual(reconciled.map(\.text), ["Yes.", "Yes."])
    XCTAssertLessThan(reconciled[0].startedAt, reconciled[1].startedAt)
  }

  private var repositoryRootURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

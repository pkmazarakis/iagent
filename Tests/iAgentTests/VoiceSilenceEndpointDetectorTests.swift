import XCTest
@testable import iAgentCore

final class VoiceSilenceEndpointDetectorTests: XCTestCase {
  func testLatchedSpeechEndsAfterConservativeQuietWindow() {
    var detector = VoiceSilenceEndpointDetector(
      requiredQuietDuration: 1.8,
      quietLevelThreshold: 0.11
    )
    let phase = VoiceEntryPhase.listening(
      sessionID: 7,
      mode: .latched,
      hasRecognizedSpeech: true
    )

    detector.observeTranscript(phase: phase, transcript: "Plan my day", now: 10)
    XCTAssertNil(detector.observeLevel(phase: phase, transcript: "Plan my day", level: 0.07, now: 10.1))
    XCTAssertNil(detector.observeLevel(phase: phase, transcript: "Plan my day", level: 0.07, now: 11.89))
    XCTAssertEqual(
      detector.observeLevel(phase: phase, transcript: "Plan my day", level: 0.07, now: 11.9),
      VoiceSilenceEndpoint(sessionID: 7, transcript: "Plan my day")
    )
    XCTAssertNil(detector.observeLevel(phase: phase, transcript: "Plan my day", level: 0.07, now: 14))
  }

  func testAudibleLevelRestartsQuietWindow() {
    var detector = VoiceSilenceEndpointDetector(requiredQuietDuration: 1.8)
    let phase = VoiceEntryPhase.listening(
      sessionID: 8,
      mode: .latched,
      hasRecognizedSpeech: true
    )

    detector.observeTranscript(phase: phase, transcript: "Summarize", now: 0)
    XCTAssertNil(detector.observeLevel(phase: phase, transcript: "Summarize", level: 0.06, now: 0.1))
    XCTAssertNil(detector.observeLevel(phase: phase, transcript: "Summarize", level: 0.25, now: 1.7))
    XCTAssertNil(detector.observeLevel(phase: phase, transcript: "Summarize", level: 0.06, now: 1.8))
    XCTAssertNil(detector.observeLevel(phase: phase, transcript: "Summarize", level: 0.06, now: 3.59))
    XCTAssertNotNil(detector.observeLevel(phase: phase, transcript: "Summarize", level: 0.06, now: 3.6))
  }

  func testTranscriptRevisionRestartsQuietWindow() {
    var detector = VoiceSilenceEndpointDetector(requiredQuietDuration: 1.8)
    let phase = VoiceEntryPhase.listening(
      sessionID: 9,
      mode: .latched,
      hasRecognizedSpeech: true
    )

    XCTAssertNil(detector.observeLevel(phase: phase, transcript: "Plan", level: 0.06, now: 0))
    detector.observeTranscript(phase: phase, transcript: "Plan tomorrow", now: 1.7)
    XCTAssertNil(detector.observeLevel(phase: phase, transcript: "Plan tomorrow", level: 0.06, now: 1.8))
    XCTAssertNil(detector.observeLevel(phase: phase, transcript: "Plan tomorrow", level: 0.06, now: 3.59))
    XCTAssertNotNil(detector.observeLevel(phase: phase, transcript: "Plan tomorrow", level: 0.06, now: 3.6))
  }

  func testPressAndHoldAndEmptySpeechNeverArm() {
    var detector = VoiceSilenceEndpointDetector(requiredQuietDuration: 0)
    let heldPhase = VoiceEntryPhase.listening(
      sessionID: 10,
      mode: .pressAndHold,
      hasRecognizedSpeech: true
    )
    let emptyPhase = VoiceEntryPhase.listening(
      sessionID: 11,
      mode: .latched,
      hasRecognizedSpeech: false
    )

    XCTAssertNil(detector.observeLevel(phase: heldPhase, transcript: "Hello", level: 0, now: 0))
    XCTAssertNil(detector.observeLevel(phase: heldPhase, transcript: "Hello", level: 0, now: 1))
    XCTAssertNil(detector.observeLevel(phase: emptyPhase, transcript: "…", level: 0, now: 2))
    XCTAssertNil(detector.observeLevel(phase: emptyPhase, transcript: "…", level: 0, now: 3))
  }

  func testLeavingListeningOrChangingSessionCancelsOldCandidate() {
    var detector = VoiceSilenceEndpointDetector(requiredQuietDuration: 1)
    let first = VoiceEntryPhase.listening(
      sessionID: 12,
      mode: .latched,
      hasRecognizedSpeech: true
    )
    let second = VoiceEntryPhase.listening(
      sessionID: 13,
      mode: .latched,
      hasRecognizedSpeech: true
    )

    XCTAssertNil(detector.observeLevel(phase: first, transcript: "First", level: 0, now: 0))
    detector.observeTranscript(
      phase: .stopping(sessionID: 12, mode: .latched),
      transcript: "First",
      now: 0.9
    )
    XCTAssertNil(detector.observeLevel(phase: second, transcript: "Second", level: 0, now: 2))
    XCTAssertNil(detector.observeLevel(phase: second, transcript: "Second", level: 0, now: 2.9))
    XCTAssertNotNil(detector.observeLevel(phase: second, transcript: "Second", level: 0, now: 3))
  }
}

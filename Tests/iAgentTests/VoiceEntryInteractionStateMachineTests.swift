import XCTest
@testable import iAgentCore

final class VoiceEntryInteractionStateMachineTests: XCTestCase {
  func testOrdinaryTapOpensCreateMenuWithoutStartingVoice() {
    var machine = VoiceEntryInteractionStateMachine()

    XCTAssertEqual(machine.pressBegan(), [])
    XCTAssertEqual(machine.phase, .pressing)
    XCTAssertEqual(machine.pressEnded(), [.openCreateMenu])
    XCTAssertEqual(machine.phase, .idle)
    XCTAssertNil(machine.currentSessionID)
  }

  func testRecognizedHoldStartsVoiceAndNeverAlsoOpensCreateMenu() {
    var machine = VoiceEntryInteractionStateMachine(initialSessionID: 41)

    machine.pressBegan()
    XCTAssertEqual(
      machine.holdRecognized(),
      [
        .presentVoiceOverlay(sessionID: 41, mode: .pressAndHold),
        .requestPermission(sessionID: 41),
      ]
    )

    XCTAssertEqual(machine.pressEnded(), [])
    XCTAssertEqual(
      machine.phase,
      .requestingPermission(sessionID: 41, mode: .latched)
    )
    XCTAssertFalse(machine.pressEnded().contains(.openCreateMenu))
  }

  func testHeldReleaseAfterFirstWordRequestsStopExactlyOnce() {
    var machine = startedHeldSession(sessionID: 7)

    machine.receiveTranscript(sessionID: 7, transcript: "Hello")
    XCTAssertEqual(
      machine.phase,
      .listening(sessionID: 7, mode: .pressAndHold, hasRecognizedSpeech: true)
    )
    XCTAssertEqual(machine.pressEnded(), [.stopListening(sessionID: 7)])
    XCTAssertEqual(machine.phase, .stopping(sessionID: 7, mode: .pressAndHold))

    XCTAssertEqual(machine.pressEnded(), [])
    XCTAssertEqual(machine.stopTapped(), [])
  }

  func testReleaseBeforeFirstWordLatchesUntilStopIsTapped() {
    var machine = startedHeldSession(sessionID: 8)

    XCTAssertEqual(machine.pressEnded(), [])
    XCTAssertEqual(
      machine.phase,
      .listening(sessionID: 8, mode: .latched, hasRecognizedSpeech: false)
    )

    machine.receiveTranscript(sessionID: 8, transcript: "Now listening")
    XCTAssertEqual(machine.pressEnded(), [])
    XCTAssertEqual(
      machine.phase,
      .listening(sessionID: 8, mode: .latched, hasRecognizedSpeech: true)
    )
    XCTAssertEqual(machine.stopTapped(), [.stopListening(sessionID: 8)])
    XCTAssertEqual(machine.stopTapped(), [])
  }

  func testPunctuationDoesNotCountAsTheFirstSpokenWord() {
    var machine = startedHeldSession(sessionID: 9)

    machine.receiveTranscript(sessionID: 9, transcript: "…")
    XCTAssertEqual(machine.pressEnded(), [])
    XCTAssertEqual(
      machine.phase,
      .listening(sessionID: 9, mode: .latched, hasRecognizedSpeech: false)
    )
  }

  func testMenuVoiceChatStartsLatchedAndIgnoresFingerRelease() {
    var machine = VoiceEntryInteractionStateMachine(initialSessionID: 11)

    XCTAssertEqual(
      machine.beginVoiceChatFromMenu(),
      [
        .presentVoiceOverlay(sessionID: 11, mode: .latched),
        .requestPermission(sessionID: 11),
      ]
    )
    XCTAssertEqual(
      machine.phase,
      .requestingPermission(sessionID: 11, mode: .latched)
    )
    XCTAssertEqual(machine.pressEnded(), [])
  }

  func testPermissionAndCaptureStartFailuresEnterFailurePhase() {
    var denied = VoiceEntryInteractionStateMachine(initialSessionID: 20)
    denied.beginVoiceChatFromMenu()

    XCTAssertEqual(denied.resolvePermission(sessionID: 20, granted: false), [])
    XCTAssertEqual(
      denied.phase,
      .failed(sessionID: 20, reason: .permissionDenied)
    )

    var failedStart = VoiceEntryInteractionStateMachine(initialSessionID: 21)
    failedStart.beginVoiceChatFromMenu()
    XCTAssertEqual(
      failedStart.resolvePermission(sessionID: 21, granted: true),
      [.startListening(sessionID: 21)]
    )
    XCTAssertEqual(failedStart.listeningStartFailed(sessionID: 21), [])
    XCTAssertEqual(
      failedStart.phase,
      .failed(sessionID: 21, reason: .captureStartFailed)
    )
  }

  func testEmptyFinalResultDoesNotHandOff() {
    var machine = startedLatchedSession(sessionID: 30)
    machine.receiveTranscript(sessionID: 30, transcript: "partial words")
    machine.stopTapped()

    XCTAssertEqual(
      machine.transcriptionFinished(sessionID: 30, finalTranscript: "  \n  "),
      []
    )
    XCTAssertEqual(machine.phase, .idle)
    XCTAssertEqual(machine.transcript, "")
  }

  func testFinalTranscriptHandsOffOnceInNormalizedForm() {
    var machine = startedLatchedSession(sessionID: 31)

    XCTAssertEqual(
      machine.transcriptionFinished(
        sessionID: 31,
        finalTranscript: "  Plan tomorrow around my meetings.\n"
      ),
      [
        .handOff(
          sessionID: 31,
          transcript: "Plan tomorrow around my meetings."
        )
      ]
    )
    XCTAssertEqual(
      machine.phase,
      .handingOff(
        sessionID: 31,
        transcript: "Plan tomorrow around my meetings."
      )
    )
    XCTAssertEqual(
      machine.transcriptionFinished(sessionID: 31, finalTranscript: "duplicate"),
      []
    )
  }

  func testAbandonCancelsActiveWorkAndResetsState() {
    var machine = startedLatchedSession(sessionID: 40)
    machine.receiveTranscript(sessionID: 40, transcript: "Do not keep this")

    XCTAssertEqual(machine.abandon(), [.cancelSession(sessionID: 40)])
    XCTAssertEqual(machine.phase, .idle)
    XCTAssertEqual(machine.transcript, "")
    XCTAssertEqual(machine.abandon(), [])
  }

  func testStopBeforePermissionCompletesCancelsWithoutWaitingForFinalResult() {
    var machine = VoiceEntryInteractionStateMachine(initialSessionID: 45)
    machine.beginVoiceChatFromMenu()

    XCTAssertEqual(machine.stopTapped(), [.cancelSession(sessionID: 45)])
    XCTAssertEqual(machine.phase, .idle)
    XCTAssertEqual(machine.stopTapped(), [])
    XCTAssertEqual(machine.resolvePermission(sessionID: 45, granted: true), [])
  }

  func testStaleAndDuplicateCallbacksCannotMutateANewerSession() {
    var machine = VoiceEntryInteractionStateMachine(initialSessionID: 50)
    machine.beginVoiceChatFromMenu()
    machine.abandon()
    machine.beginVoiceChatFromMenu()

    XCTAssertEqual(machine.currentSessionID, 51)
    let phaseBeforeStaleCallbacks = machine.phase

    XCTAssertEqual(machine.resolvePermission(sessionID: 50, granted: true), [])
    XCTAssertEqual(machine.listeningStarted(sessionID: 50), [])
    XCTAssertEqual(
      machine.receiveTranscript(sessionID: 50, transcript: "stale words"),
      []
    )
    XCTAssertEqual(
      machine.transcriptionFinished(sessionID: 50, finalTranscript: "stale final"),
      []
    )
    XCTAssertEqual(machine.phase, phaseBeforeStaleCallbacks)
    XCTAssertEqual(machine.transcript, "")

    XCTAssertEqual(
      machine.resolvePermission(sessionID: 51, granted: true),
      [.startListening(sessionID: 51)]
    )
    let phaseAfterPermission = machine.phase
    XCTAssertEqual(machine.resolvePermission(sessionID: 51, granted: true), [])
    XCTAssertEqual(machine.phase, phaseAfterPermission)
  }

  private func startedHeldSession(
    sessionID: VoiceEntrySessionID
  ) -> VoiceEntryInteractionStateMachine {
    var machine = VoiceEntryInteractionStateMachine(initialSessionID: sessionID)
    machine.pressBegan()
    machine.holdRecognized()
    machine.resolvePermission(sessionID: sessionID, granted: true)
    machine.listeningStarted(sessionID: sessionID)
    return machine
  }

  private func startedLatchedSession(
    sessionID: VoiceEntrySessionID
  ) -> VoiceEntryInteractionStateMachine {
    var machine = VoiceEntryInteractionStateMachine(initialSessionID: sessionID)
    machine.beginVoiceChatFromMenu()
    machine.resolvePermission(sessionID: sessionID, granted: true)
    machine.listeningStarted(sessionID: sessionID)
    return machine
  }
}

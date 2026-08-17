import XCTest
@testable import iAgentCore

final class RecognitionTranscriptSessionTests: XCTestCase {
  func testSilenceBoundaryRotatesEachSpokenCycleExactlyOnce() {
    var detector = RecognitionCycleBoundaryDetector(
      speechLevelThreshold: 0.22,
      silenceDuration: 0.55
    )

    // An empty recognition task must not churn simply because the room is quiet.
    XCTAssertFalse(detector.observe(level: 0.06, at: 0))
    XCTAssertFalse(detector.observe(level: 0.06, at: 1))

    XCTAssertFalse(detector.observe(level: 0.48, at: 1.1))
    XCTAssertFalse(detector.observe(level: 0.08, at: 1.64))
    XCTAssertTrue(detector.observe(level: 0.08, at: 1.66))
    XCTAssertFalse(detector.observe(level: 0.08, at: 2.2))

    detector.beginCycle()
    XCTAssertFalse(detector.observe(level: 0.51, at: 3))
    XCTAssertFalse(detector.observe(level: 0.07, at: 3.54))
    XCTAssertTrue(detector.observe(level: 0.07, at: 3.56))
  }

  func testPauseRotationPublishesEveryResumedWordAndRejectsOldCallbacks() {
    var detector = RecognitionCycleBoundaryDetector(
      speechLevelThreshold: 0.22,
      silenceDuration: 0.55
    )
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)

    XCTAssertFalse(detector.observe(level: 0.58, at: 0))
    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 0,
        candidate: "First",
        isFinal: false
      ),
      "First"
    )
    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 1,
        candidate: "First sentence streams",
        isFinal: false
      ),
      "First sentence streams"
    )
    XCTAssertTrue(detector.observe(level: 0.06, at: 0.55))

    XCTAssertEqual(session.finishCycle(generation: 1), "First sentence streams")
    detector.beginCycle()
    XCTAssertEqual(session.beginCycle(generation: 2), "First sentence streams")

    // The resumed utterance must be visible before its own pause/final callback.
    XCTAssertFalse(detector.observe(level: 0.61, at: 0.8))
    XCTAssertEqual(
      session.receive(
        generation: 2,
        sequence: 0,
        candidate: "Every",
        isFinal: false
      ),
      "First sentence streams Every"
    )
    XCTAssertEqual(
      session.receive(
        generation: 2,
        sequence: 1,
        candidate: "Every resumed",
        isFinal: false
      ),
      "First sentence streams Every resumed"
    )
    XCTAssertEqual(
      session.receive(
        generation: 2,
        sequence: 2,
        candidate: "Every resumed word",
        isFinal: false
      ),
      "First sentence streams Every resumed word"
    )

    // A delayed terminal callback from the canceled first task cannot alter cycle two.
    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 99,
        candidate: "stale first-cycle replacement",
        isFinal: true
      ),
      "First sentence streams Every resumed word"
    )

    XCTAssertFalse(detector.observe(level: 0.06, at: 1.34))
    XCTAssertTrue(detector.observe(level: 0.06, at: 1.35))
    XCTAssertEqual(session.finishCycle(generation: 2), "First sentence streams Every resumed word")
    XCTAssertEqual(
      session.committedSegments.map(\.text),
      ["First sentence streams", "Every resumed word"]
    )
    XCTAssertEqual(session.stop(), "First sentence streams Every resumed word")
  }

  func testFirstCycleGrowingPartialsReplaceOneLiveHypothesis() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)

    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 0,
        candidate: "When",
        startOffset: 0,
        endOffset: 0,
        isFinal: false
      ),
      "When"
    )
    XCTAssertTrue(session.committedSegments.isEmpty)

    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 1,
        candidate: "When I",
        startOffset: 0.1,
        endOffset: 0.1,
        isFinal: false
      ),
      "When I"
    )
    XCTAssertTrue(session.committedSegments.isEmpty)

    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 2,
        candidate: "When I make",
        startOffset: 0.2,
        endOffset: 0.2,
        isFinal: false
      ),
      "When I make"
    )
    XCTAssertTrue(session.committedSegments.isEmpty)

    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 3,
        candidate: "When I make notes",
        startOffset: 0.3,
        endOffset: 0.7,
        isFinal: true
      ),
      "When I make notes"
    )
    XCTAssertNil(session.activeSegment)
    XCTAssertEqual(session.committedSegments.map(\.text), ["When I make notes"])

    let persistedTranscript = session.stop()
    XCTAssertEqual(persistedTranscript, "When I make notes")
    XCTAssertEqual(
      MeetingNoteContent(markdown: MeetingNoteContent(transcript: persistedTranscript).markdown).transcript,
      "When I make notes"
    )
  }

  func testResumedCyclePublishesEveryGrowingPartialBeforeItsNextPause() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)

    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 0,
        candidate: "First",
        startOffset: 0,
        endOffset: 0,
        isFinal: false
      ),
      "First"
    )
    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 1,
        candidate: "First sentence",
        startOffset: 0.1,
        endOffset: 0.1,
        isFinal: true
      ),
      "First sentence"
    )
    XCTAssertEqual(session.finishCycle(generation: 1), "First sentence")
    XCTAssertEqual(session.beginCycle(generation: 2), "First sentence")

    XCTAssertEqual(
      session.receive(
        generation: 2,
        sequence: 0,
        candidate: "Second",
        startOffset: 0,
        endOffset: 0,
        isFinal: false
      ),
      "First sentence Second"
    )
    XCTAssertEqual(
      session.receive(
        generation: 2,
        sequence: 1,
        candidate: "Second sentence",
        startOffset: 0.1,
        endOffset: 0.1,
        isFinal: false
      ),
      "First sentence Second sentence"
    )
    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 99,
        candidate: "stale overwrite",
        startOffset: 9,
        endOffset: 10,
        isFinal: true
      ),
      "First sentence Second sentence"
    )
    XCTAssertEqual(
      session.receive(
        generation: 2,
        sequence: 2,
        candidate: "Second sentence grows",
        startOffset: 0.2,
        endOffset: 0.2,
        isFinal: false
      ),
      "First sentence Second sentence grows"
    )
    XCTAssertEqual(
      session.receive(
        generation: 2,
        sequence: 3,
        candidate: "Second sentence grows live",
        startOffset: 0.3,
        endOffset: 0.3,
        isFinal: true
      ),
      "First sentence Second sentence grows live"
    )

    XCTAssertEqual(
      session.committedSegments.map(\.text),
      ["First sentence", "Second sentence grows live"]
    )
    XCTAssertEqual(session.stop(), "First sentence Second sentence grows live")
  }

  func testDelayedFirstCyclePartialCannotDuplicateOrRegressGrowingText() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)

    session.receive(
      generation: 1,
      sequence: 0,
      candidate: "Hello",
      startOffset: 0,
      endOffset: 0,
      isFinal: false
    )
    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 2,
        candidate: "Hello world again",
        startOffset: 0.3,
        endOffset: 0.3,
        isFinal: false
      ),
      "Hello world again"
    )
    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 1,
        candidate: "Hello world",
        startOffset: 0.1,
        endOffset: 0.2,
        isFinal: false
      ),
      "Hello world again"
    )
    XCTAssertTrue(session.committedSegments.isEmpty)

    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 3,
        candidate: "Hello world again today",
        startOffset: 0.4,
        endOffset: 0.8,
        isFinal: true
      ),
      "Hello world again today"
    )
    XCTAssertEqual(session.committedSegments.map(\.text), ["Hello world again today"])
  }

  func testEqualPartialWithForwardShiftedEnvelopeRemainsOneActiveHypothesis() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)

    session.receive(
      generation: 1,
      sequence: 0,
      candidate: "Keep this phrase once",
      startOffset: 0,
      endOffset: 0.6,
      isFinal: false
    )
    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 1,
        candidate: "Keep this phrase once",
        startOffset: 1,
        endOffset: 1.6,
        isFinal: false
      ),
      "Keep this phrase once"
    )
    XCTAssertTrue(session.committedSegments.isEmpty)

    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 2,
        candidate: "Keep this phrase once",
        startOffset: 1.8,
        endOffset: 2.4,
        isFinal: true
      ),
      "Keep this phrase once"
    )
    XCTAssertEqual(session.committedSegments.map(\.text), ["Keep this phrase once"])
  }

  func testForwardShiftedCorrectedFinalReplacesActiveAndPreservesCommittedPrefix() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)

    session.receive(
      generation: 1,
      sequence: 0,
      candidate: "Opening context stays durable",
      startOffset: 0,
      endOffset: 0.6,
      isFinal: false
    )
    session.receive(
      generation: 1,
      sequence: 1,
      candidate: "Today we reviewed the recorder plan and assigned every launch owner",
      startOffset: 1,
      endOffset: 2,
      isFinal: false
    )
    XCTAssertEqual(session.committedSegments.map(\.text), ["Opening context stays durable"])

    XCTAssertEqual(
      session.receive(
        generation: 1,
        sequence: 2,
        candidate: "Yesterday we reviewed the recorder plan and assigned every launch owner",
        startOffset: 2.5,
        endOffset: 3.7,
        isFinal: true
      ),
      "Opening context stays durable Yesterday we reviewed the recorder plan and assigned every launch owner"
    )
    XCTAssertEqual(
      session.committedSegments.map(\.text),
      [
        "Opening context stays durable",
        "Yesterday we reviewed the recorder plan and assigned every launch owner",
      ]
    )
  }

  func testUnrelatedLaterFirstCyclePhraseStillBecomesDurable() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)
    session.receive(
      generation: 1,
      sequence: 0,
      candidate: "First point",
      startOffset: 0,
      endOffset: 0.5,
      isFinal: false
    )
    session.receive(
      generation: 1,
      sequence: 1,
      candidate: "Second point",
      startOffset: 1.2,
      endOffset: 1.8,
      isFinal: true
    )

    XCTAssertEqual(session.text, "First point Second point")
    XCTAssertEqual(session.committedSegments.map(\.text), ["First point", "Second point"])
  }

  func testThreePausesMixCumulativeRevisionsAndResetResults() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)

    session.receive(
      generation: 1,
      sequence: 1,
      candidate: "First idea",
      startOffset: 0,
      endOffset: 0.8,
      isFinal: false
    )
    session.receive(
      generation: 1,
      sequence: 2,
      candidate: "First idea is approved",
      startOffset: 0,
      endOffset: 1.4,
      isFinal: false
    )
    session.receive(
      generation: 1,
      sequence: 3,
      candidate: "Second idea follows",
      startOffset: 2.2,
      endOffset: 3.1,
      isFinal: false
    )
    session.receive(
      generation: 1,
      sequence: 4,
      candidate: "Second idea follows tomorrow",
      startOffset: 2.2,
      endOffset: 3.6,
      isFinal: false
    )
    session.receive(
      generation: 1,
      sequence: 5,
      candidate: "Third idea closes",
      startOffset: 4.5,
      endOffset: 5.4,
      isFinal: true
    )

    XCTAssertEqual(
      session.text,
      "First idea is approved Second idea follows tomorrow Third idea closes"
    )
    XCTAssertEqual(
      session.committedSegments.map(\.text),
      ["First idea is approved", "Second idea follows tomorrow", "Third idea closes"]
    )
  }

  func testTimestampResetWithCommonPrefixAppendsInsteadOfReplacing() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 4)
    session.receive(
      generation: 4,
      sequence: 1,
      candidate: "We should review the launch plan",
      startOffset: 0,
      endOffset: 1.8,
      isFinal: false
    )
    session.receive(
      generation: 4,
      sequence: 2,
      candidate: "We should assign owners",
      startOffset: 3,
      endOffset: 4.2,
      isFinal: true
    )

    XCTAssertEqual(
      session.text,
      "We should review the launch plan We should assign owners"
    )
  }

  func testOverlappingTimestampResetCannotReplaceMinutesWithFinalLine() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 7)
    session.receive(
      generation: 7,
      sequence: 1,
      candidate: "Opening discussion decisions owners and all earlier meeting context",
      startOffset: 0,
      endOffset: 10,
      isFinal: false
    )
    session.receive(
      generation: 7,
      sequence: 2,
      candidate: "Only the final line",
      startOffset: 9.8,
      endOffset: 12,
      isFinal: true
    )

    XCTAssertEqual(
      session.text,
      "Opening discussion decisions owners and all earlier meeting context Only the final line"
    )
    XCTAssertEqual(session.committedSegments.count, 2)
  }

  func testOverlappingResetTrimsRepeatedBoundaryWordsExactlyOnce() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 12)
    session.receive(
      generation: 12,
      sequence: 1,
      candidate: "We agreed to ship the mobile recorder",
      startOffset: 0,
      endOffset: 5,
      isFinal: false
    )
    session.receive(
      generation: 12,
      sequence: 2,
      candidate: "mobile recorder after final validation",
      startOffset: 4.7,
      endOffset: 6.4,
      isFinal: true
    )

    XCTAssertEqual(
      session.text,
      "We agreed to ship the mobile recorder after final validation"
    )
  }

  func testShortSameRangeCorrectionRemainsARevision() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 13)
    session.receive(
      generation: 13,
      sequence: 1,
      candidate: "We ship Tuesday",
      startOffset: 0,
      endOffset: 1,
      isFinal: false
    )
    session.receive(
      generation: 13,
      sequence: 2,
      candidate: "We ship Friday",
      startOffset: 0,
      endOffset: 1.2,
      isFinal: true
    )

    XCTAssertEqual(session.text, "We ship Friday")
  }

  func testEarlyWordCorrectionDoesNotAppendASecondCumulativeTranscript() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 15)
    session.receive(
      generation: 15,
      sequence: 1,
      candidate: "Today we reviewed the recorder plan and assigned every launch owner",
      startOffset: 0,
      endOffset: 7,
      isFinal: false
    )
    session.receive(
      generation: 15,
      sequence: 2,
      candidate: "Yesterday we reviewed the recorder plan and assigned every launch owner",
      startOffset: 0,
      endOffset: 7.2,
      isFinal: true
    )

    XCTAssertEqual(
      session.text,
      "Yesterday we reviewed the recorder plan and assigned every launch owner"
    )
    XCTAssertEqual(session.committedSegments.count, 1)
  }

  func testContainedTailRegressionCannotShortenTheActiveHypothesis() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 14)
    session.receive(
      generation: 14,
      sequence: 1,
      candidate: "The opening decision remains and the final line is already present",
      startOffset: 0,
      endOffset: 8,
      isFinal: false
    )
    session.receive(
      generation: 14,
      sequence: 2,
      candidate: "the final line is already present",
      startOffset: 5.5,
      endOffset: 8,
      isFinal: true
    )

    XCTAssertEqual(
      session.text,
      "The opening decision remains and the final line is already present"
    )
  }

  func testSharedPrefixCandidateCannotRemoveAThirdOfLongHypothesis() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 16)
    session.receive(
      generation: 16,
      sequence: 1,
      candidate: "We reviewed the complete launch plan with owners dates risks and final approval",
      startOffset: 0,
      endOffset: 9,
      isFinal: false
    )
    session.receive(
      generation: 16,
      sequence: 2,
      candidate: "We reviewed the complete launch plan again",
      startOffset: 0,
      endOffset: 6,
      isFinal: true
    )

    XCTAssertEqual(
      session.text,
      "We reviewed the complete launch plan with owners dates risks and final approval"
    )
  }

  func testMissingTimestampsDetectNonCumulativeResetWithCommonPrefix() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)
    session.receive(
      generation: 1,
      sequence: 1,
      candidate: "We should review the launch plan",
      isFinal: false
    )
    session.receive(
      generation: 1,
      sequence: 2,
      candidate: "We should assign owners",
      isFinal: true
    )

    XCTAssertEqual(
      session.committedSegments.map(\.text),
      ["We should review the launch plan", "We should assign owners"]
    )
  }

  func testNewerRevisionReplacesOnlyTheActivePortion() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 2)
    session.receive(
      generation: 2,
      sequence: 1,
      candidate: "The first section is final",
      startOffset: 0,
      endOffset: 1,
      isFinal: false
    )
    session.receive(
      generation: 2,
      sequence: 2,
      candidate: "We will ship on Tuesday",
      startOffset: 2,
      endOffset: 3,
      isFinal: false
    )
    session.receive(
      generation: 2,
      sequence: 3,
      candidate: "We will ship on Friday",
      startOffset: 2,
      endOffset: 3.2,
      isFinal: true
    )

    XCTAssertEqual(
      session.text,
      "The first section is final We will ship on Friday"
    )
    XCTAssertFalse(session.text.contains("Tuesday"))
  }

  func testOutOfOrderPartialCannotRegressNewerHypothesis() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 8)
    session.receive(
      generation: 8,
      sequence: 2,
      candidate: "Keep the complete newer hypothesis",
      isFinal: false
    )
    session.receive(
      generation: 8,
      sequence: 1,
      candidate: "Keep the complete",
      isFinal: false
    )

    XCTAssertEqual(session.text, "Keep the complete newer hypothesis")
  }

  func testLateOldGenerationCallbackIsIgnoredAfterRestart() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)
    session.receive(
      generation: 1,
      sequence: 1,
      candidate: "First cycle survives",
      isFinal: true
    )
    session.beginCycle(generation: 2)
    session.receive(
      generation: 2,
      sequence: 1,
      candidate: "Second cycle survives",
      isFinal: false
    )
    session.receive(
      generation: 1,
      sequence: 99,
      candidate: "Late stale replacement",
      isFinal: true
    )

    XCTAssertEqual(session.stop(), "First cycle survives Second cycle survives")
  }

  func testPostFinalCallbackInSameGenerationIsIgnored() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 3)
    session.receive(
      generation: 3,
      sequence: 1,
      candidate: "The complete final result",
      isFinal: true
    )
    session.receive(
      generation: 3,
      sequence: 2,
      candidate: "Only a late fragment",
      isFinal: false
    )

    XCTAssertEqual(session.text, "The complete final result")
    XCTAssertEqual(session.committedSegments.count, 1)
  }

  func testDuplicateFinalCallbackCommitsExactlyOnce() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 9)
    session.receive(
      generation: 9,
      sequence: 1,
      candidate: "Commit this final once",
      isFinal: true
    )
    session.receive(
      generation: 9,
      sequence: 1,
      candidate: "Commit this final once",
      isFinal: true
    )

    XCTAssertEqual(session.committedSegments.map(\.text), ["Commit this final once"])
  }

  func testIdenticalSpeechInDistinctCyclesRemainsTwice() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)
    session.receive(
      generation: 1,
      sequence: 1,
      candidate: "Yes we agree",
      isFinal: true
    )
    session.beginCycle(generation: 2)
    session.receive(
      generation: 2,
      sequence: 1,
      candidate: "Yes we agree",
      isFinal: true
    )

    XCTAssertEqual(session.text, "Yes we agree Yes we agree")
    XCTAssertEqual(session.committedSegments.count, 2)
  }

  func testNilFinalCandidateSealsLatestPartial() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 5)
    session.receive(
      generation: 5,
      sequence: 1,
      candidate: "Final words arrived as a partial",
      isFinal: false
    )
    session.receive(
      generation: 5,
      sequence: 2,
      candidate: nil,
      isFinal: true
    )

    XCTAssertEqual(session.text, "Final words arrived as a partial")
    XCTAssertNil(session.activeSegment)
    XCTAssertEqual(session.committedSegments.count, 1)
  }

  func testErrorRestartSealsPartialBeforeNextCycle() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 10)
    session.receive(
      generation: 10,
      sequence: 1,
      candidate: "Words before disconnect",
      isFinal: false
    )
    session.finishCycle(generation: 10)
    session.beginCycle(generation: 11)
    session.receive(
      generation: 11,
      sequence: 1,
      candidate: "Words after reconnect",
      isFinal: true
    )

    XCTAssertEqual(session.text, "Words before disconnect Words after reconnect")
  }

  func testStopAfterMultipleCyclesSealsEverySegmentInOrder() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)
    session.receive(
      generation: 1,
      sequence: 1,
      candidate: "One",
      isFinal: false
    )
    session.beginCycle(generation: 2)
    session.receive(
      generation: 2,
      sequence: 1,
      candidate: "Two",
      isFinal: true
    )
    session.beginCycle(generation: 3)
    session.receive(
      generation: 3,
      sequence: 1,
      candidate: "Three",
      isFinal: false
    )

    XCTAssertEqual(session.stop(), "One Two Three")
    XCTAssertEqual(session.committedSegments.map(\.text), ["One", "Two", "Three"])
  }

  func testFinishAndStopAreIdempotent() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 6)
    session.receive(
      generation: 6,
      sequence: 1,
      candidate: "Keep exactly one copy",
      isFinal: false
    )

    XCTAssertEqual(session.finishCycle(generation: 6), "Keep exactly one copy")
    XCTAssertEqual(session.finishCycle(generation: 6), "Keep exactly one copy")
    XCTAssertEqual(session.stop(), "Keep exactly one copy")
    XCTAssertEqual(session.stop(), "Keep exactly one copy")
    XCTAssertEqual(session.committedSegments.count, 1)
  }

  func testStopRejectsDelayedCallbacksUntilReset() {
    var session = RecognitionTranscriptSession()
    session.beginCycle(generation: 1)
    session.receive(
      generation: 1,
      sequence: 1,
      candidate: "Saved before stop",
      isFinal: false
    )
    session.stop()
    session.receive(
      generation: 1,
      sequence: 2,
      candidate: "Late after stop",
      isFinal: true
    )

    XCTAssertEqual(session.text, "Saved before stop")

    session.reset()
    session.beginCycle(generation: 2)
    session.receive(
      generation: 2,
      sequence: 1,
      candidate: "Fresh recording",
      isFinal: true
    )
    XCTAssertEqual(session.text, "Fresh recording")
  }

  func testCompletePausedTranscriptFeedsMeetingNoteAndSyncedSessionUnchanged() {
    var transcriptSession = RecognitionTranscriptSession()
    transcriptSession.beginCycle(generation: 1)
    transcriptSession.receive(
      generation: 1,
      sequence: 1,
      candidate: "Opening discussion survives",
      startOffset: 0,
      endOffset: 1.2,
      isFinal: false
    )
    transcriptSession.receive(
      generation: 1,
      sequence: 2,
      candidate: "Middle discussion survives",
      startOffset: 3,
      endOffset: 4.1,
      isFinal: false
    )
    transcriptSession.finishCycle(generation: 1)
    transcriptSession.beginCycle(generation: 2)
    transcriptSession.receive(
      generation: 2,
      sequence: 1,
      candidate: "Closing discussion survives",
      startOffset: 0,
      endOffset: 1.4,
      isFinal: false
    )

    let completeTranscript = transcriptSession.stop()
    let noteMarkdown = MeetingNoteContent(transcript: completeTranscript).markdown
    let storedSegment = SyncedTranscriptSegment(
      source: .microphone,
      text: completeTranscript
    )
    let storedSession = SyncedMeetingSession(
      noteID: UUID(),
      title: "Pause regression",
      sourceDeviceID: "test-device",
      state: .completed,
      transcriptSegments: [storedSegment]
    )

    XCTAssertEqual(
      completeTranscript,
      "Opening discussion survives Middle discussion survives Closing discussion survives"
    )
    XCTAssertEqual(MeetingNoteContent(markdown: noteMarkdown).transcript, completeTranscript)
    XCTAssertEqual(storedSession.transcriptSegments?.map(\.text), [completeTranscript])
  }
}

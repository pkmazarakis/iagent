import XCTest
@testable import iAgentCore

final class SpeechAnalyzerTranscriptAccumulatorTests: XCTestCase {
  func testGrowingVolatileUpdateReplacesOverlappingHypothesis() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()

    XCTAssertEqual(
      accumulator.update(
        text: "We agreed to ship",
        startOffset: 0,
        endOffset: 1.2,
        isFinal: false
      ),
      "We agreed to ship"
    )
    XCTAssertEqual(
      accumulator.update(
        text: "We agreed to ship Friday",
        startOffset: 0,
        endOffset: 1.8,
        isFinal: false
      ),
      "We agreed to ship Friday"
    )
  }

  func testFinalUpdateReplacesOverlappingVolatileTextAndRemainsDurable() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()
    accumulator.update(
      text: "The owner will follow",
      startOffset: 0,
      endOffset: 1.5,
      isFinal: false
    )

    XCTAssertEqual(
      accumulator.update(
        text: "The owner will follow up",
        startOffset: 0,
        endOffset: 1.7,
        isFinal: true
      ),
      "The owner will follow up"
    )
    XCTAssertEqual(
      accumulator.update(
        text: "Incorrect volatile rewrite",
        startOffset: 0.2,
        endOffset: 1.6,
        isFinal: false
      ),
      "The owner will follow up"
    )
  }

  func testNonOverlappingFinalRangesAreReturnedInTimeOrder() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()

    accumulator.update(text: "Second point", startOffset: 3, endOffset: 4, isFinal: true)
    accumulator.update(text: "First point", startOffset: 0, endOffset: 1, isFinal: true)
    accumulator.update(text: "Third point", startOffset: 5, endOffset: 6, isFinal: true)

    XCTAssertEqual(accumulator.text, "First point Second point Third point")
  }

  func testEveryOrderedVolatileRevisionReplacesThePreviousHypothesis() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()

    accumulator.update(
      text: "The draft answer included an extra word",
      startOffset: 1,
      endOffset: 2.4,
      isFinal: false
    )

    XCTAssertEqual(
      accumulator.update(
        text: "The answer removed an error",
        startOffset: 1,
        endOffset: 2.2,
        isFinal: false
      ),
      "The answer removed an error"
    )
  }

  func testEmptyResultRevokesVolatileTextWithoutRemovingFinalizedText() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()
    accumulator.update(text: "Confirmed decision", startOffset: 0, endOffset: 1, isFinal: true)
    accumulator.update(text: "Tentative noise", startOffset: 2, endOffset: 3, isFinal: false)

    XCTAssertEqual(
      accumulator.update(text: "  \n", startOffset: 2, endOffset: 3, isFinal: false),
      "Confirmed decision"
    )
  }

  func testRepeatedFinalDoesNotDuplicateDurableText() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()

    accumulator.update(text: "Decision approved", startOffset: 0, endOffset: 1, isFinal: true)
    accumulator.update(text: "Decision approved", startOffset: 0, endOffset: 1, isFinal: true)

    XCTAssertEqual(accumulator.text, "Decision approved")
  }

  func testRepeatedFinalWithRefinedRangeReplacesInsteadOfDuplicating() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()

    accumulator.update(
      text: "What was the last meeting that I had",
      startOffset: 0,
      endOffset: 2.6,
      isFinal: true
    )

    XCTAssertEqual(
      accumulator.update(
        text: "What was the last meeting that I had?",
        startOffset: 0.04,
        endOffset: 2.72,
        isFinal: true
      ),
      "What was the last meeting that I had?"
    )
  }

  func testShorterVolatileRegressionDoesNotMakeVisibleTextJumpBackwards() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()

    accumulator.update(
      text: "What was the last meeting that I had",
      startOffset: 0,
      endOffset: 2.6,
      isFinal: false
    )

    XCTAssertEqual(
      accumulator.update(
        text: "What was the last meeting",
        startOffset: 0,
        endOffset: 1.6,
        isFinal: false
      ),
      "What was the last meeting that I had"
    )

    XCTAssertEqual(
      accumulator.update(
        text: "What was the last meeting that I had yesterday",
        startOffset: 0,
        endOffset: 3.1,
        isFinal: false
      ),
      "What was the last meeting that I had yesterday"
    )
  }

  func testFinalizedPortionsRemoveMultiwordBoundaryDuplication() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()

    accumulator.update(
      text: "What was the last meeting",
      startOffset: 0,
      endOffset: 1.8,
      isFinal: true
    )
    accumulator.update(
      text: "last meeting that I had",
      startOffset: 1.7,
      endOffset: 3.2,
      isFinal: true
    )

    XCTAssertEqual(accumulator.text, "What was the last meeting that I had")
  }

  func testStopReturnsFinalizedTextAndLatestVolatileHypothesis() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()
    accumulator.update(text: "Decision approved.", startOffset: 0, endOffset: 1, isFinal: true)
    accumulator.update(
      text: "Maya will send the final recap",
      startOffset: 2,
      endOffset: 3.5,
      isFinal: false
    )

    XCTAssertEqual(
      accumulator.stop(),
      "Decision approved. Maya will send the final recap"
    )
    XCTAssertEqual(
      accumulator.update(
        text: "Late callback must be ignored",
        startOffset: 2,
        endOffset: 4,
        isFinal: true
      ),
      "Decision approved. Maya will send the final recap"
    )
  }

  func testResetStartsAnIndependentTranscript() {
    var accumulator = SpeechAnalyzerTranscriptAccumulator()
    accumulator.update(text: "Old meeting", startOffset: 0, endOffset: 1, isFinal: true)
    accumulator.stop()

    accumulator.reset()

    XCTAssertEqual(
      accumulator.update(text: "New meeting", startOffset: 0, endOffset: 1, isFinal: false),
      "New meeting"
    )
  }
}

import XCTest
@testable import iAgentCore

final class ResumableTranscriptAccumulatorTests: XCTestCase {
  func testPartialHypothesesReplaceOnlyTheUncommittedSegment() {
    var transcript = ResumableTranscriptAccumulator()

    transcript.updatePartial(with: "We should ship")
    transcript.updatePartial(with: "We should ship the mobile update")

    XCTAssertEqual(transcript.text, "We should ship the mobile update")
    XCTAssertEqual(transcript.committedTranscript, "")
  }

  func testFinalResultSurvivesPauseAndResumedSpeech() {
    var transcript = ResumableTranscriptAccumulator()

    transcript.updatePartial(with: "Keep the first phrase")
    transcript.commitFinal()
    transcript.updatePartial(with: "and append this after the pause")

    XCTAssertEqual(
      transcript.commitFinal(),
      "Keep the first phrase and append this after the pause"
    )
  }

  func testResumedPartialThatResetsToNewWordsPreservesEarlierSpeech() {
    var transcript = ResumableTranscriptAccumulator()

    transcript.updatePartial(with: "The first idea stays")
    transcript.markSpeechResumed()
    transcript.updatePartial(with: "the second idea follows")

    XCTAssertEqual(
      transcript.text,
      "The first idea stays the second idea follows"
    )
  }

  func testUnchangedPostResumeCallbackDoesNotConsumeContinuationMarker() {
    var transcript = ResumableTranscriptAccumulator()

    transcript.updatePartial(with: "Keep the first phrase")
    transcript.markSpeechResumed()
    transcript.updatePartial(with: "Keep the first phrase")
    transcript.updatePartial(with: "then append the resumed phrase")

    XCTAssertEqual(
      transcript.text,
      "Keep the first phrase then append the resumed phrase"
    )
  }

  func testResumedCumulativeRevisionDoesNotDuplicateEarlierSpeech() {
    var transcript = ResumableTranscriptAccumulator()

    transcript.updatePartial(with: "We reviewed the launch plan")
    transcript.markSpeechResumed()
    transcript.updatePartial(with: "We reviewed the launch plan and assigned owners")

    XCTAssertEqual(
      transcript.commitFinal(),
      "We reviewed the launch plan and assigned owners"
    )
  }

  func testRecognitionRestartRemovesRepeatedBoundaryWords() {
    var transcript = ResumableTranscriptAccumulator()

    transcript.commitFinal("We reviewed the launch plan")
    transcript.commitFinal("launch plan and assigned owners")

    XCTAssertEqual(
      transcript.text,
      "We reviewed the launch plan and assigned owners"
    )
  }
}

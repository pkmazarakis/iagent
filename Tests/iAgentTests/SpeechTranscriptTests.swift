import XCTest
@testable import iAgentPanel

final class SpeechTranscriptTests: XCTestCase {
  func testResumedSpeechAppendsInsteadOfReplacingTheEarlierSegment() {
    var transcript = SpeechTranscriptAccumulator()
    transcript.update(with: "Keep the first phrase")
    transcript.markSpeechResumed()
    transcript.update(with: "and append this after a pause")

    XCTAssertEqual(
      transcript.text,
      "Keep the first phrase and append this after a pause"
    )
  }

  func testResumedSpeechRemovesRepeatedBoundaryWords() {
    var transcript = SpeechTranscriptAccumulator()
    transcript.update(with: "We reviewed the launch plan")
    transcript.markSpeechResumed()
    transcript.update(with: "launch plan and assigned owners")

    XCTAssertEqual(
      transcript.finalizeSegment(),
      "We reviewed the launch plan and assigned owners"
    )
  }

  func testSmartDictationCreatesStructuredMarkdown() {
    let spoken = "Project update numbered list finalize the brief next item send the recap end list new paragraph Thanks period"

    XCTAssertEqual(
      SmartDictationFormatter.format(spoken),
      "Project update\n1. finalize the brief\n2. send the recap\n\nThanks."
    )
  }

  func testSmartDictationCreatesDashItemsAndLineBreaks() {
    let spoken = "Risks dash schedule next item budget end list new line Done exclamation point"

    XCTAssertEqual(
      SmartDictationFormatter.format(spoken),
      "Risks\n- schedule\n- budget\n\nDone!"
    )
  }
}

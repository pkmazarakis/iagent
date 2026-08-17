import XCTest
@testable import iAgentCore

final class MeetingNoteContentTests: XCTestCase {
  func testMeetingSessionDecodesLegacyPayloadWithoutTranscriptMetadata() throws {
    let noteID = UUID()
    let json = """
    {
      "id": "\(UUID().uuidString)",
      "noteID": "\(noteID.uuidString)",
      "title": "Weekly sync",
      "sourceDeviceID": "mac",
      "state": "completed",
      "startedAt": 0,
      "updatedAt": 0
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    let session = try decoder.decode(SyncedMeetingSession.self, from: Data(json.utf8))

    XCTAssertNil(session.transcriptSegments)
    XCTAssertNil(session.summaryGeneratedAt)
  }

  func testStructuredTranscriptRoundTripPreservesSourceAndTiming() throws {
    let session = SyncedMeetingSession(
      noteID: UUID(),
      title: "Weekly sync",
      sourceDeviceID: "iphone",
      state: .completed,
      transcriptSegments: [
        SyncedTranscriptSegment(
          source: .microphone,
          text: "I will send the recap.",
          startOffset: 2,
          endOffset: 5
        ),
        SyncedTranscriptSegment(
          source: .meetingAudio,
          text: "Thanks, that works.",
          startOffset: 5,
          endOffset: 7
        ),
      ],
      summaryGeneratedAt: Date(timeIntervalSince1970: 20)
    )

    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(SyncedMeetingSession.self, from: data)

    XCTAssertEqual(decoded, session)
  }

  func testMeetingNoteSectionsParseLegacyAndStructuredMarkdown() {
    let legacy = MeetingNoteContent(markdown: "# Sync\n\n## Transcript\n\nRaw words")
    XCTAssertEqual(legacy.prefix, "# Sync")
    XCTAssertNil(legacy.summary)
    XCTAssertEqual(legacy.transcript, "Raw words")

    let structured = MeetingNoteContent(
      markdown: "## Summary\n\n### Highlights\n\n- Decision\n\n## Transcript\n\nRaw words"
    )
    XCTAssertEqual(structured.summary, "### Highlights\n\n- Decision")
    XCTAssertEqual(structured.transcript, "Raw words")
  }

  func testTranscriptSurvivesAddingAndReplacingSummary() {
    let source = "**Date:** Today\n\n## Transcript\n\nWe approved the launch plan."
    let parsed = MeetingNoteContent(markdown: source)

    XCTAssertEqual(parsed.prefix, "**Date:** Today")
    XCTAssertEqual(parsed.transcript, "We approved the launch plan.")

    let updated = parsed.markdown(replacingSummary: "- Launch approved")
    XCTAssertTrue(updated.contains("## Summary\n\n- Launch approved"))
    XCTAssertEqual(MeetingNoteContent(markdown: updated).transcript, parsed.transcript)

    let replaced = MeetingNoteContent(markdown: updated)
      .markdown(replacingSummary: "- Owners assigned")
    XCTAssertFalse(replaced.contains("Launch approved"))
    XCTAssertEqual(MeetingNoteContent(markdown: replaced).transcript, parsed.transcript)
  }

  func testLegacyMeetingBodyRemainsTranscriptFirst() {
    let parsed = MeetingNoteContent(markdown: "A legacy meeting transcript")
    XCTAssertEqual(parsed.transcript, "A legacy meeting transcript")
    XCTAssertNil(parsed.summary)
    XCTAssertTrue(parsed.prefix.isEmpty)
  }

  func testSummarizerSeparatesHighlightsAndExplicitNextSteps() {
    let summary = MeetingNoteSummarizer.summaryMarkdown(
      for: "We agreed to keep the first release small. Maya will send the revised milestones by Friday."
    )

    XCTAssertTrue(summary.contains("### Highlights"))
    XCTAssertTrue(summary.contains("We agreed to keep the first release small."))
    XCTAssertTrue(summary.contains("### Next steps"))
    XCTAssertTrue(summary.contains("Maya will send the revised milestones by Friday."))
  }
}

import XCTest
@testable import iAgentPanel

final class DesktopMeetingNoteTests: XCTestCase {
  func testMeetingNoteCodecPreservesTranscriptSourcesAndTiming() throws {
    let segments = [
      MeetingTranscriptSegment(
        source: .meeting,
        startedAt: 3,
        text: "The team agreed to ship Friday."
      ),
      MeetingTranscriptSegment(
        source: .microphone,
        startedAt: 18,
        text: "I will send the rollout checklist."
      ),
    ]
    let body = MeetingNoteCodec.compose(
      metadata: MeetingNoteMetadata(
        date: "Wednesday, August 5, 2026",
        time: "1:00 PM–1:30 PM",
        calendar: "Work",
        duration: "30:00"
      ),
      summaryMarkdown: "## Key points\n\n- Friday release",
      transcriptSegments: segments,
      transcriptFallback: "_No speech was recognized._"
    )

    let parsed = try XCTUnwrap(MeetingNoteCodec.parse(body))
    XCTAssertEqual(parsed.transcriptSegments.map(\.source), [.meeting, .microphone])
    XCTAssertEqual(parsed.transcriptSegments.map(\.startedAt), [3, 18])
    XCTAssertEqual(parsed.transcriptSegments.map(\.text), segments.map(\.text))
    XCTAssertEqual(parsed.metadata.duration, "30:00")
  }

  func testReplacingSummaryDoesNotRewriteTranscript() throws {
    let original = MeetingNoteCodec.compose(
      metadata: MeetingNoteMetadata(date: "Today", time: "1–2", calendar: "Work"),
      summaryMarkdown: MeetingNoteCodec.pendingSummary,
      transcriptSegments: [
        MeetingTranscriptSegment(
          source: .microphone,
          startedAt: 7,
          text: "Keep this exact transcript."
        ),
      ],
      transcriptFallback: ""
    )

    let updated = MeetingNoteCodec.replacingSummary(
      in: original,
      with: "## Decisions\n\n- Keep the transcript"
    )
    let parsed = try XCTUnwrap(MeetingNoteCodec.parse(updated))

    XCTAssertEqual(parsed.summaryMarkdown, "## Decisions\n\n- Keep the transcript")
    XCTAssertEqual(parsed.transcriptSegments.count, 1)
    XCTAssertEqual(parsed.transcriptSegments.first?.source, .microphone)
    XCTAssertEqual(parsed.transcriptSegments.first?.text, "Keep this exact transcript.")
  }

  func testLocalSummaryUsesOnlyCapturedTranscriptContent() {
    let summary = LocalMeetingSummarizer().summarize([
      MeetingTranscriptSegment(
        source: .meeting,
        startedAt: 0,
        text: "We agreed to keep the first release small."
      ),
      MeetingTranscriptSegment(
        source: .microphone,
        startedAt: 5,
        text: "I will send the revised milestones tomorrow."
      ),
    ])

    XCTAssertTrue(summary.contains("Meeting overview"))
    XCTAssertTrue(summary.contains("Decisions"))
    XCTAssertTrue(summary.contains("Next steps"))
    XCTAssertTrue(summary.contains("revised milestones"))
  }
}

import Foundation

struct MeetingTranscriptSegment: Identifiable, Sendable, Equatable {
  let id: UUID
  let source: MeetingTranscriptSource
  let startedAt: TimeInterval
  var text: String
  var isFinal: Bool

  init(
    id: UUID = UUID(),
    source: MeetingTranscriptSource,
    startedAt: TimeInterval,
    text: String,
    isFinal: Bool = true
  ) {
    self.id = id
    self.source = source
    self.startedAt = startedAt
    self.text = text
    self.isFinal = isFinal
  }
}

struct MeetingNoteMetadata: Sendable, Equatable {
  var date = ""
  var time = ""
  var calendar = ""
  var location: String?
  var duration = ""
}

struct MeetingNoteDocument: Sendable, Equatable {
  let metadata: MeetingNoteMetadata
  let summaryMarkdown: String
  let transcriptSegments: [MeetingTranscriptSegment]

  var transcriptPlainText: String {
    transcriptSegments
      .map { "\($0.source.displayName): \($0.text)" }
      .joined(separator: "\n\n")
  }
}

enum MeetingNoteCodec {
  static let marker = "<!-- iagent-meeting-note:v2 -->"
  static let pendingSummary = "_Preparing summary…_"

  static func compose(
    metadata: MeetingNoteMetadata,
    summaryMarkdown: String,
    transcriptSegments: [MeetingTranscriptSegment],
    transcriptFallback: String
  ) -> String {
    var metadataLines = [
      "**Date:** \(metadata.date)",
      "**Time:** \(metadata.time)",
      "**Calendar:** \(metadata.calendar)",
    ]
    if let location = metadata.location, !location.isEmpty {
      metadataLines.append("**Location:** \(location)")
    }
    if !metadata.duration.isEmpty {
      metadataLines.append("**Duration:** \(metadata.duration)")
    }

    let summary = summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    let transcript = transcriptMarkdown(
      segments: transcriptSegments,
      fallback: transcriptFallback
    )

    return """
    \(marker)

    \(metadataLines.joined(separator: "  \n"))

    ## Summary

    \(summary.isEmpty ? pendingSummary : summary)

    ## Transcript

    \(transcript)
    """
  }

  static func parse(_ body: String) -> MeetingNoteDocument? {
    let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
    guard let summaryHeader = normalized.range(of: "## Summary"),
          let transcriptHeader = normalized.range(
            of: "## Transcript",
            range: summaryHeader.upperBound ..< normalized.endIndex
          )
    else {
      return parseLegacyTranscript(normalized)
    }

    let metadataSource = String(normalized[..<summaryHeader.lowerBound])
    let summary = String(normalized[summaryHeader.upperBound ..< transcriptHeader.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let transcriptSource = String(normalized[transcriptHeader.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return MeetingNoteDocument(
      metadata: parseMetadata(metadataSource),
      summaryMarkdown: summary,
      transcriptSegments: parseTranscript(transcriptSource)
    )
  }

  static func isMeetingNote(_ body: String) -> Bool {
    body.contains(marker) || (
      body.contains("## Summary") && body.contains("## Transcript")
    )
  }

  static func replacingSummary(in body: String, with summaryMarkdown: String) -> String {
    guard let summaryHeader = body.range(of: "## Summary"),
          let transcriptHeader = body.range(
            of: "## Transcript",
            range: summaryHeader.upperBound ..< body.endIndex
          )
    else { return body }

    let prefix = String(body[..<summaryHeader.upperBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    let suffix = String(body[transcriptHeader.lowerBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(prefix)\n\n\(summary)\n\n\(suffix)"
  }

  private static func transcriptMarkdown(
    segments: [MeetingTranscriptSegment],
    fallback: String
  ) -> String {
    let meaningfulSegments = segments.filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !meaningfulSegments.isEmpty else { return fallback }

    return meaningfulSegments
      .sorted {
        if $0.startedAt == $1.startedAt {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.startedAt < $1.startedAt
      }
      .map { segment in
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "### \(segment.source.displayName) · \(elapsedText(segment.startedAt))\n\n\(text)"
      }
      .joined(separator: "\n\n")
  }

  private static func parseLegacyTranscript(_ body: String) -> MeetingNoteDocument? {
    guard let transcriptHeader = body.range(of: "## Transcript") else { return nil }
    let metadataSource = String(body[..<transcriptHeader.lowerBound])
    let transcript = String(body[transcriptHeader.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let segments: [MeetingTranscriptSegment]
    if transcript.isEmpty || transcript.hasPrefix("_") {
      segments = []
    } else {
      segments = [
        MeetingTranscriptSegment(
          source: .meeting,
          startedAt: 0,
          text: transcript
        ),
      ]
    }
    return MeetingNoteDocument(
      metadata: parseMetadata(metadataSource),
      summaryMarkdown: "",
      transcriptSegments: segments
    )
  }

  private static func parseMetadata(_ source: String) -> MeetingNoteMetadata {
    var metadata = MeetingNoteMetadata()
    source.components(separatedBy: .newlines).forEach { line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if let value = metadataValue(in: trimmed, key: "Date") {
        metadata.date = value
      } else if let value = metadataValue(in: trimmed, key: "Time") {
        metadata.time = value
      } else if let value = metadataValue(in: trimmed, key: "Calendar") {
        metadata.calendar = value
      } else if let value = metadataValue(in: trimmed, key: "Location") {
        metadata.location = value
      } else if let value = metadataValue(in: trimmed, key: "Duration") {
        metadata.duration = value
      }
    }
    return metadata
  }

  private static func metadataValue(in line: String, key: String) -> String? {
    let prefix = "**\(key):**"
    guard line.hasPrefix(prefix) else { return nil }
    return String(line.dropFirst(prefix.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "  ", with: "")
  }

  private static func parseTranscript(_ source: String) -> [MeetingTranscriptSegment] {
    var segments: [MeetingTranscriptSegment] = []
    var activeSource: MeetingTranscriptSource?
    var activeStartedAt: TimeInterval = 0
    var activeLines: [String] = []

    func finishActiveSegment() {
      guard let activeSource else { return }
      let text = activeLines.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        segments.append(
          MeetingTranscriptSegment(
            source: activeSource,
            startedAt: activeStartedAt,
            text: text
          )
        )
      }
      activeLines = []
    }

    for line in source.components(separatedBy: .newlines) {
      if let heading = transcriptHeading(line) {
        finishActiveSegment()
        activeSource = heading.source
        activeStartedAt = heading.startedAt
        continue
      }
      activeLines.append(line)
    }
    finishActiveSegment()

    if segments.isEmpty,
       !source.isEmpty,
       !source.hasPrefix("_")
    {
      return [
        MeetingTranscriptSegment(source: .meeting, startedAt: 0, text: source),
      ]
    }
    return segments
  }

  private static func transcriptHeading(
    _ line: String
  ) -> (source: MeetingTranscriptSource, startedAt: TimeInterval)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("### ") else { return nil }
    let components = trimmed.dropFirst(4).components(separatedBy: " · ")
    guard let label = components.first else { return nil }
    let source: MeetingTranscriptSource = label.localizedCaseInsensitiveContains("you")
      || label.localizedCaseInsensitiveContains("microphone")
      ? .microphone
      : .meeting
    let startedAt = components.count > 1 ? elapsedInterval(components[1]) : 0
    return (source, startedAt)
  }

  private static func elapsedText(_ interval: TimeInterval) -> String {
    let totalSeconds = max(0, Int(interval.rounded(.down)))
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
  }

  private static func elapsedInterval(_ value: String) -> TimeInterval {
    let parts = value.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return 0 }
    return TimeInterval(parts[0] * 60 + parts[1])
  }
}

protocol MeetingSummarizing: Sendable {
  func summarize(_ segments: [MeetingTranscriptSegment]) -> String
}

struct LocalMeetingSummarizer: MeetingSummarizing {
  func summarize(_ segments: [MeetingTranscriptSegment]) -> String {
    let transcript = segments
      .sorted { $0.startedAt < $1.startedAt }
      .map(\.text)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else {
      return "_No speech was recognized, so there is nothing to summarize._"
    }

    let sentences = uniqueSentences(in: transcript)
    guard !sentences.isEmpty else { return transcript }

    let overview = sentences.prefix(2).joined(separator: " ")
    var sections = ["## Meeting overview\n\n\(overview)"]

    let keyPoints = Array(sentences.prefix(5))
    if !keyPoints.isEmpty {
      sections.append(
        "## Key points\n\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n")
      )
    }

    let decisions = sentences.filter { sentence in
      containsAny(
        sentence,
        terms: ["agreed", "decided", "approved", "confirmed", "selected", "chose"]
      )
    }
    if !decisions.isEmpty {
      sections.append(
        "## Decisions\n\n" + decisions.prefix(4).map { "- \($0)" }.joined(separator: "\n")
      )
    }

    let nextSteps = sentences.filter { sentence in
      containsAny(
        sentence,
        terms: ["i will", "we will", "will send", "will share", "will publish", "next step", "follow up", "action item", "by "]
      )
    }
    if !nextSteps.isEmpty {
      sections.append(
        "## Next steps\n\n" + nextSteps.prefix(5).map { "- \($0)" }.joined(separator: "\n")
      )
    }

    return sections.joined(separator: "\n\n")
  }

  private func uniqueSentences(in text: String) -> [String] {
    var sentences: [String] = []
    text.enumerateSubstrings(
      in: text.startIndex ..< text.endIndex,
      options: [.bySentences, .substringNotRequired]
    ) { _, range, _, _ in
      let sentence = String(text[range])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard sentence.count >= 4 else { return }
      if !sentences.contains(where: {
        $0.compare(sentence, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
      }) {
        sentences.append(sentence)
      }
    }
    if sentences.isEmpty {
      let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return fallback.isEmpty ? [] : [fallback]
    }
    return sentences
  }

  private func containsAny(_ sentence: String, terms: [String]) -> Bool {
    let normalized = sentence.lowercased()
    return terms.contains(where: normalized.contains)
  }
}

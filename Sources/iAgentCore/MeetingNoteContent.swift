import Foundation
import NaturalLanguage

public struct MeetingNoteContent: Sendable, Equatable {
  /// Markdown before the structured meeting sections (for legacy date/metadata blocks).
  public var prefix: String
  public var summary: String?
  public var transcript: String

  public init(prefix: String = "", summary: String? = nil, transcript: String) {
    self.prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    self.transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public init(markdown: String) {
    let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    let summaryIndex = lines.firstIndex { Self.isHeading($0, named: "summary") }
    let transcriptIndex = lines.firstIndex { Self.isHeading($0, named: "transcript") }

    let firstStructuredIndex = [summaryIndex, transcriptIndex]
      .compactMap { $0 }
      .min()
    if let firstStructuredIndex {
      prefix = lines[..<firstStructuredIndex]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      prefix = ""
    }

    if let transcriptIndex {
      transcript = lines[(transcriptIndex + 1)...]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } else if summaryIndex != nil {
      transcript = ""
    } else {
      transcript = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if let summaryIndex {
      let end = transcriptIndex.flatMap { $0 > summaryIndex ? $0 : nil } ?? lines.count
      summary = lines[(summaryIndex + 1) ..< end]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty
    } else {
      summary = nil
    }
  }

  public var markdown: String {
    markdown(replacingSummary: summary)
  }

  /// Rebuilds only the generated section while keeping legacy metadata and the transcript intact.
  public func markdown(replacingSummary newSummary: String?) -> String {
    let transcriptText = transcript.nonEmpty ?? "_No speech was recognized._"
    var sections: [String] = []
    if let prefix = prefix.nonEmpty { sections.append(prefix) }
    if let summary = newSummary?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nonEmpty {
      sections.append("## Summary\n\n\(summary)")
    }
    sections.append("## Transcript\n\n\(transcriptText)")
    return sections.joined(separator: "\n\n")
  }

  private static func isHeading(_ line: String, named name: String) -> Bool {
    line
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() == "## \(name)"
  }
}

public enum MeetingNoteSummarizer {
  public static func summaryMarkdown(for transcript: String) -> String {
    let sentences = transcriptSentences(from: transcript)
    guard !sentences.isEmpty else {
      return "_No summary is available because no speech was recognized._"
    }

    let actionSentences = sentences.filter(looksLikeAction)
    let highlightCandidates = sentences.filter { !looksLikeAction($0) }
    let highlights = rankedHighlights(
      from: highlightCandidates.isEmpty ? sentences : highlightCandidates,
      transcript: transcript,
      maximumCount: 3
    )

    var sections = ["### Highlights", bullets(highlights)]
    if !actionSentences.isEmpty {
      sections.append("### Next steps")
      sections.append(bullets(Array(actionSentences.prefix(4))))
    }
    return sections.joined(separator: "\n\n")
  }

  private static func transcriptSentences(from transcript: String) -> [String] {
    let cleaned = transcript
      .replacingOccurrences(of: "_No speech was recognized._", with: "")
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return [] }
    var values: [String] = []

    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = cleaned
    tokenizer.enumerateTokens(in: cleaned.startIndex ..< cleaned.endIndex) { range, _ in
      let value = normalizedSentence(String(cleaned[range]))
      if let value = value.nonEmpty, !values.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
        values.append(value)
      }
      return true
    }

    return values.isEmpty ? [normalizedSentence(cleaned)] : values
  }

  /// Uses Apple's compact, on-device sentence embedding to find the statements
  /// closest to the semantic center of the meeting while avoiding duplicates.
  /// When an embedding is unavailable for the detected language, lexical
  /// centrality provides a deterministic offline fallback.
  private static func rankedHighlights(
    from candidates: [String],
    transcript: String,
    maximumCount: Int
  ) -> [String] {
    guard candidates.count > maximumCount else { return candidates }

    let bounded = Array(candidates.prefix(80))
    let language = NLLanguageRecognizer.dominantLanguage(for: transcript) ?? .english
    let embedding = NLEmbedding.sentenceEmbedding(for: language)
    let vectors = bounded.map { embedding?.vector(for: $0) }
    let lexicalTerms = bounded.map(termSet)

    var centrality = Array(repeating: 0.0, count: bounded.count)
    for index in bounded.indices {
      var similarities: [Double] = []
      for other in bounded.indices where other != index {
        if let left = vectors[index], let right = vectors[other], left.count == right.count {
          similarities.append(max(0, cosineSimilarity(left, right)))
        } else {
          similarities.append(jaccardSimilarity(lexicalTerms[index], lexicalTerms[other]))
        }
      }
      let average = similarities.isEmpty ? 0 : similarities.reduce(0, +) / Double(similarities.count)
      let positionBonus = 0.08 * (1 - Double(index) / Double(max(1, bounded.count - 1)))
      let decisionBonus = containsDecisionSignal(bounded[index]) ? 0.18 : 0
      centrality[index] = average + positionBonus + decisionBonus
    }

    var selected: [Int] = []
    while selected.count < min(maximumCount, bounded.count) {
      let remaining = bounded.indices.filter { !selected.contains($0) }
      guard let next = remaining.max(by: { lhs, rhs in
        diversifiedScore(
          for: lhs,
          selected: selected,
          centrality: centrality,
          vectors: vectors,
          lexicalTerms: lexicalTerms
        ) < diversifiedScore(
          for: rhs,
          selected: selected,
          centrality: centrality,
          vectors: vectors,
          lexicalTerms: lexicalTerms
        )
      }) else { break }
      selected.append(next)
    }

    return selected.sorted().map { bounded[$0] }
  }

  private static func diversifiedScore(
    for index: Int,
    selected: [Int],
    centrality: [Double],
    vectors: [[Double]?],
    lexicalTerms: [Set<String>]
  ) -> Double {
    let maximumSimilarity = selected.map { other -> Double in
      if let left = vectors[index], let right = vectors[other], left.count == right.count {
        return max(0, cosineSimilarity(left, right))
      }
      return jaccardSimilarity(lexicalTerms[index], lexicalTerms[other])
    }.max() ?? 0
    return centrality[index] - maximumSimilarity * 0.34
  }

  private static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
    var dot = 0.0
    var leftMagnitude = 0.0
    var rightMagnitude = 0.0
    for index in lhs.indices {
      dot += lhs[index] * rhs[index]
      leftMagnitude += lhs[index] * lhs[index]
      rightMagnitude += rhs[index] * rhs[index]
    }
    guard leftMagnitude > 0, rightMagnitude > 0 else { return 0 }
    return dot / (sqrt(leftMagnitude) * sqrt(rightMagnitude))
  }

  private static func termSet(_ sentence: String) -> Set<String> {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = sentence
    var terms = Set<String>()
    tokenizer.enumerateTokens(in: sentence.startIndex ..< sentence.endIndex) { range, _ in
      let term = sentence[range].lowercased()
      if term.count > 2, !stopWords.contains(term) { terms.insert(term) }
      return true
    }
    return terms
  }

  private static func jaccardSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
    guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
    return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
  }

  private static func containsDecisionSignal(_ sentence: String) -> Bool {
    let value = sentence.lowercased()
    return ["agreed", "decided", "confirmed", "priority", "focus", "goal", "because"]
      .contains { value.contains($0) }
  }

  private static let stopWords: Set<String> = [
    "the", "and", "that", "this", "with", "from", "for", "was", "were", "are", "you",
    "your", "our", "but", "not", "have", "has", "had", "will", "would", "about", "into",
    "they", "them", "their", "then", "than", "can", "could", "should", "also", "just",
  ]

  private static func normalizedSentence(_ value: String) -> String {
    var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while cleaned.hasPrefix("-") || cleaned.hasPrefix("•") || cleaned.hasPrefix("*") {
      cleaned.removeFirst()
      cleaned = cleaned.trimmingCharacters(in: .whitespaces)
    }
    guard cleaned.count > 220 else { return cleaned }
    let cutoff = cleaned.index(cleaned.startIndex, offsetBy: 216)
    let prefix = cleaned[..<cutoff]
    let boundary = prefix.lastIndex(of: " ") ?? cutoff
    return String(cleaned[..<boundary]).trimmingCharacters(in: .whitespaces) + "…"
  }

  private static func looksLikeAction(_ sentence: String) -> Bool {
    let value = sentence.lowercased()
    let signals = [
      " will ", " need to ", " needs to ", " follow up", " next step", " action item",
      " send ", " share ", " draft ", " schedule ", " confirm ", " review ", " by friday",
      " by monday", " owner:", "assigned to",
    ]
    let padded = " \(value) "
    return signals.contains { padded.contains($0) }
  }

  private static func bullets(_ values: [String]) -> String {
    values.map { "- \($0)" }.joined(separator: "\n")
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

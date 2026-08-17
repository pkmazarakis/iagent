import Foundation

/// Reduces SpeechAnalyzer results into a durable transcript while keeping the latest
/// volatile hypothesis visible until it is finalized or capture stops.
public struct SpeechAnalyzerTranscriptAccumulator: Sendable, Equatable {
  private struct Portion: Sendable, Equatable {
    let text: String
    let startOffset: TimeInterval
    let endOffset: TimeInterval
    let isFinal: Bool
  }

  private var finalizedPortions: [Portion] = []
  private var volatilePortion: Portion?
  private var isStopped = false

  public init() {}

  /// Finalized portions and the current volatile phrase in time order.
  public var text: String {
    Self.joined(finalizedPortions + [volatilePortion].compactMap { $0 })
  }

  /// Applies one analyzer update. SpeechTranscriber publishes ordered revisions for one
  /// volatile phrase at a time; an empty volatile result revokes that phrase.
  @discardableResult
  public mutating func update(
    text rawText: String,
    startOffset: TimeInterval,
    endOffset: TimeInterval,
    isFinal: Bool
  ) -> String {
    guard !isStopped,
          startOffset.isFinite,
          endOffset.isFinite,
          startOffset >= 0,
          endOffset >= startOffset
    else { return text }

    let normalizedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedText.isEmpty else {
      volatilePortion = nil
      return text
    }

    let portion = Portion(
      text: normalizedText,
      startOffset: startOffset,
      endOffset: endOffset,
      isFinal: isFinal
    )

    if isFinal {
      applyFinal(portion)
    } else {
      applyVolatile(portion)
    }
    return text
  }

  /// Freezes the transcript and preserves the latest volatile hypothesis when no final
  /// analyzer result arrives before a stop timeout.
  @discardableResult
  public mutating func stop() -> String {
    isStopped = true
    return text
  }

  public mutating func reset() {
    finalizedPortions = []
    volatilePortion = nil
    isStopped = false
  }

  private mutating func applyFinal(_ portion: Portion) {
    // Apple defines the final result as the replacement for the current volatile
    // phrase. Clear it even if endpoint refinement slightly changed the time range.
    volatilePortion = nil

    // A transcriber can repeat a terminal result with a slightly refined range. Treat
    // that as one acoustic portion rather than appending a second copy. The finalized
    // replacement remains authoritative, so punctuation or an early-word correction
    // can still improve the stored text.
    if let repeatedIndex = finalizedPortions.firstIndex(where: {
      Self.representsSameAcousticPortion($0, portion)
    }) {
      finalizedPortions[repeatedIndex] = portion
      finalizedPortions.sort(by: Self.isEarlier)
      return
    }

    finalizedPortions.append(portion)
    finalizedPortions.sort(by: Self.isEarlier)
  }

  private mutating func applyVolatile(_ portion: Portion) {
    // A volatile callback cannot displace a finalized range.
    guard !finalizedPortions.contains(where: { Self.overlaps($0, portion) }) else { return }

    // Volatile hypotheses are replaceable, but an occasional shorter callback can
    // arrive after a more complete one. Publishing that regression makes live text
    // jump backwards and can replay words when the next expansion arrives. Keep the
    // longer hypothesis; a final result remains authoritative and may still correct it.
    if let volatilePortion,
       Self.isTextRegression(portion.text, from: volatilePortion.text)
    {
      return
    }
    volatilePortion = portion
  }

  private static func representsSameAcousticPortion(
    _ lhs: Portion,
    _ rhs: Portion
  ) -> Bool {
    let lhsWords = normalizedWords(lhs.text)
    let rhsWords = normalizedWords(rhs.text)
    guard !lhsWords.isEmpty, !rhsWords.isEmpty else { return false }

    let exactRange = lhs.startOffset == rhs.startOffset && lhs.endOffset == rhs.endOffset
    let closeRange = abs(lhs.startOffset - rhs.startOffset) <= 0.25
      && abs(lhs.endOffset - rhs.endOffset) <= 0.5
    let sameText = lhsWords == rhsWords
    let textRevision = isTextRevision(lhsWords, rhsWords)

    if exactRange { return true }
    if closeRange, sameText || textRevision { return true }

    let intersection = max(
      0,
      min(lhs.endOffset, rhs.endOffset) - max(lhs.startOffset, rhs.startOffset)
    )
    let shorterDuration = min(
      max(0, lhs.endOffset - lhs.startOffset),
      max(0, rhs.endOffset - rhs.startOffset)
    )
    let substantiallyOverlaps = shorterDuration > 0
      && intersection / shorterDuration >= 0.8
    return substantiallyOverlaps && (sameText || textRevision)
  }

  private static func isTextRegression(_ candidate: String, from previous: String) -> Bool {
    let candidateWords = normalizedWords(candidate)
    let previousWords = normalizedWords(previous)
    guard candidateWords.count < previousWords.count else { return false }
    return previousWords.starts(with: candidateWords)
      || containsContiguous(previousWords, candidateWords)
  }

  private static func isTextRevision(_ lhs: [String], _ rhs: [String]) -> Bool {
    if lhs == rhs || lhs.starts(with: rhs) || rhs.starts(with: lhs) { return true }
    let shorterCount = min(lhs.count, rhs.count)
    guard shorterCount > 0 else { return false }
    let sharedPrefix = zip(lhs, rhs).prefix { $0 == $1 }.count
    if sharedPrefix >= 2,
       Double(sharedPrefix) / Double(shorterCount) >= 0.75
    {
      return true
    }

    let lhsTerms = Set(lhs)
    let rhsTerms = Set(rhs)
    let union = lhsTerms.union(rhsTerms)
    guard !union.isEmpty else { return false }
    let overlap = Double(lhsTerms.intersection(rhsTerms).count) / Double(union.count)
    let lengthRatio = Double(shorterCount) / Double(max(lhs.count, rhs.count))
    return lengthRatio >= 0.85 && overlap >= 0.65
  }

  private static func containsContiguous(_ words: [String], _ candidate: [String]) -> Bool {
    guard !candidate.isEmpty, candidate.count <= words.count else { return false }
    for start in 0 ... (words.count - candidate.count) {
      if Array(words[start ..< start + candidate.count]) == candidate { return true }
    }
    return false
  }

  private static func overlaps(_ lhs: Portion, _ rhs: Portion) -> Bool {
    if lhs.startOffset == rhs.startOffset, lhs.endOffset == rhs.endOffset {
      return true
    }
    return lhs.startOffset < rhs.endOffset && rhs.startOffset < lhs.endOffset
  }

  private static func isEarlier(_ lhs: Portion, _ rhs: Portion) -> Bool {
    if lhs.startOffset != rhs.startOffset { return lhs.startOffset < rhs.startOffset }
    if lhs.endOffset != rhs.endOffset { return lhs.endOffset < rhs.endOffset }
    if lhs.isFinal != rhs.isFinal { return lhs.isFinal }
    return lhs.text < rhs.text
  }

  private static func joined(_ portions: [Portion]) -> String {
    portions
      .sorted(by: isEarlier)
      .map(\.text)
      .reduce(into: "") { result, next in
        result = appendingWithoutBoundaryDuplication(next, to: result)
      }
  }

  private static func appendingWithoutBoundaryDuplication(
    _ trailing: String,
    to leading: String
  ) -> String {
    let leading = leading.trimmingCharacters(in: .whitespacesAndNewlines)
    let trailing = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !leading.isEmpty else { return trailing }
    guard !trailing.isEmpty else { return leading }

    let leadingTokens = whitespaceTokens(leading)
    let trailingTokens = whitespaceTokens(trailing)
    let maximumOverlap = min(leadingTokens.count, trailingTokens.count)
    if maximumOverlap >= 2 {
      for count in stride(from: maximumOverlap, through: 2, by: -1) {
        let leadingBoundary = leadingTokens.suffix(count).map(normalizedToken)
        let trailingBoundary = trailingTokens.prefix(count).map(normalizedToken)
        if leadingBoundary == trailingBoundary {
          let remainder = trailingTokens.dropFirst(count).joined(separator: " ")
          return remainder.isEmpty ? leading : "\(leading) \(remainder)"
        }
      }
    }
    return "\(leading) \(trailing)"
  }

  private static func whitespaceTokens(_ value: String) -> [String] {
    value.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  private static func normalizedToken(_ value: String) -> String {
    String(value.lowercased().filter { $0.isLetter || $0.isNumber })
  }

  private static func normalizedWords(_ value: String) -> [String] {
    value
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }
}

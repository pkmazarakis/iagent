import Foundation

/// One durable portion of a speech-recognition session.
///
/// A segment is committed only when its temporal portion ends, its recognition cycle
/// finishes, or capture stops. Text equality is deliberately not used as identity:
/// saying the same words twice must produce two segments.
public struct RecognitionTranscriptSegment: Sendable, Equatable {
  public let generation: Int
  public let sequence: Int
  public let text: String
  public let startOffset: TimeInterval?
  public let endOffset: TimeInterval?

  public init(
    generation: Int,
    sequence: Int,
    text: String,
    startOffset: TimeInterval? = nil,
    endOffset: TimeInterval? = nil
  ) {
    self.generation = generation
    self.sequence = sequence
    self.text = text
    self.startOffset = startOffset
    self.endOffset = endOffset
  }
}

/// Reduces replaceable speech-recognition hypotheses into one durable transcript.
///
/// Recognition callbacks can arrive after a task is replaced, or MainActor hops can
/// execute callbacks out of order. Callers therefore provide both a recognition-task
/// generation and a monotonically increasing sequence number. Within a generation,
/// timestamp and text continuity identify a revision of the active hypothesis; a later
/// non-overlapping interval identifies a new temporal segment. Overlap alone is never
/// enough to discard earlier words because recognizers can reset to a short tail across
/// a pause. When timestamps are not available, textual continuity provides a
/// conservative fallback.
public struct RecognitionTranscriptSession: Sendable, Equatable {
  public private(set) var committedSegments: [RecognitionTranscriptSegment] = []
  public private(set) var activeSegment: RecognitionTranscriptSegment?

  private var currentGeneration: Int?
  private var latestSequence: Int?
  private var cycleIsClosed = false
  private var isStopped = false

  public init() {}

  /// All durable segments plus the current replaceable hypothesis, in capture order.
  public var text: String {
    Self.joined(
      committedSegments.map(\.text)
        + [activeSegment?.text].compactMap { $0 }
    )
  }

  /// Starts a new recognizer task. Any active hypothesis from an older task becomes
  /// durable exactly once before the new task accepts callbacks.
  @discardableResult
  public mutating func beginCycle(generation: Int) -> String {
    guard !isStopped else { return text }

    if let currentGeneration {
      guard generation >= currentGeneration else { return text }
      guard generation != currentGeneration else { return text }
      sealActiveSegment()
    }

    currentGeneration = generation
    latestSequence = nil
    cycleIsClosed = false
    return text
  }

  /// Applies one recognition callback.
  ///
  /// - Parameters:
  ///   - generation: The recognition-task generation that produced this callback.
  ///   - sequence: A monotonically increasing callback sequence within the generation.
  ///   - candidate: The recognizer's current formatted hypothesis. A nil or empty final
  ///     candidate seals the most recent nonempty partial hypothesis.
  ///   - startOffset: Start of the hypothesis in the recognition request's audio stream.
  ///   - endOffset: End of the hypothesis in the recognition request's audio stream.
  ///   - isFinal: Whether the recognizer marked this result final.
  @discardableResult
  public mutating func receive(
    generation: Int,
    sequence: Int,
    candidate: String?,
    startOffset: TimeInterval? = nil,
    endOffset: TimeInterval? = nil,
    isFinal: Bool
  ) -> String {
    guard !isStopped else { return text }

    if currentGeneration == nil || generation > currentGeneration! {
      beginCycle(generation: generation)
    }

    guard generation == currentGeneration, !cycleIsClosed else { return text }
    if let latestSequence {
      guard sequence > latestSequence else { return text }
    }
    latestSequence = sequence

    let normalizedCandidate = candidate?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !normalizedCandidate.isEmpty {
      applyCandidate(
        normalizedCandidate,
        generation: generation,
        sequence: sequence,
        startOffset: Self.validOffset(startOffset),
        endOffset: Self.validOffset(endOffset)
      )
    }

    if isFinal {
      sealActiveSegment()
      cycleIsClosed = true
    }

    return text
  }

  /// Seals the current task after an error or planned recognizer restart. Repeated calls
  /// for the same task are idempotent.
  @discardableResult
  public mutating func finishCycle(generation: Int) -> String {
    guard !isStopped,
          generation == currentGeneration,
          !cycleIsClosed
    else { return text }

    sealActiveSegment()
    cycleIsClosed = true
    return text
  }

  /// Seals the latest partial and rejects every delayed callback until `reset()`.
  @discardableResult
  public mutating func stop() -> String {
    guard !isStopped else { return text }
    sealActiveSegment()
    cycleIsClosed = true
    isStopped = true
    return text
  }

  public mutating func reset() {
    committedSegments = []
    activeSegment = nil
    currentGeneration = nil
    latestSequence = nil
    cycleIsClosed = false
    isStopped = false
  }

  private mutating func applyCandidate(
    _ candidate: String,
    generation: Int,
    sequence: Int,
    startOffset: TimeInterval?,
    endOffset: TimeInterval?
  ) {
    let next = RecognitionTranscriptSegment(
      generation: generation,
      sequence: sequence,
      text: candidate,
      startOffset: startOffset,
      endOffset: endOffset
    )

    guard let activeSegment else {
      self.activeSegment = next
      return
    }

    switch Self.relationship(from: activeSegment, to: next) {
    case .revision:
      self.activeSegment = next
    case let .newTemporalSegment(trimBoundaryOverlap):
      let nextText = trimBoundaryOverlap
        ? Self.removingBoundaryOverlap(candidate, after: activeSegment.text)
        : candidate
      sealActiveSegment()
      self.activeSegment = RecognitionTranscriptSegment(
        generation: next.generation,
        sequence: next.sequence,
        text: nextText,
        startOffset: next.startOffset,
        endOffset: next.endOffset
      )
    case .stale:
      break
    }
  }

  private mutating func sealActiveSegment() {
    guard let activeSegment else { return }
    let text = activeSegment.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      committedSegments.append(
        RecognitionTranscriptSegment(
          generation: activeSegment.generation,
          sequence: activeSegment.sequence,
          text: text,
          startOffset: activeSegment.startOffset,
          endOffset: activeSegment.endOffset
        )
      )
    }
    self.activeSegment = nil
  }

  private enum CandidateRelationship {
    case revision
    case newTemporalSegment(trimBoundaryOverlap: Bool)
    case stale
  }

  private enum TextRelationship {
    case revision
    case regression
    case unrelated
  }

  private static func relationship(
    from previous: RecognitionTranscriptSegment,
    to candidate: RecognitionTranscriptSegment
  ) -> CandidateRelationship {
    if let previousStart = previous.startOffset,
       let previousEnd = previous.endOffset,
       let candidateStart = candidate.startOffset,
       let candidateEnd = candidate.endOffset
    {
      if candidateEnd <= previousStart, candidateStart < previousStart {
        return .stale
      }

      let textContinuity = textRelationship(candidate.text, to: previous.text)
      if case .revision = textContinuity {
        // SFSpeech partial and final hypotheses can carry provisional, zero-length, or
        // forward-shifting timestamps even while formattedString is refining the same
        // text. Strong textual continuity is authoritative for the replaceable active
        // hypothesis; already committed portions remain untouched.
        return .revision
      }

      let previousDuration = max(0, previousEnd - previousStart)
      let candidateDuration = max(0, candidateEnd - candidateStart)
      let hasReliableTemporalBoundary = previousDuration > 0.01
        && candidateDuration > 0.01
        && candidateStart > previousEnd + 0.2
      if hasReliableTemporalBoundary {
        return .newTemporalSegment(trimBoundaryOverlap: false)
      }

      switch textContinuity {
      case .revision:
        // Handled above so provisional timestamps cannot append the same hypothesis.
        return .revision
      case .regression:
        // A shorter candidate already contained by the current hypothesis must not
        // regress the visible transcript. A later extension can still replace it.
        return .stale
      case .unrelated:
        break
      }

      // SFSpeech can reset to only the newest phrase while retaining a small timestamp
      // overlap with its prior hypothesis. Preserve the older phrase and trim any words
      // repeated at the reset boundary instead of replacing the whole active portion.
      let previousWords = normalizedWords(previous.text)
      let candidateWords = normalizedWords(candidate.text)
      let previousWordCount = previousWords.count
      let candidateWordCount = candidateWords.count
      let movedForward = candidateStart > previousStart + 0.2
      let wouldDiscardDurableContent = previousDuration >= 3
        || previousWordCount >= 10
        || candidateWordCount * 2 < previousWordCount
      if movedForward || wouldDiscardDurableContent {
        return .newTemporalSegment(trimBoundaryOverlap: true)
      }

      // Short, same-range hypotheses routinely change every word while recognition is
      // settling. They remain revisions until enough time/text exists to be durable.
      return .revision
    }

    switch textRelationship(candidate.text, to: previous.text) {
    case .revision:
      return .revision
    case .regression:
      return .stale
    case .unrelated:
      return .newTemporalSegment(trimBoundaryOverlap: true)
    }
  }

  private static func textRelationship(_ candidate: String, to previous: String) -> TextRelationship {
    let candidateWords = normalizedWords(candidate)
    let previousWords = normalizedWords(previous)
    guard !candidateWords.isEmpty, !previousWords.isEmpty else { return .unrelated }

    if candidateWords == previousWords { return .revision }
    if candidateWords.starts(with: previousWords) { return .revision }
    if previousWords.starts(with: candidateWords)
      || containsContiguous(previousWords, candidateWords)
    {
      return .regression
    }

    let sharedPrefix = zip(candidateWords, previousWords).prefix { $0 == $1 }.count
    let shorterCount = min(candidateWords.count, previousWords.count)
    let lengthRatio = Double(shorterCount) / Double(max(candidateWords.count, previousWords.count))
    if sharedPrefix >= 3,
       Double(sharedPrefix) / Double(shorterCount) >= 0.75
    {
      if candidateWords.count >= previousWords.count { return .revision }
      return lengthRatio >= 0.85 ? .revision : .regression
    }

    // A mature cumulative hypothesis can revise an early word while retaining nearly
    // all later words. Treat similarly sized, high-overlap candidates as revisions so
    // one correction does not append a second copy of the meeting-so-far.
    let candidateTerms = Set(candidateWords)
    let previousTerms = Set(previousWords)
    let termUnion = candidateTerms.union(previousTerms)
    let termOverlap = termUnion.isEmpty
      ? 0
      : Double(candidateTerms.intersection(previousTerms).count) / Double(termUnion.count)
    if lengthRatio >= 0.85, termOverlap >= 0.6 { return .revision }

    return .unrelated
  }

  private static func containsContiguous(_ words: [String], _ candidate: [String]) -> Bool {
    guard candidate.count <= words.count else { return false }
    if candidate.isEmpty { return true }
    for start in 0 ... (words.count - candidate.count) {
      if Array(words[start ..< start + candidate.count]) == candidate { return true }
    }
    return false
  }

  private static func removingBoundaryOverlap(_ candidate: String, after previous: String) -> String {
    let previousTokens = whitespaceTokens(previous)
    let candidateTokens = whitespaceTokens(candidate)
    guard previousTokens.count > 1, candidateTokens.count > 1 else { return candidate }

    let maximumOverlap = min(previousTokens.count, candidateTokens.count - 1)
    guard maximumOverlap > 0 else { return candidate }
    for count in stride(from: maximumOverlap, through: 1, by: -1) {
      let previousBoundary = previousTokens.suffix(count).map(normalizedToken)
      let candidateBoundary = candidateTokens.prefix(count).map(normalizedToken)
      if previousBoundary == candidateBoundary {
        return candidateTokens.dropFirst(count).joined(separator: " ")
      }
    }
    return candidate
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

  private static func joined(_ portions: [String]) -> String {
    portions
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func validOffset(_ value: TimeInterval?) -> TimeInterval? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
  }
}

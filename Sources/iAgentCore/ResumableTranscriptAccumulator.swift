import Foundation

/// Builds one durable transcript from the replaceable partial hypotheses emitted by
/// speech recognition. Finalized segments are committed, while the current partial
/// result remains replaceable as the recognizer revises it.
public struct ResumableTranscriptAccumulator: Sendable, Equatable {
  public private(set) var committedTranscript = ""
  public private(set) var partialTranscript = ""

  private var expectsContinuationResult = false

  public init() {}

  public var text: String {
    Self.joined(committedTranscript, partialTranscript)
  }

  public mutating func reset() {
    committedTranscript = ""
    partialTranscript = ""
    expectsContinuationResult = false
  }

  /// Marks the first recognition result after audible speech resumes. The next
  /// hypothesis may either revise the current partial segment or begin a new one.
  public mutating func markSpeechResumed() {
    guard !partialTranscript.isEmpty else { return }
    expectsContinuationResult = true
  }

  /// Replaces the current interim hypothesis without disturbing finalized text.
  @discardableResult
  public mutating func updatePartial(with candidate: String) -> String {
    let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return text }

    if expectsContinuationResult, !partialTranscript.isEmpty {
      let previousWords = Self.normalizedWords(partialTranscript)
      let candidateWords = Self.normalizedWords(candidate)

      if candidateWords == previousWords {
        partialTranscript = candidate
        return text
      }

      if Self.isRevisionOrExpansion(candidateWords, of: previousWords) {
        partialTranscript = candidate
      } else {
        commitPartial()
        partialTranscript = candidate
      }
      expectsContinuationResult = false
      return text
    }

    partialTranscript = candidate
    return text
  }

  /// Commits a recognizer's final hypothesis. A nil final result commits the most
  /// recent partial hypothesis, which preserves speech when a task ends on silence.
  @discardableResult
  public mutating func commitFinal(_ candidate: String? = nil) -> String {
    if let candidate {
      updatePartial(with: candidate)
    }
    return commitPartial()
  }

  /// Commits the current partial hypothesis before rotating recognition tasks.
  @discardableResult
  public mutating func commitPartial() -> String {
    committedTranscript = Self.joined(committedTranscript, partialTranscript)
    partialTranscript = ""
    expectsContinuationResult = false
    return text
  }

  private static func joined(_ leading: String, _ trailing: String) -> String {
    let leading = leading.trimmingCharacters(in: .whitespacesAndNewlines)
    let trailing = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !leading.isEmpty else { return trailing }
    guard !trailing.isEmpty else { return leading }

    let leadingWords = normalizedWords(leading)
    let trailingWords = normalizedWords(trailing)
    let maximumOverlap = min(leadingWords.count, trailingWords.count)
    if maximumOverlap >= 2 {
      for overlap in stride(from: maximumOverlap, through: 2, by: -1)
      where Array(leadingWords.suffix(overlap)) == Array(trailingWords.prefix(overlap)) {
        let remainder = droppingFirstWords(overlap, from: trailing)
        guard !remainder.isEmpty else { return leading }
        if remainder.first?.isWhitespace == true || remainder.first?.isPunctuation == true {
          return leading + remainder
        }
        return "\(leading) \(remainder)"
      }
    }

    return "\(leading) \(trailing)"
  }

  private static func droppingFirstWords(_ count: Int, from value: String) -> String {
    guard count > 0 else { return value }
    var wordsSeen = 0
    var insideWord = false

    for index in value.indices {
      let character = value[index]
      let isWordCharacter = character.isLetter || character.isNumber
      if isWordCharacter {
        if !insideWord {
          wordsSeen += 1
          insideWord = true
        }
      } else if insideWord {
        if wordsSeen == count {
          return String(value[index...])
        }
        insideWord = false
      }
    }

    return wordsSeen <= count ? "" : value
  }

  private static func normalizedWords(_ value: String) -> [String] {
    value
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }

  private static func isRevisionOrExpansion(
    _ candidate: [String],
    of previous: [String]
  ) -> Bool {
    guard !candidate.isEmpty, !previous.isEmpty else { return false }
    if candidate.starts(with: previous) {
      return true
    }

    let sharedPrefix = zip(candidate, previous).prefix { $0 == $1 }.count
    let revisionThreshold = min(2, previous.count)
    return sharedPrefix >= revisionThreshold
  }
}

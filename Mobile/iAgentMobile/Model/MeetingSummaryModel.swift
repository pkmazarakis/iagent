import Foundation
import iAgentCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Owns one on-device meeting-summary request. The transcript remains the source of truth:
/// generated output is accepted only while the exact request that produced it is still current.
@MainActor
final class MeetingSummaryModel: ObservableObject {
  enum Availability: Equatable {
    case available
    case unsupported
    case intelligenceDisabled
    case downloading

    var message: String {
      switch self {
      case .available: "Summarize on this iPhone"
      case .unsupported: "Summary unavailable on this iPhone"
      case .intelligenceDisabled: "Turn on Apple Intelligence for summaries"
      case .downloading: "The on-device model is still downloading"
      }
    }
  }

  enum GenerationState: Equatable {
    case idle
    case generating
    case failed(String)
  }

  @Published private(set) var availability: Availability = .unsupported
  @Published private(set) var state: GenerationState = .idle
  @Published private(set) var summary: String?
  /// Changes only when a fresh local generation succeeds. Views use this event to persist once.
  @Published private(set) var completionRevision = 0

  private var generationTask: Task<Void, Never>?
  private var activeRequestID: UUID?
  private var transcript = ""

  init(markdown: String) {
    let content = MeetingNoteContent(markdown: markdown)
    transcript = Self.normalizedTranscript(content.transcript)
    summary = content.summary
    refreshAvailability()
  }

  deinit { generationTask?.cancel() }

  var hasTranscript: Bool { !transcript.isEmpty }

  /// Refreshes persisted content and invalidates any generation whose source changed.
  func update(markdown: String) {
    let content = MeetingNoteContent(markdown: markdown)
    let nextTranscript = Self.normalizedTranscript(content.transcript)
    let nextSummary = content.summary
    if nextTranscript != transcript || (state == .generating && nextSummary != summary) {
      cancel()
    }
    transcript = nextTranscript
    // This also picks up an edited or synced Markdown summary without issuing a model call.
    summary = nextSummary
  }

  func refreshAvailability() {
    availability = Self.currentAvailability
    guard availability != .available else { return }
    generationTask?.cancel()
    generationTask = nil
    activeRequestID = nil
    if state == .generating { state = .idle }
  }

  func generate() {
    refreshAvailability()
    guard availability == .available, !transcript.isEmpty else { return }

    generationTask?.cancel()
    let source = transcript
    let requestID = UUID()
    activeRequestID = requestID
    state = .generating

    generationTask = Task { [weak self] in
      do {
        let result = try await Self.generateLocally(transcript: source)
        try Task.checkCancellation()
        guard let self,
              self.activeRequestID == requestID,
              self.transcript == source
        else { return }

        let resolved = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { throw SummaryError.emptyResponse }
        self.summary = resolved
        self.state = .idle
        self.generationTask = nil
        self.activeRequestID = nil
        self.completionRevision &+= 1
      } catch is CancellationError {
        guard let self, self.activeRequestID == requestID else { return }
        self.generationTask = nil
        self.activeRequestID = nil
        self.state = .idle
      } catch {
        guard let self,
              self.activeRequestID == requestID,
              self.transcript == source
        else { return }
        self.generationTask = nil
        self.activeRequestID = nil
        self.refreshAvailability()
        self.state = self.availability == .available
          ? .failed("Couldn’t create the local summary. Try again.")
          : .idle
      }
    }
  }

  func cancel() {
    generationTask?.cancel()
    generationTask = nil
    activeRequestID = nil
    state = .idle
  }

  private static func normalizedTranscript(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized == "_No speech was recognized._" ? "" : normalized
  }

  private static var currentAvailability: Availability {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--simulate-summary-generation") {
      return .available
    }
    #endif
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available: return .available
      case .unavailable(.deviceNotEligible): return .unsupported
      case .unavailable(.appleIntelligenceNotEnabled): return .intelligenceDisabled
      case .unavailable(.modelNotReady): return .downloading
      @unknown default: return .unsupported
      }
    }
    #endif
    return .unsupported
  }

  private static func generateLocally(transcript: String) async throws -> String {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--simulate-summary-generation") {
      let holdsGeneration = ProcessInfo.processInfo.arguments.contains("--hold-summary-generation")
      try await Task.sleep(for: .milliseconds(holdsGeneration ? 15_000 : 900))
      return """
        ### Decisions
        - Keep meeting capture fast, complete, and reliable.

        ### Action items
        - Validate the saved transcript and source labels.

        ### Key points
        - The full transcript remains attached to this meeting note.
        """
    }
    #endif
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      guard SystemLanguageModel.default.isAvailable else { throw SummaryError.unavailable }
      let session = LanguageModelSession(instructions: """
        Summarize meeting transcripts faithfully and concisely. Use concise Markdown with
        headings for Decisions, Action items, and Key points when relevant, followed by at
        most five bullets per section. Never invent details or add information not present.
        """)
      let response = try await session.respond(
        to: "Summarize this meeting transcript:\n\n\(transcript)"
      )
      return response.content
    }
    #endif
    throw SummaryError.unavailable
  }

  private enum SummaryError: Error {
    case unavailable
    case emptyResponse
  }
}

/// Generates a short meeting title with Apple's on-device Foundation Model. This deliberately
/// has no network fallback: ineligible, disabled, or not-yet-ready devices keep the deterministic
/// recorder title without surfacing an error.
@MainActor
enum MeetingTitleGenerator {
  static var isAvailable: Bool {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--simulate-title-generation") {
      return true
    }
    #endif
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      return SystemLanguageModel.default.isAvailable
    }
    #endif
    return false
  }

  static func generateTitle(from transcript: String) async -> String? {
    let source = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty, source != "_No speech was recognized._", isAvailable else {
      return nil
    }

    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--simulate-title-generation") {
      try? await Task.sleep(for: .milliseconds(650))
      guard !Task.isCancelled else { return nil }
      return "Mobile Launch Decisions"
    }
    #endif

    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      do {
        let session = LanguageModelSession(instructions: """
          Create a useful, specific title for a meeting transcript. Return only the title,
          without quotes, Markdown, labels, or ending punctuation. Use 3 to 8 words and never
          invent details that are not present in the transcript.
          """)
        let response = try await session.respond(
          to: "Title this meeting transcript:\n\n\(source)"
        )
        try Task.checkCancellation()
        return sanitized(response.content)
      } catch {
        return nil
      }
    }
    #endif
    return nil
  }

  private static func sanitized(_ response: String) -> String? {
    var value = response
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    for prefix in ["### ", "## ", "# ", "Title: ", "Meeting title: "] where value.hasPrefix(prefix) {
      value.removeFirst(prefix.count)
      value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      break
    }

    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’ "))
    while let last = value.last, ".:;!?".contains(last) {
      value.removeLast()
      value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard !value.isEmpty else { return nil }
    if value.count > 80 {
      let limit = value.index(value.startIndex, offsetBy: 80)
      let prefix = value[..<limit]
      let shortened = prefix
        .split(separator: " ")
        .dropLast()
        .joined(separator: " ")
      value = shortened.isEmpty ? String(prefix) : shortened
    }
    return value.isEmpty ? nil : value
  }
}

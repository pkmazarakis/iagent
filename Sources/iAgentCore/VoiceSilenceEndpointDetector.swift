import Foundation

/// A finalized quiet-pause candidate for a latched voice-entry session.
public struct VoiceSilenceEndpoint: Equatable, Sendable {
  public let sessionID: VoiceEntrySessionID
  public let transcript: String

  public init(sessionID: VoiceEntrySessionID, transcript: String) {
    self.sessionID = sessionID
    self.transcript = transcript
  }
}

/// Detects a conservative end-of-speech pause without owning a timer or audio engine.
///
/// The caller supplies monotonic timestamps with transcript and metering updates. Only
/// latched sessions with recognized alphanumeric content can arm the detector. A transcript
/// revision or audible level restarts the quiet window, and an endpoint is emitted once per
/// session. This keeps the policy deterministic and leaves explicit Stop as an immediate override.
public struct VoiceSilenceEndpointDetector: Sendable {
  public let requiredQuietDuration: TimeInterval
  public let quietLevelThreshold: Double

  private var activeSessionID: VoiceEntrySessionID?
  private var candidateTranscript = ""
  private var quietBeganAt: TimeInterval?
  private var didEmitEndpoint = false

  public init(
    requiredQuietDuration: TimeInterval = 1.8,
    quietLevelThreshold: Double = 0.11
  ) {
    self.requiredQuietDuration = max(0, requiredQuietDuration)
    self.quietLevelThreshold = max(0, quietLevelThreshold)
  }

  /// Arms or updates the candidate using the state machine's current transcript.
  public mutating func observeTranscript(
    phase: VoiceEntryPhase,
    transcript: String,
    now: TimeInterval
  ) {
    guard let sessionID = eligibleSessionID(for: phase), hasSpokenContent(transcript) else {
      reset()
      return
    }

    let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if activeSessionID != sessionID {
      activeSessionID = sessionID
      candidateTranscript = normalizedTranscript
      quietBeganAt = nil
      didEmitEndpoint = false
      return
    }

    guard candidateTranscript != normalizedTranscript else { return }
    candidateTranscript = normalizedTranscript
    quietBeganAt = nil
    didEmitEndpoint = false
  }

  /// Consumes an audio level and emits once after uninterrupted quiet.
  public mutating func observeLevel(
    phase: VoiceEntryPhase,
    transcript: String,
    level: Double,
    now: TimeInterval
  ) -> VoiceSilenceEndpoint? {
    observeTranscript(phase: phase, transcript: transcript, now: now)
    guard let sessionID = activeSessionID, !didEmitEndpoint else { return nil }

    guard level <= quietLevelThreshold else {
      quietBeganAt = nil
      return nil
    }

    guard let quietBeganAt else {
      self.quietBeganAt = now
      return nil
    }

    guard now >= quietBeganAt else {
      self.quietBeganAt = now
      return nil
    }
    guard now - quietBeganAt >= requiredQuietDuration else { return nil }

    didEmitEndpoint = true
    return VoiceSilenceEndpoint(
      sessionID: sessionID,
      transcript: candidateTranscript
    )
  }

  public mutating func reset() {
    activeSessionID = nil
    candidateTranscript = ""
    quietBeganAt = nil
    didEmitEndpoint = false
  }

  private func eligibleSessionID(for phase: VoiceEntryPhase) -> VoiceEntrySessionID? {
    guard case .listening(let sessionID, .latched, true) = phase else { return nil }
    return sessionID
  }

  private func hasSpokenContent(_ transcript: String) -> Bool {
    transcript.contains { $0.isLetter || $0.isNumber }
  }
}

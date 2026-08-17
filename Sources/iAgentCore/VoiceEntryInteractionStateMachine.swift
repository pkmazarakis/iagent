import Foundation

public typealias VoiceEntrySessionID = UInt64

/// How the current voice capture is kept alive.
///
/// A press-and-hold session remains attached to the finger until the first
/// spoken word. A latched session remains active until the user taps Stop.
public enum VoiceEntryMode: Equatable, Sendable {
  case pressAndHold
  case latched
}

public enum VoiceEntryFailure: Equatable, Sendable {
  case permissionDenied
  case captureStartFailed
}

/// User-visible phases for the voice-entry interaction.
///
/// Session identifiers make asynchronous speech and permission callbacks safe:
/// callbacks from an abandoned or superseded session cannot mutate a new one.
public enum VoiceEntryPhase: Equatable, Sendable {
  case idle
  case pressing
  case requestingPermission(sessionID: VoiceEntrySessionID, mode: VoiceEntryMode)
  case starting(sessionID: VoiceEntrySessionID, mode: VoiceEntryMode)
  case listening(
    sessionID: VoiceEntrySessionID,
    mode: VoiceEntryMode,
    hasRecognizedSpeech: Bool
  )
  case stopping(sessionID: VoiceEntrySessionID, mode: VoiceEntryMode)
  case handingOff(sessionID: VoiceEntrySessionID, transcript: String)
  case failed(sessionID: VoiceEntrySessionID, reason: VoiceEntryFailure)
}

/// Side effects requested by ``VoiceEntryInteractionStateMachine``.
///
/// The state machine itself does not import UI, Speech, or AVFoundation. The
/// caller performs these actions and feeds asynchronous results back with the
/// included session identifier.
public enum VoiceEntryAction: Equatable, Sendable {
  case openCreateMenu
  case presentVoiceOverlay(sessionID: VoiceEntrySessionID, mode: VoiceEntryMode)
  case requestPermission(sessionID: VoiceEntrySessionID)
  case startListening(sessionID: VoiceEntrySessionID)
  case stopListening(sessionID: VoiceEntrySessionID)
  case cancelSession(sessionID: VoiceEntrySessionID)
  case handOff(sessionID: VoiceEntrySessionID, transcript: String)
}

/// Deterministic interaction policy for the plus-button voice entry point.
///
/// Drive a complete touch sequence with ``pressBegan()``, optionally
/// ``holdRecognized()``, and finally ``pressEnded()``. Because the state machine
/// owns tap-versus-hold arbitration, a committed hold can never also open the
/// Create menu on finger-up.
public struct VoiceEntryInteractionStateMachine: Equatable, Sendable {
  public private(set) var phase: VoiceEntryPhase
  public private(set) var transcript: String

  private var nextSessionID: VoiceEntrySessionID

  public init(initialSessionID: VoiceEntrySessionID = 1) {
    phase = .idle
    transcript = ""
    nextSessionID = max(1, initialSessionID)
  }

  public var currentSessionID: VoiceEntrySessionID? {
    switch phase {
    case .requestingPermission(let sessionID, _),
         .starting(let sessionID, _),
         .listening(let sessionID, _, _),
         .stopping(let sessionID, _),
         .handingOff(let sessionID, _),
         .failed(let sessionID, _):
      sessionID
    case .idle, .pressing:
      nil
    }
  }

  /// Records touch-down on the plus button. Touch-down alone has no side effect.
  @discardableResult
  public mutating func pressBegan() -> [VoiceEntryAction] {
    guard phase == .idle else { return [] }
    phase = .pressing
    return []
  }

  /// Commits a held plus-button press to voice entry.
  @discardableResult
  public mutating func holdRecognized() -> [VoiceEntryAction] {
    guard phase == .pressing else { return [] }
    return beginVoiceSession(mode: .pressAndHold)
  }

  /// Resolves finger-up for either a regular tap or a committed hold.
  ///
  /// Releasing before the hold threshold opens the existing Create menu.
  /// Releasing a committed hold before speech arrives latches capture. Once a
  /// word has arrived, release asks the speech service to finish capture.
  @discardableResult
  public mutating func pressEnded() -> [VoiceEntryAction] {
    switch phase {
    case .pressing:
      phase = .idle
      return [.openCreateMenu]

    case .requestingPermission(let sessionID, .pressAndHold):
      phase = .requestingPermission(sessionID: sessionID, mode: .latched)
      return []

    case .starting(let sessionID, .pressAndHold):
      phase = .starting(sessionID: sessionID, mode: .latched)
      return []

    case .listening(let sessionID, .pressAndHold, false):
      phase = .listening(
        sessionID: sessionID,
        mode: .latched,
        hasRecognizedSpeech: false
      )
      return []

    case .listening(let sessionID, .pressAndHold, true):
      phase = .stopping(sessionID: sessionID, mode: .pressAndHold)
      return [.stopListening(sessionID: sessionID)]

    case .idle,
         .requestingPermission(_, .latched),
         .starting(_, .latched),
         .listening(_, .latched, _),
         .stopping,
         .handingOff,
         .failed:
      return []
    }
  }

  /// Starts the Create-menu "New voice chat" path in latched mode.
  @discardableResult
  public mutating func beginVoiceChatFromMenu() -> [VoiceEntryAction] {
    guard phase == .idle else { return [] }
    return beginVoiceSession(mode: .latched)
  }

  /// Feeds the asynchronous permission result back into the active session.
  @discardableResult
  public mutating func resolvePermission(
    sessionID: VoiceEntrySessionID,
    granted: Bool
  ) -> [VoiceEntryAction] {
    guard case .requestingPermission(let activeSessionID, let mode) = phase,
          activeSessionID == sessionID
    else { return [] }

    guard granted else {
      transcript = ""
      phase = .failed(sessionID: sessionID, reason: .permissionDenied)
      return []
    }

    phase = .starting(sessionID: sessionID, mode: mode)
    return [.startListening(sessionID: sessionID)]
  }

  /// Confirms that the speech service is actively capturing audio.
  @discardableResult
  public mutating func listeningStarted(
    sessionID: VoiceEntrySessionID
  ) -> [VoiceEntryAction] {
    guard case .starting(let activeSessionID, let mode) = phase,
          activeSessionID == sessionID
    else { return [] }

    phase = .listening(
      sessionID: sessionID,
      mode: mode,
      hasRecognizedSpeech: Self.hasSpokenContent(transcript)
    )
    return []
  }

  /// Records a speech-service startup failure for the active session.
  @discardableResult
  public mutating func listeningStartFailed(
    sessionID: VoiceEntrySessionID
  ) -> [VoiceEntryAction] {
    guard case .starting(let activeSessionID, _) = phase,
          activeSessionID == sessionID
    else { return [] }

    transcript = ""
    phase = .failed(sessionID: sessionID, reason: .captureStartFailed)
    return []
  }

  /// Applies a partial transcript. Whitespace and punctuation alone do not count
  /// as the first spoken word for hold-release behavior.
  @discardableResult
  public mutating func receiveTranscript(
    sessionID: VoiceEntrySessionID,
    transcript newTranscript: String
  ) -> [VoiceEntryAction] {
    switch phase {
    case .starting(let activeSessionID, let mode) where activeSessionID == sessionID:
      transcript = newTranscript
      phase = .listening(
        sessionID: sessionID,
        mode: mode,
        hasRecognizedSpeech: Self.hasSpokenContent(newTranscript)
      )
      return []

    case .listening(let activeSessionID, let mode, _)
      where activeSessionID == sessionID:
      transcript = newTranscript
      phase = .listening(
        sessionID: sessionID,
        mode: mode,
        hasRecognizedSpeech: Self.hasSpokenContent(newTranscript)
      )
      return []

    case .stopping(let activeSessionID, _) where activeSessionID == sessionID:
      transcript = newTranscript
      return []

    default:
      return []
    }
  }

  /// Requests capture completion for a latched voice session.
  ///
  /// Repeated taps after the first are ignored, making Stop idempotent. If the
  /// permission request has not returned yet, the pending session is cancelled
  /// immediately instead of waiting for a finish callback that cannot arrive.
  @discardableResult
  public mutating func stopTapped() -> [VoiceEntryAction] {
    switch phase {
    case .requestingPermission(let sessionID, _):
      transcript = ""
      phase = .idle
      return [.cancelSession(sessionID: sessionID)]

    case .starting(let sessionID, let mode),
         .listening(let sessionID, let mode, _):
      phase = .stopping(sessionID: sessionID, mode: mode)
      return [.stopListening(sessionID: sessionID)]

    case .idle, .pressing, .stopping, .handingOff, .failed:
      return []
    }
  }

  /// Completes capture and requests an Ask iAgent handoff only for spoken text.
  @discardableResult
  public mutating func transcriptionFinished(
    sessionID: VoiceEntrySessionID,
    finalTranscript: String
  ) -> [VoiceEntryAction] {
    let isActiveSession: Bool
    switch phase {
    case .starting(let activeSessionID, _),
         .listening(let activeSessionID, _, _),
         .stopping(let activeSessionID, _):
      isActiveSession = activeSessionID == sessionID
    case .idle, .pressing, .requestingPermission, .handingOff, .failed:
      isActiveSession = false
    }

    guard isActiveSession else { return [] }

    let finalTranscript = Self.normalizedTranscript(finalTranscript)
    guard Self.hasSpokenContent(finalTranscript) else {
      transcript = ""
      phase = .idle
      return []
    }

    transcript = finalTranscript
    phase = .handingOff(sessionID: sessionID, transcript: finalTranscript)
    return [.handOff(sessionID: sessionID, transcript: finalTranscript)]
  }

  /// Cancels any pending work and returns to the initial interaction state.
  @discardableResult
  public mutating func abandon() -> [VoiceEntryAction] {
    let action: [VoiceEntryAction]
    switch phase {
    case .requestingPermission(let sessionID, _),
         .starting(let sessionID, _),
         .listening(let sessionID, _, _),
         .stopping(let sessionID, _):
      action = [.cancelSession(sessionID: sessionID)]
    case .idle, .pressing, .handingOff, .failed:
      action = []
    }

    transcript = ""
    phase = .idle
    return action
  }

  private mutating func beginVoiceSession(
    mode: VoiceEntryMode
  ) -> [VoiceEntryAction] {
    let sessionID = nextSessionID
    nextSessionID = sessionID == .max ? 1 : sessionID + 1
    transcript = ""
    phase = .requestingPermission(sessionID: sessionID, mode: mode)
    return [
      .presentVoiceOverlay(sessionID: sessionID, mode: mode),
      .requestPermission(sessionID: sessionID),
    ]
  }

  private static func normalizedTranscript(_ transcript: String) -> String {
    transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func hasSpokenContent(_ transcript: String) -> Bool {
    transcript.contains { character in
      character.isLetter || character.isNumber
    }
  }
}

import Foundation

/// Detects an utterance boundary from microphone activity so a long-running speech
/// capture can rotate recognition tasks while the user is silent. A fresh recognition
/// task restores streaming interim hypotheses for the next utterance on devices where
/// an on-device recognizer otherwise begins batching results after its first pause.
public struct RecognitionCycleBoundaryDetector: Sendable, Equatable {
  public let speechLevelThreshold: Double
  public let silenceDuration: TimeInterval

  private var lastObservationTime: TimeInterval?
  private var lastSpeechTime: TimeInterval?
  private var boundaryWasReported = false

  public init(
    speechLevelThreshold: Double = 0.22,
    silenceDuration: TimeInterval = 0.55
  ) {
    self.speechLevelThreshold = speechLevelThreshold
    self.silenceDuration = silenceDuration
  }

  /// Resets the detector when a new recognition task begins. Silence alone never
  /// rotates an empty task; speech must first be observed in the current cycle.
  public mutating func beginCycle() {
    lastObservationTime = nil
    lastSpeechTime = nil
    boundaryWasReported = false
  }

  /// Returns `true` exactly once after speech in the current cycle is followed by the
  /// configured duration of silence. Timestamps must be monotonic; delayed observations
  /// from an older audio callback are ignored.
  public mutating func observe(level: Double, at time: TimeInterval) -> Bool {
    guard time.isFinite, level.isFinite else { return false }
    if let lastObservationTime, time < lastObservationTime { return false }
    lastObservationTime = time

    guard !boundaryWasReported else { return false }
    if level >= speechLevelThreshold {
      lastSpeechTime = time
      return false
    }

    guard let lastSpeechTime,
          time - lastSpeechTime >= silenceDuration
    else { return false }

    boundaryWasReported = true
    return true
  }
}

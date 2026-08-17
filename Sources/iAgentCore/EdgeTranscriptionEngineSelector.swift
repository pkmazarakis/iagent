/// The on-device transcription engines that iAgent can select automatically.
public enum EdgeTranscriptionEngine: Sendable, Equatable {
  case speechAnalyzer
  case legacyOnDeviceSpeech
}

/// Platform capabilities used to choose a transcription engine without importing
/// Speech or depending on a particular OS version in iAgentCore.
public struct EdgeTranscriptionEngineCapabilities: Sendable, Equatable {
  /// `true` only when SpeechAnalyzer is usable for the requested locale and its
  /// required on-device assets are installed or can be installed before capture.
  public let speechAnalyzerIsAvailable: Bool

  /// Mirrors the legacy recognizer's general availability.
  public let legacyRecognizerIsAvailable: Bool

  /// Mirrors whether the legacy recognizer supports on-device recognition for the
  /// requested locale. General availability alone must never enable a network fallback.
  public let legacyRecognizerSupportsOnDeviceRecognition: Bool

  public init(
    speechAnalyzerIsAvailable: Bool,
    legacyRecognizerIsAvailable: Bool,
    legacyRecognizerSupportsOnDeviceRecognition: Bool
  ) {
    self.speechAnalyzerIsAvailable = speechAnalyzerIsAvailable
    self.legacyRecognizerIsAvailable = legacyRecognizerIsAvailable
    self.legacyRecognizerSupportsOnDeviceRecognition =
      legacyRecognizerSupportsOnDeviceRecognition
  }
}

public enum EdgeTranscriptionEngineSelection: Sendable, Equatable {
  case selected(EdgeTranscriptionEngine)
  case unavailable
}

/// Selects only engines that can transcribe entirely on device.
public enum EdgeTranscriptionEngineSelector {
  public static func select(
    from capabilities: EdgeTranscriptionEngineCapabilities
  ) -> EdgeTranscriptionEngineSelection {
    if capabilities.speechAnalyzerIsAvailable {
      return .selected(.speechAnalyzer)
    }

    if capabilities.legacyRecognizerIsAvailable,
       capabilities.legacyRecognizerSupportsOnDeviceRecognition
    {
      return .selected(.legacyOnDeviceSpeech)
    }

    return .unavailable
  }
}

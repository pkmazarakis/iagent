import XCTest
@testable import iAgentCore

final class EdgeTranscriptionEngineSelectorTests: XCTestCase {
  func testAutomaticSelectionAcrossEveryCapabilityCombination() {
    struct Scenario {
      let name: String
      let speechAnalyzerIsAvailable: Bool
      let legacyRecognizerIsAvailable: Bool
      let legacyRecognizerSupportsOnDeviceRecognition: Bool
      let expected: EdgeTranscriptionEngineSelection
    }

    let scenarios = [
      Scenario(
        name: "no engine",
        speechAnalyzerIsAvailable: false,
        legacyRecognizerIsAvailable: false,
        legacyRecognizerSupportsOnDeviceRecognition: false,
        expected: .unavailable
      ),
      Scenario(
        name: "legacy support flag without an available recognizer",
        speechAnalyzerIsAvailable: false,
        legacyRecognizerIsAvailable: false,
        legacyRecognizerSupportsOnDeviceRecognition: true,
        expected: .unavailable
      ),
      Scenario(
        name: "network-capable legacy recognizer only",
        speechAnalyzerIsAvailable: false,
        legacyRecognizerIsAvailable: true,
        legacyRecognizerSupportsOnDeviceRecognition: false,
        expected: .unavailable
      ),
      Scenario(
        name: "legacy on-device recognizer",
        speechAnalyzerIsAvailable: false,
        legacyRecognizerIsAvailable: true,
        legacyRecognizerSupportsOnDeviceRecognition: true,
        expected: .selected(.legacyOnDeviceSpeech)
      ),
      Scenario(
        name: "SpeechAnalyzer only",
        speechAnalyzerIsAvailable: true,
        legacyRecognizerIsAvailable: false,
        legacyRecognizerSupportsOnDeviceRecognition: false,
        expected: .selected(.speechAnalyzer)
      ),
      Scenario(
        name: "SpeechAnalyzer with an unavailable legacy support flag",
        speechAnalyzerIsAvailable: true,
        legacyRecognizerIsAvailable: false,
        legacyRecognizerSupportsOnDeviceRecognition: true,
        expected: .selected(.speechAnalyzer)
      ),
      Scenario(
        name: "SpeechAnalyzer with network-capable legacy recognition",
        speechAnalyzerIsAvailable: true,
        legacyRecognizerIsAvailable: true,
        legacyRecognizerSupportsOnDeviceRecognition: false,
        expected: .selected(.speechAnalyzer)
      ),
      Scenario(
        name: "both on-device engines",
        speechAnalyzerIsAvailable: true,
        legacyRecognizerIsAvailable: true,
        legacyRecognizerSupportsOnDeviceRecognition: true,
        expected: .selected(.speechAnalyzer)
      ),
    ]

    for scenario in scenarios {
      let capabilities = EdgeTranscriptionEngineCapabilities(
        speechAnalyzerIsAvailable: scenario.speechAnalyzerIsAvailable,
        legacyRecognizerIsAvailable: scenario.legacyRecognizerIsAvailable,
        legacyRecognizerSupportsOnDeviceRecognition:
          scenario.legacyRecognizerSupportsOnDeviceRecognition
      )

      XCTAssertEqual(
        EdgeTranscriptionEngineSelector.select(from: capabilities),
        scenario.expected,
        scenario.name
      )
    }
  }
}

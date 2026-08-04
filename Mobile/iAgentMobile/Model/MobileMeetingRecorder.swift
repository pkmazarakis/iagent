import AVFoundation
import Foundation
import Speech
import SwiftUI

@MainActor
final class MobileMeetingRecorder: ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var transcript = ""
  @Published private(set) var levels = Array(repeating: CGFloat(0.04), count: 34)
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var errorMessage: String?

  private let audioEngine = AVAudioEngine()
  private let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var timer: Timer?
  private var startedAt: Date?

  var elapsedText: String {
    let total = Int(elapsed)
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  func start() async -> Bool {
    guard !isRecording else { return true }
    errorMessage = nil

    let speechStatus = await requestSpeechPermission()
    guard speechStatus == .authorized else {
      errorMessage = "Speech recognition permission is required."
      return false
    }
    guard await requestMicrophonePermission() else {
      errorMessage = "Microphone permission is required."
      return false
    }
    guard let recognizer, recognizer.isAvailable else {
      errorMessage = "Speech recognition is temporarily unavailable."
      return false
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
      try session.setActive(true, options: .notifyOthersOnDeactivation)

      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      request.addsPunctuation = true
      if recognizer.supportsOnDeviceRecognition {
        request.requiresOnDeviceRecognition = true
      }
      self.request = request

      let input = audioEngine.inputNode
      let format = input.outputFormat(forBus: 0)
      input.removeTap(onBus: 0)
      input.installTap(onBus: 0, bufferSize: 768, format: format) { [weak self] buffer, _ in
        request.append(buffer)
        let level = Self.normalizedLevel(from: buffer)
        Task { @MainActor [weak self] in
          self?.append(level: level)
        }
      }

      transcript = ""
      elapsed = 0
      startedAt = Date()
      audioEngine.prepare()
      try audioEngine.start()
      isRecording = true

      recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if let result {
            transcript = result.bestTranscription.formattedString
          }
          if let error, isRecording {
            errorMessage = error.localizedDescription
          }
        }
      }

      timer?.invalidate()
      timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, let startedAt else { return }
          elapsed = Date().timeIntervalSince(startedAt)
        }
      }
      return true
    } catch {
      stopAudio()
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func stop() -> String {
    guard isRecording || request != nil else { return transcript }
    isRecording = false
    request?.endAudio()
    recognitionTask?.finish()
    stopAudio()
    return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func reset() {
    _ = stop()
    transcript = ""
    elapsed = 0
    errorMessage = nil
    levels = Array(repeating: 0.04, count: 34)
  }

  private func stopAudio() {
    timer?.invalidate()
    timer = nil
    if audioEngine.isRunning { audioEngine.stop() }
    audioEngine.inputNode.removeTap(onBus: 0)
    request = nil
    recognitionTask = nil
    startedAt = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func append(level: CGFloat) {
    levels.append(level)
    if levels.count > 34 { levels.removeFirst(levels.count - 34) }
  }

  private func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
  }

  private func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission {
        continuation.resume(returning: $0)
      }
    }
  }

  private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
    guard let channel = buffer.floatChannelData?.pointee else { return 0.04 }
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return 0.04 }
    var sum: Float = 0
    for index in 0 ..< frameLength {
      let sample = channel[index]
      sum += sample * sample
    }
    let rms = sqrt(sum / Float(frameLength))
    let decibels = 20 * log10(max(rms, 0.000_01))
    return CGFloat(min(1, max(0.04, (decibels + 52) / 42)))
  }
}

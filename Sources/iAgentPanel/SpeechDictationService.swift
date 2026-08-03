@preconcurrency import AVFoundation
import Combine
import Foundation
@preconcurrency import Speech

struct DictationServiceError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

struct SpeechTranscriptAccumulator: Sendable, Equatable {
  private(set) var committedTranscript = ""
  private(set) var segmentTranscript = ""
  private var expectsContinuationResult = false

  var text: String {
    Self.joined(committedTranscript, segmentTranscript)
  }

  mutating func reset() {
    committedTranscript = ""
    segmentTranscript = ""
    expectsContinuationResult = false
  }

  mutating func markSpeechResumed() {
    guard !segmentTranscript.isEmpty else { return }
    expectsContinuationResult = true
  }

  @discardableResult
  mutating func update(with candidate: String) -> String {
    let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return text }

    if expectsContinuationResult, !segmentTranscript.isEmpty {
      let previousWords = Self.normalizedWords(segmentTranscript)
      let candidateWords = Self.normalizedWords(candidate)

      if candidateWords == previousWords {
        segmentTranscript = candidate
        return text
      }

      if Self.isRevisionOrExpansion(candidateWords, of: previousWords) {
        segmentTranscript = candidate
      } else {
        finalizeSegment()
        segmentTranscript = candidate
      }
      expectsContinuationResult = false
      return text
    }

    segmentTranscript = candidate
    return text
  }

  @discardableResult
  mutating func finalizeSegment() -> String {
    committedTranscript = Self.joined(committedTranscript, segmentTranscript)
    segmentTranscript = ""
    expectsContinuationResult = false
    return text
  }

  private static func joined(_ leading: String, _ trailing: String) -> String {
    let leading = leading.trimmingCharacters(in: .whitespacesAndNewlines)
    let trailing = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !leading.isEmpty else { return trailing }
    guard !trailing.isEmpty else { return leading }
    return "\(leading) \(trailing)"
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

enum SpeechPermissionBridge {
  static func requestSpeechAuthorization() async -> Bool {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      return true
    case .denied, .restricted:
      return false
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
          continuation.resume(returning: status == .authorized)
        }
      }
    @unknown default:
      return false
    }
  }

  static func requestMicrophoneAuthorization() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .denied, .restricted:
      return false
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          continuation.resume(returning: granted)
        }
      }
    @unknown default:
      return false
    }
  }
}

private final class SpeechAudioTapBridge: @unchecked Sendable {
  private weak var service: SpeechDictationService?
  private let request: SFSpeechAudioBufferRecognitionRequest
  private var bufferCount = 0

  init(
    service: SpeechDictationService,
    request: SFSpeechAudioBufferRecognitionRequest
  ) {
    self.service = service
    self.request = request
  }

  func makeTapBlock() -> AVAudioNodeTapBlock {
    { [weak self] buffer, _ in
      self?.receive(buffer)
    }
  }

  private func receive(_ buffer: AVAudioPCMBuffer) {
    request.append(buffer)

    // Keep work on AVFoundation's real-time queue small and avoid flooding the main actor.
    bufferCount += 1
    guard bufferCount.isMultiple(of: 2) else { return }
    let level = Self.normalizedLevel(from: buffer)
    Task { @MainActor [weak service] in
      service?.receiveAudioLevel(level)
    }
  }

  private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
    guard let channel = buffer.floatChannelData?.pointee else { return 0.08 }
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return 0.08 }

    var sum: Float = 0
    for index in 0..<frameCount {
      let sample = channel[index]
      sum += sample * sample
    }
    let rms = sqrt(sum / Float(frameCount))
    let decibels = 20 * log10(max(rms, 0.000_001))
    return CGFloat(min(max((decibels + 58) / 50, 0.06), 1))
  }
}

private final class SpeechRecognitionBridge: @unchecked Sendable {
  private weak var service: SpeechDictationService?
  private let generation: Int

  init(service: SpeechDictationService, generation: Int) {
    self.service = service
    self.generation = generation
  }

  func makeResultHandler() -> (SFSpeechRecognitionResult?, Error?) -> Void {
    { [weak self] result, error in
      self?.receive(result: result, error: error)
    }
  }

  private func receive(result: SFSpeechRecognitionResult?, error: Error?) {
    let transcript = result?.bestTranscription.formattedString
    let isFinal = result?.isFinal ?? false
    let nsError = error as NSError?
    let errorMessage = nsError?.localizedDescription
    let errorDomain = nsError?.domain
    let errorCode = nsError?.code
    let generation = generation

    Task { @MainActor [weak service] in
      service?.receiveRecognition(
        transcript: transcript,
        isFinal: isFinal,
        errorMessage: errorMessage,
        errorDomain: errorDomain,
        errorCode: errorCode,
        generation: generation
      )
    }
  }
}

@MainActor
final class SpeechDictationService: NSObject, ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var transcript = ""
  @Published private(set) var levels: [CGFloat] = Array(repeating: 0.06, count: 42)
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var isSpeechActive = false
  @Published private(set) var errorMessage: String?

  private let audioEngine = AVAudioEngine()
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var audioTapBridge: SpeechAudioTapBridge?
  private var recognitionBridge: SpeechRecognitionBridge?
  private var inputTapInstalled = false
  private var elapsedTimer: Timer?
  private var restartTask: Task<Void, Never>?
  private var startedAt: Date?
  private var lastSpeechActivityAt: Date?
  private var accumulator = SpeechTranscriptAccumulator()
  private var recognitionGeneration = 0
  private var consecutiveRecognitionFailures = 0
  private var isPreview = false

  private let speechLevelThreshold: CGFloat = 0.22
  private let silenceDelay: TimeInterval = 0.7

  var elapsedText: String {
    let seconds = max(0, Int(elapsed.rounded(.down)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  var isReadyToSubmit: Bool {
    !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isRecording
  }

  func start() async throws {
    guard !isRecording else { return }
    errorMessage = nil
    accumulator.reset()
    transcript = ""
    levels = Array(repeating: 0.06, count: 42)
    elapsed = 0
    isSpeechActive = false
    lastSpeechActivityAt = nil
    consecutiveRecognitionFailures = 0

    guard await SpeechPermissionBridge.requestSpeechAuthorization() else {
      throw DictationServiceError(
        message: "Speech Recognition permission is required in System Settings > Privacy & Security."
      )
    }
    guard await SpeechPermissionBridge.requestMicrophoneAuthorization() else {
      throw DictationServiceError(
        message: "Microphone permission is required in System Settings > Privacy & Security."
      )
    }

    guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
      throw DictationServiceError(message: "Speech recognition is not available for the current language.")
    }

    speechRecognizer = recognizer
    isPreview = false
    isRecording = true
    startedAt = Date()

    do {
      try startRecognitionCycle()
    } catch {
      finishCapture(cancelRecognition: true)
      throw error
    }
    startElapsedTimer()
  }

  @discardableResult
  func stop() -> String {
    transcript = accumulator.finalizeSegment()
    finishCapture(cancelRecognition: false)
    return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func cancel() {
    finishCapture(cancelRecognition: true)
    accumulator.reset()
    transcript = ""
    errorMessage = nil
  }

  func startPreview(
    transcript: String,
    elapsed: TimeInterval = 5,
    speechActive: Bool = true
  ) {
    cancel()
    isPreview = true
    isRecording = true
    isSpeechActive = speechActive
    lastSpeechActivityAt = speechActive ? Date() : nil
    accumulator.update(with: transcript)
    self.transcript = accumulator.text
    self.elapsed = elapsed
    levels = [
      0.18, 0.46, 0.72, 0.34, 0.84, 0.58, 0.27, 0.66, 0.92, 0.48, 0.74,
      0.36, 0.64, 0.43, 0.78, 0.31, 0.52, 0.26, 0.46, 0.21, 0.38, 0.18,
      0.32, 0.14, 0.27, 0.12, 0.23, 0.1, 0.2, 0.09, 0.17, 0.08, 0.14,
      0.08, 0.12, 0.08, 0.1, 0.08, 0.09, 0.08, 0.08, 0.08,
    ]
  }

  func setPreviewSpeechActive(_ active: Bool) {
    guard isPreview else { return }
    isSpeechActive = active
    lastSpeechActivityAt = active ? Date() : nil
    if !active {
      levels = Array(repeating: 0.06, count: 42)
    }
  }

  private func startRecognitionCycle() throws {
    guard let recognizer = speechRecognizer, recognizer.isAvailable else {
      throw DictationServiceError(message: "Speech recognition became unavailable.")
    }

    invalidateRecognitionCycle(cancel: true)

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
      throw DictationServiceError(message: "No usable microphone input was found.")
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }
    recognitionRequest = request

    let tapBridge = SpeechAudioTapBridge(service: self, request: request)
    audioTapBridge = tapBridge
    inputNode.installTap(
      onBus: 0,
      bufferSize: 1_024,
      format: recordingFormat,
      block: tapBridge.makeTapBlock()
    )
    inputTapInstalled = true

    if !audioEngine.isRunning {
      audioEngine.prepare()
      do {
        try audioEngine.start()
      } catch {
        inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
        audioTapBridge = nil
        recognitionRequest = nil
        throw DictationServiceError(
          message: "Could not start microphone capture: \(error.localizedDescription)"
        )
      }
    }

    recognitionGeneration += 1
    let generation = recognitionGeneration
    let bridge = SpeechRecognitionBridge(service: self, generation: generation)
    recognitionBridge = bridge
    recognitionTask = recognizer.recognitionTask(
      with: request,
      resultHandler: bridge.makeResultHandler()
    )
  }

  private func scheduleRecognitionRestart() {
    guard isRecording, !isPreview else { return }
    transcript = accumulator.finalizeSegment()
    restartTask?.cancel()
    invalidateRecognitionCycle(cancel: false)

    restartTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(70))
      guard let self, !Task.isCancelled, self.isRecording, !self.isPreview else { return }
      do {
        try self.startRecognitionCycle()
        self.restartTask = nil
      } catch {
        self.restartTask = nil
        self.errorMessage = error.localizedDescription
        self.finishCapture(cancelRecognition: true)
      }
    }
  }

  private func finishCapture(cancelRecognition: Bool) {
    restartTask?.cancel()
    restartTask = nil
    elapsedTimer?.invalidate()
    elapsedTimer = nil
    startedAt = nil
    lastSpeechActivityAt = nil

    if !isPreview {
      invalidateRecognitionCycle(cancel: cancelRecognition)
      if audioEngine.isRunning {
        audioEngine.stop()
      }
    }

    speechRecognizer = nil
    isPreview = false
    isRecording = false
    isSpeechActive = false
  }

  private func invalidateRecognitionCycle(cancel: Bool) {
    recognitionGeneration += 1
    if inputTapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      inputTapInstalled = false
    }
    recognitionRequest?.endAudio()
    if cancel {
      recognitionTask?.cancel()
    } else {
      recognitionTask?.finish()
    }
    recognitionRequest = nil
    recognitionTask = nil
    audioTapBridge = nil
    recognitionBridge = nil
  }

  private func startElapsedTimer() {
    elapsedTimer?.invalidate()
    elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let startedAt = self.startedAt else { return }
        let now = Date()
        self.elapsed = now.timeIntervalSince(startedAt)
        if self.isSpeechActive,
           let lastSpeechActivityAt = self.lastSpeechActivityAt,
           now.timeIntervalSince(lastSpeechActivityAt) >= self.silenceDelay
        {
          self.isSpeechActive = false
        }
      }
    }
    elapsedTimer?.tolerance = 0.02
  }

  fileprivate func receiveAudioLevel(_ level: CGFloat) {
    guard isRecording, !isPreview else { return }
    let previous = levels.last ?? 0.06
    let smoothedLevel = previous * 0.54 + level * 0.46
    levels.append(max(0.06, smoothedLevel))
    if levels.count > 42 {
      levels.removeFirst(levels.count - 42)
    }

    if level >= speechLevelThreshold {
      if !isSpeechActive {
        accumulator.markSpeechResumed()
      }
      lastSpeechActivityAt = Date()
      isSpeechActive = true
    }
  }

  fileprivate func receiveRecognition(
    transcript candidate: String?,
    isFinal: Bool,
    errorMessage: String?,
    errorDomain: String?,
    errorCode: Int?,
    generation: Int
  ) {
    guard generation == recognitionGeneration, isRecording, !isPreview else { return }

    if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      transcript = accumulator.update(with: candidate)
      consecutiveRecognitionFailures = 0
    }

    if isFinal {
      transcript = accumulator.finalizeSegment()
      scheduleRecognitionRestart()
      return
    }

    guard let errorMessage else { return }
    let isNoSpeech = errorDomain == "kAFAssistantErrorDomain" && errorCode == 1110
    if isNoSpeech {
      scheduleRecognitionRestart()
      return
    }

    consecutiveRecognitionFailures += 1
    if consecutiveRecognitionFailures <= 3 {
      scheduleRecognitionRestart()
    } else {
      self.errorMessage = errorMessage
      finishCapture(cancelRecognition: true)
    }
  }
}

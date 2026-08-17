import AVFoundation
import Foundation
import Speech
import SwiftUI
import iAgentCore

@MainActor
final class MobileMeetingRecorder: ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var isStarting = false
  @Published private(set) var isStopping = false
  @Published private(set) var transcript = ""
  @Published private(set) var levels: [CGFloat] = []
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var errorMessage: String?
  @Published private(set) var hasRecoverableRecording = false

  private let audioEngine = AVAudioEngine()
  private var recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var restartTask: Task<Void, Never>?
  private var timer: Timer?
  private var startedAt: Date?
  private var startAttemptID: UUID?
  /// Identifies the recorder session that owns all mutable capture state.
  ///
  /// `start()`, `stop()`, and `reset()` can interleave at suspension points even
  /// though the recorder is main-actor isolated. Advancing this epoch before a
  /// reset or a new start ensures a retired async operation can never tear down
  /// or publish into its successor.
  private var sessionEpoch: UInt64 = 0
  private var inputTapInstalled = false
  private var callbackBridge: MobileRecorderCallbackBridge?
  private var legacyAudioBridge: MobileLegacySpeechAudioBridge?
  private var speechAnalyzerSession: MobileSpeechAnalyzerSession?
  private var speechAnalyzerUpdateTask: Task<Void, Never>?
  private var speechAnalyzerAudioBridge: MobileSpeechAnalyzerAudioBridge?
  private var activeEngine: EdgeTranscriptionEngine?
  private var isSimulating = false
  private var recognitionDidComplete = false
  private var recognitionGeneration = 0
  private var consecutiveRecognitionFailures = 0
  private var transcriptSession = RecognitionTranscriptSession()
  private var simulatedPhraseIndex = 0
  private var simulatedCallbackSequence = 0

  private static let waveformHistoryCapacity = 160
  private static let captureTailDuration: Duration = .milliseconds(450)

  var elapsedText: String {
    let total = Int(elapsed)
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  func start() async -> Bool {
    guard !isRecording else { return true }
    guard !isStarting, !isStopping else { return false }
    guard !hasRecoverableRecording else {
      errorMessage = "Save the captured transcript before starting another recording."
      return false
    }

    let operationEpoch = advanceSessionEpoch()
    let attemptID = UUID()
    startAttemptID = attemptID
    isStarting = true
    defer {
      if startAttemptID == attemptID {
        startAttemptID = nil
        isStarting = false
      }
    }

    errorMessage = nil

    #if targetEnvironment(simulator)
    if ProcessInfo.processInfo.arguments.contains("--simulate-recorder") {
      startSimulatedRecording(sessionEpoch: operationEpoch)
      return true
    }
    guard ProcessInfo.processInfo.arguments.contains("--allow-simulator-microphone") else {
      errorMessage = "The iOS Simulator microphone route is unavailable. Recording works on a physical iPhone."
      return false
    }
    #endif

    let hasSpeechPermission = await MobileRecordingPermissionBridge.requestSpeechAuthorization()
    guard ownsStart(attemptID: attemptID, sessionEpoch: operationEpoch),
          !Task.isCancelled
    else { return false }
    guard hasSpeechPermission else {
      errorMessage = "Speech recognition permission is required."
      return false
    }

    let hasMicrophonePermission = await MobileRecordingPermissionBridge.requestMicrophoneAuthorization()
    guard ownsStart(attemptID: attemptID, sessionEpoch: operationEpoch),
          !Task.isCancelled
    else { return false }
    guard hasMicrophonePermission else {
      errorMessage = "Microphone permission is required."
      return false
    }
    do {
      let session = AVAudioSession.sharedInstance()
      // `.measurement` deliberately minimizes signal processing and performs poorly
      // for a phone placed across a table. The default recording mode retains the
      // system's microphone processing without imposing voice-chat routing behavior.
      try session.setCategory(.record, mode: .default, options: [.duckOthers])
      try session.setActive(true, options: .notifyOthersOnDeactivation)

      guard session.isInputAvailable,
            session.inputNumberOfChannels > 0,
            !session.currentRoute.inputs.isEmpty
      else {
        throw MobileMeetingRecorderError.noMicrophoneInput
      }

      transcriptSession.reset()
      transcript = ""
      levels = []
      elapsed = 0
      recognitionDidComplete = false
      consecutiveRecognitionFailures = 0

      let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
      guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
        throw MobileMeetingRecorderError.noMicrophoneInput
      }

      let speechAnalyzerIsAvailable: Bool
      if #available(iOS 26.0, *) {
        speechAnalyzerIsAvailable = await MobileSpeechAnalyzerSession.isSupported(
          locale: .autoupdatingCurrent
        )
      } else {
        speechAnalyzerIsAvailable = false
      }
      guard ownsStart(attemptID: attemptID, sessionEpoch: operationEpoch),
            !Task.isCancelled
      else {
        throw CancellationError()
      }

      let capabilities = EdgeTranscriptionEngineCapabilities(
        speechAnalyzerIsAvailable: speechAnalyzerIsAvailable,
        legacyRecognizerIsAvailable: recognizer?.isAvailable == true,
        legacyRecognizerSupportsOnDeviceRecognition:
          recognizer?.supportsOnDeviceRecognition == true
      )
      let selection = EdgeTranscriptionEngineSelector.select(from: capabilities)

      switch selection {
      case .selected(.speechAnalyzer):
        do {
          if #available(iOS 26.0, *) {
            try await startSpeechAnalyzerCapture(
              inputFormat: inputFormat,
              attemptID: attemptID,
              sessionEpoch: operationEpoch
            )
          } else {
            throw MobileMeetingRecorderError.onDeviceRecognitionUnavailable
          }
        } catch {
          if error is CancellationError { throw error }
          guard ownsStart(attemptID: attemptID, sessionEpoch: operationEpoch),
                !Task.isCancelled
          else { throw CancellationError() }
          // Model installation or preparation can fail independently of legacy local
          // recognition. Falling back here remains fully on device.
          guard let recognizer,
                recognizer.isAvailable,
                recognizer.supportsOnDeviceRecognition
          else { throw error }
          isRecording = true
          try startRecognitionCycle(using: recognizer)
        }
      case .selected(.legacyOnDeviceSpeech):
        guard let recognizer else {
          throw MobileMeetingRecorderError.onDeviceRecognitionUnavailable
        }
        isRecording = true
        try startRecognitionCycle(using: recognizer)
      case .unavailable:
        throw MobileMeetingRecorderError.onDeviceRecognitionUnavailable
      }

      guard ownsStart(attemptID: attemptID, sessionEpoch: operationEpoch),
            !Task.isCancelled
      else { throw CancellationError() }

      startedAt = Date()
      isRecording = true
      hasRecoverableRecording = true
      startElapsedTimer(sessionEpoch: operationEpoch)
      return true
    } catch {
      // A superseded start owns no shared cleanup. Its local analyzer is canceled by
      // the helper, while the newer attempt remains untouched.
      if ownsStart(attemptID: attemptID, sessionEpoch: operationEpoch) {
        stopAudio()
        if !(error is CancellationError) {
          errorMessage = error.localizedDescription
        }
      }
      return false
    }
  }

  func stop() async -> String {
    // `start()` may be suspended in a permission or analyzer-availability await.
    // Treat Stop as cancellation of that attempt, and invalidate it before a
    // subsequent start is allowed to claim the recorder.
    if isStarting {
      _ = advanceSessionEpoch()
      startAttemptID = nil
      isStarting = false
      stopAudio()
      return ""
    }

    let operationEpoch = sessionEpoch

    if isStopping {
      while isStopping, ownsSession(operationEpoch) {
        do {
          try await Task.sleep(for: .milliseconds(20))
        } catch {
          return ""
        }
        guard ownsSession(operationEpoch), !Task.isCancelled else { return "" }
      }
      guard ownsSession(operationEpoch), !Task.isCancelled else { return "" }
      return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard isRecording || request != nil || speechAnalyzerSession != nil || isSimulating else {
      return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let wasActivelyRecording = isRecording
    let engineAtStop = activeEngine
    isStopping = true
    isRecording = false
    restartTask?.cancel()
    restartTask = nil

    // A terminal legacy callback may have started its short service-reset window.
    // Bind a replacement request immediately so buffered audio and the stop tail are
    // still transcribed instead of being abandoned with the canceled restart task.
    if engineAtStop == .legacyOnDeviceSpeech,
       request == nil,
       let recognizer,
       recognizer.isAvailable,
       recognizer.supportsOnDeviceRecognition
    {
      try? startRecognitionCycle(using: recognizer)
    }

    // Snapshot every reference that belongs to this epoch before suspending.
    // Reading these properties after an await could otherwise target a newly
    // started analyzer or recognition request.
    let analyzerSessionAtStop = speechAnalyzerSession
    let analyzerUpdateTaskAtStop = speechAnalyzerUpdateTask
    let requestAtStop = request
    let recognitionTaskAtStop = recognitionTask

    // Keep the microphone open briefly after the UI enters its stopping state. This
    // captures the acoustic tail of a quiet final word and gives endpointing a clean
    // stretch of room tone before the input stream ends.
    if wasActivelyRecording, !isSimulating {
      do {
        try await Task.sleep(for: Self.captureTailDuration)
      } catch {
        return interruptedStopResult(sessionEpoch: operationEpoch) ?? ""
      }
      if let interrupted = interruptedStopResult(sessionEpoch: operationEpoch) {
        return interrupted
      }
    }
    if let interrupted = interruptedStopResult(sessionEpoch: operationEpoch) {
      return interrupted
    }
    stopAudioCapture()

    switch engineAtStop {
    case .speechAnalyzer:
      if let analyzerSessionAtStop {
        do {
          try await finishSpeechAnalyzerSession(analyzerSessionAtStop)
          if let interrupted = interruptedStopResult(sessionEpoch: operationEpoch) {
            return interrupted
          }
        } catch {
          if let interrupted = interruptedStopResult(sessionEpoch: operationEpoch) {
            return interrupted
          }
          errorMessage = "The recording was saved, but final transcription could not finish: \(error.localizedDescription)"
          await analyzerSessionAtStop.cancel()
          if let interrupted = interruptedStopResult(sessionEpoch: operationEpoch) {
            return interrupted
          }
        }
      }
      if let analyzerUpdateTaskAtStop {
        await analyzerUpdateTaskAtStop.value
        if let interrupted = interruptedStopResult(sessionEpoch: operationEpoch) {
          return interrupted
        }
      }
      speechAnalyzerUpdateTask = nil
      speechAnalyzerAudioBridge = nil
      speechAnalyzerSession = nil

    case .legacyOnDeviceSpeech:
      let shouldDrainRecognition = recognitionTaskAtStop != nil
      requestAtStop?.endAudio()
      recognitionTaskAtStop?.finish()

      if shouldDrainRecognition {
        let drained = await drainFinalRecognitionResult(sessionEpoch: operationEpoch)
        if let interrupted = interruptedStopResult(sessionEpoch: operationEpoch) {
          return interrupted
        }
        guard drained else { return "" }
      }
      if let interrupted = interruptedStopResult(sessionEpoch: operationEpoch) {
        return interrupted
      }
      transcript = transcriptSession.stop()

    case nil:
      transcript = transcriptSession.stop()
    }

    if let interrupted = interruptedStopResult(sessionEpoch: operationEpoch) {
      return interrupted
    }
    tearDownRecognitionAndSession(cancelTask: false)
    isStopping = false
    return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func reset() {
    // Invalidate suspended starts/stops before touching any shared resources.
    _ = advanceSessionEpoch()
    startAttemptID = nil
    isStarting = false
    isRecording = false
    isStopping = false
    stopAudioCapture()
    tearDownRecognitionAndSession(cancelTask: true)
    transcriptSession.reset()
    hasRecoverableRecording = false
    transcript = ""
    elapsed = 0
    errorMessage = nil
    levels = []
  }

  private func stopAudio() {
    isRecording = false
    stopAudioCapture()
    tearDownRecognitionAndSession(cancelTask: true)
  }

  private func stopAudioCapture() {
    timer?.invalidate()
    timer = nil
    if audioEngine.isRunning { audioEngine.stop() }
    if inputTapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      inputTapInstalled = false
    }
  }

  private func tearDownRecognitionAndSession(cancelTask: Bool) {
    restartTask?.cancel()
    restartTask = nil

    let analyzerToCancel = speechAnalyzerSession
    speechAnalyzerUpdateTask?.cancel()
    speechAnalyzerUpdateTask = nil
    speechAnalyzerAudioBridge = nil
    speechAnalyzerSession = nil
    if cancelTask, let analyzerToCancel {
      Task {
        await analyzerToCancel.cancel()
      }
    }

    invalidateRecognitionCycle(cancelTask: cancelTask)
    activeEngine = nil
    isSimulating = false
    recognitionDidComplete = true
    startedAt = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  @available(iOS 26.0, *)
  private func startSpeechAnalyzerCapture(
    inputFormat: AVAudioFormat,
    attemptID: UUID,
    sessionEpoch operationEpoch: UInt64
  ) async throws {
    let analyzerSession = try await MobileSpeechAnalyzerSession.start(
      locale: .autoupdatingCurrent,
      microphoneFormat: inputFormat
    )
    guard !Task.isCancelled,
          ownsStart(attemptID: attemptID, sessionEpoch: operationEpoch)
    else {
      await analyzerSession.cancel()
      throw CancellationError()
    }

    recognitionGeneration += 1
    let generation = recognitionGeneration
    activeEngine = .speechAnalyzer
    speechAnalyzerSession = analyzerSession
    recognitionDidComplete = false

    let updateStream = analyzerSession.updates
    speechAnalyzerUpdateTask = Task { @MainActor [weak self] in
      do {
        for try await update in updateStream {
          guard let self else { return }
          self.receiveSpeechAnalyzer(update: update, generation: generation)
        }
        guard let self,
              !Task.isCancelled,
              self.isRecording,
              !self.isStopping
        else { return }
        self.errorMessage = "On-device transcription ended unexpectedly. The transcript recorded so far was preserved."
        self.stopAudio()
      } catch {
        guard let self,
              !Task.isCancelled,
              self.isRecording,
              !self.isStopping
        else { return }
        self.errorMessage = error.localizedDescription
        self.stopAudio()
      }
    }

    let input = audioEngine.inputNode
    let bridge = MobileSpeechAnalyzerAudioBridge(
      recorder: self,
      session: analyzerSession,
      generation: generation
    )
    speechAnalyzerAudioBridge = bridge
    input.installTap(onBus: 0, bufferSize: 768, format: inputFormat, block: bridge.audioTap)
    inputTapInstalled = true
    isRecording = true

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      input.removeTap(onBus: 0)
      inputTapInstalled = false
      isRecording = false
      speechAnalyzerUpdateTask?.cancel()
      speechAnalyzerUpdateTask = nil
      speechAnalyzerAudioBridge = nil
      speechAnalyzerSession = nil
      activeEngine = nil
      await analyzerSession.cancel()
      guard ownsStart(attemptID: attemptID, sessionEpoch: operationEpoch),
            !Task.isCancelled
      else { throw CancellationError() }
      throw error
    }
  }

  private func receiveSpeechAnalyzer(
    update: MobileSpeechAnalyzerSession.Update,
    generation: Int
  ) {
    guard activeEngine == .speechAnalyzer,
          generation == recognitionGeneration,
          isRecording || isStopping
    else { return }

    // SpeechAnalyzerSession already reduces every raw range into one complete
    // snapshot before coalescing UI delivery. Publishing that snapshot directly
    // avoids replaying superseded volatile phrases through @Published.
    guard transcript != update.transcript else { return }
    transcript = update.transcript
  }

  private func startRecognitionCycle(using recognizer: SFSpeechRecognizer) throws {
    guard recognizer.isAvailable else {
      throw MobileMeetingRecorderError.recognitionUnavailable
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw MobileMeetingRecorderError.onDeviceRecognitionUnavailable
    }

    let preservesCaptureTap = inputTapInstalled && legacyAudioBridge != nil
    invalidateRecognitionCycle(
      cancelTask: true,
      preservingAudioTap: preservesCaptureTap
    )

    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw MobileMeetingRecorderError.noMicrophoneInput
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    request.addsPunctuation = true
    request.requiresOnDeviceRecognition = true
    self.request = request
    activeEngine = .legacyOnDeviceSpeech

    recognitionGeneration += 1
    let generation = recognitionGeneration
    transcript = transcriptSession.beginCycle(generation: generation)
    let bridge = MobileRecorderCallbackBridge(
      recorder: self,
      generation: generation
    )
    callbackBridge = bridge
    if let legacyAudioBridge, inputTapInstalled {
      legacyAudioBridge.bind(request: request, generation: generation)
    } else {
      let audioBridge = MobileLegacySpeechAudioBridge(
        recorder: self,
        inputFormat: format
      )
      audioBridge.bind(request: request, generation: generation)
      legacyAudioBridge = audioBridge
      input.installTap(onBus: 0, bufferSize: 768, format: format, block: audioBridge.audioTap)
      inputTapInstalled = true
    }

    if !audioEngine.isRunning {
      audioEngine.prepare()
      do {
        try audioEngine.start()
      } catch {
        input.removeTap(onBus: 0)
        inputTapInstalled = false
        legacyAudioBridge?.clear()
        legacyAudioBridge = nil
        self.request = nil
        bridge.finishDelivery()
        callbackBridge = nil
        throw error
      }
    }

    recognitionDidComplete = false
    recognitionTask = recognizer.recognitionTask(
      with: request,
      resultHandler: bridge.recognitionHandler
    )
  }

  private func invalidateRecognitionCycle(
    cancelTask: Bool,
    preservingAudioTap: Bool = false
  ) {
    recognitionGeneration += 1
    if preservingAudioTap {
      legacyAudioBridge?.unbind()
    } else {
      if inputTapInstalled {
        audioEngine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
      }
      legacyAudioBridge?.clear()
      legacyAudioBridge = nil
    }
    request?.endAudio()
    if cancelTask {
      recognitionTask?.cancel()
    } else {
      recognitionTask?.finish()
    }
    callbackBridge?.finishDelivery()
    request = nil
    recognitionTask = nil
    callbackBridge = nil
  }

  private func scheduleRecognitionRestart() {
    guard isRecording,
          !isStopping,
          !isSimulating,
          restartTask == nil
    else { return }
    transcript = transcriptSession.finishCycle(generation: recognitionGeneration)
    restartTask?.cancel()
    // This path is reached only after a terminal callback. Never cancel a healthy task
    // because quiet far-field speech may still be waiting for its final refinement.
    invalidateRecognitionCycle(cancelTask: false, preservingAudioTap: true)
    let invalidatedGeneration = recognitionGeneration
    let locale = recognizer?.locale ?? Locale.autoupdatingCurrent

    restartTask = Task { @MainActor [weak self] in
      // This task starts on the MainActor turn after Speech's terminal callback.
      // Avoid an additional fixed quiet period so the still-running audio bridge can
      // immediately feed the replacement recognizer.
      await Task.yield()
      guard let self,
            !Task.isCancelled,
            self.isRecording,
            !self.isStopping,
            self.recognitionGeneration == invalidatedGeneration
      else { return }
      guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
        self.restartTask = nil
        self.errorMessage = MobileMeetingRecorderError.recognitionUnavailable.localizedDescription
        self.stopAudio()
        return
      }

      do {
        // A new recognizer instance prevents the local Speech service from carrying its
        // post-endpoint batching state into the replacement request.
        self.recognizer = recognizer
        try self.startRecognitionCycle(using: recognizer)
        self.restartTask = nil
      } catch {
        self.restartTask = nil
        self.errorMessage = error.localizedDescription
        self.stopAudio()
      }
    }
  }

  private func drainFinalRecognitionResult(
    sessionEpoch operationEpoch: UInt64,
    timeout: Duration = .seconds(3)
  ) async -> Bool {
    guard ownsSession(operationEpoch), !Task.isCancelled else { return false }
    guard !recognitionDidComplete else { return true }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !recognitionDidComplete, clock.now < deadline {
      do {
        try await clock.sleep(for: .milliseconds(20))
      } catch {
        return false
      }
      guard ownsSession(operationEpoch), !Task.isCancelled else { return false }
    }
    return ownsSession(operationEpoch) && !Task.isCancelled
  }

  private func finishSpeechAnalyzerSession(
    _ session: MobileSpeechAnalyzerSession,
    timeout: Duration = .seconds(6)
  ) async throws {
    let (events, continuation) = AsyncStream.makeStream(
      of: MobileSpeechAnalyzerFinishEvent.self,
      bufferingPolicy: .bufferingOldest(1)
    )
    let finishTask = Task {
      do {
        try await session.finish()
        continuation.yield(.finished)
      } catch {
        continuation.yield(.failed(error))
      }
    }
    let timeoutTask = Task {
      do {
        try await Task.sleep(for: timeout)
        continuation.yield(.timedOut)
      } catch {
        // The normal finish path cancels this timer.
      }
    }

    var iterator = events.makeAsyncIterator()
    let event = await iterator.next() ?? .timedOut
    continuation.finish()
    finishTask.cancel()
    timeoutTask.cancel()

    switch event {
    case .finished:
      return
    case let .failed(error):
      throw error
    case .timedOut:
      throw MobileMeetingRecorderError.finalizationTimedOut
    }
  }

  fileprivate func receive(level: CGFloat, generation: Int) {
    guard generation == recognitionGeneration, isRecording || isStopping else { return }
    let previous = levels.last ?? 0.06
    levels.append(max(0.06, previous * 0.48 + level * 0.52))
    if levels.count > Self.waveformHistoryCapacity {
      levels.removeFirst(levels.count - Self.waveformHistoryCapacity)
    }
  }

  fileprivate func receiveRecognition(
    transcript candidate: String?,
    errorMessage candidateError: String?,
    errorDomain: String?,
    errorCode: Int?,
    isFinal: Bool,
    sequence: Int,
    startOffset: TimeInterval?,
    endOffset: TimeInterval?,
    generation: Int
  ) {
    guard generation == recognitionGeneration, isRecording || isStopping else { return }

    if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      transcript = transcriptSession.receive(
        generation: generation,
        sequence: sequence,
        candidate: candidate,
        startOffset: startOffset,
        endOffset: endOffset,
        isFinal: isFinal
      )
      consecutiveRecognitionFailures = 0
    } else if isFinal {
      transcript = transcriptSession.receive(
        generation: generation,
        sequence: sequence,
        candidate: nil,
        startOffset: startOffset,
        endOffset: endOffset,
        isFinal: true
      )
    }

    if isFinal {
      recognitionDidComplete = true
      scheduleRecognitionRestart()
      return
    }

    guard let candidateError else { return }
    recognitionDidComplete = true
    transcript = transcriptSession.finishCycle(generation: generation)
    guard isRecording else { return }

    let isNoSpeech = errorDomain == "kAFAssistantErrorDomain" && errorCode == 1110
    if isNoSpeech {
      scheduleRecognitionRestart()
      return
    }

    consecutiveRecognitionFailures += 1
    if consecutiveRecognitionFailures <= 3 {
      scheduleRecognitionRestart()
    } else {
      errorMessage = candidateError
      stopAudio()
    }
  }

  private func startElapsedTimer(sessionEpoch operationEpoch: UInt64) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self,
              self.ownsSession(operationEpoch),
              let startedAt
        else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        guard isSimulating else { return }

        let simulatedFirstWordDelay: TimeInterval
        if ProcessInfo.processInfo.arguments.contains("--simulate-listening-placeholder") {
          simulatedFirstWordDelay = 30
        } else if ProcessInfo.processInfo.arguments.contains("--simulate-delayed-first-word") {
          simulatedFirstWordDelay = 2
        } else {
          simulatedFirstWordDelay = 0
        }
        let simulatesResumedPartials = ProcessInfo.processInfo.arguments.contains(
          "--simulate-resumed-partials"
        )
        if simulatesResumedPartials {
          let resumedPartialTimeScale = ProcessInfo.processInfo.arguments.contains(
            "--hold-resumed-partials"
          ) ? 10.0 : 1.0
          while simulatedPhraseIndex < Self.simulatedResumedPartialEvents.count,
                elapsed >= Self.simulatedResumedPartialEvents[simulatedPhraseIndex].time
                  * resumedPartialTimeScale + simulatedFirstWordDelay
          {
            let event = Self.simulatedResumedPartialEvents[simulatedPhraseIndex]
            if event.startsNewCycle {
              recognitionGeneration += 1
              simulatedCallbackSequence = 0
              transcript = transcriptSession.beginCycle(generation: recognitionGeneration)
            }
            transcript = transcriptSession.receive(
              generation: recognitionGeneration,
              sequence: simulatedCallbackSequence,
              candidate: event.candidate,
              startOffset: event.startOffset,
              endOffset: event.endOffset,
              isFinal: event.isFinal
            )
            simulatedPhraseIndex += 1
            simulatedCallbackSequence += 1
          }
        } else {
          let simulatesGrowingPartials = ProcessInfo.processInfo.arguments.contains(
            "--simulate-growing-partials"
          )
          let simulatedCandidates: [String]
          if ProcessInfo.processInfo.arguments.contains("--simulate-agent-request-partials") {
            simulatedCandidates = Self.simulatedAgentRequestPartials
          } else if simulatesGrowingPartials {
            simulatedCandidates = Self.simulatedGrowingPartials
          } else {
            simulatedCandidates = Self.simulatedTranscriptPhrases
          }
          let candidateInterval = simulatesGrowingPartials ? 0.55 : 1.5
          let simulatedSpeechElapsed = max(0, elapsed - simulatedFirstWordDelay)
          let phraseCount = elapsed < simulatedFirstWordDelay
            ? 0
            : min(
              simulatedCandidates.count,
              max(1, Int(simulatedSpeechElapsed / candidateInterval) + 1)
            )
          while simulatedPhraseIndex < phraseCount {
            let phraseIndex = simulatedPhraseIndex
            let phraseStart = Double(phraseIndex) * (simulatesGrowingPartials ? 0.1 : 1.5)
            transcript = transcriptSession.receive(
              generation: recognitionGeneration,
              sequence: simulatedCallbackSequence,
              candidate: simulatedCandidates[phraseIndex],
              startOffset: phraseStart,
              endOffset: simulatesGrowingPartials ? phraseStart : phraseStart + 1,
              isFinal: false
            )
            simulatedPhraseIndex += 1
            simulatedCallbackSequence += 1
          }
        }
        let simulatesAutomaticSilence = ProcessInfo.processInfo.arguments.contains(
          "--simulate-auto-silence"
        )
        let expectedSimulatedPhraseCount: Int
        if ProcessInfo.processInfo.arguments.contains("--simulate-agent-request-partials") {
          expectedSimulatedPhraseCount = Self.simulatedAgentRequestPartials.count
        } else if ProcessInfo.processInfo.arguments.contains("--simulate-growing-partials") {
          expectedSimulatedPhraseCount = Self.simulatedGrowingPartials.count
        } else if ProcessInfo.processInfo.arguments.contains("--simulate-resumed-partials") {
          expectedSimulatedPhraseCount = Self.simulatedResumedPartialEvents.count
        } else {
          expectedSimulatedPhraseCount = Self.simulatedTranscriptPhrases.count
        }
        let simulatedSpeechIsComplete = simulatedPhraseIndex >= expectedSimulatedPhraseCount
        let pulse = CGFloat((sin(elapsed * 4.2) + 1) / 2)
        let simulatedLevel: CGFloat = simulatesAutomaticSilence && simulatedSpeechIsComplete
          ? 0.06
          : 0.18 + pulse * 0.64
        receive(level: simulatedLevel, generation: recognitionGeneration)
      }
    }
  }

  #if targetEnvironment(simulator)
  private func startSimulatedRecording(sessionEpoch operationEpoch: UInt64) {
    transcriptSession.reset()
    transcript = ""
    levels = ProcessInfo.processInfo.arguments.contains("--simulate-waveform-history")
      ? Self.simulatedWaveformHistory
      : []
    elapsed = 0
    startedAt = Date()
    isSimulating = true
    isRecording = true
    hasRecoverableRecording = true
    recognitionDidComplete = false
    consecutiveRecognitionFailures = 0
    simulatedPhraseIndex = 0
    simulatedCallbackSequence = 0
    recognitionGeneration += 1
    transcript = transcriptSession.beginCycle(generation: recognitionGeneration)
    startElapsedTimer(sessionEpoch: operationEpoch)
  }
  #endif

  @discardableResult
  private func advanceSessionEpoch() -> UInt64 {
    sessionEpoch &+= 1
    return sessionEpoch
  }

  private func ownsSession(_ operationEpoch: UInt64) -> Bool {
    operationEpoch == sessionEpoch
  }

  private func ownsStart(attemptID: UUID, sessionEpoch operationEpoch: UInt64) -> Bool {
    startAttemptID == attemptID && ownsSession(operationEpoch)
  }

  /// Returns a terminal result when an async stop is no longer allowed to
  /// continue. A superseded epoch owns nothing and returns no transcript. A
  /// canceled stop that still owns the current epoch performs synchronous,
  /// cancellation-safe teardown so it cannot strand the microphone or leave
  /// `isStopping` latched forever.
  private func interruptedStopResult(sessionEpoch operationEpoch: UInt64) -> String? {
    guard ownsSession(operationEpoch) else { return "" }
    guard Task.isCancelled else { return nil }

    stopAudioCapture()
    switch activeEngine {
    case .speechAnalyzer:
      break
    case .legacyOnDeviceSpeech, nil:
      transcript = transcriptSession.stop()
    }
    tearDownRecognitionAndSession(cancelTask: true)
    isStopping = false
    return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let simulatedTranscriptPhrases = [
    "We reviewed the mobile recorder and agreed to keep capture fast and reliable.",
    "The meeting note should separate a concise summary from the full transcript.",
    "Maya will share the revised interaction spec by Friday.",
    "Jordan will validate the call-audio source labels on the Mac capture path.",
  ]

  private static let simulatedGrowingPartials = [
    "When",
    "When I",
    "When I make",
    "When I make meeting",
    "When I make meeting notes",
    "When I make meeting notes every",
    "When I make meeting notes every word",
    "When I make meeting notes every word stays",
    "When I make meeting notes every word stays once.",
  ]

  private static let simulatedAgentRequestPartials = [
    "Plan",
    "Plan my",
    "Plan my day",
  ]

  private struct SimulatedTranscriptEvent {
    let time: TimeInterval
    let candidate: String
    let startOffset: TimeInterval
    let endOffset: TimeInterval
    let isFinal: Bool
    let startsNewCycle: Bool
  }

  private static let simulatedResumedPartialEvents = [
    SimulatedTranscriptEvent(
      time: 0.25,
      candidate: "First",
      startOffset: 0,
      endOffset: 0,
      isFinal: false,
      startsNewCycle: false
    ),
    SimulatedTranscriptEvent(
      time: 0.75,
      candidate: "First segment",
      startOffset: 0.1,
      endOffset: 0.1,
      isFinal: false,
      startsNewCycle: false
    ),
    SimulatedTranscriptEvent(
      time: 1.25,
      candidate: "First segment updates live.",
      startOffset: 0.2,
      endOffset: 0.2,
      isFinal: true,
      startsNewCycle: false
    ),
    SimulatedTranscriptEvent(
      time: 2.75,
      candidate: "Resumed",
      startOffset: 0,
      endOffset: 0,
      isFinal: false,
      startsNewCycle: true
    ),
    SimulatedTranscriptEvent(
      time: 3.25,
      candidate: "Resumed speech",
      startOffset: 0.1,
      endOffset: 0.1,
      isFinal: false,
      startsNewCycle: false
    ),
    SimulatedTranscriptEvent(
      time: 3.75,
      candidate: "Resumed speech updates",
      startOffset: 0.2,
      endOffset: 0.2,
      isFinal: false,
      startsNewCycle: false
    ),
    SimulatedTranscriptEvent(
      time: 4.25,
      candidate: "Resumed speech updates live.",
      startOffset: 0.3,
      endOffset: 0.3,
      isFinal: true,
      startsNewCycle: false
    ),
  ]

  private static let simulatedWaveformHistory: [CGFloat] = {
    var state: UInt64 = 0x4D_45_45_54_49_4E_47
    return (0 ..< waveformHistoryCapacity).map { index in
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let noise = Double((state >> 32) & 0xFFFF) / Double(UInt16.max)
      let contour = (sin(Double(index) * 0.173) + 1) / 2
      return CGFloat(0.09 + min(0.82, noise * 0.48 + contour * 0.34))
    }
  }()
}

private enum MobileSpeechAnalyzerFinishEvent: @unchecked Sendable {
  case finished
  case failed(any Error)
  case timedOut
}

private enum MobileMeetingRecorderError: LocalizedError {
  case noMicrophoneInput
  case recognitionUnavailable
  case onDeviceRecognitionUnavailable
  case finalizationTimedOut

  var errorDescription: String? {
    switch self {
    case .noMicrophoneInput:
      "No microphone input is available. Check the current audio route and try again."
    case .recognitionUnavailable:
      "Speech recognition is temporarily unavailable."
    case .onDeviceRecognitionUnavailable:
      "On-device transcription is unavailable for this language or device. No audio was sent to a server."
    case .finalizationTimedOut:
      "Final transcription took too long. The partial transcript was preserved."
    }
  }
}

private enum MobileRecordingPermissionBridge {
  nonisolated static func requestSpeechAuthorization() async -> Bool {
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

  nonisolated static func requestMicrophoneAuthorization() async -> Bool {
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

private final class MobileRecorderLevelThrottle: @unchecked Sendable {
  private let lock = NSLock()
  private var lastDeliveryTime: TimeInterval = 0

  func shouldDeliver(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard now - lastDeliveryTime >= 0.05 else { return false }
    lastDeliveryTime = now
    return true
  }
}

private final class MobileLegacySpeechAudioBridge: @unchecked Sendable {
  private struct Target {
    let request: SFSpeechAudioBufferRecognitionRequest
    let generation: Int
  }

  private weak var recorder: MobileMeetingRecorder?
  private let lock = NSLock()
  private let maximumPendingFrames: AVAudioFramePosition
  private let levelThrottle = MobileRecorderLevelThrottle()
  private var target: Target?
  private var mostRecentGeneration = 0
  private var pendingBuffers: [AVAudioPCMBuffer] = []
  private var pendingFrameCount: AVAudioFramePosition = 0

  init(recorder: MobileMeetingRecorder, inputFormat: AVAudioFormat) {
    self.recorder = recorder
    maximumPendingFrames = AVAudioFramePosition(max(1, inputFormat.sampleRate))
  }

  func bind(request: SFSpeechAudioBufferRecognitionRequest, generation: Int) {
    lock.lock()
    for buffer in pendingBuffers {
      request.append(buffer)
    }
    pendingBuffers.removeAll(keepingCapacity: true)
    pendingFrameCount = 0
    mostRecentGeneration = generation
    target = Target(request: request, generation: generation)
    lock.unlock()
  }

  func unbind() {
    lock.lock()
    target = nil
    lock.unlock()
  }

  func clear() {
    lock.lock()
    target = nil
    pendingBuffers.removeAll(keepingCapacity: false)
    pendingFrameCount = 0
    lock.unlock()
  }

  lazy var audioTap: AVAudioNodeTapBlock = { [weak self] buffer, _ in
    guard let self else { return }

    lock.lock()
    let generation: Int
    if let target {
      target.request.append(buffer)
      generation = target.generation
    } else {
      if let snapshot = buffer.copy() as? AVAudioPCMBuffer {
        pendingBuffers.append(snapshot)
        pendingFrameCount += AVAudioFramePosition(snapshot.frameLength)
        while pendingFrameCount > maximumPendingFrames, pendingBuffers.count > 1 {
          pendingFrameCount -= AVAudioFramePosition(pendingBuffers.removeFirst().frameLength)
        }
      }
      generation = mostRecentGeneration
    }
    lock.unlock()

    guard levelThrottle.shouldDeliver() else { return }
    let level = MobileRecorderAudioLevel.normalized(from: buffer)
    Task { @MainActor [weak recorder] in
      recorder?.receive(level: level, generation: generation)
    }
  }
}

private final class MobileSpeechAnalyzerAudioBridge: @unchecked Sendable {
  private weak var recorder: MobileMeetingRecorder?
  private let session: MobileSpeechAnalyzerSession
  private let generation: Int
  private let levelThrottle = MobileRecorderLevelThrottle()

  init(
    recorder: MobileMeetingRecorder,
    session: MobileSpeechAnalyzerSession,
    generation: Int
  ) {
    self.recorder = recorder
    self.session = session
    self.generation = generation
  }

  lazy var audioTap: AVAudioNodeTapBlock = { [weak self] buffer, _ in
    guard let self else { return }
    _ = session.append(buffer)
    guard levelThrottle.shouldDeliver() else { return }
    let level = MobileRecorderAudioLevel.normalized(from: buffer)
    let generation = self.generation
    Task { @MainActor [weak recorder] in
      recorder?.receive(level: level, generation: generation)
    }
  }
}

private struct MobileRecorderRecognitionEvent: Sendable {
  let transcript: String?
  let errorMessage: String?
  let errorDomain: String?
  let errorCode: Int?
  let isFinal: Bool
  let sequence: Int
  let startOffset: TimeInterval?
  let endOffset: TimeInterval?
  let generation: Int
}

private final class MobileRecorderCallbackBridge: @unchecked Sendable {
  private weak var recorder: MobileMeetingRecorder?
  private let generation: Int
  private let eventLock = NSLock()
  private let eventContinuation: AsyncStream<MobileRecorderRecognitionEvent>.Continuation
  private var deliveryTask: Task<Void, Never>?
  private var nextSequenceValue = 0
  private var coalescedTranscript: RecognitionTranscriptSession

  init(
    recorder: MobileMeetingRecorder,
    generation: Int
  ) {
    self.recorder = recorder
    self.generation = generation
    var coalescedTranscript = RecognitionTranscriptSession()
    coalescedTranscript.beginCycle(generation: generation)
    self.coalescedTranscript = coalescedTranscript
    let (events, continuation) = AsyncStream.makeStream(
      of: MobileRecorderRecognitionEvent.self,
      // Every event is reduced to a complete current-cycle transcript below. If the
      // MainActor is rendering, only its newest pending snapshot is useful; replaying
      // all superseded partials creates visible lag and duplicate-looking text.
      bufferingPolicy: .bufferingNewest(1)
    )
    eventContinuation = continuation
    deliveryTask = Task { @MainActor [weak recorder] in
      for await event in events {
        guard let recorder else { return }
        recorder.receiveRecognition(
          transcript: event.transcript,
          errorMessage: event.errorMessage,
          errorDomain: event.errorDomain,
          errorCode: event.errorCode,
          isFinal: event.isFinal,
          sequence: event.sequence,
          startOffset: event.startOffset,
          endOffset: event.endOffset,
          generation: event.generation
        )
      }
    }
  }

  lazy var recognitionHandler: (SFSpeechRecognitionResult?, Error?) -> Void = {
    [weak self] result, error in
    guard let self else { return }
    let transcript = result?.bestTranscription.formattedString
    let segments = result?.bestTranscription.segments ?? []
    let startOffset = segments.first?.timestamp
    let endOffset = segments.last.map { $0.timestamp + $0.duration }
    let errorMessage = error?.localizedDescription
    let errorDomain = (error as NSError?)?.domain
    let errorCode = (error as NSError?)?.code
    let isFinal = result?.isFinal == true
    self.enqueue(
      transcript: transcript,
      errorMessage: errorMessage,
      errorDomain: errorDomain,
      errorCode: errorCode,
      isFinal: isFinal,
      startOffset: startOffset,
      endOffset: endOffset
    )
  }

  func finishDelivery() {
    eventLock.lock()
    eventContinuation.finish()
    eventLock.unlock()
  }

  private func enqueue(
    transcript: String?,
    errorMessage: String?,
    errorDomain: String?,
    errorCode: Int?,
    isFinal: Bool,
    startOffset: TimeInterval?,
    endOffset: TimeInterval?
  ) {
    eventLock.lock()
    let sequence = nextSequenceValue
    let transcriptSnapshot = coalescedTranscript.receive(
      generation: generation,
      sequence: sequence,
      candidate: transcript,
      startOffset: startOffset,
      endOffset: endOffset,
      isFinal: isFinal
    )
    let event = MobileRecorderRecognitionEvent(
      transcript: transcriptSnapshot.isEmpty ? nil : transcriptSnapshot,
      errorMessage: errorMessage,
      errorDomain: errorDomain,
      errorCode: errorCode,
      isFinal: isFinal,
      sequence: sequence,
      startOffset: startOffset,
      endOffset: endOffset,
      generation: generation
    )
    nextSequenceValue += 1
    eventContinuation.yield(event)
    eventLock.unlock()
  }

  deinit {
    eventContinuation.finish()
  }
}

private enum MobileRecorderAudioLevel {
  static func normalized(from buffer: AVAudioPCMBuffer) -> CGFloat {
    guard let channel = buffer.floatChannelData?.pointee else { return 0.06 }
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return 0.06 }
    var sum: Float = 0
    for index in 0 ..< frameLength {
      let sample = channel[index]
      sum += sample * sample
    }
    let rms = sqrt(sum / Float(frameLength))
    let decibels = 20 * log10(max(rms, 0.000_01))
    return CGFloat(min(1, max(0.06, (decibels + 52) / 42)))
  }
}

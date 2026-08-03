@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import Speech

enum MeetingCaptureState: Equatable, Sendable {
  case idle
  case preparing
  case listening
  case stopping
  case failed(String)

  var isActive: Bool {
    switch self {
    case .preparing, .listening, .stopping: true
    case .idle, .failed: false
    }
  }
}

enum MeetingTranscriptSource: String, Sendable {
  case meeting = "Live"
  case microphone = "You"
}

struct MeetingCaptureError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

private final class MeetingSpeechTranscriber: @unchecked Sendable {
  private let source: MeetingTranscriptSource
  private let queue: DispatchQueue
  private let contextualStrings: [String]
  private let onTranscript: @Sendable (MeetingTranscriptSource, String) -> Void
  private let onError: @Sendable (String) -> Void

  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var accumulator = SpeechTranscriptAccumulator()
  private var generation = 0
  private var consecutiveFailures = 0
  private var stopping = false

  init(
    source: MeetingTranscriptSource,
    contextualStrings: [String],
    onTranscript: @escaping @Sendable (MeetingTranscriptSource, String) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) {
    self.source = source
    self.contextualStrings = contextualStrings
    self.onTranscript = onTranscript
    self.onError = onError
    queue = DispatchQueue(label: "com.platon.iagent.meeting-speech.\(source.rawValue)")
  }

  func start() throws {
    try queue.sync {
      accumulator.reset()
      stopping = false
      consecutiveFailures = 0
      guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
            recognizer.isAvailable
      else {
        throw MeetingCaptureError(
          message: "Speech recognition is unavailable for the current language."
        )
      }
      guard recognizer.supportsOnDeviceRecognition else {
        throw MeetingCaptureError(
          message: "On-device speech recognition is unavailable for the current language."
        )
      }
      self.recognizer = recognizer
      try startRecognitionCycle()
    }
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    queue.async { [weak self] in
      guard let self, !self.stopping else { return }
      self.request?.append(buffer)
    }
  }

  func stop() async -> String {
    queue.sync {
      stopping = true
      request?.endAudio()
      task?.finish()
    }

    // Speech delivers the final hypothesis asynchronously after finish(). Keep the
    // recognition cycle alive briefly so the last phrase is not discarded.
    try? await Task.sleep(for: .milliseconds(1_250))
    return queue.sync {
      let transcript = accumulator.finalizeSegment()
      invalidateRecognitionCycle(cancel: true)
      recognizer = nil
      return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  func cancel() -> String {
    queue.sync {
      stopping = true
      let transcript = accumulator.finalizeSegment()
      invalidateRecognitionCycle(cancel: true)
      recognizer = nil
      return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private func startRecognitionCycle() throws {
    guard let recognizer, recognizer.isAvailable else {
      throw MeetingCaptureError(message: "Speech recognition became unavailable.")
    }

    invalidateRecognitionCycle(cancel: true)
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    request.contextualStrings = contextualStrings
    request.requiresOnDeviceRecognition = true
    self.request = request

    generation += 1
    let currentGeneration = generation
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      let candidate = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let nsError = error as NSError?
      self.queue.async {
        self.receiveRecognition(
          transcript: candidate,
          isFinal: isFinal,
          errorMessage: nsError?.localizedDescription,
          errorDomain: nsError?.domain,
          errorCode: nsError?.code,
          generation: currentGeneration
        )
      }
    }
  }

  private func receiveRecognition(
    transcript candidate: String?,
    isFinal: Bool,
    errorMessage: String?,
    errorDomain: String?,
    errorCode: Int?,
    generation: Int
  ) {
    guard generation == self.generation else { return }

    if let candidate,
       !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      consecutiveFailures = 0
      onTranscript(source, accumulator.update(with: candidate))
    }

    if isFinal {
      onTranscript(source, accumulator.finalizeSegment())
      if !stopping {
        restartRecognitionCycle()
      }
      return
    }

    guard let errorMessage else { return }
    if stopping {
      return
    }
    let isNoSpeech = errorDomain == "kAFAssistantErrorDomain" && errorCode == 1110
    if isNoSpeech {
      restartRecognitionCycle()
      return
    }

    consecutiveFailures += 1
    if consecutiveFailures <= 3 {
      restartRecognitionCycle()
    } else {
      onError(errorMessage)
    }
  }

  private func restartRecognitionCycle() {
    guard !stopping else { return }
    onTranscript(source, accumulator.finalizeSegment())
    do {
      try startRecognitionCycle()
    } catch {
      onError(error.localizedDescription)
    }
  }

  private func invalidateRecognitionCycle(cancel: Bool) {
    generation += 1
    request?.endAudio()
    if cancel {
      task?.cancel()
    } else {
      task?.finish()
    }
    request = nil
    task = nil
  }
}

private final class MeetingAudioMixer: @unchecked Sendable {
  private struct SampleFIFO {
    private var storage: [Float] = []
    private var readIndex = 0

    var count: Int { storage.count - readIndex }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
      storage.append(contentsOf: samples)
    }

    mutating func read(_ frameCount: Int) -> [Float] {
      let available = min(frameCount, count)
      var result = Array(repeating: Float.zero, count: frameCount)
      if available > 0 {
        result.replaceSubrange(
          0 ..< available,
          with: storage[readIndex ..< readIndex + available]
        )
        readIndex += available
      }

      if readIndex >= 8_000, readIndex * 2 >= storage.count {
        storage.removeFirst(readIndex)
        readIndex = 0
      }
      return result
    }
  }

  private struct ConverterState {
    let inputFormat: AVAudioFormat
    let converter: AVAudioConverter
  }

  private final class ConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
      self.buffer = buffer
    }

    func next(
      status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
      guard !supplied else {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
  }

  private let queue = DispatchQueue(
    label: "com.platon.iagent.meeting-audio-mixer",
    qos: .userInitiated
  )
  private let transcriber: MeetingSpeechTranscriber
  private let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!
  private let chunkFrameCount = 800
  private let maximumSkewFrameCount = 2_400

  private var meetingSamples = SampleFIFO()
  private var microphoneSamples = SampleFIFO()
  private var meetingConverter: ConverterState?
  private var microphoneConverter: ConverterState?

  init(transcriber: MeetingSpeechTranscriber) {
    self.transcriber = transcriber
  }

  func append(_ buffer: AVAudioPCMBuffer, source: MeetingTranscriptSource) {
    guard let copy = Self.copy(buffer) else { return }
    queue.async { [weak self] in
      guard let self,
            let converted = self.convert(copy, source: source),
            let channel = converted.floatChannelData?.pointee
      else { return }

      let samples = UnsafeBufferPointer(
        start: channel,
        count: Int(converted.frameLength)
      )
      switch source {
      case .meeting: self.meetingSamples.append(samples)
      case .microphone: self.microphoneSamples.append(samples)
      }
      self.drain(force: false)
    }
  }

  func flush() async {
    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        self?.drain(force: true)
        continuation.resume()
      }
    }
  }

  private func drain(force: Bool) {
    while shouldEmitChunk(force: force) {
      let available = max(meetingSamples.count, microphoneSamples.count)
      let frameCount = force ? min(chunkFrameCount, available) : chunkFrameCount
      guard frameCount > 0,
            let output = AVAudioPCMBuffer(
              pcmFormat: outputFormat,
              frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let channel = output.floatChannelData?.pointee
      else { return }

      let meeting = meetingSamples.read(frameCount)
      let microphone = microphoneSamples.read(frameCount)
      for index in 0 ..< frameCount {
        channel[index] = min(max(meeting[index] + microphone[index], -1), 1)
      }
      output.frameLength = AVAudioFrameCount(frameCount)
      transcriber.append(output)
    }
  }

  private func shouldEmitChunk(force: Bool) -> Bool {
    let meetingCount = meetingSamples.count
    let microphoneCount = microphoneSamples.count
    if force {
      return max(meetingCount, microphoneCount) > 0
    }
    if min(meetingCount, microphoneCount) >= chunkFrameCount {
      return true
    }
    return max(meetingCount, microphoneCount) >= maximumSkewFrameCount
  }

  private func convert(
    _ buffer: AVAudioPCMBuffer,
    source: MeetingTranscriptSource
  ) -> AVAudioPCMBuffer? {
    let state = converterState(for: buffer.format, source: source)
    guard let converter = state?.converter else { return nil }

    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let frameCapacity = AVAudioFrameCount(
      max(1, ceil(Double(buffer.frameLength) * ratio) + 32)
    )
    guard let converted = AVAudioPCMBuffer(
      pcmFormat: outputFormat,
      frameCapacity: frameCapacity
    ) else { return nil }

    let input = ConverterInput(buffer: buffer)
    var conversionError: NSError?
    let status = converter.convert(
      to: converted,
      error: &conversionError
    ) { _, inputStatus in
      input.next(status: inputStatus)
    }
    guard status != .error, conversionError == nil else { return nil }
    return converted
  }

  private func converterState(
    for inputFormat: AVAudioFormat,
    source: MeetingTranscriptSource
  ) -> ConverterState? {
    let existing = source == .meeting ? meetingConverter : microphoneConverter
    if let existing, existing.inputFormat.isEqual(inputFormat) {
      return existing
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      return nil
    }
    let state = ConverterState(inputFormat: inputFormat, converter: converter)
    switch source {
    case .meeting: meetingConverter = state
    case .microphone: microphoneConverter = state
    }
    return state
  }

  private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(
      pcmFormat: buffer.format,
      frameCapacity: buffer.frameLength
    ) else { return nil }
    copy.frameLength = buffer.frameLength

    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for index in 0 ..< min(source.count, destination.count) {
      guard let sourceData = source[index].mData,
            let destinationData = destination[index].mData
      else { continue }
      let byteCount = min(
        Int(source[index].mDataByteSize),
        Int(destination[index].mDataByteSize)
      )
      memcpy(destinationData, sourceData, byteCount)
      destination[index].mDataByteSize = UInt32(byteCount)
    }
    return copy
  }
}

private final class MeetingMicrophoneTapBridge: @unchecked Sendable {
  private weak var service: MeetingCaptureService?
  private let mixer: MeetingAudioMixer
  private var bufferCount = 0

  init(service: MeetingCaptureService, mixer: MeetingAudioMixer) {
    self.service = service
    self.mixer = mixer
  }

  func makeTapBlock() -> AVAudioNodeTapBlock {
    { [weak self] buffer, _ in
      guard let self else { return }
      self.mixer.append(buffer, source: .microphone)
      self.bufferCount += 1
      guard self.bufferCount.isMultiple(of: 2) else { return }
      let level = Self.normalizedLevel(from: buffer)
      Task { @MainActor [weak service] in
        service?.receiveAudioLevel(level, source: .microphone)
      }
    }
  }

  static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
    guard let channel = buffer.floatChannelData?.pointee else { return 0.06 }
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return 0.06 }

    var sum: Float = 0
    for index in 0 ..< frameCount {
      let sample = channel[index]
      sum += sample * sample
    }
    let rms = sqrt(sum / Float(frameCount))
    let decibels = 20 * log10(max(rms, 0.000_001))
    return CGFloat(min(max((decibels + 58) / 50, 0.06), 1))
  }
}

private final class MeetingSystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate,
  @unchecked Sendable
{
  private weak var service: MeetingCaptureService?
  private let mixer: MeetingAudioMixer
  private var bufferCount = 0

  init(service: MeetingCaptureService, mixer: MeetingAudioMixer) {
    self.service = service
    self.mixer = mixer
  }

  func stream(
    _: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .audio,
          let buffer = Self.pcmBuffer(from: sampleBuffer)
    else { return }

    mixer.append(buffer, source: .meeting)
    bufferCount += 1
    guard bufferCount.isMultiple(of: 2) else { return }
    let level = MeetingMicrophoneTapBridge.normalizedLevel(from: buffer)
    Task { @MainActor [weak service] in
      service?.receiveAudioLevel(level, source: .meeting)
    }
  }

  func stream(_: SCStream, didStopWithError error: Error) {
    Task { @MainActor [weak service] in
      service?.receiveCaptureError(error.localizedDescription)
    }
  }

  private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard sampleBuffer.isValid,
          sampleBuffer.numSamples > 0,
          let formatDescription = sampleBuffer.formatDescription,
          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
            formatDescription
          ),
          let format = AVAudioFormat(streamDescription: streamDescription)
    else {
      return nil
    }

    let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
    guard let destination = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: frameCount
    ) else {
      return nil
    }
    destination.frameLength = frameCount

    do {
      return try sampleBuffer.withAudioBufferList { source, _ in
        let target = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        for index in 0 ..< min(source.count, target.count) {
          guard let sourceData = source[index].mData,
                let targetData = target[index].mData
          else { continue }
          let byteCount = min(
            Int(source[index].mDataByteSize),
            Int(target[index].mDataByteSize)
          )
          memcpy(targetData, sourceData, byteCount)
          target[index].mDataByteSize = UInt32(byteCount)
        }
        return destination
      }
    } catch {
      return nil
    }
  }
}

@MainActor
final class MeetingCaptureService: ObservableObject {
  @Published private(set) var state: MeetingCaptureState = .idle
  @Published private(set) var currentEvent: CalendarEventItem?
  @Published private(set) var systemTranscript = ""
  @Published private(set) var microphoneTranscript = ""
  @Published private(set) var latestTranscript = ""
  @Published private(set) var latestSource: MeetingTranscriptSource = .meeting
  @Published private(set) var levels: [CGFloat] = Array(repeating: 0.06, count: 48)
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var currentNote: LocalDocument?
  @Published private(set) var errorMessage: String?
  @Published private(set) var hasReceivedSystemAudio = false
  @Published private(set) var hasReceivedMicrophoneAudio = false
  @Published private(set) var systemRecognitionError: String?
  @Published private(set) var microphoneRecognitionError: String?

  private let documentStore: LocalDocumentStore
  private let microphoneEngine = AVAudioEngine()
  private let systemAudioQueue = DispatchQueue(
    label: "com.platon.iagent.meeting-system-audio",
    qos: .userInitiated
  )
  private var transcriber: MeetingSpeechTranscriber?
  private var audioMixer: MeetingAudioMixer?
  private var microphoneBridge: MeetingMicrophoneTapBridge?
  private var systemOutput: MeetingSystemAudioOutput?
  private var stream: SCStream?
  private var microphoneTapInstalled = false
  private var elapsedTimer: Timer?
  private var startedAt: Date?
  private var persistenceTask: Task<Void, Never>?
  private var latestSystemLevel: CGFloat = 0.06
  private var latestMicrophoneLevel: CGFloat = 0.06
  private var isPreview = false

  init(documentStore: LocalDocumentStore) {
    self.documentStore = documentStore
  }

  var isActive: Bool { state.isActive }
  var isListening: Bool { state == .listening }
  var hasCompactStatus: Bool { state != .idle }

  func dismissFailure() {
    guard case .failed = state else { return }
    state = .idle
    currentEvent = nil
    currentNote = nil
    errorMessage = nil
    levels = Array(repeating: 0.06, count: 48)
  }

  var elapsedText: String {
    let seconds = max(0, Int(elapsed.rounded(.down)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  var displayTranscript: String {
    let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !transcript.isEmpty { return transcript }
    if let errorMessage, !errorMessage.isEmpty { return errorMessage }
    switch state {
    case .preparing: return "Preparing local meeting capture"
    case .stopping: return "Finishing meeting note"
    default: return "Listening for the meeting"
    }
  }

  func start(event: CalendarEventItem) async throws {
    guard !state.isActive else { return }
    resetSession(event: event)
    state = .preparing

    do {
      guard await SpeechPermissionBridge.requestSpeechAuthorization() else {
        throw MeetingCaptureError(
          message: "Speech Recognition permission is required in System Settings > Privacy & Security."
        )
      }
      guard await SpeechPermissionBridge.requestMicrophoneAuthorization() else {
        throw MeetingCaptureError(
          message: "Microphone permission is required in System Settings > Privacy & Security."
        )
      }
      guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
        throw MeetingCaptureError(
          message: "Screen & System Audio Recording permission is required in System Settings > Privacy & Security."
        )
      }

      let contextualStrings = [event.title, event.calendarTitle]
        + (event.location.map { [$0] } ?? [])
      let transcriber = makeTranscriber(
        source: .meeting,
        contextualStrings: contextualStrings
      )
      try transcriber.start()
      self.transcriber = transcriber
      let mixer = MeetingAudioMixer(transcriber: transcriber)
      audioMixer = mixer

      try startMicrophoneCapture(mixer: mixer)
      try await startSystemAudioCapture(mixer: mixer)

      currentNote = try documentStore.save(
        kind: .note,
        title: event.title,
        body: markdownBody(for: event)
      )
      isPreview = false
      state = .listening
      startedAt = Date()
      startElapsedTimer()
    } catch {
      cleanupCapture()
      let message = error.localizedDescription
      errorMessage = message
      state = .failed(message)
      throw error
    }
  }

  func stop() async -> LocalDocument? {
    guard state.isActive else { return currentNote }
    state = .stopping
    elapsedTimer?.invalidate()
    elapsedTimer = nil
    persistenceTask?.cancel()
    persistenceTask = nil

    stopMicrophoneCapture()
    if let stream, !isPreview {
      try? await stream.stopCapture()
    }
    self.stream = nil
    systemOutput = nil

    await audioMixer?.flush()
    if let finalTranscript = await transcriber?.stop(), !finalTranscript.isEmpty {
      systemTranscript = finalTranscript
      latestTranscript = finalTranscript
    }
    transcriber = nil
    audioMixer = nil
    persistNote(finalized: true)

    let note = currentNote
    startedAt = nil
    isPreview = false
    state = .idle
    return note
  }

  func shutdown() {
    guard state.isActive else { return }
    persistenceTask?.cancel()
    persistenceTask = nil
    elapsedTimer?.invalidate()
    elapsedTimer = nil
    stopMicrophoneCapture()
    _ = transcriber?.cancel()
    transcriber = nil
    audioMixer = nil
    persistNote(finalized: true)
    if let stream, !isPreview {
      Task {
        try? await stream.stopCapture()
      }
    }
    self.stream = nil
    systemOutput = nil
    state = .idle
  }

  func startPreview(event: CalendarEventItem) throws {
    shutdown()
    resetSession(event: event)
    isPreview = true
    state = .listening
    systemTranscript = "We reviewed the launch plan and agreed to keep the first release deliberately small. I will send the revised milestones after this meeting."
    latestSource = .meeting
    latestTranscript = systemTranscript
    levels = [
      0.08, 0.12, 0.18, 0.34, 0.62, 0.82, 0.46, 0.28, 0.56, 0.9, 0.68, 0.38,
      0.22, 0.48, 0.76, 0.52, 0.3, 0.64, 0.86, 0.44, 0.26, 0.58, 0.72, 0.36,
      0.2, 0.42, 0.66, 0.4, 0.24, 0.52, 0.78, 0.5, 0.28, 0.44, 0.7, 0.34,
      0.18, 0.38, 0.6, 0.32, 0.16, 0.3, 0.48, 0.24, 0.12, 0.2, 0.14, 0.08,
    ]
    elapsed = 8 * 60 + 42
    currentNote = try documentStore.save(
      kind: .note,
      title: event.title,
      body: markdownBody(for: event)
    )
  }

  func startFailurePreview(event: CalendarEventItem, message: String) {
    shutdown()
    resetSession(event: event)
    errorMessage = message
    state = .failed(message)
  }

  fileprivate func receiveAudioLevel(
    _ level: CGFloat,
    source: MeetingTranscriptSource
  ) {
    guard state == .listening, !isPreview else { return }
    switch source {
    case .meeting:
      hasReceivedSystemAudio = true
      latestSystemLevel = level
    case .microphone:
      hasReceivedMicrophoneAudio = true
      latestMicrophoneLevel = level
    }
    let combined = max(latestSystemLevel, latestMicrophoneLevel)
    let previous = levels.last ?? 0.06
    levels.append(max(0.06, previous * 0.48 + combined * 0.52))
    if levels.count > 48 {
      levels.removeFirst(levels.count - 48)
    }
  }

  fileprivate func receiveCaptureError(_ message: String) {
    guard state.isActive, !isPreview else { return }
    errorMessage = message
  }

  private func resetSession(event: CalendarEventItem) {
    currentEvent = event
    systemTranscript = ""
    microphoneTranscript = ""
    latestTranscript = ""
    latestSource = .meeting
    levels = Array(repeating: 0.06, count: 48)
    elapsed = 0
    currentNote = nil
    errorMessage = nil
    hasReceivedSystemAudio = false
    hasReceivedMicrophoneAudio = false
    systemRecognitionError = nil
    microphoneRecognitionError = nil
    latestSystemLevel = 0.06
    latestMicrophoneLevel = 0.06
  }

  private func makeTranscriber(
    source: MeetingTranscriptSource,
    contextualStrings: [String]
  ) -> MeetingSpeechTranscriber {
    MeetingSpeechTranscriber(
      source: source,
      contextualStrings: contextualStrings,
      onTranscript: { [weak self] source, transcript in
        Task { @MainActor [weak self] in
          self?.receiveTranscript(transcript, source: source)
        }
      },
      onError: { [weak self] message in
        Task { @MainActor [weak self] in
          self?.receiveRecognitionError(message, source: source)
        }
      }
    )
  }

  private func receiveTranscript(
    _ transcript: String,
    source: MeetingTranscriptSource
  ) {
    guard state.isActive, !transcript.isEmpty else { return }
    switch source {
    case .meeting: systemTranscript = transcript
    case .microphone: microphoneTranscript = transcript
    }
    latestSource = source
    latestTranscript = transcript
    schedulePersistence()
  }

  private func receiveRecognitionError(
    _ message: String,
    source: MeetingTranscriptSource
  ) {
    guard state.isActive else { return }
    switch source {
    case .meeting: systemRecognitionError = message
    case .microphone: microphoneRecognitionError = message
    }
    errorMessage = "\(source.rawValue) transcription: \(message)"
    schedulePersistence()
  }

  private func startMicrophoneCapture(
    mixer: MeetingAudioMixer
  ) throws {
    let inputNode = microphoneEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw MeetingCaptureError(message: "No usable microphone input was found.")
    }

    let bridge = MeetingMicrophoneTapBridge(service: self, mixer: mixer)
    microphoneBridge = bridge
    inputNode.installTap(
      onBus: 0,
      bufferSize: 1_024,
      format: format,
      block: bridge.makeTapBlock()
    )
    microphoneTapInstalled = true
    microphoneEngine.prepare()
    do {
      try microphoneEngine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      microphoneTapInstalled = false
      microphoneBridge = nil
      throw MeetingCaptureError(
        message: "Could not start microphone capture: \(error.localizedDescription)"
      )
    }
  }

  private func startSystemAudioCapture(
    mixer: MeetingAudioMixer
  ) async throws {
    let content = try await SCShareableContent.current
    guard let display = preferredDisplay(in: content.displays) else {
      throw MeetingCaptureError(message: "No display is available for system audio capture.")
    }

    let ownApplications = content.applications.filter {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    let filter = SCContentFilter(
      display: display,
      excludingApplications: ownApplications,
      exceptingWindows: []
    )
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 1
    configuration.showsCursor = false
    configuration.capturesAudio = true
    configuration.sampleRate = 16_000
    configuration.channelCount = 1
    configuration.excludesCurrentProcessAudio = true

    let output = MeetingSystemAudioOutput(service: self, mixer: mixer)
    let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
    try stream.addStreamOutput(
      output,
      type: .audio,
      sampleHandlerQueue: systemAudioQueue
    )
    self.systemOutput = output
    self.stream = stream
    try await stream.startCapture()
  }

  private func preferredDisplay(in displays: [SCDisplay]) -> SCDisplay? {
    let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
    let displayID = NSScreen.main?.deviceDescription[screenNumberKey] as? CGDirectDisplayID
    return displays.first(where: { $0.displayID == displayID }) ?? displays.first
  }

  private func stopMicrophoneCapture() {
    if microphoneTapInstalled {
      microphoneEngine.inputNode.removeTap(onBus: 0)
      microphoneTapInstalled = false
    }
    if microphoneEngine.isRunning {
      microphoneEngine.stop()
    }
    microphoneBridge = nil
  }

  private func cleanupCapture() {
    stopMicrophoneCapture()
    _ = transcriber?.cancel()
    transcriber = nil
    audioMixer = nil
    if let stream {
      Task {
        try? await stream.stopCapture()
      }
    }
    self.stream = nil
    systemOutput = nil
    elapsedTimer?.invalidate()
    elapsedTimer = nil
    persistenceTask?.cancel()
    persistenceTask = nil
  }

  private func startElapsedTimer() {
    elapsedTimer?.invalidate()
    elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let startedAt = self.startedAt else { return }
        self.elapsed = Date().timeIntervalSince(startedAt)
      }
    }
    elapsedTimer?.tolerance = 0.02
  }

  private func schedulePersistence() {
    persistenceTask?.cancel()
    persistenceTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(220))
      guard let self, !Task.isCancelled else { return }
      self.persistNote()
      self.persistenceTask = nil
    }
  }

  private func persistNote(finalized: Bool = false) {
    guard let event = currentEvent,
          let note = currentNote
    else { return }

    do {
      currentNote = try documentStore.update(
        note,
        title: event.title,
        body: markdownBody(for: event, finalized: finalized)
      )
    } catch {
      errorMessage = "Could not update meeting note: \(error.localizedDescription)"
    }
  }

  private func markdownBody(
    for event: CalendarEventItem,
    finalized: Bool = false
  ) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale.current
    dateFormatter.dateStyle = .full
    dateFormatter.timeStyle = .none

    let timeFormatter = DateFormatter()
    timeFormatter.locale = Locale.current
    timeFormatter.timeStyle = .short
    let timeRange = "\(timeFormatter.string(from: event.startDate))–\(timeFormatter.string(from: event.endDate))"

    var metadata = [
      "**Date:** \(dateFormatter.string(from: event.startDate))",
      "**Time:** \(timeRange)",
      "**Calendar:** \(event.calendarTitle)",
    ]
    if let location = event.location, !location.isEmpty {
      metadata.append("**Location:** \(location)")
    }

    let transcript = systemTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let transcriptBody = combinedTranscriptBody(transcript, finalized: finalized)
    return """
    \(metadata.joined(separator: "  \n"))

    ## Transcript

    \(transcriptBody)
    """
  }

  private func combinedTranscriptBody(
    _ transcript: String,
    finalized: Bool
  ) -> String {
    guard transcript.isEmpty else { return transcript }
    guard finalized else {
      return "_Listening to microphone and system audio…_"
    }

    if let systemRecognitionError, !systemRecognitionError.isEmpty {
      return "_Transcription error: \(systemRecognitionError)_"
    }

    return hasReceivedSystemAudio || hasReceivedMicrophoneAudio
      ? "_Audio was received, but no speech was recognized._"
      : "_No microphone or system audio was received._"
  }
}

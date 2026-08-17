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

  var canStop: Bool { self == .listening }
  var isPreparing: Bool { self == .preparing }
}

enum MeetingTranscriptSource: String, CaseIterable, Codable, Sendable {
  case meeting
  case microphone

  var displayName: String {
    switch self {
    case .meeting: "Meeting"
    case .microphone: "You"
    }
  }

  var compactLabel: String {
    switch self {
    case .meeting: "Live"
    case .microphone: "You"
    }
  }

  var detailLabel: String {
    switch self {
    case .meeting: "Call audio"
    case .microphone: "Microphone"
    }
  }
}

struct MeetingCaptureError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

private final class MeetingCaptureContinuationGate<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?

  init(_ continuation: CheckedContinuation<Value, Error>) {
    self.continuation = continuation
  }

  func resume(returning value: Value) {
    takeContinuation()?.resume(returning: value)
  }

  func resume(throwing error: Error) {
    takeContinuation()?.resume(throwing: error)
  }

  private func takeContinuation() -> CheckedContinuation<Value, Error>? {
    lock.lock()
    defer { lock.unlock() }
    let result = continuation
    continuation = nil
    return result
  }
}

struct MeetingTranscriptionPiece: Sendable, Equatable {
  let source: MeetingTranscriptSource
  let text: String
}

struct MeetingTranscriptionSnapshot: Sendable, Equatable {
  let transcript: String
  let pieces: [MeetingTranscriptionPiece]
  let errorMessage: String?
}

struct MeetingRecognitionRetryPolicy: Sendable, Equatable {
  enum Decision: Sendable, Equatable {
    case restart(after: TimeInterval)
    case fail
  }

  private(set) var consecutiveFailures = 0

  mutating func receivedTranscript() {
    consecutiveFailures = 0
  }

  mutating func decision(errorDomain: String?, errorCode: Int?) -> Decision {
    if errorDomain == "kAFAssistantErrorDomain", errorCode == 1110 {
      return .restart(after: 0.2)
    }

    consecutiveFailures += 1
    guard consecutiveFailures <= 3 else { return .fail }
    return .restart(after: 0.2 * pow(2, Double(consecutiveFailures - 1)))
  }
}

enum MeetingTranscriptReconciler {
  static func reconcile(
    existing: [MeetingTranscriptSegment],
    snapshot: MeetingTranscriptionSnapshot,
    fallbackSource: MeetingTranscriptSource,
    fallbackStartedAt: TimeInterval
  ) -> [MeetingTranscriptSegment] {
    var segments = existing
    var pieces = snapshot.pieces
    let fallbackTranscript = snapshot.transcript
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if pieces.isEmpty, !fallbackTranscript.isEmpty {
      pieces = [
        MeetingTranscriptionPiece(source: fallbackSource, text: fallbackTranscript),
      ]
    }

    let appendBaseStartedAt: TimeInterval
    if let lastStartedAt = segments.last?.startedAt {
      appendBaseStartedAt = max(lastStartedAt, fallbackStartedAt) + 0.001
    } else {
      appendBaseStartedAt = fallbackStartedAt
    }
    var matchedSegmentIDs: Set<UUID> = []
    var appendedCount = 0
    for piece in pieces {
      let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }

      if let exactIndex = segments.firstIndex(where: {
        !matchedSegmentIDs.contains($0.id)
          && $0.source == piece.source
          && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
      }) {
        segments[exactIndex].isFinal = true
        matchedSegmentIDs.insert(segments[exactIndex].id)
        continue
      }

      if let partialIndex = segments.firstIndex(where: {
        guard !matchedSegmentIDs.contains($0.id),
              $0.source == piece.source,
              !$0.isFinal
        else { return false }
        let existingText = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix(existingText) || existingText.hasPrefix(text)
      }) {
        let existingText = segments[partialIndex].text
          .trimmingCharacters(in: .whitespacesAndNewlines)
        segments[partialIndex].text = text.count >= existingText.count ? text : existingText
        segments[partialIndex].isFinal = true
        matchedSegmentIDs.insert(segments[partialIndex].id)
        continue
      }

      let newSegment = MeetingTranscriptSegment(
        source: piece.source,
        startedAt: appendBaseStartedAt + Double(appendedCount) * 0.001,
        text: text,
        isFinal: true
      )
      segments.append(newSegment)
      matchedSegmentIDs.insert(newSegment.id)
      appendedCount += 1
    }

    return segments.sorted {
      if $0.startedAt == $1.startedAt {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.startedAt < $1.startedAt
    }
  }
}

private final class MeetingSpeechTranscriber: @unchecked Sendable {
  private var source: MeetingTranscriptSource
  private let queue: DispatchQueue
  private let contextualStrings: [String]
  private let onTranscript: @Sendable (
    MeetingTranscriptSource,
    String,
    String,
    Bool
  ) -> Void
  private let onError: @Sendable (MeetingTranscriptSource, String) -> Void

  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var accumulator = SpeechTranscriptAccumulator()
  private var finalizedPieces: [MeetingTranscriptionPiece] = []
  private var generation = 0
  private var retryPolicy = MeetingRecognitionRetryPolicy()
  private var stopping = false
  private var stopContinuation: CheckedContinuation<Void, Never>?
  private var terminalErrorMessage: String?
  private var recognitionTerminated = false

  init(
    source: MeetingTranscriptSource,
    contextualStrings: [String],
    onTranscript: @escaping @Sendable (
      MeetingTranscriptSource,
      String,
      String,
      Bool
    ) -> Void,
    onError: @escaping @Sendable (MeetingTranscriptSource, String) -> Void
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
      finalizedPieces = []
      stopping = false
      retryPolicy = MeetingRecognitionRetryPolicy()
      terminalErrorMessage = nil
      recognitionTerminated = false
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

  func switchSource(to newSource: MeetingTranscriptSource) {
    queue.async { [weak self] in
      guard let self, !self.stopping else { return }
      guard self.source != newSource else {
        self.accumulator.markSpeechResumed()
        return
      }

      self.finalizeCurrentSegment()
      self.source = newSource
      do {
        try self.startRecognitionCycle()
      } catch {
        self.failRecognition(error.localizedDescription)
      }
    }
  }

  func markSpeechResumed() {
    queue.async { [weak self] in
      self?.accumulator.markSpeechResumed()
    }
  }

  func stop() async -> MeetingTranscriptionSnapshot {
    queue.sync {
      stopping = true
      request?.endAudio()
      task?.finish()
    }

    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume()
          return
        }
        if self.recognitionTerminated || self.task == nil {
          continuation.resume()
          return
        }
        self.stopContinuation = continuation
        self.queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
          self?.resumeStopContinuation()
        }
      }
    }

    return queue.sync {
      finalizeCurrentSegment()
      let transcript = SmartDictationFormatter.format(accumulator.text)
      invalidateRecognitionCycle(cancel: true)
      recognizer = nil
      return MeetingTranscriptionSnapshot(
        transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
        pieces: finalizedPieces,
        errorMessage: terminalErrorMessage
      )
    }
  }

  func cancel() -> MeetingTranscriptionSnapshot {
    queue.sync {
      stopping = true
      finalizeCurrentSegment()
      let transcript = SmartDictationFormatter.format(accumulator.text)
      invalidateRecognitionCycle(cancel: true)
      recognizer = nil
      recognitionTerminated = true
      resumeStopContinuation()
      return MeetingTranscriptionSnapshot(
        transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
        pieces: finalizedPieces,
        errorMessage: terminalErrorMessage
      )
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
    request.addsPunctuation = true
    request.contextualStrings = contextualStrings
    request.requiresOnDeviceRecognition = true
    self.request = request
    recognitionTerminated = false

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
      if errorMessage == nil {
        retryPolicy.receivedTranscript()
      }
      let previousCommitted = accumulator.committedTranscript
      let previousSegment = accumulator.segmentTranscript
      let transcript = SmartDictationFormatter.format(accumulator.update(with: candidate))
      if accumulator.committedTranscript != previousCommitted,
         !previousSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        recordFinalizedPiece(previousSegment, transcript: transcript)
      }
      let activeSegment = SmartDictationFormatter.format(accumulator.segmentTranscript)
      if !activeSegment.isEmpty {
        onTranscript(source, transcript, activeSegment, false)
      }
    }

    if let errorMessage {
      let diagnostic = recognitionErrorMessage(
        errorMessage,
        domain: errorDomain,
        code: errorCode
      )
      if stopping {
        terminalErrorMessage = diagnostic
        recognitionTerminated = true
        resumeStopContinuation()
        return
      }

      switch retryPolicy.decision(errorDomain: errorDomain, errorCode: errorCode) {
      case .restart(let delay):
        restartRecognitionCycle(after: delay)
      case .fail:
        failRecognition(diagnostic)
      }
      return
    }

    if isFinal {
      finalizeCurrentSegment()
      if stopping {
        recognitionTerminated = true
        resumeStopContinuation()
      } else {
        restartRecognitionCycle(after: 0)
      }
      return
    }
  }

  private func restartRecognitionCycle(after delay: TimeInterval) {
    guard !stopping else { return }
    finalizeCurrentSegment()
    invalidateRecognitionCycle(cancel: true)
    let restartGeneration = generation
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self,
            !self.stopping,
            restartGeneration == self.generation
      else { return }
      do {
        try self.startRecognitionCycle()
      } catch {
        self.failRecognition(error.localizedDescription)
      }
    }
  }

  @discardableResult
  private func finalizeCurrentSegment() -> String {
    let finalSegment = SmartDictationFormatter.format(accumulator.segmentTranscript)
    let transcript = SmartDictationFormatter.format(accumulator.finalizeSegment())
    recordFinalizedPiece(finalSegment, transcript: transcript)
    return transcript
  }

  private func recordFinalizedPiece(_ rawSegment: String, transcript: String) {
    let segment = SmartDictationFormatter.format(rawSegment)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !segment.isEmpty else { return }
    let piece = MeetingTranscriptionPiece(source: source, text: segment)
    finalizedPieces.append(piece)
    onTranscript(source, transcript, segment, true)
  }

  private func failRecognition(_ message: String) {
    terminalErrorMessage = message
    recognitionTerminated = true
    invalidateRecognitionCycle(cancel: true)
    onError(source, message)
    resumeStopContinuation()
  }

  private func recognitionErrorMessage(
    _ message: String,
    domain: String?,
    code: Int?
  ) -> String {
    guard let domain, let code else { return message }
    if domain == "kAFAssistantErrorDomain", code == 1101 {
      return "Local speech recognition lost its connection (1101)."
    }
    return "\(message) (\(domain) \(code))"
  }

  private func resumeStopContinuation() {
    let continuation = stopContinuation
    stopContinuation = nil
    continuation?.resume()
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
            let channel = converted.floatChannelData?.pointee,
            converted.frameLength > 0
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
  private let sessionGeneration: UInt64
  private var bufferCount = 0

  init(
    service: MeetingCaptureService,
    mixer: MeetingAudioMixer,
    sessionGeneration: UInt64
  ) {
    self.service = service
    self.mixer = mixer
    self.sessionGeneration = sessionGeneration
  }

  func makeTapBlock() -> AVAudioNodeTapBlock {
    { [weak self] buffer, _ in
      guard let self else { return }
      self.mixer.append(buffer, source: .microphone)
      self.bufferCount += 1
      guard self.bufferCount.isMultiple(of: 2) else { return }
      let level = Self.normalizedLevel(from: buffer)
      let sessionGeneration = self.sessionGeneration
      Task { @MainActor [weak service] in
        service?.receiveAudioLevel(
          level,
          source: .microphone,
          sessionGeneration: sessionGeneration
        )
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
  private let sessionGeneration: UInt64
  private var bufferCount = 0

  init(
    service: MeetingCaptureService,
    mixer: MeetingAudioMixer,
    sessionGeneration: UInt64
  ) {
    self.service = service
    self.mixer = mixer
    self.sessionGeneration = sessionGeneration
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
    let sessionGeneration = self.sessionGeneration
    Task { @MainActor [weak service] in
      service?.receiveAudioLevel(
        level,
        source: .meeting,
        sessionGeneration: sessionGeneration
      )
    }
  }

  func stream(_: SCStream, didStopWithError error: Error) {
    let sessionGeneration = sessionGeneration
    Task { @MainActor [weak service] in
      service?.receiveCaptureError(
        error.localizedDescription,
        sessionGeneration: sessionGeneration
      )
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
  @Published private(set) var transcriptSegments: [MeetingTranscriptSegment] = []
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
  private var systemSpeechIsActive = false
  private var microphoneSpeechIsActive = false
  private var lastSystemSpeechActivityAt: Date?
  private var lastMicrophoneSpeechActivityAt: Date?
  private var activeSegmentIDs: [MeetingTranscriptSource: UUID] = [:]
  private var isPreview = false
  private var sessionGeneration: UInt64 = 0

  private let speechLevelThreshold: CGFloat = 0.22
  private let silenceDelay: TimeInterval = 0.7

  init(documentStore: LocalDocumentStore) {
    self.documentStore = documentStore
  }

  var isActive: Bool { state.isActive }
  var isListening: Bool { state == .listening }
  var isPreparing: Bool { state.isPreparing }
  var canStop: Bool { state.canStop }
  var hasCompactStatus: Bool { state != .idle }

  func dismissFailure() {
    guard case .failed = state else { return }
    invalidateSession()
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
    if case let .failed(message) = state { return message }
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
    sessionGeneration &+= 1
    let generation = sessionGeneration
    resetSession(event: event)
    state = .preparing

    do {
      guard await SpeechPermissionBridge.requestSpeechAuthorization() else {
        throw MeetingCaptureError(
          message: "Speech Recognition permission is required in System Settings > Privacy & Security."
        )
      }
      try validatePreparingSession(generation)
      guard await SpeechPermissionBridge.requestMicrophoneAuthorization() else {
        throw MeetingCaptureError(
          message: "Microphone permission is required in System Settings > Privacy & Security."
        )
      }
      try validatePreparingSession(generation)
      guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
        throw MeetingCaptureError(
          message: "Screen & System Audio Recording permission is required in System Settings > Privacy & Security."
        )
      }
      try validatePreparingSession(generation)

      let contextualStrings = [event.title, event.calendarTitle]
        + (event.location.map { [$0] } ?? [])
      let transcriber = makeTranscriber(
        source: .meeting,
        contextualStrings: contextualStrings,
        sessionGeneration: generation
      )
      try transcriber.start()
      try validatePreparingSession(generation)
      self.transcriber = transcriber
      let mixer = MeetingAudioMixer(transcriber: transcriber)
      audioMixer = mixer

      try startMicrophoneCapture(mixer: mixer, sessionGeneration: generation)
      try validatePreparingSession(generation)
      try await startSystemAudioCapture(
        mixer: mixer,
        sessionGeneration: generation
      )
      try validatePreparingSession(generation)

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
      guard generation == sessionGeneration else {
        throw CancellationError()
      }
      cleanupCapture()
      if error is CancellationError {
        state = .idle
        currentEvent = nil
        currentNote = nil
        errorMessage = nil
        throw error
      }
      let message = error.localizedDescription
      errorMessage = message
      state = .failed(message)
      throw error
    }
  }

  func stop() async throws -> LocalDocument? {
    guard state.canStop else { return currentNote }
    state = .stopping
    let activeMixer = audioMixer
    let activeTranscriber = transcriber
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

    await activeMixer?.flush()
    if let snapshot = await activeTranscriber?.stop() {
      reconcileFinalSnapshot(snapshot)
      if snapshot.transcript.isEmpty, let recognitionError = snapshot.errorMessage {
        storeRecognitionError(recognitionError, source: latestSource)
      }
    }
    transcriber = nil
    audioMixer = nil
    do {
      try persistNote(finalized: true)
    } catch {
      let message = "Could not save the final meeting transcript: \(error.localizedDescription)"
      errorMessage = message
      startedAt = nil
      isPreview = false
      invalidateSession()
      state = .failed(message)
      throw MeetingCaptureError(message: message)
    }

    let note = currentNote
    startedAt = nil
    isPreview = false
    invalidateSession()
    state = .idle
    return note
  }

  func cancelPreparation() {
    guard state.isPreparing else { return }
    invalidateSession()
    cleanupCapture()
    currentEvent = nil
    currentNote = nil
    startedAt = nil
    isPreview = false
    errorMessage = nil
    state = .idle
  }

  func shutdown() {
    guard state.isActive, state != .stopping else { return }
    let wasPreparing = state.isPreparing
    invalidateSession()
    persistenceTask?.cancel()
    persistenceTask = nil
    elapsedTimer?.invalidate()
    elapsedTimer = nil
    stopMicrophoneCapture()
    if !wasPreparing, let snapshot = transcriber?.cancel() {
      reconcileFinalSnapshot(snapshot)
      if snapshot.transcript.isEmpty, let recognitionError = snapshot.errorMessage {
        storeRecognitionError(recognitionError, source: latestSource)
      }
    }
    transcriber = nil
    audioMixer = nil
    if !wasPreparing {
      do {
        try persistNote(finalized: true)
      } catch {
        errorMessage = "Could not save the final meeting transcript: \(error.localizedDescription)"
      }
    }
    if let stream, !isPreview {
      Task {
        try? await stream.stopCapture()
      }
    }
    self.stream = nil
    systemOutput = nil
    if wasPreparing {
      currentEvent = nil
      currentNote = nil
      errorMessage = nil
    }
    state = .idle
  }

  func startPreview(event: CalendarEventItem) throws {
    shutdown()
    resetSession(event: event)
    isPreview = true
    state = .listening
    transcriptSegments = [
      MeetingTranscriptSegment(
        source: .meeting,
        startedAt: 2,
        text: "We reviewed the launch plan and agreed to keep the first release deliberately small."
      ),
      MeetingTranscriptSegment(
        source: .microphone,
        startedAt: 54,
        text: "I will send the revised milestones after this meeting."
      ),
      MeetingTranscriptSegment(
        source: .meeting,
        startedAt: 96,
        text: "The team confirmed that customer onboarding is the priority for Friday's release."
      ),
      MeetingTranscriptSegment(
        source: .microphone,
        startedAt: 142,
        text: "I will publish the rollout checklist and follow up with design by tomorrow."
      ),
    ]
    systemTranscript = transcriptSegments
      .filter { $0.source == .meeting }
      .map(\.text)
      .joined(separator: " ")
    microphoneTranscript = transcriptSegments
      .filter { $0.source == .microphone }
      .map(\.text)
      .joined(separator: " ")
    latestSource = .microphone
    latestTranscript = transcriptSegments.last?.text ?? ""
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
    source: MeetingTranscriptSource,
    sessionGeneration: UInt64
  ) {
    guard sessionGeneration == self.sessionGeneration,
          state.isActive,
          state != .stopping,
          !isPreview
    else { return }
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

    if level >= speechLevelThreshold {
      let now = Date()
      switch source {
      case .meeting:
        let becameActive = !systemSpeechIsActive
        if becameActive {
          // Prefer direct call audio over microphone speaker bleed when both are active.
          latestSource = .meeting
          transcriber?.switchSource(to: .meeting)
        }
        systemSpeechIsActive = true
        lastSystemSpeechActivityAt = now
      case .microphone:
        let becameActive = !microphoneSpeechIsActive
        if becameActive {
          if systemSpeechIsActive {
            transcriber?.markSpeechResumed()
          } else {
            latestSource = .microphone
            transcriber?.switchSource(to: .microphone)
          }
        }
        microphoneSpeechIsActive = true
        lastMicrophoneSpeechActivityAt = now
      }
    }
  }

  fileprivate func receiveCaptureError(
    _ message: String,
    sessionGeneration: UInt64
  ) {
    guard sessionGeneration == self.sessionGeneration,
          state == .listening,
          !isPreview
    else { return }
    errorMessage = "System audio capture stopped: \(message)"
  }

  private func resetSession(event: CalendarEventItem) {
    currentEvent = event
    systemTranscript = ""
    microphoneTranscript = ""
    transcriptSegments = []
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
    systemSpeechIsActive = false
    microphoneSpeechIsActive = false
    lastSystemSpeechActivityAt = nil
    lastMicrophoneSpeechActivityAt = nil
    activeSegmentIDs = [:]
  }

  private func makeTranscriber(
    source: MeetingTranscriptSource,
    contextualStrings: [String],
    sessionGeneration: UInt64
  ) -> MeetingSpeechTranscriber {
    MeetingSpeechTranscriber(
      source: source,
      contextualStrings: contextualStrings,
      onTranscript: { [weak self] source, transcript, segment, isFinal in
        Task { @MainActor [weak self] in
          self?.receiveTranscript(
            transcript,
            segment: segment,
            isFinal: isFinal,
            source: source,
            sessionGeneration: sessionGeneration
          )
        }
      },
      onError: { [weak self] source, message in
        Task { @MainActor [weak self] in
          self?.receiveRecognitionError(
            message,
            source: source,
            sessionGeneration: sessionGeneration
          )
        }
      }
    )
  }

  private func receiveTranscript(
    _ transcript: String,
    segment: String,
    isFinal: Bool,
    source: MeetingTranscriptSource,
    sessionGeneration: UInt64
  ) {
    guard sessionGeneration == self.sessionGeneration,
          state.isActive,
          !transcript.isEmpty
    else { return }
    latestSource = source

    let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
    latestTranscript = segment.isEmpty ? transcript : segment
    if !segment.isEmpty {
      if let activeID = activeSegmentIDs[source],
         let index = transcriptSegments.firstIndex(where: { $0.id == activeID })
      {
        transcriptSegments[index].text = segment
        transcriptSegments[index].isFinal = isFinal
      } else {
        let newSegment = MeetingTranscriptSegment(
          source: source,
          startedAt: elapsed,
          text: segment,
          isFinal: isFinal
        )
        transcriptSegments.append(newSegment)
        activeSegmentIDs[source] = newSegment.id
      }
      if isFinal {
        activeSegmentIDs[source] = nil
      }
    }
    systemTranscript = transcriptSegments
      .filter { $0.source == .meeting }
      .map(\.text)
      .joined(separator: " ")
    microphoneTranscript = transcriptSegments
      .filter { $0.source == .microphone }
      .map(\.text)
      .joined(separator: " ")
    schedulePersistence()
  }

  private func receiveRecognitionError(
    _ message: String,
    source: MeetingTranscriptSource,
    sessionGeneration: UInt64
  ) {
    guard sessionGeneration == self.sessionGeneration, state.isActive else { return }
    storeRecognitionError(message, source: source)
    schedulePersistence()
  }

  private func storeRecognitionError(
    _ message: String,
    source: MeetingTranscriptSource
  ) {
    switch source {
    case .meeting: systemRecognitionError = message
    case .microphone: microphoneRecognitionError = message
    }
    errorMessage = "\(source.displayName) transcription: \(message)"
  }

  private func reconcileFinalSnapshot(_ snapshot: MeetingTranscriptionSnapshot) {
    transcriptSegments = MeetingTranscriptReconciler.reconcile(
      existing: transcriptSegments,
      snapshot: snapshot,
      fallbackSource: latestSource,
      fallbackStartedAt: elapsed
    )
    activeSegmentIDs = [:]
    systemTranscript = transcriptSegments
      .filter { $0.source == .meeting }
      .map(\.text)
      .joined(separator: " ")
    microphoneTranscript = transcriptSegments
      .filter { $0.source == .microphone }
      .map(\.text)
      .joined(separator: " ")
    if let lastSegment = transcriptSegments.last {
      latestSource = lastSegment.source
      latestTranscript = lastSegment.text
    } else {
      latestTranscript = snapshot.transcript
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private func startMicrophoneCapture(
    mixer: MeetingAudioMixer,
    sessionGeneration: UInt64
  ) throws {
    let inputNode = microphoneEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw MeetingCaptureError(message: "No usable microphone input was found.")
    }

    let bridge = MeetingMicrophoneTapBridge(
      service: self,
      mixer: mixer,
      sessionGeneration: sessionGeneration
    )
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
    mixer: MeetingAudioMixer,
    sessionGeneration: UInt64
  ) async throws {
    let content = try await shareableContent(timeout: 10)
    try validatePreparingSession(sessionGeneration)
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

    let output = MeetingSystemAudioOutput(
      service: self,
      mixer: mixer,
      sessionGeneration: sessionGeneration
    )
    let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
    try stream.addStreamOutput(
      output,
      type: .audio,
      sampleHandlerQueue: systemAudioQueue
    )
    try validatePreparingSession(sessionGeneration)
    self.systemOutput = output
    self.stream = stream
    do {
      try await startCapture(stream, timeout: 10)
      try validatePreparingSession(sessionGeneration)
    } catch {
      if self.stream === stream {
        self.stream = nil
        self.systemOutput = nil
      }
      Task {
        try? await stream.stopCapture()
      }
      throw error
    }
  }

  private func shareableContent(timeout: TimeInterval) async throws -> SCShareableContent {
    try await withCheckedThrowingContinuation { continuation in
      let gate = MeetingCaptureContinuationGate(continuation)
      SCShareableContent.getExcludingDesktopWindows(
        false,
        onScreenWindowsOnly: false
      ) { content, error in
        if let content {
          gate.resume(returning: content)
        } else {
          gate.resume(
            throwing: error ?? MeetingCaptureError(
              message: "ScreenCaptureKit did not return any shareable content."
            )
          )
        }
      }
      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + timeout
      ) {
        gate.resume(
          throwing: MeetingCaptureError(
            message: "System audio capture did not start. Quit and reopen iAgent after granting Screen & System Audio Recording access, then try again."
          )
        )
      }
    }
  }

  private func startCapture(_ stream: SCStream, timeout: TimeInterval) async throws {
    try await withCheckedThrowingContinuation { continuation in
      let gate = MeetingCaptureContinuationGate<Void>(continuation)
      stream.startCapture { error in
        if let error {
          gate.resume(throwing: error)
        } else {
          gate.resume(returning: ())
        }
      }
      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + timeout
      ) {
        gate.resume(
          throwing: MeetingCaptureError(
            message: "System audio capture did not start. Quit and reopen iAgent after granting Screen & System Audio Recording access, then try again."
          )
        )
      }
    }
  }

  private func validatePreparingSession(_ generation: UInt64) throws {
    try Task.checkCancellation()
    guard generation == sessionGeneration, state.isPreparing else {
      throw CancellationError()
    }
  }

  private func invalidateSession() {
    sessionGeneration &+= 1
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
    if let snapshot = transcriber?.cancel() {
      reconcileFinalSnapshot(snapshot)
    }
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
        let now = Date()
        self.elapsed = now.timeIntervalSince(startedAt)
        let systemExpired = self.systemSpeechIsActive
          && self.lastSystemSpeechActivityAt.map {
            now.timeIntervalSince($0) >= self.silenceDelay
          } == true
        let microphoneExpired = self.microphoneSpeechIsActive
          && self.lastMicrophoneSpeechActivityAt.map {
            now.timeIntervalSince($0) >= self.silenceDelay
          } == true

        if systemExpired {
          self.systemSpeechIsActive = false
        }
        if microphoneExpired {
          self.microphoneSpeechIsActive = false
        }

        if systemExpired != microphoneExpired {
          if self.systemSpeechIsActive {
            self.latestSource = .meeting
            self.transcriber?.switchSource(to: .meeting)
          } else if self.microphoneSpeechIsActive {
            self.latestSource = .microphone
            self.transcriber?.switchSource(to: .microphone)
          }
        }
      }
    }
    elapsedTimer?.tolerance = 0.02
  }

  private func schedulePersistence() {
    persistenceTask?.cancel()
    persistenceTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(220))
      guard let self, !Task.isCancelled else { return }
      do {
        try self.persistNote()
      } catch {
        self.errorMessage = "Could not update meeting note: \(error.localizedDescription)"
      }
      self.persistenceTask = nil
    }
  }

  private func persistNote(finalized: Bool = false) throws {
    guard let event = currentEvent,
          let note = currentNote
    else {
      throw MeetingCaptureError(message: "The active meeting note is unavailable.")
    }

    currentNote = try documentStore.update(
      note,
      title: event.title,
      body: markdownBody(for: event, finalized: finalized)
    )
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

    let metadata = MeetingNoteMetadata(
      date: dateFormatter.string(from: event.startDate),
      time: timeRange,
      calendar: event.calendarTitle,
      location: event.location,
      duration: elapsedText
    )
    return MeetingNoteCodec.compose(
      metadata: metadata,
      summaryMarkdown: MeetingNoteCodec.pendingSummary,
      transcriptSegments: transcriptSegments,
      transcriptFallback: transcriptFallback(finalized: finalized)
    )
  }

  private func transcriptFallback(finalized: Bool) -> String {
    guard finalized else {
      return "_Listening to microphone and system audio…_"
    }

    let recognitionErrors = [systemRecognitionError, microphoneRecognitionError]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
    if !recognitionErrors.isEmpty {
      return "_Transcription error: \(recognitionErrors.joined(separator: " "))_"
    }

    return hasReceivedSystemAudio || hasReceivedMicrophoneAudio
      ? "_Audio was received, but no speech was recognized._"
      : "_No microphone or system audio was received._"
  }
}

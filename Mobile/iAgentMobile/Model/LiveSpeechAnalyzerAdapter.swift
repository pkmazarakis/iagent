import AVFoundation
import CoreMedia
import Foundation
import Speech
import iAgentCore

/// An iOS-17-safe type erasure around the iOS 26 SpeechAnalyzer implementation.
///
/// Keeping unavailable framework types inside the annotated factory lets the recorder
/// store one session property without exposing SpeechAnalyzer to older OS releases.
final class MobileSpeechAnalyzerSession: @unchecked Sendable {
  struct Update: Sendable {
    /// Complete, de-duplicated transcript through the newest analyzer result.
    let transcript: String
  }

  let updates: AsyncThrowingStream<Update, any Error>

  private let appendAction: @Sendable (AVAudioPCMBuffer) -> Bool
  private let finishAction: @Sendable () async throws -> Void
  private let cancelAction: @Sendable () async -> Void

  private init(
    updates: AsyncThrowingStream<Update, any Error>,
    appendAction: @escaping @Sendable (AVAudioPCMBuffer) -> Bool,
    finishAction: @escaping @Sendable () async throws -> Void,
    cancelAction: @escaping @Sendable () async -> Void
  ) {
    self.updates = updates
    self.appendAction = appendAction
    self.finishAction = finishAction
    self.cancelAction = cancelAction
  }

  @available(iOS 26.0, *)
  static func isSupported(locale: Locale) async -> Bool {
    guard SpeechTranscriber.isAvailable else { return false }
    return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
  }

  @available(iOS 26.0, *)
  static func start(
    locale: Locale,
    microphoneFormat: AVAudioFormat
  ) async throws -> MobileSpeechAnalyzerSession {
    let adapter = try await LiveSpeechAnalyzerAdapter.start(
      locale: locale,
      microphoneFormat: microphoneFormat
    )
    let (updates, continuation) = AsyncThrowingStream.makeStream(
      of: Update.self,
      throwing: (any Error).self,
      // Each value below is a complete transcript snapshot, so an older pending
      // snapshot has no durable information that the newest one does not contain.
      // Keeping only the newest value prevents volatile hypotheses from replaying
      // after a busy UI frame.
      bufferingPolicy: .bufferingNewest(1)
    )
    let mappingTask = Task {
      var transcript = SpeechAnalyzerTranscriptAccumulator()
      do {
        for try await update in adapter.updates {
          let snapshot = transcript.update(
            text: update.text,
            startOffset: update.range.start.seconds,
            endOffset: update.range.end.seconds,
            isFinal: update.isFinal
          )
          guard !snapshot.isEmpty else { continue }
          let delivery = continuation.yield(
            Update(transcript: snapshot)
          )
          if case .terminated = delivery {
            return
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }

    return MobileSpeechAnalyzerSession(
      updates: updates,
      appendAction: { adapter.audioSink.append($0) },
      finishAction: {
        try await adapter.finish()
        await mappingTask.value
      },
      cancelAction: {
        await adapter.cancel()
        mappingTask.cancel()
        continuation.finish()
      }
    )
  }

  @discardableResult
  func append(_ buffer: AVAudioPCMBuffer) -> Bool {
    appendAction(buffer)
  }

  func finish() async throws {
    try await finishAction()
  }

  func cancel() async {
    await cancelAction()
  }
}

/// iOS 26 adapter for long-running, fully on-device live transcription.
///
/// `LiveSpeechAnalyzerAdapter` owns the Speech session. Its `audioSink` is the only
/// object that should be called from an AVAudioEngine tap. Consume `updates` from
/// one task for the lifetime of the session, then call `finish()` rather than cancel
/// when recording ends so the last volatile range becomes final.
@available(iOS 26.0, *)
actor LiveSpeechAnalyzerAdapter {
  struct Update: Sendable {
    let text: String
    let range: CMTimeRange
    let isFinal: Bool
  }

  enum AdapterError: LocalizedError, Sendable {
    case speechTranscriberUnavailable
    case unsupportedLocale(Locale)
    case noCompatibleAudioFormat
    case inputFormatChanged
    case unableToCopyInputBuffer
    case unableToCreateConverter
    case unableToCreateOutputBuffer
    case conversionFailed(Int)
    case audioBacklogExceeded
    case resultBacklogExceeded
    case invalidState

    var errorDescription: String? {
      switch self {
      case .speechTranscriberUnavailable:
        "SpeechTranscriber isn't available on this device."
      case let .unsupportedLocale(locale):
        "SpeechTranscriber doesn't support \(locale.identifier)."
      case .noCompatibleAudioFormat:
        "SpeechAnalyzer couldn't provide a compatible audio format."
      case .inputFormatChanged:
        "The microphone format changed during transcription."
      case .unableToCopyInputBuffer:
        "The microphone buffer couldn't be copied."
      case .unableToCreateConverter:
        "The microphone audio format can't be converted for SpeechAnalyzer."
      case .unableToCreateOutputBuffer:
        "An output audio buffer couldn't be allocated."
      case let .conversionFailed(status):
        "Audio conversion failed with status \(status)."
      case .audioBacklogExceeded:
        "On-device transcription could not keep up with live audio. The partial transcript was preserved."
      case .resultBacklogExceeded:
        "Live transcription updates could not be delivered quickly enough. The partial transcript was preserved."
      case .invalidState:
        "The transcription session is no longer accepting this operation."
      }
    }
  }

  /// Thread-safe ingress suitable for direct use by an AVAudioEngine tap.
  nonisolated let audioSink: AudioSink

  /// A single-consumer stream. Volatile updates replace earlier updates over the
  /// same range; finalized updates never change.
  nonisolated let updates: AsyncThrowingStream<Update, any Error>

  private enum State {
    case starting
    case running
    case finishing
    case finished
  }

  private let analyzer: SpeechAnalyzer
  private let transcriber: SpeechTranscriber
  private let updateContinuation: AsyncThrowingStream<Update, any Error>.Continuation
  private var resultTask: Task<Void, Never>?
  private var state = State.starting

  private init(
    analyzer: SpeechAnalyzer,
    transcriber: SpeechTranscriber,
    audioSink: AudioSink,
    updates: AsyncThrowingStream<Update, any Error>,
    updateContinuation: AsyncThrowingStream<Update, any Error>.Continuation
  ) {
    self.analyzer = analyzer
    self.transcriber = transcriber
    self.audioSink = audioSink
    self.updates = updates
    self.updateContinuation = updateContinuation
  }

  /// Creates, downloads, preheats, and starts a live session.
  static func start(
    locale requestedLocale: Locale,
    microphoneFormat: AVAudioFormat
  ) async throws -> LiveSpeechAnalyzerAdapter {
    guard SpeechTranscriber.isAvailable else {
      throw AdapterError.speechTranscriberUnavailable
    }
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: requestedLocale
    ) else {
      throw AdapterError.unsupportedLocale(requestedLocale)
    }

    // Fast volatile results make the first words visible while the on-device model
    // continues refining them. The accumulator below still treats finalized output as
    // authoritative, so latency improves without freezing an early hypothesis.
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [.audioTimeRange, .transcriptionConfidence]
    )

    // This also reserves the locale. Nil means all required assets are installed.
    if let installation = try await AssetInventory.assetInstallationRequest(
      supporting: [transcriber]
    ) {
      try await installation.downloadAndInstall()
    }

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: [transcriber],
      considering: microphoneFormat
    ) else {
      throw AdapterError.noCompatibleAudioFormat
    }

    let (inputStream, inputContinuation) = AsyncStream.makeStream(
      of: AnalyzerInput.self,
      bufferingPolicy: .bufferingOldest(256)
    )
    let (updates, updateContinuation) = AsyncThrowingStream.makeStream(
      of: Update.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(128)
    )

    let analyzer = SpeechAnalyzer(
      modules: [transcriber],
      options: .init(priority: .userInitiated, modelRetention: .whileInUse)
    )
    let audioSink = try AudioSink(
      inputFormat: microphoneFormat,
      analyzerFormat: analyzerFormat,
      continuation: inputContinuation,
      failureHandler: { error in
        updateContinuation.finish(throwing: error)
      }
    )
    let adapter = LiveSpeechAnalyzerAdapter(
      analyzer: analyzer,
      transcriber: transcriber,
      audioSink: audioSink,
      updates: updates,
      updateContinuation: updateContinuation
    )

    try await adapter.begin(inputStream: inputStream, analyzerFormat: analyzerFormat)
    return adapter
  }

  private func begin(
    inputStream: AsyncStream<AnalyzerInput>,
    analyzerFormat: AVAudioFormat
  ) async throws {
    guard state == .starting else { throw AdapterError.invalidState }

    let transcriber = self.transcriber
    let continuation = updateContinuation
    resultTask = Task {
      do {
        for try await result in transcriber.results {
          let delivery = continuation.yield(
            Update(
              text: String(result.text.characters),
              range: result.range,
              isFinal: result.isFinal
            )
          )
          if case .dropped = delivery {
            continuation.finish(throwing: AdapterError.resultBacklogExceeded)
            return
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }

    do {
      // Avoid a cold-start delay on the first utterance.
      try await analyzer.prepareToAnalyze(in: analyzerFormat)
      // Starts autonomous consumption and returns after the session is started.
      try await analyzer.start(inputSequence: inputStream)
      state = .running
    } catch {
      audioSink.cancel()
      resultTask?.cancel()
      updateContinuation.finish(throwing: error)
      state = .finished
      throw error
    }
  }

  /// Graceful stop: drains conversion, terminates input, asks SpeechAnalyzer to
  /// finalize through the end of input, and waits for the result stream to close.
  func finish() async throws {
    guard state == .running else { throw AdapterError.invalidState }
    state = .finishing

    do {
      try await audioSink.finish()
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      await resultTask?.value
      state = .finished
    } catch {
      await analyzer.cancelAndFinishNow()
      resultTask?.cancel()
      updateContinuation.finish(throwing: error)
      state = .finished
      throw error
    }
  }

  /// Immediate teardown for abandonment/errors only; this may lose trailing text.
  func cancel() async {
    guard state != .finished else { return }
    state = .finishing
    audioSink.cancel()
    await analyzer.cancelAndFinishNow()
    resultTask?.cancel()
    updateContinuation.finish()
    state = .finished
  }
}

@available(iOS 26.0, *)
extension LiveSpeechAnalyzerAdapter {
  /// Serializes conversion without doing conversion work on the realtime audio thread.
  /// The synchronous copy is necessary because AVAudioPCMBuffer isn't Sendable.
  final class AudioSink: @unchecked Sendable {
    private static let maximumPendingBuffers = 256

    private let stateLock = NSLock()
    private let queue = DispatchQueue(
      label: "com.iagent.speech-analyzer-audio",
      qos: .userInitiated
    )
    private let converter: StreamAudioConverter
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let failureHandler: @Sendable (any Error) -> Void
    private var acceptsInput = true
    private var finishStarted = false
    private var cancelRequested = false
    private var pendingBufferCount = 0
    private var failure: (any Error)?

    fileprivate init(
      inputFormat: AVAudioFormat,
      analyzerFormat: AVAudioFormat,
      continuation: AsyncStream<AnalyzerInput>.Continuation,
      failureHandler: @escaping @Sendable (any Error) -> Void
    ) throws {
      converter = try StreamAudioConverter(
        inputFormat: inputFormat,
        outputFormat: analyzerFormat
      )
      self.continuation = continuation
      self.failureHandler = failureHandler
    }

    /// Returns false after finish/cancel or after a conversion failure.
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
      stateLock.lock()
      guard acceptsInput, !finishStarted, !cancelRequested, failure == nil else {
        stateLock.unlock()
        return false
      }
      guard pendingBufferCount < Self.maximumPendingBuffers else {
        stateLock.unlock()
        recordFailure(AdapterError.audioBacklogExceeded)
        return false
      }
      guard let snapshot = buffer.copy() as? AVAudioPCMBuffer else {
        stateLock.unlock()
        recordFailure(AdapterError.unableToCopyInputBuffer)
        return false
      }
      pendingBufferCount += 1

      // Submission is done while holding stateLock, so finish() is always queued
      // after every buffer that append() accepted.
      queue.async { [self, snapshot = PCMBufferTransfer(snapshot)] in
        defer { completeQueuedBuffer() }
        guard shouldProcessQueuedBuffer() else { return }
        do {
          if let converted = try converter.convert(snapshot.buffer),
             converted.frameLength > 0
          {
            switch continuation.yield(AnalyzerInput(buffer: converted)) {
            case .enqueued:
              break
            case .dropped:
              throw AdapterError.audioBacklogExceeded
            case .terminated:
              return
            @unknown default:
              throw AdapterError.audioBacklogExceeded
            }
          }
        } catch {
          recordFailure(error)
        }
      }
      stateLock.unlock()
      return true
    }

    fileprivate func finish() async throws {
      try await withCheckedThrowingContinuation {
        (checked: CheckedContinuation<Void, any Error>) in
        stateLock.lock()
        guard !finishStarted else {
          stateLock.unlock()
          checked.resume(throwing: AdapterError.invalidState)
          return
        }
        finishStarted = true
        acceptsInput = false

        queue.async { [self] in
          do {
            if let failure = currentFailure() { throw failure }
            for converted in try converter.finish() where converted.frameLength > 0 {
              switch continuation.yield(AnalyzerInput(buffer: converted)) {
              case .enqueued:
                break
              case .dropped:
                throw AdapterError.audioBacklogExceeded
              case .terminated:
                throw AdapterError.invalidState
              @unknown default:
                throw AdapterError.audioBacklogExceeded
              }
            }
            continuation.finish()
            checked.resume()
          } catch {
            continuation.finish()
            checked.resume(throwing: error)
          }
        }
        stateLock.unlock()
      }
    }

    fileprivate func cancel() {
      stateLock.lock()
      guard !cancelRequested else {
        stateLock.unlock()
        return
      }
      finishStarted = true
      acceptsInput = false
      cancelRequested = true
      stateLock.unlock()
      // End input immediately. Queued jobs observe cancelRequested and discard their
      // snapshots without doing conversion work.
      continuation.finish()
    }

    private func recordFailure(_ error: any Error) {
      stateLock.lock()
      let shouldReport = failure == nil && !cancelRequested
      if shouldReport {
        failure = error
        acceptsInput = false
      }
      stateLock.unlock()
      guard shouldReport else { return }
      continuation.finish()
      failureHandler(error)
    }

    private func shouldProcessQueuedBuffer() -> Bool {
      stateLock.lock()
      defer { stateLock.unlock() }
      return !cancelRequested && failure == nil
    }

    private func completeQueuedBuffer() {
      stateLock.lock()
      pendingBufferCount = max(0, pendingBufferCount - 1)
      stateLock.unlock()
    }

    private func currentFailure() -> (any Error)? {
      stateLock.lock()
      defer { stateLock.unlock() }
      return failure
    }
  }
}

@available(iOS 26.0, *)
private struct PCMBufferTransfer: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer

  init(_ buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }
}

@available(iOS 26.0, *)
private final class ConverterInput: @unchecked Sendable {
  private let lock = NSLock()
  private let buffer: AVAudioPCMBuffer?
  private var supplied = false

  init(buffer: AVAudioPCMBuffer?) {
    self.buffer = buffer
  }

  func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }

    guard let buffer else {
      status.pointee = .endOfStream
      return nil
    }
    guard !supplied else {
      status.pointee = .noDataNow
      return nil
    }
    supplied = true
    status.pointee = .haveData
    return buffer
  }
}

@available(iOS 26.0, *)
private final class StreamAudioConverter: @unchecked Sendable {
  private let converter: AVAudioConverter
  private let inputFormat: AVAudioFormat
  private let outputFormat: AVAudioFormat

  init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      throw LiveSpeechAnalyzerAdapter.AdapterError.unableToCreateConverter
    }
    self.converter = converter
    self.inputFormat = inputFormat
    self.outputFormat = outputFormat

    // Appropriate for a continuous live stream; removes priming/trailing frames.
    converter.primeMethod = .none
    converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
  }

  /// Called only on AudioSink.queue.
  func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
    guard input.format == inputFormat else {
      throw LiveSpeechAnalyzerAdapter.AdapterError.inputFormatChanged
    }

    let rateRatio = outputFormat.sampleRate / inputFormat.sampleRate
    let requiredFrames = max(
      1,
      Int(ceil(Double(input.frameLength) * rateRatio)) + 32
    )
    guard let output = AVAudioPCMBuffer(
      pcmFormat: outputFormat,
      frameCapacity: AVAudioFrameCount(requiredFrames)
    ) else {
      throw LiveSpeechAnalyzerAdapter.AdapterError.unableToCreateOutputBuffer
    }

    let source = ConverterInput(buffer: input)
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) {
      _, inputStatus in
      source.next(inputStatus)
    }
    if let conversionError { throw conversionError }
    if status == .error {
      throw LiveSpeechAnalyzerAdapter.AdapterError.conversionFailed(status.rawValue)
    }
    return output.frameLength > 0 ? output : nil
  }

  /// Drains any fractional output held by AVAudioConverter at end of stream.
  /// Called only on AudioSink.queue.
  func finish() throws -> [AVAudioPCMBuffer] {
    var drained: [AVAudioPCMBuffer] = []
    let source = ConverterInput(buffer: nil)

    while true {
      guard let output = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: 4096
      ) else {
        throw LiveSpeechAnalyzerAdapter.AdapterError.unableToCreateOutputBuffer
      }
      var conversionError: NSError?
      let status = converter.convert(to: output, error: &conversionError) {
        _, inputStatus in
        source.next(inputStatus)
      }
      if let conversionError { throw conversionError }
      if output.frameLength > 0 { drained.append(output) }

      switch status {
      case .haveData:
        continue
      case .inputRanDry, .endOfStream:
        return drained
      case .error:
        throw LiveSpeechAnalyzerAdapter.AdapterError.conversionFailed(status.rawValue)
      @unknown default:
        throw LiveSpeechAnalyzerAdapter.AdapterError.conversionFailed(status.rawValue)
      }
    }
  }
}

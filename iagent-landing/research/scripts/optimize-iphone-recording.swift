import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum OptimizeError: Error, CustomStringConvertible {
  case usage
  case missingVideo
  case reader(String)
  case writer(String)

  var description: String {
    switch self {
    case .usage:
      return "usage: optimize-iphone-recording <input.mp4> <output.mp4> [width] [height] [fps] [bitrate]"
    case .missingVideo:
      return "input does not contain a video track"
    case let .reader(message), let .writer(message):
      return message
    }
  }
}

private func networkOptimize(_ path: String) throws {
  let sourceURL = URL(fileURLWithPath: path)
  let temporaryURL = sourceURL
    .deletingLastPathComponent()
    .appendingPathComponent(".network-\(UUID().uuidString).mp4")
  let asset = AVURLAsset(url: sourceURL)
  guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
    throw OptimizeError.writer("could not create the fast-start export")
  }
  export.outputURL = temporaryURL
  export.outputFileType = .mp4
  export.shouldOptimizeForNetworkUse = true

  let semaphore = DispatchSemaphore(value: 0)
  export.exportAsynchronously { semaphore.signal() }
  semaphore.wait()
  guard export.status == .completed else {
    try? FileManager.default.removeItem(at: temporaryURL)
    throw OptimizeError.writer(export.error?.localizedDescription ?? "fast-start export failed")
  }

  try FileManager.default.removeItem(at: sourceURL)
  try FileManager.default.moveItem(at: temporaryURL, to: sourceURL)
}

private func optimize(
  inputPath: String,
  outputPath: String,
  width: Int,
  height: Int,
  fps: Int32,
  bitrate: Int
) async throws {
  let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
  guard let track = try await asset.loadTracks(withMediaType: .video).first else {
    throw OptimizeError.missingVideo
  }
  let duration = try await asset.load(.duration)
  let naturalSize = try await track.load(.naturalSize)
  let transform = try await track.load(.preferredTransform)
  let orientedBounds = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
  guard orientedBounds.width > 0, orientedBounds.height > 0 else {
    throw OptimizeError.reader("input video has invalid dimensions")
  }

  let reader = try AVAssetReader(asset: asset)
  let readerOutput = AVAssetReaderVideoCompositionOutput(
    videoTracks: [track],
    videoSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ]
  )
  readerOutput.alwaysCopiesSampleData = false

  let composition = AVMutableVideoComposition()
  composition.renderSize = CGSize(width: width, height: height)
  composition.frameDuration = CMTime(value: 1, timescale: fps)
  let instruction = AVMutableVideoCompositionInstruction()
  instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
  let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
  let normalized = transform.concatenating(
    CGAffineTransform(translationX: -orientedBounds.minX, y: -orientedBounds.minY)
  )
  let scale = min(CGFloat(width) / orientedBounds.width, CGFloat(height) / orientedBounds.height)
  let scaledWidth = orientedBounds.width * scale
  let scaledHeight = orientedBounds.height * scale
  let centered = normalized
    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    .concatenating(
      CGAffineTransform(
        translationX: (CGFloat(width) - scaledWidth) / 2,
        y: (CGFloat(height) - scaledHeight) / 2
      )
    )
  layerInstruction.setTransform(centered, at: .zero)
  instruction.layerInstructions = [layerInstruction]
  composition.instructions = [instruction]
  readerOutput.videoComposition = composition

  guard reader.canAdd(readerOutput) else {
    throw OptimizeError.reader("could not configure the video decoder")
  }
  reader.add(readerOutput)

  let outputURL = URL(fileURLWithPath: outputPath)
  try? FileManager.default.removeItem(at: outputURL)
  let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
  let writerInput = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoMaxKeyFrameIntervalKey: fps * 2,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]
  )
  writerInput.expectsMediaDataInRealTime = false
  guard writer.canAdd(writerInput) else {
    throw OptimizeError.writer("could not configure the H.264 encoder")
  }
  writer.add(writerInput)

  guard reader.startReading() else {
    throw OptimizeError.reader(reader.error?.localizedDescription ?? "decoder failed to start")
  }
  guard writer.startWriting() else {
    throw OptimizeError.writer(writer.error?.localizedDescription ?? "encoder failed to start")
  }
  writer.startSession(atSourceTime: .zero)

  let frameStep = CMTime(value: 1, timescale: fps)
  var nextOutputTime = CMTime.zero
  while let sample = readerOutput.copyNextSampleBuffer() {
    let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
    if CMTimeCompare(sourceTime, nextOutputTime) < 0 { continue }
    while !writerInput.isReadyForMoreMediaData {
      Thread.sleep(forTimeInterval: 0.001)
    }
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
    guard writerInput.append(
      CMSampleBuffer.createReady(
        imageBuffer: imageBuffer,
        formatDescription: CMSampleBufferGetFormatDescription(sample),
        presentationTime: nextOutputTime,
        duration: frameStep
      )
    ) else {
      throw OptimizeError.writer(writer.error?.localizedDescription ?? "could not encode a video frame")
    }
    nextOutputTime = CMTimeAdd(nextOutputTime, frameStep)
  }

  guard reader.status == .completed else {
    throw OptimizeError.reader(reader.error?.localizedDescription ?? "video decoding did not complete")
  }
  writerInput.markAsFinished()
  await writer.finishWriting()
  guard writer.status == .completed else {
    throw OptimizeError.writer(writer.error?.localizedDescription ?? "video encoding did not complete")
  }
  try networkOptimize(outputPath)
}

extension CMSampleBuffer {
  static func createReady(
    imageBuffer: CVImageBuffer,
    formatDescription: CMFormatDescription?,
    presentationTime: CMTime,
    duration: CMTime
  ) -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(
      duration: duration,
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    var description = formatDescription
    if description == nil {
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescriptionOut: &description
      )
    }
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: imageBuffer,
      formatDescription: description!,
      sampleTiming: &timing,
      sampleBufferOut: &sample
    )
    return sample!
  }
}

do {
  guard CommandLine.arguments.count >= 3 else { throw OptimizeError.usage }
  let width = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 604 : 604
  let height = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) ?? 1312 : 1312
  let fps = CommandLine.arguments.count > 5 ? Int32(CommandLine.arguments[5]) ?? 30 : 30
  let bitrate = CommandLine.arguments.count > 6 ? Int(CommandLine.arguments[6]) ?? 1_100_000 : 1_100_000
  try await optimize(
    inputPath: CommandLine.arguments[1],
    outputPath: CommandLine.arguments[2],
    width: width,
    height: height,
    fps: fps,
    bitrate: bitrate
  )
  let size = try FileManager.default.attributesOfItem(atPath: CommandLine.arguments[2])[.size] as? NSNumber
  print("wrote \(CommandLine.arguments[2]) (\(size?.intValue ?? 0) bytes, no audio)")
} catch {
  fputs("\(error)\n", stderr)
  exit(1)
}

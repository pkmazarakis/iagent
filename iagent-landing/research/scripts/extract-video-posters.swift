import AppKit
import AVFoundation
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

guard !arguments.isEmpty, arguments.count.isMultiple(of: 2) else {
    fputs("Usage: swift extract-video-posters.swift input.mp4 output.jpg [input.mp4 output.jpg ...]\n", stderr)
    exit(64)
}

for index in stride(from: 0, to: arguments.count, by: 2) {
    let inputURL = URL(fileURLWithPath: arguments[index])
    let outputURL = URL(fileURLWithPath: arguments[index + 1])
    let asset = AVURLAsset(url: inputURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    var actualTime = CMTime.zero
    let image = try generator.copyCGImage(
        at: CMTime(seconds: 0.08, preferredTimescale: 600),
        actualTime: &actualTime
    )
    let bitmap = NSBitmapImageRep(cgImage: image)

    guard let data = bitmap.representation(
        using: .jpeg,
        properties: [.compressionFactor: 0.86]
    ) else {
        throw NSError(domain: "iAgentPoster", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not encode poster for \(inputURL.lastPathComponent)"
        ])
    }

    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: outputURL, options: .atomic)
    print("\(inputURL.lastPathComponent) -> \(outputURL.lastPathComponent)")
}

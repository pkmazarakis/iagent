import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: swift compose-image-comparison.swift reference implementation output.png\n", stderr)
    exit(64)
}

let referenceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let implementationURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])

guard let reference = NSImage(contentsOf: referenceURL),
      let implementation = NSImage(contentsOf: implementationURL) else {
    throw NSError(domain: "iAgentComparison", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Could not open both comparison images"
    ])
}

let imageWidth = max(Int(reference.size.width), Int(implementation.size.width))
let imageHeight = max(Int(reference.size.height), Int(implementation.size.height))
let margin = 24
let gutter = 24
let labelHeight = 42
let canvasWidth = margin * 2 + imageWidth * 2 + gutter
let canvasHeight = margin * 2 + labelHeight + imageHeight

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasWidth,
    pixelsHigh: canvasHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    throw NSError(domain: "iAgentComparison", code: 2)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight).fill()

let labelAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)
]

let imageY = margin
let labelY = margin + imageHeight + 12
let referenceX = margin
let implementationX = margin + imageWidth + gutter

func aspectFit(_ image: NSImage, in cell: NSRect) -> NSRect {
    let scale = min(cell.width / image.size.width, cell.height / image.size.height)
    let width = image.size.width * scale
    let height = image.size.height * scale
    return NSRect(
        x: cell.midX - width / 2,
        y: cell.midY - height / 2,
        width: width,
        height: height
    )
}

let referenceCell = NSRect(x: referenceX, y: imageY, width: imageWidth, height: imageHeight)
let implementationCell = NSRect(x: implementationX, y: imageY, width: imageWidth, height: imageHeight)

reference.draw(
    in: aspectFit(reference, in: referenceCell),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
implementation.draw(
    in: aspectFit(implementation, in: implementationCell),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
NSAttributedString(string: "Reference", attributes: labelAttributes)
    .draw(at: NSPoint(x: referenceX, y: labelY))
NSAttributedString(string: "Rendered screen", attributes: labelAttributes)
    .draw(at: NSPoint(x: implementationX, y: labelY))
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    throw NSError(domain: "iAgentComparison", code: 3)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try data.write(to: outputURL, options: .atomic)

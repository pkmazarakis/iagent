import Foundation

/// Projects chronological audio levels onto a fixed number of visual bars.
///
/// Each destination bar maps to a monotonically increasing position in the retained
/// history. This deliberately interpolates between neighboring samples instead of
/// padding a wide waveform by repeating its oldest value.
public enum WaveformSampleProjector {
  public static func project(
    _ levels: [Double],
    count: Int,
    baseline: Double = 0.06
  ) -> [Double] {
    guard count > 0 else { return [] }
    guard !levels.isEmpty else { return Array(repeating: baseline, count: count) }
    guard levels.count > 1, count > 1 else {
      return Array(repeating: levels.last ?? baseline, count: count)
    }
    if levels.count == count { return levels }

    let sourceScale = Double(levels.count - 1) / Double(count - 1)
    return (0 ..< count).map { destinationIndex in
      let sourcePosition = Double(destinationIndex) * sourceScale
      let lowerIndex = Int(sourcePosition.rounded(.down))
      let upperIndex = min(levels.count - 1, lowerIndex + 1)
      let fraction = sourcePosition - Double(lowerIndex)
      return levels[lowerIndex] * (1 - fraction) + levels[upperIndex] * fraction
    }
  }
}

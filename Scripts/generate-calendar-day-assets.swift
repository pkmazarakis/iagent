import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let rootURL = scriptURL
  .deletingLastPathComponent()
  .deletingLastPathComponent()
let outputURL = rootURL
  .appendingPathComponent("Sources/iAgentPanel/Resources/CalendarDays", isDirectory: true)

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let outline = """
  <path d="M16 2v3"/>
  <path d="M3 9h18"/>
  <path d="M8 2v3"/>
  <rect x="3" y="3" width="18" height="18" rx="2"/>
"""

try """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
\(outline)
</svg>
""".write(
  to: outputURL.appendingPathComponent("calendar-outline.svg"),
  atomically: true,
  encoding: .utf8
)

enum Segment: String, CaseIterable {
  case top
  case upperRight
  case lowerRight
  case bottom
  case lowerLeft
  case upperLeft
  case middle
}

let digitSegments: [Character: Set<Segment>] = [
  "0": [.top, .upperRight, .lowerRight, .bottom, .lowerLeft, .upperLeft],
  "1": [.upperRight, .lowerRight],
  "2": [.top, .upperRight, .middle, .lowerLeft, .bottom],
  "3": [.top, .upperRight, .middle, .lowerRight, .bottom],
  "4": [.upperLeft, .middle, .upperRight, .lowerRight],
  "5": [.top, .upperLeft, .middle, .lowerRight, .bottom],
  "6": [.top, .upperLeft, .middle, .lowerLeft, .lowerRight, .bottom],
  "7": [.top, .upperRight, .lowerRight],
  "8": Set(Segment.allCases),
  "9": [.top, .upperLeft, .upperRight, .middle, .lowerRight, .bottom],
]

func format(_ value: Double) -> String {
  let rounded = value.rounded()
  if abs(value - rounded) < 0.001 {
    return String(Int(rounded))
  }
  return String(format: "%.2f", value)
}

func path(for segment: Segment, originX: Double, width: Double) -> String {
  let left = originX
  let right = originX + width
  let inset = min(0.72, width * 0.18)
  let top = 12.2
  let middle = 15.05
  let bottom = 17.9

  switch segment {
  case .top:
    return "M\(format(left + inset)) \(format(top))H\(format(right - inset))"
  case .upperRight:
    return "M\(format(right)) \(format(top + inset))V\(format(middle - inset))"
  case .lowerRight:
    return "M\(format(right)) \(format(middle + inset))V\(format(bottom - inset))"
  case .bottom:
    return "M\(format(left + inset)) \(format(bottom))H\(format(right - inset))"
  case .lowerLeft:
    return "M\(format(left)) \(format(middle + inset))V\(format(bottom - inset))"
  case .upperLeft:
    return "M\(format(left)) \(format(top + inset))V\(format(middle - inset))"
  case .middle:
    return "M\(format(left + inset)) \(format(middle))H\(format(right - inset))"
  }
}

func numeralPaths(for day: Int) -> String {
  let digits = Array(String(day))
  let width = digits.count == 1 ? 4.8 : 3.6
  let gap = digits.count == 1 ? 0 : 1.2
  let totalWidth = Double(digits.count) * width + Double(max(0, digits.count - 1)) * gap
  let startX = 12 - totalWidth / 2

  return digits.enumerated().flatMap { index, digit -> [String] in
    let originX = startX + Double(index) * (width + gap)
    return Segment.allCases.compactMap { segment in
      guard digitSegments[digit]?.contains(segment) == true else { return nil }
      return "  <path d=\"\(path(for: segment, originX: originX, width: width))\" stroke-width=\"1.45\"/>"
    }
  }.joined(separator: "\n")
}

func compactDigitPath(for segment: Segment) -> String {
  let left = 0.8
  let right = 5.2
  let inset = 0.72
  let top = 0.7
  let middle = 4.0
  let bottom = 7.3

  switch segment {
  case .top:
    return "M\(format(left + inset)) \(format(top))H\(format(right - inset))"
  case .upperRight:
    return "M\(format(right)) \(format(top + inset))V\(format(middle - inset))"
  case .lowerRight:
    return "M\(format(right)) \(format(middle + inset))V\(format(bottom - inset))"
  case .bottom:
    return "M\(format(left + inset)) \(format(bottom))H\(format(right - inset))"
  case .lowerLeft:
    return "M\(format(left)) \(format(middle + inset))V\(format(bottom - inset))"
  case .upperLeft:
    return "M\(format(left)) \(format(top + inset))V\(format(middle - inset))"
  case .middle:
    return "M\(format(left + inset)) \(format(middle))H\(format(right - inset))"
  }
}

for day in 1...31 {
  let svg = """
  <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  \(numeralPaths(for: day))
  </svg>
  """
  try svg.write(
    to: outputURL.appendingPathComponent(String(format: "calendar-day-%02d.svg", day)),
    atomically: true,
    encoding: .utf8
  )
}

for digit in 0...9 {
  let character = Character(String(digit))
  let paths = Segment.allCases.compactMap { segment in
    guard digitSegments[character]?.contains(segment) == true else { return nil }
    return "  <path d=\"\(compactDigitPath(for: segment))\"/>"
  }.joined(separator: "\n")
  let svg = """
  <svg xmlns="http://www.w3.org/2000/svg" width="6" height="8" viewBox="0 0 6 8" fill="none" stroke="#000" stroke-width="1.15" stroke-linecap="round" stroke-linejoin="round">
  \(paths)
  </svg>
  """
  try svg.write(
    to: outputURL.appendingPathComponent("calendar-digit-\(digit).svg"),
    atomically: true,
    encoding: .utf8
  )
}

import SwiftUI

struct NumberFlowText: View {
  let text: String
  let fontSize: CGFloat
  let weight: Font.Weight
  let color: Color
  let reservedWidth: CGFloat?
  let alignment: Alignment
  let lineHeight: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var previousText: String
  @State private var currentText: String
  @State private var settled = true

  init(
    _ text: String,
    fontSize: CGFloat,
    weight: Font.Weight = .medium,
    color: Color = .primary,
    reservedWidth: CGFloat? = nil,
    alignment: Alignment = .trailing,
    lineHeight: CGFloat? = nil
  ) {
    self.text = text
    self.fontSize = fontSize
    self.weight = weight
    self.color = color
    self.reservedWidth = reservedWidth
    self.alignment = alignment
    self.lineHeight = lineHeight ?? ceil(fontSize * 1.4)
    _previousText = State(initialValue: text)
    _currentText = State(initialValue: text)
  }

  var body: some View {
    Group {
      if reduceMotion {
        Text(text)
          .font(flowFont)
          .foregroundStyle(color)
      } else {
        flowingGlyphs
      }
    }
    .frame(width: reservedWidth, height: lineHeight, alignment: alignment)
    .clipped()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
    .onChange(of: text) { _, nextText in
      animate(to: nextText)
    }
  }

  private var flowingGlyphs: some View {
    let oldGlyphs = paddedGlyphs(previousText)
    let newGlyphs = paddedGlyphs(currentText)
    let trend = numericTrend(from: previousText, to: currentText)

    return HStack(spacing: 0) {
      ForEach(Array(zip(oldGlyphs, newGlyphs).enumerated()), id: \.offset) { _, pair in
        NumberFlowGlyph(
          previous: pair.0,
          current: pair.1,
          settled: settled,
          trend: trend,
          font: flowFont,
          color: color,
          width: glyphWidth,
          height: lineHeight
        )
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var flowFont: Font {
    .system(size: fontSize, weight: weight, design: .monospaced)
  }

  private var glyphWidth: CGFloat {
    ceil(fontSize * 0.64)
  }

  private func paddedGlyphs(_ value: String) -> [Character?] {
    let width = max(previousText.count, currentText.count)
    let glyphs = Array(value).map(Optional.some)
    return Array(repeating: nil, count: max(0, width - glyphs.count)) + glyphs
  }

  private func numericTrend(from oldValue: String, to newValue: String) -> CGFloat {
    let oldNumber = Int(oldValue.filter(\.isNumber)) ?? 0
    let newNumber = Int(newValue.filter(\.isNumber)) ?? 0
    return newNumber >= oldNumber ? 1 : -1
  }

  private func animate(to nextText: String) {
    guard nextText != currentText else { return }
    previousText = currentText
    currentText = nextText

    guard !reduceMotion else {
      previousText = nextText
      settled = true
      return
    }

    settled = false
    DispatchQueue.main.async {
      withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.3)) {
        settled = true
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
      guard currentText == nextText else { return }
      previousText = nextText
    }
  }
}

private struct NumberFlowGlyph: View {
  let previous: Character?
  let current: Character?
  let settled: Bool
  let trend: CGFloat
  let font: Font
  let color: Color
  let width: CGFloat
  let height: CGFloat

  var body: some View {
    ZStack {
      if previous == current {
        glyph(current)
      } else if isDigit(previous) || isDigit(current) {
        glyph(previous)
          .offset(y: settled ? -trend * height : 0)
          .opacity(settled ? 0 : 1)

        glyph(current)
          .offset(y: settled ? 0 : trend * height)
          .opacity(settled ? 1 : 0.35)
      } else {
        glyph(previous)
          .opacity(settled ? 0 : 1)
        glyph(current)
          .opacity(settled ? 1 : 0)
      }
    }
    .frame(width: width, height: height)
    .clipped()
  }

  @ViewBuilder
  private func glyph(_ character: Character?) -> some View {
    if let character {
      Text(String(character))
        .font(font)
        .foregroundStyle(color)
        .frame(width: width, height: height)
    }
  }

  private func isDigit(_ character: Character?) -> Bool {
    character?.isNumber == true
  }
}

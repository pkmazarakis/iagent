import SwiftUI
import UIKit

struct MobileWelcomeView: View {
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hasEntered = false

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let height = proxy.size.height
      let logoSize = min(210, max(196, width * 0.52))

      ZStack {
        WelcomeBackdrop()

        WelcomeLogoTile(size: logoSize)
          .frame(width: logoSize, height: logoSize)
          .position(x: width / 2, y: height * 0.39)
          .scaleEffect(hasEntered ? 1 : 0.92)
          .opacity(hasEntered ? 1 : 0)
          .blur(radius: hasEntered ? 0 : 8)
          .animation(
            reduceMotion
              ? .linear(duration: 0.01)
              : .timingCurve(0.22, 1, 0.36, 1, duration: 0.78),
            value: hasEntered
          )

        VStack(spacing: 4) {
          Text("Welcome to")
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Color(white: 0.6))

          Text("iAgent")
            .font(.system(size: 24, weight: .medium))
            .tracking(-0.2)
            .foregroundStyle(Color.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Welcome to iAgent")
        .accessibilityIdentifier("welcome-screen")
        .position(x: width / 2, y: height * 0.617)
        .offset(y: hasEntered ? 0 : 12)
        .opacity(hasEntered ? 1 : 0)
        .animation(
          reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.22, 1, 0.36, 1, duration: 0.62).delay(0.12),
          value: hasEntered
        )

        VStack {
          Spacer()

          Button(action: action) {
            Text("Get started")
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(Color(white: 0.895))
              .frame(maxWidth: .infinity)
              .frame(height: 56)
          }
          .buttonStyle(WelcomeButtonStyle())
          .accessibilityIdentifier("welcome-get-started")
          .padding(.horizontal, 28)
          .padding(.bottom, 28)
          .offset(y: hasEntered ? 0 : 10)
          .opacity(hasEntered ? 1 : 0)
          .animation(
            reduceMotion
              ? .linear(duration: 0.01)
              : .timingCurve(0.22, 1, 0.36, 1, duration: 0.58).delay(0.22),
            value: hasEntered
          )
        }
      }
      .frame(width: width, height: height)
    }
    .ignoresSafeArea()
    .background(Color(red: 0.051, green: 0.051, blue: 0.051))
    .onAppear { hasEntered = true }
  }
}

private struct WelcomeBackdrop: View {
  var body: some View {
    ZStack {
      Color(red: 0.051, green: 0.051, blue: 0.051)

      RadialGradient(
        stops: [
          .init(color: .white.opacity(0.055), location: 0),
          .init(color: .white.opacity(0.018), location: 0.38),
          .init(color: .clear, location: 1),
        ],
        center: UnitPoint(x: 0.5, y: 0.395),
        startRadius: 0,
        endRadius: 360
      )

      WelcomeDotField()

      RadialGradient(
        stops: [
          .init(color: .clear, location: 0.38),
          .init(color: .black.opacity(0.08), location: 0.72),
          .init(color: .black.opacity(0.4), location: 1),
        ],
        center: UnitPoint(x: 0.5, y: 0.43),
        startRadius: 80,
        endRadius: 500
      )

      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.12), location: 0),
          .init(color: .clear, location: 0.12),
          .init(color: .clear, location: 0.82),
          .init(color: .black.opacity(0.22), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .accessibilityHidden(true)
  }
}

private struct WelcomeDotField: View {
  var body: some View {
    Canvas { context, size in
      let spacing: CGFloat = 27
      let dotSize: CGFloat = 3
      var dots = Path()

      for x in stride(from: 25.3, through: size.width, by: spacing) {
        for y in stride(from: 24.3, through: size.height, by: spacing) {
          dots.addEllipse(
            in: CGRect(
              x: x - dotSize / 2,
              y: y - dotSize / 2,
              width: dotSize,
              height: dotSize
            )
          )
        }
      }

      context.fill(dots, with: .color(.white.opacity(0.032)))
    }
    .mask {
      LinearGradient(
        stops: [
          .init(color: .white.opacity(0.58), location: 0),
          .init(color: .white, location: 0.13),
          .init(color: .white, location: 0.89),
          .init(color: .white.opacity(0.58), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }
}

private struct WelcomeLogoTile: View {
  let size: CGFloat

  private var cornerRadius: CGFloat { size * 0.235 }
  private var logoFrame: CGFloat { size * 1.08 }

  var body: some View {
    let tile = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    ZStack {
      tile
        .fill(Color(red: 0.075, green: 0.076, blue: 0.083))

      tile
        .fill(
          LinearGradient(
            stops: [
              .init(color: .white.opacity(0.11), location: 0),
              .init(color: .white.opacity(0.035), location: 0.38),
              .init(color: .black.opacity(0.18), location: 0.72),
              .init(color: .black.opacity(0.5), location: 1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )

      tile
        .fill(
          RadialGradient(
            colors: [.white.opacity(0.07), .clear],
            center: UnitPoint(x: 0.32, y: 0.13),
            startRadius: 0,
            endRadius: size * 0.82
          )
        )

      Color.black.opacity(0.68)
        .mask(logoMask)
        .offset(x: 1.2, y: 4.8)
        .blur(radius: 1.8)

      LinearGradient(
        stops: [
          .init(color: Color(red: 0.99, green: 0.99, blue: 1), location: 0),
          .init(color: Color(red: 0.76, green: 0.77, blue: 0.79), location: 0.44),
          .init(color: Color(red: 0.97, green: 0.97, blue: 0.98), location: 0.61),
          .init(color: Color(red: 0.56, green: 0.57, blue: 0.6), location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .mask(logoMask)
      .shadow(color: .black.opacity(0.78), radius: 2.1, x: 1.2, y: 3.6)

      foregroundLogoImage

      tile
        .stroke(
          LinearGradient(
            colors: [.white.opacity(0.22), .white.opacity(0.045), .black.opacity(0.8)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 1
        )

      tile
        .inset(by: 1.5)
        .stroke(Color.black.opacity(0.45), lineWidth: 0.7)
    }
    .frame(width: size, height: size)
    .clipShape(tile)
    .compositingGroup()
    .shadow(color: .black.opacity(0.82), radius: 14, x: 0, y: 8)
    .shadow(color: .black.opacity(0.72), radius: 32, x: 0, y: 14)
    .shadow(color: .white.opacity(0.045), radius: 30, x: 0, y: -8)
    .accessibilityHidden(true)
  }

  private var foregroundLogoImage: some View {
    Image(uiImage: WelcomeAssets.foregroundLogo)
      .resizable()
      .scaledToFit()
      .frame(width: logoFrame, height: logoFrame)
      .offset(x: 2, y: -20)
  }

  private var logoMask: some View {
    foregroundLogoImage
  }
}

private struct WelcomeButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        Capsule(style: .continuous)
          .fill(Color(red: 0.161, green: 0.161, blue: 0.161))
      }
      .overlay {
        Capsule(style: .continuous)
          .stroke(
            LinearGradient(
              colors: [.white.opacity(0.12), .white.opacity(0.035)],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 1
          )
      }
      .shadow(color: .black.opacity(0.62), radius: 16, y: 9)
      .brightness(configuration.isPressed ? 0.055 : 0)
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
      .contentShape(Capsule(style: .continuous))
  }
}

private enum WelcomeAssets {
  static let logo: UIImage = {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
          let image = UIImage(contentsOfFile: url.path)
    else { return UIImage() }
    return image
  }()

  static let foregroundLogo = removingBlackBackground(from: logo)

  private static func removingBlackBackground(from image: UIImage) -> UIImage {
    guard let source = image.cgImage else { return image }

    let width = source.width
    let height = source.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: source.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo
    ) else { return image }

    context.interpolationQuality = .none
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

    for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
      let peak = max(pixels[offset], pixels[offset + 1], pixels[offset + 2])
      pixels[offset + 3] = peak <= 4 ? 0 : UInt8(min(255, Int(peak) + 5))
    }

    guard let foreground = context.makeImage() else { return image }
    return UIImage(cgImage: foreground, scale: image.scale, orientation: image.imageOrientation)
  }
}

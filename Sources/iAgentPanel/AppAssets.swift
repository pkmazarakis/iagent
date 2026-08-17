import AppKit
import SwiftUI

enum AppAssets {
  static let openAIBlossom = templateSVG(named: "openai-blossom", size: 20)
  static let messageCircle = templateSVG(named: "message-circle", size: 24)
  static let messageCloudSyncCloud = templateSVG(named: "message-cloud-sync-cloud", size: 24)
  static let messageCloudSyncArrows = templateSVG(named: "message-cloud-sync-arrows", size: 24)
  static let messageCloudCheck = templateSVG(named: "message-cloud-check", size: 24)

  private static func templateSVG(named name: String, size: CGFloat) -> NSImage? {
    guard let url = PanelResourceBundle.bundle.url(
      forResource: name,
      withExtension: "svg",
      subdirectory: "Brand"
    ), let image = NSImage(contentsOf: url), let copy = image.copy() as? NSImage
    else {
      return nil
    }

    copy.isTemplate = true
    copy.size = NSSize(width: size, height: size)
    return copy
  }
}

struct OpenAIBlossomIcon: View {
  var size: CGFloat = 20
  var color: Color = .white
  var rotation: Angle = .zero

  var body: some View {
    Group {
      if let image = AppAssets.openAIBlossom {
        Image(nsImage: image)
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .resizable()
          .scaledToFit()
      }
    }
    .foregroundStyle(color)
    .frame(width: size, height: size)
    .rotationEffect(rotation)
    .accessibilityHidden(true)
  }
}

struct MessageCircleIcon: View {
  var size: CGFloat = 20
  var color: Color = .white

  var body: some View {
    Group {
      if let image = AppAssets.messageCircle {
        Image(nsImage: image)
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "message")
          .resizable()
          .scaledToFit()
      }
    }
    .foregroundStyle(color)
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

import AppKit
import SwiftUI

enum AppAssets {
  static let openAIBlossom: NSImage? = {
    guard let url = Bundle.module.url(
      forResource: "openai-blossom",
      withExtension: "svg",
      subdirectory: "Brand"
    ), let image = NSImage(contentsOf: url), let copy = image.copy() as? NSImage
    else {
      return nil
    }

    copy.isTemplate = true
    copy.size = NSSize(width: 20, height: 20)
    return copy
  }()
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

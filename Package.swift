// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlistPath = packageRoot + "/Sources/iAgentPanel/Info.plist"

let package = Package(
  name: "iAgentPanel",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "iAgentPanel", targets: ["iAgentPanel"])
  ],
  dependencies: [
    .package(path: "Vendor/swift-markdown-engine")
  ],
  targets: [
    .executableTarget(
      name: "iAgentPanel",
      dependencies: [
        .product(name: "MarkdownEngine", package: "swift-markdown-engine")
      ],
      exclude: ["Info.plist"],
      resources: [
        .copy("Resources/Brand"),
        .copy("Resources/CalendarDays"),
      ],
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("Carbon"),
        .linkedFramework("EventKit"),
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("Speech"),
        .linkedLibrary("sqlite3"),
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", infoPlistPath,
        ]),
      ]
    )
  ]
)

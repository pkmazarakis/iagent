// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlistPath = packageRoot + "/Sources/iAgentPanel/Info.plist"

let package = Package(
  name: "iAgentPanel",
  platforms: [
    .macOS(.v14),
    .iOS(.v17)
  ],
  products: [
    .executable(name: "iAgentPanel", targets: ["iAgentPanel"]),
    .library(name: "iAgentCore", targets: ["iAgentCore"]),
    .library(name: "iAgentActionContracts", targets: ["iAgentActionContracts"]),
    .library(name: "iAgentActions", targets: ["iAgentActions"])
  ],
  dependencies: [
    .package(path: "Vendor/swift-markdown-engine")
  ],
  targets: [
    .target(
      name: "iAgentCore",
      linkerSettings: [
        .linkedFramework("CloudKit")
      ]
    ),
    .target(
      name: "iAgentActionContracts"
    ),
    .target(
      name: "iAgentActions",
      dependencies: ["iAgentActionContracts", "iAgentCore"]
    ),
    .executableTarget(
      name: "iAgentPanel",
      dependencies: [
        "iAgentCore",
        .product(name: "MarkdownEngine", package: "swift-markdown-engine")
      ],
      exclude: [
        "Info.plist",
        "iAgentPanel.entitlements",
        "iAgentPanelRelease.entitlements",
        "iAgentPanelTestFlight.entitlements",
        "Resources/iAgentPanel.icns",
      ],
      resources: [
        .copy("Resources/Brand"),
        .copy("Resources/CalendarDays"),
      ],
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("Carbon"),
        .linkedFramework("Contacts"),
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
    ),
    .testTarget(
      name: "iAgentTests",
      dependencies: [
        "iAgentCore",
        "iAgentActionContracts",
        "iAgentActions",
        "iAgentPanel"
      ]
    )
  ]
)

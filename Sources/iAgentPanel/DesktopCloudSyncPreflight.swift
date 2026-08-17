import Foundation
import Security
import iAgentCore

struct DesktopCloudSyncEntitlements: Equatable, Sendable {
  var cloudServices: [String] = []
  var containerIdentifiers: [String] = []
  var containerEnvironment: String?
  var teamIdentifier: String?
  var applicationIdentifier: String?
  var pushEnvironment: String?

  static func current() -> DesktopCloudSyncEntitlements {
    guard let task = SecTaskCreateFromSelf(nil) else { return .init() }

    func value<T>(for key: String, as _: T.Type) -> T? {
      SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? T
    }

    let applicationIdentifier =
      value(for: "com.apple.application-identifier", as: String.self)
      ?? value(for: "application-identifier", as: String.self)

    return DesktopCloudSyncEntitlements(
      cloudServices: value(for: "com.apple.developer.icloud-services", as: [String].self) ?? [],
      containerIdentifiers: value(
        for: "com.apple.developer.icloud-container-identifiers",
        as: [String].self
      ) ?? [],
      containerEnvironment: value(
        for: "com.apple.developer.icloud-container-environment",
        as: String.self
      ),
      teamIdentifier: value(for: "com.apple.developer.team-identifier", as: String.self),
      applicationIdentifier: applicationIdentifier,
      pushEnvironment: value(for: "com.apple.developer.aps-environment", as: String.self)
    )
  }
}

struct DesktopCloudSyncPreflight: Equatable, Sendable {
  static let expectedContainerIdentifier = "iCloud.com.platon.iagent"
  static let expectedEnvironment = "Production"
  static let expectedTeamIdentifier = "625CGY297X"

  let isAvailable: Bool
  let phase: IAgentCloudSyncPhase
  let environment: String?
  let teamIdentifier: String?
  let message: String

  static func current(smokeTest: Bool) -> DesktopCloudSyncPreflight {
    evaluate(
      entitlements: .current(),
      smokeTest: smokeTest,
      disableRequested: ProcessInfo.processInfo.environment["IAGENT_DISABLE_CLOUD_SYNC"] == "1"
    )
  }

  static func evaluate(
    entitlements: DesktopCloudSyncEntitlements,
    smokeTest: Bool,
    disableRequested: Bool = false
  ) -> DesktopCloudSyncPreflight {
    if smokeTest {
      return unavailable("Cloud sync is disabled during smoke tests.", phase: .offline)
    }
    if disableRequested {
      return unavailable(
        "Cloud sync was disabled by IAGENT_DISABLE_CLOUD_SYNC.",
        phase: .offline
      )
    }
    guard entitlements.cloudServices.contains("CloudKit") else {
      return unavailable("This Mac build is not signed with the CloudKit entitlement.")
    }
    guard entitlements.containerIdentifiers.contains(expectedContainerIdentifier) else {
      return unavailable("This Mac build is not signed for \(expectedContainerIdentifier).")
    }
    guard entitlements.containerEnvironment == expectedEnvironment else {
      if let environment = entitlements.containerEnvironment {
        return unavailable(
          "This Mac build uses CloudKit \(environment); TestFlight uses \(expectedEnvironment).",
          environment: environment,
          teamIdentifier: resolvedTeamIdentifier(from: entitlements)
        )
      }
      return unavailable("This Mac build has no CloudKit environment entitlement.")
    }
    guard entitlements.pushEnvironment?.lowercased() == "production" else {
      return unavailable("This Mac build has no Production push-notification entitlement.")
    }
    guard let teamIdentifier = resolvedTeamIdentifier(from: entitlements),
          !teamIdentifier.isEmpty
    else {
      return unavailable("This Mac build has no Apple Developer Team identifier.")
    }
    guard teamIdentifier == expectedTeamIdentifier else {
      return unavailable(
        "This Mac build is signed by team \(teamIdentifier), not \(expectedTeamIdentifier).",
        environment: expectedEnvironment,
        teamIdentifier: teamIdentifier
      )
    }

    return DesktopCloudSyncPreflight(
      isAvailable: true,
      phase: .idle,
      environment: expectedEnvironment,
      teamIdentifier: teamIdentifier,
      message: "CloudKit Production is ready for team \(teamIdentifier)."
    )
  }

  private static func resolvedTeamIdentifier(
    from entitlements: DesktopCloudSyncEntitlements
  ) -> String? {
    if let explicit = entitlements.teamIdentifier, !explicit.isEmpty {
      return explicit
    }
    guard let applicationIdentifier = entitlements.applicationIdentifier,
          let separator = applicationIdentifier.firstIndex(of: ".")
    else { return nil }
    let prefix = String(applicationIdentifier[..<separator])
    return prefix.isEmpty ? nil : prefix
  }

  private static func unavailable(
    _ message: String,
    phase: IAgentCloudSyncPhase = .failed,
    environment: String? = nil,
    teamIdentifier: String? = nil
  ) -> DesktopCloudSyncPreflight {
    DesktopCloudSyncPreflight(
      isAvailable: false,
      phase: phase,
      environment: environment,
      teamIdentifier: teamIdentifier,
      message: message
    )
  }
}

struct DesktopSyncStoragePaths: Equatable, Sendable {
  static let metadataFileNames = [
    "device-id.txt",
    "note-index.json",
    "publish-index.json",
  ]

  let metadataDirectoryURL: URL
  let storeURL: URL
  let migrationWarning: String?

  static func prepare(
    documentRootURL: URL,
    smokeTest: Bool,
    applicationSupportDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) -> DesktopSyncStoragePaths {
    let legacyDirectory = documentRootURL.appendingPathComponent(".sync", isDirectory: true)
    if smokeTest {
      return DesktopSyncStoragePaths(
        metadataDirectoryURL: legacyDirectory,
        storeURL: legacyDirectory.appendingPathComponent("sync-store.json"),
        migrationWarning: nil
      )
    }

    let applicationSupportDirectory = applicationSupportDirectoryURL
      ?? IAgentLocalSyncStore.defaultFileURL(appIdentifier: "iAgentPanel")
        .deletingLastPathComponent()
    do {
      try migrateMetadata(
        from: legacyDirectory,
        to: applicationSupportDirectory,
        fileManager: fileManager
      )
      return DesktopSyncStoragePaths(
        metadataDirectoryURL: applicationSupportDirectory,
        storeURL: applicationSupportDirectory.appendingPathComponent("sync-store.json"),
        migrationWarning: nil
      )
    } catch {
      return DesktopSyncStoragePaths(
        metadataDirectoryURL: legacyDirectory,
        storeURL: applicationSupportDirectory.appendingPathComponent("sync-store.json"),
        migrationWarning: "Sync metadata migration failed: \(error.localizedDescription)"
      )
    }
  }

  private static func migrateMetadata(
    from sourceDirectory: URL,
    to destinationDirectory: URL,
    fileManager: FileManager
  ) throws {
    guard sourceDirectory.standardizedFileURL != destinationDirectory.standardizedFileURL else {
      return
    }

    for fileName in metadataFileNames {
      let source = sourceDirectory.appendingPathComponent(fileName)
      let destination = destinationDirectory.appendingPathComponent(fileName)
      guard fileManager.fileExists(atPath: source.path),
            !fileManager.fileExists(atPath: destination.path)
      else { continue }

      try fileManager.createDirectory(
        at: destinationDirectory,
        withIntermediateDirectories: true
      )
      try fileManager.copyItem(at: source, to: destination)
    }
  }
}

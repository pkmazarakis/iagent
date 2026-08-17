import Foundation

/// Recovery-first handling for a legacy local replica whose CloudKit change token is no longer valid.
public enum IAgentLegacySyncStateQuarantine {
  /// Archives the current replica files together, then removes only the CloudKit state so the next
  /// engine instance performs a full fetch. The local store is never removed by this operation.
  @discardableResult
  public static func archiveReplicaAndResetCloudState(
    storeURL: URL,
    cloudStateURL: URL,
    requireStore: Bool = true,
    fileManager: FileManager = .default
  ) throws -> URL {
    if requireStore, !fileManager.fileExists(atPath: storeURL.path) {
      throw CocoaError(.fileNoSuchFile)
    }

    let quarantineRoot = storeURL.deletingLastPathComponent()
      .appendingPathComponent("LegacyFixtureQuarantine", isDirectory: true)
    let batchDirectory = quarantineRoot
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try fileManager.createDirectory(at: batchDirectory, withIntermediateDirectories: true)

    if fileManager.fileExists(atPath: storeURL.path) {
      try fileManager.copyItem(
        at: storeURL,
        to: batchDirectory.appendingPathComponent("sync-store.json")
      )
    }
    if fileManager.fileExists(atPath: cloudStateURL.path) {
      try fileManager.copyItem(
        at: cloudStateURL,
        to: batchDirectory.appendingPathComponent("cloud-state.json")
      )
      try fileManager.removeItem(at: cloudStateURL)
    }

    return batchDirectory
  }
}

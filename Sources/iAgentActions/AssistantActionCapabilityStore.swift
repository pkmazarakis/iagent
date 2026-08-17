import Foundation
import iAgentActionContracts

public protocol AssistantActionCapabilityProviding: Sendable {
  func currentPolicy() async -> AssistantActionCapabilityPolicy
  nonisolated func preparationAuthorizationGeneration() -> UInt64
  nonisolated func withPreparationAuthorization(
    expectedGeneration: UInt64,
    capability: AssistantActionCapability,
    scopeID: String,
    operation: () throws -> Void
  ) throws
}

public actor AssistantActionCapabilityStore: AssistantActionCapabilityProviding {
  public let fileURL: URL
  public nonisolated let initialPolicy: AssistantActionCapabilityPolicy
  public nonisolated let initialLoadErrorMessage: String?
  private var policy: AssistantActionCapabilityPolicy
  private nonisolated let authorizationMirror: AssistantActionCapabilityAuthorizationMirror

  public init(fileURL: URL) {
    self.fileURL = fileURL
    let resolvedPolicy: AssistantActionCapabilityPolicy
    let loadErrorMessage: String?
    if FileManager.default.fileExists(atPath: fileURL.path) {
      do {
        let data = try Data(contentsOf: fileURL)
        resolvedPolicy = try JSONDecoder().decode(
          AssistantActionCapabilityPolicy.self,
          from: data
        )
        loadErrorMessage = nil
      } catch {
        // An existing preference file must never be mistaken for a fresh install. If it cannot
        // be read, fail closed and surface the problem instead of silently enabling actions.
        resolvedPolicy = .allDisabled
        loadErrorMessage = "Saved Assistant actions preferences could not be read. Preparation is off until you choose new settings."
      }
    } else {
      resolvedPolicy = .allPreparationEnabled
      loadErrorMessage = nil
    }
    initialPolicy = resolvedPolicy
    initialLoadErrorMessage = loadErrorMessage
    policy = resolvedPolicy
    authorizationMirror = AssistantActionCapabilityAuthorizationMirror(policy: resolvedPolicy)
  }

  public static func defaultFileURL(appIdentifier: String) -> URL {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return directory
      .appendingPathComponent(appIdentifier, isDirectory: true)
      .appendingPathComponent("assistant-action-capabilities.json")
  }

  public func currentPolicy() -> AssistantActionCapabilityPolicy {
    policy
  }

  public func setPreparationEnabled(
    _ enabled: Bool,
    for capability: AssistantActionCapability,
    scopeIDs: Set<String>? = nil
  ) throws {
    var updated = policy
    updated.setPreparationEnabled(enabled, for: capability, scopeIDs: scopeIDs)
    try authorizationMirror.replace(with: updated) {
      try persist(updated)
      policy = updated
    }
  }

  public func replaceForTesting(with policy: AssistantActionCapabilityPolicy) throws {
    try authorizationMirror.replace(with: policy) {
      try persist(policy)
      self.policy = policy
    }
  }

  public nonisolated func preparationAuthorizationGeneration() -> UInt64 {
    authorizationMirror.currentGeneration()
  }

  public nonisolated func withPreparationAuthorization(
    expectedGeneration: UInt64,
    capability: AssistantActionCapability,
    scopeID: String,
    operation: () throws -> Void
  ) throws {
    try authorizationMirror.withAuthorization(
      expectedGeneration: expectedGeneration,
      capability: capability,
      scopeID: scopeID,
      operation: operation
    )
  }

  private func persist(_ policy: AssistantActionCapabilityPolicy) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    #if os(iOS)
    let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    #else
    // Complete file protection is an iOS data-protection class and can fail with EPERM on macOS.
    let writeOptions: Data.WritingOptions = [.atomic]
    #endif
    try encoder.encode(policy).write(to: fileURL, options: writeOptions)
  }
}

public struct FixedAssistantActionCapabilityProvider: AssistantActionCapabilityProviding {
  public let policy: AssistantActionCapabilityPolicy

  public init(policy: AssistantActionCapabilityPolicy) {
    self.policy = policy
  }

  public func currentPolicy() async -> AssistantActionCapabilityPolicy {
    policy
  }

  public func preparationAuthorizationGeneration() -> UInt64 {
    0
  }

  public func withPreparationAuthorization(
    expectedGeneration: UInt64,
    capability: AssistantActionCapability,
    scopeID: String,
    operation: () throws -> Void
  ) throws {
    guard expectedGeneration == 0,
      policy.allowsPreparation(capability: capability, scopeID: scopeID)
    else {
      throw AssistantActionBrokerError.capabilityDisabled
    }
    try operation()
  }
}

private final class AssistantActionCapabilityAuthorizationMirror: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var policy: AssistantActionCapabilityPolicy

  init(policy: AssistantActionCapabilityPolicy) {
    self.policy = policy
  }

  func currentGeneration() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }

  func withAuthorization(
    expectedGeneration: UInt64,
    capability: AssistantActionCapability,
    scopeID: String,
    operation: () throws -> Void
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard generation == expectedGeneration,
      policy.allowsPreparation(capability: capability, scopeID: scopeID)
    else {
      throw AssistantActionBrokerError.capabilityDisabled
    }
    try operation()
  }

  func replace(
    with updatedPolicy: AssistantActionCapabilityPolicy,
    persistAndPublish: () throws -> Void
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    try persistAndPublish()
    policy = updatedPolicy
    generation &+= 1
  }
}

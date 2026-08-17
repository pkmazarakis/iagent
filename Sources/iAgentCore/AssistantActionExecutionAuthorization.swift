import Foundation

public struct AssistantActionExecutionIdentity: Equatable, Sendable {
  public let intentID: String
  public let proposalDigest: String
  public let capabilityID: String
  public let scopeID: String

  public init(
    intentID: String,
    proposalDigest: String,
    capabilityID: String,
    scopeID: String
  ) {
    self.intentID = intentID
    self.proposalDigest = proposalDigest
    self.capabilityID = capabilityID
    self.scopeID = scopeID
  }
}

public enum AssistantActionExecutionAuthorizationError: Error, Equatable, LocalizedError, Sendable {
  case bindingMismatch
  case alreadyUsed
  case intentExpired
  case confirmationExpired

  public var errorDescription: String? {
    switch self {
    case .bindingMismatch:
      "The execution authorization does not match this exact action."
    case .alreadyUsed:
      "The execution authorization has already been used."
    case .intentExpired:
      "The action review expired before the local mutation."
    case .confirmationExpired:
      "The confirmation expired before the local mutation."
    }
  }
}

/// A synchronous foreground authority whose lock remains held while an authorized mutation runs.
/// Foreground revocation uses that same lock, so it cannot interleave with a local action write.
public struct AssistantActionForegroundAuthority: Sendable {
  public typealias AuthorizedOperation = () throws -> Void
  public typealias AuthorizationBlock = @Sendable (
    _ expectedGeneration: UInt64,
    _ operation: AuthorizedOperation
  ) throws -> Void

  private let generationBlock: @Sendable () -> UInt64
  private let authorizationBlock: AuthorizationBlock

  public init(
    currentGeneration: @escaping @Sendable () -> UInt64,
    withActiveAuthorization: @escaping AuthorizationBlock
  ) {
    generationBlock = currentGeneration
    authorizationBlock = withActiveAuthorization
  }

  package func currentGeneration() -> UInt64 {
    generationBlock()
  }

  package func withActiveAuthorization(
    expectedGeneration: UInt64,
    operation: AuthorizedOperation
  ) throws {
    try authorizationBlock(expectedGeneration, operation)
  }
}

/// A single-use, broker-issued authorization for one exact action mutation.
///
/// The token becomes consumed only after foreground and capability generations validate and both
/// authority locks are held. Once the mutation begins it remains consumed even if persistence
/// throws; recovery must return through the broker and the deterministic store idempotency slot.
public final class AssistantActionExecutionAuthorization: @unchecked Sendable {
  public struct Binding: Equatable, Sendable {
    public let identity: AssistantActionExecutionIdentity
    public let proposalExpiresAt: Date
    public let confirmationExpiresAt: Date

    public init(
      identity: AssistantActionExecutionIdentity,
      proposalExpiresAt: Date,
      confirmationExpiresAt: Date
    ) {
      self.identity = identity
      self.proposalExpiresAt = proposalExpiresAt
      self.confirmationExpiresAt = confirmationExpiresAt
    }
  }

  package typealias CapabilityAuthorizationBlock = (
    _ expectedGeneration: UInt64,
    _ operation: () throws -> Void
  ) throws -> Void

  private enum State {
    case available
    case validating
    case consumed
  }

  private let binding: Binding
  private let now: @Sendable () -> Date
  private let foregroundAuthority: AssistantActionForegroundAuthority
  private let foregroundGeneration: UInt64
  private let capabilityGeneration: UInt64
  private let capabilityAuthorization: CapabilityAuthorizationBlock
  private let stateLock = NSLock()
  private var state: State = .available

  package init(
    binding: Binding,
    now: @escaping @Sendable () -> Date,
    foregroundAuthority: AssistantActionForegroundAuthority,
    foregroundGeneration: UInt64,
    capabilityGeneration: UInt64,
    withCapabilityAuthorization: @escaping CapabilityAuthorizationBlock
  ) {
    self.binding = binding
    self.now = now
    self.foregroundAuthority = foregroundAuthority
    self.foregroundGeneration = foregroundGeneration
    self.capabilityGeneration = capabilityGeneration
    capabilityAuthorization = withCapabilityAuthorization
  }

  package func performAuthorizedMutation(
    for identity: AssistantActionExecutionIdentity,
    operation: () throws -> Void
  ) throws {
    guard identity == binding.identity else {
      throw AssistantActionExecutionAuthorizationError.bindingMismatch
    }

    stateLock.lock()
    guard case .available = state else {
      stateLock.unlock()
      throw AssistantActionExecutionAuthorizationError.alreadyUsed
    }
    state = .validating
    stateLock.unlock()

    do {
      try foregroundAuthority.withActiveAuthorization(
        expectedGeneration: foregroundGeneration
      ) {
        try capabilityAuthorization(capabilityGeneration) {
          let currentTime = now()
          guard binding.proposalExpiresAt > currentTime else {
            throw AssistantActionExecutionAuthorizationError.intentExpired
          }
          guard binding.confirmationExpiresAt > currentTime else {
            throw AssistantActionExecutionAuthorizationError.confirmationExpired
          }
          // Cancellation does not automatically abort an actor hop. Recheck it at the same final
          // boundary as the volatile authority generations so a task cancelled while queued for
          // the local store cannot begin a mutation.
          guard !Task.isCancelled else { throw CancellationError() }

          stateLock.lock()
          guard case .validating = state else {
            stateLock.unlock()
            throw AssistantActionExecutionAuthorizationError.alreadyUsed
          }
          // From this point onward, any failure represents an attempted mutation and the token is
          // intentionally spent. Both authority locks remain held until `operation` returns.
          state = .consumed
          stateLock.unlock()
          try operation()
        }
      }
    } catch {
      stateLock.lock()
      if case .validating = state {
        // No mutation began, so the failed authorization has not consumed this token.
        state = .available
      }
      stateLock.unlock()
      throw error
    }
  }
}

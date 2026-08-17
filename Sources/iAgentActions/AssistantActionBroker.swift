import Foundation
import iAgentActionContracts
import iAgentCore

public enum AssistantActionBrokerError: Error, Equatable, LocalizedError, Sendable {
  case intentNotStaged
  case intentExpired
  case intentCancelled
  case capabilityDisabled
  case appNotForeground
  case confirmationMissing
  case confirmationMismatch
  case confirmationExpired
  case confirmationAlreadyUsed
  case executionInProgress
  case staleTarget(String)
  case executorFailure(String)
  case invalidHandoffState

  public var errorDescription: String? {
    switch self {
    case .intentNotStaged: "The action is no longer awaiting review."
    case .intentExpired: "The action review expired. Prepare it again."
    case .intentCancelled: "The action was cancelled."
    case .capabilityDisabled: "This action capability is disabled."
    case .appNotForeground: "Return to iAgent before confirming this action."
    case .confirmationMissing: "A fresh confirmation is required."
    case .confirmationMismatch: "The confirmation does not match this exact action."
    case .confirmationExpired: "The confirmation expired. Review the action again."
    case .confirmationAlreadyUsed: "This confirmation has already been used."
    case .executionInProgress: "The action is already being committed."
    case let .staleTarget(detail): "The action target changed: \(detail)"
    case let .executorFailure(detail): "The action could not be completed: \(detail)"
    case .invalidHandoffState: "There is no active native handoff for this action."
    }
  }
}

public struct AssistantActionConfirmation: Equatable, Sendable {
  public let id: UUID
  public let intentID: String
  public let proposalDigest: String
  public let userGestureID: UUID
  public let confirmedAt: Date
  public let expiresAt: Date

  init(
    id: UUID,
    intentID: String,
    proposalDigest: String,
    userGestureID: UUID,
    confirmedAt: Date,
    expiresAt: Date
  ) {
    self.id = id
    self.intentID = intentID
    self.proposalDigest = proposalDigest
    self.userGestureID = userGestureID
    self.confirmedAt = confirmedAt
    self.expiresAt = expiresAt
  }
}

public struct AssistantActionExecutionResult: Equatable, Sendable {
  public let disposition: AssistantActionReceiptDisposition
  public let entityIdentifier: String?
  public let revision: String?
  public let summary: String

  public init(
    disposition: AssistantActionReceiptDisposition,
    entityIdentifier: String? = nil,
    revision: String? = nil,
    summary: String
  ) {
    self.disposition = disposition
    self.entityIdentifier = entityIdentifier
    self.revision = revision
    self.summary = summary
  }
}

public protocol AssistantActionExecuting: Sendable {
  func revalidate(_ intent: AssistantActionIntent) async throws
  func execute(
    _ intent: AssistantActionIntent,
    authorization: AssistantActionExecutionAuthorization
  ) async throws -> AssistantActionExecutionResult
  /// Read-only crash recovery for a deterministic local commit whose receipt was not persisted.
  /// Implementations return a result only when the exact reviewed payload already exists at its
  /// action idempotency slot. This must never execute, write, request permission, or open UI.
  func reconcileCommittedResult(
    _ intent: AssistantActionIntent
  ) async throws -> AssistantActionExecutionResult?
}

public extension AssistantActionExecuting {
  func reconcileCommittedResult(
    _ intent: AssistantActionIntent
  ) async throws -> AssistantActionExecutionResult? {
    nil
  }
}

public enum AssistantActionPermissionError: Error, Equatable, LocalizedError, Sendable {
  case denied(String)
  case unavailable(String)

  public var errorDescription: String? {
    switch self {
    case let .denied(detail): "Required system permission was denied: \(detail)"
    case let .unavailable(detail): "Required system permission is unavailable: \(detail)"
    }
  }
}

public protocol AssistantActionPermissionAuthorizing: Sendable {
  func authorizeIfNeeded(for intent: AssistantActionIntent) async throws
}

public struct LocalAssistantActionPermissionAuthorizer: AssistantActionPermissionAuthorizing {
  public init() {}

  public func authorizeIfNeeded(for intent: AssistantActionIntent) async throws {
    guard intent.capability != .draftCalendarEvent else {
      throw AssistantActionPermissionError.unavailable(
        "Calendar drafts require the app's contextual EventKit authorizer."
      )
    }
  }
}

public struct FixedAssistantActionPermissionAuthorizer: AssistantActionPermissionAuthorizing {
  public init() {}
  public func authorizeIfNeeded(for intent: AssistantActionIntent) async throws {}
}

public enum AssistantNativeHandoffOutcome: Sendable {
  case completed(entityIdentifier: String?, revision: String?, summary: String)
  case cancelled(summary: String)
}

public enum AssistantActionPendingRestoreResult: Equatable, Sendable {
  case awaitingReview
  case nativeHandoff(AssistantActionReceipt)
  case terminal(AssistantActionReceipt)
  case cancelled
}

public actor AssistantActionBroker {
  private enum StageStatus {
    case awaitingReview
    case confirmed(AssistantActionConfirmation, used: Bool)
    case executing
    case handedOff
    case cancelled
    case completed
  }

  private struct Reservation: Equatable {
    enum Operation: Equatable {
      case staging
      case restoring
      case confirming
      case committing
      case cancelling
      case finalizingHandoff
    }

    let id: UUID
    let operation: Operation
  }

  private struct PendingResult {
    let receipt: AssistantActionReceipt
    let event: AssistantActionJournalEvent
  }

  private struct Stage {
    let intent: AssistantActionIntent
    var status: StageStatus
    var reservation: Reservation?
    var pendingResult: PendingResult?

    init(
      intent: AssistantActionIntent,
      status: StageStatus,
      reservation: Reservation? = nil,
      pendingResult: PendingResult? = nil
    ) {
      self.intent = intent
      self.status = status
      self.reservation = reservation
      self.pendingResult = pendingResult
    }
  }

  private let capabilities: any AssistantActionCapabilityProviding
  private let permissions: any AssistantActionPermissionAuthorizing
  private let executor: any AssistantActionExecuting
  private let journal: AssistantActionJournal
  private let now: @Sendable () -> Date
  private let isAppForeground: @Sendable () -> Bool
  private let foregroundAuthority: AssistantActionForegroundAuthority
  private let confirmationLifetime: TimeInterval
  private var stages: [String: Stage] = [:]

  public init(
    capabilities: any AssistantActionCapabilityProviding,
    permissions: any AssistantActionPermissionAuthorizing,
    executor: any AssistantActionExecuting,
    journal: AssistantActionJournal,
    confirmationLifetime: TimeInterval = 30,
    now: @escaping @Sendable () -> Date = Date.init,
    isAppForeground: @escaping @Sendable () -> Bool = { true },
    foregroundAuthority suppliedForegroundAuthority: AssistantActionForegroundAuthority? = nil
  ) {
    self.capabilities = capabilities
    self.permissions = permissions
    self.executor = executor
    self.journal = journal
    self.confirmationLifetime = max(0, min(30, confirmationLifetime))
    self.now = now
    self.isAppForeground = isAppForeground
    foregroundAuthority = suppliedForegroundAuthority ?? AssistantActionForegroundAuthority(
      currentGeneration: { 0 },
      withActiveAuthorization: { expectedGeneration, operation in
        guard expectedGeneration == 0, isAppForeground() else {
          throw AssistantActionBrokerError.appNotForeground
        }
        try operation()
      }
    )
  }

  @discardableResult
  public func stage(_ intent: AssistantActionIntent) async throws -> AssistantActionReviewCard {
    let currentTime = now()
    try AssistantActionProposalValidator.validateCanonicalIntent(intent, now: currentTime)
    if let existing = stages[intent.id] {
      guard existing.intent.proposalDigest == intent.proposalDigest else {
        throw AssistantActionBrokerError.confirmationMismatch
      }
      guard existing.reservation == nil else {
        throw AssistantActionBrokerError.executionInProgress
      }
      switch existing.status {
      case .awaitingReview:
        return existing.intent.review
      case .cancelled:
        throw AssistantActionBrokerError.intentCancelled
      case .confirmed, .executing, .handedOff, .completed:
        throw AssistantActionBrokerError.executionInProgress
      }
    }

    let reservation = Reservation(id: UUID(), operation: .staging)
    stages[intent.id] = Stage(
      intent: intent,
      status: .awaitingReview,
      reservation: reservation
    )
    do {
      // Durable truth always wins over fresh preparation policy and proposal expiry. In
      // particular, a restarted process must never turn an unresolved native handoff back into
      // an actionable review merely because the same proposal is staged directly again.
      if let receipt = try await journal.receipt(forIntentID: intent.id) {
        try validate(receipt: receipt, for: intent)
        guard var reserved = reservedStage(intentID: intent.id, reservation: reservation) else {
          throw AssistantActionBrokerError.executionInProgress
        }
        reserved.status = receipt.disposition == .nativeHandoffRequired
          ? .handedOff
          : .completed
        reserved.reservation = nil
        stages[intent.id] = reserved
        throw AssistantActionBrokerError.executionInProgress
      }

      // A cancellation is the durable tombstone for an exact proposal. A stale pending-review
      // file must not resurrect that same intent after a process restart.
      guard try await !journal.isCancelled(
        intentID: intent.id,
        proposalDigest: intent.proposalDigest
      ) else {
        throw AssistantActionBrokerError.intentCancelled
      }

      // A local note/to-do can be durably written immediately before receipt persistence fails.
      // Reconcile its deterministic store slot before expiry or current capability policy so a
      // process restart cannot hide the completed write or invite a semantic duplicate.
      if let recoveredReceipt = try await reconcileCommittedReceiptIfPresent(for: intent) {
        guard var reserved = reservedStage(intentID: intent.id, reservation: reservation) else {
          throw AssistantActionBrokerError.executionInProgress
        }
        reserved.status = .completed
        reserved.reservation = nil
        stages[intent.id] = reserved
        _ = recoveredReceipt
        throw AssistantActionBrokerError.executionInProgress
      }

      guard intent.expiresAt > currentTime else {
        throw AssistantActionBrokerError.intentExpired
      }
      try await requireCapability(for: intent)
      guard !Task.isCancelled else { throw CancellationError() }
      try await journal.append(
        AssistantActionJournalEntry(intent: intent, event: .proposed, timestamp: currentTime)
      )

      guard var reserved = reservedStage(intentID: intent.id, reservation: reservation) else {
        throw AssistantActionBrokerError.executionInProgress
      }
      reserved.reservation = nil
      stages[intent.id] = reserved
    } catch {
      if reservedStage(intentID: intent.id, reservation: reservation) != nil {
        stages.removeValue(forKey: intent.id)
      }
      throw error
    }
    return intent.review
  }

  /// Restores a persisted review without allowing a terminal receipt, native handoff, or cancelled
  /// proposal to become executable again. Durable receipts are reconciled before expiry and current
  /// preparation policy because recovery/cleanup does not grant new action authority.
  public func restorePendingReview(
    _ intent: AssistantActionIntent
  ) async throws -> AssistantActionPendingRestoreResult {
    let currentTime = now()
    try AssistantActionProposalValidator.validateCanonicalIntent(intent, now: currentTime)
    let previousStage = stages[intent.id]
    if let previousStage {
      guard previousStage.intent.proposalDigest == intent.proposalDigest else {
        throw AssistantActionBrokerError.confirmationMismatch
      }
      guard previousStage.reservation == nil else {
        throw AssistantActionBrokerError.executionInProgress
      }
      if case .cancelled = previousStage.status { return .cancelled }
    }
    let reservation = Reservation(id: UUID(), operation: .restoring)
    var staged = previousStage ?? Stage(intent: intent, status: .awaitingReview)
    staged.reservation = reservation
    stages[intent.id] = staged

    do {
      let receipt = try await journal.receipt(forIntentID: intent.id)
      guard var reserved = reservedStage(intentID: intent.id, reservation: reservation) else {
        throw AssistantActionBrokerError.executionInProgress
      }
      if let receipt {
        try validate(receipt: receipt, for: reserved.intent)
        reserved.status = receipt.disposition == .nativeHandoffRequired
          ? .handedOff
          : .completed
        reserved.reservation = nil
        stages[intent.id] = reserved
        return receipt.disposition == .nativeHandoffRequired
          ? .nativeHandoff(receipt)
          : .terminal(receipt)
      }

      if try await journal.isCancelled(
        intentID: intent.id,
        proposalDigest: intent.proposalDigest
      ) {
        stages.removeValue(forKey: intent.id)
        return .cancelled
      }

      if let recoveredReceipt = try await reconcileCommittedReceiptIfPresent(for: intent) {
        guard var recovered = reservedStage(
          intentID: intent.id,
          reservation: reservation
        ) else {
          throw AssistantActionBrokerError.executionInProgress
        }
        recovered.status = .completed
        recovered.reservation = nil
        stages[intent.id] = recovered
        return .terminal(recoveredReceipt)
      }

      // Only a genuinely uncommitted review is subject to current expiry/capability policy.
      guard intent.expiresAt > currentTime else {
        throw AssistantActionBrokerError.intentExpired
      }
      try await requireCapability(for: intent)
      guard !Task.isCancelled else { throw CancellationError() }
      if case .none = previousStage {
        try await journal.append(
          AssistantActionJournalEntry(intent: intent, event: .proposed, timestamp: currentTime)
        )
      }

      guard var reservedAfterPolicy = reservedStage(
        intentID: intent.id,
        reservation: reservation
      ) else {
        throw AssistantActionBrokerError.executionInProgress
      }
      reservedAfterPolicy.status = .awaitingReview
      reservedAfterPolicy.reservation = nil
      stages[intent.id] = reservedAfterPolicy
      return .awaitingReview
    } catch {
      if case .none = previousStage {
        if reservedStage(intentID: intent.id, reservation: reservation) != nil {
          stages.removeValue(forKey: intent.id)
        }
      } else if let previousStage,
                reservedStage(intentID: intent.id, reservation: reservation) != nil
      {
        stages[intent.id] = previousStage
      }
      throw error
    }
  }

  public func confirm(
    intentID: String,
    userGestureID: UUID
  ) async throws -> AssistantActionConfirmation {
    guard var stage = stages[intentID] else {
      throw AssistantActionBrokerError.intentNotStaged
    }
    guard stage.reservation == nil else {
      throw AssistantActionBrokerError.executionInProgress
    }
    let currentTime = now()
    switch stage.status {
    case .awaitingReview:
      guard stage.intent.expiresAt > currentTime else {
        throw AssistantActionBrokerError.intentExpired
      }
      guard isAppForeground() else {
        throw AssistantActionBrokerError.appNotForeground
      }
    case .cancelled:
      throw AssistantActionBrokerError.intentCancelled
    case .confirmed(_, true):
      throw AssistantActionBrokerError.confirmationAlreadyUsed
    case .confirmed, .executing, .handedOff, .completed:
      throw AssistantActionBrokerError.executionInProgress
    }

    let confirmation = AssistantActionConfirmation(
      id: UUID(),
      intentID: stage.intent.id,
      proposalDigest: stage.intent.proposalDigest,
      userGestureID: userGestureID,
      confirmedAt: currentTime,
      expiresAt: currentTime.addingTimeInterval(confirmationLifetime)
    )
    let reservation = Reservation(id: UUID(), operation: .confirming)
    stage.reservation = reservation
    stages[intentID] = stage
    do {
      try await requireCapability(for: stage.intent)
      guard !Task.isCancelled else { throw CancellationError() }
      try await journal.append(
        AssistantActionJournalEntry(
          intent: stage.intent,
          event: .confirmed,
          timestamp: currentTime
        )
      )
      guard var reserved = reservedStage(intentID: intentID, reservation: reservation) else {
        throw AssistantActionBrokerError.executionInProgress
      }
      reserved.status = .confirmed(confirmation, used: false)
      reserved.reservation = nil
      stages[intentID] = reserved
    } catch {
      restoreStage(
        intentID: intentID,
        reservation: reservation,
        status: .awaitingReview
      )
      throw error
    }
    return confirmation
  }

  public func commit(
    _ confirmation: AssistantActionConfirmation
  ) async throws -> AssistantActionReceipt {
    guard var stage = stages[confirmation.intentID] else {
      throw AssistantActionBrokerError.intentNotStaged
    }
    guard stage.reservation == nil else {
      throw AssistantActionBrokerError.executionInProgress
    }
    guard stage.intent.proposalDigest == confirmation.proposalDigest else {
      throw AssistantActionBrokerError.confirmationMismatch
    }
    let previousStatus = stage.status
    switch stage.status {
    case let .confirmed(expected, used):
      guard expected == confirmation else {
        throw AssistantActionBrokerError.confirmationMismatch
      }
      guard !used else {
        throw AssistantActionBrokerError.confirmationAlreadyUsed
      }
    case .awaitingReview:
      throw AssistantActionBrokerError.confirmationMissing
    case .cancelled:
      throw AssistantActionBrokerError.intentCancelled
    case .executing, .handedOff, .completed:
      // A handed-off or completed stage is replayable only when its durable receipt verifies.
      break
    }

    let reservation = Reservation(id: UUID(), operation: .committing)
    stage.status = .confirmed(confirmation, used: true)
    if case .handedOff = previousStatus { stage.status = .handedOff }
    if case .completed = previousStatus { stage.status = .completed }
    stage.reservation = reservation
    stages[confirmation.intentID] = stage

    let receiptLookup: AssistantActionReceipt?
    do {
      receiptLookup = try await journal.receipt(forIntentID: confirmation.intentID)
    } catch {
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: replayRollbackStatus(for: previousStatus)
      )
      throw error
    }

    if let receipt = receiptLookup {
      do {
        try validate(receipt: receipt, for: stage.intent)
      } catch {
        restoreStage(
          intentID: confirmation.intentID,
          reservation: reservation,
          status: replayRollbackStatus(for: previousStatus)
        )
        throw error
      }
      guard var reserved = reservedStage(
        intentID: confirmation.intentID,
        reservation: reservation
      ) else {
        throw AssistantActionBrokerError.executionInProgress
      }
      reserved.status = receipt.disposition == .nativeHandoffRequired ? .handedOff : .completed
      reserved.pendingResult = nil
      reserved.reservation = nil
      stages[confirmation.intentID] = reserved
      return receipt.asReplay()
    }

    guard case .confirmed = previousStatus else {
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: previousStatus
      )
      throw AssistantActionBrokerError.invalidHandoffState
    }

    guard let reservedAfterLookup = reservedStage(
      intentID: confirmation.intentID,
      reservation: reservation
    ) else {
      throw AssistantActionBrokerError.executionInProgress
    }

    // If execution succeeded but receipt persistence failed, a fresh confirmation retries only
    // the durable record. It must never call the executor a second time in this process.
    if let pendingResult = reservedAfterLookup.pendingResult {
      do {
        try await journal.record(
          receipt: pendingResult.receipt,
          intent: reservedAfterLookup.intent,
          event: pendingResult.event
        )
        guard var reserved = reservedStage(
          intentID: confirmation.intentID,
          reservation: reservation
        ) else {
          throw AssistantActionBrokerError.executionInProgress
        }
        reserved.status = pendingResult.receipt.disposition == .nativeHandoffRequired
          ? .handedOff
          : .completed
        reserved.pendingResult = nil
        reserved.reservation = nil
        stages[confirmation.intentID] = reserved
        return pendingResult.receipt
      } catch {
        restoreStage(
          intentID: confirmation.intentID,
          reservation: reservation,
          status: .awaitingReview
        )
        throw error
      }
    }

    let currentTime = now()
    guard stage.intent.expiresAt > currentTime else {
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: .awaitingReview
      )
      throw AssistantActionBrokerError.intentExpired
    }
    guard confirmation.expiresAt > currentTime else {
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: .awaitingReview
      )
      throw AssistantActionBrokerError.confirmationExpired
    }
    guard isAppForeground() else {
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: .awaitingReview
      )
      throw AssistantActionBrokerError.appNotForeground
    }

    do {
      try await requireCapability(for: stage.intent)
    } catch {
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: .awaitingReview
      )
      throw error
    }
    if Task.isCancelled {
      try await persistCancellation(
        intent: stage.intent,
        intentID: confirmation.intentID,
        reservation: reservation
      )
      throw CancellationError()
    }

    do {
      try await permissions.authorizeIfNeeded(for: stage.intent)
    } catch is CancellationError {
      try await persistCancellation(
        intent: stage.intent,
        intentID: confirmation.intentID,
        reservation: reservation
      )
      throw CancellationError()
    } catch {
      try? await journal.append(
        AssistantActionJournalEntry(
          intent: stage.intent,
          event: .failed,
          timestamp: now(),
          errorCode: "os_permission"
        )
      )
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: .awaitingReview
      )
      throw error
    }

    do {
      try await revalidateCommitAuthorization(
        intent: stage.intent,
        confirmation: confirmation,
        reservation: reservation
      )
    } catch is CancellationError {
      try await persistCancellation(
        intent: stage.intent,
        intentID: confirmation.intentID,
        reservation: reservation
      )
      throw CancellationError()
    } catch {
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: .awaitingReview
      )
      throw error
    }

    do {
      try await journal.append(
        AssistantActionJournalEntry(
          intent: stage.intent,
          event: .executionStarted,
          timestamp: currentTime
        )
      )
    } catch {
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: .awaitingReview
      )
      throw AssistantActionBrokerError.executorFailure(
        "The audit journal could not be persisted; nothing was changed."
      )
    }

    do {
      try await revalidateCommitAuthorization(
        intent: stage.intent,
        confirmation: confirmation,
        reservation: reservation
      )
    } catch is CancellationError {
      try await persistCancellation(
        intent: stage.intent,
        intentID: confirmation.intentID,
        reservation: reservation
      )
      throw CancellationError()
    } catch {
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: .awaitingReview
      )
      throw error
    }

    guard var executing = reservedStage(
      intentID: confirmation.intentID,
      reservation: reservation
    ) else {
      throw AssistantActionBrokerError.executionInProgress
    }
    executing.status = .executing
    stages[confirmation.intentID] = executing

    let result: AssistantActionExecutionResult
    do {
      try await executor.revalidate(stage.intent)
      try await revalidateCommitAuthorization(
        intent: stage.intent,
        confirmation: confirmation,
        reservation: reservation
      )
      let identity = AssistantActionExecutionIdentity(
        intentID: stage.intent.id,
        proposalDigest: stage.intent.proposalDigest,
        capabilityID: stage.intent.capability.rawValue,
        scopeID: stage.intent.scope.id
      )
      let executionCapability = stage.intent.capability
      let executionScopeID = stage.intent.scope.id
      let executionAuthorization = AssistantActionExecutionAuthorization(
        binding: .init(
          identity: identity,
          proposalExpiresAt: stage.intent.expiresAt,
          confirmationExpiresAt: confirmation.expiresAt
        ),
        now: now,
        foregroundAuthority: foregroundAuthority,
        foregroundGeneration: foregroundAuthority.currentGeneration(),
        capabilityGeneration: capabilities.preparationAuthorizationGeneration(),
        withCapabilityAuthorization: { [capabilities] expectedGeneration, operation in
          try capabilities.withPreparationAuthorization(
            expectedGeneration: expectedGeneration,
            capability: executionCapability,
            scopeID: executionScopeID,
            operation: operation
          )
        }
      )
      result = try await executor.execute(
        stage.intent,
        authorization: executionAuthorization
      )
    } catch is CancellationError {
      try await persistCancellation(
        intent: stage.intent,
        intentID: confirmation.intentID,
        reservation: reservation
      )
      throw CancellationError()
    } catch {
      try? await journal.append(
        AssistantActionJournalEntry(
          intent: stage.intent,
          event: .failed,
          timestamp: now(),
          errorCode: String(describing: type(of: error))
        )
      )
      restoreStage(
        intentID: confirmation.intentID,
        reservation: reservation,
        status: .awaitingReview
      )
      if let brokerError = error as? AssistantActionBrokerError {
        throw brokerError
      }
      if let authorizationError = error as? AssistantActionExecutionAuthorizationError {
        switch authorizationError {
        case .intentExpired:
          throw AssistantActionBrokerError.intentExpired
        case .confirmationExpired:
          throw AssistantActionBrokerError.confirmationExpired
        case .bindingMismatch, .alreadyUsed:
          break
        }
      }
      throw AssistantActionBrokerError.executorFailure(error.localizedDescription)
    }

    let receipt = AssistantActionReceipt(
      id: "receipt_\(UUID().uuidString.lowercased())",
      intentID: stage.intent.id,
      proposalDigest: stage.intent.proposalDigest,
      capability: stage.intent.capability,
      disposition: result.disposition,
      entityIdentifier: result.entityIdentifier,
      revision: result.revision,
      summary: result.summary,
      committedAt: now()
    )
    let event: AssistantActionJournalEvent = result.disposition == .nativeHandoffRequired
      ? .handoffPresented
      : .committed
    do {
      // Publish handedOff/completed only after the receipt is durable.
      try await journal.record(receipt: receipt, intent: stage.intent, event: event)
    } catch {
      if var reserved = reservedStage(
        intentID: confirmation.intentID,
        reservation: reservation
      ) {
        reserved.status = .awaitingReview
        reserved.pendingResult = PendingResult(receipt: receipt, event: event)
        reserved.reservation = nil
        stages[confirmation.intentID] = reserved
      }
      throw error
    }
    guard var completed = reservedStage(
      intentID: confirmation.intentID,
      reservation: reservation
    ) else {
      throw AssistantActionBrokerError.executionInProgress
    }
    completed.status = result.disposition == .nativeHandoffRequired ? .handedOff : .completed
    completed.pendingResult = nil
    completed.reservation = nil
    stages[confirmation.intentID] = completed
    return receipt
  }

  public func cancel(intentID: String) async throws {
    guard var stage = stages[intentID] else {
      throw AssistantActionBrokerError.intentNotStaged
    }
    guard stage.reservation == nil else {
      throw AssistantActionBrokerError.executionInProgress
    }
    guard stage.pendingResult == nil else {
      throw AssistantActionBrokerError.executionInProgress
    }
    switch stage.status {
    case .awaitingReview, .confirmed:
      let priorStatus = stage.status
      let reservation = Reservation(id: UUID(), operation: .cancelling)
      stage.reservation = reservation
      stages[intentID] = stage
      do {
        try await journal.append(
          AssistantActionJournalEntry(intent: stage.intent, event: .cancelled, timestamp: now())
        )
        guard var reserved = reservedStage(intentID: intentID, reservation: reservation) else {
          throw AssistantActionBrokerError.executionInProgress
        }
        reserved.status = .cancelled
        reserved.reservation = nil
        stages[intentID] = reserved
      } catch {
        restoreStage(intentID: intentID, reservation: reservation, status: priorStatus)
        throw error
      }
    case .cancelled:
      return
    case .executing, .handedOff, .completed:
      throw AssistantActionBrokerError.executionInProgress
    }
  }

  public func finalizeNativeHandoff(
    intentID: String,
    proposalDigest: String,
    outcome: AssistantNativeHandoffOutcome
  ) async throws -> AssistantActionReceipt {
    guard var stage = stages[intentID] else {
      throw AssistantActionBrokerError.intentNotStaged
    }
    guard stage.intent.proposalDigest == proposalDigest else {
      throw AssistantActionBrokerError.confirmationMismatch
    }
    guard stage.reservation == nil else {
      throw AssistantActionBrokerError.executionInProgress
    }
    let previousStatus = stage.status
    let reservation = Reservation(id: UUID(), operation: .finalizingHandoff)
    stage.reservation = reservation
    stages[intentID] = stage

    let durableReceipt: AssistantActionReceipt?
    do {
      durableReceipt = try await journal.receipt(forIntentID: intentID)
    } catch {
      restoreStage(intentID: intentID, reservation: reservation, status: previousStatus)
      throw error
    }
    guard let durableReceipt else {
      restoreStage(intentID: intentID, reservation: reservation, status: previousStatus)
      throw AssistantActionBrokerError.invalidHandoffState
    }
    do {
      try validate(receipt: durableReceipt, for: stage.intent)
    } catch {
      restoreStage(intentID: intentID, reservation: reservation, status: previousStatus)
      throw error
    }
    if durableReceipt.disposition == .handoffCompleted
      || durableReceipt.disposition == .handoffCancelled
    {
      guard var reserved = reservedStage(intentID: intentID, reservation: reservation) else {
        throw AssistantActionBrokerError.executionInProgress
      }
      reserved.status = .completed
      reserved.reservation = nil
      stages[intentID] = reserved
      return durableReceipt.asReplay()
    }

    // Once native UI reports an external outcome, that exact truth is immutable even when its
    // first journal write fails. A later, conflicting delegate callback must only retry the
    // original terminal receipt; it can never replace saved/completed with cancelled (or vice
    // versa).
    if let pendingResult = stage.pendingResult {
      do {
        try await journal.record(
          receipt: pendingResult.receipt,
          intent: stage.intent,
          event: pendingResult.event
        )
      } catch {
        restoreStage(intentID: intentID, reservation: reservation, status: .handedOff)
        throw error
      }
      guard var reserved = reservedStage(intentID: intentID, reservation: reservation) else {
        throw AssistantActionBrokerError.executionInProgress
      }
      reserved.status = .completed
      reserved.pendingResult = nil
      reserved.reservation = nil
      stages[intentID] = reserved
      return pendingResult.receipt
    }
    guard durableReceipt.disposition == .nativeHandoffRequired,
      case .handedOff = previousStatus
    else {
      restoreStage(intentID: intentID, reservation: reservation, status: previousStatus)
      throw AssistantActionBrokerError.invalidHandoffState
    }
    let disposition: AssistantActionReceiptDisposition
    let entityIdentifier: String?
    let revision: String?
    let summary: String
    let event: AssistantActionJournalEvent
    switch outcome {
    case let .completed(entityID, resultRevision, resultSummary):
      disposition = .handoffCompleted
      entityIdentifier = entityID
      revision = resultRevision
      summary = resultSummary
      event = .handoffCompleted
    case let .cancelled(resultSummary):
      disposition = .handoffCancelled
      entityIdentifier = nil
      revision = nil
      summary = resultSummary
      event = .handoffCancelled
    }
    let receipt = AssistantActionReceipt(
      id: "receipt_\(UUID().uuidString.lowercased())",
      intentID: stage.intent.id,
      proposalDigest: stage.intent.proposalDigest,
      capability: stage.intent.capability,
      disposition: disposition,
      entityIdentifier: entityIdentifier,
      revision: revision,
      summary: summary,
      committedAt: now()
    )
    do {
      // Keep the stage handed off if the terminal receipt cannot be persisted so the native UI
      // can report the failure and retry the exact callback safely.
      try await journal.record(receipt: receipt, intent: stage.intent, event: event)
    } catch {
      if var reserved = reservedStage(intentID: intentID, reservation: reservation) {
        reserved.status = .handedOff
        reserved.pendingResult = PendingResult(receipt: receipt, event: event)
        reserved.reservation = nil
        stages[intentID] = reserved
      }
      throw error
    }
    guard var reserved = reservedStage(intentID: intentID, reservation: reservation) else {
      throw AssistantActionBrokerError.executionInProgress
    }
    reserved.status = .completed
    reserved.reservation = nil
    stages[intentID] = reserved
    return receipt
  }

  public func receipt(for intentID: String) async throws -> AssistantActionReceipt? {
    try await journal.receipt(forIntentID: intentID)
  }

  private func requireCapability(for intent: AssistantActionIntent) async throws {
    let policy = await capabilities.currentPolicy()
    guard policy.allowsPreparation(
      capability: intent.capability,
      scopeID: intent.scope.id
    ) else {
      throw AssistantActionBrokerError.capabilityDisabled
    }
  }

  /// Recovers the durable truth for a completed local action after the store write succeeded but
  /// the audit receipt write failed and the process terminated. The executor performs an exact,
  /// read-only deterministic-slot comparison; this path never re-executes an action.
  private func reconcileCommittedReceiptIfPresent(
    for intent: AssistantActionIntent
  ) async throws -> AssistantActionReceipt? {
    guard let result = try await executor.reconcileCommittedResult(intent) else { return nil }
    guard result.disposition == .committedLocally else {
      throw AssistantActionBrokerError.executorFailure(
        "Crash recovery returned a non-local action result. Nothing was changed."
      )
    }
    let receipt = AssistantActionReceipt(
      id: "receipt_\(UUID().uuidString.lowercased())",
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      capability: intent.capability,
      disposition: .committedLocally,
      entityIdentifier: result.entityIdentifier,
      revision: result.revision,
      summary: result.summary,
      committedAt: now()
    )
    try await journal.record(receipt: receipt, intent: intent, event: .committed)
    return receipt
  }

  private func reservedStage(
    intentID: String,
    reservation: Reservation
  ) -> Stage? {
    guard let stage = stages[intentID], stage.reservation == reservation else { return nil }
    return stage
  }

  private func restoreStage(
    intentID: String,
    reservation: Reservation,
    status: StageStatus
  ) {
    guard var stage = reservedStage(intentID: intentID, reservation: reservation) else { return }
    stage.status = status
    stage.reservation = nil
    stages[intentID] = stage
  }

  private func replayRollbackStatus(for status: StageStatus) -> StageStatus {
    if case .confirmed = status { return .awaitingReview }
    return status
  }

  private func validate(
    receipt: AssistantActionReceipt,
    for intent: AssistantActionIntent
  ) throws {
    guard receipt.intentID == intent.id,
      receipt.proposalDigest == intent.proposalDigest,
      receipt.capability == intent.capability
    else {
      throw AssistantActionBrokerError.confirmationMismatch
    }
  }

  /// Rechecks all volatile commit authority immediately before execution. Every preceding await
  /// (permission UI, journal I/O, and target revalidation) can suspend long enough for the app to
  /// background, the confirmation to expire, or the capability to be revoked.
  private func revalidateCommitAuthorization(
    intent: AssistantActionIntent,
    confirmation: AssistantActionConfirmation,
    reservation: Reservation
  ) async throws {
    guard reservedStage(intentID: intent.id, reservation: reservation) != nil else {
      throw AssistantActionBrokerError.executionInProgress
    }
    guard !Task.isCancelled else { throw CancellationError() }
    var currentTime = now()
    guard intent.expiresAt > currentTime else {
      throw AssistantActionBrokerError.intentExpired
    }
    guard confirmation.expiresAt > currentTime else {
      throw AssistantActionBrokerError.confirmationExpired
    }
    guard isAppForeground() else {
      throw AssistantActionBrokerError.appNotForeground
    }

    try await requireCapability(for: intent)

    guard reservedStage(intentID: intent.id, reservation: reservation) != nil else {
      throw AssistantActionBrokerError.executionInProgress
    }
    guard !Task.isCancelled else { throw CancellationError() }
    currentTime = now()
    guard intent.expiresAt > currentTime else {
      throw AssistantActionBrokerError.intentExpired
    }
    guard confirmation.expiresAt > currentTime else {
      throw AssistantActionBrokerError.confirmationExpired
    }
    guard isAppForeground() else {
      throw AssistantActionBrokerError.appNotForeground
    }
  }

  private func persistCancellation(
    intent: AssistantActionIntent,
    intentID: String,
    reservation: Reservation
  ) async throws {
    do {
      try await journal.append(
        AssistantActionJournalEntry(
          intent: intent,
          event: .cancelled,
          timestamp: now(),
          errorCode: "cancelled"
        )
      )
      guard var reserved = reservedStage(intentID: intentID, reservation: reservation) else {
        throw AssistantActionBrokerError.executionInProgress
      }
      reserved.status = .cancelled
      reserved.reservation = nil
      stages[intentID] = reserved
    } catch {
      restoreStage(intentID: intentID, reservation: reservation, status: .awaitingReview)
      throw error
    }
  }
}

import CryptoKit
import Foundation
import iAgentActionContracts
import iAgentCore

public actor LocalFirstAssistantActionExecutor: AssistantActionExecuting {
  private struct DeterministicLocalAction {
    let identifier: UUID
    let payload: IAgentSyncPayload
    let summary: String
  }

  private let store: IAgentLocalSyncStore
  private let sourceDeviceID: String

  public init(store: IAgentLocalSyncStore, sourceDeviceID: String) {
    self.store = store
    self.sourceDeviceID = sourceDeviceID
  }

  public func revalidate(_ intent: AssistantActionIntent) async throws {
    guard intent.capability == intent.payload.capability else {
      throw AssistantActionBrokerError.confirmationMismatch
    }
    switch intent.payload {
    case let .createTodo(todo):
      if let listName = todo.listName {
        let snapshot = await store.snapshot()
        let matches = snapshot.todoLists.filter {
          $0.deletedAt == nil && $0.name.caseInsensitiveCompare(listName) == .orderedSame
        }
        guard matches.count == 1 else {
          throw AssistantActionBrokerError.staleTarget(
            matches.isEmpty
              ? "the selected to-do list no longer exists"
              : "the selected to-do list is no longer unique"
          )
        }
      }
      try await requireCreateSlotAvailable(for: intent)
    case .createNote:
      try await requireCreateSlotAvailable(for: intent)
    case .calendarDraft, .codexTaskRequest:
      break
    }
  }

  public func execute(
    _ intent: AssistantActionIntent,
    authorization: AssistantActionExecutionAuthorization
  ) async throws -> AssistantActionExecutionResult {
    guard !Task.isCancelled else { throw CancellationError() }
    let identity = executionIdentity(for: intent)
    switch intent.payload {
    case let .createTodo(todo):
      guard let localAction = deterministicLocalAction(for: intent),
            case let .todo(record) = localAction.payload
      else { throw AssistantActionBrokerError.confirmationMismatch }
      do {
        _ = try await store.upsertActionTodo(
          record,
          expectedListName: todo.listName,
          identity: identity,
          authorization: authorization
        )
      } catch let error as IAgentLocalSyncStoreError {
        switch error {
        case let .actionTargetChanged(detail):
          throw AssistantActionBrokerError.staleTarget(detail)
        case .actionIdempotencyConflict:
          throw AssistantActionBrokerError.staleTarget(
            "the idempotency slot contains different data"
          )
        default:
          throw error
        }
      } catch let error as AssistantActionExecutionAuthorizationError {
        throw brokerError(for: error)
      }
      return AssistantActionExecutionResult(
        disposition: .committedLocally,
        entityIdentifier: localAction.identifier.uuidString,
        revision: revision(for: localAction.payload),
        summary: localAction.summary
      )

    case .createNote:
      guard let localAction = deterministicLocalAction(for: intent),
            case let .note(record) = localAction.payload
      else { throw AssistantActionBrokerError.confirmationMismatch }
      do {
        _ = try await store.upsertActionNote(
          record,
          identity: identity,
          authorization: authorization
        )
      } catch let error as IAgentLocalSyncStoreError {
        if case .actionIdempotencyConflict = error {
          throw AssistantActionBrokerError.staleTarget(
            "the idempotency slot contains different data"
          )
        }
        throw error
      } catch let error as AssistantActionExecutionAuthorizationError {
        throw brokerError(for: error)
      }
      return AssistantActionExecutionResult(
        disposition: .committedLocally,
        entityIdentifier: localAction.identifier.uuidString,
        revision: revision(for: localAction.payload),
        summary: localAction.summary
      )

    case .calendarDraft:
      try performAuthorizedHandoff(authorization, identity: identity)
      return AssistantActionExecutionResult(
        disposition: .nativeHandoffRequired,
        summary: "Calendar draft is ready for Apple’s event editor. No event has been saved."
      )

    case .codexTaskRequest:
      try performAuthorizedHandoff(authorization, identity: identity)
      return AssistantActionExecutionResult(
        disposition: .nativeHandoffRequired,
        summary: "Codex request is ready for user-controlled handoff. No task has been created."
      )
    }
  }

  /// Recovers a truthful result from a deterministic local record after a crash between the
  /// durable store write and broker-receipt persistence. This path is read-only and never invokes
  /// target revalidation, permissions, native handoffs, or another mutation.
  public func reconcileCommittedResult(
    _ intent: AssistantActionIntent
  ) async throws -> AssistantActionExecutionResult? {
    guard !Task.isCancelled else { throw CancellationError() }
    guard intent.capability == intent.payload.capability else {
      throw AssistantActionBrokerError.confirmationMismatch
    }
    guard let localAction = deterministicLocalAction(for: intent) else {
      // External native handoffs cannot be proven from the local sync store.
      return nil
    }
    do {
      guard try await store.reconcileActionPayload(localAction.payload) else { return nil }
    } catch let error as IAgentLocalSyncStoreError {
      if case .actionIdempotencyConflict = error {
        throw AssistantActionBrokerError.staleTarget(
          "the idempotency slot contains different data"
        )
      }
      throw error
    }
    return AssistantActionExecutionResult(
      disposition: .committedLocally,
      entityIdentifier: localAction.identifier.uuidString,
      revision: revision(for: localAction.payload),
      summary: localAction.summary
    )
  }

  private func executionIdentity(
    for intent: AssistantActionIntent
  ) -> AssistantActionExecutionIdentity {
    AssistantActionExecutionIdentity(
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      capabilityID: intent.capability.rawValue,
      scopeID: intent.scope.id
    )
  }

  private func performAuthorizedHandoff(
    _ authorization: AssistantActionExecutionAuthorization,
    identity: AssistantActionExecutionIdentity
  ) throws {
    do {
      try authorization.performAuthorizedMutation(for: identity) {}
    } catch let error as AssistantActionExecutionAuthorizationError {
      throw brokerError(for: error)
    }
  }

  private func brokerError(
    for error: AssistantActionExecutionAuthorizationError
  ) -> AssistantActionBrokerError {
    switch error {
    case .bindingMismatch:
      .confirmationMismatch
    case .alreadyUsed:
      .confirmationAlreadyUsed
    case .intentExpired:
      .intentExpired
    case .confirmationExpired:
      .confirmationExpired
    }
  }

  private func requireCreateSlotAvailable(for intent: AssistantActionIntent) async throws {
    guard let localAction = deterministicLocalAction(for: intent) else { return }
    guard let existing = await store.payload(for: localAction.payload.recordName) else { return }
    guard existing == localAction.payload else {
      throw AssistantActionBrokerError.staleTarget("the idempotency slot was changed")
    }
  }

  private func deterministicLocalAction(
    for intent: AssistantActionIntent
  ) -> DeterministicLocalAction? {
    let identifier = deterministicUUID(for: intent)
    switch intent.payload {
    case let .createTodo(todo):
      return DeterministicLocalAction(
        identifier: identifier,
        payload: .todo(
          SyncedTodo(
            id: identifier,
            title: todo.title,
            dueDate: todo.dueAt?.instant,
            listName: todo.listName,
            createdAt: intent.createdAt,
            updatedAt: intent.createdAt
          )
        ),
        summary: "Created the to-do locally."
      )
    case let .createNote(note):
      return DeterministicLocalAction(
        identifier: identifier,
        payload: .note(
          SyncedNote(
            id: identifier,
            title: note.title,
            body: note.body,
            createdAt: intent.createdAt,
            updatedAt: intent.createdAt,
            sourceDeviceID: sourceDeviceID
          )
        ),
        summary: "Created the note locally."
      )
    case .calendarDraft, .codexTaskRequest:
      return nil
    }
  }

  private func deterministicUUID(for intent: AssistantActionIntent) -> UUID {
    let hex = String(intent.proposalDigest.prefix(32))
    let part1 = String(hex.prefix(8))
    let part2 = String(hex.dropFirst(8).prefix(4))
    let part3 = String(hex.dropFirst(12).prefix(4))
    let part4 = String(hex.dropFirst(16).prefix(4))
    let part5 = String(hex.dropFirst(20).prefix(12))
    let uuidText = "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"
    return UUID(uuidString: uuidText) ?? UUID()
  }

  private func revision(for payload: IAgentSyncPayload) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(payload)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

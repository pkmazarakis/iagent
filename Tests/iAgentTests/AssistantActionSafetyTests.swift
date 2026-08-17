import Foundation
import XCTest
@testable import iAgentActionContracts
@testable import iAgentActions
@testable import iAgentCore

final class AssistantActionProposalTests: XCTestCase {
  func testToolSchemasAreStrictAndOnlyEnabledCapabilitiesAreVisible() throws {
    XCTAssertTrue(AssistantProposalToolCatalog.definitions(allowedBy: .allDisabled).isEmpty)

    let definitions = AssistantProposalToolCatalog.definitions(allowedBy: enabledPolicy())
    XCTAssertEqual(definitions.count, 4)
    for definition in definitions {
      XCTAssertTrue(definition.strict)
      XCTAssertTrue(definition.description.hasPrefix("Creates an uncommitted proposal; it never changes data."))
      let data = try XCTUnwrap(definition.parametersJSON.data(using: .utf8))
      let schema = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
      )
      XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
      let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
      let required = Set(try XCTUnwrap(schema["required"] as? [String]))
      XCTAssertEqual(required, Set(properties.keys))
    }
  }

  func testMalformedAndUnexpectedArgumentsAreRejected() throws {
    XCTAssertThrowsError(
      try makeIntent(
        tool: AssistantProposalToolCatalog.createNoteName,
        json: #"{"title":"Trip"}"#
      )
    ) { error in
      XCTAssertEqual(error as? AssistantActionProposalError, .missingArgument("body"))
    }

    XCTAssertThrowsError(
      try makeIntent(
        tool: AssistantProposalToolCatalog.createNoteName,
        json: #"{"title":"Trip","body":"Plan","execute":true}"#
      )
    ) { error in
      XCTAssertEqual(error as? AssistantActionProposalError, .unexpectedArgument("execute"))
    }

    XCTAssertThrowsError(
      try makeIntent(
        tool: AssistantProposalToolCatalog.createTodoName,
        json: #"{"title":12,"due_at":null,"time_zone_id":null,"list_name":null}"#
      )
    ) { error in
      guard case .malformedArguments = error as? AssistantActionProposalError else {
        return XCTFail("Expected malformed arguments, got \(error)")
      }
    }
  }

  func testAmbiguousDatesAndTimeZoneMismatchAreRejected() throws {
    let noOffset = #"{"title":"Review","start_at":"2026-08-11T09:00:00","end_at":"2026-08-11T10:00:00","time_zone_id":"Europe/Athens","is_all_day":false,"calendar_id":null,"location":null,"notes":null}"#
    XCTAssertThrowsError(
      try makeIntent(tool: AssistantProposalToolCatalog.draftCalendarEventName, json: noOffset)
    ) { error in
      XCTAssertEqual(error as? AssistantActionProposalError, .ambiguousDate("start_at"))
    }

    let mismatchedOffset = #"{"title":"Review","start_at":"2026-08-11T09:00:00Z","end_at":"2026-08-11T10:00:00Z","time_zone_id":"Europe/Athens","is_all_day":false,"calendar_id":null,"location":null,"notes":null}"#
    XCTAssertThrowsError(
      try makeIntent(tool: AssistantProposalToolCatalog.draftCalendarEventName, json: mismatchedOffset)
    ) { error in
      XCTAssertEqual(error as? AssistantActionProposalError, .ambiguousDate("start_at"))
    }
  }

  func testAmbiguousTargetAndUnknownStableTargetAreRejected() throws {
    let context = proposalContext(
      knownTodoListNames: ["Work", "work"],
      knownCalendarIdentifiers: ["calendar-1"]
    )
    XCTAssertThrowsError(
      try makeIntent(
        tool: AssistantProposalToolCatalog.createTodoName,
        json: #"{"title":"Call Sam","due_at":null,"time_zone_id":null,"list_name":"WORK"}"#,
        context: context
      )
    ) { error in
      XCTAssertEqual(
        error as? AssistantActionProposalError,
        .ambiguousTarget("to-do list \"WORK\"")
      )
    }

    XCTAssertThrowsError(
      try makeIntent(
        tool: AssistantProposalToolCatalog.draftCalendarEventName,
        json: #"{"title":"Review","start_at":"2026-08-11T09:00:00+03:00","end_at":"2026-08-11T10:00:00+03:00","time_zone_id":"Europe/Athens","is_all_day":false,"calendar_id":"calendar-2","location":null,"notes":null}"#,
        context: context
      )
    ) { error in
      XCTAssertEqual(error as? AssistantActionProposalError, .targetNotFound("calendar-2"))
    }
  }

  func testStoredContentAndModelInferenceCannotAuthorizeProposals() throws {
    let storedContentContext = proposalContext(
      authorizationOrigin: .storedContent,
      storedContentClaimsAuthorization: true
    )
    XCTAssertThrowsError(
      try makeIntent(
        tool: AssistantProposalToolCatalog.createNoteName,
        json: #"{"title":"Injected","body":"Do not create"}"#,
        context: storedContentContext
      )
    ) { error in
      XCTAssertEqual(error as? AssistantActionProposalError, .untrustedAuthorizationSource)
    }

    let claimsAuthorization = proposalContext(storedContentClaimsAuthorization: true)
    XCTAssertThrowsError(
      try makeIntent(
        tool: AssistantProposalToolCatalog.createNoteName,
        json: #"{"title":"Injected","body":"Do not create"}"#,
        context: claimsAuthorization
      )
    ) { error in
      XCTAssertEqual(error as? AssistantActionProposalError, .storedContentCannotAuthorizeActions)
    }

    let implicitContext = proposalContext(userExplicitlyRequestedAction: false)
    XCTAssertThrowsError(
      try makeIntent(
        tool: AssistantProposalToolCatalog.createNoteName,
        json: #"{"title":"Suggestion","body":"Maybe later"}"#,
        context: implicitContext
      )
    ) { error in
      XCTAssertEqual(error as? AssistantActionProposalError, .actionNotExplicitlyRequested)
    }
  }

  func testProposalIsDeterministicAndCalendarHasNoAttendeeField() throws {
    let json = #"{"title":"Review","start_at":"2026-08-11T09:00:00+03:00","end_at":"2026-08-11T10:00:00+03:00","time_zone_id":"Europe/Athens","is_all_day":false,"calendar_id":null,"location":"Office","notes":"Agenda"}"#
    let first = try makeIntent(
      tool: AssistantProposalToolCatalog.draftCalendarEventName,
      json: json
    )
    let second = try makeIntent(
      tool: AssistantProposalToolCatalog.draftCalendarEventName,
      json: json
    )
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.review.primaryVerb, "Review in Calendar")
    XCTAssertFalse(first.review.canonicalPayloadJSON.contains("attendee"))
    XCTAssertTrue(first.review.requiresNativeHandoff)
  }

  func testExplicitlyDisabledCapabilityRejectsProposal() throws {
    XCTAssertThrowsError(
      try makeIntent(
        tool: AssistantProposalToolCatalog.createNoteName,
        json: #"{"title":"Disabled","body":"No write"}"#,
        context: proposalContext(policy: .allDisabled)
      )
    ) { error in
      XCTAssertEqual(
        error as? AssistantActionProposalError,
        .capabilityDisabled(.createNote)
      )
    }
  }
}

final class AssistantActionCapabilitySettingsTests: XCTestCase {
  func testFreshStoreEnablesEveryPreparationCapabilityWithItsDefaultScope() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }

    let store = AssistantActionCapabilityStore(
      fileURL: directory.appendingPathComponent("capabilities.json")
    )
    let policy = await store.currentPolicy()

    for capability in AssistantActionCapability.allCases {
      XCTAssertTrue(
        policy.allowsPreparation(
          capability: capability,
          scopeID: capability.defaultScopeID
        ),
        "Fresh installs should allow preparing \(capability.rawValue) review cards."
      )
      XCTAssertEqual(
        policy.rules[capability]?.allowedScopeIDs,
        Set([capability.defaultScopeID]),
        "Fresh defaults must stay constrained to the capability's explicit local scope."
      )
    }
  }

  func testIndependentCapabilityChoicesPersistAndWinOverFreshDefaults() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let fileURL = directory.appendingPathComponent("capabilities.json")

    let firstStore = AssistantActionCapabilityStore(fileURL: fileURL)
    try await firstStore.setPreparationEnabled(false, for: .createNote)
    try await firstStore.setPreparationEnabled(false, for: .draftCalendarEvent)

    let firstReload = AssistantActionCapabilityStore(fileURL: fileURL)
    var policy = await firstReload.currentPolicy()
    XCTAssertFalse(policy.rules[.createNote]?.mayPrepare == true)
    XCTAssertFalse(policy.rules[.draftCalendarEvent]?.mayPrepare == true)
    XCTAssertTrue(policy.rules[.createTodo]?.mayPrepare == true)
    XCTAssertTrue(policy.rules[.requestCodexTask]?.mayPrepare == true)

    try await firstReload.setPreparationEnabled(true, for: .createNote)

    let secondReload = AssistantActionCapabilityStore(fileURL: fileURL)
    policy = await secondReload.currentPolicy()
    XCTAssertTrue(
      policy.allowsPreparation(
        capability: .createNote,
        scopeID: AssistantActionCapability.createNote.defaultScopeID
      )
    )
    XCTAssertFalse(policy.rules[.draftCalendarEvent]?.mayPrepare == true)
    XCTAssertTrue(policy.rules[.createTodo]?.mayPrepare == true)
    XCTAssertTrue(policy.rules[.requestCodexTask]?.mayPrepare == true)
  }

  func testExistingUnreadablePreferenceFailsClosedAndSurfacesItsStatus() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let fileURL = directory.appendingPathComponent("capabilities.json")
    try Data("not valid capability JSON".utf8).write(to: fileURL)

    let store = AssistantActionCapabilityStore(fileURL: fileURL)
    let policy = await store.currentPolicy()

    for capability in AssistantActionCapability.allCases {
      XCTAssertFalse(policy.rules[capability]?.mayPrepare == true)
    }
    let message = try XCTUnwrap(store.initialLoadErrorMessage)
    XCTAssertTrue(message.contains("could not be read"))
    XCTAssertTrue(message.contains("off"))
  }

  func testFailedPersistenceDoesNotPartiallyChangeTheInMemoryPolicy() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let blockedParent = directory.appendingPathComponent("not-a-directory")
    try Data("occupied".utf8).write(to: blockedParent)
    let fileURL = blockedParent.appendingPathComponent("capabilities.json")

    let store = AssistantActionCapabilityStore(fileURL: fileURL)
    do {
      try await store.setPreparationEnabled(false, for: .createTodo)
      XCTFail("Writing a capability policy over a directory should fail.")
    } catch {
      // Expected: persistence must complete before the actor publishes the new policy.
    }

    let policy = await store.currentPolicy()
    XCTAssertTrue(
      policy.allowsPreparation(
        capability: .createTodo,
        scopeID: AssistantActionCapability.createTodo.defaultScopeID
      )
    )
  }

  func testSettingsLabelsAndCopyDescribePreparationWithoutCommitAuthority() {
    XCTAssertEqual(AssistantActionCapability.createTodo.settingsTitle, "Create todos")
    XCTAssertEqual(AssistantActionCapability.createNote.settingsTitle, "Create notes")
    XCTAssertEqual(
      AssistantActionCapability.draftCalendarEvent.settingsTitle,
      "Draft calendar events"
    )
    XCTAssertEqual(
      AssistantActionCapability.requestCodexTask.settingsTitle,
      "Prepare Codex requests"
    )

    for capability in AssistantActionCapability.allCases {
      let explanation = capability.settingsExplanation.lowercased()
      XCTAssertTrue(explanation.contains("review card"))
      XCTAssertTrue(explanation.contains("explicit confirmation"))
    }
  }

  func testFreshlyEnabledCapabilityStillCannotCommitWithoutCurrentConfirmation() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let store = AssistantActionCapabilityStore(
      fileURL: directory.appendingPathComponent("capabilities.json")
    )
    let executor = CountingActionExecutor()
    let broker = AssistantActionBroker(
      capabilities: store,
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: executor,
      journal: AssistantActionJournal(),
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    let intent = try noteIntent()

    try await broker.stage(intent)
    var executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)

    let forged = AssistantActionConfirmation(
      id: UUID(),
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      userGestureID: UUID(),
      confirmedAt: intent.createdAt,
      expiresAt: intent.createdAt.addingTimeInterval(30)
    )
    await XCTAssertThrowsErrorAsync(try await broker.commit(forged)) { error in
      XCTAssertEqual(error as? AssistantActionBrokerError, .confirmationMissing)
    }
    executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }
}

final class AssistantActionBrokerTests: XCTestCase {
  func testPersistedPendingReviewStillRequiresFreshBrokerConfirmation() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("pending.json")
    let currentTime = Date(timeIntervalSince1970: 1_786_370_001)
    let intent = try noteIntent()
    let firstStore = AssistantActionPendingStore(fileURL: fileURL)
    try await firstStore.save(intent, now: currentTime)

    let restoredStore = AssistantActionPendingStore(fileURL: fileURL)
    let restoredIntent = try await restoredStore.mostRecentValidIntent(now: currentTime)
    let restored = try XCTUnwrap(restoredIntent)
    XCTAssertEqual(restored, intent)

    let executor = CountingActionExecutor()
    let broker = makeBroker(executor: executor)
    try await broker.stage(restored)
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testDecodedIntentCannotExtendItsProposalLifetime() async throws {
    let executor = CountingActionExecutor()
    let broker = makeBroker(executor: executor)
    let original = try noteIntent()
    let encoded = try JSONEncoder().encode(original)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["expiresAt"] = original.expiresAt
      .addingTimeInterval(24 * 60 * 60)
      .timeIntervalSinceReferenceDate
    let altered = try JSONDecoder().decode(
      AssistantActionIntent.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    await XCTAssertThrowsErrorAsync(try await broker.stage(altered)) { error in
      XCTAssertEqual(
        error as? AssistantActionProposalError,
        .invalidCanonicalIntent("expiry was modified")
      )
    }
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testUnconfirmedIntentNeverCallsExecutor() async throws {
    let executor = CountingActionExecutor()
    let broker = makeBroker(executor: executor)
    let intent = try noteIntent()
    try await broker.stage(intent)

    var executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)

    let forged = AssistantActionConfirmation(
      id: UUID(),
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      userGestureID: UUID(),
      confirmedAt: intent.createdAt,
      expiresAt: intent.createdAt.addingTimeInterval(30)
    )
    await XCTAssertThrowsErrorAsync(try await broker.commit(forged)) { error in
      XCTAssertEqual(error as? AssistantActionBrokerError, .confirmationMissing)
    }
    executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testSystemPermissionIsBrokerOwnedAndRequestedOnlyAfterConfirmation() async throws {
    let executor = CountingActionExecutor()
    let permissions = CountingPermissionAuthorizer()
    let broker = makeBroker(executor: executor, permissions: permissions)
    let intent = try calendarIntent()
    try await broker.stage(intent)
    var permissionCount = await permissions.authorizationCount
    XCTAssertEqual(permissionCount, 0)

    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())
    permissionCount = await permissions.authorizationCount
    XCTAssertEqual(permissionCount, 0)

    _ = try await broker.commit(confirmation)
    permissionCount = await permissions.authorizationCount
    XCTAssertEqual(permissionCount, 1)
  }

  func testDeniedSystemPermissionPreventsExecutorCall() async throws {
    let executor = CountingActionExecutor()
    let permissions = CountingPermissionAuthorizer(
      error: .denied("Calendar write-only access")
    )
    let broker = makeBroker(executor: executor, permissions: permissions)
    let intent = try calendarIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())

    await XCTAssertThrowsErrorAsync(try await broker.commit(confirmation)) { error in
      XCTAssertEqual(
        error as? AssistantActionPermissionError,
        .denied("Calendar write-only access")
      )
    }
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testConfirmationExpiryPreventsExecution() async throws {
    let executor = CountingActionExecutor()
    let broker = makeBroker(executor: executor, confirmationLifetime: -1)
    let intent = try noteIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())

    await XCTAssertThrowsErrorAsync(try await broker.commit(confirmation)) { error in
      XCTAssertEqual(error as? AssistantActionBrokerError, .confirmationExpired)
    }
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testConfirmationLifetimeCannotBeExtendedBeyondThirtySeconds() async throws {
    let executor = CountingActionExecutor()
    let broker = makeBroker(executor: executor, confirmationLifetime: 24 * 60 * 60)
    let intent = try noteIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())

    XCTAssertEqual(
      confirmation.expiresAt.timeIntervalSince(confirmation.confirmedAt),
      30,
      accuracy: 0.001
    )
  }

  func testConfirmationReplayIsIdempotentAndExecutesOnce() async throws {
    let executor = CountingActionExecutor()
    let broker = makeBroker(executor: executor)
    let intent = try noteIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())

    let first = try await broker.commit(confirmation)
    let replay = try await broker.commit(confirmation)

    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 1)
    XCTAssertEqual(first.id, replay.id)
    XCTAssertFalse(first.idempotentReplay)
    XCTAssertTrue(replay.idempotentReplay)
  }

  func testConcurrentCommitReservesIntentAndExecutorRunsExactlyOnce() async throws {
    let executor = CountingActionExecutor()
    let permissions = BlockingPermissionAuthorizer()
    let broker = makeBroker(executor: executor, permissions: permissions)
    let intent = try noteIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())

    let outcomes = await withTaskGroup(
      of: BrokerCommitOutcome.self,
      returning: [BrokerCommitOutcome].self
    ) { group in
      group.addTask {
        await captureCommitOutcome(broker: broker, confirmation: confirmation)
      }
      await permissions.waitUntilAuthorizationRequested()

      do {
        try await broker.cancel(intentID: intent.id)
        XCTFail("A cancel must not invalidate an active commit reservation.")
      } catch {
        XCTAssertEqual(error as? AssistantActionBrokerError, .executionInProgress)
      }
      do {
        try await broker.stage(intent)
        XCTFail("Restaging must not invalidate an active commit reservation.")
      } catch {
        XCTAssertEqual(error as? AssistantActionBrokerError, .executionInProgress)
      }

      group.addTask {
        await captureCommitOutcome(broker: broker, confirmation: confirmation)
      }

      // The first commit remains suspended in the permission authorizer. Therefore the first
      // completed child is deterministically the contender rejected by the broker reservation.
      let contender = await group.next()!
      await permissions.release()
      let winner = await group.next()!
      return [contender, winner]
    }

    XCTAssertEqual(outcomes.count, 2)
    XCTAssertTrue(
      outcomes.contains(.brokerError(.executionInProgress)),
      "A concurrent contender must not share or steal the winner's execution reservation."
    )
    let firstReceipt = try XCTUnwrap(
      outcomes.compactMap { outcome -> AssistantActionReceipt? in
        guard case let .receipt(receipt) = outcome else { return nil }
        return receipt
      }.first
    )
    XCTAssertFalse(firstReceipt.idempotentReplay)
    let executionCountAfterRace = await executor.executeCount
    XCTAssertEqual(executionCountAfterRace, 1)

    let replay = try await broker.commit(confirmation)
    XCTAssertEqual(replay.id, firstReceipt.id)
    XCTAssertTrue(replay.idempotentReplay)
    let executionCountAfterReplay = await executor.executeCount
    XCTAssertEqual(executionCountAfterReplay, 1)
  }

  func testConcurrentConfirmProducesAtMostOneUsableConfirmation() async throws {
    let executor = CountingActionExecutor()
    let capabilities = BlockingCapabilityProvider(policy: enabledPolicy())
    let broker = AssistantActionBroker(
      capabilities: capabilities,
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: executor,
      journal: AssistantActionJournal(),
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    let intent = try noteIntent()
    try await broker.stage(intent)
    await capabilities.blockNextRequest()

    let outcomes = await withTaskGroup(
      of: BrokerConfirmationOutcome.self,
      returning: [BrokerConfirmationOutcome].self
    ) { group in
      group.addTask {
        await captureConfirmationOutcome(broker: broker, intentID: intent.id)
      }
      await capabilities.waitUntilBlocked()

      group.addTask {
        await captureConfirmationOutcome(broker: broker, intentID: intent.id)
      }

      let contender = await group.next()!
      await capabilities.release()
      let winner = await group.next()!
      return [contender, winner]
    }

    XCTAssertTrue(outcomes.contains(.brokerError(.executionInProgress)))
    let confirmations = outcomes.compactMap { outcome -> AssistantActionConfirmation? in
      guard case let .confirmation(confirmation) = outcome else { return nil }
      return confirmation
    }
    XCTAssertEqual(confirmations.count, 1)

    _ = try await broker.commit(try XCTUnwrap(confirmations.first))
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 1)
  }

  func testBackgroundingDuringPermissionAwaitPreventsExecution() async throws {
    let environment = MutableCommitEnvironment(
      now: Date(timeIntervalSince1970: 1_786_370_001),
      isForeground: true
    )
    let executor = CountingActionExecutor()
    let permissions = BlockingPermissionAuthorizer()
    let broker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: permissions,
      executor: executor,
      journal: AssistantActionJournal(),
      now: { environment.currentTime() },
      isAppForeground: { environment.isAppForeground() }
    )
    let intent = try noteIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())

    let commit = Task { try await broker.commit(confirmation) }
    await permissions.waitUntilAuthorizationRequested()
    environment.setForeground(false)
    await permissions.release()

    do {
      _ = try await commit.value
      XCTFail("Backgrounding while system permission UI is open must invalidate confirmation.")
    } catch {
      XCTAssertEqual(error as? AssistantActionBrokerError, .appNotForeground)
    }
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testCapabilityRevocationDuringPermissionAwaitPreventsExecution() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let capabilityStore = AssistantActionCapabilityStore(
      fileURL: directory.appendingPathComponent("capabilities.json")
    )
    try await capabilityStore.replaceForTesting(with: enabledPolicy())
    let executor = CountingActionExecutor()
    let permissions = BlockingPermissionAuthorizer()
    let broker = AssistantActionBroker(
      capabilities: capabilityStore,
      permissions: permissions,
      executor: executor,
      journal: AssistantActionJournal(),
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    let intent = try noteIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())

    let commit = Task { try await broker.commit(confirmation) }
    await permissions.waitUntilAuthorizationRequested()
    try await capabilityStore.setPreparationEnabled(false, for: .createNote)
    await permissions.release()

    do {
      _ = try await commit.value
      XCTFail("Revoking a capability while permission UI is open must invalidate confirmation.")
    } catch {
      XCTAssertEqual(error as? AssistantActionBrokerError, .capabilityDisabled)
    }
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testCancellationDuringPermissionAwaitPersistsTombstoneAndNeverExecutes() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let journalURL = directory.appendingPathComponent("journal.json")
    let executor = CountingActionExecutor()
    let permissions = BlockingPermissionAuthorizer()
    let intent = try noteIntent()
    let broker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: permissions,
      executor: executor,
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())

    let commit = Task { try await broker.commit(confirmation) }
    await permissions.waitUntilAuthorizationRequested()
    commit.cancel()
    await permissions.release()

    do {
      _ = try await commit.value
      XCTFail("A cancelled commit must never reach the executor.")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)

    let restartedBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: CountingActionExecutor(),
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { Date(timeIntervalSince1970: 1_786_370_002) }
    )
    let restoration = try await restartedBroker.restorePendingReview(intent)
    XCTAssertEqual(restoration, .cancelled)
  }

  func testConfirmationExpiryDuringTargetRevalidationPreventsExecution() async throws {
    let environment = MutableCommitEnvironment(
      now: Date(timeIntervalSince1970: 1_786_370_001),
      isForeground: true
    )
    let executor = BlockingRevalidationExecutor()
    let broker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: executor,
      journal: AssistantActionJournal(),
      confirmationLifetime: 30,
      now: { environment.currentTime() },
      isAppForeground: { environment.isAppForeground() }
    )
    let intent = try noteIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())

    let commit = Task { try await broker.commit(confirmation) }
    await executor.waitUntilRevalidationStarted()
    environment.setTime(confirmation.expiresAt.addingTimeInterval(1))
    await executor.releaseRevalidation()

    do {
      _ = try await commit.value
      XCTFail("An expired confirmation must be rejected after target revalidation suspends.")
    } catch {
      XCTAssertEqual(error as? AssistantActionBrokerError, .confirmationExpired)
    }
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testDurableCancellationTombstonePreventsPendingReviewResurrection() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let journalURL = directory.appendingPathComponent("journal.json")
    let intent = try noteIntent()
    let firstBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: CountingActionExecutor(),
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    try await firstBroker.stage(intent)
    try await firstBroker.cancel(intentID: intent.id)

    let restartedExecutor = CountingActionExecutor()
    let restartedBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: restartedExecutor,
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { Date(timeIntervalSince1970: 1_786_370_002) }
    )

    let restoration = try await restartedBroker.restorePendingReview(intent)
    XCTAssertEqual(restoration, .cancelled)
    await XCTAssertThrowsErrorAsync(
      try await restartedBroker.confirm(intentID: intent.id, userGestureID: UUID())
    ) { error in
      XCTAssertEqual(error as? AssistantActionBrokerError, .intentNotStaged)
    }
    let executionCount = await restartedExecutor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testCancellationBeforeCommitWritesNothing() async throws {
    let executor = CountingActionExecutor()
    let broker = makeBroker(executor: executor)
    let intent = try noteIntent()
    try await broker.stage(intent)
    try await broker.cancel(intentID: intent.id)

    await XCTAssertThrowsErrorAsync(
      try await broker.confirm(intentID: intent.id, userGestureID: UUID())
    ) { error in
      XCTAssertEqual(error as? AssistantActionBrokerError, .intentCancelled)
    }
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testStaleRevisionStopsBeforeExecutorMutation() async throws {
    let executor = CountingActionExecutor(revalidationError: .staleTarget("revision changed"))
    let broker = makeBroker(executor: executor)
    let intent = try noteIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())

    await XCTAssertThrowsErrorAsync(try await broker.commit(confirmation)) { error in
      XCTAssertEqual(
        error as? AssistantActionBrokerError,
        .staleTarget("revision changed")
      )
    }
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testCapabilityRevocationInvalidatesPendingReview() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let capabilityStore = AssistantActionCapabilityStore(
      fileURL: directory.appendingPathComponent("capabilities.json")
    )
    try await capabilityStore.replaceForTesting(with: enabledPolicy())
    let executor = CountingActionExecutor()
    let broker = AssistantActionBroker(
      capabilities: capabilityStore,
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: executor,
      journal: AssistantActionJournal(),
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    let intent = try noteIntent()
    try await broker.stage(intent)
    try await capabilityStore.setPreparationEnabled(false, for: .createNote)

    await XCTAssertThrowsErrorAsync(
      try await broker.confirm(intentID: intent.id, userGestureID: UUID())
    ) { error in
      XCTAssertEqual(error as? AssistantActionBrokerError, .capabilityDisabled)
    }
    var executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 0)

    // The failed capability await must release its confirmation reservation so an explicit
    // retry can proceed after the user re-enables preparation.
    try await capabilityStore.setPreparationEnabled(true, for: .createNote)
    let retry = try await broker.confirm(intentID: intent.id, userGestureID: UUID())
    _ = try await broker.commit(retry)
    executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 1)
  }

  func testNativeHandoffCancellationProducesReceiptWithoutClaimingWrite() async throws {
    let executor = CountingActionExecutor(
      result: AssistantActionExecutionResult(
        disposition: .nativeHandoffRequired,
        summary: "Editor required."
      )
    )
    let broker = makeBroker(executor: executor)
    let intent = try calendarIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())
    let initial = try await broker.commit(confirmation)
    XCTAssertEqual(initial.disposition, .nativeHandoffRequired)

    let cancelled = try await broker.finalizeNativeHandoff(
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      outcome: .cancelled(summary: "Calendar editor was cancelled; no event was saved.")
    )
    XCTAssertEqual(cancelled.disposition, .handoffCancelled)
    XCTAssertNil(cancelled.entityIdentifier)
  }

  func testDuplicateNativeFinalizeReturnsSameTerminalReceiptAsReplay() async throws {
    let executor = CountingActionExecutor(
      result: AssistantActionExecutionResult(
        disposition: .nativeHandoffRequired,
        summary: "Editor required."
      )
    )
    let broker = makeBroker(executor: executor)
    let intent = try calendarIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())
    _ = try await broker.commit(confirmation)

    let first = try await broker.finalizeNativeHandoff(
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      outcome: .completed(
        entityIdentifier: "calendar-item-1",
        revision: "revision-1",
        summary: "Saved through Calendar."
      )
    )
    let duplicate = try await broker.finalizeNativeHandoff(
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      outcome: .cancelled(summary: "A stale duplicate callback must not replace completion.")
    )

    XCTAssertEqual(duplicate.id, first.id)
    XCTAssertEqual(duplicate.disposition, .handoffCompleted)
    XCTAssertFalse(first.idempotentReplay)
    XCTAssertTrue(duplicate.idempotentReplay)
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 1)
  }

  func testNativeFinalizePersistenceFailureLatchesFirstOutcomeAcrossConflictingRetry() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let writer = ControllableJournalWriter()
    let journal = AssistantActionJournal(
      fileURL: directory.appendingPathComponent("journal.json"),
      persistenceWriter: { data, url, options in
        try writer.write(data, to: url, options: options)
      }
    )
    let executor = CountingActionExecutor(
      result: AssistantActionExecutionResult(
        disposition: .nativeHandoffRequired,
        summary: "Editor required."
      )
    )
    let broker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: executor,
      journal: journal,
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    let intent = try calendarIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())
    let handoff = try await broker.commit(confirmation)
    XCTAssertEqual(handoff.disposition, .nativeHandoffRequired)

    writer.failNextWrite()
    await XCTAssertThrowsErrorAsync(
      try await broker.finalizeNativeHandoff(
        intentID: intent.id,
        proposalDigest: intent.proposalDigest,
        outcome: .completed(
          entityIdentifier: "event-1",
          revision: "revision-1",
          summary: "Calendar editor saved the event."
        )
      )
    ) { error in
      XCTAssertEqual(error as? ControllableJournalWriter.Failure, .injected)
    }
    let stillDurable = try await journal.receipt(forIntentID: intent.id)
    XCTAssertEqual(stillDurable?.id, handoff.id)
    XCTAssertEqual(stillDurable?.disposition, .nativeHandoffRequired)

    let retry = try await broker.finalizeNativeHandoff(
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      outcome: .cancelled(
        summary: "A later callback must not replace the already-reported saved outcome."
      )
    )
    XCTAssertEqual(retry.disposition, .handoffCompleted)
    XCTAssertEqual(retry.entityIdentifier, "event-1")
    XCTAssertEqual(retry.revision, "revision-1")
    XCTAssertEqual(retry.summary, "Calendar editor saved the event.")
    XCTAssertFalse(retry.idempotentReplay)
    let durableTerminal = try await journal.receipt(forIntentID: intent.id)
    XCTAssertEqual(durableTerminal, retry)
    let executionCount = await executor.executeCount
    XCTAssertEqual(executionCount, 1)
  }

  func testRestartAfterLocalWriteReceiptFailureReconcilesBeforeExpiryWithoutReexecution() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let journalURL = directory.appendingPathComponent("journal.json")
    let storeURL = directory.appendingPathComponent("store.json")
    let pendingURL = directory.appendingPathComponent("pending.json")
    let writer = ControllableJournalWriter()
    let firstStore = IAgentLocalSyncStore(fileURL: storeURL)
    let firstExecutor = ReceiptFailureAfterLocalWriteExecutor(
      base: LocalFirstAssistantActionExecutor(
        store: firstStore,
        sourceDeviceID: "crash-recovery-tests"
      ),
      failNextReceiptWith: writer
    )
    let firstJournal = AssistantActionJournal(
      fileURL: journalURL,
      persistenceWriter: { data, url, options in
        try writer.write(data, to: url, options: options)
      }
    )
    let firstBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: firstExecutor,
      journal: firstJournal,
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    let pendingStore = AssistantActionPendingStore(fileURL: pendingURL)
    let intent = try noteIntent(toolCallID: "receipt-crash-recovery")
    try await firstBroker.stage(intent)
    try await pendingStore.save(intent, now: Date(timeIntervalSince1970: 1_786_370_001))
    let confirmation = try await firstBroker.confirm(
      intentID: intent.id,
      userGestureID: UUID()
    )

    await XCTAssertThrowsErrorAsync(try await firstBroker.commit(confirmation)) { error in
      XCTAssertEqual(error as? ControllableJournalWriter.Failure, .injected)
    }
    let snapshotAfterWrite = await firstStore.snapshot()
    XCTAssertEqual(snapshotAfterWrite.notes.count, 1)
    let receiptBeforeRestart = try await firstJournal.receipt(forIntentID: intent.id)
    XCTAssertNil(receiptBeforeRestart)
    let firstExecuteCount = await firstExecutor.executeCount
    XCTAssertEqual(firstExecuteCount, 1)

    // Simulate process death: every broker, journal, store, and executor object is recreated.
    // Recovery runs after proposal expiry and after the capability was disabled, proving it is a
    // read-only receipt reconciliation rather than new preparation/execution authority.
    let restartedStore = IAgentLocalSyncStore(fileURL: storeURL)
    let restartedExecutor = ReceiptFailureAfterLocalWriteExecutor(
      base: LocalFirstAssistantActionExecutor(
        store: restartedStore,
        sourceDeviceID: "crash-recovery-tests"
      )
    )
    let restartedJournal = AssistantActionJournal(fileURL: journalURL)
    let restartedBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: .allDisabled),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: restartedExecutor,
      journal: restartedJournal,
      now: { intent.expiresAt.addingTimeInterval(60) }
    )
    let reopenedPending = AssistantActionPendingStore(fileURL: pendingURL)
    let pendingIntent = try await reopenedPending.mostRecentRestorableIntent()
    let restoredIntent = try XCTUnwrap(pendingIntent)
    let restoration = try await restartedBroker.restorePendingReview(restoredIntent)
    guard case .terminal(let recoveredReceipt) = restoration else {
      return XCTFail("The exact durable local record must recover as a terminal receipt.")
    }
    XCTAssertEqual(recoveredReceipt.disposition, .committedLocally)
    XCTAssertEqual(recoveredReceipt.intentID, intent.id)
    XCTAssertEqual(recoveredReceipt.proposalDigest, intent.proposalDigest)
    let durableRecoveredReceipt = try await restartedJournal.receipt(forIntentID: intent.id)
    XCTAssertEqual(durableRecoveredReceipt, recoveredReceipt)
    let restartedExecuteCount = await restartedExecutor.executeCount
    let reconciliationCount = await restartedExecutor.reconciliationCount
    XCTAssertEqual(restartedExecuteCount, 0)
    XCTAssertEqual(reconciliationCount, 1)
    let snapshotAfterRecovery = await restartedStore.snapshot()
    XCTAssertEqual(snapshotAfterRecovery.notes.count, 1)

    // This is the same terminal cleanup performed by the card model; the action can no longer be
    // presented or confirmed after recovery.
    try await reopenedPending.remove(intentID: intent.id)
    let pendingAfterCleanup = try await reopenedPending.mostRecentRestorableIntent()
    XCTAssertNil(pendingAfterCleanup)
  }

  func testNativeHandoffReceiptRestoresFailClosedWithoutReconfirmation() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let journalURL = directory.appendingPathComponent("journal.json")
    let intent = try calendarIntent()
    let firstExecutor = CountingActionExecutor(
      result: AssistantActionExecutionResult(
        disposition: .nativeHandoffRequired,
        summary: "Editor required."
      )
    )
    let firstBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: firstExecutor,
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    try await firstBroker.stage(intent)
    let firstConfirmation = try await firstBroker.confirm(
      intentID: intent.id,
      userGestureID: UUID()
    )
    let initial = try await firstBroker.commit(firstConfirmation)
    XCTAssertEqual(initial.disposition, .nativeHandoffRequired)

    let reopenedJournal = AssistantActionJournal(fileURL: journalURL)
    let durableInitial = try await reopenedJournal.receipt(forIntentID: intent.id)
    XCTAssertEqual(durableInitial?.id, initial.id)
    XCTAssertEqual(durableInitial?.disposition, .nativeHandoffRequired)

    let restartedExecutor = CountingActionExecutor(
      result: AssistantActionExecutionResult(
        disposition: .nativeHandoffRequired,
        summary: "Must not execute a persisted handoff again."
      )
    )
    let restartedBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: restartedExecutor,
      journal: reopenedJournal,
      now: { Date(timeIntervalSince1970: 1_786_370_002) }
    )
    let restoration = try await restartedBroker.restorePendingReview(intent)
    XCTAssertEqual(restoration, .nativeHandoff(initial))
    await XCTAssertThrowsErrorAsync(
      try await restartedBroker.confirm(intentID: intent.id, userGestureID: UUID())
    ) { error in
      XCTAssertEqual(error as? AssistantActionBrokerError, .executionInProgress)
    }
    let restartedExecutionCount = await restartedExecutor.executeCount
    XCTAssertEqual(restartedExecutionCount, 0)

    let cancelled = try await restartedBroker.finalizeNativeHandoff(
      intentID: intent.id,
      proposalDigest: intent.proposalDigest,
      outcome: .cancelled(summary: "Calendar editor was cancelled; no event was saved.")
    )
    XCTAssertEqual(cancelled.disposition, .handoffCancelled)

    let finalJournal = AssistantActionJournal(fileURL: journalURL)
    let durableFinal = try await finalJournal.receipt(forIntentID: intent.id)
    XCTAssertEqual(durableFinal?.id, cancelled.id)
    XCTAssertEqual(durableFinal?.disposition, .handoffCancelled)
  }

  func testDirectStageAfterRestartRehydratesNativeReceiptAndCannotReopenHandoff() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let journalURL = directory.appendingPathComponent("journal.json")
    let intent = try calendarIntent()
    let firstBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: CountingActionExecutor(
        result: AssistantActionExecutionResult(
          disposition: .nativeHandoffRequired,
          summary: "Editor required."
        )
      ),
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    try await firstBroker.stage(intent)
    let confirmation = try await firstBroker.confirm(intentID: intent.id, userGestureID: UUID())
    _ = try await firstBroker.commit(confirmation)

    let restartedExecutor = CountingActionExecutor()
    let restarted = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: restartedExecutor,
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { Date(timeIntervalSince1970: 1_786_370_002) }
    )
    await XCTAssertThrowsErrorAsync(try await restarted.stage(intent)) { error in
      XCTAssertEqual(error as? AssistantActionBrokerError, .executionInProgress)
    }
    await XCTAssertThrowsErrorAsync(
      try await restarted.confirm(intentID: intent.id, userGestureID: UUID())
    ) { error in
      XCTAssertEqual(error as? AssistantActionBrokerError, .executionInProgress)
    }
    let executionCount = await restartedExecutor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testExpiredNativeReceiptRestoresBeforeDisabledCapabilityPolicy() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let journalURL = directory.appendingPathComponent("journal.json")
    let intent = try calendarIntent()
    let firstBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: CountingActionExecutor(
        result: AssistantActionExecutionResult(
          disposition: .nativeHandoffRequired,
          summary: "Editor required."
        )
      ),
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    try await firstBroker.stage(intent)
    let confirmation = try await firstBroker.confirm(intentID: intent.id, userGestureID: UUID())
    let initial = try await firstBroker.commit(confirmation)

    let restartedExecutor = CountingActionExecutor()
    let restarted = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: .allDisabled),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: restartedExecutor,
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { intent.expiresAt.addingTimeInterval(3_600) }
    )
    let restored = try await restarted.restorePendingReview(intent)
    XCTAssertEqual(restored, .nativeHandoff(initial))
    await XCTAssertThrowsErrorAsync(
      try await restarted.confirm(intentID: intent.id, userGestureID: UUID())
    ) { error in
      XCTAssertEqual(error as? AssistantActionBrokerError, .executionInProgress)
    }
    let executionCount = await restartedExecutor.executeCount
    XCTAssertEqual(executionCount, 0)
  }

  func testExpiredTerminalReceiptRestoresForCleanupWithCapabilityDisabled() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let journalURL = directory.appendingPathComponent("journal.json")
    let intent = try noteIntent()
    let firstBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: CountingActionExecutor(),
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    try await firstBroker.stage(intent)
    let confirmation = try await firstBroker.confirm(intentID: intent.id, userGestureID: UUID())
    let terminal = try await firstBroker.commit(confirmation)

    let restarted = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: .allDisabled),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: CountingActionExecutor(),
      journal: AssistantActionJournal(fileURL: journalURL),
      now: { intent.expiresAt.addingTimeInterval(3_600) }
    )
    let restored = try await restarted.restorePendingReview(intent)
    XCTAssertEqual(restored, .terminal(terminal))
  }

  func testPendingStorePreservesAndFailsClosedOnCorruptExistingFile() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("pending.json")
    let corrupt = Data("not a pending action store".utf8)
    try corrupt.write(to: url)
    let store = AssistantActionPendingStore(fileURL: url)

    do {
      _ = try await store.mostRecentRestorableIntent()
      XCTFail("A corrupt pending store must not masquerade as empty.")
    } catch let error as AssistantActionPendingStoreError {
      XCTAssertEqual(error, .unreadable)
    }
    do {
      try await store.save(try noteIntent(), now: Date(timeIntervalSince1970: 1_786_370_001))
      XCTFail("A corrupt pending store must not be overwritten by a new proposal.")
    } catch let error as AssistantActionPendingStoreError {
      XCTAssertEqual(error, .unreadable)
    }
    XCTAssertEqual(try Data(contentsOf: url), corrupt)
  }

  func testPendingStoreKeepsExpiredCanonicalPayloadForReceiptFirstRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let url = directory.appendingPathComponent("pending.json")
    let intent = try calendarIntent()
    let store = AssistantActionPendingStore(fileURL: url)
    try await store.save(intent, now: intent.createdAt)

    let reopened = AssistantActionPendingStore(fileURL: url)
    let restored = try await reopened.mostRecentRestorableIntent()
    XCTAssertEqual(restored, intent)
  }

  func testConfirmedTodoAndNoteCreateLocalRecordsOnlyOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = IAgentLocalSyncStore(fileURL: directory.appendingPathComponent("store.json"))
    let executor = LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "tests")
    let broker = makeBroker(executor: executor)
    let todo = try todoIntent()
    let note = try noteIntent(toolCallID: "note-2")

    try await broker.stage(todo)
    try await broker.stage(note)
    let beforeConfirmation = await store.snapshot()
    XCTAssertTrue(beforeConfirmation.todos.isEmpty)
    XCTAssertTrue(beforeConfirmation.notes.isEmpty)

    let todoConfirmation = try await broker.confirm(intentID: todo.id, userGestureID: UUID())
    let noteConfirmation = try await broker.confirm(intentID: note.id, userGestureID: UUID())
    _ = try await broker.commit(todoConfirmation)
    _ = try await broker.commit(noteConfirmation)
    _ = try await broker.commit(todoConfirmation)

    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.todos.map(\.title), ["Call Sam"])
    XCTAssertEqual(snapshot.notes.map(\.title), ["Trip plan"])
  }

  func testTodoListChangingAfterRevalidationFailsClosedWithoutCreatingTodo() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { removeTemporaryDirectoryIfPresent(directory) }
    let store = IAgentLocalSyncStore(fileURL: directory.appendingPathComponent("store.json"))
    var reviewedList = SyncedTodoList(name: "Work", order: 0)
    try await store.upsertLocal(.todoList(reviewedList))
    let executor = LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "tests")
    let intent = try makeIntent(
      tool: AssistantProposalToolCatalog.createTodoName,
      json: #"{"title":"Review launch","due_at":null,"time_zone_id":null,"list_name":"Work"}"#,
      context: proposalContext(knownTodoListNames: ["Work"])
    )

    try await executor.revalidate(intent)
    reviewedList.name = "Archive"
    reviewedList.updatedAt = reviewedList.updatedAt.addingTimeInterval(1)
    try await store.upsertLocal(.todoList(reviewedList))

    let authorization = testExecutionAuthorization(for: intent)
    await XCTAssertThrowsErrorAsync(
      try await executor.execute(intent, authorization: authorization)
    ) { error in
      guard case AssistantActionBrokerError.staleTarget = error else {
        return XCTFail("Expected a stale reviewed list, got \(error)")
      }
    }
    let snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.todos.isEmpty)
  }

  func testCodexRequestIsHandoffOnlyAndNeverCreatesMobileTask() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = IAgentLocalSyncStore(fileURL: directory.appendingPathComponent("store.json"))
    let executor = LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "tests")
    let broker = makeBroker(executor: executor)
    let intent = try codexIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())
    let receipt = try await broker.commit(confirmation)

    XCTAssertEqual(receipt.disposition, .nativeHandoffRequired)
    let snapshot = await store.snapshot()
    XCTAssertTrue(snapshot.codexThreads.isEmpty)
    XCTAssertTrue(receipt.summary.contains("No task has been created"))
  }

  func testJournalStoresAuditMetadataWithoutUserPayloadContent() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let journalURL = directory.appendingPathComponent("journal.json")
    let journal = AssistantActionJournal(fileURL: journalURL)
    let executor = CountingActionExecutor()
    let broker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: executor,
      journal: journal,
      now: { Date(timeIntervalSince1970: 1_786_370_001) }
    )
    let intent = try noteIntent()
    try await broker.stage(intent)
    let confirmation = try await broker.confirm(intentID: intent.id, userGestureID: UUID())
    _ = try await broker.commit(confirmation)

    let events = try await journal.allEntries().map(\.event)
    XCTAssertEqual(events, [.proposed, .confirmed, .executionStarted, .committed])
    let storedText = try String(contentsOf: journalURL, encoding: .utf8)
    XCTAssertFalse(storedText.contains("Trip plan"))
    XCTAssertFalse(storedText.contains("Book the ferry"))
  }
}

private actor CountingActionExecutor: AssistantActionExecuting {
  private(set) var executeCount = 0
  private let revalidationError: AssistantActionBrokerError?
  private let result: AssistantActionExecutionResult

  init(
    revalidationError: AssistantActionBrokerError? = nil,
    result: AssistantActionExecutionResult = AssistantActionExecutionResult(
      disposition: .committedLocally,
      entityIdentifier: "entity-1",
      revision: "revision-1",
      summary: "Committed."
    )
  ) {
    self.revalidationError = revalidationError
    self.result = result
  }

  func revalidate(_ intent: AssistantActionIntent) async throws {
    if let revalidationError { throw revalidationError }
  }

  func execute(
    _ intent: AssistantActionIntent,
    authorization: AssistantActionExecutionAuthorization
  ) async throws -> AssistantActionExecutionResult {
    try authorization.performAuthorizedMutation(for: executionIdentity(for: intent)) {}
    executeCount += 1
    return result
  }
}

private actor ReceiptFailureAfterLocalWriteExecutor: AssistantActionExecuting {
  private let base: LocalFirstAssistantActionExecutor
  private let writer: ControllableJournalWriter?
  private(set) var executeCount = 0
  private(set) var reconciliationCount = 0

  init(
    base: LocalFirstAssistantActionExecutor,
    failNextReceiptWith writer: ControllableJournalWriter? = nil
  ) {
    self.base = base
    self.writer = writer
  }

  func revalidate(_ intent: AssistantActionIntent) async throws {
    try await base.revalidate(intent)
  }

  func execute(
    _ intent: AssistantActionIntent,
    authorization: AssistantActionExecutionAuthorization
  ) async throws -> AssistantActionExecutionResult {
    let result = try await base.execute(intent, authorization: authorization)
    executeCount += 1
    // The local store is durable at this point. Fail exactly the broker's following receipt write
    // to reproduce the process-death window without failing executionStarted beforehand.
    writer?.failNextWrite()
    return result
  }

  func reconcileCommittedResult(
    _ intent: AssistantActionIntent
  ) async throws -> AssistantActionExecutionResult? {
    reconciliationCount += 1
    return try await base.reconcileCommittedResult(intent)
  }
}

private actor CountingPermissionAuthorizer: AssistantActionPermissionAuthorizing {
  private(set) var authorizationCount = 0
  private let error: AssistantActionPermissionError?

  init(error: AssistantActionPermissionError? = nil) {
    self.error = error
  }

  func authorizeIfNeeded(for intent: AssistantActionIntent) async throws {
    authorizationCount += 1
    if let error { throw error }
  }
}

private enum BrokerCommitOutcome: Equatable, Sendable {
  case receipt(AssistantActionReceipt)
  case brokerError(AssistantActionBrokerError)
  case otherError(String)
}

private func captureCommitOutcome(
  broker: AssistantActionBroker,
  confirmation: AssistantActionConfirmation
) async -> BrokerCommitOutcome {
  do {
    return .receipt(try await broker.commit(confirmation))
  } catch let error as AssistantActionBrokerError {
    return .brokerError(error)
  } catch {
    return .otherError(String(describing: error))
  }
}

private enum BrokerConfirmationOutcome: Equatable, Sendable {
  case confirmation(AssistantActionConfirmation)
  case brokerError(AssistantActionBrokerError)
  case otherError(String)
}

private func captureConfirmationOutcome(
  broker: AssistantActionBroker,
  intentID: String
) async -> BrokerConfirmationOutcome {
  do {
    return .confirmation(
      try await broker.confirm(intentID: intentID, userGestureID: UUID())
    )
  } catch let error as AssistantActionBrokerError {
    return .brokerError(error)
  } catch {
    return .otherError(String(describing: error))
  }
}

private actor BlockingPermissionAuthorizer: AssistantActionPermissionAuthorizing {
  private var authorizationRequested = false
  private var requestWaiter: CheckedContinuation<Void, Never>?
  private var isReleased = false
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  func authorizeIfNeeded(for intent: AssistantActionIntent) async throws {
    authorizationRequested = true
    requestWaiter?.resume()
    requestWaiter = nil
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      releaseWaiter = continuation
    }
  }

  func waitUntilAuthorizationRequested() async {
    guard !authorizationRequested else { return }
    await withCheckedContinuation { continuation in
      requestWaiter = continuation
    }
  }

  func release() {
    isReleased = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

private actor BlockingCapabilityProvider: AssistantActionCapabilityProviding {
  nonisolated let policy: AssistantActionCapabilityPolicy
  private var shouldBlockNextRequest = false
  private var requestIsBlocked = false
  private var blockedWaiter: CheckedContinuation<Void, Never>?
  private var isReleased = false
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  init(policy: AssistantActionCapabilityPolicy) {
    self.policy = policy
  }

  func currentPolicy() async -> AssistantActionCapabilityPolicy {
    guard shouldBlockNextRequest else { return policy }
    shouldBlockNextRequest = false
    requestIsBlocked = true
    blockedWaiter?.resume()
    blockedWaiter = nil
    if !isReleased {
      await withCheckedContinuation { continuation in
        releaseWaiter = continuation
      }
    }
    return policy
  }

  nonisolated func preparationAuthorizationGeneration() -> UInt64 {
    0
  }

  nonisolated func withPreparationAuthorization(
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

  func blockNextRequest() {
    shouldBlockNextRequest = true
    requestIsBlocked = false
    isReleased = false
  }

  func waitUntilBlocked() async {
    guard !requestIsBlocked else { return }
    await withCheckedContinuation { continuation in
      blockedWaiter = continuation
    }
  }

  func release() {
    isReleased = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

private actor BlockingRevalidationExecutor: AssistantActionExecuting {
  private(set) var executeCount = 0
  private var revalidationStarted = false
  private var startedWaiter: CheckedContinuation<Void, Never>?
  private var isReleased = false
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  func revalidate(_ intent: AssistantActionIntent) async throws {
    revalidationStarted = true
    startedWaiter?.resume()
    startedWaiter = nil
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      releaseWaiter = continuation
    }
  }

  func execute(
    _ intent: AssistantActionIntent,
    authorization: AssistantActionExecutionAuthorization
  ) async throws -> AssistantActionExecutionResult {
    try authorization.performAuthorizedMutation(for: executionIdentity(for: intent)) {}
    executeCount += 1
    return AssistantActionExecutionResult(
      disposition: .committedLocally,
      entityIdentifier: "must-not-execute",
      revision: "revision-1",
      summary: "Committed."
    )
  }

  func waitUntilRevalidationStarted() async {
    guard !revalidationStarted else { return }
    await withCheckedContinuation { continuation in
      startedWaiter = continuation
    }
  }

  func releaseRevalidation() {
    isReleased = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
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

private func testExecutionAuthorization(
  for intent: AssistantActionIntent,
  now: @escaping @Sendable () -> Date = {
    Date(timeIntervalSince1970: 1_786_370_001)
  }
) -> AssistantActionExecutionAuthorization {
  let foregroundAuthority = AssistantActionForegroundAuthority(
    currentGeneration: { 0 },
    withActiveAuthorization: { expectedGeneration, operation in
      guard expectedGeneration == 0 else {
        throw AssistantActionBrokerError.appNotForeground
      }
      try operation()
    }
  )
  return AssistantActionExecutionAuthorization(
    binding: .init(
      identity: executionIdentity(for: intent),
      proposalExpiresAt: intent.expiresAt,
      confirmationExpiresAt: intent.expiresAt
    ),
    now: now,
    foregroundAuthority: foregroundAuthority,
    foregroundGeneration: 0,
    capabilityGeneration: 0,
    withCapabilityAuthorization: { expectedGeneration, operation in
      guard expectedGeneration == 0 else {
        throw AssistantActionBrokerError.capabilityDisabled
      }
      try operation()
    }
  )
}

private final class MutableCommitEnvironment: @unchecked Sendable {
  private let lock = NSLock()
  private var now: Date
  private var foreground: Bool

  init(now: Date, isForeground: Bool) {
    self.now = now
    foreground = isForeground
  }

  func currentTime() -> Date {
    lock.withLock { now }
  }

  func isAppForeground() -> Bool {
    lock.withLock { foreground }
  }

  func setTime(_ time: Date) {
    lock.withLock { now = time }
  }

  func setForeground(_ isForeground: Bool) {
    lock.withLock { foreground = isForeground }
  }
}

private final class ControllableJournalWriter: @unchecked Sendable {
  enum Failure: Error, Equatable {
    case injected
  }

  private let lock = NSLock()
  private var shouldFailNextWrite = false

  func failNextWrite() {
    lock.withLock { shouldFailNextWrite = true }
  }

  func write(
    _ data: Data,
    to url: URL,
    options: Data.WritingOptions
  ) throws {
    let shouldFail = lock.withLock {
      defer { shouldFailNextWrite = false }
      return shouldFailNextWrite
    }
    if shouldFail { throw Failure.injected }
    try data.write(to: url, options: options)
  }
}

private func enabledPolicy() -> AssistantActionCapabilityPolicy {
  var policy = AssistantActionCapabilityPolicy.allDisabled
  for capability in AssistantActionCapability.allCases {
    policy.setPreparationEnabled(true, for: capability)
  }
  return policy
}

private func removeTemporaryDirectoryIfPresent(_ directory: URL) {
  guard FileManager.default.fileExists(atPath: directory.path) else { return }
  try? FileManager.default.removeItem(at: directory)
}

private func proposalContext(
  policy: AssistantActionCapabilityPolicy = enabledPolicy(),
  authorizationOrigin: AssistantActionAuthorizationOrigin = .currentUserMessage,
  userExplicitlyRequestedAction: Bool = true,
  storedContentClaimsAuthorization: Bool = false,
  knownTodoListNames: [String] = [],
  knownCalendarIdentifiers: Set<String> = [],
  knownCodexWorkspaceIdentifiers: Set<String> = []
) -> AssistantActionProposalContext {
  AssistantActionProposalContext(
    provenance: AssistantActionProvenance(
      conversationID: "conversation-1",
      turnID: "turn-1",
      currentUserMessageID: "message-1",
      toolCallID: "tool-call-1"
    ),
    capabilityPolicy: policy,
    authorizationOrigin: authorizationOrigin,
    userExplicitlyRequestedAction: userExplicitlyRequestedAction,
    storedContentClaimsAuthorization: storedContentClaimsAuthorization,
    knownTodoListNames: knownTodoListNames,
    knownCalendarIdentifiers: knownCalendarIdentifiers,
    knownCodexWorkspaceIdentifiers: knownCodexWorkspaceIdentifiers
  )
}

private func makeIntent(
  tool: String,
  json: String,
  context: AssistantActionProposalContext = proposalContext()
) throws -> AssistantActionIntent {
  try AssistantActionProposalValidator.makeIntent(
    toolName: tool,
    argumentsJSON: Data(json.utf8),
    context: context,
    now: Date(timeIntervalSince1970: 1_786_370_000)
  )
}

private func noteIntent(toolCallID: String = "note-1") throws -> AssistantActionIntent {
  var context = proposalContext()
  context = AssistantActionProposalContext(
    provenance: AssistantActionProvenance(
      conversationID: context.provenance.conversationID,
      turnID: context.provenance.turnID,
      currentUserMessageID: context.provenance.currentUserMessageID,
      toolCallID: toolCallID
    ),
    capabilityPolicy: context.capabilityPolicy,
    authorizationOrigin: .currentUserMessage,
    userExplicitlyRequestedAction: true
  )
  return try makeIntent(
    tool: AssistantProposalToolCatalog.createNoteName,
    json: #"{"title":"Trip plan","body":"Book the ferry."}"#,
    context: context
  )
}

private func todoIntent() throws -> AssistantActionIntent {
  try makeIntent(
    tool: AssistantProposalToolCatalog.createTodoName,
    json: #"{"title":"Call Sam","due_at":null,"time_zone_id":null,"list_name":null}"#
  )
}

private func calendarIntent() throws -> AssistantActionIntent {
  try makeIntent(
    tool: AssistantProposalToolCatalog.draftCalendarEventName,
    json: #"{"title":"Review","start_at":"2026-08-11T09:00:00+03:00","end_at":"2026-08-11T10:00:00+03:00","time_zone_id":"Europe/Athens","is_all_day":false,"calendar_id":null,"location":null,"notes":null}"#
  )
}

private func codexIntent() throws -> AssistantActionIntent {
  try makeIntent(
    tool: AssistantProposalToolCatalog.requestCodexTaskName,
    json: #"{"prompt":"Inspect the failing tests and propose a fix.","workspace_id":null}"#
  )
}

private func makeBroker(
  executor: any AssistantActionExecuting,
  permissions: any AssistantActionPermissionAuthorizing = FixedAssistantActionPermissionAuthorizer(),
  confirmationLifetime: TimeInterval = 30
) -> AssistantActionBroker {
  AssistantActionBroker(
    capabilities: FixedAssistantActionCapabilityProvider(policy: enabledPolicy()),
    permissions: permissions,
    executor: executor,
    journal: AssistantActionJournal(),
    confirmationLifetime: confirmationLifetime,
    now: { Date(timeIntervalSince1970: 1_786_370_001) }
  )
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ verify: (Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {
    verify(error)
  }
}

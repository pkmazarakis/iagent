import CryptoKit
import Foundation
import iAgentActionContracts
import iAgentCore

#if canImport(FoundationModels)
  import FoundationModels
#endif

enum AskIAgentRetrievalHarnessMode: String, Sendable {
  case legacy
  case shadow
  case v2

  static var configured: AskIAgentRetrievalHarnessMode {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if let index = arguments.firstIndex(of: "--ask-iagent-retrieval-mode"),
        arguments.indices.contains(index + 1),
        let mode = AskIAgentRetrievalHarnessMode(rawValue: arguments[index + 1])
      {
        return mode
      }
      if let raw = ProcessInfo.processInfo.environment["IAGENT_ASK_RETRIEVAL_HARNESS"],
        let mode = AskIAgentRetrievalHarnessMode(rawValue: raw)
      {
        return mode
      }
      return .v2
    #else
      // V2 is the product architecture for every model tier. Legacy and shadow remain explicit
      // DEBUG-only rollback/measurement switches; Release must never silently route a turn through
      // the eager V1 evidence path merely because inference happens remotely.
      return .v2
    #endif
  }
}

/// Retrieval and action contracts stay identical across tiers, but the on-device inference driver
/// has a smaller context window. This profile only bounds tool results; it never chooses a source
/// or action on the model's behalf.
enum AskIAgentV2InferenceProfile: Sendable {
  case onDevice
  case remote

  var queryBudget: AskQueryBudget {
    switch self {
    case .onDevice:
      AskQueryBudget(
        maximumCalls: 5,
        maximumCallsPerDomain: 1,
        maximumPagesPerDomain: 1,
        maximumRecordsPerPage: 4,
        maximumTotalRecords: 12,
        maximumEvidencePassages: 8,
        maximumEvidenceCharacters: 4_200
      )
    case .remote:
      AskQueryBudget(
        maximumCalls: 8,
        maximumCallsPerDomain: 2,
        maximumPagesPerDomain: 2,
        // The canonical relay schema advertises limits through 10. Keep the native executor in
        // lockstep so a schema-valid Fast/Pro call is not rejected after it reaches the app.
        maximumRecordsPerPage: 10,
        maximumTotalRecords: 28,
        maximumEvidencePassages: 16,
        maximumEvidenceCharacters: 14_000
      )
    }
  }

  var evidenceContentCharacterLimit: Int {
    switch self {
    case .onDevice: 620
    case .remote: 1_200
    }
  }

  var toolEvidenceCharacterLimit: Int {
    switch self {
    case .onDevice: 520
    case .remote: 800
    }
  }
}

struct AskIAgentV2ToolResult: Equatable, Sendable {
  let callID: String
  let name: String
  let argumentsJSON: Data
  let payloadDigest: String
  let output: String
  let evidenceIDs: [String]
}

struct AskIAgentV2RemoteState: Sendable {
  let catalog: AskDataCatalog
  let readToolSchemaVersion: Int
  let readToolSchemaDigest: String
  let readToolSchemas: [AskStrictReadToolSchema]
  let actionToolSchemaVersion: Int
  let actionToolSchemaDigest: String
  let enabledTools: [String]
  let actionToolDefinitions: [AssistantProposalToolDefinition]
  let evidence: [AskIAgentEvidence]
  let toolHistory: [AskIAgentV2ToolResult]
  let budgetLimit: AskQueryBudget
  let budgetUsage: AskQueryBudgetUsage
}

enum AskIAgentV2ToolBridgeFailure: Error, Equatable, Sendable {
  case invalidCallID
  case unknownOrDisabledTool(String)
  case malformedArguments(String)
  case callIDPayloadMismatch(String)

  fileprivate var bridgeReceiptCode: String {
    switch self {
    case .invalidCallID: "invalidCallID"
    case .unknownOrDisabledTool: "unsupportedTool"
    case .malformedArguments: "malformedArguments"
    case .callIDPayloadMismatch: "callIDPayloadMismatch"
    }
  }
}

actor AskIAgentV2TurnContext {
  private static let maximumToolCallAttempts = 8

  nonisolated let catalog: AskDataCatalog
  nonisolated let catalogManifest: String
  nonisolated let actionToolDefinitions: [AssistantProposalToolDefinition]
  nonisolated let enabledToolNames: [String]

  private let executor: AskPinnedQueryExecutor
  private let inferenceProfile: AskIAgentV2InferenceProfile
  private let actionPolicy: AssistantActionCapabilityPolicy
  private let provenance: AssistantActionProvenance
  private let knownTodoListNames: [String]
  private let knownCalendarIdentifiers: Set<String>
  private let knownCodexWorkspaceIdentifiers: Set<String>
  private var evidence: [AskIAgentEvidence] = []
  private var evidenceIndexByStableKey: [String: Int] = [:]
  private var proposedIntent: AssistantActionIntent?
  private var proposalCallCount = 0
  private var repairableReadFailureCount = 0
  private var lastProposalFailure: ProposalFailure?
  private var queryMatchCounts: [AskSourceKind: Int] = [:]
  private var budgetUsage = AskQueryBudgetUsage()
  private var callIdentities: [String: ToolCallIdentity] = [:]
  private var completedToolCalls: [String: AskIAgentV2ToolResult] = [:]
  private var toolCallOrder: [String] = []
  private var inFlightToolCalls: [String: Task<AskIAgentV2ToolResult, Error>] = [:]
  private var toolCallAttemptCount = 0
  private var budgetExhaustionCallID: String?
  private var nativeToolCallSequence = 0

  private struct ToolCallIdentity: Equatable, Sendable {
    let name: String
    let payloadDigest: String
  }

  private enum PreparedExternalToolCall: Sendable {
    case read(AskDecodedReadToolCall)
    case rejectedRead(
      name: String,
      argumentsJSON: Data,
      payloadDigest: String,
      failure: AskReadToolCallFailure
    )
    case proposal(name: String, argumentsJSON: Data, payloadDigest: String)

    var name: String {
      switch self {
      case .read(let value): value.name
      case .rejectedRead(let name, _, _, _): name
      case .proposal(let name, _, _): name
      }
    }

    var argumentsJSON: Data {
      switch self {
      case .read(let value): value.canonicalArgumentsJSON
      case .rejectedRead(_, let argumentsJSON, _, _): argumentsJSON
      case .proposal(_, let argumentsJSON, _): argumentsJSON
      }
    }

    var payloadDigest: String {
      switch self {
      case .read(let value): value.payloadDigest
      case .rejectedRead(_, _, let payloadDigest, _): payloadDigest
      case .proposal(_, _, let payloadDigest): payloadDigest
      }
    }
  }

  private struct ReadExecution: Sendable {
    let output: String
    let evidenceIDs: [String]
  }

  /// Native proposal failures remain structured so the app can explain a disabled capability or
  /// repairable argument error truthfully without parsing model prose. None of these states grants
  /// commit authority or creates a review intent.
  private enum ProposalFailure: Sendable {
    case capabilityDisabled(AssistantActionCapability)
    case invalidArguments(String)
    case retryBudgetExhausted

    var userDescription: String {
      switch self {
      case .capabilityDisabled(let capability):
        "\(capability.settingsTitle) is disabled in Settings."
      case .invalidArguments:
        "The proposed review card was missing or contained invalid details."
      case .retryBudgetExhausted:
        "The model could not produce a valid review card within the retry limit."
      }
    }
  }

  init(
    snapshot: IAgentDataSnapshot,
    phoneEvents: [SyncedCalendarEvent],
    calendarCoverage: AskCatalogCoverage? = nil,
    snapshotID: String,
    contextAsOf: Date,
    localeIdentifier: String,
    firstWeekday: Int,
    inferenceProfile: AskIAgentV2InferenceProfile = .remote,
    actionPolicy: AssistantActionCapabilityPolicy,
    provenance: AssistantActionProvenance
  ) throws {
    var combined = snapshot
    combined.calendarEvents.append(contentsOf: phoneEvents)
    let temporalContext = AskTemporalContext(
      contextAsOf: contextAsOf,
      timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
      localeIdentifier: localeIdentifier,
      calendarIdentifier: "gregorian",
      firstWeekday: firstWeekday
    )
    let executor = try AskPinnedQueryExecutor(
      snapshot: AskDataSnapshot(
        data: combined,
        contextAsOf: contextAsOf,
        coverageOverrides: calendarCoverage.map { [.calendar: $0] } ?? [:]
      ),
      snapshotID: snapshotID,
      temporalContext: temporalContext,
      budget: inferenceProfile.queryBudget
    )
    self.executor = executor
    self.inferenceProfile = inferenceProfile
    catalog = executor.catalog
    catalogManifest = Self.compactCatalogManifest(executor.catalog)
    self.actionPolicy = actionPolicy
    // The selected model, not a native keyword/prefix classifier, chooses whether an action tool
    // fits the current request. Native policy still controls which proposal tools are available,
    // and a model call can only stage an inert review intent.
    let enabledActionDefinitions = AssistantProposalToolCatalog.definitions(allowedBy: actionPolicy)
    actionToolDefinitions = enabledActionDefinitions
    enabledToolNames = AskReadToolSchemas.allowedNames + enabledActionDefinitions.map(\.name)
    self.provenance = provenance
    knownTodoListNames = combined.todoLists
      .filter { $0.deletedAt == nil }
      .map(\.name)
    knownCalendarIdentifiers = Set(
      combined.calendarEvents.compactMap { event in
        guard event.deletedAt == nil else { return nil }
        return event.sourceIdentifier
      }
    )
    // Project labels are not stable workspace identifiers, so they are intentionally not promoted
    // to writable Codex targets by the read replica.
    knownCodexWorkspaceIdentifiers = []
  }

  func execute(
    _ query: AskReadQuery,
    progress: @escaping @Sendable (AskIAgentWorkStage) -> Void
  ) async throws -> String {
    try await executeRead(query, progress: progress).output
  }

  private func executeRead(
    _ query: AskReadQuery,
    progress: @escaping @Sendable (AskIAgentWorkStage) -> Void
  ) async throws -> ReadExecution {
    try Task.checkCancellation()
    let page = try await executor.execute(query)
    try Task.checkCancellation()
    budgetUsage = page.budgetUsage
    queryMatchCounts[query.domain] = max(
      queryMatchCounts[query.domain, default: 0],
      page.totalMatched ?? page.returnedCount
    )
    let candidates = page.items.flatMap(Self.makeEvidence)
    let accepted = ingest(candidates)
    let sources = accepted.askV2UniquedBySource()
    progress(
      .searchedSource(
        AskIAgentSourceScan(
          kind: AskIAgentSourceKind(query.domain),
          totalCount: page.totalMatched ?? page.returnedCount,
          titles: page.items.map(\.title)
        )))
    if !accepted.isEmpty { progress(.readingSources(evidence.count)) }
    try Task.checkCancellation()

    let warningText =
      page.warnings.isEmpty
      ? "none"
      : page.warnings.map(\.rawValue).joined(separator: ",")
    let pagination = page.nextCursor.map { " next_cursor=\(Self.jsonString($0))" } ?? ""
    guard !accepted.isEmpty else {
      return ReadExecution(
        output:
          "query_id=\(page.queryID) matched=\(page.totalMatched ?? 0) returned=0 warnings=\(warningText)\(pagination)",
        evidenceIDs: []
      )
    }
    return ReadExecution(
      output: """
        query_id=\(page.queryID) matched=\(page.totalMatched ?? accepted.count) returned=\(sources.count) warnings=\(warningText)\(pagination)
        \(accepted.map(toolEvidenceBlock).joined(separator: "\n\n"))
        """,
      evidenceIDs: accepted.map(\.id)
    )
  }

  func propose(toolName: String, argumentsJSON: Data, now: Date = Date()) throws -> String {
    guard proposedIntent == nil else {
      return "Proposal not prepared: this turn already has one pending review card."
    }
    return try prepareModelProposal(
      toolName: toolName,
      argumentsJSON: argumentsJSON,
      toolCallID: "\(provenance.turnID)-proposal-\(proposalCallCount + 1)",
      now: now
    )
  }

  /// Proposal argument mistakes are model-repairable tool results, not fatal app errors. The model
  /// gets one bounded receipt explaining what must change and may issue a corrected call in the
  /// next step. Unknown/disabled tools and bridge-integrity failures still fail closed earlier.
  private func prepareModelProposal(
    toolName: String,
    argumentsJSON: Data,
    toolCallID: String,
    now: Date
  ) throws -> String {
    guard proposalCallCount < 3 else {
      lastProposalFailure = .retryBudgetExhausted
      return "Proposal not prepared: the proposal retry budget is exhausted. Nothing changed."
    }
    proposalCallCount += 1
    do {
      let output = try prepareProposal(
        toolName: toolName,
        argumentsJSON: argumentsJSON,
        toolCallID: toolCallID,
        now: now
      )
      lastProposalFailure = nil
      return output
    } catch let error as AssistantActionProposalError {
      let detail = (error.errorDescription ?? "The proposal arguments were invalid.")
        .askV2Bounded(500)
      if proposalCallCount >= 3 {
        lastProposalFailure = .retryBudgetExhausted
        return "Proposal not prepared: the proposal retry budget is exhausted. Do not call another proposal tool. Nothing changed."
      }
      lastProposalFailure = .invalidArguments(detail)
      return "Proposal not prepared: \(detail) Revise the arguments and call the appropriate proposal tool again."
    }
  }

  private func prepareProposal(
    toolName: String,
    argumentsJSON: Data,
    toolCallID: String,
    now: Date
  ) throws -> String {
    guard proposedIntent == nil else {
      return "Proposal not prepared: this turn already has one pending review card."
    }
    let context = AssistantActionProposalContext(
      provenance: AssistantActionProvenance(
        conversationID: provenance.conversationID,
        turnID: provenance.turnID,
        currentUserMessageID: provenance.currentUserMessageID,
        toolCallID: toolCallID
      ),
      capabilityPolicy: actionPolicy,
      authorizationOrigin: .currentUserMessage,
      // A proposal tool invocation is the selected model's semantic classification of this current
      // user turn. It is not commit authority: the broker still requires the native card's fresh,
      // single-use confirmation gesture before any write or handoff.
      userExplicitlyRequestedAction: true,
      storedContentClaimsAuthorization: false,
      knownTodoListNames: knownTodoListNames,
      knownCalendarIdentifiers: knownCalendarIdentifiers,
      knownCodexWorkspaceIdentifiers: knownCodexWorkspaceIdentifiers
    )
    let intent = try AssistantActionProposalValidator.makeIntent(
      toolName: toolName,
      argumentsJSON: argumentsJSON,
      context: context,
      now: now
    )
    proposedIntent = intent
    return """
      Proposal prepared for native review; nothing was changed.
      intent_id=\(intent.id)
      review_title=\(Self.jsonString(intent.review.title))
      confirm_verb=\(Self.jsonString(intent.review.primaryVerb))
      expires_at=\(intent.expiresAt.ISO8601Format())
      """
  }

  /// Executes one external model tool call through the same pinned, budgeted local harness used by
  /// the on-device model. A completed call ID is an idempotency key: exact replays return the same
  /// result and a changed name or payload fails closed.
  func executeToolCall(
    callID: String,
    name: String,
    argumentsJSON: Data,
    progress: @escaping @Sendable (AskIAgentWorkStage) -> Void
  ) async throws -> AskIAgentV2ToolResult {
    try Self.validateCallID(callID)
    let prepared = try prepareExternalToolCall(name: name, argumentsJSON: argumentsJSON)
    let identity = ToolCallIdentity(name: prepared.name, payloadDigest: prepared.payloadDigest)

    if let existingIdentity = callIdentities[callID] {
      guard existingIdentity == identity else {
        throw AskIAgentV2ToolBridgeFailure.callIDPayloadMismatch(callID)
      }
      if let completed = completedToolCalls[callID] { return completed }
      if let inFlight = inFlightToolCalls[callID] {
        return try await withTaskCancellationHandler {
          try await inFlight.value
        } onCancel: {
          inFlight.cancel()
        }
      }
    } else {
      guard toolCallAttemptCount < Self.maximumToolCallAttempts else {
        let result = Self.toolCallBudgetExhaustedResult(callID: callID, prepared: prepared)
        // Cache the first rejected call so an exact replay remains idempotent and payload drift on
        // that call ID still fails closed. Later fresh calls receive the same bounded terminal
        // receipt without growing per-turn state after the hard budget is exhausted.
        if budgetExhaustionCallID == nil {
          budgetExhaustionCallID = callID
          callIdentities[callID] = identity
          completedToolCalls[callID] = result
        }
        return result
      }
      callIdentities[callID] = identity
      // Count admission before starting work. Successful reads/proposals and every repairable or
      // terminal tool receipt consume one attempt; exact call-ID replays above never consume again.
      toolCallAttemptCount += 1
    }

    let task = Task { [self] in
      try await performExternalToolCall(
        callID: callID,
        prepared: prepared,
        progress: progress
      )
    }
    inFlightToolCalls[callID] = task
    do {
      let result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      inFlightToolCalls[callID] = nil
      if completedToolCalls[callID] == nil {
        completedToolCalls[callID] = result
        toolCallOrder.append(callID)
      }
      return result
    } catch {
      inFlightToolCalls[callID] = nil
      throw error
    }
  }

  private nonisolated static func toolCallBudgetExhaustedResult(
    callID: String,
    prepared: PreparedExternalToolCall
  ) -> AskIAgentV2ToolResult {
    AskIAgentV2ToolResult(
      callID: callID,
      name: prepared.name,
      argumentsJSON: prepared.argumentsJSON,
      payloadDigest: prepared.payloadDigest,
      output: toolCallBudgetExhaustedOutput(),
      evidenceIDs: []
    )
  }

  private nonisolated static func toolCallBudgetExhaustedOutput() -> String {
    """
      {"code":"budgetExceeded","directive":"tool_call_budget_exhausted_do_not_retry","records_read":0,"repairable":false,"status":"tool_error"} The turn's total tool-call budget is exhausted. Do not call another read or proposal tool. No records were read and nothing was changed.
      """.askV2BoundedUTF16(600)
  }

  func remoteState() -> AskIAgentV2RemoteState {
    let boundedHistory = toolCallOrder.suffix(12).compactMap { completedToolCalls[$0] }
    return AskIAgentV2RemoteState(
      catalog: catalog,
      readToolSchemaVersion: AskReadToolSchemas.schemaVersion,
      readToolSchemaDigest: AskReadToolSchemas.schemaDigest,
      readToolSchemas: AskReadToolSchemas.all,
      actionToolSchemaVersion: AssistantProposalToolCatalog.schemaVersion,
      actionToolSchemaDigest: AssistantProposalToolCatalog.schemaDigest,
      enabledTools: enabledToolNames,
      actionToolDefinitions: actionToolDefinitions,
      evidence: Array(evidence.prefix(inferenceProfile.queryBudget.maximumEvidencePassages)),
      toolHistory: boundedHistory,
      budgetLimit: executor.budget,
      budgetUsage: budgetUsage
    )
  }

  private func prepareExternalToolCall(
    name: String,
    argumentsJSON: Data
  ) throws -> PreparedExternalToolCall {
    if AskReadToolSchemas.allowedNames.contains(name) {
      do {
        return .read(try AskReadToolCallDecoder.decode(name: name, argumentsJSON: argumentsJSON))
      } catch let failure as AskReadToolCallFailure where failure.code == .invalidArgument {
        // The decoder has already enforced the allowlist, payload bound, exact root keys, and
        // exact temporal keys before producing this semantic invalid-argument failure. Preserve a
        // canonical identity so exact retries replay one receipt and payload drift still fails.
        let canonical = try Self.canonicalRejectedReadArguments(name: name, data: argumentsJSON)
        return .rejectedRead(
          name: name,
          argumentsJSON: canonical.data,
          payloadDigest: canonical.digest,
          failure: failure
        )
      }
    }
    guard actionToolDefinitions.contains(where: { $0.name == name }) else {
      throw AskIAgentV2ToolBridgeFailure.unknownOrDisabledTool(name)
    }
    let canonical = try Self.canonicalActionArguments(name: name, data: argumentsJSON)
    return .proposal(
      name: name,
      argumentsJSON: canonical.data,
      payloadDigest: canonical.digest
    )
  }

  private func performExternalToolCall(
    callID: String,
    prepared: PreparedExternalToolCall,
    progress: @escaping @Sendable (AskIAgentWorkStage) -> Void
  ) async throws -> AskIAgentV2ToolResult {
    try Task.checkCancellation()
    let output: String
    let evidenceIDs: [String]
    switch prepared {
    case .read(let value):
      do {
        let execution = try await executeRead(value.query, progress: progress)
        output = execution.output.askV2Bounded(14_000)
        evidenceIDs = execution.evidenceIDs
      } catch let failure as AskQueryFailure {
        // A schema-valid, allowlisted read can still violate a domain-specific constraint (for
        // example notes + occurrence time, an invalid range/cursor, or the remaining budget).
        // Return that native typed failure as a bounded tool receipt so the model can repair its
        // next call. Bridge-integrity failures are raised before this point and still fail closed.
        output = try readFailureReceipt(failure)
        evidenceIDs = []
      }
    case .rejectedRead(_, _, _, let failure):
      output = readDecoderFailureReceipt(failure)
      evidenceIDs = []
    case .proposal(let name, let argumentsJSON, _):
      output = try prepareModelProposal(
        toolName: name,
        argumentsJSON: argumentsJSON,
        toolCallID: callID,
        now: Date()
      ).askV2Bounded(2_000)
      evidenceIDs = []
    }
    return AskIAgentV2ToolResult(
      callID: callID,
      name: prepared.name,
      argumentsJSON: prepared.argumentsJSON,
      payloadDigest: prepared.payloadDigest,
      output: output,
      evidenceIDs: evidenceIDs
    )
  }

  private static func validateCallID(_ callID: String) throws {
    let trimmed = callID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == callID, !callID.isEmpty, callID.utf16.count <= 120,
      callID.unicodeScalars.allSatisfy({ scalar in
        let value = scalar.value
        return (48...57).contains(value) || (65...90).contains(value)
          || (97...122).contains(value) || value == 45 || value == 95
      })
    else {
      throw AskIAgentV2ToolBridgeFailure.invalidCallID
    }
  }

  fileprivate func readFailureReceipt(
    _ failure: AskQueryFailure
  ) throws -> String {
    let repairable: Bool
    let directive: String
    switch failure.code {
    case .cancelled:
      throw CancellationError()
    case .invalidQuery, .invalidTemporalRange, .unsupportedTemporalField, .invalidCursor,
      .outOfCoverage:
      guard repairableReadFailureCount < 2 else {
        return Self.readFailureReceipt(
          failure,
          repairable: false,
          directive: "repair_budget_exhausted"
        )
      }
      repairableReadFailureCount += 1
      repairable = true
      directive = "revise_invalid_field_with_new_call_and_query_ids"
    case .budgetExceeded:
      repairable = false
      directive = "budget_exhausted_do_not_retry"
    case .invalidTemporalContext, .invalidBudget, .unavailable, .unsupportedDomain:
      throw failure
    }
    return Self.readFailureReceipt(failure, repairable: repairable, directive: directive)
  }

  private func readDecoderFailureReceipt(_ failure: AskReadToolCallFailure) -> String {
    let repairable = repairableReadFailureCount < 2
    if repairable { repairableReadFailureCount += 1 }
    return Self.readFailureReceipt(
      code: failure.code.rawValue,
      field: failure.field,
      repairable: repairable,
      directive: repairable
        ? "revise_invalid_field_with_new_call_and_query_ids"
        : "repair_budget_exhausted"
    )
  }

  private nonisolated static func readFailureReceipt(
    _ failure: AskQueryFailure,
    repairable: Bool,
    directive: String
  ) -> String {
    readFailureReceipt(
      code: failure.code.rawValue,
      field: failure.field,
      repairable: repairable,
      directive: directive
    )
  }

  private nonisolated static func readFailureReceipt(
    code: String,
    field: String?,
    repairable: Bool,
    directive: String
  ) -> String {
    var receipt: [String: Any] = [
      "status": "tool_error",
      "code": code,
      "repairable": repairable,
      "records_read": 0,
      "directive": directive,
    ]
    if let field { receipt["field"] = field }
    let encoded = (try? JSONSerialization.data(
      withJSONObject: receipt,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )).map { String(decoding: $0, as: UTF8.self) } ?? #"{"status":"tool_error"}"#
    let guidance = repairable
      ? "Revise only the invalid query field and retry with new call and query IDs."
      : "Do not retry this read."
    return "\(encoded) \(guidance) No records were read."
      .askV2BoundedUTF16(600)
  }

  private static func canonicalActionArguments(
    name: String,
    data: Data
  ) throws -> (data: Data, digest: String) {
    guard data.count <= 32_000 else {
      throw AskIAgentV2ToolBridgeFailure.malformedArguments(name)
    }
    let object: [String: Any]
    do {
      guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        throw AskIAgentV2ToolBridgeFailure.malformedArguments(name)
      }
      object = decoded
    } catch let error as AskIAgentV2ToolBridgeFailure {
      throw error
    } catch {
      throw AskIAgentV2ToolBridgeFailure.malformedArguments(name)
    }
    let canonical: Data
    do {
      canonical = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    } catch {
      throw AskIAgentV2ToolBridgeFailure.malformedArguments(name)
    }
    let digest = SHA256.hash(data: Data(name.utf8) + Data([0]) + canonical)
      .map { String(format: "%02x", $0) }
      .joined()
    return (canonical, digest)
  }

  private static func canonicalRejectedReadArguments(
    name: String,
    data: Data
  ) throws -> (data: Data, digest: String) {
    guard data.count <= AskReadToolCallDecoder.maximumArgumentsBytes else {
      throw AskIAgentV2ToolBridgeFailure.malformedArguments(name)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let canonical = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    else {
      throw AskIAgentV2ToolBridgeFailure.malformedArguments(name)
    }
    let digest = SHA256.hash(data: Data(name.utf8) + Data([0]) + canonical)
      .map { String(format: "%02x", $0) }
      .joined()
    return (canonical, digest)
  }

  func evidenceSnapshot() -> [AskIAgentEvidence] { evidence }

  func actionIntent() -> AssistantActionIntent? { proposedIntent }

  func hasNativeProposalFailure() -> Bool { lastProposalFailure != nil }

  /// The compact Foundation Models gateway deliberately advertises one stable schema. Enforce the
  /// user's live capability policy here, before the canonical external bridge, so a model-selected
  /// disabled kind becomes a truthful, repairable no-op rather than an opaque session failure.
  /// Remote calls keep using `executeToolCall` directly and therefore still reject unadvertised
  /// tools at the contract boundary.
  func executeCompactActionProposal(
    toolName: String,
    argumentsJSON: Data
  ) async throws -> String {
    let callID = nextNativeToolCallID(kind: "proposal")
    if !actionToolDefinitions.contains(where: { $0.name == toolName }) {
      guard let capability = AssistantProposalToolCatalog.capability(forToolNamed: toolName) else {
        throw AskIAgentV2ToolBridgeFailure.unknownOrDisabledTool(toolName)
      }
      // A policy-disabled compact proposal is still a model tool attempt. Count it even though it
      // deliberately stays outside the advertised remote-tool ledger, so repeated terminal no-op
      // receipts cannot bypass the turn-wide cap.
      guard toolCallAttemptCount < Self.maximumToolCallAttempts else {
        return Self.toolCallBudgetExhaustedOutput()
      }
      toolCallAttemptCount += 1
      guard proposalCallCount < 3 else {
        lastProposalFailure = .retryBudgetExhausted
        return "Proposal not prepared: the proposal retry budget is exhausted. Nothing changed."
      }
      proposalCallCount += 1
      lastProposalFailure = .capabilityDisabled(capability)
      return "Proposal not prepared: \(capability.settingsTitle) is disabled in Settings. Nothing changed. Do not substitute a different action kind."
    }
    let compactArgumentsJSON = try normalizedCompactActionArguments(
      toolName: toolName,
      argumentsJSON: argumentsJSON
    )
    return try await executeToolCall(
      callID: callID,
      name: toolName,
      argumentsJSON: compactArgumentsJSON,
      progress: { _ in }
    ).output
  }

  /// The compact Foundation Models schema shares one `targetID` field across people, lists,
  /// calendars, and workspaces. After the model has already selected a plain undated to-do, a
  /// non-list value in that field has no canonical target semantics. Normalize only that exact
  /// compact-only case to the default local list. Dated to-dos retain strict target validation,
  /// known list names remain exact, and the remote proposal contract is unchanged.
  private func normalizedCompactActionArguments(
    toolName: String,
    argumentsJSON: Data
  ) throws -> Data {
    guard toolName == AssistantProposalToolCatalog.createTodoName,
      var object = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any],
      Set(object.keys) == Set(["title", "due_at", "time_zone_id", "list_name"]),
      object["due_at"] is NSNull,
      let rawTarget = object["list_name"] as? String
    else { return argumentsJSON }

    let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    let isKnownList = knownTodoListNames.contains {
      $0.caseInsensitiveCompare(target) == .orderedSame
    }
    guard target.isEmpty || !isKnownList else { return argumentsJSON }

    object["list_name"] = NSNull()
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  #if canImport(FoundationModels)
    /// Foundation Models does not expose a stable call identifier to `Tool.call`. Allocate one
    /// inside the turn actor, then pass the compact gateway call through the same canonical
    /// decoder, idempotency ledger, budget, and proposal validator used by the remote harness.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    fileprivate func executeNativeReadGateway(
      _ query: AskReadQuery,
      progress: @escaping @Sendable (AskIAgentWorkStage) -> Void
    ) async throws -> String {
      let (name, argumentsJSON) = try Self.nativeReadToolCall(for: query)
      let callID = nextNativeToolCallID(kind: "read")
      return try await executeToolCall(
        callID: callID,
        name: name,
        argumentsJSON: argumentsJSON,
        progress: progress
      ).output
    }

    /// Foundation Models gives this gateway a typed Swift value, while the shared bridge accepts
    /// the canonical strict JSON contract used by the remote harness. Swift's synthesized
    /// `Encodable` omits nil optionals, but the strict contract requires every nullable field to be
    /// present as JSON null. Normalize that representation here before the common decoder so an
    /// ordinary model-selected read cannot fail as a tool-call error merely because `text`,
    /// `cursor`, or an absolute time bound is absent.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    nonisolated static func nativeReadToolCall(
      for query: AskReadQuery
    ) throws -> (name: String, argumentsJSON: Data) {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      encoder.dateEncodingStrategy = .iso8601

      let name: String
      let encoded: Data
      switch query {
      case .todo(let value):
        name = AskReadToolSchemas.todo.name
        encoded = try encoder.encode(value)
      case .calendar(let value):
        name = AskReadToolSchemas.calendar.name
        encoded = try encoder.encode(value)
      case .note(let value):
        name = AskReadToolSchemas.note.name
        encoded = try encoder.encode(value)
      case .meeting(let value):
        name = AskReadToolSchemas.meeting.name
        encoded = try encoder.encode(value)
      case .codex(let value):
        name = AskReadToolSchemas.codex.name
        encoded = try encoder.encode(value)
      }

      guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
        var time = object["time"] as? [String: Any]
      else {
        throw AskIAgentV2ToolBridgeFailure.malformedArguments(name)
      }
      for key in ["text", "cursor"] where object[key] == nil {
        object[key] = NSNull()
      }
      for key in ["start", "end"] where time[key] == nil {
        time[key] = NSNull()
      }
      object["time"] = time
      switch query {
      case .todo:
        if object["starred"] == nil { object["starred"] = NSNull() }
      case .calendar:
        if object["all_day"] == nil { object["all_day"] = NSNull() }
      case .meeting:
        if object["has_readable_content"] == nil {
          object["has_readable_content"] = NSNull()
        }
      case .note, .codex:
        break
      }
      let argumentsJSON = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      return (name, argumentsJSON)
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    fileprivate func executeNativeActionGateway(
      toolName: String,
      argumentsJSON: Data
    ) async throws -> String {
      try await executeCompactActionProposal(
        toolName: toolName,
        argumentsJSON: argumentsJSON
      )
    }

    private func nextNativeToolCallID(kind: String) -> String {
      nativeToolCallSequence += 1
      return "fm_\(kind)_\(nativeToolCallSequence)"
    }
  #endif

  func noMatchDescription() -> String {
    if let lastProposalFailure {
      return "I couldn’t prepare a review card. \(lastProposalFailure.userDescription) Nothing was changed."
    }
    let searched =
      queryMatchCounts
      .filter { $0.value == 0 }
      .map { AskIAgentSourceKind($0.key).displayName.lowercased() }
      .sorted()
    guard !searched.isEmpty else {
      return
        "I couldn’t produce a reliably grounded answer. Try naming the item or time range you want me to inspect."
    }
    return "I found no matching records in the queried \(searched.joined(separator: ", "))."
  }

  #if DEBUG
    func simulatedOutput(
      for request: AskIAgentGenerationRequest,
      progress: @escaping @Sendable (AskIAgentWorkStage) -> Void
    ) async throws -> AskIAgentGeneratorOutput {
      if ProcessInfo.processInfo.arguments.contains("--ask-iagent-v2-action-note-disabled") {
        let data = Data(#"{"title":"Trip plan","body":"Book the ferry."}"#.utf8)
        _ = try propose(
          toolName: AssistantProposalToolCatalog.createNoteName,
          argumentsJSON: data,
          now: request.contextAsOf
        )
        guard proposedIntent == nil else {
          return AskIAgentGeneratorOutput(
            claims: [Self.actionAcknowledgement(for: proposedIntent!)],
            proposedAction: proposedIntent
          )
        }
        return AskIAgentGeneratorOutput(
          claims: [
            AskIAgentGeneratedClaim(
              text:
                "Preparing note actions is disabled in Settings, so I didn’t prepare a review card or change anything.",
              evidenceIDs: [],
              grounding: .researchCoverage
            )
          ]
        )
      }

      if ProcessInfo.processInfo.arguments.contains("--ask-iagent-v2-action-note") {
        let data = Data(#"{"title":"Trip plan","body":"Book the ferry."}"#.utf8)
        _ = try propose(
          toolName: AssistantProposalToolCatalog.createNoteName,
          argumentsJSON: data,
          now: request.contextAsOf
        )
        return AskIAgentGeneratorOutput(
          claims: [Self.actionAcknowledgement(for: proposedIntent!)],
          proposedAction: proposedIntent
        )
      }

      let normalized = request.prompt.lowercased()
      if normalized.contains("last meeting") || normalized.contains("latest meeting") {
        _ = try await execute(
          .meeting(.latestCompletedReadable(queryID: "sim-latest-meeting")),
          progress: progress
        )
      } else {
        _ = try await execute(
          .calendar(
            AskCalendarQuery(
              queryID: "sim-calendar-today",
              time: AskQueryTimeFilter(field: .occurrence, preset: .today),
              sort: .startAsc,
              content: .details,
              limit: 4
            )),
          progress: progress
        )
        _ = try await execute(
          .todo(
            AskTodoQuery(
              queryID: "sim-todo-focus",
              states: [.open],
              sort: .attentionDesc,
              content: .preview,
              limit: 4
            )),
          progress: progress
        )
        _ = try await execute(
          .codex(
            AskCodexQuery(
              queryID: "sim-codex-active",
              states: [.running, .waitingForInput, .needsApproval],
              sort: .updatedDesc,
              content: .activity,
              limit: 4
            )),
          progress: progress
        )
      }
      progress(.composing)
      let selected = evidence
      guard !selected.isEmpty else {
        return AskIAgentGeneratorOutput(
          claims: [
            AskIAgentGeneratedClaim(
              text: noMatchDescription(), evidenceIDs: [], grounding: .researchCoverage)
          ]
        )
      }
      let grouped = Dictionary(grouping: selected, by: \.source.kind)
      var claims: [AskIAgentGeneratedClaim] = []
      for kind in [
        AskIAgentSourceKind.calendar, .todo, .codex, .meeting, .note,
      ] {
        let values = Array((grouped[kind] ?? []).askV2UniquedBySource().prefix(4))
        guard !values.isEmpty else { continue }
        let titles = values.map { $0.source.title }
        let lead: String
        switch kind {
        case .calendar: lead = "Keep these calendar times fixed: \(titles.joined(separator: ", "))."
        case .todo: lead = "Start with these open to-dos: \(titles.joined(separator: ", "))."
        case .codex: lead = "Also review this active Codex work: \(titles.joined(separator: ", "))."
        case .meeting: lead = "Your latest completed readable meeting is \(titles[0])."
        case .note: lead = "The relevant note is \(titles[0])."
        }
        claims.append(AskIAgentGeneratedClaim(text: lead, evidenceIDs: values.map(\.id)))
      }
      return AskIAgentGeneratorOutput(claims: claims, evidence: selected)
    }
  #endif

  private func ingest(_ candidates: [AskIAgentEvidence]) -> [AskIAgentEvidence] {
    var accepted: [AskIAgentEvidence] = []
    for candidate in candidates {
      let key = [candidate.source.id, candidate.revision, candidate.anchor ?? "record"]
        .joined(separator: "|")
      if let index = evidenceIndexByStableKey[key] {
        accepted.append(evidence[index])
        continue
      }
      guard evidence.count < inferenceProfile.queryBudget.maximumEvidencePassages else { break }
      let remapped = AskIAgentEvidence(
        id: "E\(evidence.count + 1)",
        source: candidate.source,
        revision: candidate.revision,
        anchor: candidate.anchor,
        content: candidate.content.askV2Bounded(inferenceProfile.evidenceContentCharacterLimit)
      )
      evidenceIndexByStableKey[key] = evidence.count
      evidence.append(remapped)
      accepted.append(remapped)
    }
    return accepted
  }

  private static func makeEvidence(_ item: AskQueryItem) -> [AskIAgentEvidence] {
    let kind = AskIAgentSourceKind(item.source.kind)
    let subtitle: String? =
      switch kind {
      case .todo:
        [
          item.collectionName,
          item.dueAt.map { "Due \($0.formatted(date: .abbreviated, time: .shortened))" },
        ]
        .compactMap { $0 }.joined(separator: " · ").askV2NilIfEmpty
      case .calendar:
        [
          item.startsAt.map { $0.formatted(date: .omitted, time: .shortened) },
          item.collectionName,
        ].compactMap { $0 }.joined(separator: " · ").askV2NilIfEmpty
      case .note:
        "Updated \(item.updatedAt.formatted(date: .abbreviated, time: .omitted))"
      case .meeting:
        item.startsAt?.formatted(date: .abbreviated, time: .omitted)
      case .codex:
        item.collectionName
      }
    let source = AskIAgentSourceResult(
      id: "\(kind.rawValue):\(item.source.entityID)",
      sourceID: item.source.entityID,
      kind: kind,
      title: item.title,
      subtitle: subtitle,
      status: item.status.map(displayStatus),
      excerpt: item.evidence.first?.excerpt.askV2Bounded(240),
      updatedAt: item.updatedAt,
      startDate: item.dueAt ?? item.startsAt,
      endDate: item.endsAt,
      isAllDay: item.isAllDay ?? false,
      isCompleted: item.status == .completed,
      isStarred: item.isStarred ?? false
    )
    return item.evidence.map { value in
      let content = [
        "Source: \(kind.displayName)",
        "Title: \(item.title)",
        item.status.map { "Status: \(displayStatus($0))" },
        item.dueAt.map { "Due: \($0.ISO8601Format())" },
        item.startsAt.map { "Start: \($0.ISO8601Format())" },
        item.endsAt.map { "End: \($0.ISO8601Format())" },
        item.collectionName.map { "Collection: \($0)" },
        "Excerpt:\n\(value.excerpt)",
      ].compactMap { $0 }.joined(separator: "\n")
      return AskIAgentEvidence(
        id: value.id,
        source: source,
        revision: String(Int(value.source.revision.timeIntervalSince1970 * 1_000)),
        anchor: value.anchor,
        content: content.askV2Bounded(1_200)
      )
    }
  }

  private static func displayStatus(_ status: AskKnowledgeStatus) -> String {
    switch status {
    case .open: "Open"
    case .completed: "Completed"
    case .scheduled: "Scheduled"
    case .recording: "Recording"
    case .running: "Running"
    case .waitingForInput: "Waiting for input"
    case .needsApproval: "Needs approval"
    case .failed: "Failed"
    }
  }

  private func toolEvidenceBlock(_ item: AskIAgentEvidence) -> String {
    let content = item.content.askV2Bounded(inferenceProfile.toolEvidenceCharacterLimit)
    return """
      [\(item.id)] source=\(item.source.kind.rawValue) title=\(Self.jsonString(item.source.title))
      content=\(Self.jsonString(content))
      """
  }

  private static func compactCatalogManifest(_ catalog: AskDataCatalog) -> String {
    let domains = catalog.domains.map { entry in
      var fields = [
        "\(entry.domain.rawValue):\(entry.availability.rawValue)",
        "count=\(entry.recordCount)",
        "freshness=\(entry.freshness.rawValue)",
      ]
      if let start = entry.coverage.start, let end = entry.coverage.end {
        fields.append("coverage_start=\(start.ISO8601Format())")
        fields.append("coverage_end=\(end.ISO8601Format())")
      } else {
        fields.append("coverage=unspecified")
      }
      fields.append("coverage_complete=\(entry.coverage.isCompleteWithinRange)")
      fields.append("coverage_truncated=\(entry.coverage.isTruncated)")
      return fields.joined(separator: ",")
    }
    return
      ([
        "protocol=\(catalog.version)",
        "time_zone=\(catalog.temporalContext.timeZoneIdentifier)",
        "locale=\(catalog.temporalContext.localeIdentifier)",
      ] + domains).joined(separator: "\n")
  }

  private static func jsonString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
      let encoded = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return encoded
  }

  private static func actionAcknowledgement(
    for intent: AssistantActionIntent
  ) -> AskIAgentGeneratedClaim {
    AskIAgentGeneratedClaim(
      text:
        "I prepared **\(intent.review.title)** for review. Nothing changes unless you tap **\(intent.review.primaryVerb)** on the card below.",
      evidenceIDs: [],
      grounding: .researchCoverage
    )
  }
}

#if canImport(FoundationModels)
  /// One compact read gateway keeps the on-device model in a single session. The model still
  /// chooses the domain and filters semantically; this adapter only translates its typed choice
  /// into the same strict queries used by the remote harness.
  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "A compact bounded read from the pinned iAgent snapshot")
  struct AskIAgentReadGatewayArguments {
    var queryID: String
    @Guide(description: "Data domain", .anyOf(["todo", "calendar", "note", "meeting", "codex"]))
    var domain: String
    var text: String?
    @Guide(
      description: "Time window",
      .anyOf([
        "any", "past", "today", "tomorrow", "yesterday", "thisWeek", "next7Days",
        "last7Days", "last30Days", "absolute",
      ]))
    var time: String
    @Guide(description: "Inclusive RFC 3339 start for absolute time, otherwise null")
    var start: String?
    @Guide(description: "Exclusive RFC 3339 end for absolute time, otherwise null")
    var end: String?
    @Guide(
      description: "Optional state filter",
      .anyOf(["any", "open", "completed", "active", "readable"]))
    var state: String
    @Guide(
      description: "Result ordering",
      .anyOf(["relevance", "attention", "ascending", "descending"]))
    var order: String
    @Guide(description: "Returned detail", .anyOf(["metadata", "preview", "full"]))
    var detail: String
    @Guide(description: "One through four records", .range(1...4))
    var limit: Int

    func query() throws -> AskReadQuery {
      guard let domain = AskSourceKind(rawValue: domain),
        let preset = AskQueryTemporalPreset(rawValue: time)
      else { throw AskQueryFailure(code: .invalidQuery, queryID: queryID, field: "gateway") }
      let timeField: AskQueryTemporalField
      switch domain {
      case .todo:
        timeField = .due
      case .calendar, .meeting:
        timeField = .occurrence
      case .note, .codex:
        timeField = .updated
      }
      let timeFilter = AskQueryTimeFilter(
        field: timeField,
        preset: preset,
        start: try start.map(parseDate),
        end: try end.map(parseDate)
      )
      let boundedLimit = min(max(limit, 1), 4)
      switch domain {
      case .todo:
        let states: [AskTodoStateFilter] = switch state {
        case "open", "active": [.open]
        case "completed": [.completed]
        default: []
        }
        let sort: AskTodoSort = switch order {
        case "attention": .attentionDesc
        case "ascending": .dueAsc
        case "descending": .updatedDesc
        default: .relevanceDesc
        }
        let content: AskTodoContent = switch detail {
        case "metadata": .metadata
        case "full": .full
        default: .preview
        }
        return .todo(
          AskTodoQuery(
            queryID: queryID,
            text: text,
            states: states,
            time: timeFilter,
            sort: sort,
            content: content,
            limit: boundedLimit
          ))

      case .calendar:
        let sort: AskCalendarSort = switch order {
        case "descending": .startDesc
        case "relevance": .relevanceDesc
        default: .startAsc
        }
        return .calendar(
          AskCalendarQuery(
            queryID: queryID,
            text: text,
            time: timeFilter,
            sort: sort,
            content: detail == "metadata" ? .metadata : .details,
            limit: boundedLimit
          ))

      case .note:
        let sort: AskNoteSort = order == "descending" ? .updatedDesc : .relevanceDesc
        let content: AskNoteContent = switch detail {
        case "metadata": .metadata
        case "full": .full
        default: .preview
        }
        return .note(
          AskNoteQuery(
            queryID: queryID,
            text: text,
            time: timeFilter,
            sort: sort,
            content: content,
            limit: boundedLimit
          ))

      case .meeting:
        let states: [AskMeetingStateFilter] = switch state {
        case "completed", "readable": [.completed]
        case "active": [.recording]
        default: []
        }
        let sort: AskMeetingSort = switch order {
        case "ascending": .occurrenceAsc
        case "relevance": .relevanceDesc
        default: .occurrenceDesc
        }
        let content: AskMeetingContent = switch detail {
        case "metadata": .metadata
        case "full": .summaryAndTranscriptPassages
        default: .summary
        }
        return .meeting(
          AskMeetingQuery(
            queryID: queryID,
            text: text,
            states: states,
            hasReadableContent: state == "readable" ? true : nil,
            time: timeFilter,
            sort: sort,
            content: content,
            limit: boundedLimit
          ))

      case .codex:
        let states: [AskCodexStateFilter] = switch state {
        case "active": [.running, .waitingForInput, .needsApproval]
        case "completed": [.completed]
        default: []
        }
        let sort: AskCodexSort = order == "relevance" ? .relevanceDesc : .updatedDesc
        let content: AskCodexContent = switch detail {
        case "metadata": .metadata
        case "full": .visibleOutputs
        default: .activity
        }
        return .codex(
          AskCodexQuery(
            queryID: queryID,
            text: text,
            states: states,
            time: timeFilter,
            sort: sort,
            content: content,
            limit: boundedLimit
          ))
      }
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "One uncommitted action proposal for native review")
  struct AskIAgentActionGatewayArguments {
    @Guide(description: "Action kind", .anyOf(["todo", "note", "calendar", "codex"]))
    var kind: String
    @Guide(description: "Todo, note, or calendar title; null only for Codex")
    var title: String?
    @Guide(description: "Note body, calendar notes, or Codex prompt; null for a to-do")
    var body: String?
    @Guide(
      description:
        "To-do only: RFC 3339 due timestamp with explicit offset; null when no due date was "
        + "requested and for every other kind"
    )
    var dueAt: String?
    @Guide(
      description:
        "Calendar only: RFC 3339 start timestamp with explicit offset; otherwise null"
    )
    var startAt: String?
    @Guide(
      description:
        "Calendar only: RFC 3339 end timestamp with explicit offset; otherwise null"
    )
    var endAt: String?
    @Guide(
      description:
        "IANA time zone; required with a to-do dueAt and for calendar, otherwise null"
    )
    var timeZoneID: String?
    @Guide(description: "Calendar only: whether the event is all day; otherwise null")
    var isAllDay: Bool?
    @Guide(
      description:
        "Exact existing to-do list name, calendar identifier, or Codex workspace identifier only "
        + "when the user explicitly requested that target; never a person; otherwise null"
    )
    var targetID: String?
    @Guide(description: "Calendar location only; otherwise null")
    var location: String?

    func proposal() throws -> (name: String, argumentsJSON: Data) {
      let name: String
      let values: [String: Any?]
      switch kind {
      case "todo":
        name = AssistantProposalToolCatalog.createTodoName
        let normalizedDueAt = gatewayOptional(dueAt)
        values = [
          "title": title,
          "due_at": normalizedDueAt,
          // The compact union may populate its shared time-zone field even when it correctly
          // chose no due date. A time zone has no semantics without a due timestamp, so canonical
          // to-do arguments must encode that harmless cross-kind residue as null. The inverse
          // remains invalid: a real due timestamp without a time zone still reaches strict native
          // validation and is rejected as ambiguous.
          "time_zone_id": normalizedDueAt == nil ? nil : gatewayOptional(timeZoneID),
          "list_name": gatewayOptional(targetID),
        ]
      case "note":
        name = AssistantProposalToolCatalog.createNoteName
        values = ["title": title, "body": body]
      case "calendar":
        name = AssistantProposalToolCatalog.draftCalendarEventName
        values = [
          "title": title,
          "start_at": startAt,
          "end_at": endAt,
          "time_zone_id": timeZoneID,
          "is_all_day": isAllDay,
          "calendar_id": targetID,
          "location": location,
          "notes": body,
        ]
      case "codex":
        name = AssistantProposalToolCatalog.requestCodexTaskName
        values = ["prompt": body ?? title, "workspace_id": targetID]
      default:
        throw AskIAgentV2ToolBridgeFailure.unknownOrDisabledTool(kind)
      }
      return (name, try actionJSON(values))
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  struct AskIAgentReadGatewayTool: Tool {
    let name = "query_iagent_data"
    let description = "Read one bounded domain from this turn's pinned iAgent snapshot. Read-only."
    let context: AskIAgentV2TurnContext
    let progress: @Sendable (AskIAgentWorkStage) -> Void

    func call(arguments: AskIAgentReadGatewayArguments) async throws -> String {
      do {
        return try await context.executeNativeReadGateway(
          try arguments.query(),
          progress: progress
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let failure as AskQueryFailure {
        return try await context.compactReadFailureReceipt(failure)
      } catch let failure as AskReadToolCallFailure {
        return await context.compactReadDecoderFailureReceipt(failure)
      } catch let failure as AskIAgentV2ToolBridgeFailure {
        return await context.compactReadBridgeFailureReceipt(failure)
      } catch {
        return AskIAgentV2TurnContext.compactUnexpectedReadFailureReceipt()
      }
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  struct AskIAgentActionGatewayTool: Tool {
    let name = "prepare_iagent_action"
    let description: String
    let context: AskIAgentV2TurnContext

    func call(arguments: AskIAgentActionGatewayArguments) async throws -> String {
      do {
        let proposal = try arguments.proposal()
        return try await context.executeNativeActionGateway(
          toolName: proposal.name,
          argumentsJSON: proposal.argumentsJSON
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let failure as AskIAgentV2ToolBridgeFailure {
        return await context.compactActionBridgeFailureReceipt(failure)
      } catch let failure as AssistantActionProposalError {
        return await context.compactActionArgumentFailureReceipt(
          failure.errorDescription ?? "The proposal arguments were invalid."
        )
      } catch {
        return await context.compactActionArgumentFailureReceipt(
          "The proposal arguments could not be processed."
        )
      }
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  extension AskIAgentV2TurnContext {
    fileprivate func compactReadFailureReceipt(_ failure: AskQueryFailure) throws -> String {
      switch failure.code {
      case .cancelled:
        throw CancellationError()
      case .invalidQuery, .invalidTemporalRange, .unsupportedTemporalField, .invalidCursor,
        .outOfCoverage, .budgetExceeded:
        return try readFailureReceipt(failure)
      case .invalidTemporalContext, .invalidBudget, .unavailable, .unsupportedDomain:
        return Self.readFailureReceipt(
          failure,
          repairable: false,
          directive: "native_read_unavailable_do_not_retry"
        )
      }
    }

    fileprivate func compactReadDecoderFailureReceipt(
      _ failure: AskReadToolCallFailure
    ) -> String {
      readDecoderFailureReceipt(failure)
    }

    fileprivate func compactReadBridgeFailureReceipt(
      _ failure: AskIAgentV2ToolBridgeFailure
    ) -> String {
      switch failure {
      case .unknownOrDisabledTool, .malformedArguments:
        let repairable = repairableReadFailureCount < 2
        if repairable { repairableReadFailureCount += 1 }
        return Self.readFailureReceipt(
          code: failure.bridgeReceiptCode,
          field: nil,
          repairable: repairable,
          directive: repairable
            ? "choose_a_supported_domain_and_revise_arguments"
            : "repair_budget_exhausted"
        )
      case .invalidCallID, .callIDPayloadMismatch:
        return Self.readFailureReceipt(
          code: failure.bridgeReceiptCode,
          field: nil,
          repairable: false,
          directive: "native_bridge_rejected_do_not_retry"
        )
      }
    }

    fileprivate nonisolated static func compactUnexpectedReadFailureReceipt() -> String {
      readFailureReceipt(
        code: "nativeReadFailed",
        field: nil,
        repairable: false,
        directive: "native_read_failed_do_not_retry"
      )
    }

    fileprivate func compactActionBridgeFailureReceipt(
      _ failure: AskIAgentV2ToolBridgeFailure
    ) -> String {
      let detail: String
      switch failure {
      case .unknownOrDisabledTool:
        detail = "The requested action kind is invalid or disabled."
      case .malformedArguments:
        detail = "The proposal arguments were malformed."
      case .invalidCallID, .callIDPayloadMismatch:
        detail = "The proposal request could not be validated."
      }
      return compactActionArgumentFailureReceipt(detail)
    }

    fileprivate func compactActionArgumentFailureReceipt(_ detail: String) -> String {
      guard toolCallAttemptCount < Self.maximumToolCallAttempts else {
        return Self.toolCallBudgetExhaustedOutput()
      }
      toolCallAttemptCount += 1
      guard proposalCallCount < 3 else {
        lastProposalFailure = .retryBudgetExhausted
        return "Proposal not prepared: the proposal retry budget is exhausted. Do not call another proposal tool. Nothing changed."
      }
      proposalCallCount += 1
      let bounded = detail.askV2BoundedUTF16(400)
      lastProposalFailure = .invalidArguments(bounded)
      return "Proposal not prepared: \(bounded) Revise the arguments and call the appropriate proposal tool again. Nothing changed."
        .askV2BoundedUTF16(600)
    }

    nonisolated func compactTools(
      progress: @escaping @Sendable (AskIAgentWorkStage) -> Void
    ) -> [any Tool] {
      var result: [any Tool] = [AskIAgentReadGatewayTool(context: self, progress: progress)]
      let enabledKinds = actionToolDefinitions.compactMap {
        switch AssistantProposalToolCatalog.capability(forToolNamed: $0.name) {
        case .createTodo: "todo"
        case .createNote: "note"
        case .draftCalendarEvent: "calendar"
        case .requestCodexTask: "codex"
        case nil: nil
        }
      }.joined(separator: ", ")
      result.append(
        AskIAgentActionGatewayTool(
          description:
            "Prepare one uncommitted native review card. Enabled action kinds: \(enabledKinds.isEmpty ? "none" : enabledKinds). Disabled kinds return a Settings-disabled no-op receipt. Never writes or confirms.",
          context: self
        ))
      return result
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "A half-open temporal filter pinned to the turn time zone")
  private struct AskIAgentV2TimeArguments {
    @Guide(
      description: "The record timestamp to filter",
      .anyOf(["due", "occurrence", "completed", "created", "updated", "visibleOutput"])
    )
    var field: String
    @Guide(
      description: "A bounded temporal preset",
      .anyOf([
        "any", "past", "today", "tomorrow", "yesterday", "thisWeek", "next7Days", "last7Days",
        "last30Days", "absolute",
      ])
    )
    var preset: String
    @Guide(description: "Inclusive RFC 3339 start for absolute ranges, otherwise null")
    var start: String?
    @Guide(description: "Exclusive RFC 3339 end for absolute ranges, otherwise null")
    var end: String?

    func value() throws -> AskQueryTimeFilter {
      guard let field = AskQueryTemporalField(rawValue: field),
        let preset = AskQueryTemporalPreset(rawValue: preset)
      else { throw AskQueryFailure(code: .invalidQuery, field: "time") }
      let startDate = try start.map(parseDate)
      let endDate = try end.map(parseDate)
      return AskQueryTimeFilter(field: field, preset: preset, start: startDate, end: endDate)
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "A strict bounded to-do query")
  private struct AskIAgentV2TodoArguments {
    var queryID: String
    var text: String?
    var recordIDs: [String]
    var states: [String]
    var starred: Bool?
    var listNames: [String]
    @Guide(
      description: "Exact due-date condition",
      .anyOf(["any", "hasDueDate", "noDueDate", "overdue", "dueInWindow"]))
    var due: String
    var time: AskIAgentV2TimeArguments
    @Guide(
      description: "Deterministic sort",
      .anyOf([
        "relevanceDesc", "attentionDesc", "dueAsc", "updatedDesc", "createdDesc", "completedDesc",
      ]))
    var sort: String
    @Guide(description: "Returned content", .anyOf(["metadata", "preview", "full"]))
    var content: String
    @Guide(description: "One through eight records", .range(1...8))
    var limit: Int
    var cursor: String?

    func query() throws -> AskTodoQuery {
      AskTodoQuery(
        queryID: queryID,
        text: text,
        recordIDs: recordIDs,
        states: try enumValues(states, as: AskTodoStateFilter.self),
        starred: starred,
        due: try enumValue(due, as: AskTodoDueFilter.self),
        listNames: listNames,
        time: try time.value(),
        sort: try enumValue(sort, as: AskTodoSort.self),
        content: try enumValue(content, as: AskTodoContent.self),
        limit: limit,
        cursor: cursor
      )
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "A strict bounded calendar occurrence query")
  private struct AskIAgentV2CalendarArguments {
    var queryID: String
    var text: String?
    var recordIDs: [String]
    var calendarTitles: [String]
    var allDay: Bool?
    var time: AskIAgentV2TimeArguments
    @Guide(
      description: "Deterministic sort",
      .anyOf(["relevanceDesc", "startAsc", "startDesc", "updatedDesc"]))
    var sort: String
    @Guide(description: "Returned content", .anyOf(["metadata", "details"]))
    var content: String
    @Guide(description: "One through eight records", .range(1...8))
    var limit: Int
    var cursor: String?

    func query() throws -> AskCalendarQuery {
      AskCalendarQuery(
        queryID: queryID,
        text: text,
        recordIDs: recordIDs,
        calendarTitles: calendarTitles,
        allDay: allDay,
        time: try time.value(),
        sort: try enumValue(sort, as: AskCalendarSort.self),
        content: try enumValue(content, as: AskCalendarContent.self),
        limit: limit,
        cursor: cursor
      )
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "A strict bounded standalone-note query")
  private struct AskIAgentV2NoteArguments {
    var queryID: String
    var text: String?
    var recordIDs: [String]
    var time: AskIAgentV2TimeArguments
    @Guide(
      description: "Deterministic sort", .anyOf(["relevanceDesc", "updatedDesc", "createdDesc"]))
    var sort: String
    @Guide(description: "Returned content", .anyOf(["metadata", "preview", "full"]))
    var content: String
    @Guide(description: "One through eight records", .range(1...8))
    var limit: Int
    var cursor: String?

    func query() throws -> AskNoteQuery {
      AskNoteQuery(
        queryID: queryID,
        text: text,
        recordIDs: recordIDs,
        time: try time.value(),
        sort: try enumValue(sort, as: AskNoteSort.self),
        content: try enumValue(content, as: AskNoteContent.self),
        limit: limit,
        cursor: cursor
      )
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "A strict bounded meeting query")
  private struct AskIAgentV2MeetingArguments {
    var queryID: String
    var text: String?
    var recordIDs: [String]
    var states: [String]
    var hasReadableContent: Bool?
    var time: AskIAgentV2TimeArguments
    @Guide(
      description: "Deterministic sort",
      .anyOf(["relevanceDesc", "occurrenceDesc", "occurrenceAsc", "updatedDesc"]))
    var sort: String
    @Guide(
      description: "Returned content",
      .anyOf(["metadata", "summary", "summaryAndTranscriptPassages"]))
    var content: String
    @Guide(description: "One through eight records", .range(1...8))
    var limit: Int
    var cursor: String?

    func query() throws -> AskMeetingQuery {
      AskMeetingQuery(
        queryID: queryID,
        text: text,
        recordIDs: recordIDs,
        states: try enumValues(states, as: AskMeetingStateFilter.self),
        hasReadableContent: hasReadableContent,
        time: try time.value(),
        sort: try enumValue(sort, as: AskMeetingSort.self),
        content: try enumValue(content, as: AskMeetingContent.self),
        limit: limit,
        cursor: cursor
      )
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "A strict bounded safe Codex task query")
  private struct AskIAgentV2CodexArguments {
    var queryID: String
    var text: String?
    var recordIDs: [String]
    var states: [String]
    var modes: [String]
    var projectNames: [String]
    var time: AskIAgentV2TimeArguments
    @Guide(
      description: "Deterministic sort", .anyOf(["relevanceDesc", "updatedDesc", "createdDesc"]))
    var sort: String
    @Guide(description: "Returned content", .anyOf(["metadata", "activity", "visibleOutputs"]))
    var content: String
    @Guide(description: "One through eight records", .range(1...8))
    var limit: Int
    var cursor: String?

    func query() throws -> AskCodexQuery {
      AskCodexQuery(
        queryID: queryID,
        text: text,
        recordIDs: recordIDs,
        states: try enumValues(states, as: AskCodexStateFilter.self),
        modes: try enumValues(modes, as: AskCodexModeFilter.self),
        projectNames: projectNames,
        time: try time.value(),
        sort: try enumValue(sort, as: AskCodexSort.self),
        content: try enumValue(content, as: AskCodexContent.self),
        limit: limit,
        cursor: cursor
      )
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private struct AskIAgentV2TodoTool: Tool {
    let name = "query_todos"
    let description = "Read bounded to-dos from the pinned local snapshot. Read-only."
    let context: AskIAgentV2TurnContext
    let progress: @Sendable (AskIAgentWorkStage) -> Void
    func call(arguments: AskIAgentV2TodoArguments) async throws -> String {
      try await context.execute(.todo(try arguments.query()), progress: progress)
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private struct AskIAgentV2CalendarTool: Tool {
    let name = "query_calendar"
    let description = "Read bounded calendar occurrences from the pinned local capture. Read-only."
    let context: AskIAgentV2TurnContext
    let progress: @Sendable (AskIAgentWorkStage) -> Void
    func call(arguments: AskIAgentV2CalendarArguments) async throws -> String {
      try await context.execute(.calendar(try arguments.query()), progress: progress)
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private struct AskIAgentV2NoteTool: Tool {
    let name = "query_notes"
    let description =
      "Read bounded standalone note passages from the pinned local snapshot. Read-only."
    let context: AskIAgentV2TurnContext
    let progress: @Sendable (AskIAgentWorkStage) -> Void
    func call(arguments: AskIAgentV2NoteArguments) async throws -> String {
      try await context.execute(.note(try arguments.query()), progress: progress)
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private struct AskIAgentV2MeetingTool: Tool {
    let name = "query_meetings"
    let description =
      "Read bounded meeting summaries or transcript passages from the pinned snapshot. Read-only."
    let context: AskIAgentV2TurnContext
    let progress: @Sendable (AskIAgentWorkStage) -> Void
    func call(arguments: AskIAgentV2MeetingArguments) async throws -> String {
      try await context.execute(.meeting(try arguments.query()), progress: progress)
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private struct AskIAgentV2CodexTool: Tool {
    let name = "query_codex"
    let description =
      "Read bounded safe Codex activity or visible outputs. Hidden reasoning is unavailable. Read-only."
    let context: AskIAgentV2TurnContext
    let progress: @Sendable (AskIAgentWorkStage) -> Void
    func call(arguments: AskIAgentV2CodexArguments) async throws -> String {
      try await context.execute(.codex(try arguments.query()), progress: progress)
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "Prepare one uncommitted local to-do proposal")
  private struct AskIAgentPrepareTodoArguments {
    var title: String
    var dueAt: String?
    var timeZoneID: String?
    var listName: String?
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "Prepare one uncommitted local note proposal")
  private struct AskIAgentPrepareNoteArguments {
    var title: String
    var body: String
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "Prepare one uncommitted Calendar editor draft")
  private struct AskIAgentPrepareCalendarArguments {
    var title: String
    var startAt: String
    var endAt: String
    var timeZoneID: String
    var isAllDay: Bool
    var calendarID: String?
    var location: String?
    var notes: String?
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "Prepare one uncommitted Codex request handoff")
  private struct AskIAgentPrepareCodexArguments {
    var prompt: String
    var workspaceID: String?
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private struct AskIAgentPrepareTodoTool: Tool {
    let name = AssistantProposalToolCatalog.createTodoName
    let description: String
    let context: AskIAgentV2TurnContext
    func call(arguments: AskIAgentPrepareTodoArguments) async throws -> String {
      try await context.propose(
        toolName: name,
        argumentsJSON: actionJSON([
          "title": arguments.title,
          "due_at": arguments.dueAt,
          "time_zone_id": arguments.timeZoneID,
          "list_name": arguments.listName,
        ]))
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private struct AskIAgentPrepareNoteTool: Tool {
    let name = AssistantProposalToolCatalog.createNoteName
    let description: String
    let context: AskIAgentV2TurnContext
    func call(arguments: AskIAgentPrepareNoteArguments) async throws -> String {
      try await context.propose(
        toolName: name,
        argumentsJSON: actionJSON(["title": arguments.title, "body": arguments.body]))
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private struct AskIAgentPrepareCalendarTool: Tool {
    let name = AssistantProposalToolCatalog.draftCalendarEventName
    let description: String
    let context: AskIAgentV2TurnContext
    func call(arguments: AskIAgentPrepareCalendarArguments) async throws -> String {
      try await context.propose(
        toolName: name,
        argumentsJSON: actionJSON([
          "title": arguments.title,
          "start_at": arguments.startAt,
          "end_at": arguments.endAt,
          "time_zone_id": arguments.timeZoneID,
          "is_all_day": arguments.isAllDay,
          "calendar_id": arguments.calendarID,
          "location": arguments.location,
          "notes": arguments.notes,
        ]))
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private struct AskIAgentPrepareCodexTool: Tool {
    let name = AssistantProposalToolCatalog.requestCodexTaskName
    let description: String
    let context: AskIAgentV2TurnContext
    func call(arguments: AskIAgentPrepareCodexArguments) async throws -> String {
      try await context.propose(
        toolName: name,
        argumentsJSON: actionJSON([
          "prompt": arguments.prompt,
          "workspace_id": arguments.workspaceID,
        ]))
    }
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  extension AskIAgentV2TurnContext {
    nonisolated func tools(
      readDomains: Set<AskSourceKind>,
      proposalToolName: String?,
      progress: @escaping @Sendable (AskIAgentWorkStage) -> Void
    ) -> [any Tool] {
      var tools: [any Tool] = []
      if readDomains.contains(.todo) {
        tools.append(AskIAgentV2TodoTool(context: self, progress: progress))
      }
      if readDomains.contains(.calendar) {
        tools.append(AskIAgentV2CalendarTool(context: self, progress: progress))
      }
      if readDomains.contains(.note) {
        tools.append(AskIAgentV2NoteTool(context: self, progress: progress))
      }
      if readDomains.contains(.meeting) {
        tools.append(AskIAgentV2MeetingTool(context: self, progress: progress))
      }
      if readDomains.contains(.codex) {
        tools.append(AskIAgentV2CodexTool(context: self, progress: progress))
      }
      let definitions = Dictionary(
        uniqueKeysWithValues: actionToolDefinitions.map { ($0.name, $0) })
      if proposalToolName == AssistantProposalToolCatalog.createTodoName,
        let value = definitions[AssistantProposalToolCatalog.createTodoName]
      {
        tools.append(AskIAgentPrepareTodoTool(description: value.description, context: self))
      }
      if proposalToolName == AssistantProposalToolCatalog.createNoteName,
        let value = definitions[AssistantProposalToolCatalog.createNoteName]
      {
        tools.append(AskIAgentPrepareNoteTool(description: value.description, context: self))
      }
      if proposalToolName == AssistantProposalToolCatalog.draftCalendarEventName,
        let value = definitions[AssistantProposalToolCatalog.draftCalendarEventName]
      {
        tools.append(AskIAgentPrepareCalendarTool(description: value.description, context: self))
      }
      if proposalToolName == AssistantProposalToolCatalog.requestCodexTaskName,
        let value = definitions[AssistantProposalToolCatalog.requestCodexTaskName]
      {
        tools.append(AskIAgentPrepareCodexTool(description: value.description, context: self))
      }
      return tools
    }
  }

  private func enumValue<Value: RawRepresentable>(
    _ raw: String,
    as type: Value.Type
  ) throws -> Value where Value.RawValue == String {
    guard let value = Value(rawValue: raw) else {
      throw AskQueryFailure(code: .invalidQuery, field: raw)
    }
    return value
  }

  private func enumValues<Value: RawRepresentable>(
    _ raw: [String],
    as type: Value.Type
  ) throws -> [Value] where Value.RawValue == String {
    try raw.map { try enumValue($0, as: type) }
  }

  private func parseDate(_ raw: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let value = formatter.date(from: raw) { return value }
    formatter.formatOptions = [.withInternetDateTime]
    guard let value = formatter.date(from: raw) else {
      throw AskQueryFailure(code: .invalidTemporalRange, field: "time")
    }
    return value
  }

  private func actionJSON(_ values: [String: Any?]) throws -> Data {
    let object = values.mapValues { $0 ?? NSNull() }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func gatewayOptional(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
#endif

extension Array where Element == AskIAgentEvidence {
  fileprivate func askV2UniquedBySource() -> [AskIAgentEvidence] {
    var seen = Set<String>()
    return filter { seen.insert($0.source.id).inserted }
  }
}

extension String {
  fileprivate var askV2NilIfEmpty: String? { isEmpty ? nil : self }

  fileprivate func askV2Bounded(_ limit: Int) -> String {
    guard count > limit else { return self }
    return String(prefix(limit)) + "…"
  }

  fileprivate func askV2BoundedUTF16(_ limit: Int) -> String {
    guard utf16.count > limit else { return self }
    var result = ""
    var used = 0
    for character in self {
      let width = String(character).utf16.count
      guard used + width <= limit - 1 else { break }
      result.append(character)
      used += width
    }
    return result + "…"
  }
}

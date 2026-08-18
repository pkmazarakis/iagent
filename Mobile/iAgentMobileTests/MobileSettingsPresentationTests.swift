import AVFoundation
import DeviceCheck
import EventKit
import Foundation
#if canImport(FoundationModels)
  import FoundationModels
#endif
import Speech
import XCTest
import iAgentActionContracts
@testable import iAgentActions
import iAgentCore
@testable import iAgent

final class MobileSettingsPresentationTests: XCTestCase {
  func testPendingChangesRemainVisibleWhenSyncIsIdle() {
    let presentation = MobileSyncStatusPresentation(
      status: IAgentCloudSyncStatus(phase: .idle),
      pendingCount: 2,
      isUsingPreviewData: false
    )

    XCTAssertEqual(presentation.title, "Waiting to sync")
    XCTAssertEqual(presentation.detail, "2 local changes are waiting for iCloud.")
    XCTAssertEqual(presentation.tone, .warning)
  }

  func testFailureKeepsTheCloudErrorMessageVisible() {
    let presentation = MobileSyncStatusPresentation(
      status: IAgentCloudSyncStatus(phase: .failed, message: "Network unavailable"),
      pendingCount: 0,
      isUsingPreviewData: false
    )

    XCTAssertEqual(presentation.title, "Sync issue")
    XCTAssertEqual(presentation.detail, "Network unavailable")
    XCTAssertEqual(presentation.tone, .error)
  }

  func testPreviewModeDoesNotClaimToUseCloudSync() {
    let presentation = MobileSyncStatusPresentation(
      status: IAgentCloudSyncStatus(phase: .idle, lastSuccessfulSyncAt: Date()),
      pendingCount: 0,
      isUsingPreviewData: true
    )

    XCTAssertEqual(presentation.title, "Preview data")
    XCTAssertEqual(presentation.detail, "Local sample data is ready for UI testing.")
    XCTAssertEqual(presentation.tone, .neutral)
  }

  func testPermissionStatusesUsePlainLanguage() {
    XCTAssertEqual(MobilePermissionSnapshot.calendarStatus(.fullAccess), .granted("Full Access"))
    XCTAssertEqual(MobilePermissionSnapshot.calendarStatus(.writeOnly), .limited("Add Only"))
    XCTAssertEqual(MobilePermissionSnapshot.calendarStatus(.restricted), .limited("Restricted"))
    XCTAssertEqual(MobilePermissionSnapshot.microphoneStatus(.denied), .denied)
    XCTAssertEqual(MobilePermissionSnapshot.speechStatus(.notDetermined), .notRequested)
    XCTAssertEqual(MobilePermissionSnapshot.Status.notRequested.label, "Not Asked")
  }

  func testIdleBeforeFirstCloudSyncDoesNotClaimCloudSuccess() {
    let presentation = MobileSyncStatusPresentation(
      status: IAgentCloudSyncStatus(phase: .idle),
      pendingCount: 0,
      isUsingPreviewData: false
    )

    XCTAssertEqual(presentation.title, "Stored locally")
    XCTAssertEqual(presentation.detail, "No successful iCloud sync has completed yet.")
    XCTAssertEqual(presentation.tone, .neutral)
  }

  @MainActor
  func testMessagePreviewRetainsFourteenDayWindowAndMonotonicReadState() async throws {
    let model = MobileAppModel()
    await model.start()

    XCTAssertEqual(model.visibleConversations.count, 3)
    XCTAssertEqual(
      model.visibleConversations.map(\.id),
      [
        "fixture-conversation-maya",
        "fixture-conversation-group",
        "fixture-conversation-alex",
      ]
    )
    XCTAssertEqual(model.unreadConversationCount, 2)
    XCTAssertEqual(model.awaitingReplyConversationCount, 2)
    XCTAssertEqual(
      model.filteredConversations(filter: .all).map(\.id),
      model.visibleConversations.map(\.id)
    )
    XCTAssertEqual(
      model.filteredConversations(filter: .unread).map(\.id),
      ["fixture-conversation-maya", "fixture-conversation-group"]
    )
    XCTAssertEqual(
      model.filteredConversations(filter: .awaitingReply).map(\.id),
      ["fixture-conversation-maya", "fixture-conversation-alex"]
    )
    XCTAssertEqual(model.messages(for: "fixture-conversation-maya").count, 3)
    XCTAssertFalse(
      model.visibleConversations.contains { $0.id == "fixture-conversation-expired" }
    )
    XCTAssertEqual(model.latestMessageRelayState?.phase, .available)
    XCTAssertEqual(model.syncPendingCount, 0)

    let homeSummary = model.homeUnreadMessageSummary()
    XCTAssertEqual(homeSummary.contactItems.map(\.contactName), ["Maya Chen"])
    XCTAssertEqual(
      homeSummary.contactItems.first?.previewText,
      "Perfect. I booked the table by the window."
    )
    XCTAssertEqual(homeSummary.remainingUnreadMessageCount, 2)

    let maya = try XCTUnwrap(
      model.visibleConversations.first { $0.id == "fixture-conversation-maya" }
    )
    let alex = try XCTUnwrap(
      model.visibleConversations.first { $0.id == "fixture-conversation-alex" }
    )
    XCTAssertTrue(model.isAwaitingReply(maya))
    XCTAssertEqual(model.unreadCount(for: alex.id), 0)
    XCTAssertTrue(model.isAwaitingReply(alex))

    await model.markConversationRead("fixture-conversation-maya")

    XCTAssertEqual(model.unreadCount(for: "fixture-conversation-maya"), 0)
    XCTAssertEqual(model.unreadConversationCount, 1)
    XCTAssertEqual(model.awaitingReplyConversationCount, 2)
    XCTAssertEqual(
      model.visibleConversations.map(\.id),
      [
        "fixture-conversation-group",
        "fixture-conversation-maya",
        "fixture-conversation-alex",
      ]
    )
    XCTAssertEqual(
      model.filteredConversations(filter: .unread).map(\.id),
      ["fixture-conversation-group"]
    )
    XCTAssertEqual(
      model.filteredConversations(filter: .awaitingReply).map(\.id),
      ["fixture-conversation-maya", "fixture-conversation-alex"]
    )
    XCTAssertTrue(model.isAwaitingReply(maya))
    XCTAssertTrue(model.homeUnreadMessageSummary().contactItems.isEmpty)
    XCTAssertEqual(model.homeUnreadMessageSummary().remainingUnreadMessageCount, 2)
  }

  func testMobileMessageFilterTogglesSelectionBackToAll() {
    XCTAssertEqual(MobileMessageInboxFilter.all.toggled(with: .unread), .unread)
    XCTAssertEqual(MobileMessageInboxFilter.unread.toggled(with: .unread), .all)
    XCTAssertEqual(
      MobileMessageInboxFilter.unread.toggled(with: .awaitingReply),
      .awaitingReply
    )
    XCTAssertEqual(
      MobileMessageInboxFilter.awaitingReply.toggled(with: .awaitingReply),
      .all
    )
  }

  func testMobileMessageAvatarToneSeparatesKnownUnknownAndGroupConversations() {
    func conversation(
      displayName: String,
      participants: [SyncedMessageParticipant] = [],
      isGroup: Bool = false
    ) -> SyncedMessageConversation {
      SyncedMessageConversation(
        id: "conversation-\(displayName)-\(isGroup)",
        displayName: displayName,
        participants: participants,
        isGroup: isGroup,
        latestMessageID: "message",
        latestMessageDate: .now,
        latestPreview: "Preview",
        updatedAt: .now
      )
    }

    let knownContact = SyncedMessageParticipant(
      id: "known",
      displayName: "Avery Chen",
      isContactNameResolved: true
    )
    let unknownContact = SyncedMessageParticipant(
      id: "unknown",
      displayName: "+15551234567",
      isContactNameResolved: false
    )

    XCTAssertEqual(
      mobileMessageAvatarTone(
        for: conversation(
          displayName: "Weekend crew",
          participants: [knownContact, unknownContact],
          isGroup: true
        )
      ),
      .group
    )
    XCTAssertEqual(
      mobileMessageAvatarTone(
        for: conversation(displayName: "Avery Chen", participants: [knownContact])
      ),
      .knownDirect
    )
    XCTAssertEqual(
      mobileMessageAvatarTone(
        for: conversation(displayName: "+15551234567", participants: [unknownContact])
      ),
      .unresolvedDirect
    )
    XCTAssertEqual(
      mobileMessageAvatarTone(for: conversation(displayName: "unknown@example.com")),
      .unresolvedDirect
    )
    XCTAssertEqual(
      mobileMessageAvatarTone(for: conversation(displayName: "Unknown Contact")),
      .unresolvedDirect
    )
  }

  @MainActor
  func testHomeMessageContactFilterRequiresVerifiedDirectSender() {
    let model = MobileAppModel()
    let now = Date()
    let message = SyncedMessage(
      id: "message",
      conversationID: "conversation",
      senderID: "participant",
      senderDisplayName: "Maya Chen",
      isFromMe: false,
      body: "Hello",
      sentAt: now,
      updatedAt: now
    )
    let verifiedParticipant = SyncedMessageParticipant(
      id: "participant",
      displayName: "Maya Chen",
      isContactNameResolved: true
    )
    var conversation = SyncedMessageConversation(
      id: "conversation",
      displayName: "Maya Chen",
      participants: [verifiedParticipant],
      isGroup: false,
      latestMessageID: message.id,
      latestMessageDate: now,
      latestPreview: message.body,
      updatedAt: now
    )

    XCTAssertEqual(
      model.homeContactParticipant(for: conversation, latestUnreadMessage: message),
      verifiedParticipant
    )

    conversation.participants[0].isContactNameResolved = nil
    XCTAssertNil(model.homeContactParticipant(for: conversation, latestUnreadMessage: message))

    conversation.participants[0].isContactNameResolved = false
    XCTAssertNil(model.homeContactParticipant(for: conversation, latestUnreadMessage: message))

    conversation.participants[0].isContactNameResolved = true
    conversation.isGroup = true
    XCTAssertNil(model.homeContactParticipant(for: conversation, latestUnreadMessage: message))
  }
}

@MainActor
final class MobileNoteTitleIndependenceTests: XCTestCase {
  func testVoiceStyleMentionBodySavesAndRestoresWithoutBecomingTitle() async {
    let model = MobileAppModel()
    let body = "@Ada capture this exactly as dictated."

    let saved = await model.saveNote(title: "", body: body)
    let restored = model.note(id: saved.id)

    XCTAssertEqual(saved.title, "Untitled note")
    XCTAssertEqual(saved.body, body)
    XCTAssertEqual(restored?.title, "Untitled note")
    XCTAssertEqual(restored?.body, body)
    XCTAssertFalse(restored?.title.contains("@") == true)

    await model.deleteNote(restored ?? saved)
  }

  func testMeetingSummaryChangesBodyWithoutRewritingExplicitTitle() async {
    let model = MobileAppModel()
    let title = "Weekly product sync"
    let originalBody = MeetingNoteContent(
      transcript: "@Maya opened the discussion."
    ).markdown
    let saved = await model.saveNote(
      title: title,
      body: originalBody,
      kind: .meeting
    )

    let didSaveSummary = await model.saveMeetingSummary(
      noteID: saved.id,
      summary: "Ship the reviewed plan on Friday.",
      expectedBody: originalBody
    )
    let restored = model.note(id: saved.id)

    XCTAssertTrue(didSaveSummary)
    XCTAssertEqual(restored?.title, title)
    XCTAssertEqual(
      restored.map { MeetingNoteContent(markdown: $0.body).transcript },
      "@Maya opened the discussion."
    )
    XCTAssertEqual(
      restored.flatMap { MeetingNoteContent(markdown: $0.body).summary },
      "Ship the reviewed plan on Friday."
    )

    await model.deleteNote(restored ?? saved)
  }
}

final class AskIAgentV2ActionFlowTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_786_381_200)

  #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func testFreeNativeReadGatewayEmitsStrictDecoderCompatibleNullsAndDates() throws {
      let absoluteStart = Date(timeIntervalSince1970: 1_786_320_000)
      let absoluteEnd = Date(timeIntervalSince1970: 1_786_406_400)
      let queries: [AskReadQuery] = [
        .todo(
          AskTodoQuery(
            queryID: "free-todo",
            time: AskQueryTimeFilter(field: .due),
            limit: 4
          )),
        .calendar(
          AskCalendarQuery(
            queryID: "free-calendar",
            time: AskQueryTimeFilter(
              field: .occurrence,
              preset: .absolute,
              start: absoluteStart,
              end: absoluteEnd
            ),
            limit: 4
          )),
        .note(AskNoteQuery(queryID: "free-note", limit: 4)),
        .meeting(AskMeetingQuery(queryID: "free-meeting", limit: 4)),
        .codex(AskCodexQuery(queryID: "free-codex", limit: 4)),
      ]

      for query in queries {
        let call = try AskIAgentV2TurnContext.nativeReadToolCall(for: query)
        let object = try XCTUnwrap(
          try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any]
        )
        XCTAssertTrue(object.keys.contains("text"))
        XCTAssertTrue(object["text"] is NSNull)
        XCTAssertTrue(object.keys.contains("cursor"))
        XCTAssertTrue(object["cursor"] is NSNull)
        let time = try XCTUnwrap(object["time"] as? [String: Any])
        XCTAssertTrue(time.keys.contains("start"))
        XCTAssertTrue(time.keys.contains("end"))

        let decoded = try AskReadToolCallDecoder.decode(
          name: call.name,
          argumentsJSON: call.argumentsJSON
        )
        XCTAssertEqual(decoded.query, query)
      }
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func testFreeToolCallErrorsAreTypedInsteadOfErasedToUnknown() throws {
      let tool = AskIAgentFailingTestTool()
      let bridgeError = LanguageModelSession.ToolCallError(
        tool: tool,
        underlyingError: AskIAgentV2ToolBridgeFailure.malformedArguments("query_iagent_data")
      )
      XCTAssertEqual(
        try AskIAgentFoundationGenerator.failure(forToolCallError: bridgeError).reason,
        .malformedResponse
      )

      let cancellation = LanguageModelSession.ToolCallError(
        tool: tool,
        underlyingError: CancellationError()
      )
      XCTAssertThrowsError(
        try AskIAgentFoundationGenerator.failure(forToolCallError: cancellation)
      ) { error in
        XCTAssertTrue(error is CancellationError)
      }
    }

    /// An intentionally live, availability-gated canary. It exercises Apple's real on-device
    /// model and the production compact tool bridge; it does not use injected tool arguments or a
    /// simulated generator. Simulator hosts without Apple Intelligence skip with the exact native
    /// availability classification instead of producing a false-positive contract result.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func testLiveFoundationModelExactTodoCanaryThreeTimesThenCancelsWithoutWriting() async throws {
      let nativeAvailability = AskIAgentFoundationGenerator.currentAvailability(
        localeIdentifier: "en_US"
      )
      guard nativeAvailability == .available else {
        throw XCTSkip("SystemLanguageModel unavailable: \(nativeAvailability)")
      }

      for run in 1...3 {
        let snapshot = IAgentDataSnapshot(
          todoLists: [SyncedTodoList(name: "Inbox", order: 0)]
        )
        let context = try AskIAgentV2TurnContext(
          snapshot: snapshot,
          phoneEvents: [],
          snapshotID: "live-foundation-todo-\(run)",
          contextAsOf: Date(),
          localeIdentifier: "en_US",
          firstWeekday: 2,
          inferenceProfile: .onDevice,
          actionPolicy: .allPreparationEnabled,
          provenance: AssistantActionProvenance(
            conversationID: "live-foundation-conversation-\(run)",
            turnID: "live-foundation-turn-\(run)",
            currentUserMessageID: "live-foundation-message-\(run)",
            toolCallID: "pending-model-tool-call"
          )
        )
        let initialHarnessState = await context.remoteState()
        let request = AskIAgentGenerationRequest(
          modelTier: .free,
          prompt: "create a todo to have lunch with gabby",
          recentConversation: [],
          evidence: [],
          researchContext: nil,
          contextAsOf: Date(),
          localeIdentifier: "en_US",
          v2Context: context
        )
        let output = try await AskIAgentFoundationGenerator().generate(
          request: request,
          progress: { _ in }
        )
        let intent = try XCTUnwrap(output.proposedAction)
        XCTAssertEqual(intent.capability, .createTodo)
        guard case .createTodo(let payload) = intent.payload else {
          return XCTFail("Run \(run) did not produce a to-do review intent.")
        }
        XCTAssertTrue(payload.title.localizedCaseInsensitiveContains("lunch"))
        XCTAssertTrue(payload.title.localizedCaseInsensitiveContains("gabby"))
        XCTAssertNil(payload.dueAt)
        XCTAssertTrue(payload.listName == nil || payload.listName == "Inbox")

        let completedHarnessState = await context.remoteState()
        XCTAssertEqual(completedHarnessState.catalog, initialHarnessState.catalog)
        XCTAssertEqual(completedHarnessState.evidence, initialHarnessState.evidence)
        XCTAssertEqual(completedHarnessState.budgetUsage, initialHarnessState.budgetUsage)
        XCTAssertEqual(completedHarnessState.toolHistory.count, 1)

        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("live-foundation-todo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IAgentLocalSyncStore(
          fileURL: directory.appendingPathComponent("sync-store.json")
        )
        let broker = AssistantActionBroker(
          capabilities: FixedAssistantActionCapabilityProvider(policy: .allPreparationEnabled),
          permissions: FixedAssistantActionPermissionAuthorizer(),
          executor: LocalFirstAssistantActionExecutor(
            store: store,
            sourceDeviceID: "live-foundation-canary"
          ),
          journal: AssistantActionJournal(
            fileURL: directory.appendingPathComponent("journal.json")
          ),
          isAppForeground: { true }
        )
        _ = try await broker.stage(intent)
        try await broker.cancel(intentID: intent.id)
        let stored = await store.snapshot()
        XCTAssertTrue(stored.todos.isEmpty)
        XCTAssertTrue(stored.notes.isEmpty)
        XCTAssertTrue(stored.calendarEvents.isEmpty)
        XCTAssertTrue(stored.codexThreads.isEmpty)
      }
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func testFreeCompactToolsReturnRepairReceiptsInsteadOfTerminatingTheSession() async throws {
      let context = try makeContext(tier: .free, policy: .allPreparationEnabled)
      let readTool = AskIAgentReadGatewayTool(context: context, progress: { _ in })
      let readReceipt = try await readTool.call(
        arguments: AskIAgentReadGatewayArguments(
          queryID: "invalid-read",
          domain: "invalid",
          text: nil,
          time: "any",
          start: nil,
          end: nil,
          state: "any",
          order: "relevance",
          detail: "preview",
          limit: 4
        ))
      XCTAssertTrue(readReceipt.contains(#""status":"tool_error""#))
      XCTAssertTrue(readReceipt.contains(#""repairable":true"#))
      XCTAssertTrue(readReceipt.contains("No records were read"))

      let actionTool = AskIAgentActionGatewayTool(
        description: "Controlled test gateway",
        context: context
      )
      let actionReceipt = try await actionTool.call(
        arguments: AskIAgentActionGatewayArguments(
          kind: "invalid",
          title: "Grab coffee with Gabby",
          body: nil,
          dueAt: nil,
          startAt: nil,
          endAt: nil,
          timeZoneID: nil,
          isAllDay: nil,
          targetID: nil,
          location: nil
        ))
      XCTAssertTrue(actionReceipt.contains("Proposal not prepared"))
      XCTAssertTrue(actionReceipt.contains("Nothing changed"))
      let proposedIntent = await context.actionIntent()
      let hasProposalFailure = await context.hasNativeProposalFailure()
      XCTAssertNil(proposedIntent)
      XCTAssertTrue(hasProposalFailure)
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func testFreeAddedTodoWordingCanCompleteThroughAModelSelectedProposal() async throws {
      let prompt = "Added to do to grab coffee with Gabby."
      let context = try makeContext(tier: .free, policy: .allPreparationEnabled)
      let request = AskIAgentGenerationRequest(
        modelTier: .free,
        prompt: prompt,
        recentConversation: [],
        evidence: [],
        researchContext: nil,
        contextAsOf: now,
        localeIdentifier: "en_US",
        v2Context: context
      )
      XCTAssertEqual(request.prompt, prompt)

      let tool = AskIAgentActionGatewayTool(
        description: "Controlled model-selected proposal",
        context: context
      )
      let receipt = try await tool.call(
        arguments: AskIAgentActionGatewayArguments(
          kind: "todo",
          title: "Grab coffee with Gabby",
          body: nil,
          dueAt: nil,
          startAt: nil,
          endAt: nil,
          timeZoneID: nil,
          isAllDay: nil,
          targetID: nil,
          location: nil
        ))
      XCTAssertTrue(receipt.contains("Proposal prepared for native review"))

      // A structured-output decoding failure after the tool returned must still complete from the
      // authoritative inert native proposal instead of presenting the generic Free-tier error.
      let output = try await AskIAgentFoundationGenerator().recoverV2GenerationFailure(
        AskIAgentFailure(reason: .malformedResponse),
        context: context
      )
      XCTAssertEqual(output.proposedAction?.capability, .createTodo)
      guard case .createTodo(let payload) = output.proposedAction?.payload else {
        return XCTFail("Expected the model-selected to-do proposal.")
      }
      XCTAssertEqual(payload.title, "Grab coffee with Gabby")
      XCTAssertTrue(output.claims.first?.text.contains("Nothing changes unless") == true)
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func testFreeSimpleTodoNormalizesHarmlessCompactUnionResidue() async throws {
      let context = try makeContext(
        tier: .free,
        policy: .allPreparationEnabled,
        snapshot: IAgentDataSnapshot(
          todoLists: [SyncedTodoList(name: "Inbox", order: 0)]
        )
      )
      let tool = AskIAgentActionGatewayTool(
        description: "Controlled model-selected proposal",
        context: context
      )
      let initialState = await context.remoteState()

      let receipt = try await tool.call(
        arguments: AskIAgentActionGatewayArguments(
          kind: "todo",
          title: "Have lunch with Gabby",
          body: nil,
          dueAt: nil,
          startAt: nil,
          endAt: nil,
          // Foundation Models can populate the compact union's shared time-zone field even when
          // it correctly chose no due date. That semantically irrelevant value must not consume
          // all three proposal attempts for this simple request.
          timeZoneID: "Europe/Athens",
          isAllDay: nil,
          // The compact union can also misread the person in the title as its shared target. A
          // person is not an exact known list, so this undated to-do must use the reviewed default.
          targetID: "Gabby",
          location: nil
        ))

      XCTAssertTrue(receipt.contains("Proposal prepared for native review"))
      guard case .createTodo(let payload) = await context.actionIntent()?.payload else {
        return XCTFail("Expected a simple local to-do review card.")
      }
      XCTAssertEqual(payload.title, "Have lunch with Gabby")
      XCTAssertNil(payload.dueAt)
      XCTAssertNil(payload.listName)
      let finalState = await context.remoteState()
      XCTAssertEqual(finalState.catalog, initialState.catalog)
      XCTAssertEqual(finalState.evidence, initialState.evidence)
      XCTAssertEqual(finalState.budgetUsage, initialState.budgetUsage)
      XCTAssertEqual(finalState.toolHistory.count, 1)
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func testFreeCompactTodoStillRejectsMateriallyIncompleteOrUnknownArguments() async throws {
      let missingTimeZoneContext = try makeContext(
        tier: .free,
        policy: .allPreparationEnabled
      )
      let missingTimeZoneTool = AskIAgentActionGatewayTool(
        description: "Controlled model-selected proposal",
        context: missingTimeZoneContext
      )
      let missingTimeZoneReceipt = try await missingTimeZoneTool.call(
        arguments: AskIAgentActionGatewayArguments(
          kind: "todo",
          title: "Have lunch with Gabby",
          body: nil,
          dueAt: "2026-08-14T13:00:00+03:00",
          startAt: nil,
          endAt: nil,
          timeZoneID: nil,
          isAllDay: nil,
          targetID: nil,
          location: nil
        ))
      XCTAssertTrue(missingTimeZoneReceipt.contains("due_at must be an unambiguous"))
      let missingTimeZoneIntent = await missingTimeZoneContext.actionIntent()
      XCTAssertNil(missingTimeZoneIntent)

      let unknownListContext = try makeContext(
        tier: .free,
        policy: .allPreparationEnabled,
        snapshot: IAgentDataSnapshot(
          todoLists: [SyncedTodoList(name: "Inbox", order: 0)]
        )
      )
      let unknownListTool = AskIAgentActionGatewayTool(
        description: "Controlled model-selected proposal",
        context: unknownListContext
      )
      let unknownListReceipt = try await unknownListTool.call(
        arguments: AskIAgentActionGatewayArguments(
          kind: "todo",
          title: "Have lunch with Gabby",
          body: nil,
          dueAt: "2026-08-14T13:00:00+03:00",
          startAt: nil,
          endAt: nil,
          timeZoneID: "Europe/Athens",
          isAllDay: nil,
          targetID: "Gabby",
          location: nil
        ))
      XCTAssertTrue(unknownListReceipt.contains("to-do list \"Gabby\" is unavailable"))
      let unknownListIntent = await unknownListContext.actionIntent()
      XCTAssertNil(unknownListIntent)

      let knownListContext = try makeContext(
        tier: .free,
        policy: .allPreparationEnabled,
        snapshot: IAgentDataSnapshot(
          todoLists: [SyncedTodoList(name: "Inbox", order: 0)]
        )
      )
      let knownListTool = AskIAgentActionGatewayTool(
        description: "Controlled model-selected proposal",
        context: knownListContext
      )
      let knownListReceipt = try await knownListTool.call(
        arguments: AskIAgentActionGatewayArguments(
          kind: "todo",
          title: "Have lunch with Gabby",
          body: nil,
          dueAt: nil,
          startAt: nil,
          endAt: nil,
          timeZoneID: "Europe/Athens",
          isAllDay: nil,
          targetID: "inBOX",
          location: nil
        ))
      XCTAssertTrue(knownListReceipt.contains("Proposal prepared for native review"))
      guard case .createTodo(let knownListPayload) = await knownListContext.actionIntent()?.payload
      else {
        return XCTFail("Expected the exact known list to remain on the review card.")
      }
      XCTAssertEqual(knownListPayload.listName, "Inbox")
    }
  #endif

  func testEveryTierExposesTheSamePolicyEnabledProposalTools() async throws {
    let expectedDefinitions = AssistantProposalToolCatalog.definitions(
      allowedBy: .allPreparationEnabled
    )
    let expectedNames = expectedDefinitions.map(\.name)

    XCTAssertEqual(expectedNames.count, AssistantActionCapability.allCases.count)

    for tier in AskIAgentModelTier.allCases {
      let context = try makeContext(tier: tier, policy: .allPreparationEnabled)
      let state = await context.remoteState()
      let proposalNames = state.enabledTools.filter {
        AssistantProposalToolCatalog.capability(forToolNamed: $0) != nil
      }

      XCTAssertEqual(
        state.actionToolDefinitions,
        expectedDefinitions,
        "\(tier.displayName) must receive the same policy-owned proposal schemas."
      )
      XCTAssertEqual(
        proposalNames,
        expectedNames,
        "The selected model—not a native lexical parser—must choose among every enabled action."
      )
    }
  }

  func testModelSelectedNoteCallProducesReviewIntentWithoutWritingForEveryTier() async throws {
    let arguments = try JSONSerialization.data(
      withJSONObject: [
        "title": "Bitcoin bull case",
        "body": "## Bull case\n\n- Scarce supply\n- Broader adoption",
      ],
      options: [.sortedKeys]
    )

    for tier in AskIAgentModelTier.allCases {
      let context = try makeContext(tier: tier, policy: .allPreparationEnabled)
      let initialState = await context.remoteState()
      let initialIntent = await context.actionIntent()
      XCTAssertNil(initialIntent)

      let callID = "model-note-\(tier.rawValue)"
      let result = try await context.executeToolCall(
        callID: callID,
        name: AssistantProposalToolCatalog.createNoteName,
        argumentsJSON: arguments,
        progress: { _ in }
      )

      let preparedIntent = await context.actionIntent()
      let intent = try XCTUnwrap(preparedIntent)
      XCTAssertEqual(intent.capability, .createNote)
      guard case .createNote(let payload) = intent.payload else {
        return XCTFail("Expected a create-note review intent for \(tier.displayName).")
      }
      XCTAssertEqual(payload.title, "Bitcoin bull case")
      XCTAssertEqual(payload.body, "## Bull case\n\n- Scarce supply\n- Broader adoption")
      XCTAssertEqual(intent.provenance.toolCallID, callID)
      XCTAssertEqual(result.callID, callID)
      XCTAssertEqual(result.name, AssistantProposalToolCatalog.createNoteName)
      XCTAssertTrue(result.output.contains("nothing was changed"))
      try await assertProposalOnlyState(
        context,
        initialState: initialState,
        expectedToolCall: result,
        tier: tier
      )
    }
  }

  func testModelSelectedTodoCallProducesReviewIntentWithoutWritingForEveryTier() async throws {
    let arguments = Data(
      #"{"title":"Meet Gabby in SF","due_at":null,"time_zone_id":null,"list_name":null}"#.utf8
    )

    for tier in AskIAgentModelTier.allCases {
      let context = try makeContext(tier: tier, policy: .allPreparationEnabled)
      let initialState = await context.remoteState()
      let initialIntent = await context.actionIntent()
      XCTAssertNil(initialIntent)

      let callID = "model-todo-\(tier.rawValue)"
      let result = try await context.executeToolCall(
        callID: callID,
        name: AssistantProposalToolCatalog.createTodoName,
        argumentsJSON: arguments,
        progress: { _ in }
      )

      let preparedIntent = await context.actionIntent()
      let intent = try XCTUnwrap(preparedIntent)
      XCTAssertEqual(intent.capability, .createTodo)
      guard case .createTodo(let payload) = intent.payload else {
        return XCTFail("Expected a create-todo review intent for \(tier.displayName).")
      }
      XCTAssertEqual(payload.title, "Meet Gabby in SF")
      XCTAssertNil(payload.dueAt)
      XCTAssertNil(payload.listName)
      XCTAssertEqual(intent.provenance.toolCallID, callID)
      XCTAssertEqual(result.callID, callID)
      XCTAssertEqual(result.name, AssistantProposalToolCatalog.createTodoName)
      XCTAssertTrue(result.output.contains("nothing was changed"))
      try await assertProposalOnlyState(
        context,
        initialState: initialState,
        expectedToolCall: result,
        tier: tier
      )
    }
  }

  func testDisabledModelSelectedToolRejectsWithoutHidingOtherEnabledTools() async throws {
    var policy = AssistantActionCapabilityPolicy.allPreparationEnabled
    policy.setPreparationEnabled(false, for: .createNote)
    let expectedNames = AssistantProposalToolCatalog.definitions(allowedBy: policy).map(\.name)

    for tier in AskIAgentModelTier.allCases {
      let context = try makeContext(tier: tier, policy: policy)
      let initialState = await context.remoteState()
      let proposalNames = initialState.enabledTools.filter {
        AssistantProposalToolCatalog.capability(forToolNamed: $0) != nil
      }
      XCTAssertEqual(proposalNames, expectedNames)
      XCTAssertFalse(proposalNames.contains(AssistantProposalToolCatalog.createNoteName))
      XCTAssertTrue(proposalNames.contains(AssistantProposalToolCatalog.createTodoName))

      do {
        _ = try await context.executeToolCall(
          callID: "disabled-note-\(tier.rawValue)",
          name: AssistantProposalToolCatalog.createNoteName,
          argumentsJSON: Data(#"{"title":"Disabled","body":"Do not prepare"}"#.utf8),
          progress: { _ in }
        )
        XCTFail("\(tier.displayName) must reject a model call to a policy-disabled tool.")
      } catch {
        XCTAssertEqual(
          error as? AskIAgentV2ToolBridgeFailure,
          .unknownOrDisabledTool(AssistantProposalToolCatalog.createNoteName)
        )
      }

      let rejectedIntent = await context.actionIntent()
      XCTAssertNil(rejectedIntent)
      let completedState = await context.remoteState()
      XCTAssertEqual(completedState.catalog, initialState.catalog)
      XCTAssertTrue(completedState.evidence.isEmpty)
      XCTAssertTrue(completedState.toolHistory.isEmpty)
    }
  }

  func testFreeCompactGatewayTurnsADisabledKindIntoATruthfulNoOp() async throws {
    var policy = AssistantActionCapabilityPolicy.allPreparationEnabled
    policy.setPreparationEnabled(false, for: .createNote)
    let context = try makeContext(tier: .free, policy: policy)
    let initialState = await context.remoteState()

    let disabledReceipt = try await context.executeCompactActionProposal(
      toolName: AssistantProposalToolCatalog.createNoteName,
      argumentsJSON: Data(#"{"title":"Private memo","body":"Draft"}"#.utf8)
    )

    XCTAssertTrue(disabledReceipt.contains("Create notes is disabled in Settings"))
    XCTAssertTrue(disabledReceipt.contains("Nothing changed"))
    XCTAssertTrue(disabledReceipt.contains("Do not substitute a different action kind"))
    let disabledIntent = await context.actionIntent()
    let hasFailure = await context.hasNativeProposalFailure()
    XCTAssertNil(disabledIntent)
    XCTAssertTrue(hasFailure)
    let afterDisabled = await context.remoteState()
    XCTAssertEqual(afterDisabled.catalog, initialState.catalog)
    XCTAssertEqual(afterDisabled.evidence, initialState.evidence)
    XCTAssertEqual(afterDisabled.toolHistory, initialState.toolHistory)
    let disabledDescription = await context.noMatchDescription()
    XCTAssertTrue(disabledDescription.contains("Create notes is disabled in Settings"))

    let enabledReceipt = try await context.executeCompactActionProposal(
      toolName: AssistantProposalToolCatalog.createTodoName,
      argumentsJSON: Data(
        #"{"title":"Review the memo","due_at":null,"time_zone_id":null,"list_name":null}"#.utf8
      )
    )
    XCTAssertTrue(enabledReceipt.contains("Proposal prepared for native review"))
    let enabledIntent = await context.actionIntent()
    XCTAssertEqual(enabledIntent?.capability, .createTodo)
  }

  func testFreeCompactGatewayRemainsAvailableAndNoOpsWhenEveryCapabilityIsDisabled()
    async throws
  {
    let context = try makeContext(tier: .free, policy: .allDisabled)
    let initialState = await context.remoteState()
    let calls: [(String, Data, String)] = [
      (
        AssistantProposalToolCatalog.createTodoName,
        Data(#"{"title":"Todo","due_at":null,"time_zone_id":null,"list_name":null}"#.utf8),
        "Create todos"
      ),
      (
        AssistantProposalToolCatalog.createNoteName,
        Data(#"{"title":"Note","body":"Draft"}"#.utf8),
        "Create notes"
      ),
      (
        AssistantProposalToolCatalog.draftCalendarEventName,
        Data(
          #"{"title":"Event","start_at":"2026-08-12T10:00:00+03:00","end_at":"2026-08-12T11:00:00+03:00","time_zone_id":"Europe/Athens","is_all_day":false,"calendar_id":null,"location":null,"notes":null}"#.utf8
        ),
        "Draft calendar events"
      ),
    ]

    for (name, arguments, settingsTitle) in calls {
      let receipt = try await context.executeCompactActionProposal(
        toolName: name,
        argumentsJSON: arguments
      )
      XCTAssertTrue(receipt.contains("\(settingsTitle) is disabled in Settings"))
      XCTAssertTrue(receipt.contains("Nothing changed"))
    }
    let disabledIntent = await context.actionIntent()
    XCTAssertNil(disabledIntent)
    let finalState = await context.remoteState()
    XCTAssertEqual(finalState.catalog, initialState.catalog)
    XCTAssertEqual(finalState.evidence, initialState.evidence)
    XCTAssertEqual(finalState.toolHistory, initialState.toolHistory)

    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("iAgentMobile/Model/AskIAgentV2Harness.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    XCTAssertTrue(source.contains("Enabled action kinds: \\(enabledKinds.isEmpty ? \"none\" : enabledKinds)"))
    XCTAssertFalse(source.contains("if !actionToolDefinitions.isEmpty"))
  }

  func testFreeCompactDisabledProposalReceiptsCannotBypassTheTotalToolAttemptBudget()
    async throws
  {
    let context = try makeContext(tier: .free, policy: .allDisabled)
    let arguments = Data(
      #"{"title":"No-op","due_at":null,"time_zone_id":null,"list_name":null}"#.utf8
    )

    for index in 1...8 {
      let receipt = try await context.executeCompactActionProposal(
        toolName: AssistantProposalToolCatalog.createTodoName,
        argumentsJSON: arguments
      )
      if index <= 3 {
        XCTAssertTrue(receipt.contains("Create todos is disabled in Settings"))
      } else {
        XCTAssertTrue(receipt.contains("proposal retry budget is exhausted"))
      }
      XCTAssertFalse(receipt.contains(#""code":"budgetExceeded""#))
    }

    let ninth = try await context.executeCompactActionProposal(
      toolName: AssistantProposalToolCatalog.createTodoName,
      argumentsJSON: arguments
    )
    XCTAssertTrue(ninth.contains(#""code":"budgetExceeded""#))
    XCTAssertTrue(ninth.contains("tool_call_budget_exhausted_do_not_retry"))
    XCTAssertLessThanOrEqual(ninth.utf16.count, 600)

    let state = await context.remoteState()
    XCTAssertTrue(state.toolHistory.isEmpty)
    XCTAssertEqual(state.budgetUsage.calls, 0)
    XCTAssertTrue(state.evidence.isEmpty)
  }

  func testRepairableProposalArgumentsReturnAToolReceiptAndCanBeCorrected() async throws {
    let context = try makeContext(
      tier: .fast,
      policy: .allPreparationEnabled,
      snapshot: IAgentDataSnapshot(
        todoLists: [SyncedTodoList(name: "Inbox", order: 0)]
      )
    )
    let invalidArguments = Data(
      #"{"title":"Review the memo","due_at":null,"time_zone_id":null,"list_name":"Missing list"}"#.utf8
    )

    let rejected = try await context.executeToolCall(
      callID: "todo-invalid-target",
      name: AssistantProposalToolCatalog.createTodoName,
      argumentsJSON: invalidArguments,
      progress: { _ in }
    )

    XCTAssertTrue(rejected.output.contains("Proposal not prepared"))
    XCTAssertTrue(rejected.output.contains("Revise the arguments"))
    let rejectedIntent = await context.actionIntent()
    XCTAssertNil(rejectedIntent)

    let correctedArguments = Data(
      #"{"title":"Review the memo","due_at":null,"time_zone_id":null,"list_name":null}"#.utf8
    )
    let corrected = try await context.executeToolCall(
      callID: "todo-corrected-target",
      name: AssistantProposalToolCatalog.createTodoName,
      argumentsJSON: correctedArguments,
      progress: { _ in }
    )

    XCTAssertTrue(corrected.output.contains("nothing was changed"))
    let correctedIntent = await context.actionIntent()
    XCTAssertEqual(correctedIntent?.capability, .createTodo)
    let state = await context.remoteState()
    XCTAssertEqual(state.toolHistory, [rejected, corrected])
  }

  func testRemoteModelCanRepairInvalidProposalArgumentsOnTheNextBoundedRound() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-proposal-repair-\(UUID().uuidString)")
    )
    func toolResponse(callID: String, listName: String?) throws -> Data {
      let arguments = try JSONSerialization.data(
        withJSONObject: [
          "title": "Review the memo",
          "due_at": NSNull(),
          "time_zone_id": NSNull(),
          "list_name": listName.map { $0 as Any } ?? NSNull(),
        ],
        options: [.sortedKeys]
      )
      return try JSONSerialization.data(
        withJSONObject: [
          "protocolVersion": 2,
          "kind": "tool_calls",
          "calls": [
            [
              "callID": callID,
              "name": AssistantProposalToolCatalog.createTodoName,
              "arguments": String(decoding: arguments, as: UTF8.self),
            ]
          ],
        ],
        options: [.sortedKeys]
      )
    }
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(statusCode: 200, body: try toolResponse(callID: "invalid-target", listName: "Missing")),
        .init(statusCode: 200, body: try toolResponse(callID: "corrected-target", listName: nil)),
        .init(
          statusCode: 200,
          body: try remoteActionAnswerResponse(
            message: "I prepared the memo review task for you to check."
          )
        ),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(
      tier: .fast,
      policy: .allPreparationEnabled,
      snapshot: IAgentDataSnapshot(todoLists: [SyncedTodoList(name: "Inbox", order: 0)])
    )
    let initialState = await context.remoteState()
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "proposal-repair-tests"
    )

    let output = try await generator.generate(
      request: remoteGenerationRequest(tier: .fast, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 3)
    let repairRequest = try requestJSONObject(plan.requests[1])
    let toolHistory = try XCTUnwrap(repairRequest["toolHistory"] as? [[String: Any]])
    XCTAssertEqual(toolHistory.count, 1)
    XCTAssertEqual(toolHistory[0]["callID"] as? String, "invalid-target")
    XCTAssertTrue(
      (toolHistory[0]["output"] as? String)?.contains("Proposal not prepared") == true
    )
    let intent = try XCTUnwrap(output.proposedAction)
    XCTAssertEqual(intent.capability, .createTodo)
    XCTAssertEqual(intent.provenance.toolCallID, "corrected-target")
    XCTAssertTrue(output.claims.first?.text.contains("prepared the memo review task") == true)
    XCTAssertTrue(output.claims.first?.text.contains("Nothing changes unless") == true)
    let finalState = await context.remoteState()
    XCTAssertEqual(finalState.catalog, initialState.catalog)
    XCTAssertEqual(finalState.toolHistory.map(\.callID), ["invalid-target", "corrected-target"])
  }

  func testFastV2CanRepairANativeTemporalFieldFailureOnTheNextRound() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-read-repair-\(UUID().uuidString)")
    )
    let invalid = try remoteNoteReadToolCallResponse(
      callID: "invalid-note-time",
      queryID: "invalid-note-time-query",
      temporalField: "occurrence",
      limit: 1
    )
    let corrected = try remoteNoteReadToolCallResponse(
      callID: "corrected-note-time",
      queryID: "corrected-note-time-query",
      temporalField: "updated",
      limit: 1
    )
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(statusCode: 200, body: invalid),
        .init(statusCode: 200, body: corrected),
        .init(
          statusCode: 200,
          body: try JSONSerialization.data(
            withJSONObject: ["protocolVersion": 2, "kind": "answer", "claims": []],
            options: [.sortedKeys]
          )
        ),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "read-repair-tests"
    )

    _ = try await generator.generate(
      request: remoteGenerationRequest(tier: .fast, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 3)
    let secondRequest = try requestJSONObject(plan.requests[1])
    let repairHistory = try XCTUnwrap(secondRequest["toolHistory"] as? [[String: Any]])
    XCTAssertEqual(repairHistory.count, 1)
    XCTAssertTrue((repairHistory[0]["output"] as? String)?.contains("tool_error") == true)
    XCTAssertTrue(
      (repairHistory[0]["output"] as? String)?.contains("unsupportedTemporalField") == true
    )
    let state = await context.remoteState()
    XCTAssertEqual(state.toolHistory.map(\.callID), ["invalid-note-time", "corrected-note-time"])
    XCTAssertTrue(state.toolHistory[0].output.contains(#""records_read":0"#))
    XCTAssertTrue(state.toolHistory[0].evidenceIDs.isEmpty)
    XCTAssertTrue(state.toolHistory[1].output.contains("query_id=corrected-note-time-query"))
  }

  func testRemoteProfilesAcceptTheCanonicalLimitOfTenForFastAndPro() async throws {
    let notes = (0..<12).map { index in
      SyncedNote(
        title: "Note \(index)",
        body: "Evidence \(index)",
        createdAt: now.addingTimeInterval(TimeInterval(-index)),
        updatedAt: now.addingTimeInterval(TimeInterval(-index)),
        sourceDeviceID: "limit-ten-tests"
      )
    }
    let snapshot = IAgentDataSnapshot(notes: notes)

    for tier in [AskIAgentModelTier.fast, .pro] {
      let context = try makeContext(
        tier: tier,
        policy: .allPreparationEnabled,
        snapshot: snapshot
      )
      let arguments = try remoteNoteReadArguments(
        queryID: "limit-ten-\(tier.rawValue)",
        temporalField: "updated",
        limit: 10
      )
      let result = try await context.executeToolCall(
        callID: "limit-ten-\(tier.rawValue)",
        name: AskReadToolSchemas.note.name,
        argumentsJSON: arguments,
        progress: { _ in }
      )
      let state = await context.remoteState()

      XCTAssertEqual(state.budgetLimit.maximumRecordsPerPage, 10)
      XCTAssertFalse(result.output.contains("tool_error"))
      XCTAssertEqual(result.evidenceIDs.count, 10)
      XCTAssertEqual(state.evidence.count, 10)
    }
  }

  func testFreeReadFailureBecomesATypedRepairReceiptWithoutReadingData() async throws {
    let context = try AskIAgentV2TurnContext(
      snapshot: IAgentDataSnapshot(),
      phoneEvents: [],
      snapshotID: "free-read-repair",
      contextAsOf: now,
      localeIdentifier: "en_US",
      firstWeekday: 2,
      inferenceProfile: .onDevice,
      actionPolicy: .allPreparationEnabled,
      provenance: AssistantActionProvenance(
        conversationID: "conversation-free-repair",
        turnID: "turn-free-repair",
        currentUserMessageID: "message-free-repair",
        toolCallID: "pending-model-tool-call"
      )
    )
    let result = try await context.executeToolCall(
      callID: "free-invalid-note-time",
      name: AskReadToolSchemas.note.name,
      argumentsJSON: try remoteNoteReadArguments(
        queryID: "free-invalid-note-time-query",
        temporalField: "occurrence",
        limit: 1
      ),
      progress: { _ in }
    )

    XCTAssertTrue(result.output.contains(#""status":"tool_error""#))
    XCTAssertTrue(result.output.contains(#""code":"unsupportedTemporalField""#))
    XCTAssertTrue(result.output.contains(#""field":"time.field""#))
    XCTAssertTrue(result.output.contains("No records were read"))
    XCTAssertTrue(result.evidenceIDs.isEmpty)
    let state = await context.remoteState()
    XCTAssertTrue(state.evidence.isEmpty)
    XCTAssertEqual(state.toolHistory, [result])
  }

  func testFreeTotalToolAttemptBudgetStopsTheNinthFreshCallBeforeTheExecutor() async throws {
    let context = try AskIAgentV2TurnContext(
      snapshot: IAgentDataSnapshot(
        notes: [
          SyncedNote(
            title: "Budget sentinel",
            body: "The ninth call must never read this record.",
            createdAt: now,
            updatedAt: now,
            sourceDeviceID: "free-total-tool-budget-tests"
          )
        ]
      ),
      phoneEvents: [],
      snapshotID: "free-total-tool-budget",
      contextAsOf: now,
      localeIdentifier: "en_US",
      firstWeekday: 2,
      inferenceProfile: .onDevice,
      actionPolicy: .allPreparationEnabled,
      provenance: AssistantActionProvenance(
        conversationID: "conversation-free-total-tool-budget",
        turnID: "turn-free-total-tool-budget",
        currentUserMessageID: "message-free-total-tool-budget",
        toolCallID: "pending-model-tool-call"
      )
    )

    let successful = try await context.executeToolCall(
      callID: "free-successful-read",
      name: AskReadToolSchemas.note.name,
      argumentsJSON: try remoteNoteReadArguments(
        queryID: "free-successful-read-query",
        temporalField: "updated",
        limit: 1
      ),
      progress: { _ in }
    )
    XCTAssertFalse(successful.output.contains(#""status":"tool_error""#))
    XCTAssertFalse(successful.evidenceIDs.isEmpty)

    for index in 1...7 {
      let result = try await context.executeToolCall(
        callID: "free-invalid-read-\(index)",
        name: AskReadToolSchemas.note.name,
        argumentsJSON: try remoteNoteReadArguments(
          queryID: "free-invalid-read-query-\(index)",
          temporalField: "occurrence",
          limit: 1
        ),
        progress: { _ in }
      )
      XCTAssertTrue(result.output.contains(#""status":"tool_error""#))
    }

    let validArguments = try remoteNoteReadArguments(
      queryID: "free-ninth-valid-read-query",
      temporalField: "updated",
      limit: 1
    )
    let ninth = try await context.executeToolCall(
      callID: "free-ninth-valid-read",
      name: AskReadToolSchemas.note.name,
      argumentsJSON: validArguments,
      progress: { _ in }
    )
    let replay = try await context.executeToolCall(
      callID: "free-ninth-valid-read",
      name: AskReadToolSchemas.note.name,
      argumentsJSON: validArguments,
      progress: { _ in }
    )

    XCTAssertEqual(replay, ninth)
    XCTAssertTrue(ninth.output.contains(#""code":"budgetExceeded""#))
    XCTAssertTrue(
      ninth.output.contains(#""repairable":false"#),
      "Unexpected terminal tool-budget receipt: \(ninth.output)"
    )
    XCTAssertTrue(ninth.output.contains("tool_call_budget_exhausted_do_not_retry"))
    XCTAssertTrue(ninth.output.contains("Do not call another read or proposal tool"))
    XCTAssertLessThanOrEqual(ninth.output.utf16.count, 600)
    XCTAssertTrue(ninth.evidenceIDs.isEmpty)

    let state = await context.remoteState()
    XCTAssertEqual(state.toolHistory.count, 8)
    XCTAssertEqual(state.budgetUsage.calls, 1)
    XCTAssertEqual(state.evidence.count, successful.evidenceIDs.count)
  }

  func testInvalidTimestampReadReceiptReplaysExactlyAndPayloadDriftFailsClosed() async throws {
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let invalid = try remoteNoteReadArguments(
      queryID: "invalid-timestamp-query",
      temporalField: "updated",
      limit: 1,
      preset: "absolute",
      start: "not-rfc3339",
      end: "2026-08-12T10:00:00Z"
    )
    let first = try await context.executeToolCall(
      callID: "invalid-timestamp-call",
      name: AskReadToolSchemas.note.name,
      argumentsJSON: invalid,
      progress: { _ in }
    )
    let replay = try await context.executeToolCall(
      callID: "invalid-timestamp-call",
      name: AskReadToolSchemas.note.name,
      argumentsJSON: invalid,
      progress: { _ in }
    )

    XCTAssertEqual(replay, first)
    XCTAssertTrue(first.output.contains(#""code":"invalidArgument""#))
    XCTAssertTrue(first.output.contains("No records were read"))
    XCTAssertTrue(first.evidenceIDs.isEmpty)
    let state = await context.remoteState()
    XCTAssertEqual(state.toolHistory, [first])

    let changed = try remoteNoteReadArguments(
      queryID: "invalid-timestamp-query",
      temporalField: "updated",
      limit: 2,
      preset: "absolute",
      start: "not-rfc3339",
      end: "2026-08-12T10:00:00Z"
    )
    do {
      _ = try await context.executeToolCall(
        callID: "invalid-timestamp-call",
        name: AskReadToolSchemas.note.name,
        argumentsJSON: changed,
        progress: { _ in }
      )
      XCTFail("Changing a completed decoder-failure payload must fail closed.")
    } catch let failure as AskIAgentV2ToolBridgeFailure {
      XCTAssertEqual(failure, .callIDPayloadMismatch("invalid-timestamp-call"))
    }
  }

  func testFastCanCorrectAnInvalidTimestampWithNewCallAndQueryIDs() async throws {
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let rejected = try await context.executeToolCall(
      callID: "bad-time-call",
      name: AskReadToolSchemas.note.name,
      argumentsJSON: try remoteNoteReadArguments(
        queryID: "bad-time-query",
        temporalField: "updated",
        limit: 1,
        preset: "absolute",
        start: "bad-time",
        end: "2026-08-12T10:00:00Z"
      ),
      progress: { _ in }
    )
    let corrected = try await context.executeToolCall(
      callID: "corrected-time-call",
      name: AskReadToolSchemas.note.name,
      argumentsJSON: try remoteNoteReadArguments(
        queryID: "corrected-time-query",
        temporalField: "updated",
        limit: 1,
        preset: "absolute",
        start: "2026-08-11T10:00:00Z",
        end: "2026-08-12T10:00:00Z"
      ),
      progress: { _ in }
    )

    XCTAssertTrue(rejected.output.contains("invalidArgument"))
    XCTAssertFalse(corrected.output.contains("tool_error"))
    XCTAssertTrue(corrected.output.contains("query_id=corrected-time-query"))
    let state = await context.remoteState()
    XCTAssertEqual(state.toolHistory.map(\.callID), ["bad-time-call", "corrected-time-call"])
  }

  func testProposalRetryBudgetMakesTheThirdFailureTerminal() async throws {
    let context = try makeContext(
      tier: .free,
      policy: .allPreparationEnabled,
      snapshot: IAgentDataSnapshot(
        todoLists: [SyncedTodoList(name: "Inbox", order: 0)]
      )
    )
    let invalidArguments = Data(
      #"{"title":"Review the memo","due_at":null,"time_zone_id":null,"list_name":"Missing list"}"#.utf8
    )

    for attempt in 1...2 {
      let result = try await context.executeToolCall(
        callID: "todo-invalid-\(attempt)",
        name: AssistantProposalToolCatalog.createTodoName,
        argumentsJSON: invalidArguments,
        progress: { _ in }
      )
      XCTAssertTrue(result.output.contains("Revise the arguments"))
    }

    let third = try await context.executeToolCall(
      callID: "todo-invalid-3",
      name: AssistantProposalToolCatalog.createTodoName,
      argumentsJSON: invalidArguments,
      progress: { _ in }
    )
    XCTAssertTrue(third.output.contains("retry budget is exhausted"))
    XCTAssertTrue(third.output.contains("Do not call another proposal tool"))
    XCTAssertFalse(third.output.contains("Revise the arguments"))

    let defensiveFourth = try await context.executeToolCall(
      callID: "todo-invalid-4",
      name: AssistantProposalToolCatalog.createTodoName,
      argumentsJSON: invalidArguments,
      progress: { _ in }
    )
    XCTAssertTrue(defensiveFourth.output.contains("retry budget is exhausted"))
    XCTAssertTrue(defensiveFourth.output.contains("Nothing changed"))
    let intent = await context.actionIntent()
    XCTAssertNil(intent)
  }

  func testRemoteThirdInvalidProposalEndsTruthfullyWithoutACardOrWrite() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-proposal-terminal-\(UUID().uuidString)")
    )
    func invalidTodoResponse(callID: String) throws -> Data {
      let arguments = Data(
        #"{"title":"Review the memo","due_at":null,"time_zone_id":null,"list_name":"Missing list"}"#.utf8
      )
      return try JSONSerialization.data(
        withJSONObject: [
          "protocolVersion": 2,
          "kind": "tool_calls",
          "calls": [
            [
              "callID": callID,
              "name": AssistantProposalToolCatalog.createTodoName,
              "arguments": String(decoding: arguments, as: UTF8.self),
            ]
          ],
        ],
        options: [.sortedKeys]
      )
    }
    let finalAnswer = try JSONSerialization.data(
      withJSONObject: ["protocolVersion": 2, "kind": "answer", "claims": []],
      options: [.sortedKeys]
    )
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(statusCode: 200, body: try invalidTodoResponse(callID: "invalid-proposal-1")),
        .init(statusCode: 200, body: try invalidTodoResponse(callID: "invalid-proposal-2")),
        .init(statusCode: 200, body: try invalidTodoResponse(callID: "invalid-proposal-3")),
        .init(statusCode: 200, body: finalAnswer),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(
      tier: .fast,
      policy: .allPreparationEnabled,
      snapshot: IAgentDataSnapshot(todoLists: [SyncedTodoList(name: "Inbox", order: 0)])
    )
    let initialState = await context.remoteState()
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "proposal-terminal-tests"
    )

    let output = try await generator.generate(
      request: remoteGenerationRequest(tier: .fast, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 4)
    XCTAssertNil(output.proposedAction)
    XCTAssertTrue(
      output.claims.first?.text.contains("could not produce a valid review card") == true
    )
    XCTAssertTrue(output.claims.first?.text.contains("Nothing was changed") == true)
    let state = await context.remoteState()
    XCTAssertEqual(state.catalog, initialState.catalog)
    XCTAssertTrue(state.evidence.isEmpty)
    XCTAssertEqual(
      state.toolHistory.map(\.callID),
      ["invalid-proposal-1", "invalid-proposal-2", "invalid-proposal-3"]
    )
    XCTAssertTrue(state.toolHistory[2].output.contains("retry budget is exhausted"))
    let intent = await context.actionIntent()
    XCTAssertNil(intent)
  }

  func testInitialV2MalformedUpstreamRetriesOnceThenStagesModelSelectedNoteWithoutWriting()
    async throws
  {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-initial-retry-success-\(UUID().uuidString)")
    )
    let toolResponse = try remoteNoteToolCallResponse(
      callID: "remote-note-after-retry",
      title: "Bitcoin bull case",
      body: "## Bull case\n\n- Scarce supply\n- Broader adoption"
    )
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(
          statusCode: 502,
          body: Data(#"{"error":"invalid_upstream_output"}"#.utf8)
        ),
        .init(statusCode: 200, body: toolResponse),
        .init(
          statusCode: 200,
          body: try remoteActionAnswerResponse(
            message: "I prepared a Bitcoin bull-case note for native review."
          )
        ),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }

    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let initialState = await context.remoteState()
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "v2-retry-tests"
    )

    let output = try await generator.generate(
      request: remoteGenerationRequest(tier: .fast, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 3)
    XCTAssertTrue(
      plan.requests.allSatisfy {
        $0.value(forHTTPHeaderField: "X-iAgent-Relay-Protocol") == "2"
      }
    )
    try assertActionSchemaIdentity(in: plan.requests)

    let outputIntent = try XCTUnwrap(output.proposedAction)
    let stagedIntent = await context.actionIntent()
    let contextIntent = try XCTUnwrap(stagedIntent)
    XCTAssertEqual(outputIntent, contextIntent)
    XCTAssertEqual(outputIntent.capability, .createNote)
    XCTAssertEqual(outputIntent.provenance.toolCallID, "remote-note-after-retry")
    guard case .createNote(let payload) = outputIntent.payload else {
      return XCTFail("Expected the model-selected call to stage one native note review intent.")
    }
    XCTAssertEqual(payload.title, "Bitcoin bull case")
    XCTAssertEqual(payload.body, "## Bull case\n\n- Scarce supply\n- Broader adoption")
    XCTAssertTrue(
      output.claims.first?.text.contains("prepared a Bitcoin bull-case note") == true,
      "The model-written action response must survive native validation."
    )
    XCTAssertTrue(
      output.claims.first?.text.contains("Nothing changes unless you tap") == true,
      "The client must always append its authoritative non-commit guard."
    )

    let completedState = await context.remoteState()
    XCTAssertEqual(
      completedState.catalog,
      initialState.catalog,
      "A remote tool call may stage a review intent but must not write before confirmation."
    )
    XCTAssertTrue(completedState.evidence.isEmpty)
    XCTAssertEqual(completedState.toolHistory.count, 1)
    XCTAssertEqual(completedState.toolHistory.first?.name, AssistantProposalToolCatalog.createNoteName)
  }

  func testInitialV2MalformedUpstreamStopsAfterSecondFailureWithoutIntentOrWrite() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-initial-retry-exhausted-\(UUID().uuidString)")
    )
    let invalidUpstreamOutput = Data(#"{"error":"invalid_upstream_output"}"#.utf8)
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(statusCode: 502, body: invalidUpstreamOutput),
        .init(statusCode: 502, body: invalidUpstreamOutput),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }

    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .pro, policy: .allPreparationEnabled)
    let initialState = await context.remoteState()
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "v2-retry-tests"
    )

    do {
      _ = try await generator.generate(
        request: remoteGenerationRequest(tier: .pro, context: context),
        progress: { _ in }
      )
      XCTFail("A second invalid-upstream response must end the bounded initial retry.")
    } catch let failure as AskIAgentFailure {
      XCTAssertEqual(failure.reason, .malformedResponse)
    } catch {
      XCTFail("Expected AskIAgentFailure, got \(error).")
    }

    XCTAssertEqual(plan.requests.count, 2)
    try assertActionSchemaIdentity(in: plan.requests)
    let intent = await context.actionIntent()
    XCTAssertNil(intent)
    let completedState = await context.remoteState()
    XCTAssertEqual(completedState.catalog, initialState.catalog)
    XCTAssertTrue(completedState.evidence.isEmpty)
    XCTAssertTrue(completedState.toolHistory.isEmpty)
  }

  func testProV2ReplaysValidatedOpaqueContinuationOnTheNextRoundOnly() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-pro-continuation-\(UUID().uuidString)")
    )
    let continuation: [String: Any] = [
      "round": 0,
      "callIDs": ["read-note-1"],
      "reasoningID": "rs_reasoning_1",
      "encryptedContent": "opaque_payload-123==",
    ]
    let toolResponse = try JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 2,
        "kind": "tool_calls",
        "calls": [
          [
            "callID": "read-note-1",
            "name": "query_notes",
            "arguments":
              #"{"query_id":"pro-note","text":"bitcoin","record_ids":[],"time":{"field":"updated","preset":"any","start":null,"end":null},"sort":"relevanceDesc","content":"preview","limit":1,"cursor":null}"#,
          ]
        ],
        "modelContinuation": [continuation],
      ],
      options: [.sortedKeys]
    )
    let answerResponse = try JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 2,
        "kind": "answer",
        "claims": [],
      ],
      options: [.sortedKeys]
    )
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(statusCode: 200, body: toolResponse),
        .init(statusCode: 200, body: answerResponse),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .pro, policy: .allPreparationEnabled)
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "pro-continuation-tests"
    )

    _ = try await generator.generate(
      request: remoteGenerationRequest(tier: .pro, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 2)
    let firstBody = try requestJSONObject(plan.requests[0])
    let secondBody = try requestJSONObject(plan.requests[1])
    XCTAssertNil(firstBody["modelContinuation"])
    let replay = try XCTUnwrap(secondBody["modelContinuation"] as? [[String: Any]])
    XCTAssertEqual(replay.count, 1)
    XCTAssertEqual(replay[0]["round"] as? Int, 0)
    XCTAssertEqual(replay[0]["callIDs"] as? [String], ["read-note-1"])
    XCTAssertEqual(replay[0]["reasoningID"] as? String, "rs_reasoning_1")
    XCTAssertEqual(replay[0]["encryptedContent"] as? String, "opaque_payload-123==")
  }

  func testFastV2AcceptsAndReplaysOptionalOpaqueContinuationFromLuna() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-fast-continuation-\(UUID().uuidString)")
    )
    let continuation: [String: Any] = [
      "round": 0,
      "callIDs": ["fast-read-note-1"],
      "reasoningID": "rs_fast_reasoning_1",
      "encryptedContent": "opaque_fast_payload-123==",
    ]
    let toolResponse = try JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 2,
        "kind": "tool_calls",
        "calls": [
          [
            "callID": "fast-read-note-1",
            "name": "query_notes",
            "arguments":
              #"{"query_id":"fast-note","text":"bitcoin","record_ids":[],"time":{"field":"updated","preset":"any","start":null,"end":null},"sort":"relevanceDesc","content":"preview","limit":1,"cursor":null}"#,
          ]
        ],
        "modelContinuation": [continuation],
      ],
      options: [.sortedKeys]
    )
    let answerResponse = try JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 2,
        "kind": "answer",
        "claims": [],
      ],
      options: [.sortedKeys]
    )
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(statusCode: 200, body: toolResponse),
        .init(statusCode: 200, body: answerResponse),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "fast-continuation-tests"
    )

    _ = try await generator.generate(
      request: remoteGenerationRequest(tier: .fast, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 2)
    let firstBody = try requestJSONObject(plan.requests[0])
    let secondBody = try requestJSONObject(plan.requests[1])
    XCTAssertNil(firstBody["modelContinuation"])
    let replay = try XCTUnwrap(secondBody["modelContinuation"] as? [[String: Any]])
    XCTAssertEqual(replay.count, 1)
    XCTAssertEqual(replay[0]["round"] as? Int, 0)
    XCTAssertEqual(replay[0]["callIDs"] as? [String], ["fast-read-note-1"])
    XCTAssertEqual(replay[0]["reasoningID"] as? String, "rs_fast_reasoning_1")
    XCTAssertEqual(replay[0]["encryptedContent"] as? String, "opaque_fast_payload-123==")
  }

  func testProV2ProposalContinuesToModelAnswerAndRemainsReviewOnly() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-pro-action-response-\(UUID().uuidString)")
    )
    let toolResponseObject = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: remoteNoteToolCallResponse(
          callID: "pro-note-review",
          title: "Bitcoin bull case",
          body: "A concise draft"
        )
      ) as? [String: Any]
    )
    var toolResponse = toolResponseObject
    toolResponse["modelContinuation"] = [
      [
        "round": 0,
        "callIDs": ["pro-note-review"],
        "reasoningID": "rs_pro_action_1",
        "encryptedContent": "opaque_pro_action_payload",
      ]
    ]
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(
          statusCode: 200,
          body: try JSONSerialization.data(withJSONObject: toolResponse, options: [.sortedKeys])
        ),
        .init(
          statusCode: 200,
          body: try remoteActionAnswerResponse(
            message: "I prepared a concise Bitcoin memo for you to review."
          )
        ),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .pro, policy: .allPreparationEnabled)
    let initialState = await context.remoteState()
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "pro-action-response-tests"
    )

    let output = try await generator.generate(
      request: remoteGenerationRequest(tier: .pro, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 2)
    let secondBody = try requestJSONObject(plan.requests[1])
    let replay = try XCTUnwrap(secondBody["modelContinuation"] as? [[String: Any]])
    XCTAssertEqual(replay.first?["callIDs"] as? [String], ["pro-note-review"])
    XCTAssertEqual(output.proposedAction?.capability, .createNote)
    XCTAssertTrue(output.claims.first?.text.contains("prepared a concise Bitcoin memo") == true)
    XCTAssertTrue(output.claims.first?.text.contains("Nothing changes unless") == true)
    let finalState = await context.remoteState()
    XCTAssertEqual(finalState.catalog, initialState.catalog)
    XCTAssertEqual(finalState.toolHistory.map(\.callID), ["pro-note-review"])
  }

  func testFinalV2ActionRoundRetriesTheIdenticalPacketAfter502ThenUsesModelAnswer()
    async throws
  {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-final-round-retry-\(UUID().uuidString)")
    )
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(
          statusCode: 200,
          body: try remoteNoteToolCallResponse(
            callID: "final-retry-note",
            title: "Bitcoin bull case",
            body: "A concise memo"
          )
        ),
        .init(statusCode: 502, body: Data(#"{"error":"invalid_upstream_output"}"#.utf8)),
        .init(
          statusCode: 200,
          body: try remoteActionAnswerResponse(
            message: "I prepared the Bitcoin memo for your review."
          )
        ),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "final-round-retry-tests"
    )

    let output = try await generator.generate(
      request: remoteGenerationRequest(tier: .fast, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 3)
    XCTAssertEqual(plan.requests[1].httpBody, plan.requests[2].httpBody)
    XCTAssertEqual(output.proposedAction?.capability, .createNote)
    XCTAssertTrue(output.claims.first?.text.contains("prepared the Bitcoin memo") == true)
    let state = await context.remoteState()
    XCTAssertEqual(state.toolHistory.map(\.callID), ["final-retry-note"])
  }

  func testFinalV2ActionRoundReturnsNativeReviewCardAfterTwo502sWithoutWriting()
    async throws
  {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-final-round-fallback-\(UUID().uuidString)")
    )
    let failure = Data(#"{"error":"invalid_upstream_output"}"#.utf8)
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(
          statusCode: 200,
          body: try remoteNoteToolCallResponse(
            callID: "final-fallback-note",
            title: "Bitcoin bull case",
            body: "A concise memo"
          )
        ),
        .init(statusCode: 502, body: failure),
        .init(statusCode: 502, body: failure),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let initialState = await context.remoteState()
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "final-round-fallback-tests"
    )

    let output = try await generator.generate(
      request: remoteGenerationRequest(tier: .fast, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 3)
    XCTAssertEqual(plan.requests[1].httpBody, plan.requests[2].httpBody)
    let intent = try XCTUnwrap(output.proposedAction)
    XCTAssertEqual(intent.capability, .createNote)
    XCTAssertTrue(output.claims.first?.text.contains("prepared **") == true)
    XCTAssertTrue(output.claims.first?.text.contains("Nothing changes unless") == true)
    let state = await context.remoteState()
    XCTAssertEqual(state.catalog, initialState.catalog)
    XCTAssertTrue(state.evidence.isEmpty)
    XCTAssertEqual(state.toolHistory.map(\.callID), ["final-fallback-note"])
  }

  func testMalformedAnswerAfterProposalStillReturnsTheNativeReviewCard() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-malformed-answer-card-\(UUID().uuidString)")
    )
    let malformedAnswer = try JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 2,
        "kind": "answer",
        "claims": [],
        "calls": [],
      ],
      options: [.sortedKeys]
    )
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(
          statusCode: 200,
          body: try remoteNoteToolCallResponse(
            callID: "malformed-answer-note",
            title: "Bitcoin bull case",
            body: "A concise memo"
          )
        ),
        .init(statusCode: 200, body: malformedAnswer),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let initialState = await context.remoteState()
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "malformed-answer-card-tests"
    )

    let output = try await generator.generate(
      request: remoteGenerationRequest(tier: .fast, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 2)
    XCTAssertEqual(output.proposedAction?.capability, .createNote)
    XCTAssertTrue(output.claims.first?.text.contains("Nothing changes unless") == true)
    let state = await context.remoteState()
    XCTAssertEqual(state.catalog, initialState.catalog)
    XCTAssertTrue(state.evidence.isEmpty)
    XCTAssertEqual(state.toolHistory.map(\.callID), ["malformed-answer-note"])
  }

  func testOversizedNextRoundAfterAStagedProposalKeepsTheNativeReviewCard() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-overflow-card-\(UUID().uuidString)")
    )
    func noteResponse(callID: String, body: String) throws -> Data {
      try remoteNoteToolCallResponse(callID: callID, title: "Large note", body: body)
    }
    let tooLarge = String(repeating: "x", count: 30_000)
    let maximumValid = String(repeating: "y", count: 20_000)
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(statusCode: 200, body: try noteResponse(callID: "large-note-invalid-1", body: tooLarge)),
        .init(statusCode: 200, body: try noteResponse(callID: "large-note-invalid-2", body: tooLarge)),
        .init(statusCode: 200, body: try noteResponse(callID: "large-note-valid", body: maximumValid)),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "overflow-card-tests"
    )

    let output = try await generator.generate(
      request: remoteGenerationRequest(tier: .fast, context: context),
      progress: { _ in }
    )

    XCTAssertEqual(plan.requests.count, 3)
    let intent = try XCTUnwrap(output.proposedAction)
    XCTAssertEqual(intent.capability, .createNote)
    guard case .createNote(let payload) = intent.payload else {
      return XCTFail("Expected the maximum-size valid note to remain staged for review.")
    }
    XCTAssertEqual(payload.body, maximumValid)
    XCTAssertTrue(output.claims.first?.text.contains("Nothing changes unless") == true)
    let state = await context.remoteState()
    XCTAssertEqual(
      state.toolHistory.map(\.callID),
      ["large-note-invalid-1", "large-note-invalid-2", "large-note-valid"]
    )
  }

  func testRelayStatusRetryabilityMatchesTheVisibleRetryAffordance() async throws {
    let cases: [(status: Int, body: Data, expected: AskIAgentFailure.Reason, retryable: Bool, requests: Int)] = [
      (429, Data(#"{"error":"rate_limited"}"#.utf8), .rateLimited, false, 1),
      (422, Data(#"{"error":"invalid_request"}"#.utf8), .relayContractRejected, false, 1),
      (503, Data(#"{"error":"service_unavailable"}"#.utf8), .temporarilyUnavailable, true, 2),
    ]

    for item in cases {
      let relayURL = try XCTUnwrap(
        URL(string: "http://127.0.0.1/v2-status-\(item.status)-\(UUID().uuidString)")
      )
      let plan = AskIAgentRemoteURLProtocolStub.install(
        for: relayURL,
        responses: (0..<item.requests).map { _ in
          .init(statusCode: item.status, body: item.body)
        }
      )
      defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
      let session = remoteStubSession()
      let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
      let generator = AskIAgentRemoteGenerator(
        relayURL: relayURL,
        session: session,
        safetyIdentifier: "retry-affordance-tests"
      )

      do {
        _ = try await generator.generate(
          request: remoteGenerationRequest(tier: .fast, context: context),
          progress: { _ in }
        )
        XCTFail("HTTP \(item.status) must fail.")
      } catch let failure as AskIAgentFailure {
        XCTAssertEqual(failure.reason, item.expected)
        XCTAssertEqual(failure.isRetryable, item.retryable)
      }
      XCTAssertEqual(plan.requests.count, item.requests)
      session.invalidateAndCancel()
    }
  }

  func testRemoteV2SendsTheExactAcceptedMultibytePromptWithoutTruncation() async throws {
    let exact = String(repeating: "😀", count: 599) + "ab"
    XCTAssertEqual(exact.utf16.count, AskIAgentModel.maximumPromptUTF16Length)
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-prompt-integrity-\(UUID().uuidString)")
    )
    let answer = try JSONSerialization.data(
      withJSONObject: ["protocolVersion": 2, "kind": "answer", "claims": []],
      options: [.sortedKeys]
    )
    let plan = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [.init(statusCode: 200, body: answer)]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let request = AskIAgentGenerationRequest(
      modelTier: .fast,
      prompt: exact,
      recentConversation: [],
      evidence: [],
      researchContext: nil,
      contextAsOf: now,
      localeIdentifier: "en_US",
      v2Context: context
    )
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "prompt-integrity-tests"
    )

    _ = try await generator.generate(request: request, progress: { _ in })

    XCTAssertEqual(plan.requests.count, 1)
    let body = try requestJSONObject(plan.requests[0])
    XCTAssertEqual(body["prompt"] as? String, exact)
  }

  func testNativeActionAcknowledgementAcceptsOnlyCompleteNoCommitClauses() {
    for message in [
      "Prepared ‘Grab coffee with Gabby’ as a to-do for review; nothing has been created yet.",
      "A concise memo was prepared as a note for review. Nothing has been saved yet.",
      "The draft is ready for review; nothing was created or saved.",
    ] {
      XCTAssertEqual(AskIAgentActionMessageValidator.validate(message), message)
    }
    XCTAssertNil(
      AskIAgentActionMessageValidator.validate(
        "I created the note for review; nothing has been saved yet."
      )
    )
    XCTAssertNil(AskIAgentActionMessageValidator.validate("I created and saved the note."))
  }

  func testFreeV2GenerationFailuresRemainTypedUntilANativeProposalExists() async throws {
    let generator = AskIAgentFoundationGenerator()
    let reasons: [AskIAgentFailure.Reason] = [
      .temporarilyUnavailable, .contextTooLarge, .malformedResponse,
    ]

    for reason in reasons {
      let context = try makeContext(tier: .free, policy: .allPreparationEnabled)
      let state = await context.remoteState()
      XCTAssertTrue(state.evidence.isEmpty)
      XCTAssertTrue(state.toolHistory.isEmpty)
      do {
        _ = try await generator.recoverV2GenerationFailure(
          AskIAgentFailure(reason: reason),
          context: context
        )
        XCTFail("A Free generation failure with no native intent must remain a failure.")
      } catch let failure as AskIAgentFailure {
        XCTAssertEqual(failure.reason, reason)
      }
    }

    let context = try makeContext(tier: .free, policy: .allPreparationEnabled)
    _ = try await context.executeToolCall(
      callID: "free-recovery-note",
      name: AssistantProposalToolCatalog.createNoteName,
      argumentsJSON: Data(#"{"title":"Bitcoin bull case","body":"A concise memo"}"#.utf8),
      progress: { _ in }
    )
    let output = try await generator.recoverV2GenerationFailure(
      AskIAgentFailure(reason: .temporarilyUnavailable),
      context: context
    )
    XCTAssertEqual(output.proposedAction?.capability, .createNote)
    XCTAssertTrue(output.claims.first?.text.contains("Nothing changes unless") == true)

    let unsafeReasons: [AskIAgentFailure.Reason] = [
      .restrictedSourceContent,
      .modelDeclined,
      .unsupportedLanguage,
      .remoteAuthenticationFailed,
      .rateLimited,
      .relayContractRejected,
      .busy,
      .ungroundedResponse,
      .unknown,
    ]
    for reason in unsafeReasons {
      do {
        _ = try await generator.recoverV2GenerationFailure(
          AskIAgentFailure(reason: reason),
          context: context
        )
        XCTFail("A staged Free proposal must not mask typed failure \(reason).")
      } catch let failure as AskIAgentFailure {
        XCTAssertEqual(failure.reason, reason)
      }
    }
  }

  func testRemoteRejectsActionMessageWithoutANativeProposal() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-action-message-without-proposal-\(UUID().uuidString)")
    )
    _ = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [
        .init(
          statusCode: 200,
          body: try remoteActionAnswerResponse(
            message: "I prepared something for review."
          )
        )
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "action-message-trust-boundary-tests"
    )

    do {
      _ = try await generator.generate(
        request: remoteGenerationRequest(tier: .fast, context: context),
        progress: { _ in }
      )
      XCTFail("Action prose without a native staged proposal must fail closed.")
    } catch let failure as AskIAgentFailure {
      XCTAssertEqual(failure.reason, .malformedResponse)
    }
    let intent = await context.actionIntent()
    XCTAssertNil(intent)
    let state = await context.remoteState()
    XCTAssertTrue(state.toolHistory.isEmpty)
  }

  func testProV2RejectsContinuationThatDoesNotMatchTheExactToolCallOrder() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-pro-invalid-continuation-\(UUID().uuidString)")
    )
    let response = try JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 2,
        "kind": "tool_calls",
        "calls": [
          [
            "callID": "actual-call",
            "name": "query_notes",
            "arguments":
              #"{"query_id":"invalid-continuation","text":null,"record_ids":[],"time":{"field":"updated","preset":"any","start":null,"end":null},"sort":"updatedDesc","content":"preview","limit":1,"cursor":null}"#,
          ]
        ],
        "modelContinuation": [
          [
            "round": 0,
            "callIDs": ["different-call"],
            "reasoningID": "rs_reasoning_mismatch",
            "encryptedContent": "opaque_payload",
          ]
        ],
      ],
      options: [.sortedKeys]
    )
    _ = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [.init(statusCode: 200, body: response)]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .pro, policy: .allPreparationEnabled)
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "pro-continuation-tests"
    )

    do {
      _ = try await generator.generate(
        request: remoteGenerationRequest(tier: .pro, context: context),
        progress: { _ in }
      )
      XCTFail("A continuation must be bound to the exact ordered call-ID group.")
    } catch let failure as AskIAgentFailure {
      XCTAssertEqual(failure.reason, .malformedResponse)
    }
    let state = await context.remoteState()
    XCTAssertTrue(state.toolHistory.isEmpty)
    let intent = await context.actionIntent()
    XCTAssertNil(intent)
  }

  func testProV2RequiresContinuationForEveryToolCallResponse() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-pro-missing-continuation-\(UUID().uuidString)")
    )
    let response = try remoteNoteToolCallResponse(
      callID: "pro-note-without-continuation",
      title: "Review only",
      body: "Must never be staged from an incomplete Pro turn."
    )
    _ = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [.init(statusCode: 200, body: response)]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .pro, policy: .allPreparationEnabled)
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "pro-continuation-tests"
    )

    do {
      _ = try await generator.generate(
        request: remoteGenerationRequest(tier: .pro, context: context),
        progress: { _ in }
      )
      XCTFail("A Pro tool-call response without replayable reasoning must fail closed.")
    } catch let failure as AskIAgentFailure {
      XCTAssertEqual(failure.reason, .malformedResponse)
    }
    let intent = await context.actionIntent()
    XCTAssertNil(intent)
    let state = await context.remoteState()
    XCTAssertTrue(state.toolHistory.isEmpty)
  }

  func testProV2RejectsContinuationAboveThe24KiBEnvelopeBeforeExecutingTools() async throws {
    let relayURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1/v2-pro-oversize-continuation-\(UUID().uuidString)")
    )
    let response = try JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 2,
        "kind": "tool_calls",
        "calls": [
          [
            "callID": "oversize-call",
            "name": AssistantProposalToolCatalog.createNoteName,
            "arguments": #"{"title":"Must not stage","body":"Oversize continuation"}"#,
          ]
        ],
        "modelContinuation": [
          [
            "round": 0,
            "callIDs": ["oversize-call"],
            "reasoningID": "rs_oversize",
            "encryptedContent": String(repeating: "A", count: 24 * 1_024 + 1),
          ]
        ],
      ],
      options: [.sortedKeys]
    )
    _ = AskIAgentRemoteURLProtocolStub.install(
      for: relayURL,
      responses: [.init(statusCode: 200, body: response)]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: relayURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let context = try makeContext(tier: .pro, policy: .allPreparationEnabled)
    let generator = AskIAgentRemoteGenerator(
      relayURL: relayURL,
      session: session,
      safetyIdentifier: "pro-continuation-tests"
    )

    do {
      _ = try await generator.generate(
        request: remoteGenerationRequest(tier: .pro, context: context),
        progress: { _ in }
      )
      XCTFail("Continuation larger than 24 KiB must be rejected before tool execution.")
    } catch let failure as AskIAgentFailure {
      XCTAssertEqual(failure.reason, .contextTooLarge)
      XCTAssertFalse(failure.isRetryable)
    }
    let intent = await context.actionIntent()
    XCTAssertNil(intent)
    let state = await context.remoteState()
    XCTAssertTrue(state.toolHistory.isEmpty)
  }

  func testRemoteTokenProviderFailuresRetainTheirMeaningAtGeneratorBoundary() async throws {
    let cases: [(AskIAgentRemoteTokenProviderError, AskIAgentFailure.Reason)] = [
      (.authenticationFailed, .remoteAuthenticationFailed),
      (.rateLimited(retryAfter: 21), .rateLimited),
      (.temporarilyUnavailable, .temporarilyUnavailable),
      (.malformedResponse, .temporarilyUnavailable),
    ]

    for (providerError, expectedReason) in cases {
      let context = try makeContext(tier: .fast, policy: .allPreparationEnabled)
      let generator = AskIAgentRemoteGenerator(
        relayURL: try XCTUnwrap(
          URL(string: "https://relay.invalid/typed-token-\(UUID().uuidString)/ask")
        ),
        session: remoteStubSession(),
        safetyIdentifier: "typed-token-provider-tests",
        tokenProvider: ThrowingAskIAgentRemoteTokenProvider(error: providerError)
      )

      do {
        _ = try await generator.generate(
          request: remoteGenerationRequest(tier: .fast, context: context),
          progress: { _ in }
        )
        XCTFail("The generator must not erase \(providerError).")
      } catch let failure as AskIAgentFailure {
        XCTAssertEqual(failure.reason, expectedReason)
      } catch {
        XCTFail("Expected AskIAgentFailure for \(providerError), got \(error).")
      }
    }
  }

  func testOnDeviceV2ProfileKeepsTheFirstTurnInsideABoundedContextEnvelope() async throws {
    let context = try AskIAgentV2TurnContext(
      snapshot: IAgentDataSnapshot(),
      phoneEvents: [],
      snapshotID: "on-device-context-budget",
      contextAsOf: now,
      localeIdentifier: "en_US",
      firstWeekday: 2,
      inferenceProfile: .onDevice,
      actionPolicy: .allPreparationEnabled,
      provenance: AssistantActionProvenance(
        conversationID: "conversation-free",
        turnID: "turn-free",
        currentUserMessageID: "message-free",
        toolCallID: "pending-model-tool-call"
      )
    )

    let state = await context.remoteState()
    XCTAssertEqual(state.budgetLimit.maximumCalls, 5)
    XCTAssertEqual(state.budgetLimit.maximumCallsPerDomain, 1)
    XCTAssertEqual(state.budgetLimit.maximumPagesPerDomain, 1)
    XCTAssertEqual(state.budgetLimit.maximumRecordsPerPage, 4)
    XCTAssertEqual(state.budgetLimit.maximumTotalRecords, 12)
    XCTAssertEqual(state.budgetLimit.maximumEvidencePassages, 8)
    XCTAssertEqual(state.budgetLimit.maximumEvidenceCharacters, 4_200)
    XCTAssertLessThan(context.catalogManifest.utf8.count, 700)
    XCTAssertTrue(context.catalogManifest.contains("todo:available,count=0"))
    XCTAssertTrue(context.catalogManifest.contains("coverage=unspecified"))
    XCTAssertTrue(context.catalogManifest.contains("coverage_complete=true"))
    XCTAssertFalse(context.catalogManifest.contains("snapshotID"))
  }

  @MainActor
  func testAskIAgentCalendarCaptureBoundsArePromptIndependentAndDayAligned() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Athens"))
    let reference = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-08-12T14:37:00+03:00")
    )
    let day = calendar.startOfDay(for: reference)

    let first = try XCTUnwrap(
      MobileCalendarService.askIAgentCoverage(referenceDate: reference, calendar: calendar)
    )
    let second = try XCTUnwrap(
      MobileCalendarService.askIAgentCoverage(referenceDate: reference, calendar: calendar)
    )

    XCTAssertEqual(first, second)
    XCTAssertEqual(
      first.start,
      calendar.date(
        byAdding: .day,
        value: -MobileCalendarService.askIAgentPastDayCount,
        to: day
      )
    )
    XCTAssertEqual(
      first.end,
      calendar.date(
        byAdding: .day,
        value: MobileCalendarService.askIAgentFutureDayCount,
        to: day
      )
    )
    XCTAssertEqual(calendar.component(.hour, from: first.start), 0)
    XCTAssertEqual(calendar.component(.minute, from: first.start), 0)
    XCTAssertEqual(calendar.component(.hour, from: first.end), 0)
    XCTAssertEqual(calendar.component(.minute, from: first.end), 0)
  }

  func testCalendarOutsidePinnedCoverageReturnsRepairReceiptThenAcceptsCorrectedRange()
    async throws
  {
    let formatter = ISO8601DateFormatter()
    let coverage = AskCatalogCoverage(
      start: try XCTUnwrap(formatter.date(from: "2026-08-01T00:00:00Z")),
      end: try XCTUnwrap(formatter.date(from: "2026-09-01T00:00:00Z")),
      isCompleteWithinRange: true,
      isTruncated: false
    )
    let context = try makeContext(
      tier: .free,
      policy: .allPreparationEnabled,
      calendarCoverage: coverage
    )
    XCTAssertTrue(context.catalogManifest.contains("coverage_start=2026-08-01T00:00:00Z"))
    XCTAssertTrue(context.catalogManifest.contains("coverage_end=2026-09-01T00:00:00Z"))

    let outside = try await context.executeToolCall(
      callID: "calendar-outside-call",
      name: AskReadToolSchemas.calendar.name,
      argumentsJSON: try remoteCalendarReadArguments(
        queryID: "calendar-outside-query",
        start: "2026-09-01T00:00:00Z",
        end: "2026-09-02T00:00:00Z"
      ),
      progress: { _ in }
    )
    XCTAssertTrue(outside.output.contains(#""code":"outOfCoverage""#))
    XCTAssertTrue(outside.output.contains(#""repairable":true"#))
    XCTAssertTrue(outside.output.contains("No records were read"))
    XCTAssertTrue(outside.evidenceIDs.isEmpty)

    let inside = try await context.executeToolCall(
      callID: "calendar-inside-call",
      name: AskReadToolSchemas.calendar.name,
      argumentsJSON: try remoteCalendarReadArguments(
        queryID: "calendar-inside-query",
        start: "2026-08-12T00:00:00Z",
        end: "2026-08-13T00:00:00Z"
      ),
      progress: { _ in }
    )
    XCTAssertFalse(inside.output.contains("tool_error"))
    XCTAssertTrue(inside.output.contains("matched=0"))
    let state = await context.remoteState()
    XCTAssertEqual(state.toolHistory.map(\.callID), ["calendar-outside-call", "calendar-inside-call"])
    XCTAssertEqual(state.budgetUsage.calls, 1)
  }

  func testFreeV2UsesOneCompactModelDrivenSessionWithoutPlannerOrRepairSessions() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("iAgentMobile/Model/AskIAgentModel.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    let start = try XCTUnwrap(source.range(of: "  private func generateV2("))
    let end = try XCTUnwrap(
      source.range(of: "  private static func actionResponseClaim", range: start.upperBound..<source.endIndex)
    )
    let v2 = String(source[start.lowerBound..<end.lowerBound])

    XCTAssertEqual(v2.components(separatedBy: "LanguageModelSession(").count - 1, 1)
    XCTAssertTrue(v2.contains("tools: context.compactTools(progress: progress)"))
    XCTAssertTrue(v2.contains("generating: GeneratedAskIAgentV2Completion.self"))
    XCTAssertTrue(v2.contains("response.content.actionMessage"))
    XCTAssertTrue(v2.contains("maximumResponseTokens: 420"))
    XCTAssertFalse(v2.contains("v2ToolSelection"))
    XCTAssertFalse(v2.contains("repair"))
    XCTAssertFalse(v2.contains("verifiedClaims"))
    XCTAssertFalse(source.contains("request.prompt.lowercased()"))
    XCTAssertTrue(source.contains("marks itself repairable"))
    XCTAssertTrue(source.contains("budget is exhausted"))
    XCTAssertTrue(source.contains("stop calling proposal tools"))
  }

  func testFreeCompactGatewaysLeaveDomainAndActionSelectionToTheModel() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("iAgentMobile/Model/AskIAgentV2Harness.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "  struct AskIAgentReadGatewayArguments"))
    let end = try XCTUnwrap(
      source.range(
        of: "  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)\n  @Generable(description: \"A half-open temporal filter",
        range: start.upperBound..<source.endIndex
      )
    )
    let gateways = String(source[start.lowerBound..<end.lowerBound])

    XCTAssertTrue(gateways.contains("let name = \"query_iagent_data\""))
    XCTAssertTrue(gateways.contains("let name = \"prepare_iagent_action\""))
    XCTAssertTrue(gateways.contains("var domain: String"))
    XCTAssertTrue(gateways.contains("\"last30Days\", \"absolute\""))
    XCTAssertTrue(gateways.contains("var start: String?"))
    XCTAssertTrue(gateways.contains("var end: String?"))
    XCTAssertTrue(gateways.contains("var kind: String"))
    XCTAssertTrue(gateways.contains("executeNativeReadGateway("))
    XCTAssertTrue(gateways.contains("try arguments.query()"))
    XCTAssertTrue(gateways.contains("executeNativeActionGateway"))
    XCTAssertFalse(gateways.contains("prompt.lowercased"))
    XCTAssertFalse(gateways.contains("contains(\"memo\")"))
    XCTAssertFalse(gateways.contains("contains(\"todo\")"))
  }

  @MainActor
  func testModelStartsWithPersistedActionPolicyBeforeFirstManualSend() {
    var persistedPolicy = AssistantActionCapabilityPolicy.allPreparationEnabled
    persistedPolicy.setPreparationEnabled(false, for: .createNote)

    let model = AskIAgentModel(actionCapabilityPolicy: persistedPolicy)

    XCTAssertEqual(model.actionCapabilityPolicy, persistedPolicy)
  }

  private func makeContext(
    tier: AskIAgentModelTier,
    policy: AssistantActionCapabilityPolicy,
    snapshot: IAgentDataSnapshot = IAgentDataSnapshot(),
    calendarCoverage: AskCatalogCoverage? = nil
  ) throws -> AskIAgentV2TurnContext {
    try AskIAgentV2TurnContext(
      snapshot: snapshot,
      phoneEvents: [],
      calendarCoverage: calendarCoverage,
      snapshotID: "action-flow-\(tier.rawValue)",
      contextAsOf: now,
      localeIdentifier: "en_US",
      firstWeekday: 2,
      actionPolicy: policy,
      provenance: AssistantActionProvenance(
        conversationID: "conversation-\(tier.rawValue)",
        turnID: "turn-\(tier.rawValue)",
        currentUserMessageID: "message-\(tier.rawValue)",
        toolCallID: "pending-model-tool-call"
      )
    )
  }

  private func remoteGenerationRequest(
    tier: AskIAgentModelTier,
    context: AskIAgentV2TurnContext
  ) -> AskIAgentGenerationRequest {
    AskIAgentGenerationRequest(
      modelTier: tier,
      prompt: "Create a memo about a bull case for bitcoin.",
      recentConversation: [],
      evidence: [],
      researchContext: nil,
      contextAsOf: now,
      localeIdentifier: "en_US",
      v2Context: context
    )
  }

  private func remoteNoteToolCallResponse(
    callID: String,
    title: String,
    body: String
  ) throws -> Data {
    let arguments = try JSONSerialization.data(
      withJSONObject: ["title": title, "body": body],
      options: [.sortedKeys]
    )
    return try JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 2,
        "kind": "tool_calls",
        "calls": [
          [
            "callID": callID,
            "name": AssistantProposalToolCatalog.createNoteName,
            "arguments": String(decoding: arguments, as: UTF8.self),
          ]
        ],
      ],
      options: [.sortedKeys]
    )
  }

  private func remoteNoteReadArguments(
    queryID: String,
    temporalField: String,
    limit: Int,
    preset: String = "any",
    start: String? = nil,
    end: String? = nil
  ) throws -> Data {
    let time: [String: Any] = [
      "field": temporalField,
      "preset": preset,
      "start": start ?? NSNull(),
      "end": end ?? NSNull(),
    ]
    return try JSONSerialization.data(
      withJSONObject: [
        "query_id": queryID,
        "text": NSNull(),
        "record_ids": [],
        "time": time,
        "sort": "updatedDesc",
        "content": "preview",
        "limit": limit,
        "cursor": NSNull(),
      ],
      options: [.sortedKeys]
    )
  }

  private func remoteCalendarReadArguments(
    queryID: String,
    start: String,
    end: String
  ) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "query_id": queryID,
        "text": NSNull(),
        "record_ids": [],
        "time": [
          "field": "occurrence",
          "preset": "absolute",
          "start": start,
          "end": end,
        ],
        "calendar_titles": [],
        "all_day": NSNull(),
        "sort": "startAsc",
        "content": "details",
        "limit": 1,
        "cursor": NSNull(),
      ],
      options: [.sortedKeys]
    )
  }

  private func remoteNoteReadToolCallResponse(
    callID: String,
    queryID: String,
    temporalField: String,
    limit: Int
  ) throws -> Data {
    let arguments = try remoteNoteReadArguments(
      queryID: queryID,
      temporalField: temporalField,
      limit: limit
    )
    return try JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 2,
        "kind": "tool_calls",
        "calls": [
          [
            "callID": callID,
            "name": AskReadToolSchemas.note.name,
            "arguments": String(decoding: arguments, as: UTF8.self),
          ]
        ],
      ],
      options: [.sortedKeys]
    )
  }

  private func remoteActionAnswerResponse(message: String) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 2,
        "kind": "answer",
        "claims": [],
        "actionMessage": message,
      ],
      options: [.sortedKeys]
    )
  }

  private func remoteStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AskIAgentRemoteURLProtocolStub.self]
    return URLSession(configuration: configuration)
  }

  private func assertActionSchemaIdentity(in requests: [URLRequest]) throws {
    for request in requests {
      let body = try XCTUnwrap(request.httpBody)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
      )
      XCTAssertEqual(
        object["actionToolSchemaVersion"] as? Int,
        AssistantProposalToolCatalog.schemaVersion
      )
      XCTAssertEqual(
        object["actionToolSchemaDigest"] as? String,
        AssistantProposalToolCatalog.schemaDigest
      )
    }
  }

  private func requestJSONObject(_ request: URLRequest) throws -> [String: Any] {
    let body = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  private func assertProposalOnlyState(
    _ context: AskIAgentV2TurnContext,
    initialState: AskIAgentV2RemoteState,
    expectedToolCall: AskIAgentV2ToolResult,
    tier: AskIAgentModelTier
  ) async throws {
    let completedState = await context.remoteState()

    XCTAssertEqual(
      completedState.catalog,
      initialState.catalog,
      "Preparing a \(tier.displayName) review card must not mutate the local catalog."
    )
    XCTAssertTrue(completedState.evidence.isEmpty)
    XCTAssertEqual(completedState.toolHistory, [expectedToolCall])
  }
}

#if canImport(FoundationModels)
  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @Generable(description: "Controlled Foundation Models tool arguments")
  private struct AskIAgentFailingTestToolArguments {
    var value: String
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private struct AskIAgentFailingTestTool: Tool {
    let name = "ask_iagent_test_tool"
    let description = "Controlled test tool"

    func call(arguments _: AskIAgentFailingTestToolArguments) async throws -> String {
      "unused"
    }
  }
#endif

final class AskIAgentTurnLifecycleTests: XCTestCase {
  @MainActor
  func testPromptIntegrityAcceptsExactly1200UTF16UnitsAndRejects1201WithoutAppending()
    async throws
  {
    let exact = String(repeating: "😀", count: 599) + "ab"
    let oversized = exact + "c"
    XCTAssertEqual(exact.utf16.count, AskIAgentModel.maximumPromptUTF16Length)
    XCTAssertEqual(oversized.utf16.count, AskIAgentModel.maximumPromptUTF16Length + 1)

    let acceptedGenerator = AlwaysFailAskIAgentGenerator(reason: .rateLimited)
    let acceptedModel = AskIAgentModel(generator: acceptedGenerator)
    XCTAssertTrue(acceptedModel.submit(prompt: exact, evidence: [makeEvidence()]))
    try await waitForTerminalState(acceptedModel)
    XCTAssertEqual(acceptedModel.history.first?.content, exact)
    let acceptedRequests = await acceptedGenerator.requests()
    XCTAssertEqual(acceptedRequests.first?.prompt, exact)
    XCTAssertNil(acceptedModel.inputValidationMessage)

    let rejectedGenerator = AlwaysFailAskIAgentGenerator(reason: .rateLimited)
    let rejectedModel = AskIAgentModel(generator: rejectedGenerator)
    XCTAssertFalse(rejectedModel.submit(prompt: oversized, evidence: [makeEvidence()]))
    XCTAssertEqual(rejectedModel.currentInput, oversized)
    XCTAssertEqual(rejectedModel.inputValidationMessage, AskIAgentModel.promptTooLongMessage)
    XCTAssertTrue(AskIAgentModel.promptTooLongMessage.contains("1,200"))
    XCTAssertTrue(rejectedModel.history.isEmpty)
    let rejectedRequests = await rejectedGenerator.requests()
    XCTAssertTrue(rejectedRequests.isEmpty)
  }

  @MainActor
  func testRetryGateRejectsPolicyAndRateFailuresButAllowsTransientFailure() async throws {
    for reason in [
      AskIAgentFailure.Reason.rateLimited, .relayContractRejected, .contextTooLarge,
    ] {
      let generator = AlwaysFailAskIAgentGenerator(reason: reason)
      let model = AskIAgentModel(generator: generator)
      XCTAssertTrue(model.submit(prompt: "Plan my day", evidence: [makeEvidence()]))
      try await waitForTerminalState(model)
      let messageID = try XCTUnwrap(model.history.first?.id)
      XCTAssertFalse(model.retry(userMessageID: messageID, evidence: [makeEvidence()]))
      let requests = await generator.requests()
      XCTAssertEqual(requests.count, 1)
    }

    let generator = AlwaysFailAskIAgentGenerator(reason: .temporarilyUnavailable)
    let model = AskIAgentModel(generator: generator)
    XCTAssertTrue(model.submit(prompt: "Plan my day", evidence: [makeEvidence()]))
    try await waitForTerminalState(model)
    let messageID = try XCTUnwrap(model.history.first?.id)
    XCTAssertTrue(model.retry(userMessageID: messageID, evidence: [makeEvidence()]))
    try await waitForRequestCount(2, generator: generator)
    let requests = await generator.requests()
    XCTAssertEqual(requests.count, 2)
  }

  @MainActor
  func testCancelThenRetryReusesOneUserMessageAndExcludesItFromPriorContext() async throws {
    let generator = CancelThenFailAskIAgentGenerator()
    let model = AskIAgentModel(generator: generator)
    let evidence = [makeEvidence()]

    XCTAssertTrue(model.submit(prompt: "Plan my day", evidence: evidence))
    try await waitForRequestCount(1, generator: generator)
    let originalMessage = try XCTUnwrap(model.history.first)
    XCTAssertEqual(originalMessage.role, .user)

    model.cancel()
    XCTAssertEqual(model.state, .cancelled)
    XCTAssertEqual(model.history.map(\.id), [originalMessage.id])

    XCTAssertTrue(
      model.retry(
        userMessageID: originalMessage.id,
        evidence: evidence,
        contextAsOf: Date(timeIntervalSince1970: 1_786_381_260)
      )
    )
    try await waitForTerminalState(model)

    XCTAssertEqual(model.history.filter { $0.role == .user }.map(\.id), [originalMessage.id])
    XCTAssertEqual(model.history.count, 1)
    guard case .failed(let failure) = model.state else {
      return XCTFail("The controlled second request should finish with its typed failure.")
    }
    XCTAssertEqual(failure.reason, .remoteAuthenticationFailed)

    let requests = await generator.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[0].recentConversation.isEmpty)
    XCTAssertTrue(
      requests[1].recentConversation.isEmpty,
      "The retried prompt must not be duplicated inside prior-turn model context."
    )
  }

  @MainActor
  func testSendingRetainedFailedPromptRetriesInPlace() async throws {
    let generator = AlwaysFailAskIAgentGenerator(reason: .temporarilyUnavailable)
    let model = AskIAgentModel(generator: generator)
    let evidence = [makeEvidence()]
    let prompt = "Added to do to grab coffee with Gabby."

    XCTAssertTrue(model.submit(prompt: prompt, evidence: evidence))
    try await waitForTerminalState(model)
    let originalMessage = try XCTUnwrap(model.history.first)
    XCTAssertEqual(model.currentInput, prompt)

    XCTAssertTrue(model.submit(prompt: prompt, evidence: evidence))
    try await waitForTerminalState(model)

    XCTAssertEqual(model.history.filter { $0.role == .user }.map(\.id), [originalMessage.id])
    let requests = await generator.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[1].recentConversation.isEmpty)
  }

  @MainActor
  func testSendingRetainedFailedPromptAfterTierChangeStillRetriesInPlace() async throws {
    let generator = AlwaysFailAskIAgentGenerator(reason: .temporarilyUnavailable)
    let model = AskIAgentModel(generator: generator)
    let originalTier = model.selectedModelTier
    defer { model.selectedModelTier = originalTier }
    let evidence = [makeEvidence()]
    let prompt = "Added to do to grab coffee with Gabby."

    model.selectedModelTier = .free
    XCTAssertTrue(model.submit(prompt: prompt, evidence: evidence))
    try await waitForTerminalState(model)
    let originalMessage = try XCTUnwrap(model.history.first)

    model.selectedModelTier = .pro
    XCTAssertTrue(model.submit(prompt: prompt, evidence: evidence))
    try await waitForTerminalState(model)

    XCTAssertEqual(model.history.filter { $0.role == .user }.map(\.id), [originalMessage.id])
    let requests = await generator.requests()
    XCTAssertEqual(requests.map(\.modelTier), [.free, .pro])
    XCTAssertTrue(requests[1].recentConversation.isEmpty)
  }

  @MainActor
  func testSendingRetainedNonRetryablePromptAfterTierChangeStillReusesLogicalTurn() async throws {
    let generator = AlwaysFailAskIAgentGenerator(reason: .rateLimited)
    let model = AskIAgentModel(generator: generator)
    let originalTier = model.selectedModelTier
    defer { model.selectedModelTier = originalTier }
    let evidence = [makeEvidence()]
    let prompt = "Plan my day"

    model.selectedModelTier = .free
    XCTAssertTrue(model.submit(prompt: prompt, evidence: evidence))
    try await waitForTerminalState(model)
    let originalMessage = try XCTUnwrap(model.history.first)
    guard case .failed(let firstFailure) = model.state else {
      return XCTFail("The controlled first request should fail.")
    }
    XCTAssertEqual(firstFailure.reason, .rateLimited)
    XCTAssertFalse(model.retry(userMessageID: originalMessage.id, evidence: evidence))

    model.selectedModelTier = .pro
    XCTAssertTrue(model.submit(prompt: prompt, evidence: evidence))
    try await waitForTerminalState(model)

    XCTAssertEqual(model.history.filter { $0.role == .user }.map(\.id), [originalMessage.id])
    let requestsAfterExactSend = await generator.requests()
    XCTAssertEqual(requestsAfterExactSend.map(\.modelTier), [.free, .pro])
    XCTAssertTrue(requestsAfterExactSend[1].recentConversation.isEmpty)

    let editedPrompt = "Plan my afternoon"
    XCTAssertTrue(model.submit(prompt: editedPrompt, evidence: evidence))
    try await waitForTerminalState(model)
    let userMessages = model.history.filter { $0.role == .user }
    XCTAssertEqual(userMessages.count, 2)
    XCTAssertEqual(userMessages[0].id, originalMessage.id)
    XCTAssertEqual(userMessages[1].content, editedPrompt)
    XCTAssertNotEqual(userMessages[1].id, originalMessage.id)
  }

  @MainActor
  func testSelectingConversationWhileWorkingClearsPreviousTurnLifecycleForRetry() async throws {
    let generator = CancelThenFailAskIAgentGenerator()
    let model = AskIAgentModel(generator: generator)
    let evidence = [makeEvidence()]

    XCTAssertTrue(model.submit(prompt: "Old running turn", evidence: evidence))
    try await waitForRequestCount(1, generator: generator)

    let restored = AskIAgentMessage(
      role: .user,
      content: "Restored unfinished turn",
      createdAt: Date(timeIntervalSince1970: 1_786_381_260)
    )
    model.restoreConversation([restored])
    XCTAssertEqual(model.state, .interrupted)
    XCTAssertEqual(model.history.map(\.id), [restored.id])

    XCTAssertTrue(model.retry(userMessageID: restored.id, evidence: evidence))
    try await waitForTerminalState(model)
    XCTAssertEqual(model.history.filter { $0.role == .user }.map(\.id), [restored.id])
    let requests = await generator.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].prompt, restored.content)
    XCTAssertTrue(requests[1].recentConversation.isEmpty)
  }

  @MainActor
  func testRestoredBuild28DuplicatePromptsCollapseAndRemainRetryableWithoutFalseCancellation()
    async throws
  {
    let generator = AlwaysFailAskIAgentGenerator(reason: .temporarilyUnavailable)
    let model = AskIAgentModel(generator: generator)
    let prompt = "Added to do to grab coffee with Gabby."
    let first = AskIAgentMessage(
      role: .user,
      content: prompt,
      createdAt: Date(timeIntervalSince1970: 1_786_381_200)
    )
    let newest = AskIAgentMessage(
      role: .user,
      content: prompt,
      createdAt: Date(timeIntervalSince1970: 1_786_381_201)
    )

    model.restoreConversation([first, newest])

    XCTAssertEqual(model.history.map(\.id), [newest.id])
    XCTAssertEqual(model.state, .interrupted)
    XCTAssertEqual(model.currentInput, prompt)

    XCTAssertTrue(model.submit(prompt: prompt, evidence: [makeEvidence()]))
    try await waitForTerminalState(model)
    XCTAssertEqual(model.history.filter { $0.role == .user }.map(\.id), [newest.id])
    let requests = await generator.requests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertTrue(requests[0].recentConversation.isEmpty)
  }

  @MainActor
  func testCancelledRequestCannotPublishAStaleCompletion() async throws {
    let generator = StaleCompletionAskIAgentGenerator()
    let model = AskIAgentModel(generator: generator)
    let evidence = [makeEvidence()]

    XCTAssertTrue(model.submit(prompt: "Plan my day", evidence: evidence))
    try await waitForSuspendedRequest(generator)
    let originalMessage = try XCTUnwrap(model.history.first)
    model.cancel()
    XCTAssertEqual(model.state, .cancelled)

    await generator.releaseFirstRequest()
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(model.history.map(\.id), [originalMessage.id])
    XCTAssertEqual(model.state, .cancelled)
    XCTAssertNil(model.proposedActionIntent)
  }

  @MainActor
  private func waitForTerminalState(_ model: AskIAgentModel) async throws {
    for _ in 0..<200 {
      if !model.state.isWorking { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the controlled Ask iAgent turn to finish.")
  }

  @MainActor
  private func waitForRequestCount(
    _ expectedCount: Int,
    generator: CancelThenFailAskIAgentGenerator
  ) async throws {
    for _ in 0..<200 {
      if await generator.requests().count >= expectedCount { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the controlled generator request.")
  }

  @MainActor
  private func waitForRequestCount(
    _ expectedCount: Int,
    generator: AlwaysFailAskIAgentGenerator
  ) async throws {
    for _ in 0..<200 {
      if await generator.requests().count >= expectedCount { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the controlled generator request.")
  }

  @MainActor
  private func waitForSuspendedRequest(_ generator: StaleCompletionAskIAgentGenerator)
    async throws
  {
    for _ in 0..<200 {
      if await generator.isFirstRequestSuspended { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the stale-completion test request.")
  }

  private func makeEvidence() -> AskIAgentEvidence {
    let source = AskIAgentSourceResult(
      id: "todo-source",
      sourceID: UUID().uuidString,
      kind: .todo,
      title: "Ship launch",
      subtitle: nil,
      status: "Open",
      excerpt: "Ship launch",
      updatedAt: Date(timeIntervalSince1970: 1_786_381_200),
      startDate: nil,
      endDate: nil,
      isAllDay: false,
      isCompleted: false,
      isStarred: false
    )
    return AskIAgentEvidence(
      id: "todo:evidence:0",
      source: source,
      revision: "revision-1",
      anchor: nil,
      content: "Ship launch"
    )
  }
}

private actor AlwaysFailAskIAgentGenerator: AskIAgentGenerating {
  let reason: AskIAgentFailure.Reason
  private var recordedRequests: [AskIAgentGenerationRequest] = []

  init(reason: AskIAgentFailure.Reason) { self.reason = reason }

  nonisolated func availability(localeIdentifier _: String) -> AskIAgentAvailability { .available }

  func generate(
    request: AskIAgentGenerationRequest,
    progress _: @escaping @Sendable (AskIAgentWorkStage) -> Void
  ) async throws -> AskIAgentGeneratorOutput {
    recordedRequests.append(request)
    throw AskIAgentFailure(reason: reason)
  }

  func requests() -> [AskIAgentGenerationRequest] { recordedRequests }
}

final class AskIAgentRemoteTokenProviderTests: XCTestCase {
  func testChallengeAuthenticationFailuresAreTyped() async throws {
    for statusCode in [401, 403] {
      let error = await providerError(
        challenge: .init(statusCode: statusCode, body: Data(#"{"error":"rejected"}"#.utf8))
      )
      XCTAssertEqual(error, .authenticationFailed)
    }
  }

  func testChallengeRateLimitPreservesRetryAfter() async throws {
    let error = await providerError(
      challenge: .init(
        statusCode: 429,
        body: Data(#"{"error":"rate_limited"}"#.utf8),
        headerFields: [
          "Content-Type": "application/json",
          "Retry-After": "17",
        ]
      )
    )

    XCTAssertEqual(error, .rateLimited(retryAfter: 17))
  }

  func testExchangeFailuresRemainDistinct() async throws {
    let cases: [(AskIAgentRemoteURLProtocolPlan.Response, AskIAgentRemoteTokenProviderError)] = [
      (
        .init(statusCode: 401, body: Data(#"{"error":"rejected"}"#.utf8)),
        .authenticationFailed
      ),
      (
        .init(
          statusCode: 429,
          body: Data(#"{"error":"rate_limited"}"#.utf8),
          headerFields: [
            "Content-Type": "application/json",
            "Retry-After": "9",
          ]
        ),
        .rateLimited(retryAfter: 9)
      ),
      (
        .init(statusCode: 503, body: Data(#"{"error":"service_unavailable"}"#.utf8)),
        .temporarilyUnavailable
      ),
    ]

    for (response, expectedError) in cases {
      let error = await providerError(
        challenge: .init(statusCode: 200, body: validChallengeBody()),
        exchange: response
      )
      XCTAssertEqual(error, expectedError)
    }
  }

  func testNetworkAndMalformedChallengeResponsesAreNotReportedAsBadInstallations() async throws {
    let networkError = await providerError(
      challenge: .init(error: URLError(.notConnectedToInternet))
    )
    XCTAssertEqual(networkError, .temporarilyUnavailable)

    let malformedError = await providerError(
      challenge: .init(statusCode: 200, body: Data(#"{"protocolVersion":1}"#.utf8))
    )
    XCTAssertEqual(malformedError, .malformedResponse)
  }

  func testSuccessfulChallengeAndExchangeProduceBearerToken() async throws {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let exchangeURL = attestationURL(named: "exchange", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [.init(statusCode: 200, body: validChallengeBody())]
    )
    let exchangePlan = AskIAgentRemoteURLProtocolStub.install(
      for: exchangeURL,
      responses: [.init(statusCode: 200, body: validExchangeBody())]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
    }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let provider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: TestAskIAgentInstallationKeyStore(),
      appAttest: TestAskIAgentAppAttestService()
    )

    let header = try await provider.authorizationHeader(
      for: Data(#"{"prompt":"hello"}"#.utf8),
      relayURL: relayURL
    )

    XCTAssertEqual(header, "Bearer short-lived-token")
    XCTAssertEqual(challengePlan.requests.count, 1)
    XCTAssertEqual(exchangePlan.requests.count, 1)
    XCTAssertEqual(
      challengePlan.requests.first?.value(forHTTPHeaderField: "X-iAgent-Relay-Protocol"),
      "1"
    )
    XCTAssertEqual(
      exchangePlan.requests.first?.value(forHTTPHeaderField: "X-iAgent-Relay-Protocol"),
      "1"
    )
  }

  func testInvalidAppAttestKeyRotatesTheWholeIdentityAndRetriesAsAttestation() async throws {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let exchangeURL = attestationURL(named: "exchange", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [
        .init(statusCode: 200, body: validChallengeBody(id: "old-key", mode: "assertion")),
        .init(
          statusCode: 200,
          body: validChallengeBody(id: "replacement-key", mode: "attestation")
        ),
      ]
    )
    let exchangePlan = AskIAgentRemoteURLProtocolStub.install(
      for: exchangeURL,
      responses: [.init(statusCode: 200, body: validExchangeBody())]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
    }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = RotatingAskIAgentInstallationKeyStore()
    let appAttest = SequencedAskIAgentAppAttestService(invalidAssertion: true)
    let provider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )

    let header = try await provider.authorizationHeader(
      for: Data(#"{"prompt":"hello"}"#.utf8),
      relayURL: relayURL
    )

    XCTAssertEqual(header, "Bearer short-lived-token")
    XCTAssertEqual(store.rotationCount(), 1)
    let generatedKeyCount = await appAttest.generatedKeyCount
    let assertionCount = await appAttest.assertionCount
    let attestationCount = await appAttest.attestationCount
    XCTAssertEqual(generatedKeyCount, 1)
    XCTAssertEqual(assertionCount, 1)
    XCTAssertEqual(attestationCount, 1)
    XCTAssertEqual(challengePlan.requests.count, 2)
    XCTAssertEqual(exchangePlan.requests.count, 1)

    let firstChallenge = try requestBody(challengePlan.requests[0])
    XCTAssertEqual(firstChallenge["assurance"] as? String, "app_attest")
    XCTAssertEqual(firstChallenge["installationID"] as? String, "old-installation-id")
    XCTAssertEqual(firstChallenge["keyID"] as? String, "old-app-attest-key")

    let replacementChallenge = try requestBody(challengePlan.requests[1])
    XCTAssertEqual(replacementChallenge["assurance"] as? String, "app_attest")
    XCTAssertEqual(
      replacementChallenge["installationID"] as? String,
      "replacement-installation-id"
    )
    XCTAssertEqual(replacementChallenge["keyID"] as? String, "replacement-app-attest-key")

    let replacementExchange = try requestBody(exchangePlan.requests[0])
    XCTAssertEqual(replacementExchange["installationID"] as? String, "replacement-installation-id")
    XCTAssertEqual(replacementExchange["keyID"] as? String, "replacement-app-attest-key")
    XCTAssertEqual(replacementExchange["artifactType"] as? String, "attestation")
  }

  func testLegacyIdentityBindingMismatchRotatesOnceAndReattestsTheNewIdentity() async throws {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let exchangeURL = attestationURL(named: "exchange", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [
        .init(statusCode: 401, body: identityBindingMismatchBody()),
        .init(
          statusCode: 200,
          body: validChallengeBody(id: "replacement-key", mode: "attestation")
        ),
      ]
    )
    let exchangePlan = AskIAgentRemoteURLProtocolStub.install(
      for: exchangeURL,
      responses: [.init(statusCode: 200, body: validExchangeBody())]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
    }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = RotatingAskIAgentInstallationKeyStore()
    let appAttest = SequencedAskIAgentAppAttestService()
    let provider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )

    let header = try await provider.authorizationHeader(
      for: Data(#"{"prompt":"hello"}"#.utf8),
      relayURL: relayURL
    )

    XCTAssertEqual(header, "Bearer short-lived-token")
    XCTAssertEqual(store.rotationCount(), 1)
    XCTAssertEqual(store.currentInstallationID(), "replacement-installation-id")
    XCTAssertEqual(store.currentKeyID(), "replacement-app-attest-key")
    XCTAssertEqual(challengePlan.requests.count, 2)
    XCTAssertEqual(exchangePlan.requests.count, 1)
    let generatedKeyCount = await appAttest.generatedKeyCount
    let assertionCount = await appAttest.assertionCount
    let attestationCount = await appAttest.attestationCount
    XCTAssertEqual(generatedKeyCount, 1)
    XCTAssertEqual(assertionCount, 0)
    XCTAssertEqual(attestationCount, 1)

    let firstChallenge = try requestBody(challengePlan.requests[0])
    XCTAssertEqual(firstChallenge["installationID"] as? String, "old-installation-id")
    XCTAssertEqual(firstChallenge["keyID"] as? String, "old-app-attest-key")
    let replacementChallenge = try requestBody(challengePlan.requests[1])
    XCTAssertEqual(
      replacementChallenge["installationID"] as? String,
      "replacement-installation-id"
    )
    XCTAssertEqual(replacementChallenge["keyID"] as? String, "replacement-app-attest-key")
    let replacementExchange = try requestBody(exchangePlan.requests[0])
    XCTAssertEqual(replacementExchange["artifactType"] as? String, "attestation")
    XCTAssertEqual(replacementExchange["installationID"] as? String, "replacement-installation-id")
    XCTAssertEqual(replacementExchange["keyID"] as? String, "replacement-app-attest-key")
  }

  func testDevelopmentEnvironmentMismatchRotatesOnceAndSuccessfulReattestationClearsBudget()
    async throws
  {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let exchangeURL = attestationURL(named: "exchange", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [
        .init(statusCode: 200, body: validChallengeBody(id: "development-key", mode: "attestation")),
        .init(statusCode: 200, body: validChallengeBody(id: "production-key", mode: "attestation")),
      ]
    )
    let exchangePlan = AskIAgentRemoteURLProtocolStub.install(
      for: exchangeURL,
      responses: [
        .init(statusCode: 401, body: environmentMismatchBody()),
        .init(statusCode: 200, body: validExchangeBody()),
      ]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
    }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = RotatingAskIAgentInstallationKeyStore()
    let appAttest = SequencedAskIAgentAppAttestService()
    let provider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )

    let header = try await provider.authorizationHeader(
      for: Data(#"{"prompt":"hello"}"#.utf8),
      relayURL: relayURL
    )

    XCTAssertEqual(header, "Bearer short-lived-token")
    XCTAssertEqual(store.rotationCount(), 1)
    XCTAssertNil(store.currentEnvironmentRecoveryGeneration())
    XCTAssertEqual(challengePlan.requests.count, 2)
    XCTAssertEqual(exchangePlan.requests.count, 2)
    let generatedKeyCount = await appAttest.generatedKeyCount
    let attestationCount = await appAttest.attestationCount
    let assertionCount = await appAttest.assertionCount
    XCTAssertEqual(generatedKeyCount, 1)
    XCTAssertEqual(attestationCount, 2)
    XCTAssertEqual(assertionCount, 0)

    let firstExchange = try requestBody(exchangePlan.requests[0])
    let replacementExchange = try requestBody(exchangePlan.requests[1])
    XCTAssertEqual(firstExchange["installationID"] as? String, "old-installation-id")
    XCTAssertEqual(firstExchange["keyID"] as? String, "old-app-attest-key")
    XCTAssertEqual(
      replacementExchange["installationID"] as? String,
      "replacement-installation-id"
    )
    XCTAssertEqual(replacementExchange["keyID"] as? String, "replacement-app-attest-key")
    XCTAssertEqual(replacementExchange["artifactType"] as? String, "attestation")
  }

  func testRepeatedEnvironmentMismatchAcrossCallsCannotChurnInstallationIdentity() async throws {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let exchangeURL = attestationURL(named: "exchange", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [
        .init(statusCode: 200, body: validChallengeBody(id: "development-key", mode: "attestation")),
        .init(statusCode: 200, body: validChallengeBody(id: "replacement-key", mode: "attestation")),
        .init(statusCode: 200, body: validChallengeBody(id: "later-retry", mode: "attestation")),
      ]
    )
    let exchangePlan = AskIAgentRemoteURLProtocolStub.install(
      for: exchangeURL,
      responses: [
        .init(statusCode: 401, body: environmentMismatchBody()),
        .init(statusCode: 401, body: environmentMismatchBody()),
        .init(statusCode: 401, body: environmentMismatchBody()),
      ]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
    }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = RotatingAskIAgentInstallationKeyStore()
    let appAttest = SequencedAskIAgentAppAttestService()
    let provider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )

    for prompt in ["first", "later"] {
      do {
        _ = try await provider.authorizationHeader(
          for: Data(#"{"prompt":"\#(prompt)"}"#.utf8),
          relayURL: relayURL
        )
        XCTFail("Expected the development App Attest key to be rejected.")
      } catch let error as AskIAgentRemoteTokenProviderError {
        XCTAssertEqual(error, .authenticationFailed)
      }
    }

    XCTAssertEqual(store.rotationCount(), 1)
    XCTAssertEqual(store.currentEnvironmentRecoveryGeneration(), 1)
    XCTAssertEqual(store.currentInstallationID(), "replacement-installation-id")
    XCTAssertEqual(store.currentKeyID(), "replacement-app-attest-key")
    XCTAssertEqual(challengePlan.requests.count, 3)
    XCTAssertEqual(exchangePlan.requests.count, 3)
    let generatedKeyCount = await appAttest.generatedKeyCount
    let attestationCount = await appAttest.attestationCount
    let assertionCount = await appAttest.assertionCount
    XCTAssertEqual(generatedKeyCount, 1)
    XCTAssertEqual(attestationCount, 3)
    XCTAssertEqual(assertionCount, 0)
    let assurances = try exchangePlan.requests.map(requestBody)
      .compactMap { $0["assurance"] as? String }
    XCTAssertEqual(assurances, ["app_attest", "app_attest", "app_attest"])
  }

  func testEnvironmentRecoveryJournalResumesAfterCancellationBeforeIdentityCommit() async throws {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let exchangeURL = attestationURL(named: "exchange", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [
        .init(statusCode: 200, body: validChallengeBody(id: "development", mode: "attestation")),
        .init(statusCode: 200, body: validChallengeBody(id: "resumed", mode: "attestation")),
      ]
    )
    let exchangePlan = AskIAgentRemoteURLProtocolStub.install(
      for: exchangeURL,
      responses: [
        .init(statusCode: 401, body: environmentMismatchBody()),
        .init(statusCode: 200, body: validExchangeBody()),
      ]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
    }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = CrashResumableAskIAgentInstallationKeyStore(failure: .afterJournalOnce)
    let appAttest = SequencedAskIAgentAppAttestService()
    let firstProvider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )

    do {
      _ = try await firstProvider.authorizationHeader(
        for: Data(#"{"prompt":"cancelled"}"#.utf8),
        relayURL: relayURL
      )
      XCTFail("Expected the injected post-journal cancellation.")
    } catch is CancellationError {
      // The replacement is durable but deliberately not committed by the interrupted call.
    }
    XCTAssertEqual(store.journalWriteAttemptCount(), 1)
    XCTAssertEqual(store.identityCommitCount(), 0)
    XCTAssertEqual(store.currentEnvironmentRecoveryGeneration(), 1)

    // A fresh provider models the next process. Its first identity read resumes the exact journaled
    // replacement rather than consuming the recovery or generating a second replacement.
    let resumedProvider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )
    let header = try await resumedProvider.authorizationHeader(
      for: Data(#"{"prompt":"resumed"}"#.utf8),
      relayURL: relayURL
    )

    XCTAssertEqual(header, "Bearer short-lived-token")
    XCTAssertEqual(store.journalWriteAttemptCount(), 1)
    XCTAssertEqual(store.identityCommitCount(), 1)
    XCTAssertNil(store.currentEnvironmentRecoveryGeneration())
    XCTAssertEqual(challengePlan.requests.count, 2)
    XCTAssertEqual(exchangePlan.requests.count, 2)
    let resumedChallenge = try requestBody(challengePlan.requests[1])
    XCTAssertEqual(
      resumedChallenge["installationID"] as? String,
      "journaled-replacement-installation-id"
    )
    XCTAssertEqual(resumedChallenge["keyID"] as? String, "replacement-app-attest-key")
  }

  func testEnvironmentRecoveryJournalWriteFailureLeavesManualRetryEligible() async throws {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let exchangeURL = attestationURL(named: "exchange", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [
        .init(statusCode: 200, body: validChallengeBody(id: "first", mode: "attestation")),
        .init(statusCode: 200, body: validChallengeBody(id: "retry", mode: "attestation")),
        .init(statusCode: 200, body: validChallengeBody(id: "replacement", mode: "attestation")),
      ]
    )
    let exchangePlan = AskIAgentRemoteURLProtocolStub.install(
      for: exchangeURL,
      responses: [
        .init(statusCode: 401, body: environmentMismatchBody()),
        .init(statusCode: 401, body: environmentMismatchBody()),
        .init(statusCode: 200, body: validExchangeBody()),
      ]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
    }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = CrashResumableAskIAgentInstallationKeyStore(failure: .beforeJournalOnce)
    let appAttest = SequencedAskIAgentAppAttestService()
    let provider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )

    do {
      _ = try await provider.authorizationHeader(
        for: Data(#"{"prompt":"first"}"#.utf8),
        relayURL: relayURL
      )
      XCTFail("Expected the injected journal write failure.")
    } catch let error as AskIAgentRemoteTokenProviderError {
      XCTAssertEqual(error, .temporarilyUnavailable)
    }
    XCTAssertEqual(store.journalWriteAttemptCount(), 1)
    XCTAssertEqual(store.identityCommitCount(), 0)
    XCTAssertNil(store.currentEnvironmentRecoveryGeneration())

    let header = try await provider.authorizationHeader(
      for: Data(#"{"prompt":"retry"}"#.utf8),
      relayURL: relayURL
    )
    XCTAssertEqual(header, "Bearer short-lived-token")
    XCTAssertEqual(store.journalWriteAttemptCount(), 2)
    XCTAssertEqual(store.identityCommitCount(), 1)
    XCTAssertNil(store.currentEnvironmentRecoveryGeneration())
    XCTAssertEqual(challengePlan.requests.count, 3)
    XCTAssertEqual(exchangePlan.requests.count, 3)
  }

  func testEnvironmentMismatchRecoveryEnvelopeIsExactAndExchangeScoped() async throws {
    let challengeRelayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: challengeRelayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [.init(statusCode: 401, body: environmentMismatchBody())]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let challengeStore = RotatingAskIAgentInstallationKeyStore()
    let challengeProvider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: challengeStore,
      appAttest: SequencedAskIAgentAppAttestService()
    )
    do {
      _ = try await challengeProvider.authorizationHeader(
        for: Data(#"{"prompt":"challenge"}"#.utf8),
        relayURL: challengeRelayURL
      )
      XCTFail("Expected challenge authentication to fail.")
    } catch let error as AskIAgentRemoteTokenProviderError {
      XCTAssertEqual(error, .authenticationFailed)
    }
    XCTAssertEqual(challengeStore.rotationCount(), 0)

    let exchangeRelayURL = try makeRelayURL()
    let exchangeChallengeURL = attestationURL(named: "challenge", relayURL: exchangeRelayURL)
    let exchangeURL = attestationURL(named: "exchange", relayURL: exchangeRelayURL)
    _ = AskIAgentRemoteURLProtocolStub.install(
      for: exchangeChallengeURL,
      responses: [
        .init(statusCode: 200, body: validChallengeBody(mode: "attestation")),
      ]
    )
    _ = AskIAgentRemoteURLProtocolStub.install(
      for: exchangeURL,
      responses: [
        .init(
          statusCode: 401,
          body: Data(
            #"{"error":"unauthorized","code":"app_attest_environment_mismatch","detail":"spoof"}"#.utf8
          )
        ),
      ]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeChallengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
    }
    let exchangeStore = RotatingAskIAgentInstallationKeyStore()
    let exchangeProvider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: exchangeStore,
      appAttest: SequencedAskIAgentAppAttestService()
    )
    do {
      _ = try await exchangeProvider.authorizationHeader(
        for: Data(#"{"prompt":"exchange"}"#.utf8),
        relayURL: exchangeRelayURL
      )
      XCTFail("Expected exchange authentication to fail.")
    } catch let error as AskIAgentRemoteTokenProviderError {
      XCTAssertEqual(error, .authenticationFailed)
    }
    XCTAssertEqual(exchangeStore.rotationCount(), 0)
    XCTAssertNil(exchangeStore.currentEnvironmentRecoveryGeneration())
  }

  func testGenericChallenge401PreservesTheInstallationIdentity() async throws {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [
        .init(statusCode: 401, body: Data(#"{"error":"unauthorized"}"#.utf8)),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = RotatingAskIAgentInstallationKeyStore()
    let appAttest = SequencedAskIAgentAppAttestService()
    let provider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )

    do {
      _ = try await provider.authorizationHeader(
        for: Data(#"{"prompt":"hello"}"#.utf8),
        relayURL: relayURL
      )
      XCTFail("Expected the generic challenge rejection to fail.")
    } catch let error as AskIAgentRemoteTokenProviderError {
      XCTAssertEqual(error, .authenticationFailed)
    }

    XCTAssertEqual(store.rotationCount(), 0)
    XCTAssertEqual(store.currentInstallationID(), "old-installation-id")
    XCTAssertEqual(store.currentKeyID(), "old-app-attest-key")
    XCTAssertEqual(challengePlan.requests.count, 1)
    let generatedKeyCount = await appAttest.generatedKeyCount
    XCTAssertEqual(generatedKeyCount, 0)
  }

  func testRepeatedIdentityBindingMismatchCannotRotateMoreThanOnce() async throws {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [
        .init(statusCode: 401, body: identityBindingMismatchBody()),
        .init(statusCode: 401, body: identityBindingMismatchBody()),
      ]
    )
    defer { AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL) }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = RotatingAskIAgentInstallationKeyStore()
    let appAttest = SequencedAskIAgentAppAttestService()
    let provider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )

    do {
      _ = try await provider.authorizationHeader(
        for: Data(#"{"prompt":"hello"}"#.utf8),
        relayURL: relayURL
      )
      XCTFail("Expected the replacement identity to be rejected.")
    } catch let error as AskIAgentRemoteTokenProviderError {
      XCTAssertEqual(error, .authenticationFailed)
    }

    XCTAssertEqual(store.rotationCount(), 1)
    XCTAssertEqual(store.currentInstallationID(), "replacement-installation-id")
    XCTAssertEqual(store.currentKeyID(), "replacement-app-attest-key")
    XCTAssertEqual(challengePlan.requests.count, 2)
    let generatedKeyCount = await appAttest.generatedKeyCount
    let assertionCount = await appAttest.assertionCount
    let attestationCount = await appAttest.attestationCount
    XCTAssertEqual(generatedKeyCount, 1)
    XCTAssertEqual(assertionCount, 0)
    XCTAssertEqual(attestationCount, 0)
  }

  func testAReplacementInvalidKeyCannotCauseMoreThanOneIdentityRotation() async throws {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let exchangeURL = attestationURL(named: "exchange", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [
        .init(statusCode: 200, body: validChallengeBody(id: "old-key", mode: "assertion")),
        .init(
          statusCode: 200,
          body: validChallengeBody(id: "replacement-key", mode: "attestation")
        ),
      ]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
    }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = RotatingAskIAgentInstallationKeyStore()
    let appAttest = SequencedAskIAgentAppAttestService(
      invalidAssertion: true,
      invalidAttestation: true
    )
    let provider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )

    do {
      _ = try await provider.authorizationHeader(
        for: Data(#"{"prompt":"hello"}"#.utf8),
        relayURL: relayURL
      )
      XCTFail("Expected the replacement key to fail.")
    } catch let error as AskIAgentRemoteTokenProviderError {
      XCTAssertEqual(error, .authenticationFailed)
    }

    XCTAssertEqual(store.rotationCount(), 1)
    let generatedKeyCount = await appAttest.generatedKeyCount
    XCTAssertEqual(generatedKeyCount, 1)
    XCTAssertEqual(challengePlan.requests.count, 2)
  }

  func testExchangeAuthenticationFailureDoesNotDestroyAValidInstallationIdentity() async throws {
    let relayURL = try makeRelayURL()
    let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
    let exchangeURL = attestationURL(named: "exchange", relayURL: relayURL)
    let challengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: challengeURL,
      responses: [.init(statusCode: 200, body: validChallengeBody())]
    )
    _ = AskIAgentRemoteURLProtocolStub.install(
      for: exchangeURL,
      responses: [.init(statusCode: 401, body: identityBindingMismatchBody())]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
    }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = RotatingAskIAgentInstallationKeyStore()
    let provider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: SequencedAskIAgentAppAttestService()
    )

    do {
      _ = try await provider.authorizationHeader(
        for: Data(#"{"prompt":"hello"}"#.utf8),
        relayURL: relayURL
      )
      XCTFail("Expected exchange authentication to fail.")
    } catch let error as AskIAgentRemoteTokenProviderError {
      XCTAssertEqual(error, .authenticationFailed)
    }

    XCTAssertEqual(store.rotationCount(), 0)
    XCTAssertEqual(challengePlan.requests.count, 1)
  }

  func testOverlappingInvalidKeyRecoveryCommitsOneIdentityAndFutureAuthUsesIt() async throws {
    let firstRelayURL = try makeRelayURL()
    let secondRelayURL = try makeRelayURL()
    let firstChallengeURL = attestationURL(named: "challenge", relayURL: firstRelayURL)
    let firstExchangeURL = attestationURL(named: "exchange", relayURL: firstRelayURL)
    let secondChallengeURL = attestationURL(named: "challenge", relayURL: secondRelayURL)
    let secondExchangeURL = attestationURL(named: "exchange", relayURL: secondRelayURL)
    let firstChallengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: firstChallengeURL,
      responses: [
        .init(statusCode: 200, body: validChallengeBody(id: "old-key", mode: "assertion")),
        .init(
          statusCode: 200,
          body: validChallengeBody(id: "replacement-attestation", mode: "attestation")
        ),
        .init(
          statusCode: 200,
          body: validChallengeBody(id: "future-assertion", mode: "assertion")
        ),
      ]
    )
    let firstExchangePlan = AskIAgentRemoteURLProtocolStub.install(
      for: firstExchangeURL,
      responses: [
        .init(statusCode: 200, body: validExchangeBody()),
        .init(statusCode: 200, body: validExchangeBody()),
      ]
    )
    // If provider B could overlap the old-key transaction, its first assertion would also raise
    // invalidKey and this second attestation response would let the counterfactual race finish.
    // With the gate, B never consumes that recovery response because it observes the committed key.
    let secondChallengePlan = AskIAgentRemoteURLProtocolStub.install(
      for: secondChallengeURL,
      responses: [
        .init(statusCode: 200, body: validChallengeBody(id: "queued-assertion", mode: "assertion")),
        .init(
          statusCode: 200,
          body: validChallengeBody(id: "racing-attestation", mode: "attestation")
        ),
      ]
    )
    let secondExchangePlan = AskIAgentRemoteURLProtocolStub.install(
      for: secondExchangeURL,
      responses: [
        .init(statusCode: 200, body: validExchangeBody()),
      ]
    )
    defer {
      AskIAgentRemoteURLProtocolStub.removePlan(for: firstChallengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: firstExchangeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: secondChallengeURL)
      AskIAgentRemoteURLProtocolStub.removePlan(for: secondExchangeURL)
    }
    let session = remoteStubSession()
    defer { session.invalidateAndCancel() }
    let store = RotatingAskIAgentInstallationKeyStore()
    let appAttest = OverlappingInvalidKeyAskIAgentAppAttestService()
    // Two providers model a brief presentation handoff. The identity is process-global, so the
    // critical section must extend beyond either provider actor's own isolation.
    let firstProvider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )
    let secondProvider = AskIAgentRemoteTokenProvider(
      session: session,
      keychain: store,
      appAttest: appAttest
    )

    let first = Task {
      try await firstProvider.authorizationHeader(
        for: Data(#"{"prompt":"first"}"#.utf8),
        relayURL: firstRelayURL
      )
    }
    try await waitForSuspendedInvalidAssertion(appAttest)

    let secondStarted = AskIAgentTokenProviderTestSignal()
    let second = Task {
      await secondStarted.signal()
      return try await secondProvider.authorizationHeader(
        for: Data(#"{"prompt":"second"}"#.utf8),
        relayURL: secondRelayURL
      )
    }
    await secondStarted.wait()
    try await Task.sleep(for: .milliseconds(50))

    // The second provider has started, but cannot read or mutate the shared identity, request a
    // replacement challenge, or supersede the first challenge while recovery is suspended.
    XCTAssertEqual(firstChallengePlan.requests.count, 1)
    XCTAssertEqual(secondChallengePlan.requests.count, 0)
    XCTAssertEqual(store.installationReadCount(), 1)

    await appAttest.releaseInvalidAssertion()
    let firstHeader = try await first.value
    let secondHeader = try await second.value
    let futureHeader = try await secondProvider.authorizationHeader(
      for: Data(#"{"prompt":"future"}"#.utf8),
      relayURL: firstRelayURL
    )
    XCTAssertEqual(firstHeader, "Bearer short-lived-token")
    XCTAssertEqual(secondHeader, "Bearer short-lived-token")
    XCTAssertEqual(futureHeader, "Bearer short-lived-token")

    XCTAssertEqual(store.rotationCount(), 1)
    XCTAssertEqual(store.currentInstallationID(), "replacement-installation-id")
    XCTAssertEqual(store.currentKeyID(), "replacement-app-attest-key")
    XCTAssertEqual(firstChallengePlan.requests.count, 3)
    XCTAssertEqual(firstExchangePlan.requests.count, 2)
    XCTAssertEqual(secondChallengePlan.requests.count, 1)
    XCTAssertEqual(secondExchangePlan.requests.count, 1)
    let generatedKeyCount = await appAttest.generatedKeyCount
    let assertionCount = await appAttest.assertionCount
    let attestationCount = await appAttest.attestationCount
    XCTAssertEqual(generatedKeyCount, 1)
    XCTAssertEqual(assertionCount, 3)
    XCTAssertEqual(attestationCount, 1)

    let firstChallenges = try firstChallengePlan.requests.map(requestBody)
    XCTAssertEqual(
      firstChallenges.compactMap { $0["installationID"] as? String },
      [
        "old-installation-id",
        "replacement-installation-id",
        "replacement-installation-id",
      ]
    )
    XCTAssertEqual(
      firstChallenges.compactMap { $0["keyID"] as? String },
      [
        "old-app-attest-key",
        "replacement-app-attest-key",
        "replacement-app-attest-key",
      ]
    )
    XCTAssertTrue(firstChallenges.allSatisfy { $0["assurance"] as? String == "app_attest" })
    let secondChallenge = try requestBody(XCTUnwrap(secondChallengePlan.requests.first))
    XCTAssertEqual(secondChallenge["installationID"] as? String, "replacement-installation-id")
    XCTAssertEqual(secondChallenge["keyID"] as? String, "replacement-app-attest-key")
    XCTAssertEqual(secondChallenge["assurance"] as? String, "app_attest")

    let firstExchanges = try firstExchangePlan.requests.map(requestBody)
    XCTAssertEqual(
      firstExchanges.compactMap { $0["artifactType"] as? String },
      ["attestation", "assertion"]
    )
    XCTAssertTrue(firstExchanges.allSatisfy { $0["assurance"] as? String == "app_attest" })
    let secondExchange = try requestBody(XCTUnwrap(secondExchangePlan.requests.first))
    XCTAssertEqual(secondExchange["artifactType"] as? String, "assertion")
    XCTAssertEqual(secondExchange["assurance"] as? String, "app_attest")
  }

  private func waitForSuspendedInvalidAssertion(
    _ appAttest: OverlappingInvalidKeyAskIAgentAppAttestService
  ) async throws {
    for _ in 0..<200 {
      if await appAttest.isInvalidAssertionSuspended { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the controlled invalid-key assertion.")
  }

  private func providerError(
    challenge: AskIAgentRemoteURLProtocolPlan.Response,
    exchange: AskIAgentRemoteURLProtocolPlan.Response? = nil
  ) async -> AskIAgentRemoteTokenProviderError? {
    do {
      let relayURL = try makeRelayURL()
      let challengeURL = attestationURL(named: "challenge", relayURL: relayURL)
      let exchangeURL = attestationURL(named: "exchange", relayURL: relayURL)
      _ = AskIAgentRemoteURLProtocolStub.install(for: challengeURL, responses: [challenge])
      if let exchange {
        _ = AskIAgentRemoteURLProtocolStub.install(for: exchangeURL, responses: [exchange])
      }
      defer {
        AskIAgentRemoteURLProtocolStub.removePlan(for: challengeURL)
        AskIAgentRemoteURLProtocolStub.removePlan(for: exchangeURL)
      }
      let session = remoteStubSession()
      defer { session.invalidateAndCancel() }
      let provider = AskIAgentRemoteTokenProvider(
        session: session,
        keychain: TestAskIAgentInstallationKeyStore(),
        appAttest: TestAskIAgentAppAttestService()
      )

      _ = try await provider.authorizationHeader(
        for: Data(#"{"prompt":"hello"}"#.utf8),
        relayURL: relayURL
      )
      XCTFail("Expected the token provider to fail.")
      return nil
    } catch let error as AskIAgentRemoteTokenProviderError {
      return error
    } catch {
      XCTFail("Expected a typed token-provider failure, got \(error).")
      return nil
    }
  }

  private func makeRelayURL() throws -> URL {
    try XCTUnwrap(URL(string: "https://relay.invalid/\(UUID().uuidString)/ask"))
  }

  private func attestationURL(named name: String, relayURL: URL) -> URL {
    relayURL.deletingLastPathComponent()
      .appendingPathComponent("attestation", isDirectory: true)
      .appendingPathComponent(name, isDirectory: false)
  }

  private func validChallengeBody(
    id: String = "challenge-id",
    mode: String = "assertion"
  ) -> Data {
    let expiresAt = Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1_000)
    return try! JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 1,
        "challengeID": id,
        "mode": mode,
        "clientData": "Y2xpZW50LWRhdGE",
        "expiresAt": expiresAt,
      ],
      options: [.sortedKeys]
    )
  }

  private func validExchangeBody() -> Data {
    let expiresAt = Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1_000)
    return try! JSONSerialization.data(
      withJSONObject: [
        "protocolVersion": 1,
        "token": "short-lived-token",
        "expiresAt": expiresAt,
        "assurance": "app_attest",
      ],
      options: [.sortedKeys]
    )
  }

  private func identityBindingMismatchBody() -> Data {
    Data(
      #"{"error":"unauthorized","code":"app_attest_identity_binding_mismatch"}"#.utf8
    )
  }

  private func environmentMismatchBody() -> Data {
    Data(
      #"{"error":"unauthorized","code":"app_attest_environment_mismatch"}"#.utf8
    )
  }

  private func remoteStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AskIAgentRemoteURLProtocolStub.self]
    return URLSession(configuration: configuration)
  }

  private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

private actor CancelThenFailAskIAgentGenerator: AskIAgentGenerating {
  private var recordedRequests: [AskIAgentGenerationRequest] = []

  nonisolated func availability(localeIdentifier _: String) -> AskIAgentAvailability { .available }

  func generate(
    request: AskIAgentGenerationRequest,
    progress _: @escaping @Sendable (AskIAgentWorkStage) -> Void
  ) async throws -> AskIAgentGeneratorOutput {
    recordedRequests.append(request)
    if recordedRequests.count == 1 {
      try await Task.sleep(for: .seconds(30))
      throw CancellationError()
    }
    throw AskIAgentFailure(reason: .remoteAuthenticationFailed)
  }

  func requests() -> [AskIAgentGenerationRequest] { recordedRequests }
}

private actor StaleCompletionAskIAgentGenerator: AskIAgentGenerating {
  private var continuation: CheckedContinuation<Void, Never>?

  nonisolated func availability(localeIdentifier _: String) -> AskIAgentAvailability { .available }

  var isFirstRequestSuspended: Bool { continuation != nil }

  func generate(
    request: AskIAgentGenerationRequest,
    progress _: @escaping @Sendable (AskIAgentWorkStage) -> Void
  ) async throws -> AskIAgentGeneratorOutput {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
    return AskIAgentGeneratorOutput(
      claims: [
        AskIAgentGeneratedClaim(
          text: "This completion arrived after cancellation.",
          evidenceIDs: request.evidence.map(\.id)
        )
      ],
      evidence: request.evidence
    )
  }

  func releaseFirstRequest() {
    let pending = continuation
    continuation = nil
    pending?.resume()
  }
}

private struct ThrowingAskIAgentRemoteTokenProvider: AskIAgentRemoteTokenProviding {
  let error: AskIAgentRemoteTokenProviderError

  func authorizationHeader(for _: Data, relayURL _: URL) async throws -> String {
    throw error
  }
}

private final class TestAskIAgentInstallationKeyStore: AskIAgentInstallationKeyStoring,
  @unchecked Sendable
{
  func installationID() throws -> String { "test-installation-id" }
  func appAttestKeyID() throws -> String? { "existing-app-attest-key" }
  func setAppAttestKeyID(_: String?) throws {}
  func resumeOrStartAppAttestEnvironmentRecovery(generation _: Int) throws -> String? {
    "rotated-test-installation-id"
  }
  func clearAppAttestEnvironmentRecovery(generation _: Int) throws {}
  func rotateInstallationIdentity() throws -> String { "rotated-test-installation-id" }
}

private final class RotatingAskIAgentInstallationKeyStore: AskIAgentInstallationKeyStoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storedInstallationID = "old-installation-id"
  private var storedKeyID: String? = "old-app-attest-key"
  private var rotations = 0
  private var installationReads = 0
  private var environmentRecoveryGeneration: Int?

  func installationID() throws -> String {
    lock.withLock {
      installationReads += 1
      return storedInstallationID
    }
  }

  func appAttestKeyID() throws -> String? {
    lock.withLock { storedKeyID }
  }

  func setAppAttestKeyID(_ keyID: String?) throws {
    lock.withLock { storedKeyID = keyID }
  }

  func resumeOrStartAppAttestEnvironmentRecovery(generation: Int) throws -> String? {
    lock.withLock {
      guard environmentRecoveryGeneration.map({ $0 < generation }) ?? true else { return nil }
      environmentRecoveryGeneration = generation
      rotations += 1
      storedInstallationID = "replacement-installation-id"
      storedKeyID = nil
      return storedInstallationID
    }
  }

  func clearAppAttestEnvironmentRecovery(generation: Int) throws {
    lock.withLock {
      guard environmentRecoveryGeneration == generation else { return }
      environmentRecoveryGeneration = nil
    }
  }

  func rotateInstallationIdentity() throws -> String {
    lock.withLock {
      rotations += 1
      storedInstallationID = "replacement-installation-id"
      storedKeyID = nil
      return storedInstallationID
    }
  }

  func rotationCount() -> Int {
    lock.withLock { rotations }
  }

  func installationReadCount() -> Int {
    lock.withLock { installationReads }
  }

  func currentInstallationID() -> String {
    lock.withLock { storedInstallationID }
  }

  func currentKeyID() -> String? {
    lock.withLock { storedKeyID }
  }

  func currentEnvironmentRecoveryGeneration() -> Int? {
    lock.withLock { environmentRecoveryGeneration }
  }
}

private final class CrashResumableAskIAgentInstallationKeyStore:
  AskIAgentInstallationKeyStoring, @unchecked Sendable
{
  enum InjectedFailure: Equatable {
    case beforeJournalOnce
    case afterJournalOnce
  }

  private enum TestFailure: Error {
    case journalWriteFailed
  }

  private let lock = NSLock()
  private var storedInstallationID = "old-installation-id"
  private var storedKeyID: String? = "old-app-attest-key"
  private var journalGeneration: Int?
  private var journalReplacement: String?
  private var journalWriteAttempts = 0
  private var identityCommits = 0
  private var injectedFailure: InjectedFailure?

  init(failure: InjectedFailure) {
    injectedFailure = failure
  }

  func installationID() throws -> String {
    lock.withLock {
      finishJournaledRecoveryIfNeeded()
      return storedInstallationID
    }
  }

  func appAttestKeyID() throws -> String? {
    lock.withLock {
      finishJournaledRecoveryIfNeeded()
      return storedKeyID
    }
  }

  func setAppAttestKeyID(_ keyID: String?) throws {
    lock.withLock {
      finishJournaledRecoveryIfNeeded()
      storedKeyID = keyID
    }
  }

  func resumeOrStartAppAttestEnvironmentRecovery(generation: Int) throws -> String? {
    try lock.withLock {
      if journalGeneration == generation,
        let journalReplacement
      {
        guard storedInstallationID != journalReplacement else { return nil }
        finishJournaledRecoveryIfNeeded()
        return journalReplacement
      }
      journalWriteAttempts += 1
      if injectedFailure == .beforeJournalOnce {
        injectedFailure = nil
        throw TestFailure.journalWriteFailed
      }
      let replacement = "journaled-replacement-installation-id"
      journalGeneration = generation
      journalReplacement = replacement
      if injectedFailure == .afterJournalOnce {
        injectedFailure = nil
        throw CancellationError()
      }
      finishJournaledRecoveryIfNeeded()
      return replacement
    }
  }

  func clearAppAttestEnvironmentRecovery(generation: Int) throws {
    lock.withLock {
      guard journalGeneration == generation else { return }
      journalGeneration = nil
      journalReplacement = nil
    }
  }

  func rotateInstallationIdentity() throws -> String {
    lock.withLock {
      storedInstallationID = "ordinary-replacement-installation-id"
      storedKeyID = nil
      identityCommits += 1
      return storedInstallationID
    }
  }

  func journalWriteAttemptCount() -> Int {
    lock.withLock { journalWriteAttempts }
  }

  func identityCommitCount() -> Int {
    lock.withLock { identityCommits }
  }

  func currentEnvironmentRecoveryGeneration() -> Int? {
    lock.withLock { journalGeneration }
  }

  private func finishJournaledRecoveryIfNeeded() {
    guard let replacement = journalReplacement,
      storedInstallationID != replacement
    else { return }
    storedKeyID = nil
    storedInstallationID = replacement
    identityCommits += 1
  }
}

private actor SequencedAskIAgentAppAttestService: AskIAgentAppAttestServicing {
  nonisolated let isSupported = true
  private let invalidAssertion: Bool
  private let invalidAttestation: Bool
  private(set) var generatedKeyCount = 0
  private(set) var assertionCount = 0
  private(set) var attestationCount = 0

  init(invalidAssertion: Bool = false, invalidAttestation: Bool = false) {
    self.invalidAssertion = invalidAssertion
    self.invalidAttestation = invalidAttestation
  }

  func generateKey() async throws -> String {
    generatedKeyCount += 1
    return "replacement-app-attest-key"
  }

  func attestKey(_: String, clientDataHash _: Data) async throws -> Data {
    attestationCount += 1
    if invalidAttestation { throw invalidKeyError() }
    return Data("attestation".utf8)
  }

  func generateAssertion(_: String, clientDataHash _: Data) async throws -> Data {
    assertionCount += 1
    if invalidAssertion { throw invalidKeyError() }
    return Data("assertion".utf8)
  }

  private func invalidKeyError() -> NSError {
    NSError(domain: DCErrorDomain, code: DCError.Code.invalidKey.rawValue)
  }
}

private actor OverlappingInvalidKeyAskIAgentAppAttestService: AskIAgentAppAttestServicing {
  nonisolated let isSupported = true
  private var invalidAssertionContinuation: CheckedContinuation<Void, Never>?
  private(set) var generatedKeyCount = 0
  private(set) var assertionCount = 0
  private(set) var attestationCount = 0

  var isInvalidAssertionSuspended: Bool { invalidAssertionContinuation != nil }

  func generateKey() async throws -> String {
    generatedKeyCount += 1
    return "replacement-app-attest-key"
  }

  func attestKey(_: String, clientDataHash _: Data) async throws -> Data {
    attestationCount += 1
    return Data("attestation".utf8)
  }

  func generateAssertion(_ keyID: String, clientDataHash _: Data) async throws -> Data {
    assertionCount += 1
    if keyID == "old-app-attest-key" {
      if invalidAssertionContinuation == nil {
        await withCheckedContinuation { continuation in
          invalidAssertionContinuation = continuation
        }
      }
      throw NSError(domain: DCErrorDomain, code: DCError.Code.invalidKey.rawValue)
    }
    return Data("assertion".utf8)
  }

  func releaseInvalidAssertion() {
    let continuation = invalidAssertionContinuation
    invalidAssertionContinuation = nil
    continuation?.resume()
  }
}

private actor AskIAgentTokenProviderTestSignal {
  private var isSignaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    isSignaled = true
    let pending = waiters
    waiters.removeAll()
    for continuation in pending { continuation.resume() }
  }

  func wait() async {
    guard !isSignaled else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private struct TestAskIAgentAppAttestService: AskIAgentAppAttestServicing {
  let isSupported = true

  func generateKey() async throws -> String { "generated-app-attest-key" }

  func attestKey(_: String, clientDataHash _: Data) async throws -> Data {
    Data("attestation".utf8)
  }

  func generateAssertion(_: String, clientDataHash _: Data) async throws -> Data {
    Data("assertion".utf8)
  }
}

private final class AskIAgentRemoteURLProtocolPlan: @unchecked Sendable {
  struct Response: Sendable {
    let statusCode: Int?
    let body: Data
    let headerFields: [String: String]
    let error: URLError?

    init(
      statusCode: Int,
      body: Data,
      headerFields: [String: String] = ["Content-Type": "application/json"]
    ) {
      self.statusCode = statusCode
      self.body = body
      self.headerFields = headerFields
      error = nil
    }

    init(error: URLError) {
      statusCode = nil
      body = Data()
      headerFields = [:]
      self.error = error
    }
  }

  private let lock = NSLock()
  private var queuedResponses: [Response]
  private var recordedRequests: [URLRequest] = []

  init(responses: [Response]) {
    queuedResponses = responses
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }

  func takeResponse(for request: URLRequest) -> Response? {
    lock.lock()
    defer { lock.unlock() }
    recordedRequests.append(Self.materializedRequest(request))
    guard !queuedResponses.isEmpty else { return nil }
    return queuedResponses.removeFirst()
  }

  /// URLSession may move an upload body from `httpBody` into `httpBodyStream` before a custom
  /// URLProtocol sees it. Materialize that stream while it is still owned by the stub so contract
  /// assertions inspect the bytes that were actually sent rather than an empty request copy.
  private static func materializedRequest(_ request: URLRequest) -> URLRequest {
    guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
    stream.open()
    defer { stream.close() }

    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      body.append(contentsOf: buffer.prefix(count))
    }

    var copy = request
    copy.httpBodyStream = nil
    copy.httpBody = body
    return copy
  }
}

private final class AskIAgentRemoteURLProtocolStub: URLProtocol, @unchecked Sendable {
  typealias Response = AskIAgentRemoteURLProtocolPlan.Response

  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var plans: [String: AskIAgentRemoteURLProtocolPlan] = [:]

  static func install(
    for url: URL,
    responses: [Response]
  ) -> AskIAgentRemoteURLProtocolPlan {
    let plan = AskIAgentRemoteURLProtocolPlan(responses: responses)
    registryLock.lock()
    plans[url.absoluteString] = plan
    registryLock.unlock()
    return plan
  }

  static func removePlan(for url: URL) {
    registryLock.lock()
    plans.removeValue(forKey: url.absoluteString)
    registryLock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool {
    plan(for: request.url) != nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let requestURL = request.url,
      let plan = Self.plan(for: requestURL),
      let response = plan.takeResponse(for: request)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    if let error = response.error {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    guard let statusCode = response.statusCode,
      let httpResponse = HTTPURLResponse(
        url: requestURL,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: response.headerFields
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func plan(for url: URL?) -> AskIAgentRemoteURLProtocolPlan? {
    guard let url else { return nil }
    registryLock.lock()
    defer { registryLock.unlock() }
    return plans[url.absoluteString]
  }
}

final class AskIAgentNativeHandoffPresentationTests: XCTestCase {
  @MainActor
  func testCalendarConfirmationRoutesToEditorAndCancelFinalizesWithoutLocalWrite() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.directory) }
    let calendarArguments =
      #"{"title":"Design review","start_at":"2026-08-14T09:00:00+03:00","end_at":"2026-08-14T10:00:00+03:00","time_zone_id":"Europe/Athens","is_all_day":false,"calendar_id":null,"location":null,"notes":null}"#
    let intent = try makeIntent(
      toolName: AssistantProposalToolCatalog.draftCalendarEventName,
      arguments: calendarArguments
    )

    await harness.cards.present(intent)
    let snapshotBeforeConfirmation = await harness.store.snapshot()
    XCTAssertTrue(snapshotBeforeConfirmation.calendarEvents.isEmpty)

    let confirmationReceipt = await harness.cards.confirmFromCurrentUserGesture()
    let receipt = try XCTUnwrap(confirmationReceipt).receipt
    XCTAssertEqual(receipt.disposition, .nativeHandoffRequired)
    let snapshotBeforeEditor = await harness.store.snapshot()
    XCTAssertTrue(snapshotBeforeEditor.calendarEvents.isEmpty)
    let resolvedHandoff = try XCTUnwrap(
      AskIAgentNativeActionHandoff.resolve(intent: harness.cards.intent, receipt: receipt)
    )
    guard case .calendar(let intentID, let proposalDigest, let draft) = resolvedHandoff else {
      return XCTFail("A confirmed calendar draft must open Apple's event editor.")
    }
    XCTAssertEqual(intentID, intent.id)
    XCTAssertEqual(proposalDigest, intent.proposalDigest)
    XCTAssertEqual(draft.title, "Design review")

    let didFinish = await harness.cards.finishCalendarHandoff(
      intentID: intentID,
      proposalDigest: proposalDigest,
      outcome: .cancelled
    )
    XCTAssertTrue(didFinish)
    XCTAssertEqual(harness.cards.receipt?.disposition, .handoffCancelled)
    let snapshotAfterCancellation = await harness.store.snapshot()
    XCTAssertTrue(snapshotAfterCancellation.calendarEvents.isEmpty)
    let pendingAfterCancellation = try await harness.pendingStore.mostRecentValidIntent()
    XCTAssertNil(pendingAfterCancellation)
  }

  @MainActor
  func testCodexConfirmationRoutesToShareHandoffAndCompletionNeverCreatesTask() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.directory) }
    let intent = try makeIntent(
      toolName: AssistantProposalToolCatalog.requestCodexTaskName,
      arguments: #"{"prompt":"Inspect the failing tests and propose a fix.","workspace_id":null}"#
    )

    await harness.cards.present(intent)
    let snapshotBeforeConfirmation = await harness.store.snapshot()
    XCTAssertTrue(snapshotBeforeConfirmation.codexThreads.isEmpty)

    let confirmationReceipt = await harness.cards.confirmFromCurrentUserGesture()
    let receipt = try XCTUnwrap(confirmationReceipt).receipt
    XCTAssertEqual(receipt.disposition, .nativeHandoffRequired)
    let snapshotBeforeHandoff = await harness.store.snapshot()
    XCTAssertTrue(snapshotBeforeHandoff.codexThreads.isEmpty)
    let resolvedHandoff = try XCTUnwrap(
      AskIAgentNativeActionHandoff.resolve(intent: harness.cards.intent, receipt: receipt)
    )
    guard case .codex(let intentID, let proposalDigest, let request) = resolvedHandoff else {
      return XCTFail("A confirmed Codex request must open the user-controlled handoff.")
    }
    XCTAssertEqual(intentID, intent.id)
    XCTAssertEqual(proposalDigest, intent.proposalDigest)
    XCTAssertEqual(request.prompt, "Inspect the failing tests and propose a fix.")

    let didFinish = await harness.cards.finishCodexHandoff(
      intentID: intentID,
      proposalDigest: proposalDigest,
      outcome: .completed
    )
    XCTAssertTrue(didFinish)
    XCTAssertEqual(harness.cards.receipt?.disposition, .handoffCompleted)
    XCTAssertTrue(harness.cards.receipt?.summary.contains("did not create or run") == true)
    let snapshotAfterHandoff = await harness.store.snapshot()
    XCTAssertTrue(snapshotAfterHandoff.codexThreads.isEmpty)
    let pendingAfterHandoff = try await harness.pendingStore.mostRecentValidIntent()
    XCTAssertNil(pendingAfterHandoff)
  }

  @MainActor
  func testNativeHandoffRouteRejectsMismatchedReceipt() throws {
    let intent = try makeIntent(
      toolName: AssistantProposalToolCatalog.requestCodexTaskName,
      arguments: #"{"prompt":"Review this request.","workspace_id":null}"#
    )
    let mismatched = AssistantActionReceipt(
      id: "receipt-mismatch",
      intentID: "different-intent",
      proposalDigest: intent.proposalDigest,
      capability: intent.capability,
      disposition: .nativeHandoffRequired,
      entityIdentifier: nil,
      revision: nil,
      summary: "Handoff required.",
      committedAt: Date()
    )

    XCTAssertNil(
      AskIAgentNativeActionHandoff.resolve(intent: intent, receipt: mismatched)
    )
  }

  @MainActor
  func testStaleCalendarCallbackFinalizesCapturedIntentWithoutOverwritingNewCard() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.directory) }
    let calendar = try makeIntent(
      toolName: AssistantProposalToolCatalog.draftCalendarEventName,
      arguments:
        #"{"title":"Design review","start_at":"2026-08-14T09:00:00+03:00","end_at":"2026-08-14T10:00:00+03:00","time_zone_id":"Europe/Athens","is_all_day":false,"calendar_id":null,"location":null,"notes":null}"#
    )
    let codex = try makeIntent(
      toolName: AssistantProposalToolCatalog.requestCodexTaskName,
      arguments: #"{"prompt":"Review the release notes.","workspace_id":null}"#
    )

    await harness.cards.present(calendar)
    let optionalCalendarResult = await harness.cards.confirmFromCurrentUserGesture()
    let calendarResult = try XCTUnwrap(optionalCalendarResult)
    XCTAssertEqual(calendarResult.receipt.disposition, .nativeHandoffRequired)

    await harness.cards.present(codex)
    XCTAssertEqual(harness.cards.intent?.id, codex.id)
    XCTAssertNil(harness.cards.receipt)

    let didFinish = await harness.cards.finishCalendarHandoff(
      intentID: calendar.id,
      proposalDigest: calendar.proposalDigest,
      outcome: .cancelled
    )
    XCTAssertTrue(didFinish)
    XCTAssertEqual(harness.cards.intent?.id, codex.id)
    XCTAssertNil(harness.cards.receipt)
    let pending = try await harness.pendingStore.allValidIntents()
    XCTAssertEqual(pending.map(\.id), [codex.id])
    let calendarReceipt = try await harness.cards.broker.receipt(for: calendar.id)
    XCTAssertEqual(calendarReceipt?.disposition, .handoffCancelled)
  }

  @MainActor
  func testRestoreCleansTerminalReceiptCrashWindowWithoutPresentingReviewAgain() async throws {
    let first = try makeHarness()
    defer { try? FileManager.default.removeItem(at: first.directory) }
    let calendar = try makeIntent(
      toolName: AssistantProposalToolCatalog.draftCalendarEventName,
      arguments:
        #"{"title":"Design review","start_at":"2026-08-14T09:00:00+03:00","end_at":"2026-08-14T10:00:00+03:00","time_zone_id":"Europe/Athens","is_all_day":false,"calendar_id":null,"location":null,"notes":null}"#
    )
    await first.cards.present(calendar)
    let optionalResult = await first.cards.confirmFromCurrentUserGesture()
    let result = try XCTUnwrap(optionalResult)
    XCTAssertEqual(result.receipt.disposition, .nativeHandoffRequired)
    _ = try await first.cards.broker.finalizeNativeHandoff(
      intentID: calendar.id,
      proposalDigest: calendar.proposalDigest,
      outcome: .cancelled(summary: "Cancelled safely.")
    )
    // Deliberately leave the pending review in place to reproduce the crash window between the
    // durable terminal receipt and best-effort pending cleanup.
    let pendingBeforeRestart = try await first.pendingStore.mostRecentValidIntent()
    XCTAssertEqual(pendingBeforeRestart?.id, calendar.id)

    let restarted = try makeHarness(directory: first.directory)
    await restarted.cards.restoreMostRecentPendingReview()
    XCTAssertNil(restarted.cards.intent)
    let pendingAfterRestart = try await restarted.pendingStore.mostRecentValidIntent()
    XCTAssertNil(pendingAfterRestart)
    let durable = try await restarted.cards.broker.receipt(for: calendar.id)
    XCTAssertEqual(durable?.disposition, .handoffCancelled)
  }

  @MainActor
  func testRestoreOfUncertainNativeHandoffIsNonConfirmableAndDoesNotReopenEditor() async throws {
    let first = try makeHarness()
    defer { try? FileManager.default.removeItem(at: first.directory) }
    let calendar = try makeIntent(
      toolName: AssistantProposalToolCatalog.draftCalendarEventName,
      arguments:
        #"{"title":"Design review","start_at":"2026-08-14T09:00:00+03:00","end_at":"2026-08-14T10:00:00+03:00","time_zone_id":"Europe/Athens","is_all_day":false,"calendar_id":null,"location":null,"notes":null}"#
    )
    await first.cards.present(calendar)
    let optionalInitial = await first.cards.confirmFromCurrentUserGesture()
    let initial = try XCTUnwrap(optionalInitial)
    XCTAssertEqual(initial.receipt.disposition, .nativeHandoffRequired)

    let restarted = try makeHarness(directory: first.directory)
    await restarted.cards.restoreMostRecentPendingReview()
    XCTAssertEqual(restarted.cards.intent?.id, calendar.id)
    XCTAssertEqual(restarted.cards.receipt?.id, initial.receipt.id)
    XCTAssertEqual(restarted.cards.receipt?.disposition, .nativeHandoffRequired)
    XCTAssertTrue(restarted.cards.errorMessage?.contains("may already have completed") == true)

    let duplicateConfirmation = await restarted.cards.confirmFromCurrentUserGesture()
    XCTAssertNil(duplicateConfirmation)
    XCTAssertEqual(restarted.cards.receipt?.id, initial.receipt.id)
    let durable = try await restarted.cards.broker.receipt(for: calendar.id)
    XCTAssertEqual(durable?.id, initial.receipt.id)
  }

  @MainActor
  func testCardRestartAfterLocalWriteReceiptFailureReconcilesAndCleansPending() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("sync-store.json")
    let journalURL = directory.appendingPathComponent("journal.json")
    let pendingURL = directory.appendingPathComponent("pending-actions.json")
    let writer = MobileActionJournalFailureWriter()
    let firstStore = IAgentLocalSyncStore(fileURL: storeURL)
    let firstExecutor = MobileReceiptFailureAfterLocalWriteExecutor(
      base: LocalFirstAssistantActionExecutor(
        store: firstStore,
        sourceDeviceID: "mobile-crash-recovery"
      ),
      failNextReceiptWith: writer
    )
    let firstJournal = AssistantActionJournal(
      fileURL: journalURL,
      persistenceWriter: { data, url, options in
        try writer.write(data, to: url, options: options)
      }
    )
    let pendingStore = AssistantActionPendingStore(fileURL: pendingURL)
    let intent = try makeIntent(
      toolName: AssistantProposalToolCatalog.createNoteName,
      arguments: #"{"title":"Crash recovery","body":"Keep exactly one durable note."}"#
    )
    let firstBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: .allPreparationEnabled),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: firstExecutor,
      journal: firstJournal,
      now: { intent.createdAt.addingTimeInterval(1) },
      isAppForeground: { true }
    )
    let firstCards = AssistantActionCardModel(
      broker: firstBroker,
      pendingStore: pendingStore
    )
    await firstCards.present(intent)
    let failedCommit = await firstCards.confirmFromCurrentUserGesture()
    XCTAssertNil(failedCommit)
    let firstSnapshot = await firstStore.snapshot()
    let firstExecuteCount = await firstExecutor.executeCount
    XCTAssertEqual(firstSnapshot.notes.count, 1)
    XCTAssertEqual(firstExecuteCount, 1)

    // Recreate every runtime object after expiry and with preparation disabled. Card restoration
    // must reconcile the exact deterministic record, persist its receipt, clean the pending card,
    // and never call execute again.
    let restartedStore = IAgentLocalSyncStore(fileURL: storeURL)
    let restartedExecutor = MobileReceiptFailureAfterLocalWriteExecutor(
      base: LocalFirstAssistantActionExecutor(
        store: restartedStore,
        sourceDeviceID: "mobile-crash-recovery"
      )
    )
    let restartedJournal = AssistantActionJournal(fileURL: journalURL)
    let restartedBroker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: .allDisabled),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: restartedExecutor,
      journal: restartedJournal,
      now: { intent.expiresAt.addingTimeInterval(60) },
      isAppForeground: { true }
    )
    let restartedPending = AssistantActionPendingStore(fileURL: pendingURL)
    let restartedCards = AssistantActionCardModel(
      broker: restartedBroker,
      pendingStore: restartedPending
    )
    await restartedCards.restoreMostRecentPendingReview()

    XCTAssertNil(restartedCards.intent)
    XCTAssertNil(restartedCards.receipt)
    XCTAssertNil(restartedCards.errorMessage)
    let restartedSnapshot = await restartedStore.snapshot()
    let restartedExecuteCount = await restartedExecutor.executeCount
    let reconciliationCount = await restartedExecutor.reconciliationCount
    XCTAssertEqual(restartedSnapshot.notes.count, 1)
    XCTAssertEqual(restartedExecuteCount, 0)
    XCTAssertEqual(reconciliationCount, 1)
    let durableReceipt = try await restartedJournal.receipt(forIntentID: intent.id)
    XCTAssertEqual(durableReceipt?.disposition, .committedLocally)
    let pendingAfterRecovery = try await restartedPending.mostRecentRestorableIntent()
    XCTAssertNil(pendingAfterRecovery)
  }

  @MainActor
  private func makeHarness(directory suppliedDirectory: URL? = nil) throws -> (
    directory: URL,
    store: IAgentLocalSyncStore,
    pendingStore: AssistantActionPendingStore,
    cards: AssistantActionCardModel
  ) {
    let directory = suppliedDirectory ?? FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = IAgentLocalSyncStore(fileURL: directory.appendingPathComponent("sync-store.json"))
    let pendingStore = AssistantActionPendingStore(
      fileURL: directory.appendingPathComponent("pending-actions.json")
    )
    let broker = AssistantActionBroker(
      capabilities: FixedAssistantActionCapabilityProvider(policy: .allPreparationEnabled),
      permissions: FixedAssistantActionPermissionAuthorizer(),
      executor: LocalFirstAssistantActionExecutor(store: store, sourceDeviceID: "handoff-tests"),
      journal: AssistantActionJournal(fileURL: directory.appendingPathComponent("journal.json")),
      isAppForeground: { true }
    )
    return (
      directory,
      store,
      pendingStore,
      AssistantActionCardModel(broker: broker, pendingStore: pendingStore)
    )
  }

  private func makeIntent(
    toolName: String,
    arguments: String
  ) throws -> AssistantActionIntent {
    try AssistantActionProposalValidator.makeIntent(
      toolName: toolName,
      argumentsJSON: Data(arguments.utf8),
      context: AssistantActionProposalContext(
        provenance: AssistantActionProvenance(
          conversationID: "handoff-conversation",
          turnID: UUID().uuidString.lowercased(),
          currentUserMessageID: UUID().uuidString.lowercased(),
          toolCallID: UUID().uuidString.lowercased()
        ),
        capabilityPolicy: .allPreparationEnabled,
        authorizationOrigin: .currentUserMessage,
        userExplicitlyRequestedAction: true
      )
    )
  }
}

private final class MobileActionJournalFailureWriter: @unchecked Sendable {
  enum Failure: Error {
    case injected
  }

  private let lock = NSLock()
  private var shouldFailNextWrite = false

  func failNextWrite() {
    lock.withLock { shouldFailNextWrite = true }
  }

  func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
    let shouldFail = lock.withLock {
      defer { shouldFailNextWrite = false }
      return shouldFailNextWrite
    }
    if shouldFail { throw Failure.injected }
    try data.write(to: url, options: options)
  }
}

private actor MobileReceiptFailureAfterLocalWriteExecutor: AssistantActionExecuting {
  private let base: LocalFirstAssistantActionExecutor
  private let writer: MobileActionJournalFailureWriter?
  private(set) var executeCount = 0
  private(set) var reconciliationCount = 0

  init(
    base: LocalFirstAssistantActionExecutor,
    failNextReceiptWith writer: MobileActionJournalFailureWriter? = nil
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

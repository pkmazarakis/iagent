import Foundation
import XCTest

final class MessageReplySourceContractTests: XCTestCase {
  func testIOSUsesOnlyMessageUIUserConfirmedComposer() throws {
    let transport = try source("Mobile/iAgentMobile/Model/MobileMessageReplyTransport.swift")
    let view = try source("Mobile/iAgentMobile/Views/MessagesMobileView.swift")
    let settings = try source("Mobile/iAgentMobile/Views/MobileSettingsView.swift")

    XCTAssertTrue(transport.contains("MFMessageComposeViewController.canSendText()"))
    XCTAssertTrue(transport.contains("controller.recipients = recipients"))
    XCTAssertTrue(transport.contains("controller.body = request.body"))
    XCTAssertTrue(transport.contains("controller.messageComposeDelegate = self"))
    XCTAssertTrue(transport.contains("$0.address.kind == .phone"))
    XCTAssertTrue(transport.contains("case .sent:"))
    XCTAssertTrue(transport.contains("completion = .sendRequested"))
    XCTAssertFalse(transport.contains("UIApplication.shared.open"))
    XCTAssertFalse(transport.lowercased().contains("sms:"))

    XCTAssertTrue(view.contains("Enable reply handoff?"))
    XCTAssertTrue(view.contains("MobileMessageReplyComposer("))
    XCTAssertTrue(view.contains(".filter { $0.address.kind == .phone }"))
    XCTAssertTrue(view.contains("guard !conversation.isGroup else { return [] }"))
    XCTAssertTrue(view.contains("Phase 1 supports one-to-one conversations only"))
    XCTAssertTrue(
      view.contains(
        "every eligible one-to-one conversation in your rolling 14-day Messages inbox"
      )
    )
    XCTAssertTrue(
      settings.contains(
        "every eligible one-to-one conversation in your rolling 14-day Messages inbox"
      )
    )
    XCTAssertTrue(view.contains("Review reply in Messages"))
    XCTAssertFalse(view.contains("MessageBubble(message: request"))
  }

  func testMacUsesBoundedPublicAppleScriptWithExplicitComposeFallback() throws {
    let transport = try source("Sources/iAgentPanel/MessageReplyTransport.swift")
    let pipeline = try source("Sources/iAgentPanel/MessagesDirectSendPipeline.swift")
    let view = try source("Sources/iAgentPanel/MessageInboxViews.swift")
    let controller = try source("Sources/iAgentPanel/iAgentPanelApp.swift")
    let info = try source("Sources/iAgentPanel/Info.plist")
    let entitlements = try source(
      "Sources/iAgentPanel/iAgentPanelTestFlight.entitlements"
    )
    let developmentEntitlements = try source(
      "Sources/iAgentPanel/iAgentPanel.entitlements"
    )
    let releaseEntitlements = try source(
      "Sources/iAgentPanel/iAgentPanelRelease.entitlements"
    )
    let buildScript = try source("Scripts/build-app.sh")
    let readiness = try source("Scripts/check-macos-testflight-readiness.sh")
    let signing = try source("Scripts/verify-macos-cloudkit-signing.sh")

    XCTAssertTrue(transport.contains("NSSharingService(named: .composeMessage)"))
    XCTAssertTrue(transport.contains("service.recipients = [payload.recipient]"))
    XCTAssertTrue(transport.contains("service.perform(withItems: items)"))
    XCTAssertTrue(transport.contains("case composeRequested"))
    XCTAssertTrue(transport.contains("case outcomeUncertain(String)"))
    XCTAssertTrue(transport.contains("case fallbackRequired(String)"))
    XCTAssertTrue(transport.contains("DirectMessagesReplyTransport"))
    XCTAssertFalse(transport.lowercased().contains("scriptingbridge"))
    XCTAssertFalse(transport.contains("IMCore"))

    XCTAssertTrue(pipeline.contains("/usr/bin/osascript"))
    XCTAssertTrue(pipeline.contains("process.arguments = [\"-l\", \"AppleScript\", \"-\"] + command.arguments"))
    XCTAssertTrue(pipeline.contains("tell application id \"com.apple.MobileSMS\""))
    XCTAssertTrue(pipeline.contains("static let timeout: TimeInterval = 60"))
    XCTAssertTrue(pipeline.contains("Darwin.kill(process.processIdentifier, SIGKILL)"))
    XCTAssertTrue(pipeline.contains("[recipient, body, service.appleScriptValue, chatGUID ?? \"\"]"))
    XCTAssertTrue(pipeline.contains("PRAGMA query_only = ON"))
    XCTAssertTrue(pipeline.contains("m.ROWID > ?2"))
    XCTAssertTrue(pipeline.contains("plainTextExpression"))
    XCTAssertTrue(pipeline.contains("MessageAttributedBodyDecoder.decode"))
    XCTAssertTrue(pipeline.contains("contains(body)"))
    XCTAssertTrue(pipeline.contains("do not retry automatically"))
    XCTAssertFalse(pipeline.contains("IMCore"))

    XCTAssertTrue(view.contains("replyTransport: DirectMessagesReplyTransport()"))
    XCTAssertTrue(view.contains("sendUserInitiated("))
    XCTAssertTrue(view.contains("MacMessageReplyService(serviceName: conversation.serviceName)"))
    XCTAssertTrue(view.contains("case let .outcomeUncertain(message):"))
    XCTAssertTrue(view.contains("case let .fallbackRequired(message):"))
    XCTAssertTrue(view.contains("Open in Messages?"))
    XCTAssertTrue(view.contains("beginUserConfirmedFallback(request)"))
    XCTAssertTrue(view.contains("will not send automatically"))
    XCTAssertTrue(view.contains("guard !conversation.isGroup else { return [] }"))
    XCTAssertTrue(view.contains("Phase 1 supports one-to-one conversations only"))
    XCTAssertTrue(controller.contains("func setMessageReplyTransportEnabled(_ enabled: Bool)"))
    XCTAssertTrue(controller.contains("scrubMessageReplyAddresses()"))
    XCTAssertTrue(controller.contains("startMessageProviderUpdates()"))
    XCTAssertTrue(controller.contains("return \"Back to Messages\""))
    XCTAssertTrue(controller.contains("messageReplySendInFlightConversationID"))
    XCTAssertTrue(controller.contains("func beginMessageReplySend(for conversationID: String) -> Bool"))
    XCTAssertTrue(controller.contains("func finishMessageReplySend(for conversationID: String)"))
    XCTAssertTrue(controller.contains("nextPresentation != .expanded"))
    XCTAssertTrue(controller.contains("messageReplyDraftsByConversationID"))
    XCTAssertTrue(view.contains("controller.beginMessageReplySend(for: conversation.id)"))
    XCTAssertTrue(view.contains("controller.finishMessageReplySend(for: conversationID)"))
    XCTAssertTrue(view.contains("controller.messageReplyDraft(for: conversation.id)"))
    XCTAssertTrue(view.contains("controller.storeMessageReplyDraft(draft, for: conversation.id)"))

    XCTAssertTrue(info.contains("NSAppleEventsUsageDescription"))
    XCTAssertTrue(info.contains("only after you press Send"))
    XCTAssertTrue(entitlements.contains("com.apple.security.automation.apple-events"))
    XCTAssertTrue(entitlements.contains("com.apple.security.temporary-exception.apple-events"))
    XCTAssertTrue(entitlements.contains("com.apple.MobileSMS"))
    XCTAssertTrue(entitlements.contains("com.apple.iCal"))
    let entitlementObject = try XCTUnwrap(
      try PropertyListSerialization.propertyList(
        from: Data(entitlements.utf8),
        options: [],
        format: nil
      ) as? [String: Any]
    )
    XCTAssertEqual(
      entitlementObject["com.apple.security.temporary-exception.apple-events"] as? [String],
      ["com.apple.MobileSMS", "com.apple.iCal"]
    )
    XCTAssertTrue(developmentEntitlements.contains("com.apple.security.automation.apple-events"))
    XCTAssertTrue(releaseEntitlements.contains("com.apple.security.automation.apple-events"))
    XCTAssertTrue(buildScript.contains("Code-signing entitlements must allow Apple Events automation"))
    XCTAssertTrue(readiness.contains("Apple Events automation entitlement is required"))
    XCTAssertTrue(readiness.contains("Messages must be the first sandbox Apple Events target"))
    XCTAssertTrue(readiness.contains("Calendar must remain the second sandbox Apple Events target"))
    XCTAssertTrue(readiness.contains("targets must be limited to Messages and Calendar"))
    XCTAssertTrue(signing.contains("Apple Events automation entitlement is missing"))
    XCTAssertTrue(signing.contains("Messages sandbox Apple Events target is missing or out of order"))
    XCTAssertTrue(signing.contains("Calendar sandbox Apple Events target is missing or out of order"))
    XCTAssertTrue(signing.contains("targets contain an unexpected app"))
  }

  func testMacDirectComposerMatchesSingleFieldVoiceAndReturnContract() throws {
    let view = try source("Sources/iAgentPanel/MessageInboxViews.swift")
    let composerStart = try XCTUnwrap(view.range(of: "private var replyComposer"))
    let composerEnd = try XCTUnwrap(
      view.range(of: "private var eligibleRecipients", range: composerStart.upperBound..<view.endIndex)
    )
    let composer = String(view[composerStart.lowerBound..<composerEnd.lowerBound])

    XCTAssertTrue(composer.contains("TextField(replyPlaceholder"))
    XCTAssertTrue(view.contains("\"Text Message\""))
    XCTAssertTrue(composer.contains("attemptSend()"))
    XCTAssertTrue(composer.contains("Image(systemName: \"arrow.up\")"))
    XCTAssertTrue(composer.contains("Color.agentBlue"))
    XCTAssertTrue(composer.contains("\"mic.fill\" : \"mic\""))
    XCTAssertTrue(composer.contains("performReplyAction"))
    XCTAssertTrue(composer.contains(".onKeyPress(.return, phases: .down)"))
    XCTAssertTrue(composer.contains("keyPress.modifiers.contains(.shift)"))
    XCTAssertTrue(composer.contains("[.command, .control, .option]"))
    XCTAssertTrue(composer.contains("return .ignored"))
    XCTAssertTrue(composer.contains("return .handled"))
    XCTAssertTrue(composer.contains(".accessibilityLabel(\"Message\")"))
    XCTAssertTrue(composer.contains("Press Return to send"))
    XCTAssertTrue(composer.contains("Send message"))
    XCTAssertTrue(view.contains("toggleReplyDictation()"))
    XCTAssertTrue(view.contains("replyDictation.start()"))
    XCTAssertFalse(composer.contains("recipientControl"))
    XCTAssertFalse(composer.contains("arrow.up.right.square"))
    XCTAssertFalse(composer.contains("Button(\"Enable replies\")"))
    XCTAssertFalse(composer.contains("Refreshing reply recipients"))
    XCTAssertFalse(composer.contains("controller.isMessageInboxSyncing"))
    XCTAssertFalse(composer.contains("Opens Messages for review"))

    let attemptStart = try XCTUnwrap(view.range(of: "private func attemptSend()"))
    let attemptEnd = try XCTUnwrap(
      view.range(
        of: "private func beginRecipientResolution()",
        range: attemptStart.upperBound..<view.endIndex
      )
    )
    let attempt = String(view[attemptStart.lowerBound..<attemptEnd.lowerBound])
    XCTAssertTrue(attempt.contains("beginRecipientResolution()"))
    XCTAssertFalse(attempt.contains("messageReplyTransportEnabled"))
    XCTAssertFalse(attempt.contains("replyAlert = .enable"))
    XCTAssertFalse(attempt.contains("setMessageReplyTransportEnabled(true)"))

    XCTAssertFalse(view.contains("case .enable:"))
    XCTAssertTrue(view.contains("case .sent:"))
    XCTAssertTrue(view.contains("if draftBody == request.body"))
    XCTAssertTrue(view.contains("case let .outcomeUncertain(message):"))
    XCTAssertTrue(view.contains("Check Messages before retrying"))
  }

  func testInitialMessagesBackfillStopsLoadingBeforeIdleUpdatesStream() throws {
    let controller = try source("Sources/iAgentPanel/iAgentPanelApp.swift")
    let start = try XCTUnwrap(controller.range(of: "private func startMessageProviderUpdates()"))
    let end = try XCTUnwrap(
      controller.range(
        of: "private func finishMessageProviderBackfill",
        range: start.upperBound..<controller.endIndex
      )
    )
    let implementation = String(controller[start.lowerBound..<end.lowerBound])
    let applied = try XCTUnwrap(implementation.range(of: "applyDesktopSyncState(initialState"))
    let afterApplied = applied.upperBound..<implementation.endIndex
    let finished = try XCTUnwrap(
      implementation.range(of: "finishMessageProviderBackfill(refreshGeneration)", range: afterApplied)
    )
    let updates = try XCTUnwrap(
      implementation.range(of: "for try await batch", range: afterApplied)
    )

    XCTAssertLessThan(finished.lowerBound, updates.lowerBound)
    XCTAssertFalse(implementation.contains("var ingestedFirstUpdate = false"))
  }

  func testSandboxMessagesSelectionSurvivesTheSeparatePrivacyGate() throws {
    let sandbox = try source("Sources/iAgentPanel/SandboxAccessManager.swift")
    let controller = try source("Sources/iAgentPanel/iAgentPanelApp.swift")
    let view = try source("Sources/iAgentPanel/MessageInboxViews.swift")
    let restoreStart = try XCTUnwrap(
      sandbox.range(of: "func restoreMessagesAccessIfEnabled(")
    )
    let restoreEnd = try XCTUnwrap(
      sandbox.range(
        of: "func requestMessagesDirectoryAccess(",
        range: restoreStart.upperBound..<sandbox.endIndex
      )
    )
    let restore = String(sandbox[restoreStart.lowerBound..<restoreEnd.lowerBound])
    XCTAssertTrue(restore.contains("messagesDatabaseURLForSelectedDirectory"))
    XCTAssertFalse(restore.contains("validatedMessagesDatabaseURL"))

    let requestStart = restoreEnd
    let requestEnd = try XCTUnwrap(
      sandbox.range(
        of: "nonisolated static func messagesDatabaseURLForSelectedDirectory(",
        range: requestStart.upperBound..<sandbox.endIndex
      )
    )
    let request = String(sandbox[requestStart.lowerBound..<requestEnd.lowerBound])
    XCTAssertTrue(request.contains("messagesDatabaseURLForSelectedDirectory"))
    XCTAssertTrue(request.contains(".withSecurityScope"))
    XCTAssertTrue(request.contains("defaults.set(data, forKey: Key.messages)"))
    XCTAssertTrue(request.contains("messagesDirectoryURL = directoryURL"))
    XCTAssertFalse(request.contains("validatedMessagesDatabaseURL"))
    XCTAssertTrue(
      controller.contains("messageProviderAccess = .disabled(error.localizedDescription)")
    )
    XCTAssertTrue(view.contains("copy the draft first, then retry after relaunch"))

    let provider = try source("Sources/iAgentPanel/MessageInboxProvider.swift")
    let inspectStart = try XCTUnwrap(provider.range(of: "private static func inspectAccess("))
    let inspectEnd = try XCTUnwrap(
      provider.range(
        of: "private static func loadSnapshot(",
        range: inspectStart.upperBound..<provider.endIndex
      )
    )
    let inspection = String(provider[inspectStart.lowerBound..<inspectEnd.lowerBound])
    XCTAssertTrue(inspection.contains("homeDirectory(forUser: userName)"))
    XCTAssertFalse(inspection.contains("homeDirectoryForCurrentUser"))
  }

  func testProviderPublishesAddressesOnlyBehindDesktopOptIn() throws {
    let provider = try source("Sources/iAgentPanel/MessageInboxProvider.swift")

    XCTAssertTrue(
      provider.contains(
        "includesReplyAddresses: MessageReplyPreferences.isEnabled(in: preferences)"
      )
    )
    XCTAssertTrue(
      provider.contains(
        "let replyAddress = includesReplyAddresses"
      )
    )
    XCTAssertTrue(provider.contains("replyAddress: presentation.replyAddress"))
  }

  func testReplyRequestAndRevocationRemainFailClosed() throws {
    let reply = try source("Sources/iAgentCore/MessageReply.swift")
    let store = try source("Sources/iAgentCore/LocalSyncStore.swift")
    let coordinator = try source("Sources/iAgentPanel/DesktopSyncCoordinator.swift")

    XCTAssertTrue(reply.contains("maximumRecipientCount = 1"))
    XCTAssertTrue(reply.contains("let domain = String(components[1]).lowercased()"))
    XCTAssertTrue(reply.contains("return \"\\(local)@\\(domain)\""))
    XCTAssertTrue(store.contains("public func scrubMessageReplyAddresses() throws -> Bool"))
    XCTAssertTrue(store.contains("state.baseRecords.removeValue(forKey: recordName)"))
    XCTAssertTrue(coordinator.contains("store.scrubMessageReplyAddresses()"))
  }

  private func source(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: root.appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }
}

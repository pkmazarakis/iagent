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

  func testMacUsesPublicSharingServiceAndExplicitPreHandoffConfirmation() throws {
    let transport = try source("Sources/iAgentPanel/MessageReplyTransport.swift")
    let view = try source("Sources/iAgentPanel/MessageInboxViews.swift")
    let controller = try source("Sources/iAgentPanel/iAgentPanelApp.swift")

    XCTAssertTrue(transport.contains("NSSharingService(named: .composeMessage)"))
    XCTAssertTrue(transport.contains("service.recipients = payload.recipients"))
    XCTAssertTrue(transport.contains("service.perform(withItems: payload.items)"))
    XCTAssertTrue(transport.contains("case handoffRequested"))
    XCTAssertFalse(transport.lowercased().contains("osascript"))
    XCTAssertFalse(transport.lowercased().contains("applescript"))
    XCTAssertFalse(transport.lowercased().contains("scriptingbridge"))
    XCTAssertFalse(transport.lowercased().contains("imessage:"))

    XCTAssertTrue(view.contains("Open in Messages?"))
    XCTAssertTrue(view.contains("beginUserConfirmedHandoff(request)"))
    XCTAssertTrue(view.contains("iAgent will not press Send"))
    XCTAssertTrue(view.contains("guard !conversation.isGroup else { return [] }"))
    XCTAssertTrue(view.contains("Phase 1 supports one-to-one conversations only"))
    XCTAssertFalse(view.contains("title: \"Opened Messages\""))
    XCTAssertTrue(controller.contains("func setMessageReplyTransportEnabled(_ enabled: Bool)"))
    XCTAssertTrue(controller.contains("scrubMessageReplyAddresses()"))
    XCTAssertTrue(controller.contains("startMessageProviderUpdates()"))
  }

  func testMacDirectComposerMatchesSingleFieldVoiceAndReturnContract() throws {
    let view = try source("Sources/iAgentPanel/MessageInboxViews.swift")
    let composerStart = try XCTUnwrap(view.range(of: "private var replyComposer"))
    let composerEnd = try XCTUnwrap(
      view.range(of: "private var eligibleRecipients", range: composerStart.upperBound..<view.endIndex)
    )
    let composer = String(view[composerStart.lowerBound..<composerEnd.lowerBound])

    XCTAssertTrue(composer.contains("TextField(\"iMessage\""))
    XCTAssertTrue(composer.contains("attemptHandoff()"))
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
    XCTAssertTrue(composer.contains("Press Return to review in Messages"))
    XCTAssertTrue(composer.contains("Review reply in Messages"))
    XCTAssertTrue(view.contains("toggleReplyDictation()"))
    XCTAssertTrue(view.contains("replyDictation.start()"))
    XCTAssertFalse(composer.contains("recipientControl"))
    XCTAssertFalse(composer.contains("arrow.up.right.square"))
    XCTAssertFalse(composer.contains("Button(\"Enable replies\")"))
    XCTAssertFalse(composer.contains("Refreshing reply recipients"))
    XCTAssertFalse(composer.contains("controller.isMessageInboxSyncing"))
    XCTAssertFalse(composer.contains("Opens Messages for review"))

    let attemptStart = try XCTUnwrap(view.range(of: "private func attemptHandoff()"))
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

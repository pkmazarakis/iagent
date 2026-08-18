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
    XCTAssertTrue(view.contains("Messages handoff requested"))
    XCTAssertFalse(view.contains("title: \"Opened Messages\""))
    XCTAssertTrue(
      view.contains(
        "every eligible one-to-one conversation in your rolling 14-day Messages inbox"
      )
    )
    XCTAssertTrue(controller.contains("func setMessageReplyTransportEnabled(_ enabled: Bool)"))
    XCTAssertTrue(controller.contains("scrubMessageReplyAddresses()"))
    XCTAssertTrue(controller.contains("startMessageProviderUpdates()"))
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

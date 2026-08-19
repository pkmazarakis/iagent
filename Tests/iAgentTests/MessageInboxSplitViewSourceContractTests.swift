import Foundation
import XCTest

@testable import iAgentPanel

final class MessageInboxSplitViewSourceContractTests: XCTestCase {
  func testConversationSelectionKeepsTheInboxSidebarVisible() throws {
    let source = try messageInboxSource()
    let splitStart = try XCTUnwrap(source.range(of: "private var splitInbox"))
    let splitEnd = try XCTUnwrap(
      source.range(
        of: "private var conversationPlaceholder",
        range: splitStart.upperBound..<source.endIndex
      )
    )
    let split = String(source[splitStart.lowerBound..<splitEnd.lowerBound])

    XCTAssertTrue(split.contains("HStack(spacing: 0)"))
    XCTAssertTrue(split.contains("conversationList"))
    XCTAssertTrue(split.contains(".frame(width: MessageInboxLayout.sidebarWidth)"))
    XCTAssertTrue(split.contains("MessageConversationPage("))
    XCTAssertTrue(split.contains(".id(selectedConversation.id)"))
    XCTAssertTrue(split.contains(".transition(detailTransition)"))
    XCTAssertTrue(split.contains(".animation(detailAnimation"))
    XCTAssertFalse(source.contains("title: \"Back to Messages\""))
  }

  func testDetailRevealHasReducedMotionCrossfadeAndRestrainedSpatialMotion() throws {
    let source = try messageInboxSource()

    XCTAssertTrue(source.contains("detailRevealDuration: TimeInterval = 0.22"))
    XCTAssertTrue(source.contains("if reduceMotion"))
    XCTAssertTrue(source.contains("return .opacity"))
    XCTAssertTrue(source.contains("horizontalOffset: 6"))
    XCTAssertTrue(source.contains(".timingCurve("))
  }

  func testComposerIsOneCompactPillWithStableVoiceAndSendSlot() throws {
    let source = try messageInboxSource()
    let composerStart = try XCTUnwrap(source.range(of: "private var replyComposer"))
    let composerEnd = try XCTUnwrap(
      source.range(
        of: "private var eligibleRecipients",
        range: composerStart.upperBound..<source.endIndex
      )
    )
    let composer = String(source[composerStart.lowerBound..<composerEnd.lowerBound])

    XCTAssertEqual(MessageInboxLayout.composerHeight, 38)
    XCTAssertEqual(MessageInboxLayout.composerActionSize, 28)
    XCTAssertTrue(composer.contains("TextField(replyPlaceholder"))
    XCTAssertTrue(source.contains("\"iMessage\""))
    XCTAssertTrue(source.contains("\"Text Message\""))
    XCTAssertTrue(composer.contains(".lineLimit(1)"))
    XCTAssertTrue(composer.contains(".frame(height: MessageInboxLayout.composerHeight)"))
    XCTAssertTrue(composer.contains("Image(systemName: \"arrow.up\")"))
    XCTAssertTrue(composer.contains("replyDictation.isRecording ? \"mic.fill\" : \"mic\""))
    XCTAssertTrue(composer.contains(".onKeyPress(.return, phases: .down)"))
    XCTAssertTrue(composer.contains("keyPress.modifiers.contains(.shift)"))
    XCTAssertTrue(composer.contains(".disabled(replyActionIsBusy)"))
    XCTAssertTrue(composer.contains("ProgressView()"))
    XCTAssertTrue(composer.contains(".accessibilityLabel(\"Message\")"))
    XCTAssertFalse(composer.contains("recipientControl"))
  }

  func testDirectSendKeepsTheDraftUnlessTheOutgoingMessageIsVerified() throws {
    let source = try messageInboxSource()
    let sendStart = try XCTUnwrap(source.range(of: "private func beginDirectSend()"))
    let sendEnd = try XCTUnwrap(
      source.range(
        of: "private func beginConfirmedFallback()",
        range: sendStart.upperBound..<source.endIndex
      )
    )
    let send = String(source[sendStart.lowerBound..<sendEnd.lowerBound])

    XCTAssertTrue(send.contains("replyTransport.sendUserInitiated("))
    XCTAssertTrue(send.contains("MacMessageReplyService(serviceName: conversation.serviceName)"))
    XCTAssertTrue(send.contains("case .sent:"))
    XCTAssertTrue(send.contains("if draftBody == request.body"))
    XCTAssertTrue(send.contains("draftBody = \"\""))
    XCTAssertTrue(send.contains("case let .outcomeUncertain(message):"))
    XCTAssertTrue(send.contains("case let .fallbackRequired(message):"))
    XCTAssertTrue(send.contains("pendingFallbackRequest = request"))
    XCTAssertFalse(send.contains("beginUserConfirmedFallback"))
    XCTAssertTrue(source.contains("replyTransport.beginUserConfirmedFallback(request)"))
  }

  private func messageInboxSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repositoryRoot
        .appendingPathComponent("Sources/iAgentPanel/MessageInboxViews.swift"),
      encoding: .utf8
    )
  }
}

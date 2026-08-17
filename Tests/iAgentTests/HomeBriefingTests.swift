import Foundation
import XCTest

@testable import iAgentPanel

final class HomeBriefingTests: XCTestCase {
  @MainActor
  func testMessagesMetricUsesTheSharedHomeRoute() throws {
    let suiteName = "HomeBriefingTests-\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let controller = PanelController(smokeTest: true, preferences: preferences)
    controller.selectedMessageConversationID = "open-conversation"
    controller.messageInboxFilter = .unread

    controller.openHomeSection(.messages)

    XCTAssertEqual(
      HomeSection.allCases,
      [.calendar, .codex, .messages, .notes, .todos]
    )
    XCTAssertEqual(controller.contentMode, .messages)
    XCTAssertEqual(controller.panelTitle, "Messages")
    XCTAssertNil(controller.selectedMessageConversationID)
    XCTAssertEqual(controller.messageInboxFilter, .all)
  }

  func testUnreadMessageCopyHandlesSingularAndPluralCounts() {
    XCTAssertEqual(HomeBriefingCopy.unreadMessages(0), "0 unread messages,")
    XCTAssertEqual(HomeBriefingCopy.unreadMessages(1), "1 unread message,")
    XCTAssertEqual(HomeBriefingCopy.unreadMessages(12), "12 unread messages,")
  }

  func testNotesMetricUsesTheCloudSymbol() {
    XCTAssertEqual(HomeMetricSymbols.notes, "icloud")
  }

  func testHomeMetricMotionPlansAreBoundedAndReduceMotionIsStatic() {
    XCTAssertEqual(
      HomeMetricMotionPlan.messageDotPhases(reduceMotion: false),
      [.active(0), .active(1), .active(2), .rest]
    )
    XCTAssertEqual(
      HomeMetricMotionPlan.messageDotPhases(reduceMotion: true),
      [.rest]
    )
  }

  func testHomeMessageDotsReproduceTheSuppliedRoundPointStrokes() {
    XCTAssertEqual(HomeMetricGeometry.iconSize, 18)
    XCTAssertEqual(HomeMetricGeometry.messageDotWidth, 1.5075, accuracy: 0.000_001)
    XCTAssertEqual(HomeMetricGeometry.messageDotHeight, 1.5, accuracy: 0.000_001)
    XCTAssertEqual(HomeMetricGeometry.messageDotCenterSpacing, 3, accuracy: 0.000_001)
  }

  func testHomeMessageSVGResourceContainsTheSuppliedLucidePath() throws {
    let messageURL = try XCTUnwrap(
      PanelResourceBundle.bundle.url(
        forResource: "message-circle",
        withExtension: "svg",
        subdirectory: "Brand"
      )
    )
    let message = try String(contentsOf: messageURL, encoding: .utf8)

    XCTAssertTrue(
      message.contains(
        #"<path d="M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719"/>"#
      )
    )
    XCTAssertEqual(AppAssets.messageCircle?.isTemplate, true)
  }
}

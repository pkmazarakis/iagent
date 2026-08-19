import Foundation
import XCTest

@testable import iAgentPanel

final class PanelPageChromeTests: XCTestCase {
  func testSharedPageLayoutMatchesMessagesSpacingContract() {
    XCTAssertEqual(PanelPageLayout.contentInset, 20)
    XCTAssertEqual(PanelPageLayout.headerLeadingInset, 10)
    XCTAssertEqual(PanelPageLayout.headerTrailingInset, 10)
    XCTAssertEqual(PanelPageLayout.headerItemSpacing, 8)
    XCTAssertEqual(PanelPageLayout.headerHeight, 36)
    XCTAssertEqual(PanelPageLayout.headerFlexibleSpace, 64)
    XCTAssertEqual(PanelPageHeaderPlacement.root.leadingInset, 20)
    XCTAssertEqual(PanelPageHeaderPlacement.navigation.leadingInset, 10)
  }

  func testAllDesktopBackHeadersUseTheSharedComponent() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceDirectory = repositoryRoot.appendingPathComponent("Sources/iAgentPanel")
    let chrome = try String(
      contentsOf: sourceDirectory.appendingPathComponent("PanelPageChrome.swift"),
      encoding: .utf8
    )
    let app = try String(
      contentsOf: sourceDirectory.appendingPathComponent("iAgentPanelApp.swift"),
      encoding: .utf8
    )
    let messages = try String(
      contentsOf: sourceDirectory.appendingPathComponent("MessageInboxViews.swift"),
      encoding: .utf8
    )

    let backChevron = "Image(systemName: \"chevron.left\")"
    XCTAssertEqual(chrome.components(separatedBy: backChevron).count - 1, 1)
    XCTAssertFalse(app.contains(backChevron))
    XCTAssertFalse(messages.contains(backChevron))
    XCTAssertTrue(app.contains("PanelPageHeader("))
    XCTAssertFalse(messages.contains("PanelPageHeader("))
    XCTAssertTrue(messages.contains("private var splitInbox"))
    XCTAssertTrue(messages.contains("MessageInboxLayout.sidebarWidth"))
    XCTAssertTrue(messages.contains("Show this conversation alongside the inbox"))
  }

  func testSemanticContentEdgesUseTheSharedInsetToken() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceDirectory = repositoryRoot.appendingPathComponent("Sources/iAgentPanel")
    let sourceFiles = [
      "HomeViews.swift",
      "MarkdownNoteEditor.swift",
      "MessageInboxViews.swift",
      "NotesListView.swift",
      "PanelCreationViews.swift",
      "iAgentPanelApp.swift",
    ]

    for sourceFile in sourceFiles {
      let source = try String(
        contentsOf: sourceDirectory.appendingPathComponent(sourceFile),
        encoding: .utf8
      )
      XCTAssertFalse(
        source.contains(".padding(.horizontal, 20)"),
        "\(sourceFile) should use PanelPageLayout.contentInset for 20pt page edges"
      )
      XCTAssertFalse(
        source.contains(".padding(.leading, 20)"),
        "\(sourceFile) should use PanelPageLayout.contentInset for 20pt page edges"
      )
      XCTAssertFalse(
        source.contains(".padding(.trailing, 20)"),
        "\(sourceFile) should use PanelPageLayout.contentInset for 20pt page edges"
      )
      XCTAssertFalse(
        source.contains("? 50 : 20"),
        "\(sourceFile) should share the ordinary 20pt branch of indented row edges"
      )
    }
  }
}

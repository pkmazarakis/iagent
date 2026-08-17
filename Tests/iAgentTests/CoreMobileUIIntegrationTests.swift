import Foundation
import XCTest

final class CoreMobileUIIntegrationTests: XCTestCase {
  func testCodexDetailsUseAHomeStyleDraggableActivityDrawer() throws {
    let source = try mobileSource("Views/CodexMobileView.swift")

    XCTAssertTrue(source.contains("JoiDrawerNavigationLink {"))
    XCTAssertTrue(source.contains("PanelScreen {"))
    XCTAssertGreaterThanOrEqual(
      source.components(separatedBy: "JoiDrawerPage(restingFraction: 0.38)").count - 1,
      2
    )
    XCTAssertTrue(source.contains(".scrollIndicators(.hidden)"))
    XCTAssertTrue(source.contains(".accessibilityIdentifier(\"codex-thread-activity-drawer\")"))
    XCTAssertTrue(source.contains(".accessibilityIdentifier(\"codex-thread-detail-page\")"))
    XCTAssertFalse(source.contains("JoiTimelineSheet {"))
    XCTAssertFalse(source.contains(".sheet(item: $selectedThread)"))
    XCTAssertFalse(source.contains("codex-thread-detail-sheet"))
  }

  func testCodexProjectRowsShareTheProjectTitleGridAndKeepAllStatesLeading() throws {
    let source = try mobileSource("Views/CodexMobileView.swift")

    XCTAssertGreaterThanOrEqual(
      source.components(separatedBy: "CodexThreadStatusIndicator(state: thread.state)\n        .frame(width: 24, height: 24)").count - 1,
      1
    )
    XCTAssertTrue(source.contains(".padding(.leading, 24)"))
    XCTAssertFalse(source.contains(".padding(.leading, 38)"))
    XCTAssertFalse(source.contains("if !thread.state.isActive"))
  }

  func testQuickTodoRequiresExplicitSubmitAndRetainsDetailedComposerRoute() throws {
    let source = try mobileSource("Views/TodosMobileView.swift")

    XCTAssertTrue(source.contains("TextField(\"New To-do\", text: $quickTitle)"))
    XCTAssertTrue(source.contains("if quickCanSubmit { return \"arrow.up\" }"))
    XCTAssertTrue(source.contains("JoiDrawerButton(action: onCreateTodo)"))
    XCTAssertTrue(source.contains("let saved = await model.createTodo(title: title)"))
    XCTAssertFalse(source.contains("model.createTodo(title: spokenTitle)"))
  }

  func testNotesReuseTodoFormattingToolbarAndReturnTargetsDescription() throws {
    let notes = try mobileSource("Views/NotesMobileView.swift")
    let todoEditor = try mobileSource("Views/TodoCreationView.swift")

    XCTAssertTrue(notes.contains("submitLabel(.next)"))
    XCTAssertTrue(notes.contains(".onSubmit(focusDescriptionEditor)"))
    XCTAssertTrue(notes.contains("TodoMarkdownToolbar("))
    XCTAssertFalse(notes.contains("TextField(\"Title\", text: $title, axis: .vertical)"))
    XCTAssertTrue(todoEditor.contains("struct TodoMarkdownToolbar: View"))
    XCTAssertTrue(todoEditor.contains("TodoMarkdownToolbar(\n      activeCommands: $activeMarkdownCommands"))
  }

  func testTodayTabUsesHomeSymbol() throws {
    let source = try mobileSource("Views/MobileRootView.swift")
    XCTAssertTrue(source.contains("case .today: \"house\""))
  }

  private func mobileSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repositoryRoot
        .appendingPathComponent("Mobile/iAgentMobile")
        .appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }
}

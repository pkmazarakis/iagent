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

  func testHiddenArtifactMentionSurfacesCannotCapturePageTouches() throws {
    let source = try mobileSource("Views/TodoCreationView.swift")

    XCTAssertTrue(
      source.contains(
        ".overlay(alignment: .topLeading) {\n        if isShowingPicker {\n          GeometryReader"
      )
    )
    XCTAssertTrue(source.contains(".allowsHitTesting(query != nil)"))
    XCTAssertGreaterThanOrEqual(
      source.components(separatedBy: ".allowsHitTesting(false)").count - 1,
      3
    )
    XCTAssertFalse(
      source.contains("GeometryReader { proxy in\n          if isShowingPicker")
    )
  }

  func testDesktopArtifactMentionAnchorsAreInertWhilePickerIsHidden() throws {
    let picker = try desktopSource("ArtifactMentionPicker.swift")
    let integrations = try desktopSource("PanelCreationViews.swift")

    XCTAssertTrue(picker.contains("override func hitTest(_: NSPoint) -> NSView? { nil }"))
    XCTAssertTrue(picker.contains(".allowsHitTesting(false)"))
    XCTAssertGreaterThanOrEqual(
      integrations.components(separatedBy: ".artifactMentionPicker(").count - 1,
      5
    )

    XCTAssertTrue(
      picker.contains(
        "panel.orderFrontRegardless()\n        installEventMonitorIfNeeded()"
      )
    )
    XCTAssertTrue(
      picker.contains(
        "private func hide() {\n        removeEventMonitor()"
      )
    )
    XCTAssertTrue(
      picker.contains(
        "func tearDown() {\n        hide()\n        removeWindowObservers()"
      )
    )
    XCTAssertTrue(
      picker.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)")
    )
    XCTAssertFalse(picker.contains(".leftMouseDown"))
    XCTAssertFalse(picker.contains(".rightMouseDown"))
    XCTAssertFalse(picker.contains("init() {\n        eventMonitor ="))
  }

  func testNoteTitleAndBodyStayIndependentAcrossRestoreSaveVoiceAndMeetingPaths() throws {
    let editor = try mobileSource("Views/NotesMobileView.swift")
    let model = try mobileSource("Model/MobileAppModel.swift")
    let meetingSummary = try mobileSource("Model/MeetingSummaryModel.swift")

    XCTAssertTrue(editor.contains("_title = State(initialValue: route.note?.title ?? \"\")"))
    XCTAssertTrue(editor.contains("_bodyText = State(initialValue: route.note?.body ?? \"\")"))
    XCTAssertTrue(editor.contains("title: title,\n      body: bodyText"))
    XCTAssertTrue(editor.contains("bodyText = dictationBase"))

    XCTAssertTrue(
      model.contains(
        "title: title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? \"Untitled note\",\n      body: body"
      )
    )
    XCTAssertTrue(model.contains("meeting.title = note.title"))
    XCTAssertGreaterThanOrEqual(
      model.components(separatedBy: "title: activeMeetingTitle").count - 1,
      2
    )
    XCTAssertFalse(model.contains("MeetingTitleGenerator"))
    XCTAssertFalse(model.contains("scheduleMeetingTitleGeneration"))
    XCTAssertFalse(meetingSummary.contains("generateTitle(from transcript:"))
  }

  func testTodayTabUsesHomeSymbol() throws {
    let source = try mobileSource("Views/MobileRootView.swift")
    XCTAssertTrue(source.contains("case .today: \"house\""))
  }

  private func mobileSource(_ relativePath: String) throws -> String {
    try String(
      contentsOf: repositoryRoot
        .appendingPathComponent("Mobile/iAgentMobile")
        .appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }

  private func desktopSource(_ relativePath: String) throws -> String {
    try String(
      contentsOf: repositoryRoot
        .appendingPathComponent("Sources/iAgentPanel")
        .appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

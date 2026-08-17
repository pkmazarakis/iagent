import Foundation
import XCTest

final class AssistantActionSettingsSourceTests: XCTestCase {
  func testSettingsExposeFourIndependentPreparationTogglesWithAccessibleTargets() throws {
    let source = try mobileSettingsSource()

    XCTAssertTrue(source.contains("assistantActionsSection"))
    XCTAssertTrue(source.contains("ForEach(AssistantActionCapability.allCases"))
    XCTAssertTrue(source.contains("Toggle(isOn: assistantActionBinding(for: capability))"))
    XCTAssertTrue(source.contains(".frame(minHeight: 44)"))
    XCTAssertTrue(source.contains(".disabled(actionSettings.isUpdating(capability))"))
    XCTAssertTrue(source.contains("settings.assistant-actions.error"))
    XCTAssertTrue(
      source.contains("settings.assistant-actions.\\(capability.rawValue).toggle")
    )
    XCTAssertFalse(source.localizedCaseInsensitiveContains("full autonomy"))
  }

  func testSettingsExplainReviewAndExplicitConfirmationBoundary() throws {
    let source = try mobileSettingsSource()

    XCTAssertTrue(source.contains("settingsSectionHeader(\"Assistant actions\")"))
    XCTAssertTrue(source.contains("enabled for a new install"))
    XCTAssertTrue(source.contains("Your saved choices stay as set"))
    XCTAssertTrue(source.contains("prepare a review card"))
    XCTAssertTrue(source.contains("explicitly confirm"))
    XCTAssertTrue(source.contains("nothing is created, saved, sent, or handed off"))
  }

  func testCalendarAvailabilityIsTruthfulWithoutRequestingPermissionFromSettings() throws {
    let source = try mobileSettingsSource()

    XCTAssertTrue(source.contains("Calendar permission is requested only after confirmation."))
    XCTAssertTrue(
      source.contains("Calendar access is denied; review cards can still be prepared.")
    )
    XCTAssertTrue(source.contains("Calendar access is ready and checked again after confirmation."))
    XCTAssertFalse(source.contains("requestContextualWriteAccess()"))
  }

  func testActionReviewUsesOnlyContentAndCompactExplicitControls() throws {
    let source = try assistantActionReviewSource()

    XCTAssertTrue(source.contains("Image(systemName: \"xmark\")"))
    XCTAssertTrue(source.contains("Image(systemName: \"checkmark\")"))
    XCTAssertGreaterThanOrEqual(
      source.components(separatedBy: ".frame(width: 44, height: 44)").count - 1,
      2
    )
    XCTAssertTrue(source.contains("Proposed content:"))
    XCTAssertTrue(source.contains("No change happens before confirmation."))
    XCTAssertFalse(source.contains("DisclosureGroup(\"Exact payload\""))
    XCTAssertFalse(source.contains("private func reviewField"))
    XCTAssertFalse(source.contains(".buttonStyle(.bordered)"))
    XCTAssertFalse(source.contains(".buttonStyle(.borderedProminent)"))
  }

  func testActionReviewGivesContentFullWidthAboveASeparateControlRow() throws {
    let source = try assistantActionReviewSource()
    let body = try sourceSlice(
      source,
      from: "public var body: some View",
      to: "private var proposalBody: some View"
    )

    XCTAssertTrue(body.contains("VStack(alignment: .leading"))
    XCTAssertTrue(body.contains("proposalBody"))
    XCTAssertTrue(body.contains("actionButtons"))
    XCTAssertTrue(body.contains(".frame(maxWidth: .infinity, alignment: .trailing)"))
    XCTAssertLessThan(
      try XCTUnwrap(body.range(of: "proposalBody")?.lowerBound),
      try XCTUnwrap(body.range(of: "actionButtons")?.lowerBound)
    )
    XCTAssertFalse(body.contains("HStack(alignment: .bottom"))
    XCTAssertFalse(source.contains("@Environment(\\.dynamicTypeSize)"))
  }

  func testLongNoteReviewStartsCollapsedAndOffersExplicitDisclosure() throws {
    let source = try assistantActionReviewSource()

    XCTAssertTrue(source.contains("@State private var isBodyExpanded = false"))
    XCTAssertTrue(source.contains("isCollapsibleNote"))
    XCTAssertTrue(
      source.contains(".lineLimit(isCollapsibleNote && !isBodyExpanded ? 5 : nil)")
    )
    XCTAssertTrue(source.contains("isBodyExpanded ? \"Show less\" : \"Show more\""))
    XCTAssertTrue(source.contains(".onChange(of: intent.id)"))
    XCTAssertTrue(source.contains("isBodyExpanded = false"))
  }

  func testExpandedNoteRetainsTheEntireProposedValue() throws {
    let source = try assistantActionReviewSource()
    let proposalBody = try sourceSlice(
      source,
      from: "private var proposalBody: some View",
      to: "private var actionButtons: some View"
    )
    let accessibilityLabel = try sourceSlice(
      source,
      from: "private var proposalBodyAccessibilityLabel: String",
      to: "private var presentation: AssistantActionReviewPresentation"
    )

    XCTAssertTrue(proposalBody.contains("Text(reviewBody)"))
    XCTAssertTrue(proposalBody.contains("? 5 : nil"))
    XCTAssertTrue(proposalBody.contains(".accessibilityLabel(proposalBodyAccessibilityLabel)"))
    XCTAssertFalse(proposalBody.contains(".prefix("))
    XCTAssertFalse(proposalBody.contains("String(reviewBody"))
    XCTAssertTrue(accessibilityLabel.contains("guard isCollapsibleNote, !isBodyExpanded else"))
    XCTAssertTrue(accessibilityLabel.contains("Proposed content: \\(reviewBody)"))
  }

  func testActionReviewControlsStayAccessibleAndCannotAutoCommit() throws {
    let source = try assistantActionReviewSource()

    XCTAssertGreaterThanOrEqual(
      source.components(separatedBy: ".frame(width: 44, height: 44)").count - 1,
      2
    )
    XCTAssertTrue(source.contains(".accessibilityLabel(intent.review.cancelVerb)"))
    XCTAssertTrue(source.contains(".accessibilityLabel(intent.review.primaryVerb)"))
    XCTAssertTrue(source.contains("Button(role: .cancel, action: onCancel)"))
    XCTAssertTrue(source.contains("Button(action: onConfirm)"))
    XCTAssertFalse(source.contains(".onAppear"))
    XCTAssertFalse(source.contains("Task {"))
    XCTAssertFalse(source.contains("broker.confirm"))
    XCTAssertFalse(source.contains("broker.commit"))
  }

  func testReviewedCalendarCannotSilentlyFallBackToEventKitDefault() throws {
    let source = try fullAssistantActionViewsSource()
    let controller = try sourceSlice(
      source,
      from: "private struct EventEditorController",
      to: "private struct CalendarEditorFailureView"
    )

    XCTAssertTrue(controller.contains("if let calendarIdentifier = draft.calendarIdentifier"))
    XCTAssertTrue(
      controller.contains("guard let calendar = eventStore.calendar(withIdentifier:")
    )
    XCTAssertTrue(controller.contains("guard calendar.allowsContentModifications"))
    XCTAssertTrue(controller.contains("return failureController("))
    XCTAssertTrue(controller.contains("event.calendar = calendar"))
    XCTAssertFalse(
      controller.contains("if let calendar = eventStore.calendar(withIdentifier:")
    )
  }

  func testNativeFinalizationFailureOffersExactRetryWithoutRepeatingHandoffUI() throws {
    let source = try askIAgentViewSource()

    XCTAssertTrue(source.contains("private enum AskIAgentNativeFinalizationRetry"))
    XCTAssertTrue(source.contains("nativeFinalizationRetry = .calendar("))
    XCTAssertTrue(source.contains("nativeFinalizationRetry = .codex("))
    XCTAssertTrue(source.contains("nativeFinalizationRecoveryView(retry)"))
    XCTAssertTrue(source.contains("Retry final status"))
    XCTAssertTrue(source.contains("retryNativeFinalization(retry)"))
    XCTAssertTrue(source.contains("without repeating the handoff"))
  }

  func testPendingStoreRecoveryErrorIsVisibleWithoutAnActionCard() throws {
    let source = try askIAgentViewSource()

    XCTAssertTrue(source.contains("if actionIntent == nil, let actionErrorMessage"))
    XCTAssertTrue(source.contains("Action recovery error."))
    XCTAssertTrue(
      try fullAssistantActionViewsSource().contains("mostRecentRestorableIntent()")
    )
  }

  private func mobileSettingsSource() throws -> String {
    let repositoryRoot = repositoryRoot()
    return try String(
      contentsOf: repositoryRoot
        .appendingPathComponent("Mobile/iAgentMobile/Views/MobileSettingsView.swift"),
      encoding: .utf8
    )
  }

  private func assistantActionReviewSource() throws -> String {
    let source = try fullAssistantActionViewsSource()
    guard let start = source.range(of: "public struct AssistantActionReviewView"),
          let end = source.range(
            of: "private struct AssistantActionReviewPresentation",
            range: start.upperBound..<source.endIndex
          )
    else {
      XCTFail("AssistantActionReviewView source boundary is missing")
      return ""
    }
    return String(source[start.lowerBound..<end.lowerBound])
  }

  private func fullAssistantActionViewsSource() throws -> String {
    try String(
      contentsOf: repositoryRoot()
        .appendingPathComponent("Sources/iAgentActions/AssistantActionViews.swift"),
      encoding: .utf8
    )
  }

  private func askIAgentViewSource() throws -> String {
    try String(
      contentsOf: repositoryRoot()
        .appendingPathComponent("Mobile/iAgentMobile/Views/AskIAgentView.swift"),
      encoding: .utf8
    )
  }

  private func sourceSlice(_ source: String, from startMarker: String, to endMarker: String) throws
    -> String
  {
    let start = try XCTUnwrap(source.range(of: startMarker))
    let end = try XCTUnwrap(
      source.range(of: endMarker, range: start.upperBound..<source.endIndex)
    )
    return String(source[start.lowerBound..<end.lowerBound])
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

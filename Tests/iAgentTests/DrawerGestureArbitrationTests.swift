import XCTest
@testable import iAgentCore

final class DrawerGestureArbitrationTests: XCTestCase {
  func testPageSwipeTracksFromAnywhereWithoutAnEdgeRequirement() {
    XCTAssertTrue(
      PageSwipeGestureArbitration.shouldTrack(
        horizontalTranslation: 42,
        verticalTranslation: 8,
        localHorizontalGestureIsActive: false
      )
    )
    XCTAssertEqual(
      PageSwipeGestureArbitration.pageDelta(
        predictedHorizontalTranslation: -120,
        predictedVerticalTranslation: 12,
        localHorizontalGestureIsActive: false
      ),
      1
    )
  }

  func testNoteDeleteSwipeRetainsHorizontalGestureOwnership() {
    XCTAssertFalse(
      PageSwipeGestureArbitration.shouldTrack(
        horizontalTranslation: -100,
        verticalTranslation: 4,
        localHorizontalGestureIsActive: true
      )
    )
    XCTAssertNil(
      PageSwipeGestureArbitration.pageDelta(
        predictedHorizontalTranslation: -180,
        predictedVerticalTranslation: 4,
        localHorizontalGestureIsActive: true
      )
    )
  }

  func testPageSwipeRejectsVerticalOrShortReleases() {
    XCTAssertFalse(
      PageSwipeGestureArbitration.shouldTrack(
        horizontalTranslation: 20,
        verticalTranslation: 40,
        localHorizontalGestureIsActive: false
      )
    )
    XCTAssertNil(
      PageSwipeGestureArbitration.pageDelta(
        predictedHorizontalTranslation: 50,
        predictedVerticalTranslation: 5,
        localHorizontalGestureIsActive: false
      )
    )
  }

  func testVerticalNoteRowDragRemainsOwnedByDrawerContentScroll() {
    XCTAssertFalse(
      HorizontalRowSwipeGestureArbitration.shouldBegin(
        horizontalVelocity: 90,
        verticalVelocity: -700
      )
    )
    XCTAssertFalse(
      HorizontalRowSwipeGestureArbitration.shouldBegin(
        horizontalVelocity: 300,
        verticalVelocity: -300
      )
    )
  }

  func testHorizontalNoteRowDragOwnsSwipeDeleteInteraction() {
    XCTAssertTrue(
      HorizontalRowSwipeGestureArbitration.shouldBegin(
        horizontalVelocity: -700,
        verticalVelocity: 90
      )
    )
  }

  func testActivationGateSuppressesFingerUpActionUntilExplicitlyReleased() {
    let gate = DrawerActivationGate()
    var activationCount = 0

    gate.setBlocked(true)
    XCTAssertFalse(gate.performIfAllowed { activationCount += 1 })
    XCTAssertEqual(activationCount, 0)

    gate.setBlocked(false)
    XCTAssertTrue(gate.performIfAllowed { activationCount += 1 })
    XCTAssertEqual(activationCount, 1)
  }

  func testActivationGateRemainsBlockedAcrossRepeatedPanUpdates() {
    let gate = DrawerActivationGate()
    gate.setBlocked(true)
    gate.setBlocked(true)

    XCTAssertTrue(gate.blocksActivation)
    XCTAssertFalse(gate.performIfAllowed {})

    gate.setBlocked(false)
    XCTAssertFalse(gate.blocksActivation)
  }

  func testExpandedDrawerOwnsOnlyDownwardPanThatBeginsAtContentTop() {
    XCTAssertEqual(owner(expanded: true, offset: 0, x: 0, y: 700), .drawer)
    XCTAssertEqual(owner(expanded: true, offset: 40, x: 0, y: 700), .content)
    XCTAssertEqual(owner(expanded: true, offset: 0, x: 0, y: -700), .content)
  }

  func testCollapsedDrawerOwnsUpwardPanButLeavesHorizontalRowsAlone() {
    XCTAssertEqual(owner(expanded: false, offset: 0, x: 0, y: -700), .drawer)
    XCTAssertEqual(owner(expanded: false, offset: 0, x: 0, y: 700), .ignored)
    XCTAssertEqual(owner(expanded: false, offset: 0, x: 800, y: -120), .ignored)
  }

  func testTopToleranceAvoidsFractionalOffsetJitter() {
    XCTAssertEqual(owner(expanded: true, offset: 1.49, x: 0, y: 500), .drawer)
    XCTAssertEqual(owner(expanded: true, offset: 1.51, x: 0, y: 500), .content)
  }

  func testDetentResolutionUsesDistanceOrVelocitySymmetrically() {
    let travel = 400.0

    XCTAssertTrue(target(startedExpanded: true, translation: 80, velocity: 100, travel: travel))
    XCTAssertFalse(target(startedExpanded: true, translation: 120, velocity: 100, travel: travel))
    XCTAssertFalse(target(startedExpanded: true, translation: 20, velocity: 700, travel: travel))

    XCTAssertFalse(target(startedExpanded: false, translation: -80, velocity: -100, travel: travel))
    XCTAssertTrue(target(startedExpanded: false, translation: -120, velocity: -100, travel: travel))
    XCTAssertTrue(target(startedExpanded: false, translation: -20, velocity: -700, travel: travel))
  }

  func testReversingDirectionDoesNotChangeOwnerForAnActiveGesture() {
    // Ownership is chosen only once, at recognizer begin. The policy has no API
    // for re-evaluating a gesture after it begins, which prevents handoff jitter.
    let initialOwner = owner(expanded: true, offset: 0, x: 0, y: 600)
    XCTAssertEqual(initialOwner, .drawer)
    XCTAssertTrue(target(startedExpanded: true, translation: 0, velocity: -400, travel: 400))
  }

  func testExpandedContentNeverHandsDownwardPanToDrawerWhenTouchStartsScrolled() {
    for offset in [2.0, 20.0, 400.0] {
      XCTAssertEqual(
        owner(expanded: true, offset: offset, x: 0, y: 1_200),
        .content,
        "A touch that starts in scrolled content must remain content-owned"
      )
    }
  }

  func testExpandedUpwardPanAlwaysScrollsContentIncludingAtTop() {
    for offset in [0.0, 20.0, 400.0] {
      XCTAssertEqual(owner(expanded: true, offset: offset, x: 0, y: -800), .content)
    }
  }

  func testAmbiguousDiagonalDoesNotStealHorizontalRowGesture() {
    XCTAssertEqual(owner(expanded: false, offset: 0, x: 500, y: -500), .ignored)
    XCTAssertEqual(owner(expanded: true, offset: 0, x: -600, y: 599), .ignored)
  }

  func testShortSlowDragReturnsToStartingDetent() {
    XCTAssertTrue(target(startedExpanded: true, translation: 30, velocity: 100, travel: 400))
    XCTAssertFalse(target(startedExpanded: false, translation: -30, velocity: -100, travel: 400))
  }

  private func owner(
    expanded: Bool,
    offset: Double,
    x: Double,
    y: Double
  ) -> DrawerPanOwner {
    DrawerGestureArbitration.owner(
      isExpanded: expanded,
      contentOffset: offset,
      topOffset: 0,
      horizontalVelocity: x,
      verticalVelocity: y
    )
  }

  private func target(
    startedExpanded: Bool,
    translation: Double,
    velocity: Double,
    travel: Double
  ) -> Bool {
    DrawerGestureArbitration.targetIsExpanded(
      startedExpanded: startedExpanded,
      translation: translation,
      verticalVelocity: velocity,
      detentTravel: travel
    )
  }
}

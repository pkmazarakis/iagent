import AppKit
import XCTest

@testable import iAgentPanel

final class PanelTooltipTests: XCTestCase {
    func testDefaultHoverDelayIsExactlyHalfASecond() {
        XCTAssertEqual(PanelTooltipMetrics.defaultDelay, 0.5)
    }

    func testTopPinnedTooltipIsPlacedBelowTriggerAndInsidePanelWidth() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let parentFrame = NSRect(x: 340, y: 552, width: 760, height: 348)
        let anchorRect = NSRect(x: 910, y: 864, width: 22, height: 28)
        let tooltipSize = NSSize(width: 260, height: 64)

        let frame = PanelTooltipMetrics.frame(
            anchorRect: anchorRect,
            tooltipSize: tooltipSize,
            parentFrame: parentFrame,
            screenFrame: screenFrame
        )

        XCTAssertEqual(
            frame.maxY,
            anchorRect.minY - PanelTooltipMetrics.gap,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(frame.minX, parentFrame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, parentFrame.maxX)
        XCTAssertTrue(frame.intersects(parentFrame))
    }

    @MainActor
    func testHoverGateCanRevealDeterministicallyAndHidesOnExit() {
        var showCount = 0
        var hideCount = 0
        let gate = PanelTooltipHoverGate(
            onShow: { showCount += 1 },
            onHide: { hideCount += 1 }
        )

        gate.setHovering(true)

        XCTAssertTrue(gate.isHovering)
        XCTAssertTrue(gate.hasPendingShow)
        XCTAssertFalse(gate.isPresented)
        XCTAssertEqual(showCount, 0)

        gate.firePendingForTesting()

        XCTAssertFalse(gate.hasPendingShow)
        XCTAssertTrue(gate.isPresented)
        XCTAssertEqual(showCount, 1)

        gate.setHovering(false)

        XCTAssertFalse(gate.isHovering)
        XCTAssertFalse(gate.isPresented)
        XCTAssertEqual(hideCount, 1)
    }

    @MainActor
    func testHoverExitCancelsPendingReveal() {
        var showCount = 0
        var hideCount = 0
        let gate = PanelTooltipHoverGate(
            onShow: { showCount += 1 },
            onHide: { hideCount += 1 }
        )

        gate.setHovering(true)
        gate.setHovering(false)
        gate.firePendingForTesting()

        XCTAssertFalse(gate.hasPendingShow)
        XCTAssertFalse(gate.isPresented)
        XCTAssertEqual(showCount, 0)
        XCTAssertEqual(hideCount, 0)
    }

    @MainActor
    func testPresenterUsesNonactivatingChildPanelAboveParentAtSameLevel() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen is available to host an AppKit panel")
        }

        let parentFrame = NSRect(
            x: screen.frame.midX - 380,
            y: screen.frame.maxY - 348,
            width: 760,
            height: 348
        )
        let parent = PanelWindow(
            contentRect: parentFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        parent.level = .screenSaver
        parent.isOpaque = false
        parent.backgroundColor = .clear

        let contentView = NSView(frame: NSRect(origin: .zero, size: parentFrame.size))
        let anchorView = NSView(frame: NSRect(x: 560, y: 284, width: 22, height: 28))
        contentView.addSubview(anchorView)
        parent.contentView = contentView
        parent.orderFrontRegardless()

        let presenter = PanelTooltipPresenter()
        defer {
            presenter.hide()
            parent.orderOut(nil)
        }

        presenter.show(text: "Messages sync is healthy", anchorView: anchorView)

        let tooltip = try XCTUnwrap(presenter.tooltipWindow)
        XCTAssertTrue(tooltip.parent === parent)
        XCTAssertTrue(parent.childWindows?.contains(where: { $0 === tooltip }) == true)
        XCTAssertEqual(tooltip.level, parent.level)
        XCTAssertTrue(tooltip.styleMask.contains(.borderless))
        XCTAssertTrue(tooltip.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(tooltip.ignoresMouseEvents)
        XCTAssertFalse(tooltip.canBecomeKey)
        XCTAssertFalse(tooltip.canBecomeMain)
        XCTAssertFalse(tooltip.isKeyWindow)

        let anchorRectOnScreen = parent.convertToScreen(
            anchorView.convert(anchorView.bounds, to: nil)
        )
        XCTAssertLessThanOrEqual(
            tooltip.frame.maxY,
            anchorRectOnScreen.minY - PanelTooltipMetrics.gap + 0.001
        )

        presenter.hide()

        XCTAssertNil(presenter.tooltipWindow)
        XCTAssertNil(tooltip.parent)
        XCTAssertFalse(tooltip.isVisible)
    }

    @MainActor
    func testOrderingParentOutRemovesTooltipAndDoesNotResurrectIt() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen is available to host an AppKit panel")
        }

        let parent = PanelWindow(
            contentRect: NSRect(
                x: screen.frame.midX - 380,
                y: screen.frame.maxY - 348,
                width: 760,
                height: 348
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        parent.level = .screenSaver
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 348))
        let anchorView = NSView(frame: NSRect(x: 560, y: 284, width: 22, height: 28))
        contentView.addSubview(anchorView)
        parent.contentView = contentView
        parent.orderFrontRegardless()

        let presenter = PanelTooltipPresenter()
        var parentUnavailableCount = 0
        presenter.onParentWindowUnavailable = {
            parentUnavailableCount += 1
        }
        defer {
            presenter.hide()
            parent.orderOut(nil)
        }

        presenter.show(text: "Messages sync is healthy", anchorView: anchorView)
        let originalTooltip = try XCTUnwrap(presenter.tooltipWindow)

        parent.orderOut(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(parentUnavailableCount, 1)
        XCTAssertNil(presenter.tooltipWindow)
        XCTAssertNil(originalTooltip.parent)
        XCTAssertFalse(originalTooltip.isVisible)

        parent.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(presenter.tooltipWindow)
        XCTAssertFalse(originalTooltip.isVisible)
    }
}

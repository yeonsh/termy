import XCTest
import AppKit
@testable import termy

final class TerminalScrollWheelTests: XCTestCase {
    // A power of two keeps the banked remainders exact.
    private let cellHeight: CGFloat = 16

    // MARK: - ScrollWheelLineAccumulator

    /// SwiftTerm f37922e scrolled a full row for any non-zero precise
    /// delta, so a 1pt trackpad nudge moved a whole row of text.
    func test_subCellPreciseDelta_scrollsNothing() {
        var accumulator = ScrollWheelLineAccumulator()

        let lines = accumulator.lines(delta: 1, isPrecise: true, cellHeight: cellHeight, route: .scrollback)

        XCTAssertEqual(lines, 0)
        XCTAssertEqual(accumulator.remainder, 2)
    }

    func test_preciseDeltas_accumulateAcrossEvents() {
        var accumulator = ScrollWheelLineAccumulator()

        let perEvent = (0..<8).map { _ in
            accumulator.lines(delta: 2, isPrecise: true, cellHeight: cellHeight, route: .scrollback)
        }

        XCTAssertEqual(perEvent, [0, 0, 0, 1, 0, 0, 0, 1])
        XCTAssertEqual(accumulator.remainder, 0)
    }

    /// SwiftTerm's step curve turned a 100pt flick into a full screen (40
    /// rows). Ghostty-matched travel is 200pt: 12 rows with 8pt carried.
    func test_largePreciseDelta_isDistanceAccurate() {
        var accumulator = ScrollWheelLineAccumulator()

        let lines = accumulator.lines(delta: 100, isPrecise: true, cellHeight: cellHeight, route: .scrollback)

        XCTAssertEqual(lines, 12)
        XCTAssertEqual(accumulator.remainder, 8)
    }

    func test_negativePreciseDelta_scrollsDown() {
        var accumulator = ScrollWheelLineAccumulator()

        let lines = accumulator.lines(delta: -44, isPrecise: true, cellHeight: cellHeight, route: .scrollback)

        XCTAssertEqual(lines, -5)
        XCTAssertEqual(accumulator.remainder, -8)
    }

    func test_directionReversal_drainsBankedTravel() {
        var accumulator = ScrollWheelLineAccumulator()

        _ = accumulator.lines(delta: 5, isPrecise: true, cellHeight: cellHeight, route: .scrollback)
        let lines = accumulator.lines(delta: -5, isPrecise: true, cellHeight: cellHeight, route: .scrollback)

        XCTAssertEqual(lines, 0)
        XCTAssertEqual(accumulator.remainder, 0)
    }

    /// Travel banked while scrolling local scrollback must not leak into
    /// wheel reports once the child turns mouse tracking on.
    func test_routeChange_restartsBank() {
        var accumulator = ScrollWheelLineAccumulator()

        _ = accumulator.lines(delta: 5, isPrecise: true, cellHeight: cellHeight, route: .scrollback)
        let lines = accumulator.lines(delta: 5, isPrecise: true, cellHeight: cellHeight, route: .mouseReport)

        XCTAssertEqual(lines, 0)
        XCTAssertEqual(accumulator.remainder, 10)
    }

    func test_wheelTick_scrollsThreeRows() {
        var accumulator = ScrollWheelLineAccumulator()

        XCTAssertEqual(accumulator.lines(delta: 1, isPrecise: false, cellHeight: cellHeight, route: .scrollback), 3)
        XCTAssertEqual(accumulator.lines(delta: -1, isPrecise: false, cellHeight: cellHeight, route: .scrollback), -3)
    }

    /// macOS reports a slow notch as a fraction of a tick; it still counts as
    /// one whole tick.
    func test_slowWheelNotch_countsAsWholeTick() {
        var accumulator = ScrollWheelLineAccumulator()

        XCTAssertEqual(accumulator.lines(delta: 0.1, isPrecise: false, cellHeight: cellHeight, route: .scrollback), 3)
        XCTAssertEqual(accumulator.lines(delta: -0.1, isPrecise: false, cellHeight: cellHeight, route: .scrollback), -3)
    }

    func test_acceleratedWheel_carriesFractionalRows() {
        var accumulator = ScrollWheelLineAccumulator()

        XCTAssertEqual(accumulator.lines(delta: 2.5, isPrecise: false, cellHeight: cellHeight, route: .scrollback), 7)
        XCTAssertEqual(accumulator.remainder, 8)
        XCTAssertEqual(accumulator.lines(delta: 2.5, isPrecise: false, cellHeight: cellHeight, route: .scrollback), 8)
        XCTAssertEqual(accumulator.remainder, 0)
    }

    func test_sensitivity_scalesBothDevices() {
        var precise = ScrollWheelLineAccumulator()
        var wheel = ScrollWheelLineAccumulator()

        XCTAssertEqual(precise.lines(delta: 4, isPrecise: true, cellHeight: cellHeight, route: .scrollback, sensitivity: 2), 1)
        XCTAssertEqual(wheel.lines(delta: 1, isPrecise: false, cellHeight: cellHeight, route: .scrollback, sensitivity: 0.5), 1)
        XCTAssertEqual(wheel.remainder, 8)
    }

    func test_zeroDelta_scrollsNothing() {
        var accumulator = ScrollWheelLineAccumulator()

        XCTAssertEqual(accumulator.lines(delta: 0, isPrecise: true, cellHeight: cellHeight, route: .scrollback), 0)
        XCTAssertEqual(accumulator.lines(delta: 0, isPrecise: false, cellHeight: cellHeight, route: .scrollback), 0)
    }

    // MARK: - TerminalScrollSensitivity

    func test_sensitivity_defaultsToOneWhenUnset() {
        // `UserDefaults.double(forKey:)` returns 0 for a missing key.
        XCTAssertEqual(TerminalScrollSensitivity.resolve(stored: 0), 1)
    }

    func test_sensitivity_usesStoredValue() {
        XCTAssertEqual(TerminalScrollSensitivity.resolve(stored: 1.5), 1.5)
    }

    func test_sensitivity_clampsOutOfRangeValues() {
        XCTAssertEqual(TerminalScrollSensitivity.resolve(stored: 50), 10)
        XCTAssertEqual(TerminalScrollSensitivity.resolve(stored: 0.01), 0.1, accuracy: 0.0001)
        XCTAssertEqual(TerminalScrollSensitivity.resolve(stored: -2), 1)
    }

    // MARK: - TerminalScrollRoute

    func test_route_prefersMouseReportingOverAlternateBuffer() {
        XCTAssertEqual(TerminalScrollRoute.route(mouseReporting: true, alternateBuffer: true), .mouseReport)
        XCTAssertEqual(TerminalScrollRoute.route(mouseReporting: true, alternateBuffer: false), .mouseReport)
        XCTAssertEqual(TerminalScrollRoute.route(mouseReporting: false, alternateBuffer: true), .cursorKeys)
        XCTAssertEqual(TerminalScrollRoute.route(mouseReporting: false, alternateBuffer: false), .scrollback)
    }

    // MARK: - ScrollGestureLatch

    func test_latch_keepsGestureOnViewAfterPointerLeaves() {
        var latch = ScrollGestureLatch()

        XCTAssertTrue(latch.claims(phase: .began, momentumPhase: [], isOverView: { true }))
        XCTAssertTrue(latch.claims(phase: .changed, momentumPhase: [], isOverView: { false }))
        XCTAssertTrue(latch.claims(phase: .ended, momentumPhase: [], isOverView: { false }))
        XCTAssertTrue(latch.claims(phase: [], momentumPhase: .began, isOverView: { false }))
        XCTAssertTrue(latch.claims(phase: [], momentumPhase: .changed, isOverView: { false }))
        XCTAssertTrue(latch.claims(phase: [], momentumPhase: .ended, isOverView: { false }))
    }

    /// Momentum from a flick that started in another scroll view must not be
    /// stolen when it drifts over the terminal.
    func test_latch_ignoresGestureThatBeganElsewhere() {
        var latch = ScrollGestureLatch()

        XCTAssertFalse(latch.claims(phase: .began, momentumPhase: [], isOverView: { false }))
        XCTAssertFalse(latch.claims(phase: .changed, momentumPhase: [], isOverView: { true }))
        XCTAssertFalse(latch.claims(phase: [], momentumPhase: .changed, isOverView: { true }))
    }

    func test_latch_releasesWhenMomentumEnds() {
        var latch = ScrollGestureLatch()

        _ = latch.claims(phase: .began, momentumPhase: [], isOverView: { true })
        _ = latch.claims(phase: [], momentumPhase: .ended, isOverView: { true })

        XCTAssertFalse(latch.claims(phase: [], momentumPhase: .changed, isOverView: { true }))
    }

    func test_latch_routesClassicWheelByPosition() {
        var latch = ScrollGestureLatch()

        XCTAssertTrue(latch.claims(phase: [], momentumPhase: [], isOverView: { true }))
        XCTAssertFalse(latch.claims(phase: [], momentumPhase: [], isOverView: { false }))
    }

    func test_latch_evaluatesPositionOnlyWhenGestureBegins() {
        var latch = ScrollGestureLatch()
        var hitTests = 0
        let over: () -> Bool = { hitTests += 1; return true }

        _ = latch.claims(phase: .began, momentumPhase: [], isOverView: over)
        for _ in 0..<10 {
            _ = latch.claims(phase: .changed, momentumPhase: [], isOverView: over)
        }

        XCTAssertEqual(hitTests, 1)
    }

    // MARK: - TermyTerminalView wiring

    /// Regression for "scrolling is far too fast": 60 trackpad events of 2pt
    /// each (120pt of finger travel) used to scroll 60 rows — one per event.
    /// They must scroll by distance instead.
    @MainActor
    func test_tinyTrackpadEvents_scrollByDistanceNotEventCount() throws {
        let view = Self.scrolledTerminal()
        let startRow = view.terminal.buffer.yDisp
        let cellHeight = Self.cellHeight(of: view)
        let event = try XCTUnwrap(Self.scrollEvent(units: .pixel, amount: 2))

        for _ in 0..<60 {
            view.handleScrollWheel(event)
        }

        let travel = 120 * ScrollWheelLineAccumulator.preciseMultiplier * TerminalScrollSensitivity.current()
        let expectedRows = Int(travel / cellHeight)
        XCTAssertLessThan(expectedRows, 60)
        XCTAssertEqual(startRow - view.terminal.buffer.yDisp, expectedRows)
    }

    @MainActor
    func test_wheelTick_scrollsScrollbackByThreeRows() throws {
        let view = Self.scrolledTerminal()
        let startRow = view.terminal.buffer.yDisp
        let event = try XCTUnwrap(Self.scrollEvent(units: .line, amount: 1))
        XCTAssertFalse(event.hasPreciseScrollingDeltas)

        view.handleScrollWheel(event)

        let expectedRows = Int(ScrollWheelLineAccumulator.rowsPerWheelTick * TerminalScrollSensitivity.current())
        XCTAssertEqual(startRow - view.terminal.buffer.yDisp, expectedRows)
    }

    /// Travel left over from one gesture must not tip the next gesture's
    /// first nudge over a row boundary.
    @MainActor
    func test_newGesture_dropsPreviousGesturesRemainder() throws {
        let view = Self.scrolledTerminal()
        let cellHeight = Self.cellHeight(of: view)
        let pointsToTravel = ScrollWheelLineAccumulator.preciseMultiplier * TerminalScrollSensitivity.current()
        let almostARowPoints = ((cellHeight - 1) / pointsToTravel).rounded(.down)
        // Without the reset, the nudge below would cross a row boundary.
        XCTAssertGreaterThanOrEqual((almostARowPoints + 2) * pointsToTravel, cellHeight)
        let almostARow = try XCTUnwrap(Self.scrollEvent(units: .pixel, amount: Int32(almostARowPoints)))
        let nudge = try XCTUnwrap(Self.scrollEvent(units: .pixel, amount: 2, phase: .began))
        XCTAssertEqual(nudge.phase, .began)

        view.handleScrollWheel(almostARow)
        let startRow = view.terminal.buffer.yDisp
        view.handleScrollWheel(nudge)

        XCTAssertEqual(view.terminal.buffer.yDisp, startRow)
    }

    @MainActor
    private static func scrolledTerminal() -> TermyTerminalView {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.feed(text: (0..<600).map { "line \($0)\r\n" }.joined())
        return view
    }

    @MainActor
    private static func cellHeight(of view: TermyTerminalView) -> CGFloat {
        view.getOptimalFrameSize().height / CGFloat(view.terminal.rows)
    }

    private static func scrollEvent(units: CGScrollEventUnit, amount: Int32, phase: CGScrollPhase? = nil) -> NSEvent? {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: units,
            wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0
        ) else { return nil }
        if let phase {
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        return NSEvent(cgEvent: cgEvent)
    }

}

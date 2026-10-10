import XCTest
@testable import termy

@MainActor
final class MissionControlModelTests: XCTestCase {
    func test_setLivePaneIds_flattensWindowsInRegistrationOrder() {
        let model = MissionControlModel(startPump: false)
        let winA = UUID()
        let winB = UUID()
        model.setLivePaneIds(["p1", "p2"], forWindow: winA)
        model.setLivePaneIds(["p3"], forWindow: winB)
        XCTAssertEqual(model.livePaneIds, ["p1", "p2", "p3"])
        XCTAssertEqual(model.paneOrder, ["p1": 0, "p2": 1, "p3": 2])
    }

    func test_removeWindow_dropsThatWindowsPanes() {
        let model = MissionControlModel(startPump: false)
        let winA = UUID()
        let winB = UUID()
        model.setLivePaneIds(["p1", "p2"], forWindow: winA)
        model.setLivePaneIds(["p3"], forWindow: winB)
        model.removeWindow(winA)
        XCTAssertEqual(model.livePaneIds, ["p3"])
        XCTAssertEqual(model.paneOrder, ["p3": 0])
    }

    func test_setLivePaneIds_reRegisteringWindowReplacesItsPanes() {
        let model = MissionControlModel(startPump: false)
        let winA = UUID()
        model.setLivePaneIds(["p1", "p2"], forWindow: winA)
        model.setLivePaneIds(["p1"], forWindow: winA)
        XCTAssertEqual(model.livePaneIds, ["p1"])
        XCTAssertEqual(model.paneOrder, ["p1": 0])
    }

    private func snap(_ id: String, turnOpen: Bool, state: PaneState = .thinking) -> PaneSnapshot {
        var s = PaneSnapshot.empty(paneId: id, projectId: "proj")
        s.state = state
        s.turnOpen = turnOpen
        return s
    }

    func test_midTurnPaneCount_countsOnlyLiveMidTurnPanes() {
        let model = MissionControlModel(startPump: false)
        model.setLivePaneIds(["p1", "p2", "p3"], forWindow: UUID())
        model.applySnapshot(snap("p1", turnOpen: true))
        model.applySnapshot(snap("p2", turnOpen: false, state: .waiting))
        model.applySnapshot(snap("p3", turnOpen: true, state: .waiting))   // permission wait
        model.applySnapshot(snap("closed", turnOpen: true))                // not live
        XCTAssertEqual(model.midTurnPaneCount, 2)
    }

    // Review Focus 2
    func test_midTurnPaneCount_dropsWhenBusyWindowCloses() {
        let model = MissionControlModel(startPump: false)
        let winA = UUID()
        let winB = UUID()
        model.setLivePaneIds(["a1"], forWindow: winA)
        model.setLivePaneIds(["b1"], forWindow: winB)
        model.applySnapshot(snap("a1", turnOpen: true))
        model.applySnapshot(snap("b1", turnOpen: false, state: .idle))
        XCTAssertEqual(model.midTurnPaneCount, 1)
        model.removeWindow(winA)
        XCTAssertEqual(model.midTurnPaneCount, 0)
    }

    func test_removeWindow_firesOnLivePanesChanged() {
        let model = MissionControlModel(startPump: false)
        let win = UUID()
        var calls = 0
        model.onLivePanesChanged = { calls += 1 }
        model.setLivePaneIds(["p1"], forWindow: win)
        model.removeWindow(win)
        XCTAssertEqual(calls, 2)
    }

    func test_snapshotLookup_returnsLatest() {
        let model = MissionControlModel(startPump: false)
        model.applySnapshot(snap("p1", turnOpen: false, state: .idle))
        model.applySnapshot(snap("p1", turnOpen: true))
        XCTAssertEqual(model.snapshot(paneId: "p1")?.turnOpen, true)
        XCTAssertNil(model.snapshot(paneId: "nope"))
    }

    func test_applySnapshot_notifiesSubscriber() {
        let model = MissionControlModel(startPump: false)
        var seen: [String] = []
        model.onSnapshotUpdate = { seen.append($0.paneId) }
        model.applySnapshot(snap("p1", turnOpen: true))
        XCTAssertEqual(seen, ["p1"])
    }
}

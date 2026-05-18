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
}

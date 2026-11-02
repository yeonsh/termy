import XCTest
@testable import termy

// hc pane을 Pane·Workspace에 붙이면서 생긴 순수 규칙들: 닫을 때 무엇을 하는지, 종료 중에 보류된 kill을
// 어떻게 기다리는지, mission control이 hc pane을 어떻게 세는지, OSC 7 경로를 어떻게 읽는지.
// hc Pane 자체는 여기서 만들지 않는다(만들면 HcSessionManager.shared, 곧 사용자 core에 붙는다).

@MainActor
final class PaneLaunchTests: XCTestCase {
    func testTeardownAction() {
        XCTAssertEqual(Workspace.teardownAction(kind: .local, isTerminating: false), .terminateLocal)
        XCTAssertEqual(Workspace.teardownAction(kind: .hc, isTerminating: false), .killHc)
        XCTAssertEqual(Workspace.teardownAction(kind: .hc, isTerminating: true), .none)
        // local pane은 지금처럼 언제나 셸을 끝낸다(앱이 끝나면 어차피 함께 끝난다).
        XCTAssertEqual(Workspace.teardownAction(kind: .local, isTerminating: true), .terminateLocal)
    }

    func testBackendKind() {
        XCTAssertEqual(PaneLaunch.local.backendKind, .local)
        XCTAssertEqual(PaneLaunch.hc(machine: nil).backendKind, .hc)
        XCTAssertEqual(PaneLaunch.hc(machine: "bdpc01").backendKind, .hc)
        XCTAssertEqual(PaneBackendKind(rawValue: "hc"), .hc)
        XCTAssertEqual(PaneBackendKind.local.rawValue, "local")
    }

    private func snap(_ id: String) -> PaneSnapshot {
        var s = PaneSnapshot.empty(paneId: id, projectId: "proj")
        s.state = .thinking
        s.turnOpen = true
        return s
    }

    func testMidTurnCountExcludesHcPanes() {
        let model = MissionControlModel(startPump: false)
        let win = UUID()
        model.setLivePaneIds(["A", "B"], forWindow: win)
        model.applySnapshot(snap("A"))
        model.applySnapshot(snap("B"))
        XCTAssertEqual(model.midTurnPaneCount, 2)
        model.setHcPaneIds(["B"], forWindow: win)
        XCTAssertEqual(model.midTurnPaneCount, 1, "an update relaunch doesn't kill hc panes, so they don't hold it")

        // 창이 닫히면 그 창의 hc 목록도 사라진다: 같은 id가 다른 창에서 local로 살아나면 다시 센다.
        model.removeWindow(win)
        model.setLivePaneIds(["B"], forWindow: UUID())
        XCTAssertEqual(model.midTurnPaneCount, 1)
    }

    // R10: hc가 다시 attach할 때 보내는 first paint의 OSC 7은 ST 앞에 NUL이 붙는다.
    func testOsc7PathStripsControlCharacters() {
        XCTAssertEqual(Pane.osc7Path("file://mac.local/Users/ysh/proj\u{0}"), "/Users/ysh/proj")
        XCTAssertEqual(Pane.osc7Path("file://mac.local/Users/ysh/proj"), "/Users/ysh/proj")
        XCTAssertEqual(Pane.osc7Path("file://mac.local/tmp/a%20b\u{7}"), "/tmp/a b")
        XCTAssertEqual(Pane.osc7Path("file:///Users/ysh/한글"), "/Users/ysh/한글")
        XCTAssertEqual(Pane.osc7Path("~/proj\u{0}"), NSHomeDirectory() + "/proj")
        XCTAssertNil(Pane.osc7Path("\u{0}"))
        XCTAssertNil(Pane.osc7Path(""))
    }

    /// hc pane의 헤더 오른쪽 끝 herdr 표시. local pane에는 없다.
    func testHerdrMarkToolTip() {
        XCTAssertNil(Pane.herdrMarkToolTip(for: .local))
        XCTAssertEqual(Pane.herdrMarkToolTip(for: .hc(machine: nil)), "Running in herdr-core")
        XCTAssertEqual(Pane.herdrMarkToolTip(for: .hc(machine: "bdpc01")), "Running in herdr-core on bdpc01")
    }

    @MainActor
    func testHeaderShowsHerdrMarkOnlyForHcPanes() throws {
        let header = PaneHeaderView()
        XCTAssertTrue(header.herdrMark.isHidden, "a new header has no mark")

        header.setHerdrMark(toolTip: "Running in herdr-core")
        XCTAssertFalse(header.herdrMark.isHidden)
        XCTAssertEqual(header.herdrMark.toolTip, "Running in herdr-core")
        let image = try XCTUnwrap(header.herdrMark.image, "the HerdrMark asset is in the app bundle")
        XCTAssertTrue(image.isTemplate, "tinted like the header text, light and dark")

        header.setHerdrMark(toolTip: nil)
        XCTAssertTrue(header.herdrMark.isHidden)
    }

    func testHcStatusText() {
        XCTAssertEqual(Pane.hcStatusText(.connecting), "Connecting to herdr-core…")
        XCTAssertEqual(Pane.hcStatusText(.restartingShell), "Restarting shell…")
        XCTAssertEqual(Pane.hcStatusText(.unavailable("not installed")), "herdr-core unavailable: not installed")
        XCTAssertNil(Pane.hcStatusText(.attached))
    }

    // Review Focus 1: applicationWillTerminate는 main에서 돈다. flushPendingKills의 끝은 main actor로 돌아오므로
    // main을 semaphore로 막으면 timeout까지 끝나지 못한다. main run loop를 돌리며 기다리면 그 사이에 끝난다.
    func testRunMainLoopLetsMainActorWorkFinish() {
        let hops = TestBox(0)
        let started = Date()
        let finished = AppLifecycle.runMainLoop(timeout: 2) {
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(10))
                hops.value += 1
            }
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(hops.value, 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testRunMainLoopStopsAtTimeout() {
        let started = Date()
        let finished = AppLifecycle.runMainLoop(timeout: 0.2) {
            try? await Task.sleep(for: .seconds(5))
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(finished)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2)
        XCTAssertLessThan(elapsed, 1)
    }
}

@MainActor
final class TestBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

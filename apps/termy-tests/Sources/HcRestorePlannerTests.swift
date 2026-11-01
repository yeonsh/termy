import XCTest
@testable import termy

// 복원 때의 판단을 hc 없이 본다: 고아 terminal 찾기, 고아 정리를 언제 하는지(R14), 그리고 복원한 원격 pane이
// 그 머신이 연결된 것을 보기 전에는 새 셸을 띄우지 않는 것(R13). scratch core에는 원격 머신이 없으므로 원격
// 경로는 여기 순수 함수로만 확인한다.

final class HcRestorePlannerTests: XCTestCase {
    private func terminal(_ address: String, pane: String?, state: String = "live", project: String? = "bdpc01:/srv/app",
                          cwd: String? = "/srv/app") -> HcTerminal {
        var labels = ["termy.instance": "release"]
        if let pane { labels["termy.pane"] = pane }
        if let project { labels["termy.project"] = project }
        return HcTerminal(address: address, state: state, labels: labels, cwd: cwd, exitCode: nil, reason: nil,
                          status: nil, foreground: nil, cols: nil, rows: nil, title: nil)
    }

    func testOrphansAreLiveTermyTerminalsNotInLayout() {
        let t = { (addr: String, pane: String) in HcTerminal(address: addr, state: "live", labels: ["termy.pane": pane, "termy.instance": "release", "termy.project": "bdpc01:/srv/app"], cwd: "/srv/app", exitCode: nil, reason: nil, status: nil, foreground: nil, cols: nil, rows: nil, title: nil) }
        let o = HcRestorePlanner.orphans(live: [t("t1", "A"), t("bdpc01/t2", "B")], knownPaneIds: ["A"])
        XCTAssertEqual(o, [HcOrphan(paneId: "B", address: "bdpc01/t2", machine: "bdpc01", projectKey: "bdpc01:/srv/app", cwd: "/srv/app")])
    }

    func testOrphansSkipFinishedUnlabeledAndDuplicatePanes() {
        let o = HcRestorePlanner.orphans(live: [
            terminal("t1", pane: "done", state: "finished"),
            terminal("t2", pane: nil),
            terminal("t3", pane: ""),
            terminal("t4", pane: "C", project: nil, cwd: "/tmp"),
            terminal("t5", pane: "C"),
        ], knownPaneIds: [])
        XCTAssertEqual(o, [HcOrphan(paneId: "C", address: "t4", machine: nil, projectKey: nil, cwd: "/tmp")],
                       "one pane per paneId: two panes on one terminal would kill each other's shell")
    }

    func testRemoteOrphanProjectIdFollowsRemoteProjectRule() {
        let remote = HcOrphan(paneId: "B", address: "bdpc01/t2", machine: "bdpc01", projectKey: "bdpc01:/srv/app", cwd: "/srv/app/sub")
        XCTAssertEqual(HcRestorePlanner.projectId(for: remote), "app@bdpc01")
        let noKey = HcOrphan(paneId: "B", address: "bdpc01/t2", machine: "bdpc01", projectKey: nil, cwd: "/srv/web")
        XCTAssertEqual(HcRestorePlanner.projectId(for: noKey), "web@bdpc01")
        let local = HcOrphan(paneId: "A", address: "t1", machine: nil, projectKey: "/tmp", cwd: "/tmp")
        XCTAssertNil(HcRestorePlanner.projectId(for: local), "local panes derive their project from cwd")
    }

    // MARK: - 고아 정리를 할지(R14)

    func testAdoptionRunsOnlyWithHcPanesOrLocalSetting() {
        let off = InMemoryUserDefaults()
        XCTAssertFalse(WindowManager.shouldAdoptHcOrphans(paneKinds: [], defaults: off))
        XCTAssertFalse(WindowManager.shouldAdoptHcOrphans(paneKinds: [.local, .local], defaults: off),
                       "local-only users never start or reach herdr-core")
        XCTAssertTrue(WindowManager.shouldAdoptHcOrphans(paneKinds: [.local, .hc], defaults: off))
        let on = InMemoryUserDefaults()
        on.set(true as NSNumber, forKey: "termy.herdrCore.localPanes")
        XCTAssertTrue(WindowManager.shouldAdoptHcOrphans(paneKinds: [.local], defaults: on))
    }

    // MARK: - 원격 pane의 새 셸(R13)

    private func plan(address: String? = nil, machine: String?, seen: Bool, terminals: [HcTerminal] = []) -> HcPaneBackend.AttachPlan {
        HcPaneBackend.plan(paneId: "P", address: address, machine: machine, machineSeen: seen,
                           store: HcEventStore(seq: 1, terminals: terminals), instance: "release")
    }

    func testRestoredRemotePaneWaitsUntilItsMachineIsSeen() {
        XCTAssertEqual(plan(machine: "bdpc01", seen: false), .awaitMachine("bdpc01"),
                       "its terminal may be alive on a machine whose line is not back yet: running now makes a second shell")
        XCTAssertEqual(plan(machine: "bdpc01", seen: true), .run, "machine connected and no terminal of ours: new shell")
    }

    func testRemotePaneAttachesToItsLiveTerminal() {
        let mine = terminal("bdpc01/t7", pane: "P")
        XCTAssertEqual(plan(machine: "bdpc01", seen: false, terminals: [mine]), .attach("bdpc01/t7"))
        let finished = terminal("bdpc01/t7", pane: "P", state: "finished")
        XCTAssertEqual(plan(machine: "bdpc01", seen: true, terminals: [finished]), .run,
                       "a finished terminal gets a new shell with the same pane id")
    }

    func testLocalPaneNeverWaitsForAMachine() {
        XCTAssertEqual(plan(machine: nil, seen: false), .run)
        XCTAssertEqual(plan(machine: nil, seen: false, terminals: [terminal("t3", pane: "P")]), .attach("t3"))
    }

    func testOtherInstanceTerminalIsNotOurs() {
        var other = terminal("t3", pane: "P")
        other.labels["termy.instance"] = "debug"
        XCTAssertEqual(plan(machine: nil, seen: false, terminals: [other]), .run)
    }

    func testCachedAddressKeepsExistingRules() {
        let record = terminal("t3", pane: "P")
        XCTAssertEqual(plan(address: "t3", machine: nil, seen: false, terminals: [record]), .attach("t3"))
        XCTAssertEqual(plan(address: "bdpc01/t3", machine: "bdpc01", seen: false), .waitForMachine("bdpc01"))
    }
}

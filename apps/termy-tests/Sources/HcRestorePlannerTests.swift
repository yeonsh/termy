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

    /// 원격 머신에서 따로 도는 termy의 local pane은 같은 `termy.instance`를 달고 이 core에 그 머신의 terminal로 보인다.
    /// 키에 머신 접두사가 없는 그런 terminal을 붙이면 열지 않은 탭(`rv@mac-builder`)이 생기고, 닫으면 그 셸을 kill한다.
    func testRemoteTerminalsOfAnotherTermyAreNotOrphans() {
        let o = HcRestorePlanner.orphans(live: [
            terminal("mac-builder/t1", pane: "X", project: "/Users/jtkim/work/rv", cwd: "/Users/jtkim/work/rv"),
            terminal("mac-builder/t2", pane: "Y", project: nil, cwd: "/Users/jtkim"),
            terminal("mac-builder/t3", pane: "Z", project: "bdpc01:/srv/app"),
            terminal("bdpc01/t4", pane: "B"),
            terminal("t5", pane: "L", project: "/Users/me/app", cwd: "/Users/me/app"),
        ], knownPaneIds: [])
        XCTAssertEqual(o.map(\.paneId), ["B", "L"], "remote needs `<its machine>:`; local terminals stay ours")
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

    // MARK: - 띄우기 직전의 확인(R13b)

    private func machine(_ name: String, _ state: String) -> HcMachine {
        HcMachine(name: name, host: name, state: state, why: nil)
    }

    private func check(_ terminals: [HcTerminal], _ machines: [HcMachine]) -> HcPaneBackend.RemoteRunCheck {
        HcPaneBackend.remoteRunCheck(paneId: "P", instance: "release", machine: "bdpc01", terminals: terminals, machines: machines)
    }

    func testRemoteRunCheckAttachesToThePanesLiveTerminal() {
        XCTAssertEqual(check([terminal("bdpc01/t7", pane: "P")], [machine("bdpc01", "connected")]), .attach("bdpc01/t7"),
                       "seen was only a wake-up: the terminal was there all along")
    }

    func testRemoteRunCheckWaitsWhileItsMachineIsNotConnected() {
        XCTAssertEqual(check([], [machine("bdpc01", "connecting")]), .wait(.connecting))
        XCTAssertEqual(check([], [machine("bdpc01", "needs_login")]), .wait(.unavailable("bdpc01 needs login")))
        XCTAssertEqual(check([], [machine("bdpc01", "unreachable")]), .wait(.unavailable("bdpc01 unreachable")))
    }

    func testRemoteRunCheckRunsOnlyWhenNothingOfOursIsAlive() {
        XCTAssertEqual(check([], [machine("bdpc01", "connected"), machine("other", "unreachable")]), .run)
        XCTAssertEqual(check([], []), .run, "an unknown machine: terminal.run reports why")
        let finished = terminal("bdpc01/t7", pane: "P", state: "finished")
        XCTAssertEqual(check([finished], [machine("bdpc01", "connected")]), .run)
    }

    /// labels 필터를 모르는 core가 모든 terminal을 돌려줘도 다른 pane이나 instance의 terminal에 붙지 않는다.
    func testRemoteRunCheckIgnoresOtherPanesAndInstances() {
        var otherInstance = terminal("bdpc01/t8", pane: "P")
        otherInstance.labels["termy.instance"] = "debug"
        XCTAssertEqual(check([terminal("bdpc01/t7", pane: "Q"), otherInstance], [machine("bdpc01", "connected")]), .run)
    }

    // MARK: - 기다리는 원격 pane의 상태 줄

    func testWaitingStateNamesTheMachineAndWhy() {
        XCTAssertEqual(HcPaneBackend.waitingState(machine: "bdpc01", lineState: "needs_login"), .unavailable("bdpc01 needs login"))
        XCTAssertEqual(HcPaneBackend.waitingState(machine: "bdpc01", lineState: "unreachable"), .unavailable("bdpc01 unreachable"))
        XCTAssertEqual(HcPaneBackend.waitingState(machine: "bdpc01", lineState: "connecting"), .connecting)
        XCTAssertEqual(HcPaneBackend.waitingState(machine: "bdpc01", lineState: nil), .connecting, "line state not known yet")
        XCTAssertEqual(Pane.hcStatusText(HcPaneBackend.waitingState(machine: "bdpc01", lineState: "needs_login")),
                       "herdr-core unavailable: bdpc01 needs login")
    }

    // MARK: - 닫은 pane의 terminal

    /// address를 모른 채 닫힌 pane(머신이 끊겨 있던 원격 pane 등)의 terminal이 나중에 오면 kill한다.
    func testTerminalsOfClosedPanesAreKilledWhenTheyArrive() {
        var otherInstance = terminal("bdpc01/t4", pane: "B")
        otherInstance.labels["termy.instance"] = "debug"
        let arrived = [terminal("t1", pane: "A"), terminal("bdpc01/t2", pane: "B"),
                       terminal("bdpc01/t3", pane: "B", state: "finished"), otherInstance, terminal("t5", pane: nil)]
        XCTAssertEqual(HcSessionManager.terminalsOfClosedPanes(["B"], in: arrived, instance: "release"), ["bdpc01/t2"])
        XCTAssertEqual(HcSessionManager.terminalsOfClosedPanes([], in: arrived, instance: "release"), [])
    }

    func testCachedAddressKeepsExistingRules() {
        let record = terminal("t3", pane: "P")
        XCTAssertEqual(plan(address: "t3", machine: nil, seen: false, terminals: [record]), .attach("t3"))
        XCTAssertEqual(plan(address: "bdpc01/t3", machine: "bdpc01", seen: false), .waitForMachine("bdpc01"))
    }
}

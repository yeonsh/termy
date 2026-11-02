import XCTest
import AppKit
@testable import termy

// HcPaneBackend + HcSessionManager를 scratch core(HcTestCore)에 붙여 hc pane 하나의 수명을 본다.
// 사용자 core는 건드리지 않는다: manager는 scratch endpoint로만 만들고 HcSessionManager.shared는 쓰지 않는다.
// 셸은 사용자 zsh dotfiles 대신 `/bin/sh -l`(launch.shell = /bin/sh)로 띄워 시간이 일정하게 한다.
// label은 TERMY_INSTANCE=test로 붙여 다른 instance와 섞이지 않게 한다.

@MainActor
final class HcPaneBackendIntegrationTests: XCTestCase {
    private struct ListResult: Decodable, Sendable { let terminals: [HcTerminal] }

    private var savedInstance: String?

    override func setUp() async throws {
        savedInstance = getenv("TERMY_INSTANCE").map { String(cString: $0) }
        setenv("TERMY_INSTANCE", "test", 1)
    }

    override func tearDown() async throws {
        if let savedInstance { setenv("TERMY_INSTANCE", savedInstance, 1) } else { unsetenv("TERMY_INSTANCE") }
    }

    private func makeManager() throws -> HcSessionManager {
        let core = try HcTestCore.makeOrSkip()
        addTeardownBlock { await core.stop() }
        let endpoint = core.endpoint
        let manager = HcSessionManager(endpointProvider: { endpoint })
        addTeardownBlock { await manager.shutdown() }   // 역순: 연결을 닫은 뒤 core를 멈춘다
        return manager
    }

    private func makeBackend(_ manager: HcSessionManager, paneId: String = UUID().uuidString) -> (HcPaneBackend, TermyTerminalView) {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let backend = HcPaneBackend(paneId: paneId, projectKey: "/tmp", projectId: "tmp",
                                    launch: HcLaunch(machine: nil, cwd: "/tmp", shell: "/bin/sh"),
                                    view: view, manager: manager)
        return (backend, view)
    }

    private func waitUntil(_ seconds: Double, _ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out after \(seconds) s: \(what)")
                throw HcTimeoutError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 입력 줄의 echo(`echo hc-ok`)가 아니라 명령의 출력 줄과 정확히 같은 줄이 있는지.
    private func screenHasLine(_ view: TermyTerminalView, _ text: String) -> Bool {
        let t = view.getTerminal()
        return (0..<t.rows).contains { t.getLine(row: $0)?.translateToString(trimRight: true) == text }
    }

    private func liveTestTerminals(_ manager: HcSessionManager) async throws -> [HcTerminal] {
        let r: ListResult = try await manager.call("terminal.list", HcEmptyParams())
        return r.terminals.filter { $0.labels["termy.instance"] == "test" }
    }

    private func elapsed(_ since: Date) -> String { String(format: "%.2f s", Date().timeIntervalSince(since)) }

    func testStartRunsShellAndEchoes() async throws {
        let manager = try makeManager()
        let (backend, view) = makeBackend(manager)
        let started = Date()
        backend.start()
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        print("[hc6] start → attached: \(elapsed(started))")
        view.send(txt: "echo hc-ok\r")
        try await waitUntil(5, "hc-ok on screen") { screenHasLine(view, "hc-ok") }
        print("[hc6] start → hc-ok: \(elapsed(started))")

        // 실제 레코드가 HcTerminal로 풀리고 label·상태가 맞는지(Task 5의 decoder를 live JSON으로 확인).
        let terminals = try await liveTestTerminals(manager)
        XCTAssertEqual(terminals.count, 1)
        let t = try XCTUnwrap(terminals.first)
        XCTAssertEqual(t.address, backend.address)
        XCTAssertEqual(t.state, "live")
        XCTAssertEqual(t.labels["termy.pane"], backend.paneId)
        XCTAssertEqual(t.labels["termy.project"], "/tmp")
        XCTAssertEqual(t.labels["termy.instance"], "test")
        XCTAssertEqual(t.cwd, "/tmp")
        XCTAssertNil(t.exitCode)
        // foreground는 hc가 1초에 두 번쯤 읽으므로 막 뜬 terminal에서는 아직 null일 수 있다.
    }

    func testStartReattachesExistingTerminal() async throws {
        let manager = try makeManager()
        let paneId = UUID().uuidString
        let (first, view1) = makeBackend(manager, paneId: paneId)
        first.start()
        try await waitUntil(5, "first attached") { first.connectionState == .attached }
        view1.send(txt: "echo first-run-marker\r")
        try await waitUntil(5, "marker on first screen") { screenHasLine(view1, "first-run-marker") }
        let address = try XCTUnwrap(first.address)
        first.detach()

        let (second, view2) = makeBackend(manager, paneId: paneId)
        let started = Date()
        second.start()
        try await waitUntil(5, "second attached") { second.connectionState == .attached }
        try await waitUntil(5, "marker in first paint") { screenHasLine(view2, "first-run-marker") }
        print("[hc6] reattach → marker: \(elapsed(started))")
        XCTAssertEqual(second.address, address)
        let terminals = try await liveTestTerminals(manager)
        XCTAssertEqual(terminals.map(\.address), [address])
    }

    /// attach 응답을 기다리는 사이 grid가 바뀌면 그 RESIZE는 session이 없어 버려진다. 붙은 뒤 지금 크기를 한 번
    /// 보내야 프로그램이 attach 때의 크기(고아를 열 때는 frame이 잡히기 전의 80x25)에 머물지 않는다.
    func testGridChangeDuringAttachReachesTheProgram() async throws {
        let manager = try makeManager()
        let (backend, view) = makeBackend(manager)
        backend.start()
        // address는 attach 호출 직전(attach 인자의 grid를 읽은 곳)에 정해지고 session은 응답을 처리할 때 열린다.
        // main actor를 양보하며 기다리다 그 사이에 크기를 바꾼다.
        let deadline = Date().addingTimeInterval(5)
        while backend.address == nil {
            guard Date() < deadline else { return XCTFail("no terminal address") }
            await Task.yield()
        }
        XCTAssertEqual(backend.connectionState, .connecting, "resized before the attach reply was handled")
        let sent = (cols: view.getTerminal().cols, rows: view.getTerminal().rows)
        view.setFrameSize(NSSize(width: 900, height: 560))
        let grid = (cols: view.getTerminal().cols, rows: view.getTerminal().rows)
        XCTAssertTrue(grid != sent, "the grid changed")
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        view.send(txt: "stty size\r")
        try await waitUntil(5, "the shell sees \(grid.rows) \(grid.cols), not \(sent.rows) \(sent.cols)") {
            screenHasLine(view, "\(grid.rows) \(grid.cols)")
        }
    }

    /// core(ghostty-vt)는 DECRQM ?2048에 "지원"이라고 답한다. 그래서 이 모드를 켠 프로그램(nvim 0.10+)은
    /// SIGWINCH를 듣지 않고 크기 알림 `CSI 48;rows;cols;h;w t`를 기다린다. 알림은 client가 보내야 한다
    /// (core는 보내지 않는다). 보내지 않으면 창이나 글꼴 크기를 바꿔도 nvim이 예전 크기로 남는다.
    func testInBandResizeReportReachesProgramThatEnabledIt() async throws {
        let manager = try makeManager()
        let (backend, view) = makeBackend(manager)
        backend.start()
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        let start = (cols: view.getTerminal().cols, rows: view.getTerminal().rows)
        view.send(txt: "perl \(try inBandResizeProbeScript())\r")
        try await waitUntil(5, "armed") { screenHasLine(view, "ARMED") }
        try await waitUntil(5, "a report as soon as the mode is on") {
            screenHasLine(view, "GOT 48;\(start.rows);\(start.cols)")
        }

        view.setFrameSize(NSSize(width: 900, height: 560))
        let grid = (cols: view.getTerminal().cols, rows: view.getTerminal().rows)
        XCTAssertTrue(grid != start, "the grid changed")
        try await waitUntil(5, "a report with the new grid") {
            screenHasLine(view, "GOT 48;\(grid.rows);\(grid.cols)")
        }
    }

    /// 다시 붙은 pane(새 view)도 프로그램이 켜 둔 mode 2048을 알아야 한다. 아니면 termy를 다시 띄운 뒤
    /// 열려 있던 nvim이 크기 변경을 놓친다.
    func testInBandResizeReportSurvivesReattach() async throws {
        let manager = try makeManager()
        let paneId = UUID().uuidString
        let (first, view1) = makeBackend(manager, paneId: paneId)
        first.start()
        try await waitUntil(5, "first attached") { first.connectionState == .attached }
        view1.send(txt: "perl \(try inBandResizeProbeScript())\r")
        try await waitUntil(5, "armed") { screenHasLine(view1, "ARMED") }
        first.detach()

        let (second, view2) = makeBackend(manager, paneId: paneId)
        second.start()
        try await waitUntil(5, "second attached") { second.connectionState == .attached }
        view2.setFrameSize(NSSize(width: 900, height: 560))
        let grid = (cols: view2.getTerminal().cols, rows: view2.getTerminal().rows)
        try await waitUntil(5, "a report with the new grid after reattach") {
            screenHasLine(view2, "GOT 48;\(grid.rows);\(grid.cols)")
        }
    }

    /// mode 2048을 켜고, 받은 크기 알림마다 `GOT 48;rows;cols`를 한 줄씩 찍는 프로그램.
    private func inBandResizeProbeScript() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termy-inband-\(UUID().uuidString).pl")
        try #"""
        system("stty raw -echo"); $| = 1;
        print "\e[?2048h"; print "ARMED\r\n";
        my $buf = ""; my $rin = ""; vec($rin, fileno(STDIN), 1) = 1; my $end = time + 20;
        while (time < $end) {
            next unless select(my $r = $rin, undef, undef, 0.1) > 0;
            sysread(STDIN, my $c, 256) or last;
            $buf .= $c;
            while ($buf =~ s/\e\[48;(\d+);(\d+);\d+;\d+t//) { print "GOT 48;$1;$2\r\n"; }
        }
        print "\e[?2048l"; system("stty sane");
        """#.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testKillRemovesTerminal() async throws {
        let manager = try makeManager()
        let (backend, _) = makeBackend(manager)
        backend.start()
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        let address = try XCTUnwrap(backend.address)
        var exits: [Int32] = []
        backend.onExit = { exits.append($0) }
        let started = Date()
        backend.kill()
        await manager.flushPendingKills(timeout: 2)
        print("[hc6] kill flush: \(elapsed(started))")
        let terminals = try await liveTestTerminals(manager)
        XCTAssertFalse(terminals.contains { $0.address == address })
        XCTAssertEqual(exits, [], "kill() is the caller's own close; it must not report an exit")
    }

    func testReconnectReattachesWithoutNewTerminal() async throws {
        let manager = try makeManager()
        let (backend, view) = makeBackend(manager)
        var states: [HcPaneConnectionState] = []
        backend.onConnectionState = { states.append($0) }
        backend.start()
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        let address = try XCTUnwrap(backend.address)
        let before = try await liveTestTerminals(manager)
        XCTAssertEqual(before.count, 1)

        states.removeAll()
        let started = Date()
        await manager._debugTerminateConnection()
        try await waitUntil(10, "re-attached after reconnect") {
            states.contains(.connecting) && backend.connectionState == .attached
        }
        print("[hc6] reconnect → attached: \(elapsed(started)), states \(states)")
        XCTAssertEqual(backend.address, address)
        let after = try await liveTestTerminals(manager)
        XCTAssertEqual(after.map(\.address), [address])

        view.send(txt: "echo after-reconnect\r")
        try await waitUntil(5, "input works after reconnect") { screenHasLine(view, "after-reconnect") }
    }

    func testLargeBurstReachesScreen() async throws {
        let manager = try makeManager()
        let (backend, view) = makeBackend(manager)
        backend.start()
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        let started = Date()
        view.send(txt: "seq 1 200000; echo LAST-LINE\r")
        try await waitUntil(20, "LAST-LINE on screen") { screenHasLine(view, "LAST-LINE") }
        print("[hc6] seq 200000 → LAST-LINE: \(elapsed(started))")
        XCTAssertEqual(backend.connectionState, .attached)
    }

    func testExitClosesWithCode() async throws {
        let manager = try makeManager()
        let (backend, view) = makeBackend(manager)
        var exits: [Int32] = []
        backend.onExit = { exits.append($0) }
        backend.start()
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        view.send(txt: "exit 4\r")
        try await waitUntil(5, "onExit") { !exits.isEmpty }
        XCTAssertEqual(exits, [4])
    }

    /// 연결이 끊긴 사이에 프로그램이 끝나면 다시 연결한 snapshot의 finished 레코드로 onExit을 부른다.
    func testExitWhileDisconnectedReportsCode() async throws {
        let manager = try makeManager()
        let (backend, view) = makeBackend(manager)
        var exits: [Int32] = []
        backend.onExit = { exits.append($0) }
        backend.start()
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        view.send(txt: "sleep 0.2; exit 3\r")
        try await waitUntil(5, "command echoed") {
            let t = view.getTerminal()
            return (0..<t.rows).contains { t.getLine(row: $0)?.translateToString(trimRight: true).hasSuffix("sleep 0.2; exit 3") == true }
        }
        await manager._debugTerminateConnection()
        try await waitUntil(10, "onExit after reconnect") { !exits.isEmpty }
        XCTAssertEqual(exits, [3])
    }

    /// kept terminal의 셸이 signal로 죽으면(loss) pane은 닫히지 않고 "restarting shell"을 거쳐 새 셸에 다시 붙는다.
    func testSignaledShellRestartsAndReattaches() async throws {
        let manager = try makeManager()
        let (backend, view) = makeBackend(manager)
        var states: [HcPaneConnectionState] = []
        var exits: [Int32] = []
        backend.onConnectionState = { states.append($0) }
        backend.onExit = { exits.append($0) }
        backend.start()
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        let address = try XCTUnwrap(backend.address)
        states.removeAll()
        let started = Date()
        view.send(txt: "kill -9 $$\r")
        try await waitUntil(20, "re-attached to the new shell") {
            states.contains(.restartingShell) && backend.connectionState == .attached
        }
        print("[hc6] signaled → re-attached: \(elapsed(started)), states \(states)")
        XCTAssertEqual(exits, [])
        XCTAssertEqual(backend.address, address)
        view.send(txt: "echo after-restart\r")
        try await waitUntil(5, "input works in the new shell") { screenHasLine(view, "after-restart") }
        let terminals = try await liveTestTerminals(manager)
        XCTAssertEqual(terminals.map(\.address), [address])
    }

    func testUnavailableWhenEndpointMissing() async throws {
        let manager = HcSessionManager(endpointProvider: { nil })
        addTeardownBlock { await manager.shutdown() }
        let (backend, _) = makeBackend(manager)
        backend.start()
        try await waitUntil(2, "unavailable") {
            if case .unavailable = backend.connectionState { return true }
            return false
        }
        XCTAssertEqual(manager.availability, .notInstalled)
        XCTAssertNil(backend.address)
    }
}

import XCTest
import AppKit
@testable import termy

// session.json의 hc pane 기록으로 창을 복원하는 흐름을 WindowManager에서 scratch core(HcTestCore)로 본다: 같은
// paneId로 같은 terminal에 다시 붙고, hc를 쓸 수 없으면 local로 바뀌지 않고, 레이아웃에 없던 terminal은 pane으로
// 열리고, 복원한 원격 pane은 그 머신을 보기 전에는 셸을 띄우지 않는다.
// 사용자 데이터는 건드리지 않는다: WindowManager에는 임시 폴더의 SessionPersistence·WorkspacePersistence와
// InMemoryUserDefaults를 넣는다(기본값은 ~/Library/Application Support/termy와 실제 defaults다).
// 사용자 core도 건드리지 않는다: HcSessionManager.shared를 scratch(또는 endpoint 없는) manager로 바꾸고 되돌린다.
// 셸은 SHELL=/bin/sh, label은 TERMY_INSTANCE=test. 테스트 host는 마지막 창이 닫히거나 풀리면 끝나므로, 복원한
// 창은 닫지 않고 hc viewer를 떼고 removeWindow·orderOut 한 뒤 붙잡아 둔다.

@MainActor
final class HcRestoreIntegrationTests: XCTestCase {
    private struct ListResult: Decodable, Sendable { let terminals: [HcTerminal] }

    /// 닫거나 풀면 테스트 host가 끝난다. 프로세스가 끝날 때까지 붙잡아 둔다.
    private static var retiredControllers: [MainWindowController] = []

    private var savedEnvironment: [String: String?] = [:]
    private var savedManager: HcSessionManager?

    override func setUp() async throws {
        for (key, value) in [("TERMY_INSTANCE", "test"), ("SHELL", "/bin/sh")] {
            savedEnvironment[key] = getenv(key).map { String(cString: $0) }
            setenv(key, value, 1)
        }
    }

    override func tearDown() async throws {
        AppLifecycle.isTerminating = false
        if let savedManager { HcSessionManager.shared = savedManager }
        savedManager = nil
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        savedEnvironment = [:]
    }

    // MARK: - 준비

    private func install(_ manager: HcSessionManager) {
        if savedManager == nil { savedManager = HcSessionManager.shared }
        HcSessionManager.shared = manager
    }

    private func installScratchManager() throws -> HcSessionManager {
        let core = try HcTestCore.makeOrSkip()
        addTeardownBlock { await core.stop() }
        let endpoint = core.endpoint
        let manager = HcSessionManager(endpointProvider: { endpoint })
        addTeardownBlock { await manager.shutdown() }   // 역순: 연결을 닫은 뒤 core를 멈춘다
        install(manager)
        return manager
    }

    /// 임시 폴더의 session.json에 windows를 쓰고, 그 폴더만 쓰는 WindowManager로 복원한다.
    private func restore(_ windows: [WindowRecord], defaults: UserDefaults = InMemoryUserDefaults()) async throws -> WindowManager {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("termy-restore-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let persistence = try SessionPersistence(rootDir: root)
        try await persistence.save(SessionRecord(windows: windows))
        let workspaces = root.appendingPathComponent("workspaces", isDirectory: true)
        let windowManager = WindowManager(sessionPersistence: persistence,
                                          workspacePersistence: { try? WorkspacePersistence(rootDir: workspaces) },
                                          defaults: defaults)
        // manager.shutdown·core.stop보다 먼저 돈다(teardown block은 역순).
        addTeardownBlock { @MainActor in await Self.retire(windowManager) }
        let restored = await windowManager.restoreSessionWindows()
        XCTAssertTrue(restored, "the saved session opened a window")
        return windowManager
    }

    /// 창을 닫지 않고 정리한다: hc viewer를 떼고(terminal은 scratch core와 함께 끝난다) 등록을 풀고 보이지 않게
    /// 한다. orderOut도 하지 않는다: 보이는 마지막 창이 빠지면 AppKit이 "마지막 창이 닫힘" 검사를 걸어 host가 끝난다.
    private static func retire(_ windowManager: WindowManager) async {
        for controller in windowManager.controllers {
            for pane in controller.panes {
                pane.detachHcTerminal()
                if pane.launch == .local, pane.terminal.process.running { pane.terminal.process.terminate() }
            }
            await controller.autosaver?.flushSync()
            windowManager.removeWindow(controller)
            controller.window?.alphaValue = 0
            controller.window?.ignoresMouseEvents = true
            retiredControllers.append(controller)
        }
        await windowManager.sessionAutosaver?.flushSync()
    }

    private func window(_ panes: [PaneRecord]) -> WindowRecord {
        WindowRecord(frame: FrameRecord(x: 120, y: 120, width: 900, height: 600), rows: [panes])
    }

    private func waitUntil(_ seconds: Double, _ what: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("timed out after \(seconds) s: \(what)")
                throw HcTimeoutError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func attachedBackend(_ pane: Pane) async throws -> HcPaneBackend {
        let backend = try XCTUnwrap(pane.hcBackend, "an hc pane has a backend")
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        return backend
    }

    /// 지난 실행의 pane처럼 terminal을 띄우고 viewer만 떠난다(⌘Q 뒤처럼 core에 살아 있다).
    private func leaveTerminal(_ manager: HcSessionManager, paneId: String, marker: String? = nil) async throws -> String {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let backend = HcPaneBackend(paneId: paneId, projectKey: "/private/tmp", projectId: "tmp",
                                    launch: HcLaunch(machine: nil, cwd: "/tmp", shell: "/bin/sh"),
                                    view: view, manager: manager)
        backend.start()
        try await waitUntil(5, "previous run attached") { backend.connectionState == .attached }
        if let marker {
            view.send(txt: "echo \(marker)\r")
            try await waitUntil(5, "marker on the previous screen") { screenHasLine(view, marker) }
        }
        let address = try XCTUnwrap(backend.address)
        backend.detach()
        return address
    }

    /// 입력 줄의 echo가 아니라 명령의 출력 줄과 정확히 같은 줄이 있는지.
    private func screenHasLine(_ view: TermyTerminalView, _ text: String) -> Bool {
        let t = view.getTerminal()
        return (0..<t.rows).contains { t.getLine(row: $0)?.translateToString(trimRight: true) == text }
    }

    private func testTerminals(_ manager: HcSessionManager) async throws -> [HcTerminal] {
        let r: ListResult = try await manager.call("terminal.list", HcEmptyParams())
        return r.terminals.filter { $0.labels["termy.instance"] == "test" }
    }

    // MARK: - 테스트

    func testRestoreReattachesSamePaneId() async throws {
        let manager = try installScratchManager()
        let paneId = UUID().uuidString
        let address = try await leaveTerminal(manager, paneId: paneId, marker: "restore-marker")
        let before = try await testTerminals(manager)
        XCTAssertEqual(before.map(\.address), [address])

        let details = PaneHookDetails(lastSessionId: "hct-session", lastPrompt: "fix the bug", lastAssistantMessage: "fixed",
                                      lastCwd: "/tmp", agentKind: .codex)
        let saved = PaneRecord(cwd: "/tmp", paneId: paneId, backend: .hc, projectId: "tmp", projectKey: "/private/tmp",
                               hookDetails: details)
        let windowManager = try await restore([window([saved])])
        let controller = try XCTUnwrap(windowManager.controllers.first)
        XCTAssertEqual(controller.panes.count, 1)
        let pane = try XCTUnwrap(controller.panes.first)
        XCTAssertEqual(pane.paneId, paneId, "the saved pane id is reused")
        XCTAssertEqual(pane.launch, .hc(machine: nil))
        XCTAssertEqual(pane.projectKey, "/private/tmp")

        let backend = try await attachedBackend(pane)
        XCTAssertEqual(backend.address, address, "re-attached to the same terminal")
        try await waitUntil(5, "previous output in the first paint") { screenHasLine(pane.terminal, "restore-marker") }
        let after = try await testTerminals(manager)
        XCTAssertEqual(after.map(\.address), [address], "no new terminal")

        // hook 세부 정보가 상태를 바꾸지 않고 돌아오고, 다음 저장에 같은 값으로 남는다.
        try await waitUntil(5, "details restored") {
            await HookDaemon.shared.snapshot(paneId: paneId)?.lastSessionId == "hct-session"
        }
        let snapshot = await HookDaemon.shared.snapshot(paneId: paneId)
        XCTAssertEqual(snapshot?.state, .initializing)
        XCTAssertEqual(snapshot?.agentKind, .codex)
        XCTAssertEqual(snapshot?.lastPrompt, "fix the bug")
        let record = try XCTUnwrap(controller.sessionWindowRecord()?.rows.first?.first)
        XCTAssertEqual(record.paneId, paneId)
        XCTAssertEqual(record.backend, .hc)
        XCTAssertNil(record.machine)
        XCTAssertEqual(record.projectKey, "/private/tmp")
        XCTAssertEqual(record.projectId, pane.projectId)
        XCTAssertEqual(record.hookDetails, details)
        XCTAssertNil(controller.sessionWindowRecord(includeAgentResume: true)?.rows.first?.first?.agentResume,
                     "hc panes are not resumed: an update relaunch does not stop them")
    }

    /// Review Focus 4. hc를 쓸 수 없는 상태로 hc pane을 복원해도 local 셸로 바뀌지 않는다.
    func testHcPaneStaysUnavailableWhenCoreMissing() async throws {
        let manager = HcSessionManager(endpointProvider: { nil })
        addTeardownBlock { await manager.shutdown() }
        install(manager)
        let paneId = UUID().uuidString
        let windowManager = try await restore([window([
            PaneRecord(cwd: "/tmp", paneId: paneId, backend: .hc, projectId: "tmp", projectKey: "/private/tmp"),
        ])])
        let controller = try XCTUnwrap(windowManager.controllers.first)
        let pane = try XCTUnwrap(controller.panes.first)
        XCTAssertEqual(pane.paneId, paneId)
        XCTAssertEqual(pane.launch, .hc(machine: nil))
        let backend = try XCTUnwrap(pane.hcBackend)
        try await waitUntil(3, "unavailable") {
            if case .unavailable = backend.connectionState { return true }
            return false
        }
        XCTAssertEqual(manager.availability, .notInstalled)
        XCTAssertFalse(pane.terminal.process.running, "no local shell under the same pane id")
        XCTAssertNil(backend.address)

        // 저장해도 hc pane으로 남아 다음 실행에도 local 셸이 뜨지 않는다.
        let record = try XCTUnwrap(controller.sessionWindowRecord()?.rows.first?.first)
        XCTAssertEqual(record.paneId, paneId)
        XCTAssertEqual(record.launch, .hc(machine: nil))
    }

    func testOrphanAdoptedIntoWindow() async throws {
        let manager = try installScratchManager()
        // autosave 전에 꺼진 pane의 terminal: 저장된 레이아웃에는 없고 core에는 살아 있다.
        let orphanId = UUID().uuidString
        let orphanAddress = try await leaveTerminal(manager, paneId: orphanId)

        let knownId = UUID().uuidString
        let windowManager = try await restore([window([
            PaneRecord(cwd: "/tmp", paneId: knownId, backend: .hc, projectId: "tmp", projectKey: "/private/tmp"),
        ])])
        let controller = try XCTUnwrap(windowManager.controllers.first)
        let known = try await attachedBackend(try XCTUnwrap(controller.panes.first))

        await windowManager.adoptHcOrphans()
        XCTAssertEqual(controller.panes.map(\.paneId), [knownId, orphanId])
        let adopted = controller.panes[1]
        XCTAssertEqual(adopted.launch, .hc(machine: nil))
        XCTAssertEqual(adopted.projectKey, "/private/tmp", "the pane takes the terminal's termy.project label")
        let adoptedBackend = try await attachedBackend(adopted)
        XCTAssertEqual(adoptedBackend.address, orphanAddress, "attached to the orphan, not a new shell")
        let live = Set(try await testTerminals(manager).filter { $0.state == "live" }.map(\.address))
        XCTAssertEqual(live, Set([try XCTUnwrap(known.address), orphanAddress]))

        // 이미 pane이 있는 terminal은 다시 열지 않는다.
        await windowManager.adoptHcOrphans()
        XCTAssertEqual(controller.panes.count, 2)
    }

    /// R13. 복원한 원격 pane은 그 머신이 지금 구독에서 연결된 것을 보기 전에는 terminal.run을 부르지 않는다.
    /// scratch core에는 머신이 없으므로 끝까지 기다리는 쪽만 볼 수 있다(머신을 본 뒤 띄우는 쪽은 HcRestorePlannerTests).
    func testRestoredRemotePaneWaitsForItsMachine() async throws {
        let manager = try installScratchManager()
        let paneId = UUID().uuidString
        let windowManager = try await restore([window([
            PaneRecord(cwd: "/srv/app", paneId: paneId, backend: .hc, machine: "hct-ghost", projectId: "app@hct-ghost",
                       projectKey: "hct-ghost:/srv/app"),
        ])])
        let pane = try XCTUnwrap(windowManager.controllers.first?.panes.first)
        XCTAssertEqual(pane.launch, .hc(machine: "hct-ghost"))
        XCTAssertEqual(pane.projectId, "app@hct-ghost")
        let backend = try XCTUnwrap(pane.hcBackend)
        try await waitUntil(5, "connected") {
            if case .connected = manager.availability { return true }
            return false
        }
        // 연결 뒤 reattach → machine.list 응답까지 돌 시간을 준다.
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(backend.connectionState, .connecting)
        XCTAssertNil(backend.address)
        XCTAssertFalse(manager.hasSeenMachine("hct-ghost"))
        let terminals = try await testTerminals(manager)
        XCTAssertFalse(terminals.contains { $0.labels["termy.pane"] == paneId }, "no shell for a machine never seen")
    }
}

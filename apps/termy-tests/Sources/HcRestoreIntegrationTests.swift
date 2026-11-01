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
    private func restore(_ windows: [WindowRecord], defaults: UserDefaults = InMemoryUserDefaults(),
                         expectWindow: Bool = true) async throws -> WindowManager {
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
        XCTAssertEqual(restored, expectWindow, "the saved session opened a window")
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

    /// address를 모른 채 닫힌 pane(머신이 끊겨 있던 원격 pane)의 terminal이 나중에 오면(`created`) kill한다.
    /// scratch core에는 머신이 없으므로, 닫은 뒤에 같은 label의 local terminal을 띄워 늦게 오는 terminal을 흉내 낸다.
    func testClosedPaneTerminalArrivingLaterIsKilled() async throws {
        let manager = try installScratchManager()
        try await manager.ensureConnected()
        let paneId = UUID().uuidString
        manager.killPane(paneId: paneId)   // 아직 그 pane의 terminal이 없다
        XCTAssertFalse(manager.hasPendingKills, "quitting does not wait for a terminal that may never come")

        let params = HcPaneBackend.runParams(paneId: paneId, projectKey: "bdpc01:/srv/app", projectId: "app@bdpc01",
                                             launch: HcLaunch(machine: nil, cwd: "/tmp", shell: "/bin/sh"),
                                             instance: HcSessionManager.instanceLabel, baseEnvironment: [:])
        let late: HcTerminal = try await manager.call("terminal.run", params)
        try await waitUntil(5, "the late terminal is killed") {
            let live = (try? await self.testTerminals(manager))?.filter { $0.state == "live" }.map(\.address)
            return live.map { !$0.contains(late.address) } ?? false
        }

        // 같은 id로 다시 연 pane(⌘K 등)의 terminal은 kill하지 않는다.
        let reopened = UUID().uuidString
        manager.killPane(paneId: reopened)
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let backend = HcPaneBackend(paneId: reopened, projectKey: "/private/tmp", projectId: "tmp",
                                    launch: HcLaunch(machine: nil, cwd: "/tmp", shell: "/bin/sh"), view: view, manager: manager)
        addTeardownBlock { @MainActor in backend.detach() }
        backend.start()
        try await waitUntil(5, "reopened pane attached") { backend.connectionState == .attached }
        let address = try XCTUnwrap(backend.address)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(backend.connectionState, .attached)
        let live = try await testTerminals(manager).filter { $0.state == "live" }.map(\.address)
        XCTAssertTrue(live.contains(address), "a pane opened again under that id keeps its terminal")
    }

    /// R13b의 확인 호출이 실제 core에서 labels로 걸러지고 machines가 함께 오는지(원격 pane이 띄우기 직전에 쓴다).
    func testPaneLookupFiltersByPaneLabel() async throws {
        let manager = try installScratchManager()
        let wanted = UUID().uuidString
        _ = try await leaveTerminal(manager, paneId: wanted)
        _ = try await leaveTerminal(manager, paneId: UUID().uuidString)
        let lookup: HcPaneLookup = try await manager.call(
            "terminal.list", HcPaneBackend.paneLookupParams(paneId: wanted, instance: HcSessionManager.instanceLabel))
        XCTAssertEqual(lookup.terminals.map { $0.labels["termy.pane"] }, [wanted])
        // hc 0.1.16은 머신이 없으면 machines 키를 빼고 보낸다(schema는 required라고 한다). 없어도 풀려야 한다.
        XCTAssertEqual(lookup.machines ?? [], [], "the scratch core has no machines")
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

    // MARK: - Debug와 release가 session.json을 함께 쓸 때(R19, R20)

    /// R19. local pane은 저장된 id를 다시 쓰지 않는다. 다시 붙을 것이 없고, 함께 쓰는 session.json에서 다른 instance의
    /// local pane id를 가져오면 그 instance의 agent hook이 이 pane의 상태를 움직인다.
    func testLocalRecordGetsAFreshPaneId() async throws {
        let manager = HcSessionManager(endpointProvider: { nil })
        addTeardownBlock { await manager.shutdown() }
        install(manager)
        let saved = UUID().uuidString
        let windowManager = try await restore([window([
            PaneRecord(cwd: "/tmp", paneId: saved, backend: .local, projectId: "tmp"),
        ])])
        let pane = try XCTUnwrap(windowManager.controllers.first?.panes.first)
        XCTAssertEqual(pane.launch, .local)
        XCTAssertNotEqual(pane.paneId, saved, "a local pane gets a new id")
    }

    /// R20. 다른 instance가 남긴 hc pane은 복원하지 않는다(그 terminal은 그 instance가 고아로 되찾는다). instance가
    /// 없는 hc 기록(이 필드 전의 파일)은 이 instance의 것이다. 저장할 때는 hc pane에만 자기 instance를 남긴다.
    func testOtherInstanceHcPanesAreNotRestored() async throws {
        let manager = HcSessionManager(endpointProvider: { nil })
        addTeardownBlock { await manager.shutdown() }
        install(manager)
        let other = UUID().uuidString, mine = UUID().uuidString, older = UUID().uuidString
        func hc(_ id: String, _ instance: String?) -> PaneRecord {
            PaneRecord(cwd: "/tmp", paneId: id, backend: .hc, projectId: "tmp", projectKey: "/private/tmp", instance: instance)
        }
        let windowManager = try await restore([
            window([hc(other, "release"), PaneRecord(cwd: "/tmp", backend: .local, projectId: "tmp"),
                    hc(mine, "test"), hc(older, nil)]),
            window([hc(UUID().uuidString, "release")]),
        ])
        XCTAssertEqual(windowManager.controllers.count, 1, "a window of only another instance's panes is not opened")
        let controller = try XCTUnwrap(windowManager.controllers.first)
        XCTAssertEqual(controller.panes.map(\.launch), [.local, .hc(machine: nil), .hc(machine: nil)])
        XCTAssertEqual(controller.panes.dropFirst().map(\.paneId), [mine, older])
        XCTAssertFalse(controller.panes.contains { $0.paneId == other })

        let records = try XCTUnwrap(controller.sessionWindowRecord()?.rows.flatMap { $0 })
        XCTAssertEqual(records.map(\.instance), [nil, "test", "test"], "hc panes record this instance; local panes don't")
    }

    func testSessionOfOnlyOtherInstancePanesOpensNoWindow() async throws {
        let manager = HcSessionManager(endpointProvider: { nil })
        addTeardownBlock { await manager.shutdown() }
        install(manager)
        let windowManager = try await restore([window([
            PaneRecord(cwd: "/tmp", paneId: UUID().uuidString, backend: .hc, projectId: "tmp", projectKey: "/private/tmp",
                       instance: "release"),
        ])], expectWindow: false)
        XCTAssertTrue(windowManager.controllers.isEmpty)
    }

    // MARK: - hook 세부 정보 저장(I1)

    /// hc pane의 hook 세부 정보가 바뀌면 레이아웃이 그대로여도 session.json에 저장한다(⌘Q나 강제 종료 뒤에도 prompt·
    /// 마지막 응답·sessionId가 남게). local pane은 세부 정보를 남기지 않으므로 저장을 요청하지 않는다.
    /// MissionControlModel → WindowManager 연결은 AppDelegate처럼 이어 붙인다(테스트 host에서는 AppDelegate가 잇지 않는다).
    func testHcHookDetailsChangeSavesTheSession() async throws {
        let manager = HcSessionManager(endpointProvider: { nil })
        addTeardownBlock { await manager.shutdown() }
        install(manager)
        let hcId = UUID().uuidString
        let windowManager = try await restore([window([
            PaneRecord(cwd: "/tmp", paneId: hcId, backend: .hc, projectId: "tmp", projectKey: "/private/tmp"),
            PaneRecord(cwd: "/tmp", backend: .local, projectId: "tmp"),
        ])])
        let model = MissionControlModel.shared
        model.onHookDetailsChanged = { [weak windowManager] in windowManager?.hookDetailsChanged(paneId: $0) }
        addTeardownBlock { @MainActor in MissionControlModel.shared.onHookDetailsChanged = nil }
        let controller = try XCTUnwrap(windowManager.controllers.first)
        let localId = try XCTUnwrap(controller.panes.last?.paneId)
        let autosaver = try XCTUnwrap(windowManager.sessionAutosaver)
        let file = autosaver.persistence.fileURL

        // 복원이 요청한 저장(과 그 뒤의 헤더 갱신 저장)을 끝낸 뒤 파일을 지워 다음 저장만 본다.
        try await Task.sleep(for: .milliseconds(700))
        await autosaver.flushSync()
        try FileManager.default.removeItem(at: file)

        var local = PaneSnapshot.empty(paneId: localId, projectId: "tmp")
        local.lastSessionId = "local-session"
        local.lastPrompt = "local prompt"
        model.applySnapshot(local)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a local pane's hook details don't save the session")

        var hc = PaneSnapshot.empty(paneId: hcId, projectId: "tmp")
        hc.state = .thinking
        model.applySnapshot(hc)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a state-only update doesn't save the session")

        hc.lastSessionId = "hc-session"
        hc.lastPrompt = "ship it"
        hc.agentKind = .codex
        model.applySnapshot(hc)
        try await waitUntil(3, "session saved after the hook") { FileManager.default.fileExists(atPath: file.path) }
        guard case .loaded(let saved) = await autosaver.persistence.load() else { return XCTFail("the saved session loads") }
        let record = saved.windows.flatMap { $0.rows.flatMap { $0 } }.first { $0.paneId == hcId }
        XCTAssertEqual(record?.hookDetails,
                       PaneHookDetails(lastSessionId: "hc-session", lastPrompt: "ship it", lastAssistantMessage: nil,
                                       lastCwd: nil, agentKind: .codex))
    }
}

import XCTest
import AppKit
@testable import termy

// 원격 project 흐름 가운데 머신 없이 볼 수 있는 것. scratch core(HcTestCore)에는 머신이 없으므로 머신이 없는 결과의
// decode, machine.exec 인자 모양(on 없이 이 Mac에서 돈다), 없는 머신에서의 폴더 확인 실패와 Windows 판정을 본다.
// ⌘K 기록 저장 → 다시 열기, 새 원격 project 열기, 원격 pane을 따르는 새 pane은 endpoint 없는 manager로 본다(원격
// pane은 "not installed"로 기다릴 뿐 어디에도 셸을 띄우지 않는다).
// 사용자 core와 데이터는 건드리지 않는다: HcSessionManager.shared는 바꿔 끼우고 되돌리며, WindowManager에는 임시
// 폴더의 SessionPersistence·WorkspacePersistence와 InMemoryUserDefaults를 넣는다. 셸은 SHELL=/bin/sh,
// label은 TERMY_INSTANCE=test. 테스트 host는 마지막 창이 닫히면 끝나므로 창은 닫지 않고 붙잡아 둔다.

@MainActor
final class HcRemoteProjectIntegrationTests: XCTestCase {
    private static var retiredControllers: [MainWindowController] = []
    private static var retiredSheets: [RemoteProjectSheet] = []

    private var savedEnvironment: [String: String?] = [:]
    private var savedManager: HcSessionManager?

    override func setUp() async throws {
        for (key, value) in [("TERMY_INSTANCE", "test"), ("SHELL", "/bin/sh")] {
            savedEnvironment[key] = getenv(key).map { String(cString: $0) }
            setenv(key, value, 1)
        }
    }

    override func tearDown() async throws {
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

    private func scratchManager() throws -> HcSessionManager {
        let core = try HcTestCore.makeOrSkip()
        addTeardownBlock { await core.stop() }
        let endpoint = core.endpoint
        let manager = HcSessionManager(endpointProvider: { endpoint })
        addTeardownBlock { await manager.shutdown() }   // 역순: 연결을 닫은 뒤 core를 멈춘다
        return manager
    }

    private func installManagerWithoutCore() {
        let manager = HcSessionManager(endpointProvider: { nil })
        addTeardownBlock { await manager.shutdown() }
        install(manager)
    }

    /// 임시 폴더의 session.json에 windows를 쓰고 그 폴더만 쓰는 WindowManager로 복원한다. ⌘K 기록 폴더도 돌려준다.
    private func restore(_ windows: [WindowRecord]) async throws -> (WindowManager, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("termy-remote-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let persistence = try SessionPersistence(rootDir: root)
        try await persistence.save(SessionRecord(windows: windows))
        let workspaces = root.appendingPathComponent("workspaces", isDirectory: true)
        let windowManager = WindowManager(sessionPersistence: persistence,
                                          workspacePersistence: { try? WorkspacePersistence(rootDir: workspaces) },
                                          defaults: InMemoryUserDefaults())
        addTeardownBlock { @MainActor in await Self.retire(windowManager) }
        let restored = await windowManager.restoreSessionWindows()
        XCTAssertTrue(restored, "the saved session opened a window")
        return (windowManager, workspaces)
    }

    /// 창을 닫지 않고 정리한다(HcRestoreIntegrationTests와 같다): hc viewer를 떼고 local 셸을 끝내고 등록을 푼다.
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
        WindowRecord(frame: FrameRecord(x: 140, y: 140, width: 900, height: 600), rows: [panes])
    }

    private func loaded(_ key: String, in workspaces: URL) async throws -> WorkspaceRecord {
        let persistence = try WorkspacePersistence(rootDir: workspaces)
        guard case .loaded(let record) = await persistence.load(canonicalPath: key) else {
            XCTFail("no saved record for \(key)")
            throw HcTimeoutError()
        }
        return record
    }

    private let remotePane = PaneRecord(cwd: "/srv/app/sub", backend: .hc, machine: "bdpc01",
                                        projectId: "app@bdpc01", projectKey: "bdpc01:/srv/app")

    // MARK: - hc가 빈 배열을 빼먹은 결과(scratch core)

    func testMachinesIsEmptyOnACoreWithoutMachines() async throws {
        let manager = try scratchManager()
        let machines = try await manager.machines()
        XCTAssertEqual(machines, [])
    }

    /// 새 원격 pane이 terminal.run 직전에 묻는 label 조회(R13b)는 처음에는 맞는 terminal이 없다.
    func testPaneLookupWithoutAMatchDecodesEmpty() async throws {
        let manager = try scratchManager()
        let lookup: HcPaneLookup = try await manager.call(
            "terminal.list", HcPaneBackend.paneLookupParams(paneId: UUID().uuidString, instance: "test"))
        XCTAssertEqual(lookup.terminals, [])
        XCTAssertEqual(lookup.machines ?? [], [])
    }

    // MARK: - machine.exec

    /// 폴더 확인과 Windows 판정이 쓰는 machine.exec 인자(argv·on·timeout)를 core가 받는다. on이 없으면 이 Mac에서 돈다.
    func testExecRunsArgvAndReturnsTheExitCode() async throws {
        let manager = try scratchManager()
        let present = try await manager.exec(on: nil, argv: ["test", "-d", "/tmp"])
        XCTAssertEqual(present, HcExecResult(code: 0, timedOut: false))
        let missing = try await manager.exec(on: nil, argv: ["test", "-d", "/nonexistent-\(UUID().uuidString)"])
        XCTAssertNotNil(missing.exitCode)
        XCTAssertNotEqual(missing.exitCode, 0)
        let uname = try await manager.exec(on: nil, argv: ["uname"])
        XCTAssertEqual(uname.exitCode, 0)
    }

    /// 시간이 다 된 실행은 오류가 아니라 결과로 온다(`timed_out`). termy는 그것을 프로그램의 답으로 읽지 않는다.
    func testExecTimeoutIsAResultWithoutAnExitCode() async throws {
        let manager = try scratchManager()
        let slow = try await manager.exec(on: nil, argv: ["sleep", "5"], timeout: 1)
        XCTAssertTrue(slow.timedOut)
        XCTAssertNil(slow.exitCode)
        let verdict = RemoteProject.windowsVerdict(.success(slow))
        XCTAssertFalse(verdict.cache, "a timed-out uname is not remembered")
    }

    /// 없는 머신에서 uname을 부르면 실패한다: Windows로 보여 주되(만들 수 없다) 기억하지 않는다.
    func testWindowsCheckFailureIsNotRemembered() async throws {
        let manager = try scratchManager()
        let machine = "nosuch-\(UUID().uuidString.prefix(6))"
        let windows = await RemoteProjectSheet.isWindows(machine: machine, manager: manager)
        XCTAssertTrue(windows)
        XCTAssertNil(RemoteProjectSheet.rememberedWindows[machine])
    }

    /// 그 머신에서 폴더를 확인하지 못하면 만들지 않고 이유를 보여 준다.
    func testCreateWithAFolderTheMachineCantFindShowsTheError() async throws {
        let manager = try scratchManager()
        try await manager.ensureConnected()
        var created: [WorkspaceRecord] = []
        let sheet = RemoteProjectSheet(manager: manager, onCreate: { created.append($0) })
        Self.retiredSheets.append(sheet)
        sheet.show(machines: [HcMachine(name: "box", host: nil, state: "connected", why: nil)], windows: [])
        sheet.folderField.stringValue = "/tmp"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.folderField))

        await sheet.create()

        XCTAssertEqual(sheet.messageLabel.stringValue, "Folder not found on box.")
        XCTAssertEqual(created, [])
        XCTAssertTrue(sheet.createButton.isEnabled, "the user can fix the folder and try again")
    }

    // MARK: - ⌘K 기록(endpoint 없는 manager)

    /// R17: 원격 pane은 원격 기록으로 저장되고(가짜 로컬 `/srv/app` 기록이 없다), ⌘K로 다시 열면 그 머신의 hc
    /// pane이 같은 project로 열린다. 이미 열려 있는 창에서는 pane을 더 만들지 않는다.
    func testRemoteProjectRoundTripsThroughAutosaveAndReopen() async throws {
        installManagerWithoutCore()
        let (windowManager, workspaces) = try await restore([
            window([remotePane, PaneRecord(cwd: "/tmp")]),
            window([PaneRecord(cwd: "/tmp")]),
        ])
        XCTAssertEqual(windowManager.controllers.count, 2)
        let first = windowManager.controllers[0]
        let second = windowManager.controllers[1]
        await first.autosaver?.flushSync()

        let record = try await loaded("bdpc01:/srv/app", in: workspaces)
        XCTAssertEqual(record.machine, "bdpc01")
        XCTAssertEqual(record.displayLabel, "app@bdpc01")
        XCTAssertEqual(record.panes, [remotePane])
        let all = await (try WorkspacePersistence(rootDir: workspaces)).all()
        XCTAssertFalse(all.contains { $0.machine == nil && $0.canonicalPath.hasSuffix("/srv/app/sub") },
                       "no local record for the remote cwd: \(all.map(\.canonicalPath))")
        XCTAssertTrue(all.filter { $0.machine == nil }.allSatisfy { $0.panes.allSatisfy { $0.backend == nil && $0.machine == nil } },
                      "local records keep cwd-only panes")

        let before = first.panes.count
        first.restore(workspace: record)
        XCTAssertEqual(first.panes.count, before, "an open remote project is only shown, not opened again")

        second.restore(workspace: record)
        let reopened = second.panes.filter(\.isRemote)
        XCTAssertEqual(reopened.count, 1)
        let pane = try XCTUnwrap(reopened.first)
        XCTAssertEqual(pane.launch, .hc(machine: "bdpc01"))
        XCTAssertEqual(pane.projectId, "app@bdpc01")
        XCTAssertEqual(pane.projectKey, "bdpc01:/srv/app")
        XCTAssertEqual(pane.currentCwd, "/srv/app/sub")
        XCTAssertEqual(pane.hcBackend?.launch, HcLaunch(machine: "bdpc01", cwd: "/srv/app/sub", shell: "/bin/sh"))
    }

    /// 시트의 onCreate: 기록을 저장하고 그 project를 연다. 열린 원격 pane에서 새 pane을 만들면 같은 머신·폴더·project다.
    func testCreatedRemoteProjectIsSavedAndOpens() async throws {
        installManagerWithoutCore()
        let (windowManager, workspaces) = try await restore([window([PaneRecord(cwd: "/tmp")])])
        let controller = try XCTUnwrap(windowManager.controllers.first)

        await controller.openRemoteProject(RemoteProject.record(machine: "bdpc01", folder: "/srv/app", now: Date()))

        let saved = try await loaded("bdpc01:/srv/app", in: workspaces)
        XCTAssertEqual(saved.machine, "bdpc01")
        XCTAssertEqual(saved.displayLabel, "app@bdpc01")
        let remote = controller.panes.filter(\.isRemote)
        XCTAssertEqual(remote.count, 1)
        XCTAssertEqual(remote.first?.launch, .hc(machine: "bdpc01"))
        XCTAssertEqual(remote.first?.projectId, "app@bdpc01")
        XCTAssertEqual(remote.first?.projectKey, "bdpc01:/srv/app")
        XCTAssertEqual(remote.first?.currentCwd, "/srv/app")

        controller.newPane(nil)
        controller.splitColumn(nil)
        let after = controller.panes.filter(\.isRemote)
        XCTAssertEqual(after.count, 3, "new panes next to a remote pane are remote panes")
        for pane in after {
            XCTAssertEqual(pane.launch, .hc(machine: "bdpc01"))
            XCTAssertEqual(pane.projectId, "app@bdpc01")
            XCTAssertEqual(pane.projectKey, "bdpc01:/srv/app")
            XCTAssertEqual(pane.currentCwd, "/srv/app")
        }
    }

    /// 원격 pane에 포커스가 있을 때 생기는 local pane(고아 terminal 입양 등)은 그 머신의 폴더와 project를 빌리지 않는다.
    func testLocalPaneNextToARemotePaneKeepsToThisMac() async throws {
        installManagerWithoutCore()
        let (windowManager, _) = try await restore([window([PaneRecord(cwd: "/tmp")])])
        let controller = try XCTUnwrap(windowManager.controllers.first)
        await controller.openRemoteProject(RemoteProject.record(machine: "bdpc01", folder: "/srv/app", now: Date()))
        XCTAssertEqual(controller.panes.last?.isRemote, true, "the remote pane is focused")

        let paneId = UUID().uuidString
        controller.adoptHcOrphan(HcOrphan(paneId: paneId, address: "t99", machine: nil, projectKey: nil, cwd: nil))

        let local = try XCTUnwrap(controller.panes.first { $0.paneId == paneId })
        XCTAssertEqual(local.launch, .hc(machine: nil))
        XCTAssertNotEqual(local.currentCwd, "/srv/app")
        XCTAssertNotEqual(local.projectId, "app@bdpc01")
        XCTAssertFalse(local.projectKey.hasPrefix("bdpc01:"))
    }

    /// 같은 머신·폴더의 기록이 이미 있으면 덮어쓰지 않고 그 레이아웃으로 연다.
    func testCreatingAnExistingRemoteProjectOpensItsSavedLayout() async throws {
        installManagerWithoutCore()
        let (windowManager, workspaces) = try await restore([window([PaneRecord(cwd: "/tmp")])])
        let controller = try XCTUnwrap(windowManager.controllers.first)
        var existing = RemoteProject.record(machine: "bdpc01", folder: "/srv/app", now: Date(timeIntervalSince1970: 0))
        existing.panes.append(PaneRecord(cwd: "/srv/app/docs", backend: .hc, machine: "bdpc01",
                                         projectId: "app@bdpc01", projectKey: "bdpc01:/srv/app"))
        try await WorkspacePersistence(rootDir: workspaces).save(existing)

        await controller.openRemoteProject(RemoteProject.record(machine: "bdpc01", folder: "/srv/app", now: Date()))

        XCTAssertEqual(controller.panes.filter(\.isRemote).map(\.currentCwd), ["/srv/app", "/srv/app/docs"])
    }
}

import XCTest
import AppKit
@testable import termy

// Workspace에서 hc pane을 만들고 닫는 수명을 scratch core(HcTestCore)에서 본다: pane을 닫으면 terminal이 끝나고,
// 창을 닫으면 그 창의 hc terminal이 끝나지만 앱 종료 중에는 남고, 셸이 끝나면 pane이 닫힌다.
// 사용자 core는 건드리지 않는다: 모든 테스트가 hc pane을 만들기 전에 HcSessionManager.shared를 scratch endpoint
// manager로 바꾸고 tearDown에서 되돌린다. 셸은 SHELL=/bin/sh(사용자 zsh dotfiles 대신), label은 TERMY_INSTANCE=test.
// 테스트 host는 마지막 창이 닫히면 끝나므로, 닫지 않는 sentinel 창 안에 Workspace를 둔다.

@MainActor
final class HcPaneLifecycleIntegrationTests: XCTestCase {
    private struct ListResult: Decodable, Sendable { let terminals: [HcTerminal] }

    /// 닫지 않는다: 테스트 host 앱은 마지막 창이 사라지면 끝난다.
    private static let sentinel: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }()

    private var savedEnvironment: [String: String?] = [:]
    private var savedManager: HcSessionManager?

    override func setUp() async throws {
        for (key, value) in [("TERMY_INSTANCE", "test"), ("SHELL", "/bin/sh")] {
            savedEnvironment[key] = getenv(key).map { String(cString: $0) }
            setenv(key, value, 1)
        }
        Self.sentinel.orderOut(nil)
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

    /// scratch core에 붙는 manager를 HcSessionManager.shared에 넣는다. hc pane을 만들기 전에 불러야 한다.
    private func installScratchManager() throws -> HcSessionManager {
        let core = try HcTestCore.makeOrSkip()
        addTeardownBlock { await core.stop() }
        let endpoint = core.endpoint
        let manager = HcSessionManager(endpointProvider: { endpoint })
        addTeardownBlock { await manager.shutdown() }   // 역순: 연결을 닫은 뒤 core를 멈춘다
        if savedManager == nil { savedManager = HcSessionManager.shared }
        HcSessionManager.shared = manager
        return manager
    }

    private func makeWorkspace() -> Workspace {
        let contentView = Self.sentinel.contentView!
        let workspace = Workspace(frame: contentView.bounds)
        workspace.autoresizingMask = [.width, .height]
        contentView.addSubview(workspace)
        // manager보다 먼저 돈다(teardown block은 역순): 남은 pane은 viewer만 떠나고 terminal은 core와 함께 끝난다.
        addTeardownBlock { @MainActor in
            for pane in workspace.panes { pane.hcBackend?.detach() }
            workspace.removeFromSuperview()
        }
        return workspace
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

    private func attachedBackend(_ pane: Pane) async throws -> HcPaneBackend {
        let backend = try XCTUnwrap(pane.hcBackend, "an hc pane has a backend")
        try await waitUntil(5, "attached") { backend.connectionState == .attached }
        return backend
    }

    private func testTerminals(_ manager: HcSessionManager) async throws -> [HcTerminal] {
        let r: ListResult = try await manager.call("terminal.list", HcEmptyParams())
        return r.terminals.filter { $0.labels["termy.instance"] == "test" }
    }

    private func liveAddresses(_ manager: HcSessionManager) async throws -> Set<String> {
        Set(try await testTerminals(manager).filter { $0.state == "live" }.map(\.address))
    }

    func testClosingHcPaneKillsTerminal() async throws {
        let manager = try installScratchManager()
        let workspace = makeWorkspace()
        let pane = workspace.addPane(cwd: "/tmp", launch: .hc(machine: nil))
        XCTAssertEqual(pane.launch, .hc(machine: nil))
        XCTAssertFalse(pane.isRemote)
        let backend = try await attachedBackend(pane)
        let address = try XCTUnwrap(backend.address)
        let before = try await testTerminals(manager)
        XCTAssertEqual(before.first { $0.address == address }?.labels["termy.pane"], pane.paneId)
        XCTAssertEqual(before.first { $0.address == address }?.labels["termy.project"], pane.projectKey)

        XCTAssertTrue(workspace.closeFocusedPane(), "the only pane closed")
        XCTAssertFalse(workspace.panes.contains { $0 === pane })
        await manager.flushPendingKills(timeout: 2)
        let after = try await testTerminals(manager)
        XCTAssertFalse(after.contains { $0.address == address }, "closing the pane kills its terminal")
    }

    func testWindowCloseKillsHcPanesUnlessTerminating() async throws {
        let manager = try installScratchManager()

        // 사용자가 창을 닫았다: 그 창의 hc terminal을 모두 끝낸다(MainWindowController.windowWillClose).
        let closing = makeWorkspace()
        let a = closing.addPane(cwd: "/tmp", launch: .hc(machine: nil))
        let b = closing.addPane(cwd: "/tmp", splitAxis: .column, launch: .hc(machine: nil))
        let killed = [try await attachedBackend(a).address, try await attachedBackend(b).address].compactMap { $0 }
        XCTAssertEqual(killed.count, 2)
        closing.windowWillClose()
        await manager.flushPendingKills(timeout: 2)
        let afterClose = try await liveAddresses(manager)
        XCTAssertTrue(afterClose.isDisjoint(with: killed), "window close kills its hc terminals")

        // 앱 종료 중(⌘Q, 업데이트 재시작)에 창이나 pane이 정리되면 terminal은 남는다. 다음 실행 때 다시 붙는다.
        let quitting = makeWorkspace()
        let c = quitting.addPane(cwd: "/tmp", launch: .hc(machine: nil))
        let d = quitting.addPane(cwd: "/tmp", splitAxis: .column, launch: .hc(machine: nil))
        let kept = [try await attachedBackend(c).address, try await attachedBackend(d).address].compactMap { $0 }
        XCTAssertEqual(kept.count, 2)
        AppLifecycle.isTerminating = true
        quitting.closePane(d)
        quitting.windowWillClose()
        await manager.flushPendingKills(timeout: 0.5)
        try await Task.sleep(for: .milliseconds(300))
        let afterQuit = try await liveAddresses(manager)
        XCTAssertTrue(Set(kept).isSubset(of: afterQuit), "terminals survive a quit")
    }

    /// Review Focus 1. 마지막 창을 닫으면 kill이 보류된 채 앱이 곧 끝난다. applicationWillTerminate가 쓰는 그대로
    /// main run loop를 돌리며 기다리면 hc의 응답까지 받은 뒤(terminal이 끝난 뒤) 돌아와야 한다.
    func testPendingKillsFlushBeforeExit() throws {
        let manager = try installScratchManager()
        let workspace = makeWorkspace()
        let pane = workspace.addPane(cwd: "/tmp", launch: .hc(machine: nil))
        let backend = try XCTUnwrap(pane.hcBackend)
        XCTAssertTrue(AppLifecycle.runMainLoop(timeout: 5) {
            while backend.connectionState != .attached { try? await Task.sleep(for: .milliseconds(20)) }
        }, "attached")
        let address = try XCTUnwrap(backend.address)

        XCTAssertTrue(workspace.closeFocusedPane())
        XCTAssertTrue(manager.hasPendingKills)
        let started = Date()
        let flushed = AppLifecycle.waitForPendingHcKills(manager, timeout: 0.3)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(flushed, "the flush finished before its deadline")
        XCTAssertLessThan(elapsed, 0.3)
        XCTAssertFalse(manager.hasPendingKills)

        let terminals = TestBox<[HcTerminal]?>(nil)
        XCTAssertTrue(AppLifecycle.runMainLoop(timeout: 5) {
            terminals.value = try? await self.testTerminals(manager)
        })
        let list = try XCTUnwrap(terminals.value)
        XCTAssertFalse(list.contains { $0.address == address }, "terminal.list no longer has the killed terminal")
    }

    func testHcPaneExitClosesPane() async throws {
        let manager = try installScratchManager()
        let workspace = makeWorkspace()
        let pane = workspace.addPane(cwd: "/tmp", launch: .hc(machine: nil))
        let backend = try await attachedBackend(pane)
        let address = try XCTUnwrap(backend.address)
        pane.terminal.send(txt: "exit\r")
        try await waitUntil(5, "pane removed") { !workspace.panes.contains { $0 === pane } }
        let live = try await liveAddresses(manager)
        XCTAssertFalse(live.contains(address))
    }

    /// R10: hc first paint의 OSC 7 바이트 모양(ST 앞 NUL, `…/path\0` ESC \\)이 pane cwd를 깨뜨리지 않는다.
    /// live로 한 번, 같은 paneId로 다시 붙은 first paint로 한 번 본다. 초기 cwd는 `/tmp`이고 OSC 7은
    /// `/private/tmp`를 알리므로, cwd가 바뀌었는지로 OSC 7이 실제로 적용됐는지 안다.
    func testOsc7WithNulKeepsCleanCwd() async throws {
        _ = try installScratchManager()
        let first = makeWorkspace().addPane(cwd: "/tmp", launch: .hc(machine: nil))
        let firstBackend = try await attachedBackend(first)
        // /bin/sh는 OSC 7을 스스로 보내지 않는다. spike에서 본 first paint의 바이트 그대로 셸이 보내게 한다.
        first.terminal.send(txt: "printf '\\033]7;file://localhost/private/tmp\\000\\033\\\\'\r")
        try await waitUntil(5, "live OSC 7 applied") { first.currentCwd == "/private/tmp" }
        firstBackend.detach()

        // 같은 paneId로 다시 연다(복원과 같은 경로): label로 같은 terminal을 찾아 history와 함께 붙는다.
        let pane = makeWorkspace().addPane(cwd: "/tmp", paneId: first.paneId, launch: .hc(machine: nil))
        let backend = try await attachedBackend(pane)
        XCTAssertEqual(backend.address, firstBackend.address, "re-attached, not a new terminal")
        try await waitUntil(5, "first-paint OSC 7 applied") { pane.currentCwd != "/tmp" }
        XCTAssertEqual(pane.currentCwd, "/private/tmp")
        XCTAssertEqual(pane.projectId, "tmp", "no drift to a garbage project path")
    }
}

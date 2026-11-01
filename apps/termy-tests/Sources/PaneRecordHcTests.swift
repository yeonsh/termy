import XCTest
@testable import termy

// hc pane을 session.json에 남기는 필드(paneId·backend·machine·project·hook 세부 정보)와, 그 필드가 없는 예전
// 파일이 지금처럼(새 id, local) 읽히는지, 그리고 복원한 hook 세부 정보가 pane 상태를 건드리지 않는지 본다.

final class PaneRecordHcTests: XCTestCase {
    func testOldPaneRecordDecodesAsLocal() throws {
        let r = try JSONDecoder().decode(PaneRecord.self, from: Data(#"{"cwd":"/tmp"}"#.utf8))
        XCTAssertNil(r.paneId); XCTAssertEqual(r.launch, .local)
        XCTAssertNil(r.backend)
        XCTAssertNil(r.machine)
        XCTAssertNil(r.projectId)
        XCTAssertNil(r.projectKey)
        XCTAssertNil(r.hookDetails)
    }

    func testHcPaneRecordRoundTrips() throws {
        let r = PaneRecord(cwd: "/srv/app", paneId: "P", backend: .hc, machine: "bdpc01", projectId: "app@bdpc01",
                           projectKey: "bdpc01:/srv/app", hookDetails: PaneHookDetails(lastSessionId: "s", lastPrompt: "p", lastAssistantMessage: nil, lastCwd: "/srv/app", agentKind: .claude))
        XCTAssertEqual(try JSONDecoder().decode(PaneRecord.self, from: JSONEncoder().encode(r)), r)
        XCTAssertEqual(r.launch, .hc(machine: "bdpc01"))
    }

    func testLocalHcRecordLaunchesWithoutMachine() {
        XCTAssertEqual(PaneRecord(cwd: "/tmp", backend: .hc).launch, .hc(machine: nil))
        XCTAssertEqual(PaneRecord(cwd: "/tmp", backend: .local, machine: "ignored").launch, .local)
    }

    /// 새 필드가 없는 pane은 예전과 같은 JSON이 된다(키가 생기지 않는다).
    func testRecordWithoutNewFieldsEncodesLikeBefore() throws {
        let json = String(decoding: try JSONEncoder().encode(PaneRecord(cwd: "/a")), as: UTF8.self)
        for key in ["paneId", "backend", "machine", "projectId", "projectKey", "hookDetails"] {
            XCTAssertFalse(json.contains(key), key)
        }
    }

    /// 예전 session.json 전체가 그대로 읽히고, 모든 pane이 local·새 id로 복원된다.
    func testOldSessionFileDecodesWithLocalPanes() throws {
        let legacy = #"""
        {"schemaVersion":1,"windows":[{"frame":{"x":0,"y":0,"width":1200,"height":760},
          "rows":[[{"cwd":"/a"},{"cwd":"/b","agentResume":{"kind":"claude","sessionId":"s1","flags":[]}}],[{"cwd":"/c"}]],
          "focusedPaneIndex":1}]}
        """#
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(legacy.utf8))
        let panes = record.windows.flatMap { $0.rows.flatMap { $0 } }
        XCTAssertEqual(panes.map(\.cwd), ["/a", "/b", "/c"])
        XCTAssertTrue(panes.allSatisfy { $0.paneId == nil && $0.launch == .local && $0.hookDetails == nil })
        XCTAssertEqual(panes[1].agentResume?.sessionId, "s1")
    }

    // MARK: - hook 세부 정보

    private func snapshot(_ build: (inout PaneSnapshot) -> Void) -> PaneSnapshot {
        var s = PaneSnapshot.empty(paneId: "P", projectId: "app")
        build(&s)
        return s
    }

    func testHookDetailsFromSnapshot() {
        XCTAssertNil(PaneHookDetails(snapshot: nil))
        XCTAssertNil(PaneHookDetails(snapshot: snapshot { _ in }), "an untouched snapshot has nothing worth saving")
        let s = snapshot {
            $0.lastSessionId = "s"; $0.lastPrompt = "p"; $0.lastAssistantMessage = "a"; $0.lastCwd = "/srv"; $0.agentKind = .codex
        }
        XCTAssertEqual(PaneHookDetails(snapshot: s),
                       PaneHookDetails(lastSessionId: "s", lastPrompt: "p", lastAssistantMessage: "a", lastCwd: "/srv", agentKind: .codex))
        XCTAssertEqual(PaneHookDetails(snapshot: snapshot { $0.agentKind = .codex })?.agentKind, .codex,
                       "a detected agent alone is kept: the next SessionStart then keeps the restored session id")
    }

    func testRestoreDetailsFillsFieldsWithoutTouchingState() async {
        let daemon = HookDaemon.testInstance()
        let details = PaneHookDetails(lastSessionId: "s", lastPrompt: "p", lastAssistantMessage: "a", lastCwd: "/srv", agentKind: .codex)
        await daemon.restoreDetails(paneId: "P", projectId: "app", details: details)
        let restored = await daemon.snapshot(paneId: "P")
        XCTAssertEqual(restored?.state, .initializing)
        XCTAssertEqual(restored?.needsAttention, false)
        XCTAssertEqual(restored?.projectId, "app")
        XCTAssertEqual(restored?.lastSessionId, "s")
        XCTAssertEqual(restored?.lastPrompt, "p")
        XCTAssertEqual(restored?.lastAssistantMessage, "a")
        XCTAssertEqual(restored?.lastCwd, "/srv")
        XCTAssertEqual(restored?.agentKind, .codex)
    }

    func testRestoreDetailsKeepsLiveStateAndFillsOnlyMissingFields() async {
        let daemon = HookDaemon.testInstance()
        await daemon.injectSnapshot {
            var s = PaneSnapshot.empty(paneId: "P", projectId: "app")
            s.state = .thinking
            s.turnOpen = true
            s.lastSessionId = "s"
            s.lastPrompt = "newer prompt"
            return s
        }
        await daemon.restoreDetails(paneId: "P", projectId: "app",
                                    details: PaneHookDetails(lastSessionId: "s", lastPrompt: "old", lastAssistantMessage: "a", lastCwd: "/srv", agentKind: .claude))
        let s = await daemon.snapshot(paneId: "P")
        XCTAssertEqual(s?.state, .thinking)
        XCTAssertEqual(s?.turnOpen, true)
        XCTAssertEqual(s?.lastPrompt, "newer prompt", "a live hook value is newer than the saved one")
        XCTAssertEqual(s?.lastAssistantMessage, "a")
        XCTAssertEqual(s?.lastCwd, "/srv")
    }

    func testRestoreDetailsIgnoresAnotherSession() async {
        let daemon = HookDaemon.testInstance()
        await daemon.injectSnapshot {
            var s = PaneSnapshot.empty(paneId: "P", projectId: "app")
            s.lastSessionId = "new"
            return s
        }
        await daemon.restoreDetails(paneId: "P", projectId: "app",
                                    details: PaneHookDetails(lastSessionId: "old", lastPrompt: "p", lastAssistantMessage: "a", lastCwd: "/srv", agentKind: .claude))
        let s = await daemon.snapshot(paneId: "P")
        XCTAssertEqual(s?.lastSessionId, "new")
        XCTAssertNil(s?.lastPrompt)
        XCTAssertNil(s?.lastAssistantMessage)
    }
}

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
        XCTAssertNil(r.instance)
    }

    func testHcPaneRecordRoundTrips() throws {
        let r = PaneRecord(cwd: "/srv/app", paneId: "P", backend: .hc, machine: "bdpc01", projectId: "app@bdpc01",
                           projectKey: "bdpc01:/srv/app", hookDetails: PaneHookDetails(lastSessionId: "s", lastPrompt: "p", lastAssistantMessage: nil, lastCwd: "/srv/app", agentKind: .claude),
                           instance: "release")
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
        for key in ["paneId", "backend", "machine", "projectId", "projectKey", "hookDetails", "instance"] {
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

    // MARK: - R20: 다른 instance의 hc pane

    private func hc(_ id: String, instance: String?, project: String = "app") -> PaneRecord {
        PaneRecord(cwd: "/srv", paneId: id, backend: .hc, projectId: project, projectKey: "/srv", instance: instance)
    }

    private func local(_ id: String, project: String = "app") -> PaneRecord {
        PaneRecord(cwd: "/srv", paneId: id, backend: .local, projectId: project)
    }

    private func ids(_ record: WindowRecord?) -> [[String?]]? {
        record.map { $0.rows.map { $0.map(\.paneId) } }
    }

    func testRestorableKeepsWindowsWithoutOtherInstancePanes() {
        let window = WindowRecord(frame: FrameRecord(x: 0, y: 0, width: 800, height: 600),
                                  rows: [[hc("A", instance: "debug"), local("B")], [hc("C", instance: nil)]],
                                  filterProjectId: "app", focusedPaneIndex: 2, projectOrder: ["app"])
        XCTAssertEqual(window.restorable(instance: "debug"), window, "nil instance (older file) counts as this instance")
        let empty = WindowRecord(frame: FrameRecord(x: 0, y: 0, width: 800, height: 600), rows: [])
        XCTAssertEqual(empty.restorable(instance: "debug"), empty, "nothing skipped: restore as before")
    }

    func testRestorableDropsOtherInstanceHcPanes() {
        let window = WindowRecord(frame: FrameRecord(x: 0, y: 0, width: 800, height: 600),
                                  rows: [[hc("R1", instance: "release"), local("L")],
                                         [hc("R2", instance: "release", project: "other")],
                                         [hc("D", instance: "debug"), hc("O", instance: nil)]],
                                  filterProjectId: "app", focusedPaneIndex: 3, projectOrder: ["app", "other"])
        let kept = window.restorable(instance: "debug")
        XCTAssertEqual(ids(kept), [["L"], ["D", "O"]], "empty rows go too")
        XCTAssertEqual(kept?.focusedPaneIndex, 1, "focus follows the same pane (D)")
        XCTAssertEqual(kept?.filterProjectId, "app")
        XCTAssertEqual(kept?.projectOrder, ["app", "other"])
        XCTAssertEqual(kept?.frame, window.frame)

        var focusedOnSkipped = window
        focusedOnSkipped.focusedPaneIndex = 0
        XCTAssertNil(focusedOnSkipped.restorable(instance: "debug")?.focusedPaneIndex)

        // 필터의 project에 남은 pane이 없으면 빈 화면 대신 전체를 보여 준다.
        var filteredToSkipped = window
        filteredToSkipped.filterProjectId = "other"
        XCTAssertNil(filteredToSkipped.restorable(instance: "debug")?.filterProjectId)
    }

    func testRestorableIsNilWhenEveryPaneBelongsToAnotherInstance() {
        let window = WindowRecord(frame: FrameRecord(x: 0, y: 0, width: 800, height: 600),
                                  rows: [[hc("R1", instance: "release")], [hc("R2", instance: "release")]])
        XCTAssertNil(window.restorable(instance: "debug"))
        XCTAssertNotNil(window.restorable(instance: "release"))
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

    /// Debug와 release가 session.json을 함께 쓰고 AgentKind는 늘어난다. 모르는 agentKind 하나가 파일 전체를
    /// 격리하게(모든 창 배치를 잃게) 하면 안 된다: 그 값만 nil로 읽고 나머지는 그대로다.
    func testUnknownAgentKindDecodesAsNil() throws {
        let json = #"{"lastSessionId":"s","lastPrompt":"p","lastAssistantMessage":"a","lastCwd":"/srv","agentKind":"gemini"}"#
        let details = try JSONDecoder().decode(PaneHookDetails.self, from: Data(json.utf8))
        XCTAssertEqual(details, PaneHookDetails(lastSessionId: "s", lastPrompt: "p", lastAssistantMessage: "a",
                                                lastCwd: "/srv", agentKind: nil))
        let known = try JSONDecoder().decode(PaneHookDetails.self, from: Data(#"{"agentKind":"codex"}"#.utf8))
        XCTAssertEqual(known.agentKind, .codex)
        XCTAssertNil(try JSONDecoder().decode(PaneHookDetails.self, from: Data("{}".utf8)).agentKind)
        let roundTrip = PaneHookDetails(lastSessionId: "s", lastPrompt: nil, lastAssistantMessage: nil, lastCwd: nil, agentKind: .opencode)
        XCTAssertEqual(try JSONDecoder().decode(PaneHookDetails.self, from: JSONEncoder().encode(roundTrip)), roundTrip)
    }

    func testSessionWithUnknownAgentKindLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("termy-kind-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let persistence = try SessionPersistence(rootDir: root)
        let file = #"""
        {"schemaVersion":1,"windows":[{"frame":{"x":0,"y":0,"width":1200,"height":760},
          "rows":[[{"cwd":"/a"},{"cwd":"/b","paneId":"P","backend":"hc","hookDetails":{"lastPrompt":"p","agentKind":"gemini"}}]]}]}
        """#
        try Data(file.utf8).write(to: persistence.fileURL)
        guard case .loaded(let record) = await persistence.load() else {
            return XCTFail("an unknown agent kind must not quarantine session.json")
        }
        let panes = record.windows.flatMap { $0.rows.flatMap { $0 } }
        XCTAssertEqual(panes.map(\.cwd), ["/a", "/b"])
        XCTAssertEqual(panes[1].hookDetails?.lastPrompt, "p")
        XCTAssertNil(panes[1].hookDetails?.agentKind)
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

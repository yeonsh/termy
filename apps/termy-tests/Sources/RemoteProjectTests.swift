import AppKit
import XCTest
@testable import termy

// 원격 project(머신 + 폴더)의 키·표시 이름·기록, ⌘K 머신 목록 표시, 원격 pane을 따르는 새 pane, ⌘K 기록 저장의
// 원격 묶음, 머신이 끊긴 채 닫은 원격 pane의 kill, hc가 빈 배열을 빼먹은 결과의 decode를 본다. hc 없이 도는
// 단위 테스트다(scratch core가 필요한 것은 HcRemoteProjectIntegrationTests).

@MainActor
final class RemoteProjectTests: XCTestCase {
    private static var retiredSheets: [RemoteProjectSheet] = []

    // MARK: - 키·기록

    func testKeyAndProjectId() {
        XCTAssertEqual(RemoteProject.key(machine: "bdpc01", folder: "/srv/app"), "bdpc01:/srv/app")
        XCTAssertEqual(RemoteProject.projectId(machine: "bdpc01", folder: "/srv/app"), "app@bdpc01")
    }

    func testRecordHasOneHcPane() {
        let r = RemoteProject.record(machine: "bdpc01", folder: "/srv/app", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r.machine, "bdpc01"); XCTAssertEqual(r.panes.first?.launch, .hc(machine: "bdpc01"))
        XCTAssertEqual(r.schemaVersion, WorkspaceRecord.currentSchemaVersion)
        XCTAssertEqual(r.canonicalPath, "bdpc01:/srv/app")
        XCTAssertEqual(r.displayLabel, "app@bdpc01")
        XCTAssertEqual(r.updatedAt, Date(timeIntervalSince1970: 0))
        XCTAssertNil(r.rows)
        XCTAssertEqual(r.panes, [PaneRecord(cwd: "/srv/app", backend: .hc, machine: "bdpc01",
                                            projectId: "app@bdpc01", projectKey: "bdpc01:/srv/app")])
    }

    func testOldWorkspaceRecordDecodesWithoutMachine() throws {
        let json = #"{"schemaVersion":1,"canonicalPath":"/p/api","displayLabel":"api","updatedAt":"2026-10-01T00:00:00Z","panes":[{"cwd":"/p/api"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(WorkspaceRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.machine)
        XCTAssertEqual(record.canonicalPath, "/p/api")
        XCTAssertEqual(record.panes.first?.launch, .local)
    }

    func testRemoteRecordRoundTripsThroughJSON() throws {
        let record = RemoteProject.record(machine: "bdpc01", folder: "/srv/app", now: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(WorkspaceRecord.self, from: encoder.encode(record)), record)
    }

    func testNormalizedFolder() {
        XCTAssertEqual(RemoteProject.normalizedFolder("  /srv/app/ "), "/srv/app")
        XCTAssertEqual(RemoteProject.normalizedFolder("/srv/app//"), "/srv/app")
        XCTAssertEqual(RemoteProject.normalizedFolder("/"), "/")
        XCTAssertNil(RemoteProject.normalizedFolder(""))
        XCTAssertNil(RemoteProject.normalizedFolder("   "))
        XCTAssertNil(RemoteProject.normalizedFolder("srv/app"), "relative to what? the folder must be absolute")
        XCTAssertNil(RemoteProject.normalizedFolder("~/app"), "machine.exec runs argv without a shell: ~ is not expanded")
    }

    // MARK: - 머신 목록

    func testMachineLabels() {
        let m = { (s: String) in HcMachine(name: "box", host: nil, state: s, why: nil) }
        XCTAssertTrue(RemoteProject.machineLabel(m("connected"), isWindows: false) == ("box", true))
        XCTAssertTrue(RemoteProject.machineLabel(m("needs_login"), isWindows: false) == ("box (needs login)", false))
        XCTAssertTrue(RemoteProject.machineLabel(m("connected"), isWindows: true) == ("box (Windows not supported)", false))
        XCTAssertTrue(RemoteProject.machineLabel(m("unreachable"), isWindows: false) == ("box (unreachable)", false))
        XCTAssertTrue(RemoteProject.machineLabel(m("connecting"), isWindows: false) == ("box (connecting)", false))
    }

    func testStrings() {
        XCTAssertEqual(RemoteProject.loginHint(machine: "bdpc01"), "Run `hc machine login bdpc01` in a terminal, then try again.")
        XCTAssertEqual(RemoteProject.folderNotFound(machine: "bdpc01"), "Folder not found on bdpc01.")
    }

    /// `uname`이 0이 아니거나 호출이 실패하면 Windows로 본다. 기억은 머신이 확실히 답한 것만 한다: 연결이 잠깐
    /// 끊겨 실패했거나 느린 머신에서 시간이 다 된 것까지 기억하면 그 머신은 앱을 다시 켤 때까지 만들 수 없다.
    func testWindowsVerdict() {
        let ran = { (code: Int32?, timedOut: Bool) in RemoteProject.windowsVerdict(.success(HcExecResult(code: code, timedOut: timedOut))) }
        XCTAssertTrue(ran(0, false) == (false, true))
        XCTAssertTrue(ran(1, false) == (true, true))
        XCTAssertTrue(ran(127, false) == (true, true))
        XCTAssertTrue(ran(nil, true) == (true, false), "uname ran out of time: a slow line, not an answer")
        XCTAssertTrue(ran(0, true) == (true, false), "a timed-out run's code is not uname's answer")
        XCTAssertTrue(ran(nil, false) == (true, false), "ended by a signal: no answer")
        XCTAssertTrue(RemoteProject.windowsVerdict(.failure(HcError.rpc(kind: "spawn_failed", message: "no uname"))) == (true, true))
        XCTAssertTrue(RemoteProject.windowsVerdict(.failure(HcError.rpc(kind: "unavailable", message: "line down"))) == (true, false))
        XCTAssertTrue(RemoteProject.windowsVerdict(.failure(HcError.disconnected)) == (true, false))
    }

    /// hc 0.1.16 `machine.exec` 결과(ExecResult). timeout은 오류가 아니라 `timed_out: true`와 null code로 온다.
    func testExecResultDecodes() throws {
        let done = try JSONDecoder().decode(HcExecResult.self, from: Data(
            #"{"code":0,"ms":3,"signal":null,"stderr":"","stdout":"TGludXgK","timed_out":false,"truncated":false}"#.utf8))
        XCTAssertEqual(done, HcExecResult(code: 0, timedOut: false))
        XCTAssertEqual(done.exitCode, 0)
        let timedOut = try JSONDecoder().decode(HcExecResult.self, from: Data(
            #"{"code":null,"ms":5001,"signal":9,"stderr":"","stdout":"","timed_out":true,"truncated":false}"#.utf8))
        XCTAssertEqual(timedOut, HcExecResult(code: nil, timedOut: true))
        XCTAssertNil(timedOut.exitCode, "a timed-out folder check must not read as \"exists\"")
        XCTAssertNil(HcExecResult(code: 0, timedOut: true).exitCode)
    }

    // MARK: - 시트

    private func makeSheet(onCreate: @escaping (WorkspaceRecord) -> Void = { _ in }) -> RemoteProjectSheet {
        let manager = HcSessionManager(endpointProvider: { nil })
        let sheet = RemoteProjectSheet(manager: manager, onCreate: onCreate)
        Self.retiredSheets.append(sheet)   // 패널을 풀지 않는다(테스트 host의 창 수를 건드리지 않게)
        return sheet
    }

    func testSheetStrings() {
        let sheet = makeSheet()
        XCTAssertEqual(sheet.panel.title, "New Remote Project")
        XCTAssertEqual(sheet.titleLabel.stringValue, "New Remote Project")
        XCTAssertEqual(sheet.machineLabel.stringValue, "Machine")
        XCTAssertEqual(sheet.folderLabel.stringValue, "Folder")
        XCTAssertEqual(sheet.createButton.title, "Create")
        XCTAssertEqual(sheet.cancelButton.title, "Cancel")
    }

    func testSheetListsMachinesWithTheirState() {
        let sheet = makeSheet()
        sheet.show(machines: [
            HcMachine(name: "win", host: nil, state: "connected", why: nil),
            HcMachine(name: "bdpc01", host: nil, state: "connected", why: nil),
            HcMachine(name: "laptop", host: nil, state: "needs_login", why: "no key"),
            HcMachine(name: "far", host: nil, state: "unreachable", why: nil),
        ], windows: ["win"])

        XCTAssertEqual(sheet.machinePopup.itemTitles,
                       ["win (Windows not supported)", "bdpc01", "laptop (needs login)", "far (unreachable)"])
        XCTAssertEqual(sheet.machinePopup.itemArray.map(\.isEnabled), [false, true, true, false],
                       "a needs-login machine stays selectable so its login hint can show")
        XCTAssertEqual(sheet.machinePopup.titleOfSelectedItem, "bdpc01", "the first usable machine is selected")
        XCTAssertEqual(sheet.messageLabel.stringValue, "")

        XCTAssertFalse(sheet.createButton.isEnabled, "no folder yet")
        sheet.folderField.stringValue = "/srv/app"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.folderField))
        XCTAssertTrue(sheet.createButton.isEnabled)

        sheet.machinePopup.selectItem(at: 2)
        sheet.machinePopup.sendAction(sheet.machinePopup.action, to: sheet.machinePopup.target)
        XCTAssertEqual(sheet.messageLabel.stringValue, "Run `hc machine login laptop` in a terminal, then try again.")
        XCTAssertFalse(sheet.createButton.isEnabled, "a machine that needs login can't host a new project")

        sheet.machinePopup.selectItem(at: 1)
        sheet.machinePopup.sendAction(sheet.machinePopup.action, to: sheet.machinePopup.target)
        XCTAssertEqual(sheet.messageLabel.stringValue, "")
        XCTAssertTrue(sheet.createButton.isEnabled)
    }

    func testSheetSelectsANeedsLoginMachineWhenNoneIsUsable() {
        let sheet = makeSheet()
        sheet.show(machines: [
            HcMachine(name: "far", host: nil, state: "unreachable", why: nil),
            HcMachine(name: "laptop", host: nil, state: "needs_login", why: nil),
        ], windows: [])
        XCTAssertEqual(sheet.machinePopup.titleOfSelectedItem, "laptop (needs login)")
        XCTAssertEqual(sheet.messageLabel.stringValue, "Run `hc machine login laptop` in a terminal, then try again.")
        XCTAssertFalse(sheet.createButton.isEnabled)
    }

    // MARK: - 새 pane이 원격 pane을 따른다

    func testNewPaneFollowsFocusedRemotePane() {
        let r = Workspace.launchForNewPane(focused: (.hc(machine: "bdpc01"), "/srv/app/sub", "app@bdpc01", "bdpc01:/srv/app"), defaults: InMemoryUserDefaults(), hcAllowsNewPanes: true)
        XCTAssertEqual(r.launch, .hc(machine: "bdpc01")); XCTAssertEqual(r.cwd, "/srv/app/sub"); XCTAssertEqual(r.projectKey, "bdpc01:/srv/app")
        XCTAssertEqual(r.projectId, "app@bdpc01")
    }

    /// local(또는 로컬 hc) pane에 포커스가 있거나 pane이 없으면 지금 규칙: 설정이 backend를 정하고 cwd·project는
    /// addPane이 포커스된 pane과 cwd로 정한다.
    func testNewPaneWithoutRemoteFocusFollowsTheSetting() {
        let off = InMemoryUserDefaults()
        let local = Workspace.launchForNewPane(focused: (.local, "/p/api", "api", "/p/api"), defaults: off, hcAllowsNewPanes: true)
        XCTAssertEqual(local.launch, .local)
        XCTAssertNil(local.cwd); XCTAssertNil(local.projectId); XCTAssertNil(local.projectKey)

        let on = InMemoryUserDefaults()
        HcFeatureSettings.setLocalPanesEnabled(true, on)
        let localHc = Workspace.launchForNewPane(focused: (.hc(machine: nil), "/p/api", "api", "/p/api"), defaults: on, hcAllowsNewPanes: true)
        XCTAssertEqual(localHc.launch, .hc(machine: nil))
        XCTAssertNil(localHc.cwd); XCTAssertNil(localHc.projectId); XCTAssertNil(localHc.projectKey)

        let none = Workspace.launchForNewPane(focused: nil, defaults: on, hcAllowsNewPanes: true)
        XCTAssertEqual(none.launch, .hc(machine: nil))
        XCTAssertNil(none.cwd)
    }

    /// R21. hc를 쓸 수 없는 것이 확실하면 로컬 쪽 새 pane(⌘N·split·새 창의 첫 pane)은 local이다. 원격 pane 옆의
    /// 새 pane은 그 머신의 pane으로 남는다(local로 바꾸면 원격 project 안에 이 Mac의 셸이 생긴다).
    func testNewPaneIsLocalWhenHcIsKnownUnusable() {
        let on = InMemoryUserDefaults()
        HcFeatureSettings.setLocalPanesEnabled(true, on)
        XCTAssertEqual(Workspace.launchForNewPane(focused: nil, defaults: on, hcAllowsNewPanes: false).launch, .local)
        XCTAssertEqual(Workspace.launchForNewPane(focused: (.hc(machine: nil), "/p/api", "api", "/p/api"), defaults: on,
                                                  hcAllowsNewPanes: false).launch, .local)
        let remote = Workspace.launchForNewPane(focused: (.hc(machine: "bdpc01"), "/srv/app", "app@bdpc01", "bdpc01:/srv/app"),
                                                defaults: on, hcAllowsNewPanes: false)
        XCTAssertEqual(remote.launch, .hc(machine: "bdpc01"))
    }

    // MARK: - ⌘K로 다시 열기

    func testReopenedRemoteRecordMakesHcPanesOfItsMachine() {
        var record = RemoteProject.record(machine: "bdpc01", folder: "/srv/app", now: Date())
        // 예전 형식이나 손으로 고친 파일처럼 pane에 원격 필드가 없어도 기록의 머신·project를 단다.
        record.panes = [PaneRecord(cwd: "/srv/app/sub")]
        let pane = RemoteProject.reopenedPane(record.panes[0], in: record)
        XCTAssertEqual(pane.launch, .hc(machine: "bdpc01"))
        XCTAssertEqual(PaneLaunch.forReopenedRecord(pane, defaults: InMemoryUserDefaults(), hcAllowsNewPanes: true), .hc(machine: "bdpc01"))
        XCTAssertEqual(pane.cwd, "/srv/app/sub")
        XCTAssertEqual(pane.machine, "bdpc01")
        XCTAssertEqual(pane.projectId, "app@bdpc01")
        XCTAssertEqual(pane.projectKey, "bdpc01:/srv/app")
    }

    func testReopenedLocalRecordKeepsItsPanes() {
        let record = WorkspaceRecord(canonicalPath: "/p/api", displayLabel: "api", panes: [PaneRecord(cwd: "/p/api/docs")])
        XCTAssertEqual(RemoteProject.reopenedPane(record.panes[0], in: record), PaneRecord(cwd: "/p/api/docs"))
    }

    // MARK: - ⌘K 기록 저장(R17)

    private typealias Info = WorkspaceAutosaver.PaneInfo

    func testAutosaveGroupsLocalPanesByWorktreeAsBefore() {
        let records = WorkspaceAutosaver.records(layouts: [PaneLayoutNode<Info>.fromColumns([[
            .init(cwd: "/p/api", key: "/p/api", label: "api", machine: nil),
            .init(cwd: "/p/api/docs", key: "/p/api", label: "api", machine: nil),
            .init(cwd: "/p/web", key: "/p/web", label: "web", machine: nil),
        ]])!], now: Date(timeIntervalSince1970: 5))
        let byKey = Dictionary(uniqueKeysWithValues: records.map { ($0.canonicalPath, $0) })
        XCTAssertEqual(Set(byKey.keys), ["/p/api", "/p/web"])
        let api = [PaneRecord(cwd: "/p/api"), PaneRecord(cwd: "/p/api/docs")]
        XCTAssertEqual(byKey["/p/api"], WorkspaceRecord(
            canonicalPath: "/p/api", displayLabel: "api", updatedAt: Date(timeIntervalSince1970: 5),
            panes: api, rows: [api], layout: PaneLayoutNode.fromColumns([api])))
        XCTAssertNil(byKey["/p/web"]?.machine)
    }

    /// 원격 pane의 cwd(`/srv/app`)를 이 Mac의 경로로 묶으면 로컬로 다시 열리는 가짜 project가 생긴다. 원격 pane은
    /// project 키로 묶어 원격 기록으로 남긴다.
    func testAutosaveSavesRemotePanesAsARemoteRecord() {
        let remote = { (cwd: String) in
            Info(cwd: cwd, key: "bdpc01:/srv/app", label: "app@bdpc01", machine: "bdpc01")
        }
        let records = WorkspaceAutosaver.records(layouts: [
            PaneLayoutNode<Info>.fromColumns([[remote("/srv/app")], [remote("/srv/app/sub")]])!,
            PaneLayoutNode<Info>.fromColumns([[.init(cwd: "/p/api", key: "/p/api", label: "api", machine: nil)]])!,
        ], now: Date(timeIntervalSince1970: 5))
        let byKey = Dictionary(uniqueKeysWithValues: records.map { ($0.canonicalPath, $0) })
        XCTAssertEqual(Set(byKey.keys), ["bdpc01:/srv/app", "/p/api"], "no local /srv/app record")

        let record = byKey["bdpc01:/srv/app"]
        XCTAssertEqual(record?.machine, "bdpc01")
        XCTAssertEqual(record?.displayLabel, "app@bdpc01")
        let pane = { (cwd: String) in
            PaneRecord(cwd: cwd, backend: .hc, machine: "bdpc01", projectId: "app@bdpc01", projectKey: "bdpc01:/srv/app")
        }
        XCTAssertEqual(record?.rows, [[pane("/srv/app")], [pane("/srv/app/sub")]])
        XCTAssertEqual(record?.layout, PaneLayoutNode.fromColumns([[pane("/srv/app")], [pane("/srv/app/sub")]]))
        XCTAssertEqual(record?.panes, [pane("/srv/app"), pane("/srv/app/sub")])
        XCTAssertNil(record?.panes.first?.paneId, "⌘K records don't keep pane ids (R15)")

        XCTAssertEqual(byKey["/p/api"]?.panes, [PaneRecord(cwd: "/p/api")])
        XCTAssertNil(byKey["/p/api"]?.machine)
    }

    /// 한 키의 pane이 project tree 여럿에 있으면(드문 경우) 그 tree들을 좌우로 균등하게 묶는다.
    func testAutosaveJoinsOneKeyFromSeveralProjectTrees() {
        let api = { (cwd: String) in Info(cwd: cwd, key: "/p/api", label: "api", machine: nil) }
        let records = WorkspaceAutosaver.records(layouts: [
            PaneLayoutNode<Info>.fromColumns([[api("/p/api"), api("/p/api/docs")]])!,
            .leaf(api("/p/api/src")),
        ], now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(records.map(\.canonicalPath), ["/p/api"])
        let columns = [[PaneRecord(cwd: "/p/api"), PaneRecord(cwd: "/p/api/docs")], [PaneRecord(cwd: "/p/api/src")]]
        XCTAssertEqual(records.first?.layout, PaneLayoutNode.fromColumns(columns))
        XCTAssertEqual(records.first?.rows, columns)
        XCTAssertEqual(records.first?.panes, columns.flatMap { $0 })
    }

    // MARK: - 머신이 끊긴 채 닫은 원격 pane(R18)

    func testRemoteKillRejectedFallsBackToKillOnArrival() {
        let rejected = HcKillResult.rejected(kind: "unavailable")
        XCTAssertEqual(HcSessionManager.killFollowUp(address: "bdpc01/t3", paneId: "P1", result: rejected),
                       .killOnArrival(paneId: "P1"))
        XCTAssertEqual(HcSessionManager.killFollowUp(address: "bdpc01/t3", paneId: "P1", result: .rejected(kind: "not_found")),
                       .killOnArrival(paneId: "P1"), "a machine that is down may not know its terminals yet")
        XCTAssertEqual(HcSessionManager.killFollowUp(address: "bdpc01/t3", paneId: nil, result: rejected), .done)
        XCTAssertEqual(HcSessionManager.killFollowUp(address: "t3", paneId: "P1", result: .rejected(kind: "not_found")), .done,
                       "a local terminal the core doesn't know is gone")
        XCTAssertEqual(HcSessionManager.killFollowUp(address: "bdpc01/t3", paneId: "P1", result: .killed), .done)
        XCTAssertEqual(HcSessionManager.killFollowUp(address: "bdpc01/t3", paneId: "P1", result: .connectionLost), .retry)
        XCTAssertEqual(HcSessionManager.killFollowUp(address: "t3", paneId: "P1", result: .connectionLost), .retry)
    }

    // MARK: - hc가 빈 배열을 빼먹은 결과

    /// hc 0.1.16은 schema가 필수라고 적은 빈 배열도 결과에서 뺀다(머신이 없으면 `machines`).
    func testEmptyArraysMayBeMissing() throws {
        let lookup = try JSONDecoder().decode(HcPaneLookup.self, from: Data(#"{"hidden_finished":0}"#.utf8))
        XCTAssertEqual(lookup.terminals, [])
        XCTAssertNil(lookup.machines)
        let list = try JSONDecoder().decode(HcMachineList.self, from: Data("{}".utf8))
        XCTAssertEqual(list.machines, [])
        let full = try JSONDecoder().decode(HcMachineList.self, from: Data(
            #"{"machines":[{"name":"bdpc01","host":"bdpc01","state":"connected","why":null}]}"#.utf8))
        XCTAssertEqual(full.machines, [HcMachine(name: "bdpc01", host: "bdpc01", state: "connected", why: nil)])
    }
}

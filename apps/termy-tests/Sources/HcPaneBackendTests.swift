import XCTest
import AppKit
@testable import termy

// HcPaneBackend/HcSessionManager의 순수 부분: terminal.run 인자, CLOSE 해석, instance label,
// 그리고 scratch core에서 받은 실제 terminal 레코드가 HcTerminal로 풀리는지.

@MainActor
final class HcPaneBackendTests: XCTestCase {
    func testLocalRunParams() {
        let p = HcPaneBackend.runParams(paneId: "P1", projectKey: "/Users/u/app", projectId: "app",
            launch: HcLaunch(machine: nil, cwd: "/Users/u/app", shell: "/bin/zsh"),
            instance: "release", baseEnvironment: [:])
        XCTAssertEqual(p.argv?.first, "/bin/sh"); XCTAssertEqual(p.argv?.last, "/bin/zsh")
        XCTAssertTrue(p.argv![2].contains("unset CLAUDECODE"))
        XCTAssertTrue(p.argv![2].contains(#"[ "${GIT_EDITOR-}" = true ] && unset GIT_EDITOR"#))
        XCTAssertTrue(p.argv![2].hasSuffix(#"exec "$1" -l"#))
        XCTAssertEqual(p.env["TERMY_PANE_ID"], "P1"); XCTAssertEqual(p.env["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(p.labels, ["termy.pane=P1", "termy.project=/Users/u/app", "termy.instance=release"])
        XCTAssertTrue(p.keep && p.no_parent && p.no_notify); XCTAssertNil(p.on)
    }

    func testLocalRunParamsDetails() {
        let p = HcPaneBackend.runParams(paneId: "P1", projectKey: "/Users/u/app", projectId: "app",
            launch: HcLaunch(machine: nil, cwd: "/Users/u/app", shell: "/bin/zsh"),
            instance: "release", baseEnvironment: ["LC_ALL": "ko_KR.UTF-8"])
        XCTAssertEqual(Array(p.argv![0...1]), ["/bin/sh", "-c"])
        XCTAssertEqual(p.argv![3], "termy-shell")
        let script = p.argv![2]
        for key in Pane.agentSessionMarkerEnvKeys { XCTAssertTrue(script.contains(" \(key)"), key) }
        XCTAssertTrue(script.hasPrefix("unset "))
        XCTAssertEqual(p.cwd, "/Users/u/app")
        XCTAssertEqual(p.env["LC_ALL"], "ko_KR.UTF-8")
        XCTAssertEqual(p.env["TERMY_PROJECT_ID"], "app")
        XCTAssertEqual(p.env["TERM"], "xterm-256color")
        XCTAssertEqual(p.env["COLORTERM"], "truecolor")
        XCTAssertEqual(p.env["TERM_PROGRAM"], "termy")
        XCTAssertEqual(HcPaneBackend.termProgram, "termy")
    }

    func testRemoteRunParams() {
        let p = HcPaneBackend.runParams(paneId: "P2", projectKey: "bdpc01:/srv/app", projectId: "app@bdpc01",
            launch: HcLaunch(machine: "bdpc01", cwd: "/srv/app", shell: "/bin/zsh"), instance: "debug", baseEnvironment: [:])
        XCTAssertNil(p.argv); XCTAssertEqual(p.on, "bdpc01"); XCTAssertNil(p.env["LC_ALL"])
        XCTAssertEqual(p.cwd, "/srv/app")
        XCTAssertEqual(p.env["TERMY_PANE_ID"], "P2")
        XCTAssertEqual(p.labels, ["termy.pane=P2", "termy.project=bdpc01:/srv/app", "termy.instance=debug"])
    }

    /// hc의 `labels`는 `{key: value}` 객체이고 argv/on은 없으면 보내지 않는다(argv 없이 = 그 머신의 셸).
    func testRunParamsWireShape() throws {
        let p = HcPaneBackend.runParams(paneId: "P2", projectKey: "bdpc01:/srv/app", projectId: "app@bdpc01",
            launch: HcLaunch(machine: "bdpc01", cwd: "/srv/app", shell: "/bin/zsh"), instance: "debug", baseEnvironment: [:])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        XCTAssertNil(obj["argv"])
        XCTAssertEqual(obj["on"] as? String, "bdpc01")
        XCTAssertEqual(obj["labels"] as? [String: String],
                       ["termy.pane": "P2", "termy.project": "bdpc01:/srv/app", "termy.instance": "debug"])
        XCTAssertEqual(obj["keep"] as? Bool, true)
        XCTAssertEqual(obj["no_parent"] as? Bool, true)
        XCTAssertEqual(obj["no_notify"] as? Bool, true)

        let local = HcPaneBackend.runParams(paneId: "P1", projectKey: "/a=b", projectId: "a",
            launch: HcLaunch(machine: nil, cwd: "/a", shell: "/bin/zsh"), instance: "t", baseEnvironment: [:])
        let lobj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(local)) as? [String: Any])
        XCTAssertNil(lobj["on"])
        XCTAssertEqual((lobj["argv"] as? [String])?.count, 5)
        // 값에 `=`가 있어도 첫 `=`에서만 나눈다.
        XCTAssertEqual((lobj["labels"] as? [String: String])?["termy.project"], "/a=b")
    }

    func testCloseOutcome() {
        XCTAssertEqual(HcPaneBackend.closeOutcome(json: Data(#"{"reason":"exited","exit_code":0,"signal":null}"#.utf8)), .exited(0))
        XCTAssertEqual(HcPaneBackend.closeOutcome(json: Data(#"{"reason":"killed","exit_code":null,"signal":15}"#.utf8)), .exited(-1))
        XCTAssertEqual(HcPaneBackend.closeOutcome(json: Data(#"{"reason":"server_stop"}"#.utf8)), .unavailable("server_stop"))
    }

    func testCloseOutcomeOtherReasons() {
        XCTAssertEqual(HcPaneBackend.closeOutcome(json: Data(#"{"exit_code":129,"finished_ms":1,"reason":"killed","signal":null}"#.utf8)), .exited(129))
        for reason in ["holder_lost", "host_shutdown", "stopped_by_restart", "signaled"] {
            XCTAssertEqual(HcPaneBackend.closeOutcome(json: Data(#"{"reason":"\#(reason)","exit_code":null}"#.utf8)), .unavailable(reason))
        }
        XCTAssertEqual(HcPaneBackend.closeOutcome(json: nil), .unavailable("closed"))
        XCTAssertEqual(HcPaneBackend.closeOutcome(json: Data("not json".utf8)), .unavailable("closed"))
    }

    func testInstanceLabelHonorsOverride() {
        let saved = getenv("TERMY_INSTANCE").map { String(cString: $0) }
        defer {
            if let saved { setenv("TERMY_INSTANCE", saved, 1) } else { unsetenv("TERMY_INSTANCE") }
        }
        setenv("TERMY_INSTANCE", "t", 1)
        XCTAssertEqual(HcSessionManager.instanceLabel, "t")
        unsetenv("TERMY_INSTANCE")
        #if DEBUG
        XCTAssertEqual(HcSessionManager.instanceLabel, "debug")
        #else
        XCTAssertEqual(HcSessionManager.instanceLabel, "release")
        #endif
    }

    func testReconnectDelays() {
        XCTAssertEqual((0..<8).map(HcSessionManager.reconnectDelay(attempt:)), [0.5, 1, 2, 4, 8, 15, 15, 15])
    }

    func testDisplayHex() {
        XCTAssertEqual(HcPaneBackend.hex(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)), "#ff8000")
        XCTAssertEqual(HcPaneBackend.hex(NSColor(white: 0, alpha: 1)), "#000000")
    }

    func testMachineDecodes() throws {
        let json = #"{"machines":[{"name":"bdpc01","target":"yeonsh@bdpc01","id":"x","host":"bdpc01","version":"0.1.16","state":"needs_login","why":"no key","since_ms":1}]}"#
        struct Box: Decodable { let machines: [HcMachine] }
        let box = try JSONDecoder().decode(Box.self, from: Data(json.utf8))
        XCTAssertEqual(box.machines, [HcMachine(name: "bdpc01", host: "bdpc01", state: "needs_login", why: "no key")])
    }

    /// scratch core(hc 0.1.16)의 `terminal.list` 결과를 그대로 옮긴 것. 키 이름이 바뀌면 여기서 걸린다.
    func testTerminalRecordDecodesRealSnapshot() throws {
        let live = #"{"address": "t1", "argv": ["/bin/sh", "-c", "read line; exit 0"], "cols": 200, "created_ms": 1793529582753, "cwd": "/tmp", "die_with_parent": false, "exit_code": null, "finished_ms": null, "foreground": {"argv": ["/bin/sh", "-c", "read line; exit 0"], "cwd": "/private/tmp", "name": "bash", "pid": 3293}, "identity": "termy", "keep": true, "labels": {"termy.instance": "probe", "termy.pane": "P1"}, "name": null, "notify": false, "parent": null, "pid": 3293, "reason": null, "reported": false, "rm": false, "rows": 120, "screen": "exact", "signal": null, "state": "live", "status": null, "status_ms": null, "template": null, "title": "", "turn": 0}"#
        let t = try JSONDecoder().decode(HcTerminal.self, from: Data(live.utf8))
        XCTAssertEqual(t, HcTerminal(address: "t1", state: "live", labels: ["termy.instance": "probe", "termy.pane": "P1"],
                                     cwd: "/tmp", exitCode: nil, reason: nil, status: nil,
                                     foreground: HcForeground(pid: 3293, name: "bash", argv: ["/bin/sh", "-c", "read line; exit 0"], cwd: "/private/tmp"),
                                     cols: 200, rows: 120, title: ""))

        let finished = #"{"address": "t2", "argv": ["/bin/sh", "-c", "exit 4"], "cols": 200, "created_ms": 1793529585806, "cwd": "/private/tmp", "die_with_parent": false, "exit_code": 4, "finished_ms": 1793529585844, "identity": "ghostty", "keep": true, "labels": {"termy.instance": "probe", "termy.pane": "P2"}, "name": null, "notify": false, "parent": null, "pid": 3303, "reason": "exited", "reported": false, "rm": false, "rows": 120, "screen": "exact", "signal": null, "state": "finished", "status": null, "status_ms": null, "template": null, "title": "", "turn": 0}"#
        let f = try JSONDecoder().decode(HcTerminal.self, from: Data(finished.utf8))
        XCTAssertEqual(f.state, "finished"); XCTAssertEqual(f.exitCode, 4); XCTAssertEqual(f.reason, "exited")
        XCTAssertNil(f.foreground)

        // status는 spike에서 본 7501 레코드 모양(`progress`/`title`처럼 termy가 쓰지 않는 키가 붙어도 된다).
        let withStatus = live.replacingOccurrences(of: #""status": null"#,
            with: #""status": {"app":"claude-code","kind":"permission","msg":"approve Bash: ls","state":"blocked","progress":null}"#)
        XCTAssertEqual(try JSONDecoder().decode(HcTerminal.self, from: Data(withStatus.utf8)).status,
                       HcStatus(state: "blocked", kind: "permission", msg: "approve Bash: ls", app: "claude-code"))
    }
}

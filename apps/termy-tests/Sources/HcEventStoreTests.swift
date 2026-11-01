import XCTest
@testable import termy

final class HcEventStoreTests: XCTestCase {
    private func term(_ addr: String, labels: [String: String] = [:], state: String = "live") -> HcTerminal {
        HcTerminal(address: addr, state: state, labels: labels, cwd: nil, exitCode: nil, reason: nil,
                   status: nil, foreground: nil, cols: 80, rows: 24, title: nil)
    }

    private func event(_ json: String) throws -> HcEvent {
        let raw = #"{"jsonrpc":"2.0","method":"event","params":\#(json)}"#
        return try HcEvent.decode(notification: Data(raw.utf8))
    }

    func testStaleSeqIgnored() throws {
        var s = HcEventStore(seq: 10, terminals: [term("t7")])
        let c = s.apply(try event(#"{"seq":10,"type":"title","terminal":"t7","data":{"title":"x"}}"#))
        XCTAssertNil(c)
        XCTAssertNil(s.terminals["t7"]?.title)
        XCTAssertEqual(s.seq, 10)
    }

    func testTitleAndSizeStored() throws {
        var s = HcEventStore(seq: 1, terminals: [term("t7")])
        XCTAssertNil(s.apply(try event(#"{"seq":2,"type":"title","terminal":"t7","data":{"title":"vim"}}"#)))
        XCTAssertNil(s.apply(try event(#"{"seq":3,"type":"size","terminal":"t7","data":{"cols":100,"rows":30}}"#)))
        XCTAssertEqual(s.terminals["t7"]?.title, "vim")
        XCTAssertEqual(s.terminals["t7"]?.cols, 100)
        XCTAssertEqual(s.seq, 3)
    }

    func testStatusEventReplacesStatus() throws {
        var s = HcEventStore(seq: 10, terminals: [term("t7")])
        let c = s.apply(try event(#"{"seq":11,"type":"status","terminal":"t7","data":{"status":{"state":"working","app":"claude-code"},"records":{},"reported":true}}"#))
        let want = HcStatus(state: "working", kind: nil, msg: nil, app: "claude-code")
        XCTAssertEqual(c, .status("t7", want))
        XCTAssertEqual(s.terminals["t7"]?.status, want)
        _ = s.apply(try event(#"{"seq":12,"type":"status","terminal":"t7","data":{"status":null,"records":{},"reported":true}}"#))
        XCTAssertNil(s.terminals["t7"]?.status)
    }

    func testFinishedDropsForegroundAndSetsState() throws {
        var t = term("t7")
        t.foreground = HcForeground(pid: 1, name: "sh", argv: ["sh"], cwd: "/")
        var s = HcEventStore(seq: 1, terminals: [t])
        let c = s.apply(try event(#"{"seq":2,"type":"finished","terminal":"t7","data":{"reason":"exited","exit_code":0,"signal":null,"finished_ms":5}}"#))
        XCTAssertEqual(c, .finished("t7", exitCode: 0, reason: "exited"))
        XCTAssertEqual(s.terminals["t7"]?.state, "finished")
        XCTAssertNil(s.terminals["t7"]?.foreground)
        XCTAssertEqual(s.terminals["t7"]?.exitCode, 0)
    }

    func testLostKeepsLiveAndDropsForeground() throws {
        var t = term("t7")
        t.foreground = HcForeground(pid: 1, name: "sh", argv: nil, cwd: nil)
        var s = HcEventStore(seq: 1, terminals: [t])
        let c = s.apply(try event(#"{"seq":2,"type":"lost","terminal":"t7","data":{"reason":"signaled","exit_code":null,"signal":9,"finished_ms":null}}"#))
        XCTAssertEqual(c, .lost("t7", reason: "signaled"))
        XCTAssertEqual(s.terminals["t7"]?.state, "live")
        XCTAssertNil(s.terminals["t7"]?.foreground)
    }

    func testRestartedReplacesRecord() throws {
        var s = HcEventStore(seq: 1, terminals: [term("t7", state: "live")])
        let c = s.apply(try event(#"{"seq":2,"type":"restarted","terminal":"t7","data":{"address":"t7","state":"live","labels":{"termy.pane":"p1"},"cwd":"/tmp","cols":90,"rows":20}}"#))
        guard case .restarted(let t)? = c else { return XCTFail("\(String(describing: c))") }
        XCTAssertEqual(t.labels["termy.pane"], "p1")
        XCTAssertEqual(s.terminals["t7"]?.cols, 90)
    }

    func testLabelsWithRecordAddsTerminal() throws {
        var s = HcEventStore(seq: 1, terminals: [])
        let c = s.apply(try event(#"{"seq":2,"type":"labels","terminal":"t9","data":{"labels":{"termy.pane":"p"},"record":{"address":"t9","state":"live","labels":{"termy.pane":"p"}}}}"#))
        guard case .upserted(let t)? = c else { return XCTFail("\(String(describing: c))") }
        XCTAssertEqual(t.address, "t9")
        XCTAssertEqual(s.terminals["t9"]?.labels, ["termy.pane": "p"])
    }

    func testCreatedAddsAndRemovedDrops() throws {
        var s = HcEventStore(seq: 1, terminals: [])
        XCTAssertNotNil(s.apply(try event(#"{"seq":2,"type":"created","terminal":"t1","data":{"address":"t1","state":"live"}}"#)))
        XCTAssertEqual(s.terminals["t1"]?.labels, [:])
        XCTAssertEqual(s.apply(try event(#"{"seq":3,"type":"removed","terminal":"t1","data":{}}"#)), .removed("t1"))
        XCTAssertNil(s.terminals["t1"])
    }

    func testForegroundNullClears() throws {
        var t = term("t7")
        t.foreground = HcForeground(pid: 1, name: "sh", argv: nil, cwd: nil)
        var s = HcEventStore(seq: 1, terminals: [t])
        let c = s.apply(try event(#"{"seq":2,"type":"foreground","terminal":"t7","data":null}"#))
        XCTAssertEqual(c, .foreground("t7", nil))
        XCTAssertNil(s.terminals["t7"]?.foreground)
        let c2 = s.apply(try event(#"{"seq":3,"type":"foreground","terminal":"t7","data":{"pid":42,"name":"node","argv":["node"],"cwd":"/w"}}"#))
        XCTAssertEqual(c2, .foreground("t7", HcForeground(pid: 42, name: "node", argv: ["node"], cwd: "/w")))
    }

    func testMissedResets() throws {
        var s = HcEventStore(seq: 10, terminals: [term("t1")])
        s.resetFromMissed(seq: 57, terminals: [term("t2")])
        XCTAssertNil(s.apply(try event(#"{"seq":50,"type":"removed","terminal":"t2","data":{}}"#)))
        XCTAssertNotNil(s.terminals["t2"])
        XCTAssertNil(s.terminals["t1"])
        XCTAssertEqual(s.seq, 57)
    }

    func testRemoteAddressMachine() {
        XCTAssertEqual(HcAddress.machine(of: "bdpc01/t3"), "bdpc01")
        XCTAssertNil(HcAddress.machine(of: "t3"))
    }

    func testTermyTerminalsFiltersByInstance() {
        let a = term("t1", labels: ["termy.instance": "release", "termy.pane": "p1"])
        let b = term("t2", labels: ["termy.instance": "debug", "termy.pane": "p2"])
        let c = term("t3", labels: ["termy.instance": "release"])
        let d = term("t4", labels: ["termy.instance": "release", "termy.pane": "p4"], state: "finished")
        let s = HcEventStore(seq: 1, terminals: [a, b, c, d])
        XCTAssertEqual(s.termyTerminals(instance: "release").map(\.address), ["t1"])
    }

    func testTerminalDecodesSnakeCaseRecord() throws {
        let json = #"{"address":"t7","state":"finished","exit_code":3,"reason":"exited","cwd":"/x","cols":80,"rows":24,"status":{"app":"claude-code","kind":"permission","msg":"approve","state":"blocked"},"foreground":null}"#
        let t = try JSONDecoder().decode(HcTerminal.self, from: Data(json.utf8))
        XCTAssertEqual(t.exitCode, 3)
        XCTAssertEqual(t.labels, [:])
        XCTAssertEqual(t.status?.kind, "permission")
    }
}

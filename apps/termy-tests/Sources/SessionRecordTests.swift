import XCTest
@testable import termy

final class SessionRecordTests: XCTestCase {
    func test_sessionRecord_roundTripsThroughJSON() throws {
        let record = SessionRecord(windows: [
            WindowRecord(
                frame: FrameRecord(x: 10, y: 20, width: 1200, height: 760),
                rows: [
                    [PaneRecord(cwd: "/a"), PaneRecord(cwd: "/b")],
                    [PaneRecord(cwd: "/c")]
                ],
                filterProjectId: "proj",
                focusedPaneIndex: 2
            )
        ])
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func test_sessionRecord_defaultSchemaVersionIsCurrent() {
        let record = SessionRecord(windows: [])
        XCTAssertEqual(record.schemaVersion, SessionRecord.currentSchemaVersion)
    }

    func test_frameRecord_convertsToAndFromCGRect() {
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertEqual(FrameRecord(rect).cgRect, rect)
    }

    func test_paneRecord_withAgentResume_roundTrips() throws {
        let pane = PaneRecord(
            cwd: "/a",
            agentResume: AgentResumeRecord(
                kind: .codex,
                sessionId: "019a-session",
                cwd: "/a/sub",
                flags: ["-m", "gpt-5"]
            )
        )
        let data = try JSONEncoder().encode(pane)
        XCTAssertEqual(try JSONDecoder().decode(PaneRecord.self, from: data), pane)
    }

    func test_paneRecord_decodesLegacyJSONWithoutAgentResume() throws {
        let legacy = #"{"cwd": "/legacy"}"#
        let pane = try JSONDecoder().decode(PaneRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(pane.cwd, "/legacy")
        XCTAssertNil(pane.agentResume)
    }

    func test_paneRecord_withoutAgentResume_omitsKey() throws {
        let data = try JSONEncoder().encode(PaneRecord(cwd: "/a"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("agentResume"))
    }

    // MARK: - 분할 tree(layouts)

    private let frame = FrameRecord(x: 0, y: 0, width: 1200, height: 760)

    private func pane(_ cwd: String) -> PaneRecord { PaneRecord(cwd: cwd) }

    private func branch(_ node: PaneLayoutNode<PaneRecord>, _ weight: Double) -> PaneLayoutBranch<PaneRecord> {
        PaneLayoutBranch(node: node, weight: weight)
    }

    func test_windowRecord_layoutsRoundTrip() throws {
        // [A | B/C], 끌어 바꾼 비율 그대로.
        let root = PaneLayoutNode.split(.leftToRight, [
            branch(.leaf(pane("/a")), 0.3),
            branch(.split(.topToBottom, [branch(.leaf(pane("/b")), 0.6), branch(.leaf(pane("/c")), 0.4)]), 0.7),
        ])
        let record = WindowRecord(frame: frame, rows: [[pane("/a")], [pane("/b"), pane("/c")]],
                                  filterProjectId: "api", focusedPaneIndex: 2, projectOrder: ["api"],
                                  layouts: [ProjectLayoutRecord(projectId: "api", root: root)])
        let decoded = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.layoutTrees, [root])
    }

    func test_windowRecord_legacyJSONWithoutLayouts_buildsTreeFromRows() throws {
        // PaneRecordHcTests.testOldSessionFileDecodesWithLocalPanes의 예전 session.json.
        let legacy = #"""
        {"schemaVersion":1,"windows":[{"frame":{"x":0,"y":0,"width":1200,"height":760},
          "rows":[[{"cwd":"/a"},{"cwd":"/b","agentResume":{"kind":"claude","sessionId":"s1","flags":[]}}],[{"cwd":"/c"}]],
          "focusedPaneIndex":1}]}
        """#
        let window = try XCTUnwrap(JSONDecoder().decode(SessionRecord.self, from: Data(legacy.utf8)).windows.first)
        XCTAssertNil(window.layouts)
        XCTAssertEqual(window.layoutTrees.count, 1)
        XCTAssertEqual(window.layoutTrees[0].leaves.map(\.cwd), ["/a", "/b", "/c"])
        XCTAssertEqual(window.layoutTrees[0].map(\.cwd), PaneLayoutNode.fromColumns([["/a", "/b"], ["/c"]]))
        XCTAssertEqual(window.layoutTrees[0].leaves[1].agentResume?.sessionId, "s1")
    }

    /// 예전 빌드(Debug·release가 session.json을 함께 쓴다)는 `rows`만 읽는다. 펼친 순서가 잎 순서와 같아야 pane도
    /// 포커스도 잃지 않는다.
    func test_windowRecord_rowsFlattenInLayoutReadingOrder() throws {
        // api: row(A, col(B, C)), web: col(row(D, E), F) — 저장 경로(`init(frame:layouts:…)`)로 만든다.
        let api = PaneLayoutNode.split(.leftToRight, [
            branch(.leaf(pane("/a")), 0.4),
            branch(.split(.topToBottom, [branch(.leaf(pane("/b")), 0.5), branch(.leaf(pane("/c")), 0.5)]), 0.6),
        ])
        let web = PaneLayoutNode.split(.topToBottom, [
            branch(.split(.leftToRight, [branch(.leaf(pane("/d")), 0.5), branch(.leaf(pane("/e")), 0.5)]), 0.7),
            branch(.leaf(pane("/f")), 0.3),
        ])
        let record = WindowRecord(frame: frame,
                                  layouts: [ProjectLayoutRecord(projectId: "api", root: api),
                                            ProjectLayoutRecord(projectId: "web", root: web)],
                                  focusedPaneIndex: 4, projectOrder: ["api", "web"])
        let leaves = try XCTUnwrap(record.layouts).flatMap { $0.root.leaves }
        XCTAssertEqual(record.rows.flatMap { $0 }, leaves)
        XCTAssertEqual(leaves.map(\.cwd), ["/a", "/b", "/c", "/d", "/e", "/f"])

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["rows"], "older builds read rows")
        XCTAssertNotNil(json["layouts"])

        struct OldBuildWindow: Decodable { var rows: [[PaneRecord]]; var focusedPaneIndex: Int? }
        let old = try JSONDecoder().decode(OldBuildWindow.self, from: data)
        let oldPanes = old.rows.flatMap { $0 }
        XCTAssertEqual(oldPanes.map(\.cwd), ["/a", "/b", "/c", "/d", "/e", "/f"])
        XCTAssertEqual(old.focusedPaneIndex.map { oldPanes[$0].cwd }, "/e", "focus lands on the same pane")
    }
}

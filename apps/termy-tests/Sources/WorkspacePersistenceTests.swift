// WorkspacePersistenceTests.swift
//
// Covers the serial writer. Every test uses an isolated temp directory so
// the real `~/Library/Application Support/termy/workspaces/` is never
// touched, even if tests crash mid-run.

import XCTest
@testable import termy

final class WorkspacePersistenceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("termy-persist-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makePersistence() async throws -> WorkspacePersistence {
        try WorkspacePersistence(rootDir: tempRoot)
    }

    private func makeRecord(
        path: String = "/Users/test/code/api",
        label: String = "api",
        panes: [PaneRecord] = [PaneRecord(cwd: "/Users/test/code/api")]
    ) -> WorkspaceRecord {
        WorkspaceRecord(canonicalPath: path, displayLabel: label, panes: panes)
    }

    // MARK: - test_roundTrip

    func test_roundTrip_savesAndLoadsRecord() async throws {
        let p = try await makePersistence()
        let record = makeRecord(panes: [
            PaneRecord(cwd: "/Users/test/code/api"),
            PaneRecord(cwd: "/Users/test/code/api/docs")
        ])
        try await p.save(record)

        switch await p.load(canonicalPath: record.canonicalPath) {
        case .loaded(let loaded):
            XCTAssertEqual(loaded.canonicalPath, record.canonicalPath)
            XCTAssertEqual(loaded.displayLabel, record.displayLabel)
            XCTAssertEqual(loaded.panes.count, 2)
            XCTAssertEqual(loaded.panes[0].cwd, "/Users/test/code/api")
            XCTAssertEqual(loaded.panes[1].cwd, "/Users/test/code/api/docs")
        default:
            XCTFail("expected .loaded outcome")
        }
    }

    // MARK: - test_savedFileHas0600Mode

    func test_savedFileHas0600Mode() async throws {
        let p = try await makePersistence()
        let record = makeRecord()
        try await p.save(record)

        let url = await p.fileURL(for: record.canonicalPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    // MARK: - test_filenameIsHashedPathTraversalProof

    func test_filenameIsHashedPathTraversalProof() async throws {
        let p = try await makePersistence()
        // Feed a nasty path with slashes, dots, null-byte-ish content.
        let nastyPath = "/Users/test/code/../../../etc/passwd\u{0000}weird/api"
        let url = await p.fileURL(for: nastyPath)
        // Resolve filename component and assert it stays inside `tempRoot`
        // and contains no path-traversal characters.
        XCTAssertEqual(url.deletingLastPathComponent().path, tempRoot.path)
        let filename = url.lastPathComponent
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains(".."))
        XCTAssertFalse(filename.contains("\u{0000}"))
        XCTAssertTrue(filename.hasSuffix(".json"))
    }

    // MARK: - test_unknownSchemaVersion_quarantinedAndStartsFresh

    func test_unknownSchemaVersion_quarantinedAndReturnsQuarantined() async throws {
        let p = try await makePersistence()
        let recordPath = "/Users/test/code/api"
        let url = await p.fileURL(for: recordPath)

        // Write a file with a schemaVersion far in the future.
        let futureJSON = #"""
        {
          "schemaVersion": 999,
          "canonicalPath": "/Users/test/code/api",
          "displayLabel": "api",
          "updatedAt": "2099-01-01T00:00:00Z",
          "panes": [],
          "someFutureField": "ignored"
        }
        """#
        try futureJSON.write(to: url, atomically: true, encoding: .utf8)

        let outcome = await p.load(canonicalPath: recordPath)
        switch outcome {
        case .quarantined(let reason, let archivedAt):
            XCTAssertEqual(reason, "v999")
            XCTAssertTrue(FileManager.default.fileExists(atPath: archivedAt.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "original file should be moved out of the workspaces root")
        default:
            XCTFail("expected .quarantined, got \(outcome)")
        }
    }

    // MARK: - test_corruptJSON_quarantined

    func test_corruptJSON_quarantined() async throws {
        let p = try await makePersistence()
        let recordPath = "/Users/test/code/api"
        let url = await p.fileURL(for: recordPath)
        // Write bytes that look like JSON but fail schemaVersion probe.
        try "not even JSON at all {{{".write(to: url, atomically: true, encoding: .utf8)

        let outcome = await p.load(canonicalPath: recordPath)
        switch outcome {
        case .quarantined(let reason, _):
            XCTAssertEqual(reason, "undecodable")
        default:
            XCTFail("expected .quarantined, got \(outcome)")
        }
    }

    // MARK: - test_missing_whenNoFileOnDisk

    func test_missing_whenNoFileOnDisk() async throws {
        let p = try await makePersistence()
        let outcome = await p.load(canonicalPath: "/nonexistent/path")
        if case .missing = outcome {
            // ok
        } else {
            XCTFail("expected .missing, got \(outcome)")
        }
    }

    // MARK: - test_all_sortsByUpdatedAtDescending

    func test_all_sortsByUpdatedAtDescending() async throws {
        let p = try await makePersistence()
        let older = WorkspaceRecord(
            canonicalPath: "/a", displayLabel: "a",
            updatedAt: Date(timeIntervalSince1970: 100),
            panes: []
        )
        let newer = WorkspaceRecord(
            canonicalPath: "/b", displayLabel: "b",
            updatedAt: Date(timeIntervalSince1970: 200),
            panes: []
        )
        try await p.save(older)
        try await p.save(newer)

        let listed = await p.all()
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed[0].canonicalPath, "/b", "newer project must come first")
        XCTAssertEqual(listed[1].canonicalPath, "/a")
    }

    // MARK: - test_save_overwritesPreviousRecord

    func test_save_overwritesPreviousRecord() async throws {
        let p = try await makePersistence()
        let first = makeRecord(panes: [PaneRecord(cwd: "/a")])
        try await p.save(first)

        let second = makeRecord(panes: [
            PaneRecord(cwd: "/a"),
            PaneRecord(cwd: "/a/docs")
        ])
        try await p.save(second)

        guard case .loaded(let loaded) = await p.load(canonicalPath: first.canonicalPath) else {
            XCTFail("expected loaded")
            return
        }
        XCTAssertEqual(loaded.panes.count, 2)
    }

    // MARK: - test_delete_removesFile

    func test_delete_removesFile() async throws {
        let p = try await makePersistence()
        let r = makeRecord()
        try await p.save(r)
        let url = await p.fileURL(for: r.canonicalPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await p.delete(canonicalPath: r.canonicalPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - test_quarantineDirHas0700Mode

    func test_quarantineDirHas0700Mode() async throws {
        let p = try await makePersistence()
        let attrs = try FileManager.default.attributesOfItem(atPath: p.quarantineDir.path)
        let mode = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o700)
    }

    // MARK: - Row structure

    func test_saveAndLoad_preservesRowStructure() async throws {
        let p = try await makePersistence()
        let grid: [[PaneRecord]] = [
            [PaneRecord(cwd: "/a"),
             PaneRecord(cwd: "/a/src")],
            [PaneRecord(cwd: "/a/docs")]
        ]
        let record = WorkspaceRecord(
            canonicalPath: "/a",
            displayLabel: "a",
            panes: grid.flatMap { $0 },
            rows: grid
        )
        try await p.save(record)

        guard case .loaded(let loaded) = await p.load(canonicalPath: record.canonicalPath) else {
            XCTFail("expected loaded")
            return
        }
        XCTAssertEqual(loaded.rows?.count, 2, "two rows preserved")
        XCTAssertEqual(loaded.rows?[0].count, 2, "first row has 2 panes side by side")
        XCTAssertEqual(loaded.rows?[1].count, 1, "second row has 1 pane")
        XCTAssertEqual(loaded.rows?[1][0].cwd, "/a/docs")
    }

    func test_effectiveRows_v1RecordWithoutRows_fallsBackToSingleRow() {
        // Legacy record written before the `rows` field existed: only `panes`
        // is present; effectiveRows should wrap everything as a single row.
        let legacy = WorkspaceRecord(
            canonicalPath: "/a",
            displayLabel: "a",
            panes: [
                PaneRecord(cwd: "/a"),
                PaneRecord(cwd: "/b")
            ],
            rows: nil
        )
        XCTAssertEqual(legacy.effectiveRows.count, 1)
        XCTAssertEqual(legacy.effectiveRows[0].count, 2)
    }

    func test_effectiveRows_preferStructuredRowsOverFlatPanes() {
        let rec = WorkspaceRecord(
            canonicalPath: "/a",
            displayLabel: "a",
            panes: [PaneRecord(cwd: "/a"), PaneRecord(cwd: "/b"), PaneRecord(cwd: "/c")],
            rows: [[PaneRecord(cwd: "/a")], [PaneRecord(cwd: "/b"), PaneRecord(cwd: "/c")]]
        )
        XCTAssertEqual(rec.effectiveRows.count, 2)
        XCTAssertEqual(rec.effectiveRows[0].count, 1)
        XCTAssertEqual(rec.effectiveRows[1].count, 2)
    }

    // MARK: - Split tree (layout)

    func test_effectiveLayout_prefersLayoutThenRows() throws {
        let a = PaneRecord(cwd: "/a"), b = PaneRecord(cwd: "/b"), c = PaneRecord(cwd: "/c")
        // 같은 pane·같은 순서지만 모양(위아래)과 비율은 tree의 것이다. rows는 그 열 근사(좌우 두 열)일 뿐이다.
        let saved = PaneLayoutNode.split(.topToBottom, [
            PaneLayoutBranch(node: .leaf(a), weight: 0.3),
            PaneLayoutBranch(node: .leaf(b), weight: 0.7),
        ])
        let withLayout = WorkspaceRecord(canonicalPath: "/a", displayLabel: "a", updatedAt: Date(timeIntervalSince1970: 5),
                                         panes: [a, b], rows: [[a], [b]], layout: saved)
        XCTAssertEqual(withLayout.effectiveLayout, saved, "the saved tree wins over rows")
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceRecord.self, from: JSONEncoder().encode(withLayout)), withLayout)

        let rowsOnly = WorkspaceRecord(canonicalPath: "/a", displayLabel: "a", panes: [a, b, c], rows: [[a], [b, c]])
        XCTAssertNil(rowsOnly.layout)
        XCTAssertEqual(rowsOnly.effectiveLayout, PaneLayoutNode.fromColumns([[a], [b, c]]))

        let panesOnly = WorkspaceRecord(canonicalPath: "/a", displayLabel: "a", panes: [a, b], rows: nil)
        XCTAssertEqual(panesOnly.effectiveLayout, PaneLayoutNode.fromColumns([[a, b]]))

        XCTAssertNil(WorkspaceRecord(canonicalPath: "/a", displayLabel: "a", panes: []).effectiveLayout)
    }

    /// 다른 빌드가 쓴 모르는 모양의 `layout`은 nil로 읽고 `rows`로 복원한다(기록 전체를 격리하지 않는다).
    func test_unreadableLayout_decodesAsNilAndFallsBackToRows() throws {
        let unknownAxis = #"{"axis":"diagonal","children":[{"weight":1,"node":{"pane":{"cwd":"/a"}}}]}"#
        for layout in [unknownAxis, #""oops""#, #"{"children":[]}"#] {
            let json = #"""
            {"schemaVersion":1,"canonicalPath":"/a","displayLabel":"a","updatedAt":0,
             "panes":[{"cwd":"/a"},{"cwd":"/b"}],"rows":[[{"cwd":"/a"}],[{"cwd":"/b"}]],"layout":\#(layout)}
            """#
            let record = try JSONDecoder().decode(WorkspaceRecord.self, from: Data(json.utf8))
            XCTAssertNil(record.layout, layout)
            XCTAssertEqual(record.effectiveLayout,
                           PaneLayoutNode.fromColumns([[PaneRecord(cwd: "/a")], [PaneRecord(cwd: "/b")]]), layout)
        }

        let withoutPanes = #"{"schemaVersion":1,"canonicalPath":"/a","displayLabel":"a","updatedAt":0}"#
        XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceRecord.self, from: Data(withoutPanes.utf8)),
                             "panes stays required")
    }

    /// `layout`은 그 잎이 펼친 `effectiveRows`와 같을 때(같은 pane, 같은 순서)만 쓴다. 어긋나면 pane을 잃지 않게 rows다.
    func test_effectiveLayout_disagreeingWithRows_fallsBackToRows() throws {
        let a = PaneRecord(cwd: "/a"), b = PaneRecord(cwd: "/b")
        let fromRows = PaneLayoutNode.fromColumns([[a], [b]])
        func record(_ layout: PaneLayoutNode<PaneRecord>) -> WorkspaceRecord {
            WorkspaceRecord(canonicalPath: "/a", displayLabel: "a", panes: [a, b], rows: [[a], [b]], layout: layout)
        }

        // 잎 없는 split: 읽히지만(Task 1은 children을 검사하지 않는다) 그대로 쓰면 두 pane을 모두 잃는다.
        let json = #"""
        {"schemaVersion":1,"canonicalPath":"/a","displayLabel":"a","updatedAt":0,
         "panes":[{"cwd":"/a"},{"cwd":"/b"}],"rows":[[{"cwd":"/a"}],[{"cwd":"/b"}]],
         "layout":{"axis":"leftToRight","children":[]}}
        """#
        let empty = try JSONDecoder().decode(WorkspaceRecord.self, from: Data(json.utf8))
        XCTAssertNotNil(empty.layout, "precondition: the leafless tree decodes")
        XCTAssertEqual(empty.effectiveLayout, fromRows)

        XCTAssertEqual(record(PaneLayoutNode.fromColumns([[b], [a]])!).effectiveLayout, fromRows, "different order")
        XCTAssertEqual(record(.leaf(a)).effectiveLayout, fromRows, "a pane missing from the tree")
        XCTAssertEqual(record(PaneLayoutNode.fromColumns([[a], [b], [PaneRecord(cwd: "/c")]])!).effectiveLayout, fromRows,
                       "a pane rows don't have")

        // rows 없는 예전 기록도 `panes`(= effectiveRows)와 맞으면 tree를 쓴다.
        let stacked = PaneLayoutNode.fromColumns([[a, b]])!
        let panesOnly = WorkspaceRecord(canonicalPath: "/a", displayLabel: "a", panes: [a, b], layout: stacked)
        XCTAssertEqual(panesOnly.effectiveLayout, stacked)
    }
}

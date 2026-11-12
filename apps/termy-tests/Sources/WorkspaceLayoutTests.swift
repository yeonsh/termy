import XCTest
import AppKit
@testable import termy

/// Workspace가 project마다 분할 tree 하나로 pane을 배치하는지 본다: ⌘D·⌘⇧D는 포커스된 pane만 나누고, 닫으면 그 split이
/// 접히고, 다른 project로 `cd`했다 돌아오면 배치를 손대지 않은 동안에는 옛 자리·크기로 돌아온다.
@MainActor
final class WorkspaceLayoutTests: XCTestCase {
    /// Never closed: the test host app quits when its last window goes away.
    private static let window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }()

    private var workspace: Workspace!
    private var tempDirs: [URL] = []

    override func setUp() {
        super.setUp()
        let contentView = Self.window.contentView!
        workspace = Workspace(frame: contentView.bounds)
        workspace.autoresizingMask = [.width, .height]
        contentView.addSubview(workspace)
    }

    override func tearDown() {
        for pane in workspace.panes { workspace.closePane(pane) }
        workspace.removeFromSuperview()
        workspace = nil
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        super.tearDown()
    }

    func test_splitRight_splitsOnlyFocusedPane() throws {
        let dir = try makeProjectDir("alpha")
        let a = workspace.addPane(cwd: dir)
        let b = workspace.addPane(cwd: dir, splitAxis: .column)     // ⌘⇧D: a 아래
        workspace.focus(pane: a)
        let c = workspace.addPane(cwd: dir, splitAxis: .row)        // ⌘D: a만 좌우로
        settle()
        XCTAssertEqual(signature(a.projectId, [a: "a", b: "b", c: "c"]), "col(row(a:0.500,c:0.500):0.500,b:0.500)")
        XCTAssertEqual(frame(of: c).minY, frame(of: a).minY, accuracy: 1)
        XCTAssertEqual(frame(of: c).width, frame(of: a).width, accuracy: 1)
        XCTAssertEqual(frame(of: b).width, frame(of: a).width * 2 + 8, accuracy: 1)
        assertLayoutInvariant()
    }

    func test_closingPane_collapsesItsSplit() throws {
        let dir = try makeProjectDir("alpha")
        let a = workspace.addPane(cwd: dir)
        let b = workspace.addPane(cwd: dir, splitAxis: .column)
        workspace.focus(pane: a)
        let c = workspace.addPane(cwd: dir, splitAxis: .row)
        settle()

        workspace.closePane(c)
        settle()

        XCTAssertEqual(workspace.layoutTree(forProject: a.projectId)?.leaves, [a.paneId, b.paneId])
        XCTAssertEqual(frame(of: a).width, frame(of: b).width, accuracy: 1)
        assertLayoutInvariant()
    }

    func test_driftOutAndBack_returnsToSameSlotAndSize() throws {
        let alphaDir = try makeProjectDir("alpha")
        let betaDir = try makeProjectDir("beta")
        let (a, b, c) = makeUnevenRow(in: alphaDir)
        let alpha = a.projectId
        XCTAssertEqual(signature(alpha, [a: "a", b: "b", c: "c"]), "row(a:0.500,b:0.250,c:0.250)",
                       "precondition: ⌘D twice gives an uneven row")
        let before = try XCTUnwrap(workspace.layoutTree(forProject: alpha))
        let bFrame = frame(of: b)

        drift(b, to: betaDir)
        XCTAssertNotEqual(b.projectId, alpha, "precondition: b drifted out")
        XCTAssertEqual(workspace.layoutTree(forProject: alpha)?.leaves, [a.paneId, c.paneId])
        assertLayoutInvariant()

        drift(b, to: alphaDir)
        XCTAssertEqual(b.projectId, alpha, "precondition: b drifted back")
        XCTAssertEqual(workspace.layoutTree(forProject: alpha), before)
        let back = frame(of: b)
        XCTAssertEqual(back.minX, bFrame.minX, accuracy: 1)
        XCTAssertEqual(back.minY, bFrame.minY, accuracy: 1)
        XCTAssertEqual(back.width, bFrame.width, accuracy: 1)
        XCTAssertEqual(back.height, bFrame.height, accuracy: 1)
        assertLayoutInvariant()
    }

    func test_driftOut_editAlpha_thenBack_autoPlaces() throws {
        let alphaDir = try makeProjectDir("alpha")
        let betaDir = try makeProjectDir("beta")
        let (a, b, _) = makeUnevenRow(in: alphaDir)
        let alpha = a.projectId
        let before = try XCTUnwrap(workspace.layoutTree(forProject: alpha))

        drift(b, to: betaDir)
        XCTAssertNotEqual(b.projectId, alpha, "precondition: b drifted out")
        workspace.addPane(cwd: alphaDir)
        settle()
        drift(b, to: alphaDir)
        XCTAssertEqual(b.projectId, alpha, "precondition: b drifted back")

        let after = try XCTUnwrap(workspace.layoutTree(forProject: alpha))
        XCTAssertFalse(after.hasSameStructure(as: before), "b came back to its old slot although alpha changed meanwhile")
        XCTAssertEqual(after.leaves.count, 4)
        assertLayoutInvariant()
    }

    func test_paneClosedWhileAway_leavesNoGhostSlot() throws {
        let alphaDir = try makeProjectDir("alpha")
        let betaDir = try makeProjectDir("beta")
        let (a, b, c) = makeUnevenRow(in: alphaDir)
        let alpha = a.projectId

        drift(b, to: betaDir)
        let beta = b.projectId
        XCTAssertNotEqual(beta, alpha, "precondition: b drifted out")
        workspace.closePane(b)
        settle()

        XCTAssertEqual(workspace.layoutTree(forProject: alpha)?.leaves, [a.paneId, c.paneId])
        XCTAssertNil(workspace.layoutTree(forProject: beta))
        XCTAssertFalse(workspace.filterOptions.contains(.project(beta)))
        assertLayoutInvariant()
    }

    func test_applyRestoredLayout_installsExactTree() throws {
        let dir = try makeProjectDir("alpha")
        let a = workspace.addPane(cwd: dir)
        let b = workspace.addPane(cwd: dir)
        let c = workspace.addPane(cwd: dir)
        let d = workspace.addPane(cwd: dir)
        let tree = try XCTUnwrap(PaneLayoutNode.fromColumns([[a], [b, c], [d]]))

        workspace.applyRestoredLayout(tree)
        settle()

        let ids = tree.map { $0.paneId }
        XCTAssertEqual(workspace.layoutTree(forProject: a.projectId), ids)
        let expected = try XCTUnwrap(ids.frames(
            in: PaneDropPlanner.contentRect(for: workspace.bounds.size), gap: PaneDropPlanner.gap
        ).frame(of: b.paneId))
        let actual = frame(of: b)
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1)
        assertLayoutInvariant()
    }

    func test_applyRestoredLayout_paneInAnotherProject_staysPlaced() throws {
        let alphaDir = try makeProjectDir("alpha")
        let betaDir = try makeProjectDir("beta")
        let a1 = workspace.addPane(cwd: alphaDir)
        let a2 = workspace.addPane(cwd: alphaDir)
        let b1 = workspace.addPane(cwd: betaDir)
        let alpha = a1.projectId
        let beta = b1.projectId
        XCTAssertNotEqual(alpha, beta, "precondition: two projects")
        // 자동 배치(a1 | a2)와 다른 모양: a2 위, a1 아래.
        let tree = try XCTUnwrap(PaneLayoutNode.fromColumns([[a2, b1, a1]]))

        workspace.applyRestoredLayout(tree)
        settle()

        let alphaPart = try XCTUnwrap(tree.removing(where: { $0.projectId != alpha })).map { $0.paneId }
        XCTAssertEqual(workspace.layoutTree(forProject: alpha), alphaPart)
        XCTAssertEqual(workspace.layoutTree(forProject: beta)?.leaves, [b1.paneId])
        assertLayoutInvariant()
        for pane in [a1, a2, b1] {
            workspace.filter = .project(pane.projectId)
            settle()
            XCTAssertFalse(pane.terminal.isHiddenOrHasHiddenAncestor, "\(pane.projectId) pane hidden in its own view")
            XCTAssertGreaterThan(frame(of: pane).width, 100)
        }
    }

    func test_cycleFocus_walksTreeReadingOrder() throws {
        let dir = try makeProjectDir("alpha")
        let a = workspace.addPane(cwd: dir)
        let b = workspace.addPane(cwd: dir)
        let c = workspace.addPane(cwd: dir)
        let d = workspace.addPane(cwd: dir)
        workspace.applyRestoredLayout(try XCTUnwrap(PaneLayoutNode.fromColumns([[a], [b, c], [d]])))
        settle()
        workspace.focus(pane: a)

        workspace.cycleFocus(delta: 1)
        XCTAssertTrue(workspace.focusedPane === b)
        workspace.cycleFocus(delta: 1)
        XCTAssertTrue(workspace.focusedPane === c)
        workspace.cycleFocus(delta: 1)
        XCTAssertTrue(workspace.focusedPane === d)
    }

    // MARK: - Helpers

    /// ⌘D 두 번: a | b | c, 비율 a .5, b .25, c .25.
    private func makeUnevenRow(in dir: String) -> (Pane, Pane, Pane) {
        let a = workspace.addPane(cwd: dir)
        let b = workspace.addPane(cwd: dir, splitAxis: .row)
        let c = workspace.addPane(cwd: dir, splitAxis: .row)
        settle()
        return (a, b, c)
    }

    /// 모든 pane은 자기 project 보이는 tree의 잎으로 정확히 한 번 있고, 다른 project의 보이는 tree에는 없다.
    private func assertLayoutInvariant(file: StaticString = #filePath, line: UInt = #line) {
        let trees = workspace.knownProjectIds.map { ($0, workspace.layoutTree(forProject: $0)?.leaves ?? []) }
        for pane in workspace.panes {
            for (projectId, leaves) in trees {
                let count = leaves.filter { $0 == pane.paneId }.count
                XCTAssertEqual(count, projectId == pane.projectId ? 1 : 0,
                               "pane of \(pane.projectId) appears \(count)× in \(projectId)'s tree", file: file, line: line)
            }
        }
        XCTAssertEqual(trees.reduce(0) { $0 + $1.1.count }, workspace.panes.count,
                       "visible trees hold a leaf that is not an open pane", file: file, line: line)
    }

    /// Workspace 기준 y-아래 좌표의 pane frame.
    private func frame(of pane: Pane) -> CGRect {
        let r = pane.convert(pane.bounds, to: workspace)
        return CGRect(x: r.minX, y: workspace.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    /// pane id → 짧은 이름으로 바꾼 보이는 tree의 signature.
    private func signature(_ projectId: String, _ names: [Pane: String]) -> String? {
        let byId = Dictionary(uniqueKeysWithValues: names.map { ($0.key.paneId, $0.value) })
        return workspace.layoutTree(forProject: projectId).map { layoutSignature($0.map { byId[$0] ?? "?" }) }
    }

    /// OSC 7과 같은 길로 cwd를 바꾸고 projectId가 바뀔 때까지 기다린다. 셸은 프롬프트 때만 OSC 7을 보낼 수 있으므로,
    /// 첫 프롬프트가 그려진 뒤(버퍼 첫 줄이 비지 않을 때까지, 최대 5초) 0.3초 더 기다리고 나서 바꾼다 — 테스트 셸이 늦게
    /// 보낸 자기 cwd가 시뮬레이션한 drift를 덮지 않게.
    private func drift(_ pane: Pane, to dir: String) {
        let promptDeadline = Date().addingTimeInterval(5)
        while (pane.terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) ?? "").isEmpty,
              Date() < promptDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = pane.projectId
        pane.hostCurrentDirectoryUpdate(source: pane.terminal, directory: URL(fileURLWithPath: dir).absoluteString)
        let deadline = Date().addingTimeInterval(3)
        while pane.projectId == before && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        settle()
    }

    /// Run the layout passes and the async thaw that follow a relayout.
    private func settle() {
        for _ in 0..<4 {
            Self.window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func makeProjectDir(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("termy-layout-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir.deletingLastPathComponent())
        return dir.path
    }
}

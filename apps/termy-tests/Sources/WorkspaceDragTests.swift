import XCTest
import AppKit
@testable import termy

/// header를 끌어 pane을 옮긴다: 미리보기 상자 == 놓은 뒤 실제 frame, 끄는 도중 배치가 바뀌면 옛 계획은 버린다, 끌 수 없는
/// 화면에서는 시작하지 않는다. `endToEnd` 테스트는 창에 넣은 실제 이벤트(mouseDragged·mouseUp·Esc)로 header의
/// `trackEvents` 루프와 NSSplitView 경계선 추적을 끝까지 돌린다 — 실제 앱을 띄워 확인할 수 없는 끌기 배선을 대신 본다.
@MainActor
final class WorkspaceDragTests: XCTestCase {
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
        Self.drainPostedEvents()
        let contentView = Self.window.contentView!
        workspace = Workspace(frame: contentView.bounds)
        workspace.autoresizingMask = [.width, .height]
        contentView.addSubview(workspace)
    }

    override func tearDown() {
        Self.drainPostedEvents()
        for pane in workspace.panes { workspace.closePane(pane) }
        workspace.removeFromSuperview()
        workspace = nil
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        super.tearDown()
    }

    // MARK: - Plan · apply

    /// 미리보기 상자 == 놓은 뒤 실제 frame (스펙 "하면 실패인 것" 2번).
    func test_dropPreviewMatchesActualFrame() throws {
        let (a, b, c, d) = try makeABCD()
        let original = try XCTUnwrap(PaneLayoutNode.fromColumns([[a], [b, c], [d]]))
        let fa = frame(of: a), fb = frame(of: b), fd = frame(of: d)
        let bounds = workspace.bounds
        // B↔C 틈은 C에게는 자기 바로 옆 틈(제자리)이라 A를 끼운다.
        let cases: [(name: String, mover: Pane, point: CGPoint)] = [
            ("A right triangle", c, CGPoint(x: fa.midX + fa.width * 0.4, y: fa.midY)),
            ("gap A|column", c, CGPoint(x: fa.maxX + 4, y: fa.midY)),
            ("gap B/C", a, CGPoint(x: fb.midX, y: fb.maxY + 4)),
            ("D center (swap)", a, CGPoint(x: fd.midX, y: fd.midY)),
            ("outer bottom", c, CGPoint(x: bounds.midX, y: bounds.height - 5)),
        ]
        for (name, mover, point) in cases {
            workspace.applyRestoredLayout(original)
            settle()
            let plan = try XCTUnwrap(workspace.dragPlan(moving: mover, toFlippedPoint: point), name)
            XCTAssertTrue(workspace.applyDrop(plan, generation: workspace.layoutGeneration), name)
            settle()
            XCTAssertEqual(workspace.layoutTree(forProject: a.projectId), plan.result, name)
            assertFrame(frame(of: mover), plan.previewFrame, name)
        }
    }

    func test_staleGeneration_dropIsIgnored() throws {
        let (a, b, c, d) = try makeABCD()
        let fa = frame(of: a)
        let target = CGPoint(x: fa.midX + fa.width * 0.4, y: fa.midY)
        let plan = try XCTUnwrap(workspace.dragPlan(moving: c, toFlippedPoint: target))
        let generation = workspace.layoutGeneration

        workspace.closePane(d)
        settle()

        XCTAssertFalse(workspace.applyDrop(plan, generation: generation))
        XCTAssertEqual(workspace.layoutTree(forProject: a.projectId)?.leaves, [a.paneId, b.paneId, c.paneId])

        // 잎은 그대로이고 크기만 바뀌어도(창 크기 변경) 옛 계획은 버린다.
        let plan2 = try XCTUnwrap(workspace.dragPlan(moving: c, toFlippedPoint: target))
        let generation2 = workspace.layoutGeneration
        let before = workspace.layoutTree(forProject: a.projectId)
        workspace.setFrameSize(NSSize(width: workspace.bounds.width - 100, height: workspace.bounds.height))
        XCTAssertFalse(workspace.applyDrop(plan2, generation: generation2))
        XCTAssertEqual(workspace.layoutTree(forProject: a.projectId), before)
    }

    func test_cannotDrag_singlePane_maximized_multiProjectAll() throws {
        let alphaDir = try makeProjectDir("alpha")
        let betaDir = try makeProjectDir("beta")
        let a = workspace.addPane(cwd: alphaDir)
        settle()
        XCTAssertFalse(workspace.canBeginPaneDrag(a), "single pane")

        let a2 = workspace.addPane(cwd: alphaDir)
        settle()
        XCTAssertTrue(workspace.canBeginPaneDrag(a))
        XCTAssertTrue(workspace.canBeginPaneDrag(a2))

        workspace.toggleMaximize()
        settle()
        XCTAssertFalse(workspace.canBeginPaneDrag(a2), "maximized")

        let b = workspace.addPane(cwd: betaDir)
        XCTAssertNotEqual(b.projectId, a.projectId, "precondition: two projects")
        workspace.filter = .all
        settle()
        XCTAssertFalse(workspace.canBeginPaneDrag(a), "ALL with several projects")

        workspace.filter = .project(a.projectId)
        settle()
        XCTAssertTrue(workspace.canBeginPaneDrag(a))
        XCTAssertFalse(workspace.canBeginPaneDrag(b), "pane outside the shown tree")
    }

    func test_headerMouseDown_reachesPaneCallback() throws {
        let dir = try makeProjectDir("alpha")
        let a = workspace.addPane(cwd: dir)
        _ = workspace.addPane(cwd: dir)
        settle()
        var received = 0
        a.onHeaderMouseDown = { _ in received += 1 }
        let header = headerRect(of: a)

        try click(at: NSPoint(x: header.midX, y: header.midY))
        try click(at: NSPoint(x: header.minX + 14, y: header.midY))   // 라벨 위

        XCTAssertEqual(received, 2)
    }

    // MARK: - End to end: real event tracking

    func test_headerDrag_endToEnd_dropsWhereThePreviewShowed() throws {
        let (a, _, c, _) = try makeABCD()
        workspace.focus(pane: a)
        var saves = 0
        workspace.onLayoutChanged = { saves += 1 }
        let fa = frame(of: a)
        let target = CGPoint(x: fa.midX + fa.width * 0.4, y: fa.midY)
        let expected = try XCTUnwrap(workspace.dragPlan(moving: c, toFlippedPoint: target))
        let before = workspace.layoutTree(forProject: a.projectId)
        let cBefore = frame(of: c)
        let generation = workspace.layoutGeneration
        let cursorBefore = NSCursor.current
        let start = headerCenter(of: c)
        let probe = DragProbe()

        try post(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y))
        try post(.leftMouseDragged, at: windowPoint(target))
        duringTracking { [self] in
            probe.ran = true
            let overlay = self.overlay()
            XCTAssertNotNil(overlay, "overlay not shown while dragging")
            if let preview = overlay?.previewFrame {
                self.assertFrame(preview, expected.previewFrame, "preview box")
            } else {
                XCTFail("no preview box over a valid drop zone")
            }
            XCTAssertTrue(overlay.map { self.workspace.subviews.last === $0 } ?? false, "overlay is not on top")
            XCTAssertEqual(c.alphaValue, 0.35, accuracy: 0.001)
            XCTAssertTrue(NSCursor.current == NSCursor.closedHand, "cursor is not a closed hand")
            XCTAssertEqual(self.workspace.layoutGeneration, generation, "relayout while dragging")
            XCTAssertEqual(self.workspace.layoutTree(forProject: c.projectId), before)
            self.assertFrame(self.frame(of: c), cBefore, "pane moved while dragging")
            try? self.post(.leftMouseUp, at: self.windowPoint(target))
        }
        try sendMouseDown(at: start)

        XCTAssertTrue(probe.ran, "the drag loop never waited for the next event")
        settle()
        XCTAssertEqual(workspace.layoutTree(forProject: a.projectId), expected.result)
        assertFrame(frame(of: c), expected.previewFrame, "dropped frame")
        XCTAssertEqual(c.alphaValue, 1)
        XCTAssertNil(overlay())
        XCTAssertTrue(workspace.focusedPane === c)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(NSCursor.current == cursorBefore, "cursor not popped")
    }

    func test_headerDrag_endToEnd_escapeCancels() throws {
        let (a, _, c, _) = try makeABCD()
        var saves = 0
        workspace.onLayoutChanged = { saves += 1 }
        let fa = frame(of: a)
        let target = CGPoint(x: fa.midX + fa.width * 0.4, y: fa.midY)
        let before = workspace.layoutTree(forProject: a.projectId)
        let cursorBefore = NSCursor.current
        let start = headerCenter(of: c)
        let probe = DragProbe()

        try post(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y))
        try post(.leftMouseDragged, at: windowPoint(target))
        duringTracking { [self] in
            probe.ran = true
            XCTAssertNotNil(self.overlay()?.previewFrame, "precondition: dragging over a drop zone")
            try? self.postEscape()
        }
        try sendMouseDown(at: start)

        XCTAssertTrue(probe.ran)
        settle()
        XCTAssertEqual(workspace.layoutTree(forProject: a.projectId), before)
        XCTAssertNil(overlay())
        XCTAssertEqual(c.alphaValue, 1)
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(workspace.focusedPane === c, "pressing the header still focuses")
        XCTAssertTrue(NSCursor.current == cursorBefore, "cursor not popped")
    }

    /// 끄는 도중 셸이 끝나 pane이 닫히면(세대가 바뀜) 끌기를 그만두고, 마우스를 놓아도 옛 계획을 쓰지 않는다.
    func test_headerDrag_endToEnd_layoutChangeMidDragCancels() throws {
        let (a, _, c, d) = try makeABCD()
        var saves = 0
        workspace.onLayoutChanged = { saves += 1 }
        let fa = frame(of: a)
        let target = CGPoint(x: fa.midX + fa.width * 0.4, y: fa.midY)
        let start = headerCenter(of: c)
        let probe = DragProbe()

        try post(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y))
        try post(.leftMouseDragged, at: windowPoint(target))
        duringTracking { [self] in
            probe.ran = true
            XCTAssertNotNil(self.overlay()?.previewFrame, "precondition: dragging over a drop zone")
            self.workspace.closePane(d)
            probe.treeAfterClose = self.workspace.layoutTree(forProject: a.projectId)
            try? self.post(.leftMouseDragged, at: self.windowPoint(target))
            try? self.post(.leftMouseUp, at: self.windowPoint(target))
        }
        try sendMouseDown(at: start)

        XCTAssertTrue(probe.ran)
        // 루프는 세대가 바뀐 뒤 첫 이벤트(mouseDragged)에서 멈췄다 — 뒤의 mouseUp은 꺼내 가지 않았다.
        XCTAssertNotNil(NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true),
                        "the drag kept tracking after the layout changed")
        settle()
        XCTAssertNotNil(probe.treeAfterClose)
        XCTAssertEqual(workspace.layoutTree(forProject: a.projectId), probe.treeAfterClose)
        XCTAssertNil(overlay())
        XCTAssertEqual(c.alphaValue, 1)
        XCTAssertEqual(saves, 0)
    }

    func test_headerDrag_endToEnd_releaseOutsideWindowCancels() throws {
        let (a, _, c, _) = try makeABCD()
        var saves = 0
        workspace.onLayoutChanged = { saves += 1 }
        let fa = frame(of: a)
        let target = CGPoint(x: fa.midX + fa.width * 0.4, y: fa.midY)
        let before = workspace.layoutTree(forProject: a.projectId)
        let start = headerCenter(of: c)
        let outside = NSPoint(x: -40, y: -40)
        let probe = DragProbe()

        try post(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y))
        try post(.leftMouseDragged, at: windowPoint(target))
        duringTracking { [self] in
            probe.ran = true
            XCTAssertNotNil(self.overlay()?.previewFrame, "precondition: dragging over a drop zone")
            try? self.post(.leftMouseDragged, at: outside)
            try? self.post(.leftMouseUp, at: outside)
        }
        try sendMouseDown(at: start)

        XCTAssertTrue(probe.ran)
        settle()
        XCTAssertEqual(workspace.layoutTree(forProject: a.projectId), before)
        XCTAssertNil(overlay())
        XCTAssertEqual(c.alphaValue, 1)
        XCTAssertEqual(saves, 0)
    }

    func test_headerClick_endToEnd_withoutMovementOnlyFocuses() throws {
        let (a, _, c, _) = try makeABCD()
        workspace.focus(pane: a)
        var saves = 0
        workspace.onLayoutChanged = { saves += 1 }
        let before = workspace.layoutTree(forProject: a.projectId)
        let generation = workspace.layoutGeneration
        let start = headerCenter(of: c)
        let probe = DragProbe()

        try post(.leftMouseDragged, at: NSPoint(x: start.x + 2, y: start.y + 1))
        duringTracking { [self] in
            probe.ran = true
            XCTAssertNil(self.overlay(), "a 2pt wobble started a drag")
            XCTAssertEqual(c.alphaValue, 1)
            try? self.post(.leftMouseUp, at: NSPoint(x: start.x + 2, y: start.y + 1))
        }
        try sendMouseDown(at: start)

        XCTAssertTrue(probe.ran)
        settle()
        XCTAssertTrue(workspace.focusedPane === c)
        XCTAssertEqual(workspace.layoutTree(forProject: a.projectId), before)
        XCTAssertEqual(workspace.layoutGeneration, generation)
        XCTAssertNil(overlay())
        XCTAssertEqual(saves, 0)
    }

    /// 경계선 끌기(Task 5)의 실제 배선: GapSplitView.mouseDown → NSSplitView 추적 → captureUserResize → 비율 저장.
    func test_dividerDrag_endToEnd_storesWeights() throws {
        let dir = try makeProjectDir("alpha")
        let a = workspace.addPane(cwd: dir)
        _ = workspace.addPane(cwd: dir, splitAxis: .row)
        settle()
        var saves = 0
        workspace.onLayoutChanged = { saves += 1 }
        let root = try XCTUnwrap(workspace.rootSplit)
        let left = root.arrangedSubviews[0].frame
        let divider = root.convert(NSPoint(x: left.maxX + root.dividerThickness / 2, y: root.bounds.midY), to: nil)
        let aWidth = frame(of: a).width

        try post(.leftMouseDragged, at: NSPoint(x: divider.x + 40, y: divider.y))
        try post(.leftMouseDragged, at: NSPoint(x: divider.x + 120, y: divider.y))
        try post(.leftMouseUp, at: NSPoint(x: divider.x + 120, y: divider.y))
        try sendMouseDown(at: divider)
        settle()

        XCTAssertEqual(saves, 1)
        guard case .split(_, let branches) = workspace.layoutTree(forProject: a.projectId) else {
            return XCTFail("no root split")
        }
        XCTAssertGreaterThan(branches[0].weight, 0.55, "weights did not follow the divider")
        workspace.toggleMaximize(); workspace.toggleMaximize(); settle()   // relayout 두 번
        XCTAssertEqual(frame(of: a).width, aWidth + 120, accuracy: 1)
    }

    // MARK: - Helpers

    /// `duringTracking` 블록이 남기는 값.
    @MainActor private final class DragProbe {
        var ran = false
        var treeAfterClose: PaneLayoutNode<String>?
    }

    /// 같은 폴더 pane 4개를 `A | B/C | D`(열 각 1/3)로.
    private func makeABCD() throws -> (Pane, Pane, Pane, Pane) {
        let dir = try makeProjectDir("alpha")
        let a = workspace.addPane(cwd: dir)
        let b = workspace.addPane(cwd: dir)
        let c = workspace.addPane(cwd: dir)
        let d = workspace.addPane(cwd: dir)
        workspace.applyRestoredLayout(try XCTUnwrap(PaneLayoutNode.fromColumns([[a], [b, c], [d]])))
        settle()
        return (a, b, c, d)
    }

    private func overlay() -> PaneDragOverlayView? {
        workspace.subviews.lazy.compactMap { $0 as? PaneDragOverlayView }.first
    }

    /// Workspace 기준 y-아래 좌표의 pane frame.
    private func frame(of pane: Pane) -> CGRect {
        let r = pane.convert(pane.bounds, to: workspace)
        return CGRect(x: r.minX, y: workspace.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    /// Workspace 기준 y-아래 좌표 → 창 좌표.
    private func windowPoint(_ flipped: CGPoint) -> NSPoint {
        workspace.convert(NSPoint(x: flipped.x, y: workspace.bounds.height - flipped.y), to: nil)
    }

    /// pane header(위쪽 26pt 띠)의 창 좌표 rect.
    private func headerRect(of pane: Pane) -> NSRect {
        let r = pane.convert(pane.bounds, to: nil)
        return NSRect(x: r.minX, y: r.maxY - 26, width: r.width, height: 26)
    }

    private func headerCenter(of pane: Pane) -> NSPoint {
        let r = headerRect(of: pane)
        return NSPoint(x: r.midX, y: r.midY)
    }

    private func assertFrame(_ actual: CGRect, _ expected: CGRect, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, "\(message): minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, "\(message): minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, "\(message): width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, "\(message): height", file: file, line: line)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: Self.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    /// 큐 끝에 넣는다. 뒤이은 mouseDown이 연 추적 루프가 꺼내 간다.
    private func post(_ type: NSEvent.EventType, at point: NSPoint) throws {
        NSApp.postEvent(try mouseEvent(type, at: point), atStart: false)
    }

    private func postEscape() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: Self.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        NSApp.postEvent(event, atStart: false)
    }

    /// mouseDown을 창의 hitTest가 고른 view에 보낸다. 끌기면 그 안에서 추적 루프가 돌고, 놓거나 취소한 뒤에 돌아온다.
    /// `NSApp.sendEvent`를 쓰지 않는 까닭: 테스트 호스트 앱은 활성화되지 않아 창이 key가 될 수 없고, key가 아닌 창은
    /// 첫 클릭을 view에 넘기지 않는다(`acceptsFirstMouse` — header도 NSSplitView도 false). 그 관문만 건너뛰고, 그 아래
    /// (hitTest, header·NSSplitView의 mouseDown, 큐에서 이벤트를 꺼내는 추적 루프)는 앱과 같은 경로다.
    private func sendMouseDown(at point: NSPoint) throws {
        let event = try mouseEvent(.leftMouseDown, at: point)
        let frameView = try XCTUnwrap(Self.window.contentView?.superview)
        let target = try XCTUnwrap(frameView.hitTest(point), "nothing under \(point)")
        target.mouseDown(with: event)
    }

    private func click(at point: NSPoint) throws {
        try sendMouseDown(at: point)
    }

    /// 추적 루프가 큐의 이벤트를 다 쓰고 다음 이벤트를 기다릴 때(0.1초 뒤) `body`를 돌린다. 끝내는 이벤트는 `body`가 넣는다.
    private func duringTracking(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { body() }
        }
    }

    /// 앞 테스트가 남긴(취소로 쓰이지 않은) 이벤트가 다음 추적 루프에 들어가지 않게.
    private static func drainPostedEvents() {
        while NSApp.nextEvent(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown],
            until: Date(), inMode: .default, dequeue: true
        ) != nil {}
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
            .appendingPathComponent("termy-drag-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir.deletingLastPathComponent())
        return dir.path
    }
}

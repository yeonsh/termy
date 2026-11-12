import XCTest
import AppKit
@testable import termy

@MainActor
final class ViewedPaneTrackerTests: XCTestCase {
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

    func test_resolve_activeAppWithKeyMainWindow_returnsFocusedPane() {
        XCTAssertEqual(ViewedPaneTracker.resolve(isAppActive: true, keyWindowFocusedPaneId: "p1"), "p1")
    }

    func test_resolve_inactiveApp_returnsNil() {
        XCTAssertNil(ViewedPaneTracker.resolve(isAppActive: false, keyWindowFocusedPaneId: "p1"))
    }

    func test_resolve_keyWindowIsNotMain_returnsNil() {
        XCTAssertNil(ViewedPaneTracker.resolve(isAppActive: true, keyWindowFocusedPaneId: nil))
    }

    func test_workspaceFocus_postsFocusedPaneDidChange() throws {
        let first = workspace.addPane(cwd: try makeDir("a"))
        let second = workspace.addPane(cwd: try makeDir("b"))
        workspace.focus(pane: first)

        let posted = expectation(forNotification: Workspace.focusedPaneDidChangeNotification, object: workspace)
        workspace.focus(pane: second)
        wait(for: [posted], timeout: 2)

        let silent = expectation(forNotification: Workspace.focusedPaneDidChangeNotification, object: workspace)
        silent.isInverted = true
        workspace.focus(pane: second)
        wait(for: [silent], timeout: 0.3)
    }

    // MARK: - Debounced refresh

    private func makeTracker(
        scheduler: ManualScheduler, resolved: Box, sent: SentLog
    ) -> ViewedPaneTracker {
        ViewedPaneTracker(
            schedule: scheduler.schedule,
            resolver: { resolved.value },
            sender: { sent.values.append($0) }
        )
    }

    func test_scheduleRefresh_collapsesTransientValuesIntoSettledOne() {
        let scheduler = ManualScheduler()
        let resolved = Box(value: "X")
        let sent = SentLog()
        let tracker = makeTracker(scheduler: scheduler, resolved: resolved, sent: sent)

        tracker.scheduleRefresh()
        scheduler.advance(by: 0.1)
        resolved.value = "T"
        tracker.scheduleRefresh()
        scheduler.advance(by: 0.2)
        XCTAssertTrue(sent.values.isEmpty)
        scheduler.advance(by: 0.2)
        XCTAssertEqual(sent.values, ["T"])
    }

    func test_scheduleRefresh_sameValueAgain_sendsNothing() {
        let scheduler = ManualScheduler()
        let resolved = Box(value: "T")
        let sent = SentLog()
        let tracker = makeTracker(scheduler: scheduler, resolved: resolved, sent: sent)

        tracker.scheduleRefresh()
        scheduler.advance(by: 1)
        tracker.scheduleRefresh()
        scheduler.advance(by: 1)
        XCTAssertEqual(sent.values, ["T"])
    }

    func test_scheduleRefresh_changeToNil_sendsNil() {
        let scheduler = ManualScheduler()
        let resolved = Box(value: "T")
        let sent = SentLog()
        let tracker = makeTracker(scheduler: scheduler, resolved: resolved, sent: sent)

        tracker.scheduleRefresh()
        scheduler.advance(by: 1)
        resolved.value = nil
        tracker.scheduleRefresh()
        scheduler.advance(by: 1)
        XCTAssertEqual(sent.values, ["T", nil])
    }

    private final class Box { var value: String?; init(value: String?) { self.value = value } }
    private final class SentLog { var values: [String?] = [] }

    private func makeDir(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("termy-viewed-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir.deletingLastPathComponent())
        return dir.path
    }
}

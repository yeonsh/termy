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

    private func makeDir(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("termy-viewed-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir.deletingLastPathComponent())
        return dir.path
    }
}

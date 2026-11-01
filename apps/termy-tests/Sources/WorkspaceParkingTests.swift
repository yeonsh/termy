import XCTest
import AppKit
@testable import termy

/// Panes hidden by a project filter keep running (Claude Code redraws its
/// status line while you look at another project), so their PTY must keep
/// the size they had on screen. When a hidden pane's PTY collapsed to a
/// sliver, claude-hud truncated every status-line row to that width
/// (`[Op...`) and the pane showed it after unhiding until the agent
/// printed again.
@MainActor
final class WorkspaceParkingTests: XCTestCase {
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

    func test_switchingFromAllToProject_keepsHiddenPaneTerminalSize() throws {
        let alpha = workspace.addPane(cwd: try makeProjectDir("alpha"))
        let beta = workspace.addPane(cwd: try makeProjectDir("beta"))
        XCTAssertNotEqual(alpha.projectId, beta.projectId)
        workspace.filter = .all
        settle()

        let shown = size(of: beta)
        XCTAssertGreaterThan(shown.cols, 40, "precondition: beta laid out in the ALL grid")
        XCTAssertGreaterThan(shown.rows, 10, "precondition: beta laid out in the ALL grid")

        workspace.filter = .project(alpha.projectId)
        settle()

        XCTAssertEqual(size(of: beta).cols, shown.cols, "hidden pane's PTY columns changed")
        XCTAssertEqual(size(of: beta).rows, shown.rows, "hidden pane's PTY rows changed")
    }

    func test_hiddenPane_comesBackAtTheVisibleSize() throws {
        let alpha = workspace.addPane(cwd: try makeProjectDir("alpha"))
        let beta = workspace.addPane(cwd: try makeProjectDir("beta"))
        workspace.filter = .project(beta.projectId)
        settle()
        let alone = size(of: beta)

        workspace.filter = .all
        settle()
        workspace.filter = .project(alpha.projectId)
        settle()
        workspace.filter = .project(beta.projectId)
        settle()

        XCTAssertEqual(size(of: beta).cols, alone.cols)
        XCTAssertEqual(size(of: beta).rows, alone.rows)
    }

    // MARK: - Helpers

    private func size(of pane: Pane) -> (cols: Int, rows: Int) {
        let terminal = pane.terminal.getTerminal()
        return (terminal.cols, terminal.rows)
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
            .appendingPathComponent("termy-parking-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir.deletingLastPathComponent())
        return dir.path
    }
}

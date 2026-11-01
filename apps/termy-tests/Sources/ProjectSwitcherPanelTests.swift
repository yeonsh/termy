import AppKit
import XCTest
@testable import termy

/// ⌘K remove button (2026-10-31): a saved project whose folder was renamed
/// away stays in the list until the user removes it. Removing forgets the
/// saved layout only; the folder is never touched.
@MainActor
final class ProjectSwitcherPanelTests: XCTestCase {
    private var panel: ProjectSwitcherPanel!
    private var removed: [String] = []
    private static var retiredPanels: [ProjectSwitcherPanel] = []

    override func setUp() async throws {
        Self.keepAWindowOpen()
        panel = ProjectSwitcherPanel()
        removed = []
        panel.onDelete = { [weak self] record in self?.removed.append(record.canonicalPath) }
    }

    override func tearDown() async throws {
        // Hide, never close or release: the test host is termy, and losing
        // its only window quits the app mid-run.
        panel.orderOut(nil)
        Self.retiredPanels.append(panel)
        panel = nil
    }

    // Newest first: alpha, beta, gamma.
    private let records = [
        WorkspaceRecord(canonicalPath: "/p/alpha", displayLabel: "alpha",
                        updatedAt: Date(timeIntervalSince1970: 3_000), panes: [PaneRecord(cwd: "/p/alpha")]),
        WorkspaceRecord(canonicalPath: "/p/beta", displayLabel: "beta",
                        updatedAt: Date(timeIntervalSince1970: 2_000), panes: [PaneRecord(cwd: "/p/beta")]),
        WorkspaceRecord(canonicalPath: "/p/gamma", displayLabel: "gamma",
                        updatedAt: Date(timeIntervalSince1970: 1_000), panes: [PaneRecord(cwd: "/p/gamma")]),
    ]

    func test_removeButton_dropsTheRowAndReportsItsRecord() throws {
        panel.present(records: records, openPaths: [], over: nil)

        try XCTUnwrap(removeButton(row: 1)).performClick(nil)

        XCTAssertEqual(removed, ["/p/beta"])
        XCTAssertEqual(visibleLabels(), ["alpha", "gamma"])
    }

    /// The autosaver rewrites an open project's record on its next save, so
    /// removing it would not stick.
    func test_openProject_hasNoRemoveButton() throws {
        panel.present(records: records, openPaths: ["/p/beta"], over: nil)

        XCTAssertEqual(try XCTUnwrap(removeButton(row: 0)).isHidden, false)
        XCTAssertEqual(try XCTUnwrap(removeButton(row: 1)).isHidden, true)
    }

    func test_removingTheSelectedRow_selectsTheRowThatTakesItsPlace() throws {
        panel.present(records: records, openPaths: [], over: nil)
        table().selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        try XCTUnwrap(removeButton(row: 1)).performClick(nil)

        XCTAssertEqual(selectedLabel(), "gamma")
    }

    func test_removingAnotherRow_keepsTheSelectedProject() throws {
        panel.present(records: records, openPaths: [], over: nil)
        table().selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        try XCTUnwrap(removeButton(row: 0)).performClick(nil)

        XCTAssertEqual(selectedLabel(), "gamma")
    }

    func test_commandDelete_withEmptyQuery_removesTheSelectedRow() {
        panel.present(records: records, openPaths: [], over: nil)

        XCTAssertTrue(sendCommandDelete())

        XCTAssertEqual(removed, ["/p/alpha"])
        XCTAssertEqual(visibleLabels(), ["beta", "gamma"])
    }

    /// With a query typed, ⌘⌫ keeps its text-field meaning (delete to the
    /// start of the line) instead of removing a project.
    func test_commandDelete_withQuery_editsTheQuery() {
        panel.present(records: records, openPaths: [], over: nil)
        searchField().stringValue = "a"

        XCTAssertFalse(sendCommandDelete())

        XCTAssertEqual(removed, [])
    }

    func test_commandDelete_onOpenProject_removesNothing() {
        panel.present(records: records, openPaths: ["/p/alpha"], over: nil)

        _ = sendCommandDelete()

        XCTAssertEqual(removed, [])
        XCTAssertEqual(visibleLabels(), ["alpha", "beta", "gamma"])
    }

    /// The footer opens the remote-project sheet. The panel steps aside first
    /// so the sheet lands on the main window.
    func test_newRemoteProjectButton_closesThePanelAndReports() throws {
        var tapped = 0
        panel.onNewRemoteProject = { tapped += 1 }
        panel.present(records: records, openPaths: [], over: nil)

        let button = try XCTUnwrap(descendants(of: panel.contentView!, as: NSButton.self)
            .first { $0.title == "New Remote Project…" })
        button.performClick(nil)

        XCTAssertEqual(tapped, 1)
        XCTAssertFalse(panel.isVisible)
    }

    /// A remote project's row reads `app@bdpc01` over `bdpc01:/srv/app`, and
    /// its trash hides while one of its panes is open (the key is the
    /// project key, not a local path).
    func test_remoteProjectRow() throws {
        let remote = RemoteProject.record(machine: "bdpc01", folder: "/srv/app", now: Date(timeIntervalSince1970: 4_000))
        panel.present(records: [remote] + records, openPaths: ["bdpc01:/srv/app"], over: nil)

        XCTAssertEqual(visibleLabels(), ["app@bdpc01", "alpha", "beta", "gamma"])
        XCTAssertEqual(try XCTUnwrap(removeButton(row: 0)).isHidden, true)
        let texts = descendants(of: try XCTUnwrap(cell(row: 0)), as: NSTextField.self).map(\.stringValue)
        XCTAssertTrue(texts.contains("bdpc01:/srv/app"), "the path line shows machine:folder, got \(texts)")
    }

    /// Hiding or closing the panel must not take away the host's last window:
    /// the test host then quits, and run alone this class lost every second
    /// test. An invisible titled window stays open for the run.
    private static var sentinel: NSWindow?
    private static func keepAWindowOpen() {
        guard sentinel == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 40, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFront(nil)
        sentinel = window
    }

    // MARK: - View lookup

    private func table() -> NSTableView {
        descendants(of: panel.contentView!, as: NSTableView.self)[0]
    }

    private func searchField() -> NSTextField {
        descendants(of: panel.contentView!, as: NSTextField.self).first { $0.isEditable }!
    }

    private func cell(row: Int) -> NSView? {
        table().view(atColumn: 0, row: row, makeIfNecessary: true)
    }

    private func removeButton(row: Int) -> NSButton? {
        cell(row: row).flatMap { descendants(of: $0, as: NSButton.self).first }
    }

    /// Project label of each row, read from the row's VoiceOver label
    /// ("<label>, at <path>, …").
    private func visibleLabels() -> [String] {
        (0..<table().numberOfRows).map { label(of: cell(row: $0)) }
    }

    private func selectedLabel() -> String {
        label(of: cell(row: table().selectedRow))
    }

    private func label(of cell: NSView?) -> String {
        String(cell?.accessibilityLabel()?.split(separator: ",").first ?? "")
    }

    private func sendCommandDelete() -> Bool {
        let field = searchField()
        return field.delegate?.control?(field, textView: NSTextView(),
                                        doCommandBy: #selector(NSResponder.deleteToBeginningOfLine(_:))) ?? false
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { sub -> [T] in
            ((sub as? T).map { [$0] } ?? []) + descendants(of: sub, as: type)
        }
    }
}

import XCTest
@testable import termy

@MainActor
final class MarkdownPreviewManagerTests: XCTestCase {
    private var manager: MarkdownPreviewManager!
    private var dir: URL!
    /// The app delegate quits when the last visible window closes, which
    /// would end the test host mid-run; this keeps one window up for the
    /// whole run (closing it would trigger the same quit).
    private static let sentinel: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }()

    override func setUp() async throws {
        manager = MarkdownPreviewManager(
            defaults: UserDefaults(suiteName: "MarkdownPreviewManagerTests-\(UUID().uuidString)")!
        )
        Self.sentinel.orderFront(nil)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        manager.closeAll()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_openingSameFileTwiceReusesWindow() throws {
        let url = try makeFile("a.md")
        let first = manager.open(url)
        let second = manager.open(url)
        XCTAssertTrue(first === second)
        XCTAssertEqual(manager.controllers.count, 1)
    }

    func test_symlinkAndDotPathsShareWindow() throws {
        let url = try makeFile("real.md")
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        manager.open(url)
        manager.open(link)
        manager.open(URL(fileURLWithPath: dir.path + "/./real.md"))
        XCTAssertEqual(manager.controllers.count, 1)
    }

    func test_differentFilesGetSeparateWindows() throws {
        manager.open(try makeFile("a.md"))
        manager.open(try makeFile("b.md"))
        XCTAssertEqual(manager.controllers.count, 2)
    }

    func test_closingWindowForgetsIt() throws {
        let controller = manager.open(try makeFile("a.md"))
        controller.close()
        XCTAssertTrue(manager.controllers.isEmpty)
    }

    func test_closeAllClosesEverything() throws {
        manager.open(try makeFile("a.md"))
        manager.open(try makeFile("b.md"))
        manager.closeAll()
        XCTAssertTrue(manager.controllers.isEmpty)
    }

    func test_isPreviewWindow() throws {
        let controller = manager.open(try makeFile("a.md"))
        XCTAssertTrue(MarkdownPreviewManager.isPreviewWindow(controller.window))
        XCTAssertFalse(MarkdownPreviewManager.isPreviewWindow(NSWindow()))
        XCTAssertFalse(MarkdownPreviewManager.isPreviewWindow(nil))
    }
}

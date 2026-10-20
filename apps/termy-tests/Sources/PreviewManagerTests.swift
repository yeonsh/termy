import XCTest
@testable import termy

@MainActor
final class PreviewManagerTests: XCTestCase {
    private var manager: PreviewManager!
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
        // In memory, so runs don't leave plists in ~/Library/Preferences.
        manager = PreviewManager(defaults: InMemoryUserDefaults())
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

    private func makePDF(_ name: String) throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data as CFMutableData)), mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let url = dir.appendingPathComponent(name)
        try (data as Data).write(to: url)
        return url
    }

    func test_openingSameFileTwiceReusesWindow() throws {
        let url = try makeFile("a.md")
        let first = try XCTUnwrap(manager.open(url))
        let second = try XCTUnwrap(manager.open(url))
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
        let controller = try XCTUnwrap(manager.open(try makeFile("a.md")))
        controller.close()
        XCTAssertTrue(manager.controllers.isEmpty)
    }

    func test_closeAllClosesEverything() throws {
        manager.open(try makeFile("a.md"))
        manager.open(try makeFile("b.md"))
        manager.closeAll()
        XCTAssertTrue(manager.controllers.isEmpty)
    }

    func test_centeredFrame_centersInVisibleFrame() {
        XCTAssertEqual(
            PreviewManager.centeredFrame(
                size: NSSize(width: 800, height: 600),
                in: NSRect(x: 3840, y: 100, width: 1600, height: 1000)
            ),
            NSRect(x: 4240, y: 300, width: 800, height: 600)
        )
    }

    /// A window taller or wider than the screen keeps its title bar reachable.
    func test_centeredFrame_keepsTopLeftOnScreenWhenTooBig() {
        XCTAssertEqual(
            PreviewManager.centeredFrame(
                size: NSSize(width: 1600, height: 932),
                in: NSRect(x: 0, y: 0, width: 1440, height: 875)
            ),
            NSRect(x: 0, y: -57, width: 1600, height: 932)
        )
    }

    func test_firstPreviewIsCenteredOnTheClickedWindowsScreen() throws {
        let screen = try XCTUnwrap(NSApp.keyWindow?.screen ?? NSScreen.main)
        let window = try XCTUnwrap(manager.open(try makeFile("a.md"))?.window)
        XCTAssertEqual(
            window.frame,
            PreviewManager.centeredFrame(size: window.frame.size, in: screen.visibleFrame)
        )
    }

    /// The cascade follows the newest preview that is still open, not a
    /// point left over from one already closed.
    func test_newPreviewCascadesFromNewestOpenPreview() throws {
        let a = try XCTUnwrap(manager.open(try makeFile("a.md"))?.window)
        let bController = try XCTUnwrap(manager.open(try makeFile("b.md")))
        let b = try XCTUnwrap(bController.window)
        XCTAssertGreaterThan(b.frame.minX, a.frame.minX)
        XCTAssertLessThan(b.frame.maxY, a.frame.maxY)

        let bFrame = b.frame
        bController.close()
        let c = try XCTUnwrap(manager.open(try makeFile("c.md"))?.window)
        XCTAssertEqual(c.frame, bFrame)
    }

    func test_isPreviewWindow() throws {
        let controller = try XCTUnwrap(manager.open(try makeFile("a.md")))
        XCTAssertTrue(PreviewManager.isPreviewWindow(controller.window))
        XCTAssertFalse(PreviewManager.isPreviewWindow(NSWindow()))
        XCTAssertFalse(PreviewManager.isPreviewWindow(nil))
    }

    func test_openingPdfShowsPdfPreview() throws {
        let controller = try XCTUnwrap(manager.open(try makePDF("report.pdf")))
        XCTAssertTrue(controller is PDFPreviewWindowController)
    }

    func test_openingSamePdfTwiceReusesWindow() throws {
        let url = try makePDF("report.pdf")
        let first = try XCTUnwrap(manager.open(url))
        let second = try XCTUnwrap(manager.open(url))
        XCTAssertTrue(first === second)
        XCTAssertEqual(manager.controllers.count, 1)
    }

    func test_markdownAndPdfShareCascadeAndCloseAll() throws {
        let a = try XCTUnwrap(manager.open(try makeFile("a.md"))?.window)
        let b = try XCTUnwrap(manager.open(try makePDF("b.pdf"))?.window)
        XCTAssertGreaterThan(b.frame.minX, a.frame.minX)
        XCTAssertLessThan(b.frame.maxY, a.frame.maxY)
        manager.closeAll()
        XCTAssertTrue(manager.controllers.isEmpty)
    }

    func test_isPreviewWindow_pdf() throws {
        let controller = try XCTUnwrap(manager.open(try makePDF("report.pdf")))
        XCTAssertTrue(PreviewManager.isPreviewWindow(controller.window))
    }

    func test_unknownKindOpensNothing() throws {
        XCTAssertNil(manager.open(try makeFile("notes.txt")))
        XCTAssertTrue(manager.controllers.isEmpty)
    }
}

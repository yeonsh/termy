import XCTest
import WebKit
@testable import termy

/// Stands in for AppKit's dragging info so the web view's drop overrides
/// can be driven directly; only the pasteboard matters to them.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    @MainActor
    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

@MainActor
final class MarkdownPreviewWebViewTests: XCTestCase {
    private var dir: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("termy-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func drag(_ urls: [URL]) -> FakeDraggingInfo {
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return FakeDraggingInfo(pasteboard: pasteboard)
    }

    private func makeWebView() -> MarkdownPreviewWebView {
        MarkdownPreviewWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: WKWebViewConfiguration())
    }

    // MARK: previewFiles(in:isRegularFile:)

    func test_markdownFiles_keepsExistingMarkdownFilesOnly() {
        let existing: Set<String> = ["/proj/a.md", "/proj/b.txt", "/proj/c d.markdown"]
        let result = MarkdownPreviewWebView.previewFiles(
            in: [
                URL(fileURLWithPath: "/proj/a.md"),
                URL(fileURLWithPath: "/proj/b.txt"),
                URL(fileURLWithPath: "/proj/missing.md"),
                URL(fileURLWithPath: "/proj/c d.markdown"),
                URL(string: "https://example.com/README.md")!,
            ],
            isRegularFile: { existing.contains($0) }
        )
        XCTAssertEqual(result, [
            URL(fileURLWithPath: "/proj/a.md").resolvingSymlinksInPath(),
            URL(fileURLWithPath: "/proj/c d.markdown").resolvingSymlinksInPath(),
        ])
    }

    // MARK: drop handling

    func test_droppingMarkdownFileOpensIt() throws {
        let file = try makeFile("spec.md")
        let webView = makeWebView()
        var opened: [URL] = []
        webView.onDropPreviewFiles = { opened += $0 }

        let info = drag([file])
        XCTAssertEqual(webView.draggingEntered(info), .copy)
        XCTAssertEqual(webView.draggingUpdated(info), .copy)
        XCTAssertTrue(webView.performDragOperation(info))
        XCTAssertEqual(opened, [file.resolvingSymlinksInPath()])
    }

    func test_droppingOnlyNonMarkdownFilesIsRefused() throws {
        let file = try makeFile("notes.txt")
        let webView = makeWebView()
        var opened: [URL] = []
        webView.onDropPreviewFiles = { opened += $0 }

        let info = drag([file])
        XCTAssertEqual(webView.draggingEntered(info), [])
        XCTAssertFalse(webView.performDragOperation(info))
        XCTAssertEqual(opened, [])
    }

    func test_mixedDropOpensOnlyTheMarkdownFiles() throws {
        let markdown = try makeFile("plan.md")
        let text = try makeFile("log.txt")
        let webView = makeWebView()
        var opened: [URL] = []
        webView.onDropPreviewFiles = { opened += $0 }

        XCTAssertTrue(webView.performDragOperation(drag([text, markdown])))
        XCTAssertEqual(opened, [markdown.resolvingSymlinksInPath()])
    }

    // MARK: controller wiring

    func test_previewControllerUsesDropHandlingWebView() throws {
        let file = try makeFile("spec.md")
        let controller = MarkdownPreviewWindowController(fileURL: file, defaults: InMemoryUserDefaults())
        defer { controller.close() }
        XCTAssertNotNil(controller.webView.onDropPreviewFiles)
    }
}

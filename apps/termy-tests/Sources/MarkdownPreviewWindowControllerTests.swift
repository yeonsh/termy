import XCTest
import WebKit
@testable import termy

@MainActor
final class MarkdownPreviewWindowControllerTests: XCTestCase {
    private let document = URL(fileURLWithPath: "/proj/docs/spec.md")

    private func route(
        _ type: WKNavigationType,
        _ string: String?,
        existing: Set<String> = []
    ) -> MarkdownPreviewWindowController.LinkRoute {
        MarkdownPreviewWindowController.route(
            navigationType: type,
            url: string.flatMap { URL(string: $0) },
            documentURL: document,
            isRegularFile: { existing.contains($0) }
        )
    }

    /// In memory, so runs don't leave plists in ~/Library/Preferences.
    private func makeDefaults() -> UserDefaults {
        InMemoryUserDefaults()
    }

    /// Reload would load the base URL itself: the raw `.md` as plain text.
    func test_route_allowsOwnLoadsAndCancelsReload() {
        XCTAssertEqual(route(.other, "file:///proj/docs/spec.md"), .allow)
        XCTAssertEqual(route(.reload, "file:///proj/docs/spec.md"), .cancel)
    }

    /// WebKit files the context menu's Open Link and drops under `.other`
    /// too; those must not navigate the preview away from the document.
    func test_route_routesOtherNavigationsLikeClicks() {
        XCTAssertEqual(route(.other, "https://example.com/a"), .openExternally(URL(string: "https://example.com/a")!))
        XCTAssertEqual(
            route(.other, "file:///proj/docs/plan.md", existing: ["/proj/docs/plan.md"]),
            .preview(URL(fileURLWithPath: "/proj/docs/plan.md").resolvingSymlinksInPath())
        )
        XCTAssertEqual(route(.other, "file:///etc/hosts", existing: ["/etc/hosts"]), .cancel)
        XCTAssertEqual(route(.other, nil), .cancel)
    }

    func test_route_sendsWebLinksToBrowser() {
        XCTAssertEqual(route(.linkActivated, "https://example.com/a"), .openExternally(URL(string: "https://example.com/a")!))
        XCTAssertEqual(route(.linkActivated, "http://example.com"), .openExternally(URL(string: "http://example.com")!))
        XCTAssertEqual(route(.linkActivated, "mailto:a@b.c"), .openExternally(URL(string: "mailto:a@b.c")!))
    }

    func test_route_allowsInPageAnchor() {
        XCTAssertEqual(route(.linkActivated, "file:///proj/docs/spec.md#goals"), .allow)
    }

    func test_route_opensOtherMarkdownFileInPreview() {
        XCTAssertEqual(
            route(.linkActivated, "file:///proj/docs/plan.md#task-1", existing: ["/proj/docs/plan.md"]),
            .preview(URL(fileURLWithPath: "/proj/docs/plan.md").resolvingSymlinksInPath())
        )
    }

    func test_route_cancelsEverythingElse() {
        XCTAssertEqual(route(.linkActivated, "file:///proj/docs/missing.md"), .cancel)
        XCTAssertEqual(route(.linkActivated, "file:///proj/src/main.swift", existing: ["/proj/src/main.swift"]), .cancel)
        XCTAssertEqual(route(.linkActivated, "javascript:alert(1)"), .cancel)
        XCTAssertEqual(route(.formSubmitted, "file:///proj/docs/spec.md"), .cancel)
        XCTAssertEqual(route(.backForward, "file:///proj/docs/spec.md"), .cancel)
        XCTAssertEqual(route(.linkActivated, nil), .cancel)
    }

    func test_savedContentSize() {
        let defaults = makeDefaults()
        let key = MarkdownPreviewWindowController.contentSizeDefaultsKey
        XCTAssertEqual(
            MarkdownPreviewWindowController.savedContentSize(defaults: defaults),
            MarkdownPreviewWindowController.defaultContentSize
        )
        defaults.set(NSStringFromSize(NSSize(width: 600, height: 700)), forKey: key)
        XCTAssertEqual(MarkdownPreviewWindowController.savedContentSize(defaults: defaults), NSSize(width: 600, height: 700))
        defaults.set("garbage", forKey: key)
        XCTAssertEqual(
            MarkdownPreviewWindowController.savedContentSize(defaults: defaults),
            MarkdownPreviewWindowController.defaultContentSize
        )
    }

    func test_decodeMarkdown_toleratesInvalidUTF8() {
        let data = Data("# 제목 ".utf8) + Data([0xFF, 0xFE]) + Data(" end".utf8)
        let text = MarkdownPreviewWindowController.decodeMarkdown(data)
        XCTAssertTrue(text.hasPrefix("# 제목 "), text)
        XCTAssertTrue(text.hasSuffix(" end"), text)
    }

    func test_windowShowsFileNameAndDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("spec.md")
        try "# Hi\n".write(to: url, atomically: true, encoding: .utf8)

        let controller = MarkdownPreviewWindowController(fileURL: url, defaults: makeDefaults())
        defer { controller.close() }
        XCTAssertEqual(controller.window?.title, "spec.md")
        XCTAssertEqual(controller.window?.subtitle, (dir.path as NSString).abbreviatingWithTildeInPath)
        XCTAssertEqual(controller.window?.representedURL, url)
    }

    /// Force Touch link previews load the target outside `decidePolicyFor`.
    func test_webViewHasNoLinkPreview() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("spec.md")
        try "# Hi\n".write(to: url, atomically: true, encoding: .utf8)

        let controller = MarkdownPreviewWindowController(fileURL: url, defaults: makeDefaults())
        defer { controller.close() }
        XCTAssertFalse(controller.webView.allowsLinkPreview)
    }

    // MARK: - Show in Finder

    /// `spec.md` in a fresh temp folder.
    private func makeMarkdownFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("spec.md")
        try "# Hi\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_finderReveal_selectsFileAndFallsBackToItsFolder() {
        func reveal(existing: Set<String>) -> MarkdownPreviewWindowController.FinderReveal? {
            MarkdownPreviewWindowController.finderReveal(for: document, exists: { existing.contains($0) })
        }
        XCTAssertEqual(reveal(existing: ["/proj/docs/spec.md", "/proj/docs"]), .selectFile(document))
        // Deleted while previewed: the folder it lived in.
        XCTAssertEqual(reveal(existing: ["/proj/docs"]), .openFolder(URL(fileURLWithPath: "/proj/docs", isDirectory: true)))
        XCTAssertNil(reveal(existing: []))
    }

    func test_contextMenuEndsWithShowInFinder() throws {
        let url = try makeMarkdownFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = MarkdownPreviewWindowController(fileURL: url, defaults: makeDefaults())
        defer { controller.close() }

        let menu = NSMenu()
        menu.addItem(withTitle: "Reload", action: nil, keyEquivalent: "")
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        controller.webView.willOpenMenu(menu, with: event)

        XCTAssertEqual(menu.items.first?.title, "Reload")
        let item = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(item.title, "Show in Finder")
        XCTAssertEqual(item.action, #selector(MarkdownPreviewWindowController.showInFinder(_:)))
        XCTAssertTrue(item.target === controller)
    }

    /// A preview outlives its file; once the folder is gone too there is
    /// nothing left to show.
    func test_showInFinderDisabledOnceFolderIsGone() throws {
        let url = try makeMarkdownFile()
        let controller = MarkdownPreviewWindowController(fileURL: url, defaults: makeDefaults())
        defer { controller.close() }
        let item = NSMenuItem(
            title: "Show in Finder",
            action: #selector(MarkdownPreviewWindowController.showInFinder(_:)),
            keyEquivalent: ""
        )
        XCTAssertTrue(controller.validateMenuItem(item))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        XCTAssertFalse(controller.validateMenuItem(item))
    }

    // MARK: - Live reload

    /// The app delegate quits when the last visible window closes; keep one up.
    private static let sentinel: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }()

    private func eval(_ controller: MarkdownPreviewWindowController, _ js: String) async -> Any? {
        (try? await controller.webView.callAsyncJavaScript(js, contentWorld: .defaultClient)) ?? nil
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func longMarkdown(version: Int) -> String {
        "# VERSION-\(version)\n\n" + (1...300).map { "Paragraph \($0) of the long document.\n" }.joined(separator: "\n")
    }

    func test_liveReload_keepsScrollPositionAndShowsNewestContent() async throws {
        Self.sentinel.orderFront(nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("long.md")
        try longMarkdown(version: 1).write(to: url, atomically: true, encoding: .utf8)

        let controller = MarkdownPreviewWindowController(fileURL: url, defaults: makeDefaults())
        defer { controller.close() }
        controller.window?.orderFront(nil)

        let loaded = await waitUntil { (await self.eval(controller, "return document.body.innerText.includes('VERSION-1');") as? Bool) == true }
        XCTAssertTrue(loaded, "first load")
        _ = await eval(controller, "window.scrollTo(0, 2000);")
        let scrolled = await waitUntil { abs(((await self.eval(controller, "return window.scrollY;")) as? Double ?? 0) - 2000) < 2 }
        XCTAssertTrue(scrolled, "scrolled to 2000")

        try longMarkdown(version: 2).write(to: url, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 200_000_000)
        try longMarkdown(version: 3).write(to: url, atomically: true, encoding: .utf8)

        let showsNewest = await waitUntil { (await self.eval(controller, "return document.body.innerText.includes('VERSION-3');") as? Bool) == true }
        XCTAssertTrue(showsNewest, "newest content")
        let restored = await waitUntil { abs(((await self.eval(controller, "return window.scrollY;")) as? Double ?? 0) - 2000) < 2 }
        XCTAssertTrue(restored, "scroll restored")
        // Stays put once things settle.
        try await Task.sleep(nanoseconds: 500_000_000)
        let finalY = await eval(controller, "return window.scrollY;") as? Double ?? -1
        XCTAssertEqual(finalY, 2000, accuracy: 2)
    }
}

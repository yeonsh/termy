import XCTest
import PDFKit
@testable import termy

@MainActor
final class PDFPreviewWindowControllerTests: XCTestCase {
    /// A `pages`-page US Letter PDF. CoreGraphics ends it with `%%EOF`.
    private func makePDFData(pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Bytes after `%%EOF` that push it out of the last 1024.
    private let trailingNewlines = Data(repeating: UInt8(ascii: "\n"), count: 2000)

    /// `report.pdf` holding `data`, in a fresh temp folder removed after the test.
    private func makeReport(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("report.pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Truncates and rewrites the same file, the way some generators do.
    private func writeInPlace(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }

    // MARK: - Completeness

    func test_hasEndMarker() {
        let complete = makePDFData(pages: 2)
        XCTAssertTrue(PDFPreviewWindowController.hasEndMarker(complete))
        XCTAssertFalse(PDFPreviewWindowController.hasEndMarker(complete.dropLast(20)))
        XCTAssertFalse(PDFPreviewWindowController.hasEndMarker(complete + trailingNewlines), "marker outside the last 1024 bytes")
    }

    func test_documentFromData() {
        let complete = makePDFData(pages: 2)
        XCTAssertEqual(PDFPreviewWindowController.document(from: complete, requireEndMarker: true)?.pageCount, 2)
        XCTAssertNil(PDFPreviewWindowController.document(from: complete.prefix(complete.count / 2), requireEndMarker: true))
        let garbage = Data("not a pdf".utf8)
        XCTAssertNil(PDFPreviewWindowController.document(from: garbage, requireEndMarker: true))
        XCTAssertNil(PDFPreviewWindowController.document(from: garbage, requireEndMarker: false))
        let padded = complete + trailingNewlines
        XCTAssertNil(PDFPreviewWindowController.document(from: padded, requireEndMarker: true))
        XCTAssertEqual(PDFPreviewWindowController.document(from: padded, requireEndMarker: false)?.pageCount, 2)
    }

    // MARK: - Window

    /// The app delegate quits when the last visible window closes; keep one up.
    private static let sentinel: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }()

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// An on-screen preview of `url`; PDFView only tracks its page once laid out.
    private func openPreview(
        _ url: URL,
        defaults: UserDefaults = InMemoryUserDefaults(),
        settleInterval: TimeInterval = PDFPreviewWindowController.defaultSettleInterval
    ) -> PDFPreviewWindowController {
        Self.sentinel.orderFront(nil)
        let controller = PDFPreviewWindowController(fileURL: url, defaults: defaults, settleInterval: settleInterval)
        controller.window?.orderFront(nil)
        return controller
    }

    func test_windowShowsFileNameAndDirectory() throws {
        let url = try makeReport(makePDFData(pages: 1))
        let controller = openPreview(url)
        defer { controller.close() }
        XCTAssertEqual(controller.window?.title, "report.pdf")
        XCTAssertEqual(controller.window?.subtitle, (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        XCTAssertEqual(controller.window?.representedURL, url)
        XCTAssertEqual(controller.window?.tabbingMode, .disallowed)
    }

    func test_pdfViewSettings() throws {
        let url = try makeReport(makePDFData(pages: 1))
        let controller = openPreview(url)
        defer { controller.close() }
        XCTAssertTrue(controller.pdfView.autoScales)
        XCTAssertEqual(controller.pdfView.displayMode, .singlePageContinuous)
        XCTAssertTrue(controller.pdfView.displaysPageBreaks)
    }

    func test_savedContentSize() {
        let defaults = InMemoryUserDefaults()
        let key = PDFPreviewWindowController.contentSizeDefaultsKey
        XCTAssertEqual(PreviewWindowSupport.savedContentSize(defaults: defaults, key: key), NSSize(width: 820, height: 900))
        defaults.set("{200, 100}", forKey: key)
        XCTAssertEqual(PreviewWindowSupport.savedContentSize(defaults: defaults, key: key), NSSize(width: 820, height: 900))
        defaults.set("{1000, 700}", forKey: key)
        XCTAssertEqual(PreviewWindowSupport.savedContentSize(defaults: defaults, key: key), NSSize(width: 1000, height: 700))
    }

    func test_closingStoresContentSizeUnderPDFKey() throws {
        let url = try makeReport(makePDFData(pages: 1))
        let defaults = InMemoryUserDefaults()
        let controller = openPreview(url, defaults: defaults)
        controller.close()
        XCTAssertNotNil(defaults.string(forKey: "PDFPreview.contentSize"))
        XCTAssertNil(defaults.string(forKey: "MarkdownPreview.contentSize"))
    }

    // MARK: - Loading

    func test_firstLoad_showsDocument() throws {
        let url = try makeReport(makePDFData(pages: 6))
        let controller = openPreview(url)
        defer { controller.close() }
        XCTAssertEqual(controller.pdfView.document?.pageCount, 6)
        XCTAssertNil(controller.bannerText)
    }

    /// No banner while the file might still be mid-write.
    func test_firstLoad_unreadableFileShowsBannerAfterSettling() async throws {
        let url = try makeReport(Data("not a pdf".utf8))
        let controller = openPreview(url, settleInterval: 0.3)
        defer { controller.close() }
        XCTAssertNil(controller.bannerText)
        XCTAssertNil(controller.pdfView.document)
        let shown = await waitUntil { controller.bannerText == "Couldn't read this PDF." }
        XCTAssertTrue(shown, "unreadable banner, got \(controller.bannerText ?? "nil")")
    }

    func test_firstLoad_readErrorShowsReadBanner() throws {
        let url = try makeReport(makePDFData(pages: 6))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let controller = openPreview(url)
        defer { controller.close() }
        XCTAssertTrue(controller.bannerText?.hasPrefix("Couldn't read this file: ") == true, controller.bannerText ?? "nil")
    }

    // MARK: - Reloading

    /// Scrolls to page 3 (0-based) and waits until PDFView reports it.
    private func showPage3(of controller: PDFPreviewWindowController) async throws {
        let page = try XCTUnwrap(controller.pdfView.document?.page(at: 3))
        controller.pdfView.go(to: page)
        let onPage = await waitUntil { controller.currentPageIndex == 3 }
        XCTAssertTrue(onPage, "on page 3, got \(String(describing: controller.currentPageIndex))")
    }

    func test_reload_swapsCompleteVersionAndKeepsPage() async throws {
        let url = try makeReport(makePDFData(pages: 6))
        let controller = openPreview(url)
        defer { controller.close() }
        try await showPage3(of: controller)
        try makePDFData(pages: 7).write(to: url, options: .atomic)
        let swapped = await waitUntil { controller.pdfView.document?.pageCount == 7 }
        XCTAssertTrue(swapped, "7-page version")
        XCTAssertEqual(controller.currentPageIndex, 3)
        XCTAssertNil(controller.bannerText)
    }

    func test_reload_clampsToLastPageWhenShorter() async throws {
        let url = try makeReport(makePDFData(pages: 6))
        let controller = openPreview(url)
        defer { controller.close() }
        try await showPage3(of: controller)
        try makePDFData(pages: 2).write(to: url, options: .atomic)
        let swapped = await waitUntil { controller.pdfView.document?.pageCount == 2 }
        XCTAssertTrue(swapped, "2-page version")
        XCTAssertEqual(controller.currentPageIndex, 1)
    }

    func test_reload_keepsZoomWhenNotAutoScaling() async throws {
        let url = try makeReport(makePDFData(pages: 6))
        let controller = openPreview(url)
        defer { controller.close() }
        controller.pdfView.autoScales = false
        controller.pdfView.scaleFactor = 1.7
        try makePDFData(pages: 7).write(to: url, options: .atomic)
        let swapped = await waitUntil { controller.pdfView.document?.pageCount == 7 }
        XCTAssertTrue(swapped, "7-page version")
        XCTAssertFalse(controller.pdfView.autoScales)
        XCTAssertEqual(controller.pdfView.scaleFactor, 1.7, accuracy: 0.01)
    }

    /// Review Focus 1: a truncated rewrite must not replace what the reader
    /// sees until the whole file is back.
    func test_reload_inPlaceTruncateThenRewrite_keepsPreviousThenSwaps() async throws {
        let url = try makeReport(makePDFData(pages: 6))
        let controller = openPreview(url, settleInterval: 5)
        defer { controller.close() }
        let next = makePDFData(pages: 7)
        try writeInPlace(next.prefix(next.count / 2), to: url)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(controller.pdfView.document?.pageCount, 6)
        XCTAssertNil(controller.bannerText)

        try writeInPlace(next, to: url)
        let swapped = await waitUntil { controller.pdfView.document?.pageCount == 7 }
        XCTAssertTrue(swapped, "7-page version")
        XCTAssertNil(controller.bannerText)
    }

    func test_reload_unreadableAfterSettling_showsStaleBannerThenClears() async throws {
        let url = try makeReport(makePDFData(pages: 6))
        let controller = openPreview(url, settleInterval: 0.3)
        defer { controller.close() }
        try Data("broken".utf8).write(to: url, options: .atomic)
        let stale = await waitUntil { controller.bannerText == "Couldn't read the new version. Showing the previous one." }
        XCTAssertTrue(stale, "stale banner, got \(controller.bannerText ?? "nil")")
        XCTAssertEqual(controller.pdfView.document?.pageCount, 6)

        try makePDFData(pages: 7).write(to: url, options: .atomic)
        let swapped = await waitUntil { controller.pdfView.document?.pageCount == 7 }
        XCTAssertTrue(swapped, "7-page version")
        XCTAssertNil(controller.bannerText)
    }

    /// Junk after `%%EOF` only delays the swap until the file settles.
    func test_reload_endMarkerlessButParseableIsShownAfterSettling() async throws {
        let url = try makeReport(makePDFData(pages: 6))
        let controller = openPreview(url, settleInterval: 0.3)
        defer { controller.close() }
        try (makePDFData(pages: 7) + trailingNewlines).write(to: url, options: .atomic)
        let swapped = await waitUntil { controller.pdfView.document?.pageCount == 7 }
        XCTAssertTrue(swapped, "7-page version")
        XCTAssertNil(controller.bannerText)
    }

    /// The file counts as settled only once it stops changing.
    func test_reload_newEventRestartsSettleWait() async throws {
        let url = try makeReport(makePDFData(pages: 6))
        let controller = openPreview(url, settleInterval: 1.0)
        defer { controller.close() }
        try Data("broken-1".utf8).write(to: url, options: .atomic)
        try await Task.sleep(nanoseconds: 600_000_000)
        try Data("broken-two".utf8).write(to: url, options: .atomic)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(controller.bannerText, "1.2 s after the first write, 0.6 s after the second")

        let stale = await waitUntil { controller.bannerText == PDFPreviewWindowController.staleBanner }
        XCTAssertTrue(stale, "stale banner, got \(controller.bannerText ?? "nil")")
    }

    func test_deleted_showsDeletedBannerThenReloadsWhenRecreated() async throws {
        let url = try makeReport(makePDFData(pages: 6))
        let controller = openPreview(url)
        defer { controller.close() }
        try FileManager.default.removeItem(at: url)
        let deleted = await waitUntil { controller.bannerText == MarkdownPreviewWindowController.deletedBanner }
        XCTAssertTrue(deleted, "deleted banner, got \(controller.bannerText ?? "nil")")
        XCTAssertEqual(controller.pdfView.document?.pageCount, 6)

        try makePDFData(pages: 7).write(to: url, options: .atomic)
        let swapped = await waitUntil { controller.pdfView.document?.pageCount == 7 }
        XCTAssertTrue(swapped, "7-page version")
        XCTAssertNil(controller.bannerText)
    }

    // MARK: - Links and Finder

    func test_linkRoute_sendsWebLinksToBrowser() {
        for text in ["https://example.com/a", "http://x.org", "mailto:a@b.c"] {
            let url = URL(string: text)!
            XCTAssertEqual(PDFPreviewWindowController.linkRoute(for: url, isRegularFile: { _ in false }), .openExternally(url), text)
        }
    }

    func test_linkRoute_opensMarkdownFileInPreview() {
        XCTAssertEqual(
            PDFPreviewWindowController.linkRoute(for: URL(string: "file:///proj/docs/a.md")!, isRegularFile: { $0 == "/proj/docs/a.md" }),
            .preview(URL(fileURLWithPath: "/proj/docs/a.md").resolvingSymlinksInPath())
        )
    }

    func test_linkRoute_opensPdfFileInPreview() {
        XCTAssertEqual(
            PDFPreviewWindowController.linkRoute(for: URL(string: "file:///proj/out/other.pdf")!, isRegularFile: { $0 == "/proj/out/other.pdf" }),
            .preview(URL(fileURLWithPath: "/proj/out/other.pdf").resolvingSymlinksInPath())
        )
    }

    func test_linkRoute_ignoresAppsScriptsAndMissingFiles() {
        let existing: Set<String> = ["/Applications/Calculator.app", "/proj/run.command"]
        for text in [
            "file:///Applications/Calculator.app", "file:///proj/run.command", "file:///proj/none.pdf",
            "other.pdf", "ftp://x/y", "javascript:alert(1)",
        ] {
            let url = URL(string: text)!
            XCTAssertEqual(PDFPreviewWindowController.linkRoute(for: url, isRegularFile: { existing.contains($0) }), .ignore, text)
        }
    }

    func test_pdfViewDelegateIsController() throws {
        let controller = openPreview(try makeReport(makePDFData(pages: 1)))
        defer { controller.close() }
        XCTAssertTrue(controller.pdfView.delegate === controller)
    }

    func test_contextMenuEndsWithShowInFinder() throws {
        let controller = openPreview(try makeReport(makePDFData(pages: 1)))
        defer { controller.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try XCTUnwrap(controller.pdfView.menu(for: event))
        let item = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(item.title, "Show in Finder")
        XCTAssertEqual(item.action, #selector(PDFPreviewWindowController.showInFinder(_:)))
        XCTAssertTrue(item.target === controller)
        if menu.items.count > 1 {
            XCTAssertTrue(menu.items[menu.items.count - 2].isSeparatorItem)
        }
    }

    func test_showInFinderDisabledOnceFolderIsGone() throws {
        let url = try makeReport(makePDFData(pages: 1))
        let controller = openPreview(url)
        defer { controller.close() }
        let item = NSMenuItem(
            title: "Show in Finder",
            action: #selector(PDFPreviewWindowController.showInFinder(_:)),
            keyEquivalent: ""
        )
        XCTAssertTrue(controller.validateMenuItem(item))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        XCTAssertFalse(controller.validateMenuItem(item))
    }
}

import XCTest
@testable import termy

@MainActor
final class ImagePreviewWindowControllerTests: XCTestCase {
    /// A `width`×`height` bitmap (1 pixel = 1 point) in `type`, filled with a
    /// pattern so truncated copies are really missing data.
    private func makeBitmap(width: Int, height: Int, type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: height)
        if let bytes = rep.bitmapData {
            for index in 0..<(rep.bytesPerRow * height) {
                bytes[index] = UInt8(truncatingIfNeeded: (index &* 31) ^ (index >> 7))
            }
        }
        return rep.representation(using: type, properties: [:])!
    }

    /// `name` holding `data`, in a fresh temp folder removed after the test.
    private func makeShot(_ data: Data, name: String = "shot.png") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Truncates and rewrites the same file, the way some tools do.
    private func writeInPlace(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }

    // MARK: - Completeness

    func test_hasEndMarker() {
        let png = makeBitmap(width: 120, height: 80, type: .png)
        XCTAssertTrue(ImagePreviewWindowController.hasEndMarker(png))
        XCTAssertFalse(ImagePreviewWindowController.hasEndMarker(png.dropLast(1)))
        XCTAssertFalse(ImagePreviewWindowController.hasEndMarker(png.prefix(png.count / 2)))
        let jpeg = makeBitmap(width: 120, height: 80, type: .jpeg)
        XCTAssertTrue(ImagePreviewWindowController.hasEndMarker(jpeg))
        XCTAssertFalse(ImagePreviewWindowController.hasEndMarker(jpeg.prefix(jpeg.count * 9 / 10)))
        let gif = makeBitmap(width: 120, height: 80, type: .gif)
        XCTAssertTrue(ImagePreviewWindowController.hasEndMarker(gif))
        XCTAssertFalse(ImagePreviewWindowController.hasEndMarker(gif.dropLast(1)))
        let bmp = makeBitmap(width: 120, height: 80, type: .bmp)
        XCTAssertTrue(ImagePreviewWindowController.hasEndMarker(bmp))
        XCTAssertFalse(ImagePreviewWindowController.hasEndMarker(bmp.prefix(bmp.count / 2)))
        // RIFF size 20 = "WEBP" + 16 payload bytes.
        var webp = Data("RIFF".utf8) + Data([20, 0, 0, 0]) + Data("WEBP".utf8) + Data(repeating: 0, count: 16)
        XCTAssertTrue(ImagePreviewWindowController.hasEndMarker(webp))
        webp.removeLast(4)
        XCTAssertFalse(ImagePreviewWindowController.hasEndMarker(webp))
        let tiff = makeBitmap(width: 120, height: 80, type: .tiff)
        XCTAssertTrue(ImagePreviewWindowController.hasEndMarker(tiff.prefix(10)), "no marker rule for TIFF")
    }

    func test_imageFromData() {
        let png = makeBitmap(width: 120, height: 80, type: .png)
        XCTAssertEqual(ImagePreviewWindowController.image(from: png, requireEndMarker: true)?.size, NSSize(width: 120, height: 80))
        XCTAssertNil(ImagePreviewWindowController.image(from: png.prefix(png.count / 2), requireEndMarker: true))
        XCTAssertNotNil(ImagePreviewWindowController.image(from: png.prefix(png.count / 2), requireEndMarker: false))
        let garbage = Data("not an image".utf8)
        XCTAssertNil(ImagePreviewWindowController.image(from: garbage, requireEndMarker: false))
        XCTAssertNil(ImagePreviewWindowController.image(from: Data(), requireEndMarker: false))
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="red"/></svg>"#.utf8)
        XCTAssertEqual(ImagePreviewWindowController.image(from: svg, requireEndMarker: true)?.size, NSSize(width: 40, height: 20))
        XCTAssertNil(ImagePreviewWindowController.image(from: svg.prefix(svg.count / 2), requireEndMarker: false))
    }

    func test_fitMagnification() {
        let view = NSSize(width: 1000, height: 1000)
        XCTAssertEqual(ImagePreviewWindowController.fitMagnification(imageSize: NSSize(width: 2000, height: 1000), viewSize: view), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ImagePreviewWindowController.fitMagnification(imageSize: NSSize(width: 1000, height: 3000), viewSize: view), 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(ImagePreviewWindowController.fitMagnification(imageSize: NSSize(width: 16, height: 16), viewSize: view), 1)
        XCTAssertEqual(ImagePreviewWindowController.fitMagnification(imageSize: .zero, viewSize: view), 1)
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

    /// An on-screen preview of `url`, laid out so `contentSize` is real.
    private func openPreview(
        _ url: URL,
        defaults: UserDefaults = InMemoryUserDefaults(),
        settleInterval: TimeInterval = ImagePreviewWindowController.defaultSettleInterval
    ) -> ImagePreviewWindowController {
        Self.sentinel.orderFront(nil)
        let controller = ImagePreviewWindowController(fileURL: url, defaults: defaults, settleInterval: settleInterval)
        controller.window?.orderFront(nil)
        controller.window?.layoutIfNeeded()
        return controller
    }

    func test_windowShowsFileNameAndDirectory() throws {
        let url = try makeShot(makeBitmap(width: 120, height: 80, type: .png))
        let controller = openPreview(url)
        defer { controller.close() }
        XCTAssertEqual(controller.window?.title, "shot.png")
        XCTAssertEqual(controller.window?.subtitle, (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        XCTAssertEqual(controller.window?.representedURL, url)
        XCTAssertEqual(controller.window?.tabbingMode, .disallowed)
    }

    func test_viewSettings() throws {
        let controller = openPreview(try makeShot(makeBitmap(width: 120, height: 80, type: .png)))
        defer { controller.close() }
        XCTAssertTrue(controller.imageView.animates)
        XCTAssertTrue(controller.scrollView.allowsMagnification)
        XCTAssertTrue(controller.scrollView.documentView === controller.imageView)
        XCTAssertTrue(controller.scrollView.contentView is CenteringClipView)
    }

    func test_closingStoresContentSizeUnderImageKey() throws {
        let url = try makeShot(makeBitmap(width: 120, height: 80, type: .png))
        let defaults = InMemoryUserDefaults()
        let controller = openPreview(url, defaults: defaults)
        controller.close()
        XCTAssertNotNil(defaults.string(forKey: "ImagePreview.contentSize"))
        XCTAssertNil(defaults.string(forKey: "PDFPreview.contentSize"))
    }

    // MARK: - First load

    func test_firstLoad_showsImage() throws {
        let controller = openPreview(try makeShot(makeBitmap(width: 120, height: 80, type: .png)))
        defer { controller.close() }
        XCTAssertEqual(controller.imageView.image?.size, NSSize(width: 120, height: 80))
        XCTAssertNil(controller.bannerText)
        XCTAssertTrue(controller.fitsWindow)
        XCTAssertEqual(controller.scrollView.magnification, 1)
    }

    func test_firstLoad_bigImageFitsWindow() throws {
        let controller = openPreview(try makeShot(makeBitmap(width: 4000, height: 3000, type: .png)))
        defer { controller.close() }
        let expected = ImagePreviewWindowController.fitMagnification(
            imageSize: NSSize(width: 4000, height: 3000), viewSize: controller.scrollView.contentSize
        )
        XCTAssertEqual(controller.scrollView.magnification, expected, accuracy: 0.001)
        XCTAssertLessThan(controller.scrollView.magnification, 1)
    }

    /// No banner while the file might still be mid-write.
    func test_firstLoad_unreadableFileShowsBannerAfterSettling() async throws {
        for (name, data) in [("shot.png", Data("not an image".utf8)), ("empty.png", Data())] {
            let controller = openPreview(try makeShot(data, name: name), settleInterval: 0.2)
            defer { controller.close() }
            XCTAssertNil(controller.bannerText)
            XCTAssertNil(controller.imageView.image)
            let shown = await waitUntil { controller.bannerText == ImagePreviewWindowController.unreadableBanner }
            XCTAssertTrue(shown, "\(name): unreadable banner, got \(controller.bannerText ?? "nil")")
        }
    }

    func test_firstLoad_readErrorShowsReadBanner() throws {
        let url = try makeShot(makeBitmap(width: 120, height: 80, type: .png))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let controller = openPreview(url)
        defer { controller.close() }
        XCTAssertTrue(controller.bannerText?.hasPrefix("Couldn't read this file: ") == true, controller.bannerText ?? "nil")
    }

    // MARK: - Reloading

    func test_reload_swapsCompleteVersion() async throws {
        let url = try makeShot(makeBitmap(width: 120, height: 80, type: .png))
        let controller = openPreview(url)
        defer { controller.close() }
        try makeBitmap(width: 200, height: 100, type: .png).write(to: url, options: .atomic)
        let swapped = await waitUntil { controller.imageView.image?.size == NSSize(width: 200, height: 100) }
        XCTAssertTrue(swapped, "200x100 version")
        XCTAssertNil(controller.bannerText)
    }

    func test_reload_inPlaceTruncateThenRewrite_keepsPreviousThenSwaps() async throws {
        let url = try makeShot(makeBitmap(width: 120, height: 80, type: .png))
        let controller = openPreview(url, settleInterval: 5)
        defer { controller.close() }
        let next = makeBitmap(width: 200, height: 100, type: .png)
        try writeInPlace(next.prefix(next.count / 2), to: url)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(controller.imageView.image?.size, NSSize(width: 120, height: 80))
        XCTAssertNil(controller.bannerText)

        try writeInPlace(next, to: url)
        let swapped = await waitUntil { controller.imageView.image?.size == NSSize(width: 200, height: 100) }
        XCTAssertTrue(swapped, "200x100 version")
        XCTAssertNil(controller.bannerText)
    }

    func test_reload_unreadableAfterSettling_showsStaleBannerThenClears() async throws {
        let url = try makeShot(makeBitmap(width: 120, height: 80, type: .png))
        let controller = openPreview(url, settleInterval: 0.3)
        defer { controller.close() }
        try Data("broken".utf8).write(to: url, options: .atomic)
        let stale = await waitUntil { controller.bannerText == ImagePreviewWindowController.staleBanner }
        XCTAssertTrue(stale, "stale banner, got \(controller.bannerText ?? "nil")")
        XCTAssertEqual(controller.imageView.image?.size, NSSize(width: 120, height: 80))

        try makeBitmap(width: 200, height: 100, type: .png).write(to: url, options: .atomic)
        let swapped = await waitUntil { controller.imageView.image?.size == NSSize(width: 200, height: 100) }
        XCTAssertTrue(swapped, "200x100 version")
        XCTAssertNil(controller.bannerText)
    }

    func test_reload_keepsManualZoom() async throws {
        let url = try makeShot(makeBitmap(width: 4000, height: 3000, type: .png))
        let controller = openPreview(url)
        defer { controller.close() }
        controller.scrollView.magnification = 2
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: controller.scrollView)
        XCTAssertFalse(controller.fitsWindow)
        try makeBitmap(width: 3000, height: 2000, type: .png).write(to: url, options: .atomic)
        let swapped = await waitUntil { controller.imageView.image?.size == NSSize(width: 3000, height: 2000) }
        XCTAssertTrue(swapped, "3000x2000 version")
        XCTAssertEqual(controller.scrollView.magnification, 2, accuracy: 0.0001)
    }

    func test_toggleFitOrActualSize() throws {
        let controller = openPreview(try makeShot(makeBitmap(width: 4000, height: 3000, type: .png)))
        defer { controller.close() }
        let fit = controller.scrollView.magnification
        XCTAssertLessThan(fit, 1)
        controller.toggleFitOrActualSize()
        XCTAssertEqual(controller.scrollView.magnification, 1, accuracy: 0.0001)
        XCTAssertFalse(controller.fitsWindow)
        controller.toggleFitOrActualSize()
        XCTAssertEqual(controller.scrollView.magnification, fit, accuracy: 0.001)
        XCTAssertTrue(controller.fitsWindow)
    }

    func test_deleted_showsDeletedBannerThenReloadsWhenRecreated() async throws {
        let url = try makeShot(makeBitmap(width: 120, height: 80, type: .png))
        let controller = openPreview(url)
        defer { controller.close() }
        try FileManager.default.removeItem(at: url)
        let deleted = await waitUntil { controller.bannerText == MarkdownPreviewWindowController.deletedBanner }
        XCTAssertTrue(deleted, "deleted banner, got \(controller.bannerText ?? "nil")")
        XCTAssertEqual(controller.imageView.image?.size, NSSize(width: 120, height: 80))

        try makeBitmap(width: 200, height: 100, type: .png).write(to: url, options: .atomic)
        let swapped = await waitUntil { controller.imageView.image?.size == NSSize(width: 200, height: 100) }
        XCTAssertTrue(swapped, "200x100 version")
        XCTAssertNil(controller.bannerText)
    }

    // MARK: - Finder

    func test_contextMenuEndsWithShowInFinder() throws {
        let controller = openPreview(try makeShot(makeBitmap(width: 120, height: 80, type: .png)))
        defer { controller.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try XCTUnwrap(controller.scrollView.menu(for: event))
        let item = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(item.title, "Show in Finder")
        XCTAssertEqual(item.action, #selector(ImagePreviewWindowController.showInFinder(_:)))
        XCTAssertTrue(item.target === controller)
        if menu.items.count > 1 {
            XCTAssertTrue(menu.items[menu.items.count - 2].isSeparatorItem)
        }
    }

    func test_showInFinderDisabledOnceFolderIsGone() throws {
        let url = try makeShot(makeBitmap(width: 120, height: 80, type: .png))
        let controller = openPreview(url)
        defer { controller.close() }
        let item = NSMenuItem(
            title: "Show in Finder",
            action: #selector(ImagePreviewWindowController.showInFinder(_:)),
            keyEquivalent: ""
        )
        XCTAssertTrue(controller.validateMenuItem(item))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        XCTAssertFalse(controller.validateMenuItem(item))
    }
}

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

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MarkdownPreviewWindowControllerTests-\(UUID().uuidString)")!
    }

    func test_route_allowsOwnLoadsAndReload() {
        XCTAssertEqual(route(.other, "file:///proj/docs/spec.md"), .allow)
        XCTAssertEqual(route(.reload, "file:///proj/docs/spec.md"), .allow)
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
}

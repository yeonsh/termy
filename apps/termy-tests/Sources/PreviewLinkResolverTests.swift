import XCTest
@testable import termy

final class PreviewLinkResolverTests: XCTestCase {
    private let home = "/Users/me"

    private func resolve(
        _ text: String,
        bases: [String] = ["/proj"],
        existing: Set<String>
    ) -> PreviewLinkResolution {
        PreviewLinkResolver.resolve(
            linkText: text,
            baseDirectories: bases,
            homeDirectory: home,
            isRegularFile: { existing.contains($0) }
        )
    }

    private func file(_ path: String) -> PreviewLinkResolution {
        .file(URL(fileURLWithPath: path).resolvingSymlinksInPath())
    }

    func test_absolutePath() {
        XCTAssertEqual(resolve("/proj/docs/a.md", existing: ["/proj/docs/a.md"]), file("/proj/docs/a.md"))
    }

    func test_homePath() {
        XCTAssertEqual(resolve("~/notes/a.md", existing: ["/Users/me/notes/a.md"]), file("/Users/me/notes/a.md"))
    }

    func test_relativeUsesFirstBaseThatHasTheFile() {
        XCTAssertEqual(
            resolve("docs/a.md", bases: ["/agent", "/shell"], existing: ["/shell/docs/a.md"]),
            file("/shell/docs/a.md")
        )
        XCTAssertEqual(
            resolve("docs/a.md", bases: ["/agent", "/shell"], existing: ["/agent/docs/a.md", "/shell/docs/a.md"]),
            file("/agent/docs/a.md")
        )
    }

    func test_dotAndDotDotSegments() {
        XCTAssertEqual(resolve("./docs/a.md", existing: ["/proj/docs/a.md"]), file("/proj/docs/a.md"))
        XCTAssertEqual(
            resolve("../other/a.md", bases: ["/proj/sub"], existing: ["/proj/other/a.md"]),
            file("/proj/other/a.md")
        )
    }

    func test_fileURLIsPercentDecoded() {
        XCTAssertEqual(resolve("file:///proj/docs/a%20b.md", existing: ["/proj/docs/a b.md"]), file("/proj/docs/a b.md"))
    }

    func test_lineAndFragmentSuffixesAreDropped() {
        for text in ["docs/a.md:12", "docs/a.md:12:3", "docs/a.md#L12", "docs/a.md#goals"] {
            XCTAssertEqual(resolve(text, existing: ["/proj/docs/a.md"]), file("/proj/docs/a.md"), text)
        }
    }

    func test_surroundingPunctuationIsDropped() {
        for text in ["(docs/a.md),", "`docs/a.md`.", "\"docs/a.md\"", "docs/a.md:", "[docs/a.md]"] {
            XCTAssertEqual(resolve(text, existing: ["/proj/docs/a.md"]), file("/proj/docs/a.md"), text)
        }
    }

    func test_extensionIsCaseInsensitiveAndAcceptsMarkdown() {
        XCTAssertEqual(resolve("README.MD", existing: ["/proj/README.MD"]), file("/proj/README.MD"))
        XCTAssertEqual(resolve("notes.markdown", existing: ["/proj/notes.markdown"]), file("/proj/notes.markdown"))
    }

    /// SwiftTerm's path regex runs on through Hangul particles (`\w`), `**`
    /// and trailing words ending in `.`, so agent summaries hand over these.
    func test_textGluedAfterTheExtensionIsCut() {
        let texts = [
            "docs/a.md에",
            "docs/a.md에 저장했습니다.",
            "docs/a.md를",
            "docs/a.md now.",
            "docs/a.md**",
            "docs/a.md:12에서",
        ]
        for text in texts {
            XCTAssertEqual(resolve(text, existing: ["/proj/docs/a.md"]), file("/proj/docs/a.md"), text)
        }
        XCTAssertEqual(resolve("notes.MARKDOWN을", existing: ["/proj/notes.MARKDOWN"]), file("/proj/notes.MARKDOWN"))
    }

    func test_nonMarkdownPathIsNotMarkdown() {
        XCTAssertEqual(resolve("src/main.swift", existing: ["/proj/src/main.swift"]), .notPreviewable)
        XCTAssertEqual(resolve("docs/a.md.bak", existing: []), .notPreviewable)
        XCTAssertEqual(resolve("README.md.bak", existing: []), .notPreviewable)
        XCTAssertEqual(resolve("docs/a.mdx", existing: ["/proj/docs/a.mdx"]), .notPreviewable)
        XCTAssertEqual(resolve("docs/a.md-old/b.txt", existing: []), .notPreviewable)
    }

    func test_webURLEndingInMdIsNotMarkdown() {
        XCTAssertEqual(resolve("https://github.com/o/r/blob/main/README.md", existing: []), .notPreviewable)
    }

    func test_missingFileIsMissing() {
        XCTAssertEqual(resolve("docs/none.md", existing: []), .missing)
        XCTAssertEqual(resolve("docs/a.md", bases: [], existing: ["/proj/docs/a.md"]), .missing)
    }

    func test_emptyAndDuplicateBasesAreSkipped() {
        var checked: [String] = []
        _ = PreviewLinkResolver.resolve(
            linkText: "docs/a.md",
            baseDirectories: ["", "/proj", "/proj"],
            homeDirectory: home,
            isRegularFile: { checked.append($0); return false }
        )
        XCTAssertEqual(checked, ["/proj/docs/a.md"])
    }

    func test_symlinkIsResolvedOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.md")
        try "# x\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.md"),
            withDestinationURL: real
        )

        let result = PreviewLinkResolver.resolve(
            linkText: "link.md",
            baseDirectories: [dir.path],
            homeDirectory: home,
            isRegularFile: PreviewLinkResolver.fileExistsAsRegularFile
        )
        XCTAssertEqual(result, .file(real.resolvingSymlinksInPath()))
    }

    func test_directoryIsNotARegularFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fake = dir.appendingPathComponent("folder.md")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(PreviewLinkResolver.fileExistsAsRegularFile(fake.path))
    }

    /// Reading a FIFO blocks until a writer shows up — on the main thread.
    func test_fifoIsNotARegularFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("pipe.md")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o644), 0)
        XCTAssertFalse(PreviewLinkResolver.fileExistsAsRegularFile(fifo.path))
    }

    func test_regularFileAndSymlinkToOneAreRegularFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.md")
        try "# x\n".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertTrue(PreviewLinkResolver.fileExistsAsRegularFile(real.path))
        XCTAssertTrue(PreviewLinkResolver.fileExistsAsRegularFile(link.path))
        XCTAssertFalse(PreviewLinkResolver.fileExistsAsRegularFile(dir.appendingPathComponent("none.md").path))
    }

    func test_previewKind() {
        XCTAssertEqual(PreviewKind(fileURL: URL(fileURLWithPath: "/x/a.md")), .markdown)
        XCTAssertEqual(PreviewKind(fileURL: URL(fileURLWithPath: "/x/b.MARKDOWN")), .markdown)
        XCTAssertEqual(PreviewKind(fileURL: URL(fileURLWithPath: "/x/c.Pdf")), .pdf)
        XCTAssertNil(PreviewKind(fileURL: URL(fileURLWithPath: "/x/d.txt")))
        XCTAssertNil(PreviewKind(fileURL: URL(fileURLWithPath: "/x/Makefile")))
    }
}

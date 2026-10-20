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

    func test_otherPathIsNotPreviewable() {
        XCTAssertEqual(resolve("src/main.swift", existing: ["/proj/src/main.swift"]), .notPreviewable)
        XCTAssertEqual(resolve("docs/a.md.bak", existing: []), .notPreviewable)
        XCTAssertEqual(resolve("README.md.bak", existing: []), .notPreviewable)
        XCTAssertEqual(resolve("docs/a.mdx", existing: ["/proj/docs/a.mdx"]), .notPreviewable)
        XCTAssertEqual(resolve("docs/a.md-old/b.txt", existing: []), .notPreviewable)
    }

    func test_pdfPaths() {
        let expected = file("/proj/out/report.pdf")
        let existing: Set<String> = ["/proj/out/report.pdf"]
        for text in [
            "out/report.pdf", "./out/report.pdf:3", "file:///proj/out/report.pdf", "`out/report.pdf`",
            "(out/report.pdf).", "out/report.pdf에 저장했습니다.", "out/report.pdf를",
        ] {
            XCTAssertEqual(resolve(text, existing: existing), expected, text)
        }
    }

    func test_uppercasePdfExtension() {
        XCTAssertEqual(resolve("out/REPORT.PDF", existing: ["/proj/out/REPORT.PDF"]), file("/proj/out/REPORT.PDF"))
    }

    func test_webURLEndingInPdfIsNotPreviewable() {
        XCTAssertEqual(resolve("https://arxiv.org/pdf/2401.00001.pdf", existing: []), .notPreviewable)
    }

    func test_pdfLookalikesAreNotPreviewable() {
        XCTAssertEqual(resolve("out/report.pdfx", existing: ["/proj/out/report.pdfx"]), .notPreviewable)
        XCTAssertEqual(resolve("out/report.pdf.bak", existing: ["/proj/out/report.pdf.bak"]), .notPreviewable)
    }

    func test_missingPdf() {
        XCTAssertEqual(resolve("out/none.pdf", existing: []), .missing)
    }

    func test_webURLEndingInMdIsNotPreviewable() {
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

    // MARK: - Links SwiftTerm cut short

    private let reportDir = "/r/2026-10-20-netdrive"
    private let parenReport = "NetDrive 시장 탈환 전략 (보강판) 2026-10-20.pdf"
    private let notesReport = "NetDrive 시장 탈환 전략 보강판 개정 노트 2026-10-20.pdf"

    private func resolveCutOff(
        _ link: String,
        following: String,
        bases: [String] = ["/proj"],
        listing: [String: [String]],
        existing: Set<String>? = nil
    ) -> URL? {
        let files = existing ?? Set(listing.flatMap { dir, names in names.map { "\(dir)/\($0)" } })
        return PreviewLinkResolver.resolveCutOff(
            linkText: link,
            followingText: following,
            baseDirectories: bases,
            homeDirectory: home,
            listDirectory: { listing[$0] ?? [] },
            isRegularFile: { files.contains($0) }
        )
    }

    /// SwiftTerm stops a path at `(`; the rest of the name is on screen.
    func test_resolveCutOff_findsTheParenthesizedName() {
        XCTAssertEqual(
            resolveCutOff(
                "\(reportDir)/NetDrive 시장 탈환 전략",
                following: " (보강판) 2026-10-20.pdf",
                listing: [reportDir: [parenReport, notesReport, "other.pdf"]]
            ),
            URL(fileURLWithPath: "\(reportDir)/\(parenReport)").resolvingSymlinksInPath()
        )
    }

    /// A sibling sharing the cut-off prefix must not win just because it exists.
    func test_resolveCutOff_picksTheNameTheTextSpellsOut() {
        XCTAssertNil(resolveCutOff(
            "\(reportDir)/NetDrive 시장 탈환 전략",
            following: " (초안) 2026-10-20.pdf",
            listing: [reportDir: [parenReport, notesReport]]
        ))
    }

    /// Wraps add indentation or drop the space they broke at.
    func test_resolveCutOff_ignoresWhitespaceFromWraps() {
        let expected = URL(fileURLWithPath: "\(reportDir)/\(parenReport)").resolvingSymlinksInPath()
        for following in [" (보강판)\n  2026-10-20.pdf", "(보강판)2026-10-\n  20.pdf"] {
            XCTAssertEqual(
                resolveCutOff("\(reportDir)/NetDrive 시장 탈환 전략", following: following, listing: [reportDir: [parenReport]]),
                expected,
                following
            )
        }
    }

    func test_resolveCutOff_needsTheNameToEndThere() {
        let listing = ["/proj/docs": ["a (1).pdf"]]
        let expected = URL(fileURLWithPath: "/proj/docs/a (1).pdf").resolvingSymlinksInPath()
        XCTAssertEqual(resolveCutOff("docs/a", following: " (1).pdf에 저장했습니다.", listing: listing), expected)
        XCTAssertEqual(resolveCutOff("docs/a", following: " (1).pdf.", listing: listing), expected)
        XCTAssertEqual(resolveCutOff("docs/a", following: " (1).pdf", listing: listing), expected)
        XCTAssertNil(resolveCutOff("docs/a", following: " (1).pdfx", listing: listing))
        XCTAssertNil(resolveCutOff("docs/a", following: " (1).pdf.bak", listing: listing))
    }

    func test_resolveCutOff_triesBaseDirectoriesInOrder() {
        XCTAssertEqual(
            resolveCutOff(
                "docs/a",
                following: " (draft).md",
                bases: ["/one", "/two"],
                listing: ["/two/docs": ["a (draft).md"]]
            ),
            URL(fileURLWithPath: "/two/docs/a (draft).md").resolvingSymlinksInPath()
        )
    }

    func test_resolveCutOff_linkEndingAtAFolder() {
        XCTAssertEqual(
            resolveCutOff("~/notes/", following: "(draft) plan.md", listing: ["/Users/me/notes": ["(draft) plan.md"]]),
            URL(fileURLWithPath: "/Users/me/notes/(draft) plan.md").resolvingSymlinksInPath()
        )
    }

    func test_resolveCutOff_onlyPreviewableRegularFiles() {
        XCTAssertNil(resolveCutOff("docs/a", following: " (1).txt", listing: ["/proj/docs": ["a (1).txt"]]))
        // Listed but not a regular file (a folder named like one).
        XCTAssertNil(resolveCutOff("docs/a", following: " (1).pdf", listing: ["/proj/docs": ["a (1).pdf"]], existing: []))
    }

    func test_resolveCutOff_leavesURLsAlone() {
        let listing = ["/proj/docs": ["a (1).pdf"]]
        XCTAssertNil(resolveCutOff("https://example.com/docs/a", following: " (1).pdf", listing: listing))
        XCTAssertNil(resolveCutOff("file:///proj/docs/a", following: " (1).pdf", listing: listing))
    }
}

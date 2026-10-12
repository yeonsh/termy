import XCTest
@testable import termy

final class MarkdownHTMLRendererTests: XCTestCase {
    private func body(_ markdown: String) -> String {
        MarkdownHTMLRenderer.body(markdown: markdown)
    }

    func test_escapesTextInlineCodeAndCodeBlocks() {
        let html = body("a < b & c\n\n`Array<Int>`\n\n```swift\nlet x: Array<String> = [] // <tag>\n```\n")
        XCTAssertTrue(html.contains("a &lt; b &amp; c"), html)
        XCTAssertTrue(html.contains("<code>Array&lt;Int&gt;</code>"), html)
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let x: Array&lt;String&gt; = [] // &lt;tag&gt;"), html)
    }

    func test_rawHTMLIsShownAsText() {
        let html = body("<script>alert(1)</script>\n\n<div onclick=\"x()\">hi</div>\n\nsee <b>bold</b>\n")
        XCTAssertFalse(html.contains("<script"), html)
        XCTAssertFalse(html.contains("<div"), html)
        XCTAssertFalse(html.contains("<b>"), html)
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), html)
        XCTAssertTrue(html.contains("&lt;div onclick=&quot;x()&quot;&gt;hi&lt;/div&gt;"), html)
        XCTAssertTrue(html.contains("&lt;b&gt;bold&lt;/b&gt;"), html)
    }

    func test_headingIdsAreGitHubStyleAndDeduplicated() {
        let html = body("# 1. 목표와 동기\n\n## Goals\n\n## Goals\n\n### `MarkdownLinkResolver` (pure)\n")
        XCTAssertTrue(html.contains("<h1 id=\"1-목표와-동기\">1. 목표와 동기</h1>"), html)
        XCTAssertTrue(html.contains("<h2 id=\"goals\">Goals</h2>"), html)
        XCTAssertTrue(html.contains("<h2 id=\"goals-1\">Goals</h2>"), html)
        XCTAssertTrue(
            html.contains("<h3 id=\"markdownlinkresolver-pure\"><code>MarkdownLinkResolver</code> (pure)</h3>"),
            html
        )
    }

    func test_tableWithAlignment() {
        let html = body("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n")
        XCTAssertTrue(html.contains("<thead>"), html)
        XCTAssertTrue(html.contains("<tbody>"), html)
        XCTAssertTrue(html.contains("<th style=\"text-align: left\">a</th>"), html)
        XCTAssertTrue(html.contains("<th style=\"text-align: center\">b</th>"), html)
        XCTAssertTrue(html.contains("<td style=\"text-align: right\">3</td>"), html)
    }

    func test_taskListItems() {
        let html = body("- [ ] todo\n- [x] done\n- plain\n")
        XCTAssertTrue(html.contains("<li class=\"task-list-item\"><input type=\"checkbox\" disabled> "), html)
        XCTAssertTrue(html.contains("<li class=\"task-list-item\"><input type=\"checkbox\" disabled checked> "), html)
        XCTAssertTrue(html.contains("<li><p>plain</p>"), html)
    }

    func test_orderedListStart() {
        XCTAssertTrue(body("3. three\n4. four\n").contains("<ol start=\"3\">"))
        XCTAssertTrue(body("1. one\n").contains("<ol>"))
    }

    func test_linkHrefIsEscaped() {
        let html = body("[x](https://example.com/?a=1&b=2)")
        XCTAssertTrue(html.contains("<a href=\"https://example.com/?a=1&amp;b=2\">x</a>"), html)
    }

    func test_imageShowsAltText() {
        let html = body("![diagram of flow](img/flow.png)")
        XCTAssertTrue(html.contains("<span class=\"image-alt\">[image: diagram of flow]</span>"), html)
        XCTAssertFalse(html.contains("<img"), html)
    }

    func test_inlineFormatting() {
        let html = body("~~old~~ *em* **strong**\n\n> quote\n\n---\n")
        XCTAssertTrue(html.contains("<del>old</del>"), html)
        XCTAssertTrue(html.contains("<em>em</em>"), html)
        XCTAssertTrue(html.contains("<strong>strong</strong>"), html)
        XCTAssertTrue(html.contains("<blockquote>"), html)
        XCTAssertTrue(html.contains("<hr>"), html)
    }

    func test_documentHasCSPEscapedTitleAndBanner() {
        let html = MarkdownHTMLRenderer.document(markdown: "# Hi", title: "a<b>.md", banner: "File was deleted.")
        XCTAssertTrue(
            html.contains("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">"),
            html
        )
        XCTAssertTrue(html.contains("<title>a&lt;b&gt;.md</title>"), html)
        XCTAssertTrue(html.contains("<div class=\"preview-banner\">File was deleted.</div>"), html)
        XCTAssertFalse(
            MarkdownHTMLRenderer.document(markdown: "x", title: "t").contains("<div class=\"preview-banner\">")
        )
    }

    func test_escapeHandlesSpecialCharactersFollowedByCombiningMarks() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.escape("\"\u{301}<\u{301}&\u{301}"),
            "&quot;\u{301}&lt;\u{301}&amp;\u{301}"
        )
    }

    func test_linkDestinationWithQuoteAndCombiningMarkStaysInsideHref() {
        let html = body("[a](<x\"\u{301}y>)")
        XCTAssertTrue(html.contains("href=\"x&quot;\u{301}y\""), html)
    }

    func test_codeFenceLanguageWithQuoteAndCombiningMarkStaysInsideClass() {
        let html = body("```sw\"\u{301}ift\nx\n```\n")
        XCTAssertTrue(html.contains("class=\"language-sw&quot;\u{301}ift\""), html)
    }

    /// Smoke test on a real spec: tables and task lists from this repo's
    /// own docs render without falling back to raw text.
    func test_rendersThisFeaturesSpec() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // termy-tests
            .deletingLastPathComponent()   // apps
            .deletingLastPathComponent()   // repo root
        let spec = repoRoot.appendingPathComponent("docs/superpowers/specs/2026-10-12-markdown-preview-design.md")
        let html = body(try String(contentsOf: spec, encoding: .utf8))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("task-list-item"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"))
    }
}

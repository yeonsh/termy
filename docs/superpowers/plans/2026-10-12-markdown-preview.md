# Markdown 프리뷰 창 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** termy pane에서 `.md` 파일 경로를 Cmd+클릭하면, 파일마다 하나씩 뜨는 별도 창에 GitHub 스타일로 렌더링해 보여 주고, 파일이 바뀌면 스크롤 위치를 유지한 채 갱신한다.

**Architecture:** Cmd+클릭 monitor가 링크 텍스트를 `MarkdownLinkResolver`로 해석해 pane의 cwd 후보에서 실제 파일을 찾는다. `MarkdownPreviewManager`가 파일당 `MarkdownPreviewWindowController` 하나를 관리한다. 컨트롤러는 swift-markdown으로 파싱하고 termy 자체 writer(`MarkdownHTMLRenderer`)로 escape된 HTML을 만들어, 페이지 JavaScript를 끈 WKWebView에 띄운다. `MarkdownFileWatcher`가 파일과 상위 디렉터리를 감시해 갱신을 알린다. AppDelegate는 프리뷰가 key일 때 ⌘W를 프리뷰 닫기로 돌리고 pane 액션을 끈다.

**Tech Stack:** Swift 6, AppKit, WebKit(WKWebView), swift-markdown 0.9.0(cmark-gfm), SwiftTerm 1.20.0(고정), XcodeGen(`project.yml`), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-12-markdown-preview-design.md`

## Global Constraints

- Swift 6 언어 모드, macOS 14 deployment target. 새 코드는 strict concurrency에서 경고 없이 컴파일돼야 한다.
- SwiftTerm `exactVersion: "1.20.0"`, Sparkle `2.6.4`, TOMLKit `from: "0.6.0"`은 그대로 둔다. 새 패키지는 swift-markdown `exactVersion: "0.9.0"` 하나뿐이다.
- **새 `.swift` 파일을 만들거나 `project.yml`을 고치면 반드시 `xcodegen generate`를 실행**한다. `termy.xcodeproj/`와 `Package.resolved`는 `.gitignore` 대상이라 커밋하지 않는다. 커밋할 것은 `project.yml`과 소스·테스트·문서뿐이다.
- 테스트 명령(모든 태스크 공통):
  `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25`
  → `** TEST SUCCEEDED **`. `-derivedDataPath`와 `-skipPackagePluginValidation`을 빼면 이 환경에서 EPERM이나 plugin 검증 오류가 난다. 여러 클래스는 `-only-testing`을 반복한다.
- **Task 1–6에서는 termy.app을 실행하지 않는다.** `scripts/relaunch.sh`, `open termy.app`, Debug 빌드 실행 모두 금지다. 이 세션 자체가 termy 안에서 돌고 있고(`TERMY_PANE_ID` 설정됨), 두 번째 인스턴스는 hook socket(`/tmp/termy-$UID.sock`)과 `~/Library/Application Support/termy/session.json`을 가로챈다. XCTest host로 뜨는 것은 괜찮다(`TestHostDetector`가 막는다).
- 앱 UI 문구는 영어이며 아래 문자열을 그대로 쓴다.
  - 메뉴: `"Close Preview"`(프리뷰가 key일 때), `"Close Pane"`(그 밖)
  - 삭제 배너: `"This file was deleted. The preview will reload if it comes back."`
  - 읽기 실패: `"Couldn't read this file: <error.localizedDescription>"`
  - 이미지 자리: `[image: <대체 텍스트>]`
- WKWebView는 `allowsContentJavaScript = false`, `websiteDataStore = .nonPersistent()`로 만든다. 앱 쪽 JS는 `contentWorld: .defaultClient`로만 실행한다.
- 파일에서 온 내용(텍스트, 코드, 링크 주소, raw HTML, 언어 이름, 제목)은 전부 HTML escape한다. raw HTML을 그대로 통과시키는 경로가 있으면 안 된다.
- 테스트가 `UserDefaults.standard`에 쓰지 않게 한다(테스트 host가 실제 termy와 같은 defaults 도메인을 쓴다). 창 크기 저장은 주입한 `UserDefaults`로 한다.
- 커밋 메시지는 한국어, `Co-Authored-By` 라인을 넣지 않는다. 접두사는 기존 관례(`feat(preview):`, `test(preview):`, `docs(changelog):` 등)를 따른다.
- 주석 밀도와 스타일은 주변 코드를 따른다. 파일 머리 주석에 "왜"를 쓰고, 타입·메서드에는 `///` 한두 줄을 붙인다.

## Review Focus

spec이 암시하지만 다른 태스크 테스트가 다루지 않는 입력 가운데, 실제로 부딪히기 쉬운 순서로 적는다. 각 줄의 테스트는 해당 태스크에 들어 있다.

1. **좁은 pane에서 Ink가 두 줄로 나눠 그린 긴 경로**: 어느 줄을 Cmd+클릭해도 전체 경로가 열려야 한다. → Task 5 `test_linkLookup_joinsInkStyleHardWrappedPath`
2. **`.md`로 끝나는 웹 URL**(`https://github.com/…/README.md`): beep이 아니라 브라우저로 열려야 한다. → Task 2 `test_webURLEndingInMdIsNotMarkdown`, Task 5 `test_linkClickAction_webURLEndingInMdOpensBrowser`
3. **agent가 atomic save(rename)한 뒤 계속 고치는 경우**: 교체 뒤의 수정도 계속 반영돼야 한다. → Task 3 `test_atomicReplaceThenInPlaceWriteBothReported`
4. **`<script>`, raw HTML, `Array<String>` 같은 제네릭이 든 문서**: 아무것도 실행되지 않고 코드는 글자 그대로 보여야 한다. → Task 1 `test_rawHTMLIsShownAsText`, `test_escapesTextInlineCodeAndCodeBlocks`
5. **UTF-8이 아닌 바이트가 섞인 파일**: 오류 화면 대신 나머지 내용을 보여야 한다. → Task 4 `test_decodeMarkdown_toleratesInvalidUTF8`

## 파일 구조

| 파일 | 역할 | 태스크 |
|---|---|---|
| `project.yml` (수정) | swift-markdown 패키지 추가 | 1 |
| `apps/termy/Sources/MarkdownHTMLRenderer.swift` (신규) | markdown → escape된 HTML 문서. `MarkdownHTMLWriter` 포함 | 1 |
| `apps/termy/Sources/MarkdownPreviewStyle.swift` (신규) | 프리뷰 CSS 문자열 | 1 |
| `apps/termy/Sources/MarkdownLinkResolver.swift` (신규) | 링크 텍스트 → md 파일 URL 판정 | 2 |
| `apps/termy/Sources/MarkdownFileWatcher.swift` (신규) | 파일·디렉터리 감시, 변화 분류 | 3 |
| `apps/termy/Sources/MarkdownPreviewWindowController.swift` (신규) | 프리뷰 창 하나, WKWebView, 링크 정책 | 4 |
| `apps/termy/Sources/MarkdownPreviewManager.swift` (신규) | 파일당 창 하나 관리, 계단식 배치 | 4 |
| `apps/termy/Sources/TermyTerminalView.swift` (수정) | Cmd+클릭 결정 함수와 실행 | 5 |
| `apps/termy/Sources/Pane.swift` (수정) | 기준 디렉터리 제공, 프리뷰 열기 연결 | 5 |
| `apps/termy/Sources/AppDelegate.swift` (수정) | ⌘W·pane 메뉴 판정 | 6 |
| `apps/termy/Sources/WindowManager.swift` (수정) | 마지막 메인 창이 닫히면 프리뷰도 닫기 | 6 |
| `CHANGELOG.md` (수정) | Unreleased 항목 | 7 |
| 테스트 (신규) `apps/termy-tests/Sources/` 아래 `MarkdownHTMLRendererTests`, `MarkdownLinkResolverTests`, `MarkdownFileWatcherTests`, `MarkdownPreviewManagerTests`, `MarkdownPreviewWindowControllerTests`, `PaneMarkdownBaseDirectoriesTests`, `AppDelegatePreviewMenuTests` | | 1–6 |
| 테스트 (수정) `apps/termy-tests/Sources/TermyTerminalViewTests.swift` | `linkClickAction`, hard-wrap 링크 | 5 |

---

### Task 1: swift-markdown 의존성과 HTML 렌더러

**Files:**
- Modify: `project.yml` (`packages:` 블록, `termy` 타깃 `dependencies:`)
- Create: `apps/termy/Sources/MarkdownHTMLRenderer.swift`
- Create: `apps/termy/Sources/MarkdownPreviewStyle.swift`
- Test: `apps/termy-tests/Sources/MarkdownHTMLRendererTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `enum MarkdownHTMLRenderer`
    - `static func document(markdown: String, title: String, banner: String? = nil) -> String`
    - `static func body(markdown: String) -> String`
    - `static func escape(_ text: String) -> String`
    - `static func slug(for text: String) -> String`
  - `enum MarkdownPreviewStyle { static let css: String }`

- [ ] **Step 1: swift-markdown 패키지를 추가하고 resolve되는지 확인**

`project.yml`의 `packages:` 블록 끝(TOMLKit 다음)에 추가:

```yaml
  SwiftMarkdown:
    url: https://github.com/swiftlang/swift-markdown
    exactVersion: "0.9.0"
```

`termy` 타깃 `dependencies:`의 `- package: TOMLKit` 다음 줄에 추가:

```yaml
      - package: SwiftMarkdown
        product: Markdown
```

Run: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild -resolvePackageDependencies -project termy.xcodeproj -scheme termy -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation 2>&1 | tail -15`
Expected: 출력에 `swift-markdown`과 `swift-cmark`이 resolve되고 오류가 없다.

- [ ] **Step 2: 실패하는 테스트 작성**

`apps/termy-tests/Sources/MarkdownHTMLRendererTests.swift`:

```swift
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
```

- [ ] **Step 3: 테스트가 실패하는지 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/MarkdownHTMLRendererTests 2>&1 | tail -25`
Expected: 컴파일 실패, `cannot find 'MarkdownHTMLRenderer' in scope`.

- [ ] **Step 4: CSS 작성**

`apps/termy/Sources/MarkdownPreviewStyle.swift`:

```swift
// MarkdownPreviewStyle.swift
//
// Stylesheet for the markdown preview window. Kept as a Swift string, not a
// bundled .css resource, so `MarkdownHTMLRenderer.document` stays a pure
// function with no bundle lookup. GitHub-like look; light/dark follow the
// window's appearance (termy's appearance setting) via
// `prefers-color-scheme`.

enum MarkdownPreviewStyle {
    static let css = """
    :root {
      color-scheme: light dark;
      --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --border: #d1d9e0;
      --code-bg: #f6f8fa; --link: #0969da; --banner-bg: #fff8c5; --banner-border: #d4a72c;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #f0f6fc; --muted: #9198a1; --bg: #0d1117; --border: #3d444d;
        --code-bg: #151b23; --link: #4493f8; --banner-bg: #3a2e05; --banner-border: #9e6a03;
      }
    }
    html { background: var(--bg); }
    body {
      margin: 0; color: var(--fg); background: var(--bg);
      font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    .markdown-body { max-width: 900px; margin: 0 auto; padding: 32px 40px 64px; overflow-wrap: break-word; }
    h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1em; }
    h5 { font-size: .875em; }
    h6 { font-size: .85em; color: var(--muted); }
    p, ul, ol, blockquote, pre, table { margin: 0 0 16px; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    ul, ol { padding-left: 2em; }
    li + li { margin-top: .25em; }
    li > p { margin: 0; }
    .task-list-item { list-style: none; }
    .task-list-item > input { margin: 0 .35em 0 -1.4em; vertical-align: middle; }
    .task-list-item > input + p { display: inline; }
    blockquote { padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    code, pre, .raw-html { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 85%; }
    code { padding: .2em .4em; background: var(--code-bg); border-radius: 6px; }
    pre { padding: 16px; overflow: auto; line-height: 1.45; background: var(--code-bg); border-radius: 6px; }
    pre code { padding: 0; background: transparent; font-size: 100%; white-space: pre; }
    table { display: block; width: max-content; max-width: 100%; overflow: auto; border-collapse: collapse; }
    th, td { padding: 6px 13px; border: 1px solid var(--border); }
    th { font-weight: 600; }
    tbody tr:nth-child(2n) td { background: var(--code-bg); }
    hr { height: .25em; margin: 24px 0; background: var(--border); border: 0; }
    del { color: var(--muted); }
    .image-alt { color: var(--muted); font-style: italic; }
    .raw-html { white-space: pre-wrap; color: var(--muted); }
    .preview-banner {
      margin: 0 0 24px; padding: 10px 14px;
      background: var(--banner-bg); border: 1px solid var(--banner-border); border-radius: 6px;
    }
    """
}
```

- [ ] **Step 5: 렌더러 작성**

`apps/termy/Sources/MarkdownHTMLRenderer.swift`:

```swift
// MarkdownHTMLRenderer.swift
//
// Turns a markdown file into the HTML document the preview window shows.
// swift-markdown (cmark-gfm) parses; the HTML writer is ours because
// swift-markdown 0.9.0's `HTMLFormatter` writes text, inline code and code
// blocks without escaping them and emits headings without ids. Everything
// that came from the file — raw HTML included — is escaped, so the page
// shows exactly what the agent wrote and never interprets it.

import Foundation
import Markdown

enum MarkdownHTMLRenderer {
    /// Complete HTML document for the preview web view. `banner`, when set,
    /// is shown above the body (e.g. the file was deleted).
    static func document(markdown: String, title: String, banner: String? = nil) -> String {
        var html = """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>\(MarkdownPreviewStyle.css)</style>
        </head><body><main class="markdown-body">

        """
        if let banner {
            html += "<div class=\"preview-banner\">\(escape(banner))</div>\n"
        }
        html += body(markdown: markdown)
        html += "</main></body></html>\n"
        return html
    }

    /// HTML for the markdown body alone.
    static func body(markdown: String) -> String {
        var writer = MarkdownHTMLWriter()
        writer.visit(Document(parsing: markdown))
        return writer.result
    }

    /// Escapes the five HTML-significant characters; safe for text content
    /// and for quoted attribute values.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// GitHub-style heading anchor: lowercased; letters and digits of any
    /// script, `-` and `_` kept; spaces become `-`; everything else dropped.
    static func slug(for text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " {
                out += "-"
            }
        }
        return out
    }
}

/// Walks a swift-markdown tree and appends HTML to `result`.
struct MarkdownHTMLWriter: MarkupWalker {
    private(set) var result = ""
    /// Uses per heading slug, for GitHub's `-1`, `-2` de-duplication.
    private var slugCounts: [String: Int] = [:]
    private var columnAlignments: [Table.ColumnAlignment?] = []
    private var inTableHead = false
    private var cellIndex = 0

    private mutating func wrap(_ tag: String, _ markup: Markup, attributes: String = "") {
        result += "<\(tag)\(attributes)>"
        descendInto(markup)
        result += "</\(tag)>"
    }

    private static func escape(_ text: String) -> String {
        MarkdownHTMLRenderer.escape(text)
    }

    // MARK: Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) {
        wrap("p", paragraph)
        result += "\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        let base = MarkdownHTMLRenderer.slug(for: heading.plainText)
        let uses = slugCounts[base, default: 0]
        slugCounts[base] = uses + 1
        let id = uses == 0 ? base : "\(base)-\(uses)"
        wrap("h\(heading.level)", heading, attributes: " id=\"\(Self.escape(id))\"")
        result += "\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        var classAttribute = ""
        if let language = codeBlock.language, !language.isEmpty {
            classAttribute = " class=\"language-\(Self.escape(language))\""
        }
        result += "<pre><code\(classAttribute)>\(Self.escape(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += "<p class=\"raw-html\">\(Self.escape(html.rawHTML))</p>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        result += "<ol\(start)>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            result += "<li class=\"task-list-item\"><input type=\"checkbox\" disabled\(checked)> "
        } else {
            result += "<li>"
        }
        descendInto(listItem)
        result += "</li>\n"
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) {
        columnAlignments = table.columnAlignments
        result += "<table>\n"
        descendInto(table)
        result += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        inTableHead = true
        cellIndex = 0
        result += "<thead><tr>"
        descendInto(tableHead)
        result += "</tr></thead>\n"
        inTableHead = false
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard tableBody.childCount > 0 else { return }
        result += "<tbody>\n"
        descendInto(tableBody)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        cellIndex = 0
        result += "<tr>"
        descendInto(tableRow)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        var style = ""
        if cellIndex < columnAlignments.count, let alignment = columnAlignments[cellIndex] {
            switch alignment {
            case .left: style = " style=\"text-align: left\""
            case .center: style = " style=\"text-align: center\""
            case .right: style = " style=\"text-align: right\""
            }
        }
        cellIndex += 1
        wrap(inTableHead ? "th" : "td", tableCell, attributes: style)
    }

    // MARK: Inlines

    mutating func visitText(_ text: Text) {
        result += Self.escape(text.string)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        wrap("em", emphasis)
    }

    mutating func visitStrong(_ strong: Strong) {
        wrap("strong", strong)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        wrap("del", strikethrough)
    }

    mutating func visitLink(_ link: Link) {
        wrap("a", link, attributes: " href=\"\(Self.escape(link.destination ?? ""))\"")
    }

    mutating func visitImage(_ image: Image) {
        let alt = image.plainText.isEmpty ? (image.source ?? "") : image.plainText
        result += "<span class=\"image-alt\">[image: \(Self.escape(alt))]</span>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += Self.escape(inlineHTML.rawHTML)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }
}
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/MarkdownHTMLRendererTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`. 빌드 로그에 새 파일 관련 concurrency 경고가 없어야 한다(`grep -i warning`으로 확인).

`test_headingIdsAreGitHubStyleAndDeduplicated`의 h3가 실패하면 실제 출력을 보고 판단한다. `heading.plainText`가 inline code를 backtick 포함으로 돌려줘도 slug 단계에서 backtick은 빠지므로 id는 같아야 한다. 다르면 slug 규칙을 고치지 말고 출력값을 보고하라.

- [ ] **Step 7: 커밋**

```bash
git add project.yml apps/termy/Sources/MarkdownHTMLRenderer.swift apps/termy/Sources/MarkdownPreviewStyle.swift apps/termy-tests/Sources/MarkdownHTMLRendererTests.swift
git commit -m "feat(preview): swift-markdown으로 파싱하고 모든 내용을 escape하는 markdown HTML 렌더러를 추가"
```

---

### Task 2: 링크 텍스트를 md 파일로 해석하기

**Files:**
- Create: `apps/termy/Sources/MarkdownLinkResolver.swift`
- Test: `apps/termy-tests/Sources/MarkdownLinkResolverTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `enum MarkdownLinkResolution: Equatable { case notMarkdown, missing, file(URL) }`
  - `enum MarkdownLinkResolver`
    - `static let extensions: Set<String>`
    - `static func resolve(linkText: String, baseDirectories: [String], homeDirectory: String, isRegularFile: (String) -> Bool) -> MarkdownLinkResolution`
    - `static func markdownPath(from linkText: String) -> String?`
    - `static func fileExistsAsRegularFile(_ path: String) -> Bool`

- [ ] **Step 1: 실패하는 테스트 작성**

`apps/termy-tests/Sources/MarkdownLinkResolverTests.swift`:

```swift
import XCTest
@testable import termy

final class MarkdownLinkResolverTests: XCTestCase {
    private let home = "/Users/me"

    private func resolve(
        _ text: String,
        bases: [String] = ["/proj"],
        existing: Set<String>
    ) -> MarkdownLinkResolution {
        MarkdownLinkResolver.resolve(
            linkText: text,
            baseDirectories: bases,
            homeDirectory: home,
            isRegularFile: { existing.contains($0) }
        )
    }

    private func file(_ path: String) -> MarkdownLinkResolution {
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

    func test_nonMarkdownPathIsNotMarkdown() {
        XCTAssertEqual(resolve("src/main.swift", existing: ["/proj/src/main.swift"]), .notMarkdown)
        XCTAssertEqual(resolve("docs/a.md.bak", existing: []), .notMarkdown)
    }

    func test_webURLEndingInMdIsNotMarkdown() {
        XCTAssertEqual(resolve("https://github.com/o/r/blob/main/README.md", existing: []), .notMarkdown)
    }

    func test_missingFileIsMissing() {
        XCTAssertEqual(resolve("docs/none.md", existing: []), .missing)
        XCTAssertEqual(resolve("docs/a.md", bases: [], existing: ["/proj/docs/a.md"]), .missing)
    }

    func test_emptyAndDuplicateBasesAreSkipped() {
        var checked: [String] = []
        _ = MarkdownLinkResolver.resolve(
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

        let result = MarkdownLinkResolver.resolve(
            linkText: "link.md",
            baseDirectories: [dir.path],
            homeDirectory: home,
            isRegularFile: MarkdownLinkResolver.fileExistsAsRegularFile
        )
        XCTAssertEqual(result, .file(real.resolvingSymlinksInPath()))
    }

    func test_directoryIsNotARegularFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fake = dir.appendingPathComponent("folder.md")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(MarkdownLinkResolver.fileExistsAsRegularFile(fake.path))
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/MarkdownLinkResolverTests 2>&1 | tail -25`
Expected: 컴파일 실패, `cannot find 'MarkdownLinkResolver' in scope`.

- [ ] **Step 3: 구현**

`apps/termy/Sources/MarkdownLinkResolver.swift`:

```swift
// MarkdownLinkResolver.swift
//
// Decides whether a Cmd+clicked terminal link names a markdown file termy
// should preview, and which file on disk that is. SwiftTerm hands over the
// raw matched text — `docs/x.md`, `./x.md:12`, `file:///…/x.md`, often with
// prose punctuation stuck to it — and a relative path is relative to
// whatever cwd the agent printed it from, so callers pass candidate base
// directories in priority order and the first one holding the file wins.

import Foundation

enum MarkdownLinkResolution: Equatable {
    /// Not a markdown link; the caller falls back to its URL handling.
    case notMarkdown
    /// Shaped like a markdown path, but no such file exists.
    case missing
    /// The markdown file to open, symlinks resolved.
    case file(URL)
}

enum MarkdownLinkResolver {
    static let extensions: Set<String> = ["md", "markdown"]

    private static let leadingPunctuation: Set<Character> = ["(", "[", "`", "'", "\""]
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "`", "'", "\""]

    static func resolve(
        linkText: String,
        baseDirectories: [String],
        homeDirectory: String,
        isRegularFile: (String) -> Bool
    ) -> MarkdownLinkResolution {
        guard let path = markdownPath(from: linkText) else { return .notMarkdown }

        let candidates: [String]
        if path.hasPrefix("~/") {
            candidates = [(homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2)))]
        } else if path.hasPrefix("/") {
            candidates = [path]
        } else {
            var seen = Set<String>()
            candidates = baseDirectories
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .map { ($0 as NSString).appendingPathComponent(path) }
        }

        for candidate in candidates {
            let standardized = (candidate as NSString).standardizingPath
            if isRegularFile(standardized) {
                return .file(URL(fileURLWithPath: standardized).resolvingSymlinksInPath())
            }
        }
        return .missing
    }

    /// The path in `linkText` when it names a markdown file: surrounding
    /// punctuation, `file://`, `#fragment` and `:line[:col]` removed. nil
    /// for any other extension and for web URLs.
    static func markdownPath(from linkText: String) -> String? {
        var text = Substring(linkText.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = text.first, leadingPunctuation.contains(first) {
            text = text.dropFirst()
        }
        while let last = text.last, trailingPunctuation.contains(last) {
            text = text.dropLast()
        }

        var path = String(text)
        if path.lowercased().hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            path = url.path
        } else if path.contains("://") {
            // `https://…/README.md` is a web page, not a local file.
            return nil
        } else if let hash = path.firstIndex(of: "#") {
            path = String(path[..<hash])
        }
        path = stripLineSuffix(path)

        guard extensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return path
    }

    /// `isRegularFile` for real use: something exists at `path` and it is
    /// not a directory.
    static func fileExistsAsRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Drops an editor-style `:12` or `:12:3` suffix.
    private static func stripLineSuffix(_ path: String) -> String {
        var result = Substring(path)
        for _ in 0..<2 {
            guard let colon = result.lastIndex(of: ":") else { break }
            let tail = result[result.index(after: colon)...]
            guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }) else { break }
            result = result[..<colon]
        }
        return String(result)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/MarkdownLinkResolverTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: 커밋**

```bash
git add apps/termy/Sources/MarkdownLinkResolver.swift apps/termy-tests/Sources/MarkdownLinkResolverTests.swift
git commit -m "feat(preview): Cmd+클릭한 링크 텍스트를 pane 기준 디렉터리에서 md 파일로 해석하는 resolver를 추가"
```

---

### Task 3: 파일 감시

**Files:**
- Create: `apps/termy/Sources/MarkdownFileWatcher.swift`
- Test: `apps/termy-tests/Sources/MarkdownFileWatcherTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `struct FileFingerprint: Equatable { let inode: UInt64; let size: Int64; let mtimeNanoseconds: Int64; static func current(atPath: String) -> FileFingerprint? }`
  - `enum FileChange: Equatable { case unchanged, modified, deleted, recreated }`
  - `@MainActor final class MarkdownFileWatcher`
    - `init(fileURL: URL, onChange: @escaping (FileChange) -> Void)` — 만드는 즉시 감시 시작. `onChange`는 main queue에서, `.unchanged`가 아닐 때만 불린다.
    - `func stop()` — 소유자가 반드시 부른다.
    - `nonisolated static func classify(old: FileFingerprint?, new: FileFingerprint?) -> FileChange`
    - `static let debounceInterval: TimeInterval` (0.15)

- [ ] **Step 1: 실패하는 테스트 작성**

`apps/termy-tests/Sources/MarkdownFileWatcherTests.swift`:

```swift
import XCTest
@testable import termy

@MainActor
final class MarkdownFileWatcherTests: XCTestCase {
    // MARK: classify

    private let a = FileFingerprint(inode: 1, size: 10, mtimeNanoseconds: 100)

    func test_classify() {
        XCTAssertEqual(MarkdownFileWatcher.classify(old: nil, new: nil), .unchanged)
        XCTAssertEqual(MarkdownFileWatcher.classify(old: a, new: a), .unchanged)
        XCTAssertEqual(MarkdownFileWatcher.classify(old: nil, new: a), .recreated)
        XCTAssertEqual(MarkdownFileWatcher.classify(old: a, new: nil), .deleted)
        XCTAssertEqual(
            MarkdownFileWatcher.classify(old: a, new: FileFingerprint(inode: 1, size: 11, mtimeNanoseconds: 100)),
            .modified
        )
        XCTAssertEqual(
            MarkdownFileWatcher.classify(old: a, new: FileFingerprint(inode: 1, size: 10, mtimeNanoseconds: 101)),
            .modified
        )
        // Atomic save: same size and mtime granularity, new inode.
        XCTAssertEqual(
            MarkdownFileWatcher.classify(old: a, new: FileFingerprint(inode: 2, size: 10, mtimeNanoseconds: 100)),
            .modified
        )
    }

    func test_fingerprintIsNilForMissingFile() {
        XCTAssertNil(FileFingerprint.current(atPath: "/nonexistent/\(UUID().uuidString).md"))
    }

    // MARK: live events

    private func makeTempFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try contents.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// Lets the main queue run (dispatch sources and the debounce fire
    /// there) until `condition` holds.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_inPlaceWriteIsReported() async throws {
        let url = try makeTempFile("one")
        var changes: [FileChange] = []
        let watcher = MarkdownFileWatcher(fileURL: url) { changes.append($0) }
        defer { watcher.stop() }

        try "one two".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { !changes.isEmpty }
        XCTAssertEqual(changes.first, .modified)
    }

    func test_atomicReplaceThenInPlaceWriteBothReported() async throws {
        let url = try makeTempFile("one")
        var changes: [FileChange] = []
        let watcher = MarkdownFileWatcher(fileURL: url) { changes.append($0) }
        defer { watcher.stop() }

        try "two two".write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil { changes.count >= 1 }
        // The watcher must have re-attached to the replacement file.
        try "three three three".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { changes.count >= 2 }
        XCTAssertEqual(Array(changes.prefix(2)), [.modified, .modified])
    }

    func test_deleteThenRecreateIsReported() async throws {
        let url = try makeTempFile("one")
        var changes: [FileChange] = []
        let watcher = MarkdownFileWatcher(fileURL: url) { changes.append($0) }
        defer { watcher.stop() }

        try FileManager.default.removeItem(at: url)
        try await waitUntil { changes.count >= 1 }
        try "back".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { changes.count >= 2 }
        XCTAssertEqual(Array(changes.prefix(2)), [.deleted, .recreated])
    }

    func test_stopSilencesWatcher() async throws {
        let url = try makeTempFile("one")
        var changes: [FileChange] = []
        let watcher = MarkdownFileWatcher(fileURL: url) { changes.append($0) }
        watcher.stop()

        try "one two".write(to: url, atomically: false, encoding: .utf8)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(changes, [])
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/MarkdownFileWatcherTests 2>&1 | tail -25`
Expected: 컴파일 실패, `cannot find 'FileFingerprint' in scope`.

- [ ] **Step 3: 구현**

`apps/termy/Sources/MarkdownFileWatcher.swift`:

```swift
// MarkdownFileWatcher.swift
//
// Tells a preview window when its markdown file changes on disk. Agents
// write files both in place and by atomic save (write a temp file, rename
// it over the original), so we watch the file itself for content changes
// and its parent directory for the file being replaced, removed or
// re-created. Bursts of events — an agent writing in chunks — collapse
// into one check after a short debounce, and the check compares a stat
// fingerprint so events that changed nothing don't re-render.

import Foundation

struct FileFingerprint: Equatable {
    let inode: UInt64
    let size: Int64
    let mtimeNanoseconds: Int64

    /// nil when nothing is at `path` (or it can't be stat'ed).
    static func current(atPath path: String) -> FileFingerprint? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileFingerprint(
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        )
    }
}

/// `.none` would read as `Optional.none` at call sites, hence `.unchanged`.
enum FileChange: Equatable {
    case unchanged
    case modified
    case deleted
    case recreated
}

@MainActor
final class MarkdownFileWatcher {
    static let debounceInterval: TimeInterval = 0.15

    private let path: String
    private let directoryPath: String
    private let onChange: (FileChange) -> Void
    private var fingerprint: FileFingerprint?
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingCheck: DispatchWorkItem?

    /// Starts watching immediately. `onChange` runs on the main queue and
    /// never with `.unchanged`. Call `stop()` when done.
    init(fileURL: URL, onChange: @escaping (FileChange) -> Void) {
        path = fileURL.path
        directoryPath = fileURL.deletingLastPathComponent().path
        self.onChange = onChange
        fingerprint = FileFingerprint.current(atPath: path)
        directorySource = makeSource(path: directoryPath, events: .write)
        attachFileSource()
    }

    func stop() {
        pendingCheck?.cancel()
        pendingCheck = nil
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
    }

    nonisolated static func classify(old: FileFingerprint?, new: FileFingerprint?) -> FileChange {
        switch (old, new) {
        case (nil, nil): return .unchanged
        case (nil, .some): return .recreated
        case (.some, nil): return .deleted
        case let (.some(old), .some(new)): return old == new ? .unchanged : .modified
        }
    }

    /// (Re)opens the file source on whatever file is at `path` now. The
    /// old source watched a vnode that an atomic save or delete retired.
    private func attachFileSource() {
        fileSource?.cancel()
        fileSource = makeSource(path: path, events: [.write, .extend, .attrib, .delete, .rename, .revoke])
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func check() {
        let new = FileFingerprint.current(atPath: path)
        let change = Self.classify(old: fingerprint, new: new)
        if new?.inode != fingerprint?.inode {
            attachFileSource()
        }
        fingerprint = new
        if change != .unchanged {
            onChange(change)
        }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/MarkdownFileWatcherTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`. 같은 명령을 한 번 더 돌려 두 번 다 통과하는지 확인한다(이벤트 테스트가 불안정하면 여기서 드러난다).

- [ ] **Step 5: 커밋**

```bash
git add apps/termy/Sources/MarkdownFileWatcher.swift apps/termy-tests/Sources/MarkdownFileWatcherTests.swift
git commit -m "feat(preview): 파일과 상위 디렉터리를 감시해 수정·atomic save·삭제·재생성을 알리는 watcher를 추가"
```

---

### Task 4: 프리뷰 창과 창 관리자

**Files:**
- Create: `apps/termy/Sources/MarkdownPreviewWindowController.swift`
- Create: `apps/termy/Sources/MarkdownPreviewManager.swift`
- Test: `apps/termy-tests/Sources/MarkdownPreviewWindowControllerTests.swift`
- Test: `apps/termy-tests/Sources/MarkdownPreviewManagerTests.swift`

**Interfaces:**
- Consumes:
  - `MarkdownHTMLRenderer.document(markdown:title:banner:)` (Task 1)
  - `MarkdownLinkResolver.resolve(linkText:baseDirectories:homeDirectory:isRegularFile:)`, `MarkdownLinkResolver.fileExistsAsRegularFile(_:)` (Task 2)
  - `MarkdownFileWatcher(fileURL:onChange:)`, `.stop()`, `FileChange` (Task 3)
- Produces:
  - `@MainActor final class MarkdownPreviewWindowController: NSWindowController`
    - `init(fileURL: URL, defaults: UserDefaults = .standard)`
    - `let fileURL: URL`, `var onClose: ((MarkdownPreviewWindowController) -> Void)?`
    - `enum LinkRoute: Equatable { case allow, cancel, openExternally(URL), preview(URL) }`
    - `nonisolated static func route(navigationType: WKNavigationType, url: URL?, documentURL: URL, isRegularFile: (String) -> Bool) -> LinkRoute`
    - `static func savedContentSize(defaults: UserDefaults) -> NSSize`, `static let defaultContentSize`, `static let contentSizeDefaultsKey`, `static let deletedBanner`
    - `nonisolated static func decodeMarkdown(_ data: Data) -> String`
  - `@MainActor final class MarkdownPreviewManager`
    - `static let shared`, `init(defaults: UserDefaults = .standard)`
    - `@discardableResult func open(_ url: URL) -> MarkdownPreviewWindowController`
    - `func closeAll()`
    - `private(set) var controllers: [String: MarkdownPreviewWindowController]`
    - `static func isPreviewWindow(_ window: NSWindow?) -> Bool`
    - `nonisolated static func key(for url: URL) -> String`

- [ ] **Step 1: 실패하는 테스트 작성 — 창 컨트롤러**

`apps/termy-tests/Sources/MarkdownPreviewWindowControllerTests.swift`:

```swift
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
```

- [ ] **Step 2: 실패하는 테스트 작성 — 관리자**

`apps/termy-tests/Sources/MarkdownPreviewManagerTests.swift`:

```swift
import XCTest
@testable import termy

@MainActor
final class MarkdownPreviewManagerTests: XCTestCase {
    private var manager: MarkdownPreviewManager!
    private var dir: URL!

    override func setUp() async throws {
        manager = MarkdownPreviewManager(
            defaults: UserDefaults(suiteName: "MarkdownPreviewManagerTests-\(UUID().uuidString)")!
        )
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
```

- [ ] **Step 3: 테스트가 실패하는지 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/MarkdownPreviewWindowControllerTests -only-testing:termy-tests/MarkdownPreviewManagerTests 2>&1 | tail -25`
Expected: 컴파일 실패, `cannot find 'MarkdownPreviewWindowController' in scope`.

- [ ] **Step 4: 창 컨트롤러 구현**

`apps/termy/Sources/MarkdownPreviewWindowController.swift`:

```swift
// MarkdownPreviewWindowController.swift
//
// One window per previewed markdown file (MarkdownPreviewManager keeps the
// one-per-file rule). The file is agent-written, so the WKWebView runs with
// page JavaScript off and every navigation is decided here: our own loads
// go through, links leave for the browser or open another preview, nothing
// else happens. Live reloads keep the reader's place by reading and
// restoring `scrollY` from the `.defaultClient` content world, which the
// page JavaScript switch doesn't affect.

import AppKit
import WebKit

@MainActor
final class MarkdownPreviewWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    static let defaultContentSize = NSSize(width: 820, height: 900)
    static let contentSizeDefaultsKey = "MarkdownPreview.contentSize"
    static let deletedBanner = "This file was deleted. The preview will reload if it comes back."

    /// Where a navigation inside the preview goes.
    enum LinkRoute: Equatable {
        case allow
        case cancel
        case openExternally(URL)
        case preview(URL)
    }

    let fileURL: URL
    /// Called from `windowWillClose`; the manager forgets the window here.
    var onClose: ((MarkdownPreviewWindowController) -> Void)?

    private let webView: WKWebView
    private let defaults: UserDefaults
    private var watcher: MarkdownFileWatcher?
    private var lastMarkdown = ""
    private var hasLoaded = false
    private var pendingScrollY: Double?

    init(fileURL: URL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.savedContentSize(defaults: defaults)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.lastPathComponent
        window.subtitle = (fileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        window.representedURL = fileURL
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init(window: window)

        window.delegate = self
        webView.navigationDelegate = self
        reload(after: nil)
        watcher = MarkdownFileWatcher(fileURL: fileURL) { [weak self] change in
            self?.reload(after: change)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Content size for a new preview window: the last one closed, or the
    /// default when nothing usable is stored.
    static func savedContentSize(defaults: UserDefaults) -> NSSize {
        guard let stored = defaults.string(forKey: contentSizeDefaultsKey) else {
            return defaultContentSize
        }
        let size = NSSizeFromString(stored)
        return size.width >= 320 && size.height >= 240 ? size : defaultContentSize
    }

    /// UTF-8 with invalid bytes replaced — one stray byte shouldn't hide
    /// the whole document behind an error.
    nonisolated static func decodeMarkdown(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    // MARK: - Loading

    /// Re-reads and renders the file. `change == nil` is the first load.
    private func reload(after change: FileChange?) {
        if change == .deleted {
            render(markdown: lastMarkdown, banner: Self.deletedBanner)
            return
        }
        do {
            lastMarkdown = Self.decodeMarkdown(try Data(contentsOf: fileURL))
            render(markdown: lastMarkdown, banner: nil)
        } catch {
            render(markdown: "", banner: "Couldn't read this file: \(error.localizedDescription)")
        }
    }

    private func render(markdown: String, banner: String?) {
        let html = MarkdownHTMLRenderer.document(
            markdown: markdown,
            title: fileURL.lastPathComponent,
            banner: banner
        )
        guard hasLoaded else {
            hasLoaded = true
            webView.loadHTMLString(html, baseURL: fileURL)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let scrollY = try? await self.webView.callAsyncJavaScript(
                "return window.scrollY;",
                contentWorld: .defaultClient
            ) as? Double
            self.pendingScrollY = scrollY
            self.webView.loadHTMLString(html, baseURL: self.fileURL)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let scrollY = pendingScrollY else { return }
        pendingScrollY = nil
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "window.scrollTo(0, y);",
                arguments: ["y": scrollY],
                contentWorld: .defaultClient
            )
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let route = Self.route(
            navigationType: navigationAction.navigationType,
            url: navigationAction.request.url,
            documentURL: fileURL,
            isRegularFile: MarkdownLinkResolver.fileExistsAsRegularFile
        )
        switch route {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case .openExternally(let url):
            NSWorkspace.shared.open(url)
            return .cancel
        case .preview(let url):
            MarkdownPreviewManager.shared.open(url)
            return .cancel
        }
    }

    /// Where a navigation inside the preview goes. Pure for testing.
    nonisolated static func route(
        navigationType: WKNavigationType,
        url: URL?,
        documentURL: URL,
        isRegularFile: (String) -> Bool
    ) -> LinkRoute {
        switch navigationType {
        case .other, .reload:
            // Our own `loadHTMLString` and the context menu's Reload. Page
            // JS is off and raw HTML is escaped, so the page itself can't
            // start one of these.
            return .allow
        case .linkActivated:
            guard let url else { return .cancel }
            return linkRoute(for: url, documentURL: documentURL, isRegularFile: isRegularFile)
        default:
            return .cancel
        }
    }

    nonisolated private static func linkRoute(
        for url: URL,
        documentURL: URL,
        isRegularFile: (String) -> Bool
    ) -> LinkRoute {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return .openExternally(url)
        case "file":
            if url.fragment != nil, url.path == documentURL.path {
                return .allow   // in-page anchor; WebKit scrolls to it
            }
            let resolution = MarkdownLinkResolver.resolve(
                linkText: url.absoluteString,
                baseDirectories: [],
                homeDirectory: NSHomeDirectory(),
                isRegularFile: isRegularFile
            )
            if case .file(let target) = resolution {
                return .preview(target)
            }
            return .cancel
        default:
            return .cancel
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        if let contentSize = window?.contentLayoutRect.size {
            defaults.set(NSStringFromSize(contentSize), forKey: Self.contentSizeDefaultsKey)
        }
        onClose?(self)
    }
}
```

참고: `decidePolicyFor`의 async 형태가 컴파일러 경고 "nearly matches optional requirement"를 내면, 경고가 제안하는 SDK 시그니처(`decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void`)로 바꾸고 같은 `route` 분기 뒤 `decisionHandler(...)`를 부른다. 이 경고가 남아 있으면 delegate 메서드가 아예 호출되지 않으므로 반드시 없애야 한다.

- [ ] **Step 5: 관리자 구현**

`apps/termy/Sources/MarkdownPreviewManager.swift`:

```swift
// MarkdownPreviewManager.swift
//
// One preview window per markdown file. Cmd+clicking a file that's already
// open brings its window forward instead of stacking another; files are
// keyed by their symlink-resolved standard path, so `./docs/x.md` and an
// absolute path to the same file share a window.

import AppKit

@MainActor
final class MarkdownPreviewManager {
    static let shared = MarkdownPreviewManager()

    private(set) var controllers: [String: MarkdownPreviewWindowController] = [:]
    private let defaults: UserDefaults
    /// Top-left for the next window in the cascade.
    private var nextTopLeft: NSPoint = .zero

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// True when `window` belongs to a markdown preview.
    static func isPreviewWindow(_ window: NSWindow?) -> Bool {
        window?.windowController is MarkdownPreviewWindowController
    }

    /// Shows the preview for `url`, reusing its window when already open.
    @discardableResult
    func open(_ url: URL) -> MarkdownPreviewWindowController {
        let key = Self.key(for: url)
        if let existing = controllers[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = MarkdownPreviewWindowController(fileURL: URL(fileURLWithPath: key), defaults: defaults)
        controller.onClose = { [weak self] _ in
            _ = self?.controllers.removeValue(forKey: key)
        }
        if let window = controller.window {
            if controllers.isEmpty {
                window.center()
                nextTopLeft = window.cascadeTopLeft(from: .zero)
            } else {
                nextTopLeft = window.cascadeTopLeft(from: nextTopLeft)
            }
        }
        controllers[key] = controller
        controller.showWindow(nil)
        return controller
    }

    /// Closes every preview window.
    func closeAll() {
        for controller in Array(controllers.values) {
            controller.close()
        }
    }
}
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/MarkdownPreviewWindowControllerTests -only-testing:termy-tests/MarkdownPreviewManagerTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`. 빌드 로그에 `nearly matches`가 없어야 한다:
`xcodebuild build-for-testing -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation 2>&1 | grep -i -E 'nearly matches|warning: .*Markdown' ; echo "exit=$?"` → 출력 없이 `exit=1`.

- [ ] **Step 7: 커밋**

```bash
git add apps/termy/Sources/MarkdownPreviewWindowController.swift apps/termy/Sources/MarkdownPreviewManager.swift apps/termy-tests/Sources/MarkdownPreviewWindowControllerTests.swift apps/termy-tests/Sources/MarkdownPreviewManagerTests.swift
git commit -m "feat(preview): 페이지 JS를 끈 WKWebView로 md 파일을 보여 주는 프리뷰 창과 파일당 창 하나를 지키는 관리자를 추가"
```

---

### Task 5: Cmd+클릭을 프리뷰에 연결

**Files:**
- Modify: `apps/termy/Sources/TermyTerminalView.swift` (파일 머리 주석, `openLinkUnderMouse` `:237-247`, `requestOpenLink`·`openableURL` 주석 `:249-271`, 새 프로퍼티·함수·enum)
- Modify: `apps/termy/Sources/Pane.swift` (init 안 `terminal.onClickInBounds = …` 다음, 새 메서드)
- Test: `apps/termy-tests/Sources/TermyTerminalViewTests.swift` (테스트 추가)
- Test: `apps/termy-tests/Sources/PaneMarkdownBaseDirectoriesTests.swift` (신규)

**Interfaces:**
- Consumes:
  - `MarkdownLinkResolver.resolve(...)`, `.fileExistsAsRegularFile(_:)`, `MarkdownLinkResolution` (Task 2)
  - `MarkdownPreviewManager.shared.open(_:)` (Task 4)
  - 기존: `TermyTerminalView.openableURL(from:)`, `MissionControlModel.shared.snapshot(paneId:)?.lastCwd`, `GitBranch.workTreeRoot(for:)`, `Pane.currentCwd`, `Pane.paneId`
- Produces:
  - `enum LinkClickAction: Equatable { case previewMarkdown(URL), beep, openURL(URL), ignore }`
  - `TermyTerminalView.markdownBaseDirectories: (() -> [String])?`
  - `TermyTerminalView.onOpenMarkdownFile: ((URL) -> Void)?`
  - `nonisolated static func TermyTerminalView.linkClickAction(for:baseDirectories:homeDirectory:isRegularFile:) -> LinkClickAction`
  - `nonisolated static func Pane.markdownBaseDirectories(agentCwd: String?, shellCwd: String, workTreeRoot: String?) -> [String]`

- [ ] **Step 1: 실패하는 테스트 작성**

`apps/termy-tests/Sources/TermyTerminalViewTests.swift`의 클래스 끝(마지막 `}` 앞)에 추가:

```swift
    // MARK: - Cmd+click link actions

    private func clickAction(_ text: String, existing: Set<String> = []) -> LinkClickAction {
        TermyTerminalView.linkClickAction(
            for: text,
            baseDirectories: ["/proj"],
            homeDirectory: "/Users/me",
            isRegularFile: { existing.contains($0) }
        )
    }

    func test_linkClickAction_existingMarkdownOpensPreview() {
        XCTAssertEqual(
            clickAction("docs/a.md", existing: ["/proj/docs/a.md"]),
            .previewMarkdown(URL(fileURLWithPath: "/proj/docs/a.md").resolvingSymlinksInPath())
        )
        XCTAssertEqual(
            clickAction("file:///proj/docs/a.md", existing: ["/proj/docs/a.md"]),
            .previewMarkdown(URL(fileURLWithPath: "/proj/docs/a.md").resolvingSymlinksInPath())
        )
    }

    func test_linkClickAction_missingMarkdownBeeps() {
        XCTAssertEqual(clickAction("docs/none.md"), .beep)
    }

    func test_linkClickAction_webURLOpensBrowser() {
        XCTAssertEqual(clickAction("https://example.com"), .openURL(URL(string: "https://example.com")!))
    }

    func test_linkClickAction_webURLEndingInMdOpensBrowser() {
        let link = "https://github.com/o/r/blob/main/README.md"
        XCTAssertEqual(clickAction(link), .openURL(URL(string: link)!))
    }

    func test_linkClickAction_otherPathsAreIgnored() {
        XCTAssertEqual(clickAction("src/main.swift", existing: ["/proj/src/main.swift"]), .ignore)
        XCTAssertEqual(clickAction("   "), .ignore)
    }

    /// Review Focus 1: Ink hard-wraps long lines by moving the cursor, so
    /// the second row is not a soft-wrapped continuation. SwiftTerm's
    /// `heuristicImplicitGroup` is what joins them; pin that it does.
    @MainActor
    func test_linkLookup_joinsInkStyleHardWrappedPath() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let terminal = view.getTerminal()
        terminal.resize(cols: 40, rows: 10)
        // Row 0 fills all 40 columns; Ink then does CR, cursor-down, and
        // indents the continuation by two columns.
        view.feed(text: "  docs/superpowers/specs/2026-10-12-mark\r\u{1b}[1B\u{1b}[2Cdown-preview-design.md")

        let path = "docs/superpowers/specs/2026-10-12-markdown-preview-design.md"
        XCTAssertEqual(terminal.link(at: .screen(Position(col: 10, row: 0)), mode: .explicitAndImplicit), path)
        XCTAssertEqual(terminal.link(at: .screen(Position(col: 5, row: 1)), mode: .explicitAndImplicit), path)
    }
```

**hard-wrap 테스트가 실패하면** 직접 줄을 이어 붙이는 로직을 만들지 말고, 두 `link(at:)` 호출이 실제로 돌려준 값을 적어 DONE_WITH_CONCERNS로 보고한다(SwiftTerm heuristic의 한계라 범위 결정이 필요하다). `Position` 이니셜라이저가 다르면 SwiftTerm 1.20.0 소스(`build/DerivedData-tests/SourcePackages/checkouts/SwiftTerm`)에서 확인해 맞춘다.

`apps/termy-tests/Sources/PaneMarkdownBaseDirectoriesTests.swift`:

```swift
import XCTest
@testable import termy

final class PaneMarkdownBaseDirectoriesTests: XCTestCase {
    func test_orderIsAgentThenShellThenRepoRoot() {
        XCTAssertEqual(
            Pane.markdownBaseDirectories(agentCwd: "/agent", shellCwd: "/shell/sub", workTreeRoot: "/shell"),
            ["/agent", "/shell/sub", "/shell"]
        )
    }

    func test_missingAndDuplicateEntriesAreDropped() {
        XCTAssertEqual(
            Pane.markdownBaseDirectories(agentCwd: nil, shellCwd: "/proj", workTreeRoot: "/proj"),
            ["/proj"]
        )
        XCTAssertEqual(
            Pane.markdownBaseDirectories(agentCwd: "", shellCwd: "/proj", workTreeRoot: nil),
            ["/proj"]
        )
        XCTAssertEqual(
            Pane.markdownBaseDirectories(agentCwd: "/proj", shellCwd: "/proj", workTreeRoot: nil),
            ["/proj"]
        )
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/TermyTerminalViewTests -only-testing:termy-tests/PaneMarkdownBaseDirectoriesTests 2>&1 | tail -25`
Expected: 컴파일 실패, `cannot find type 'LinkClickAction' in scope`.

- [ ] **Step 3: `TermyTerminalView` 수정**

(a) 파일 머리 주석(1–11행)의 마지막 문단 뒤에 한 문단을 덧붙인다:

```swift
//
// Cmd+click on a markdown file path (`docs/spec.md`, `./x.md:12`, …) opens
// it in a preview window instead: `linkClickAction` resolves the path
// against the pane's cwd candidates and the Pane opens the preview.
```

(b) `import SwiftTerm` 다음, `final class TermyTerminalView` 앞에 추가:

```swift
/// What a Cmd+click on a terminal link does.
enum LinkClickAction: Equatable {
    case previewMarkdown(URL)
    case beep
    case openURL(URL)
    case ignore
}
```

(c) `var onClickInBounds: (() -> Void)?` 선언 다음에 추가:

```swift
    /// Directories a relative markdown path is resolved against, most
    /// likely first. Set by Pane; without it only absolute and `~/` paths
    /// resolve.
    var markdownBaseDirectories: (() -> [String])?

    /// Opens a resolved markdown file in a preview window. Set by Pane.
    var onOpenMarkdownFile: ((URL) -> Void)?
```

(d) `openLinkUnderMouse(windowLocation:)` 전체(`:237-247`)를 교체:

```swift
    private func openLinkUnderMouse(windowLocation: NSPoint) -> Bool {
        guard let pos = cellPosition(at: windowLocation) else { return false }
        guard let raw = terminal.link(at: .screen(pos), mode: .explicitAndImplicit) else {
            return false
        }
        let action = Self.linkClickAction(
            for: raw,
            baseDirectories: markdownBaseDirectories?() ?? [],
            homeDirectory: NSHomeDirectory(),
            isRegularFile: MarkdownLinkResolver.fileExistsAsRegularFile
        )
        switch action {
        case .previewMarkdown(let url):
            onOpenMarkdownFile?(url)
            return true
        case .beep:
            // Consumed so SwiftTerm's own mouseUp doesn't act on it too.
            NSSound.beep()
            return true
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            return true
        case .ignore:
            return false
        }
    }

    /// Markdown files first (`file://` ones included, so they preview
    /// instead of launching the default app), then schemed URLs; any
    /// other path stays a no-op.
    nonisolated static func linkClickAction(
        for linkText: String,
        baseDirectories: [String],
        homeDirectory: String,
        isRegularFile: (String) -> Bool
    ) -> LinkClickAction {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignore }
        switch MarkdownLinkResolver.resolve(
            linkText: trimmed,
            baseDirectories: baseDirectories,
            homeDirectory: homeDirectory,
            isRegularFile: isRegularFile
        ) {
        case .file(let url):
            return .previewMarkdown(url)
        case .missing:
            return .beep
        case .notMarkdown:
            return openableURL(from: trimmed).map(LinkClickAction.openURL) ?? .ignore
        }
    }
```

(e) `requestOpenLink` 위 주석의 마지막 문장 "Hold SwiftTerm's path to the same scheme allowlist so a path-shaped click stays a no-op."을 아래로 바꾼다(동작은 그대로):

```swift
    /// launching it outright if it's an app or script. Hold SwiftTerm's path
    /// to the same scheme allowlist so a path-shaped click stays a no-op;
    /// markdown paths never get here because the monitor consumes them.
```

(`requestOpenLink` 본문과 `openableURL`은 바꾸지 않는다.)

- [ ] **Step 4: `Pane` 수정**

`Pane.init`의 다음 블록 바로 뒤에:

```swift
        terminal.onClickInBounds = { [weak self] in
            self?.onPaneClicked?()
        }
```

추가:

```swift
        terminal.markdownBaseDirectories = { [weak self] in
            self?.markdownBaseDirectories() ?? []
        }
        terminal.onOpenMarkdownFile = { url in
            _ = MarkdownPreviewManager.shared.open(url)
        }
```

`Pane` 클래스 안, `hostCurrentDirectoryUpdate` 앞(다른 cwd 관련 메서드 근처)에 추가:

```swift
    /// Where a relative markdown path printed in this pane most likely
    /// points: the agent's cwd (hook-reported — Claude Code prints paths
    /// relative to it), then the shell's, then the shell's repo root.
    func markdownBaseDirectories() -> [String] {
        Self.markdownBaseDirectories(
            agentCwd: MissionControlModel.shared.snapshot(paneId: paneId)?.lastCwd,
            shellCwd: currentCwd,
            workTreeRoot: GitBranch.workTreeRoot(for: currentCwd)
        )
    }

    nonisolated static func markdownBaseDirectories(
        agentCwd: String?,
        shellCwd: String,
        workTreeRoot: String?
    ) -> [String] {
        var result: [String] = []
        for directory in [agentCwd, shellCwd, workTreeRoot] {
            guard let directory, !directory.isEmpty, !result.contains(directory) else { continue }
            result.append(directory)
        }
        return result
    }
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/TermyTerminalViewTests -only-testing:termy-tests/PaneMarkdownBaseDirectoriesTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **` (hard-wrap 테스트가 실패하면 Step 1의 지시대로 보고한다).

- [ ] **Step 6: 커밋**

```bash
git add apps/termy/Sources/TermyTerminalView.swift apps/termy/Sources/Pane.swift apps/termy-tests/Sources/TermyTerminalViewTests.swift apps/termy-tests/Sources/PaneMarkdownBaseDirectoriesTests.swift
git commit -m "feat(preview): pane에서 md 경로를 Cmd+클릭하면 프리뷰 창을 열고 없는 파일이면 beep을 울림"
```

---

### Task 6: ⌘W와 pane 메뉴, 창 수명

**Files:**
- Modify: `apps/termy/Sources/AppDelegate.swift` (`activeController` `:141-146`, `closePane` `:164-166`, `validateMenuItem` `:298-310`, 새 static 멤버)
- Modify: `apps/termy/Sources/WindowManager.swift` (`removeWindow` `:102-109`)
- Test: `apps/termy-tests/Sources/AppDelegatePreviewMenuTests.swift` (신규)

**Interfaces:**
- Consumes: `MarkdownPreviewManager.isPreviewWindow(_:)`, `MarkdownPreviewManager.shared.closeAll()` (Task 4)
- Produces: `static func AppDelegate.previewMenuState(for action: Selector?, previewIsKey: Bool) -> (isEnabled: Bool, title: String?)`

- [ ] **Step 1: pane 액션 목록 확인**

Run: `grep -n 'activeController?' apps/termy/Sources/AppDelegate.swift`
Expected: 아래 Step 3의 `paneScopedActions`에 있는 액션 + `closePane`이 정확히 나온다. 목록에 없는 액션이 나오면 `paneScopedActions`에 더하고, 목록에 있는데 grep에 없는 액션은 뺀다.

- [ ] **Step 2: 실패하는 테스트 작성**

`apps/termy-tests/Sources/AppDelegatePreviewMenuTests.swift`:

```swift
import XCTest
@testable import termy

@MainActor
final class AppDelegatePreviewMenuTests: XCTestCase {
    private func state(_ action: Selector, previewIsKey: Bool) -> (isEnabled: Bool, title: String?) {
        AppDelegate.previewMenuState(for: action, previewIsKey: previewIsKey)
    }

    func test_closeItemClosesPreviewWhilePreviewIsKey() {
        let close = #selector(AppDelegate.closePane(_:))
        XCTAssertTrue(state(close, previewIsKey: true).isEnabled)
        XCTAssertEqual(state(close, previewIsKey: true).title, "Close Preview")
        XCTAssertTrue(state(close, previewIsKey: false).isEnabled)
        XCTAssertEqual(state(close, previewIsKey: false).title, "Close Pane")
    }

    func test_paneActionsDisabledOnlyWhilePreviewIsKey() {
        let paneActions: [Selector] = [
            #selector(AppDelegate.newPane(_:)),
            #selector(AppDelegate.splitRow(_:)),
            #selector(AppDelegate.splitColumn(_:)),
            #selector(AppDelegate.toggleMaximizePane(_:)),
            #selector(AppDelegate.focusNextPane(_:)),
            #selector(AppDelegate.focusPaneLeft(_:)),
            #selector(AppDelegate.cycleFilterNext(_:)),
            #selector(AppDelegate.selectFilter3(_:)),
            #selector(AppDelegate.showProjectSwitcher(_:)),
            #selector(AppDelegate.increaseFontSize(_:)),
            #selector(AppDelegate.cycleWaitingPane(_:)),
            #selector(AppDelegate.selectDashboard2(_:)),
        ]
        for action in paneActions {
            XCTAssertFalse(state(action, previewIsKey: true).isEnabled, "\(action)")
            XCTAssertTrue(state(action, previewIsKey: false).isEnabled, "\(action)")
            XCTAssertNil(state(action, previewIsKey: true).title, "\(action)")
        }
    }

    func test_appWideActionsStayEnabled() {
        let appActions: [Selector] = [
            #selector(AppDelegate.newWindow(_:)),
            #selector(AppDelegate.useDarkAppearance(_:)),
            #selector(AppDelegate.openNotificationSettings(_:)),
        ]
        for action in appActions {
            XCTAssertTrue(state(action, previewIsKey: true).isEnabled, "\(action)")
        }
    }
}
```

- [ ] **Step 3: 테스트가 실패하는지 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/AppDelegatePreviewMenuTests 2>&1 | tail -25`
Expected: 컴파일 실패, `type 'AppDelegate' has no member 'previewMenuState'`.

- [ ] **Step 4: `AppDelegate` 수정**

(a) `activeController`를 교체:

```swift
    private var activeController: MainWindowController? {
        // A focused markdown preview has no panes; without this, pane
        // commands would fall through to the first main window's panes.
        if MarkdownPreviewManager.isPreviewWindow(NSApp.keyWindow) {
            return nil
        }
        if let winCtrl = NSApp.keyWindow?.windowController as? MainWindowController {
            return winCtrl
        }
        return windowManager.controllers.first
    }
```

(b) `closePane`을 교체:

```swift
    @IBAction func closePane(_ sender: Any?) {
        // ⌘W on a focused preview closes the preview, never a pane.
        if let keyWindow = NSApp.keyWindow, MarkdownPreviewManager.isPreviewWindow(keyWindow) {
            keyWindow.performClose(sender)
            return
        }
        activeController?.closePane(sender)
    }
```

(c) `validateMenuItem`을 교체:

```swift
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(useSystemAppearance(_:)):
            menuItem.state = selectedAppearancePreference == .system ? .on : .off
        case #selector(useLightAppearance(_:)):
            menuItem.state = selectedAppearancePreference == .light ? .on : .off
        case #selector(useDarkAppearance(_:)):
            menuItem.state = selectedAppearancePreference == .dark ? .on : .off
        default:
            break
        }
        let previewState = Self.previewMenuState(
            for: menuItem.action,
            previewIsKey: MarkdownPreviewManager.isPreviewWindow(NSApp.keyWindow)
        )
        if let title = previewState.title {
            menuItem.title = title
        }
        return previewState.isEnabled
    }

    /// Enablement, and the ⌘W title, when a markdown preview may be the
    /// key window. Pure so the pane-action list is testable.
    static func previewMenuState(for action: Selector?, previewIsKey: Bool) -> (isEnabled: Bool, title: String?) {
        if action == #selector(AppDelegate.closePane(_:)) {
            return (true, previewIsKey ? "Close Preview" : "Close Pane")
        }
        guard previewIsKey, let action else { return (true, nil) }
        return (!paneScopedActions.contains(action), nil)
    }

    /// Every action that goes through `activeController` (except
    /// `closePane`, which closes the preview instead). `activeController`
    /// is nil while a preview is key, so these would do nothing.
    private static let paneScopedActions: Set<Selector> = [
        #selector(AppDelegate.newPane(_:)),
        #selector(AppDelegate.splitColumn(_:)),
        #selector(AppDelegate.splitRow(_:)),
        #selector(AppDelegate.toggleMaximizePane(_:)),
        #selector(AppDelegate.focusPrevPane(_:)),
        #selector(AppDelegate.focusNextPane(_:)),
        #selector(AppDelegate.focusPaneLeft(_:)),
        #selector(AppDelegate.focusPaneRight(_:)),
        #selector(AppDelegate.focusPaneUp(_:)),
        #selector(AppDelegate.focusPaneDown(_:)),
        #selector(AppDelegate.cycleFilterPrev(_:)),
        #selector(AppDelegate.cycleFilterNext(_:)),
        #selector(AppDelegate.showProjectSwitcher(_:)),
        #selector(AppDelegate.showKeyboardShortcuts(_:)),
        #selector(AppDelegate.showFontSettings(_:)),
        #selector(AppDelegate.increaseFontSize(_:)),
        #selector(AppDelegate.decreaseFontSize(_:)),
        #selector(AppDelegate.selectFilter0(_:)),
        #selector(AppDelegate.selectFilter1(_:)),
        #selector(AppDelegate.selectFilter2(_:)),
        #selector(AppDelegate.selectFilter3(_:)),
        #selector(AppDelegate.selectFilter4(_:)),
        #selector(AppDelegate.selectFilter5(_:)),
        #selector(AppDelegate.selectFilter6(_:)),
        #selector(AppDelegate.selectFilter7(_:)),
        #selector(AppDelegate.selectFilter8(_:)),
        #selector(AppDelegate.selectFilter9(_:)),
        #selector(AppDelegate.cycleDashboardPrev(_:)),
        #selector(AppDelegate.cycleDashboardNext(_:)),
        #selector(AppDelegate.cycleWaitingPane(_:)),
        #selector(AppDelegate.selectDashboard1(_:)),
        #selector(AppDelegate.selectDashboard2(_:)),
        #selector(AppDelegate.selectDashboard3(_:)),
        #selector(AppDelegate.selectDashboard4(_:)),
        #selector(AppDelegate.selectDashboard5(_:)),
        #selector(AppDelegate.selectDashboard6(_:)),
        #selector(AppDelegate.selectDashboard7(_:)),
        #selector(AppDelegate.selectDashboard8(_:)),
        #selector(AppDelegate.selectDashboard9(_:)),
    ]
```

- [ ] **Step 5: `WindowManager.removeWindow` 수정**

`sessionAutosaver?.requestSave()` 다음 줄에 추가:

```swift
        // Previews belong to the main windows. With none left, close them
        // too so "closing the last window quits termy" still holds.
        if controllers.isEmpty {
            MarkdownPreviewManager.shared.closeAll()
        }
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/AppDelegatePreviewMenuTests -only-testing:termy-tests/WindowManagerTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: 커밋**

```bash
git add apps/termy/Sources/AppDelegate.swift apps/termy/Sources/WindowManager.swift apps/termy-tests/Sources/AppDelegatePreviewMenuTests.swift
git commit -m "fix(preview): 프리뷰 창이 key일 때 ⌘W가 pane 대신 프리뷰를 닫고 pane 메뉴를 끄며, 마지막 메인 창과 함께 프리뷰도 닫음"
```

---

### Task 7: 마무리 — 전체 테스트, CHANGELOG, 실제 앱 검증 (controller 담당)

**Files:**
- Modify: `CHANGELOG.md` (`## Unreleased` 아래)

- [ ] **Step 1: 전체 테스트**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: CHANGELOG 항목 추가**

`CHANGELOG.md`의 `## Unreleased` 바로 아래(빈 줄 하나 두고)에 추가:

```markdown
- Cmd+click a Markdown file path in a pane — a spec or plan Claude Code
  just wrote, for example — to open it rendered in its own window. Tables,
  task lists and code blocks look the way they do on GitHub, and the
  preview follows termy's light or dark appearance. When an agent edits
  the file, the preview updates in place and keeps your scroll position.
  Clicking a path to a file that doesn't exist beeps. ⌘W closes the
  preview without touching your panes.
```

커밋:

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): md 경로 Cmd+클릭 프리뷰 항목을 추가"
```

- [ ] **Step 3: Debug 빌드**

Run: `xcodebuild build -project termy.xcodeproj -scheme termy -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData-debug -skipPackagePluginValidation 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. 앱은 실행하지 않는다(세션이 termy 안에서 돈다).

- [ ] **Step 4: 사용자에게 실제 앱 검증 요청**

빌드 경로(`build/DerivedData-debug/Build/Products/Debug/termy.app`)와 spec §10 체크리스트를 사용자에게 전달하고 결과를 받는다. 실패 항목은 `superpowers:systematic-debugging`으로 다룬다.

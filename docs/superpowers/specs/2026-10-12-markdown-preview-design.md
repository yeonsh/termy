# Markdown 프리뷰 창 — 설계 문서

- 날짜: 2026-10-12
- 상태: 동작 범위 승인(2026-10-12), 구현 진행
- 범위: termy pane에서 `.md` 파일 경로를 Cmd+클릭하면 렌더링된 프리뷰 창을 띄운다

## 1. 목표와 동기

Claude Code는 spec·plan 문서를 쓰고 나서 `docs/superpowers/specs/…-design.md` 같은 경로를
출력한다. 지금은 그 경로를 Cmd+클릭해도 아무 일이 일어나지 않는다. 검토하려면 다른 앱을 열고
경로를 찾아가야 한다.

이 작업의 목표는 **agent가 쓴 문서를 그 자리에서 열어 편하게 읽고, agent가 고치면 바로 다시
보는 것**이다. 주 사용 장면은 spec·plan 검토다(긴 문서를 꼼꼼히 읽는다).

성공 기준:

- Claude Code 출력에 나온 `.md` 경로를 Cmd+클릭하면 렌더링된 프리뷰 창이 뜬다.
- 표, 체크리스트, 언어 지정 코드 블록이 GitHub와 비슷하게 보인다.
- agent가 파일을 고치면 스크롤 위치를 유지한 채 다시 그려진다.
- 프리뷰 창에서 ⌘W를 누르면 프리뷰만 닫히고 pane은 건드리지 않는다.

## 2. 비목표

- 코드 문법 색상, mermaid, 수식
- 이미지 표시(대체 텍스트만 보여 준다)
- 편집, ⌘F 찾기
- md가 아닌 파일 열기, 줄 번호(`:12`) 위치로 이동
- 맨 URL 자동 링크(swift-markdown은 cmark-gfm `autolink` 확장을 붙이지 않는다)
- 프리뷰 창의 세션 저장·복원, Mission Control 표시
- 설정 UI

## 3. 현재 구조 (출발점)

- **Cmd+클릭**: `TermyTerminalView.installLinkClickMonitor`(`TermyTerminalView.swift:219`)가
  `leftMouseUp`을 가로채 `terminal.link(at:mode: .explicitAndImplicit)`로 링크 텍스트를 얻고,
  `openableURL`(scheme 허용 목록)을 통과한 URL만 `NSWorkspace`로 연다. 경로는 scheme이 없어서
  통과하지 못하고, 이벤트는 SwiftTerm의 `mouseUp` → `requestOpenLink` override로 넘어가 거기서도
  무시된다.
- **SwiftTerm 링크 감지**(1.20.0, `Terminal.swift:6193`): Ghostty식 정규식이 `/abs`, `~/`,
  `./`, `../`, `dir/file.ext` 형태 경로를 잡는다. soft-wrap 줄은 이어 붙이고, Ink처럼 커서
  이동으로 hard-wrap한 줄도 `heuristicImplicitGroup`으로 이어 붙이려 시도한다.
- **cwd 출처**: `Pane.currentCwd`(OSC 7, 셸 cwd), `MissionControlModel.shared.snapshot(paneId:)?.lastCwd`
  (hook으로 받은 agent cwd), `GitBranch.workTreeRoot(for:)`.
- **메뉴**: ⌘W는 `AppDelegate.closePane`이다. `activeController`(`AppDelegate.swift:141`)는 key
  window가 `MainWindowController`가 아니면 `windowManager.controllers.first`로 대체한다. 그래서
  다른 창이 key인 상태에서 ⌘W를 누르면 **첫 메인 창의 pane이 닫힌다.**
- **창 수명**: `applicationShouldTerminateAfterLastWindowClosed`가 `true`다.
  `WindowManager.removeWindow`가 메인 창 목록을 관리한다.
- **외형**: `AppAppearance`가 `NSApp.appearance`를 설정한다. 새 창은 이를 물려받는다.
- **의존성**: WebKit, markdown 라이브러리 없음. UI 문구는 영어.

## 4. 결정 사항

| 항목 | 결정 | 이유 |
|---|---|---|
| 트리거 | Cmd+클릭 | 기존 링크 관례와 hover 밑줄을 그대로 쓴다 |
| 표시 위치 | 별도 창 | pane 크기가 변하지 않아 TUI가 다시 그리지 않는다. 다른 모니터에 둘 수 있다 |
| 창 재사용 | 파일마다 창 하나 | spec과 plan을 나란히 본다. 같은 파일은 기존 창을 앞으로 |
| 파싱 | swift-markdown 0.9.0 (cmark-gfm) | 표·체크리스트·취소선을 정확히 파싱한다 |
| HTML 출력 | termy 자체 writer | 기본 `HTMLFormatter`는 텍스트·코드를 escape하지 않고 heading id가 없다 |
| 표시 | WKWebView, 페이지 JavaScript 끔 | agent가 쓴 파일 안의 HTML/script가 실행되지 않는다 |
| raw HTML | escape해서 글자로 보여 준다 | 안전하고 단순하다. 검토용으로 충분하다 |
| 갱신 | 파일·상위 디렉터리 이벤트 감시 | 즉시 반영. atomic save(rename)도 잡는다 |
| 파일 없음 | `NSSound.beep()` | 아무 반응이 없으면 고장으로 보인다 |
| 문구 | 영어 | 기존 UI와 맞춘다 |

## 5. 컴포넌트 설계

새 파일은 모두 `apps/termy/Sources/` 아래에 둔다.

### 5.1 의존성 — `project.yml`

```yaml
packages:
  Markdown:
    url: https://github.com/swiftlang/swift-markdown
    exactVersion: "0.9.0"
```

`termy` 타깃 dependencies에 `- package: Markdown` / `product: Markdown`을 더하고 `xcodegen`으로
프로젝트를 다시 만든다. swift-cmark는 swift-markdown이 끌어온다. 다른 패키지처럼 정확한
버전으로 고정한다.

### 5.2 경로 해석 — `MarkdownLinkResolver` (순수 함수)

```swift
enum MarkdownLinkResolution: Equatable {
    case notMarkdown          // md 링크가 아니다 → 기존 흐름
    case missing              // md 경로처럼 생겼지만 파일이 없다 → beep
    case file(URL)            // 열 파일 (symlink를 푼 표준 경로)
}

enum MarkdownLinkResolver {
    static let extensions: Set<String> = ["md", "markdown"]

    nonisolated static func resolve(
        linkText: String,
        baseDirectories: [String],
        homeDirectory: String,
        isRegularFile: (String) -> Bool
    ) -> MarkdownLinkResolution
}
```

정규화 순서:

1. 앞뒤 공백을 자른다. 앞쪽의 `(` `[` `` ` `` `'` `"`, 뒤쪽의 `.` `,` `;` `:` `!` `?` `)` `]`
   `` ` `` `'` `"`를 반복해서 떼어 낸다.
2. `file://`로 시작하면 `URL(string:)`의 `path`(percent 디코딩됨)를 쓴다.
3. `#` 뒤(fragment: `#L12`, `#heading`)를 버린다. 끝의 `:숫자` 또는 `:숫자:숫자`를 버린다.
4. 마지막 경로 요소의 확장자가 `extensions`에 없으면(대소문자 무시) `.notMarkdown`.
5. `~/`로 시작하면 `homeDirectory`로 바꾼다. `/`로 시작하면 절대 경로다. 그 밖은 상대 경로로
   보고 `baseDirectories`의 각 항목(빈 값 제외, 중복 제거, 주어진 순서)에 붙인 후보를 만든다.
6. 후보마다 `standardizingPath`를 적용하고, `isRegularFile`이 처음으로 `true`인 후보를
   `URL(fileURLWithPath:).resolvingSymlinksInPath()`로 돌려준다. 없으면 `.missing`.

### 5.3 클릭 연결 — `TermyTerminalView`, `Pane`

`TermyTerminalView`에 결정 함수와 연결 지점을 더한다.

```swift
enum LinkClickAction: Equatable {
    case previewMarkdown(URL)
    case beep
    case openURL(URL)
    case ignore
}

// TermyTerminalView
var markdownBaseDirectories: (() -> [String])?
var onOpenMarkdownFile: ((URL) -> Void)?

nonisolated static func linkClickAction(
    for linkText: String,
    baseDirectories: [String],
    homeDirectory: String,
    isRegularFile: (String) -> Bool
) -> LinkClickAction
```

- `linkClickAction`은 먼저 `MarkdownLinkResolver`를 부른다. `.file` → `.previewMarkdown`,
  `.missing` → `.beep`. `.notMarkdown`이면 기존 `openableURL` → `.openURL`, 아니면 `.ignore`.
  그래서 `file:///…/x.md`도 기본 앱 대신 프리뷰로 열린다.
- `openLinkUnderMouse`는 이 결과를 실행한다. `.previewMarkdown`, `.beep`, `.openURL`이면 `true`를
  돌려줘 이벤트를 소비한다. 그래야 SwiftTerm의 `mouseUp`이 같은 클릭을 다시 처리하지 않는다.
  `.ignore`이면 지금처럼 `false`.
- `requestOpenLink` override는 그대로 둔다(md 클릭은 monitor가 이미 소비한다).
- `Pane`은 생성 시 두 closure를 연결한다.
  - `markdownBaseDirectories`: `[agent cwd(lastCwd), currentCwd, GitBranch.workTreeRoot(for: currentCwd)]`에서
    nil을 빼고 중복을 제거한 목록. agent cwd를 먼저 보는 이유는 Claude Code가 출력하는 상대
    경로의 기준이 agent의 cwd이기 때문이다.
  - `onOpenMarkdownFile`: `MarkdownPreviewManager.shared.open(url)`.

### 5.4 렌더링 — `MarkdownHTMLRenderer` (순수 함수)

```swift
enum MarkdownHTMLRenderer {
    /// 완성된 HTML 문서. `banner`가 있으면 본문 위에 경고 띠를 넣는다.
    nonisolated static func document(markdown: String, title: String, banner: String? = nil) -> String
    /// `<main>` 안에 들어갈 본문 HTML.
    nonisolated static func body(markdown: String) -> String
}

struct MarkdownHTMLWriter: MarkupWalker { … }   // swift-markdown `Document(parsing:)` 결과를 순회
```

출력 규칙:

- 텍스트, inline code, 코드 블록 내용, 링크 주소, 속성 값을 모두 HTML escape한다
  (`&` `<` `>` `"` `'`).
- heading: `<hN id="slug">` 안에 inline 자식을 렌더링한다(`plainText`가 아니다). slug는
  GitHub식이다. 소문자로 바꾸고, 글자·숫자(한글 포함)·`-`·`_`만 남기고, 공백은 `-`로 바꾼다.
  같은 slug가 다시 나오면 `-1`, `-2`를 붙인다.
- 코드 블록: `<pre><code class="language-x">…</code></pre>`. 언어 이름도 escape한다.
- 체크리스트 항목: `<li class="task-list-item"><input type="checkbox" disabled [checked]> …`.
- 표: `<table><thead>…</thead><tbody>…</tbody></table>`. 열 정렬은
  `style="text-align: left|center|right"`.
- 순서 있는 목록은 시작 번호가 1이 아니면 `start` 속성을 넣는다.
- 이미지: `<span class="image-alt">[image: 대체 텍스트]</span>`.
- `HTMLBlock`, `InlineHTML`: escape한 글자로 출력한다(블록은 `<p>`로 감싼다).
- 취소선 `<del>`, 강조 `<em>` / `<strong>`, 인용 `<blockquote>`, 구분선 `<hr>`,
  soft break는 `\n`, line break는 `<br>`.

`document()`의 골격:

```html
<!doctype html>
<html><head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<meta name="color-scheme" content="light dark">
<title>…</title>
<style>…</style>
</head><body><main class="markdown-body">[banner]…</main></body></html>
```

CSS는 `MarkdownPreviewStyle.swift`의 문자열 상수로 둔다(리소스 파일을 추가하지 않는다).
GitHub와 비슷하게 꾸미고, 시스템 글꼴과 `ui-monospace`를 쓴다. 본문 최대 폭은 900px로
가운데 정렬하고, `prefers-color-scheme`로 라이트/다크를 나눈다.

### 5.5 파일 감시 — `MarkdownFileWatcher`

```swift
struct FileFingerprint: Equatable { let inode: UInt64; let size: Int64; let mtimeNanoseconds: Int64 }

enum FileChange: Equatable { case none, modified, deleted, recreated }

final class MarkdownFileWatcher {
    init(fileURL: URL, onChange: @escaping (FileChange) -> Void)
    func stop()
    nonisolated static func classify(old: FileFingerprint?, new: FileFingerprint?) -> FileChange
}
```

- 파일 자체(`DispatchSource.makeFileSystemObjectSource`, 이벤트 `.write .extend .attrib .delete
  .rename .revoke`)와 상위 디렉터리(`.write`)를 함께 감시한다. 파일 감시는 내용 변경을,
  디렉터리 감시는 atomic save로 파일이 다시 생기는 것을 잡는다.
- 이벤트가 오면 main queue에서 150ms debounce한 뒤 `stat`으로 fingerprint를 다시 구하고
  `classify`로 판정한다.
  - `nil → nil`: `.none`
  - 같음: `.none`
  - `a → b`(inode·크기·mtime 중 하나라도 다름): `.modified`
  - `a → nil`: `.deleted`
  - `nil → a`: `.recreated`
- 파일이 삭제되거나 rename되면 파일 source를 정리한다. 다시 생기면 새 fd로 다시 단다.
- `stop()`은 두 source를 cancel하고, cancel handler에서 fd를 닫는다.

### 5.6 창 — `MarkdownPreviewWindowController`, `MarkdownPreviewManager`

`MarkdownPreviewManager` (`@MainActor`, `static let shared`):

- `open(_ url: URL)`: 키는 `url.standardizedFileURL.resolvingSymlinksInPath().path`다. 이미 열린
  창이 있으면 `makeKeyAndOrderFront`, 없으면 새 controller를 만들어 보여 준다.
- `closeAll()`: 열린 프리뷰 창을 모두 닫는다.
- controller의 `windowWillClose`에서 목록에서 뺀다.
- `isPreviewWindow(_ window: NSWindow?) -> Bool`: AppDelegate가 메뉴 판정에 쓴다.

`MarkdownPreviewWindowController` (`NSWindowController`, `NSWindowDelegate`, `WKNavigationDelegate`):

- 창: titled, closable, miniaturizable, resizable. `title` = 파일 이름, `subtitle` = 상위 디렉터리
  (`~`로 줄임), `representedURL` = 파일 URL(제목 proxy 아이콘). `tabbingMode = .disallowed`,
  `isReleasedWhenClosed = false`.
- 크기: 기본 content size 820×900. 마지막으로 닫은 창의 크기를 UserDefaults
  `MarkdownPreview.contentSize`에 저장해 다음 창에 쓴다. 첫 창은 `center()`, 다음 창부터는
  가장 최근 프리뷰 창 기준으로 `cascadeTopLeft(from:)`.
- WKWebView 구성: `defaultWebpagePreferences.allowsContentJavaScript = false`,
  `websiteDataStore = .nonPersistent()`.
- 불러오기: 파일을 UTF-8로 읽는다(실패하면 `String(decoding:as: UTF8.self)`로 손실 허용 디코딩).
  `MarkdownHTMLRenderer.document`로 HTML을 만들고 `loadHTMLString(html, baseURL: fileURL)`로
  띄운다. baseURL을 파일 URL로 두면 문서 안의 상대 링크가 파일 위치 기준으로 풀린다.
- 갱신(`FileChange`):
  - `.modified` / `.recreated`: 다시 읽고 렌더링한다. 그 전에 앱 쪽 content world
    (`WKContentWorld.defaultClient`)에서 `window.scrollY`를 읽어 두었다가, `didFinish` 뒤
    `window.scrollTo(0, y)`로 되돌린다.
  - `.deleted`: 마지막 markdown을 banner와 함께 다시 그린다. 문구:
    "This file was deleted. The preview will reload if it comes back."
- 읽기 실패(권한 등): 본문 대신 "Couldn't read this file: <이유>"를 보여 준다.
- 링크 정책(`decidePolicyFor navigationAction`):
  - 우리가 부른 `loadHTMLString`(`navigationType == .other`): 허용.
  - 같은 문서의 fragment 이동(fragment를 뗀 URL이 현재 문서 URL과 같음): 허용(WebKit이 스크롤).
  - 그 밖의 `.linkActivated`는 취소하고 직접 처리한다.
    - `http` / `https` / `mailto`: `NSWorkspace.shared.open`.
    - `file` URL: `MarkdownLinkResolver.resolve`(기준 디렉터리 = 이 파일의 디렉터리)가
      `.file`이면 `MarkdownPreviewManager.shared.open`, 아니면 무시.
    - 그 밖: 무시.
  - 나머지 navigation은 모두 취소한다.

### 5.7 메뉴와 창 수명 — `AppDelegate`, `WindowManager`

- `AppDelegate.activeController`: key window가 프리뷰 창이면 `nil`을 돌려준다. 그래서 pane을
  다루는 모든 메뉴 액션이 프리뷰에 포커스가 있는 동안 메인 창에 닿지 않는다.
- `AppDelegate.closePane`: key window가 프리뷰 창이면 그 창을 `performClose`한다.
- `AppDelegate.validateMenuItem`: key window가 프리뷰 창일 때
  - `closePane` 항목은 활성 상태로 두고 제목을 "Close Preview"로 바꾼다(아니면 "Close Pane").
  - `activeController`를 거치는 나머지 액션(새 pane, split, maximize, pane 이동, 필터,
    프로젝트 전환기, 단축키 패널, 글꼴, dashboard 순환)은 비활성화한다.
- `WindowManager.removeWindow`: 메인 창 목록이 비면 `MarkdownPreviewManager.shared.closeAll()`을
  부른다. 프리뷰 창만 남아서 앱이 종료되지 않는 일을 막고, 지금의 "마지막 창을 닫으면 종료"
  동작을 유지한다.

## 6. 전체 흐름

```
Cmd+클릭 (leftMouseUp)
  → TermyTerminalView link monitor
  → cellPosition → terminal.link(at:mode:)
  → linkClickAction(linkText, Pane.markdownBaseDirectories(), home, isRegularFile)
      .previewMarkdown(url) → Pane.onOpenMarkdownFile → MarkdownPreviewManager.open(url)
                               → (기존 창 앞으로) 또는 (새 창: 읽기 → 렌더링 → WKWebView)
      .beep                 → NSSound.beep()
      .openURL(url)         → NSWorkspace.open (기존 동작)
      .ignore               → 이벤트 통과 (기존 동작)

파일 변경 → MarkdownFileWatcher (debounce 150ms, classify)
  → controller: scrollY 저장 → 다시 렌더링 → didFinish → scrollTo
```

## 7. 엣지 케이스

- **hard-wrap된 긴 경로**: SwiftTerm의 `heuristicImplicitGroup`에 기댄다. 일부만 잡히면 그
  경로가 없어 beep이 난다. 실제 앱에서 좁은 pane으로 확인한다(§10).
- **공백이 든 경로**: SwiftTerm 정규식이 잡는 범위 안에서만 동작한다. 못 잡으면 `.ignore`나 beep.
- **`$HOME/x.md` 같은 변수 경로**: 변수를 풀지 않는다. 상대 경로로 취급되어 대개 beep.
- **같은 파일, 다른 표기**(`./docs/x.md`, symlink, 절대 경로): 표준 경로 키로 창 하나에 모인다.
- **`x.md`라는 이름의 디렉터리**: `isRegularFile`이 false라 beep.
- **agent가 연달아 쓰기**: 150ms debounce로 한 번만 다시 그린다.
- **UTF-8이 아닌 파일**: 손실 허용 디코딩으로 보여 준다.
- **메인 창을 모두 닫음**: 프리뷰도 함께 닫히고 앱이 종료된다(§5.7).
- **앱 재시작·업데이트**: 프리뷰 창은 복원하지 않는다. session.json은 바뀌지 않는다.
- **mouse reporting 중인 TUI**: Cmd+클릭은 이미 reporting을 잠시 끄고 처리한다(기존 동작).
- **`file:///…/x.md` URL**: 기본 앱 대신 프리뷰로 연다(의도한 동작 변경).

## 8. 테스트 전략

단위 테스트(XCTest, `apps/termy-tests/Sources/`):

- `MarkdownLinkResolverTests`: 절대·`~`·상대(기준 순서)·`./`·`../`·`file://`·percent 인코딩,
  `:12`·`:12:3`·`#L12` 접미사, 앞뒤 구두점, 대문자 `.MD`, `.markdown`, md 아님 →
  `.notMarkdown`, 파일 없음·디렉터리 → `.missing`. 파일 시스템은 `isRegularFile` 주입으로
  흉내 내고, symlink 해석은 임시 디렉터리로 한 번 확인한다.
- `TermyTerminalViewTests`에 `linkClickAction` 추가: https → `.openURL`, 있는 md →
  `.previewMarkdown`, 없는 md → `.beep`, md 아닌 경로 → `.ignore`, `file://…md` → `.previewMarkdown`.
- `MarkdownHTMLRendererTests`: 텍스트·inline code·코드 블록 escape, heading slug(한글·중복·구두점),
  heading 안의 inline code, 표 정렬, 체크리스트, raw HTML escape, 링크 주소 escape, 이미지 대체
  텍스트, CSP meta, banner.
- `MarkdownFileWatcherTests`: `classify`의 다섯 경우와 inode만 바뀐 경우. 임시 파일로 실제
  수정·삭제·rename 후 재생성 이벤트를 받는지 한 번씩 확인한다(expectation, 짧은 timeout).
- `MarkdownPreviewManagerTests`: 같은 URL 두 번 → 창 하나, symlink 경로 → 같은 창,
  `closeAll` 후 비어 있음, `isPreviewWindow` 판정.

실제 동작 검증은 §10.

## 9. 구현 전 확인 항목

1. swift-markdown 0.9.0이 termy 빌드(Xcode 26.6, Swift 6 언어 모드,
   `-skipPackagePluginValidation`)에서 resolve·컴파일되는가.
2. `allowsContentJavaScript = false`인 상태에서 `.defaultClient` content world의
   `evaluateJavaScript` / `callAsyncJavaScript`가 동작하는가(스크롤 유지). 안 되면 JS를 켜고 CSP
   `script-src 'none'`으로 페이지 script를 막는 쪽으로 바꾼다.
3. WKWebView의 `prefers-color-scheme`가 `NSApp.appearance`(termy 라이트/다크 설정)를 따르는가.

## 10. 실제 동작 검증

이 작업 세션은 termy 안에서 돈다(`TERMY_PANE_ID` 설정됨). 그래서 termy를 직접 다시 띄워
확인할 수 없고, Debug 빌드(`-derivedDataPath build/DerivedData-debug`)를 만든 뒤 사용자가
아래 목록을 확인한다.

- [ ] Claude Code가 출력한 상대 경로 `.md`를 Cmd+클릭 → 프리뷰 창이 뜬다.
- [ ] 같은 경로를 다시 Cmd+클릭 → 새 창 없이 기존 창이 앞으로 온다.
- [ ] 다른 `.md` 경로 → 창이 하나 더 뜬다.
- [ ] 좁은 pane에서 두 줄로 나뉜 긴 경로를 Cmd+클릭 → 열린다(안 되면 기록).
- [ ] 없는 `.md` 경로 → beep, 창 없음.
- [ ] 표·체크리스트·코드 블록이 제대로 보인다. 라이트/다크 전환을 따른다.
- [ ] agent가 파일을 고치면 스크롤 위치를 유지한 채 갱신된다.
- [ ] 프리뷰에 포커스를 두고 ⌘W → 프리뷰만 닫힌다. File 메뉴 제목이 "Close Preview"다.
- [ ] 프리뷰에 포커스를 두고 ⌘T / split 단축키 → 아무 일도 없다.
- [ ] 프리뷰 안 `https` 링크 → 브라우저, 상대 `.md` 링크 → 새 프리뷰 창, `#heading` 링크 → 이동.
- [ ] 메인 창을 모두 닫음 → 프리뷰도 닫히고 앱이 종료된다.

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
2. `file://`로 시작하면 `URL(string:)`의 `path`(percent 디코딩됨)를 쓴다. 그 밖에 `://`가
   들어 있으면(`https://…/README.md` 같은 웹 URL) `.notMarkdown`이다.
3. `#` 뒤(fragment: `#L12`, `#heading`)를 버린다. 끝의 `:숫자` 또는 `:숫자:숫자`를 버린다.
4. 확장자가 `extensions`에 없으면, 뒤에 파일 이름 문자(`[A-Za-z0-9._/-]`)가 이어지지 않는 첫
   `.md`/`.markdown`(대소문자 무시) 바로 뒤에서 자른다(`^.*?\.(md|markdown)(?![A-Za-z0-9._/-])`).
   그런 곳이 없으면 `.notMarkdown`이다. SwiftTerm 1.20.0의 implicit link 정규식은 한글을 `\w`로
   보고, 공백 뒤라도 `.`이나 `/`로 끝나는 조각까지 이어 붙인다. 그래서 실제로 이런 링크 텍스트가 온다.
   - `스펙을 docs/…/x-design.md에 저장했습니다.` → `docs/…/x-design.md에 저장했습니다.`
   - `docs/…/x.md를 보세요` → `docs/…/x.md를`
   - `The plan is in docs/…/x.md now.` → `docs/…/x.md now.`
   - `cat **docs/x.md** now` → `docs/x.md**`

   자르고 나면 모두 `docs/…/x.md`가 된다. 줄 번호 뒤에 조사가 붙은 `docs/x.md:12에서`는
   `:12에서`가 숫자로만 되어 있지 않아 3단계에서 남지만, 여기서 `.md` 뒤의 `:`에서 잘린다. `docs/x.mdx`,
   `README.md.bak`은 `.md` 뒤에 파일 이름 문자가 이어지므로 그대로 `.notMarkdown`이다.
5. 마지막 경로 요소의 확장자가 `extensions`에 없으면(대소문자 무시) `.notMarkdown`. 4단계에서
   이름 없이 `.md`만 남은 경우(`.md에` → `.md`, 확장자가 없는 dotfile)도 여기서 걸러진다.
6. `~/`로 시작하면 `homeDirectory`로 바꾼다. `/`로 시작하면 절대 경로다. 그 밖은 상대 경로로
   보고 `baseDirectories`의 각 항목(빈 값 제외, 중복 제거, 주어진 순서)에 붙인 후보를 만든다.
7. 후보마다 `standardizingPath`를 적용하고, `isRegularFile`이 처음으로 `true`인 후보를
   `URL(fileURLWithPath:).resolvingSymlinksInPath()`로 돌려준다. 즉 파일이 있는 첫 기준
   디렉터리가 이긴다. 없으면 `.missing`.

실제 `isRegularFile`(`fileExistsAsRegularFile`)은 `stat()`으로 symlink를 따라간 뒤
`S_ISREG`(`(st_mode & S_IFMT) == S_IFREG`)인 것만 받는다. 디렉터리뿐 아니라 `x.md`라는 이름의
FIFO나 device도 거른다. 그런 것을 메인 스레드에서 동기로 읽으면 멈추기 때문이다.

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
- 이벤트를 소비할 때는 Cmd+클릭 동안 꺼 둔 mouse reporting도 그 자리에서 되돌린다
  (`endClickReportingOverride`). AppKit은 local monitor를 설치 순서대로 부르고, `nil`을 돌려받은
  이벤트는 뒤 monitor에 넘기지 않는다. link monitor가 restore monitor보다 먼저 설치되어 있어서,
  이렇게 하지 않으면 mouse를 잡는 TUI(Claude Code fullscreen, tmux, vim) 아래에서 다음 일반 클릭이
  child에 가지 않는다.
- `requestOpenLink` override는 그대로 둔다(md 클릭은 monitor가 이미 소비한다).
- `Pane`은 생성 시 두 closure를 연결한다.
  - `markdownBaseDirectories`: `[currentCwd, agent cwd(lastCwd), GitBranch.workTreeRoot(for: currentCwd)]`에서
    nil·빈 값을 빼고 중복을 제거한 목록(shell → agent → repo root). agent가 도는 동안 shell cwd는
    agent를 띄운 디렉터리라, Claude Code가 출력하는 상대 경로는 첫 후보에서 풀린다. shell을 먼저
    보는 이유는 `lastCwd`가 agent가 끝난 뒤에도 남기 때문이다. `exit` 후 `cd other-project`를
    하면 `README.md` 같은 흔한 이름이 이전 프로젝트 파일로 조용히 열린다. 이전 세션의 scrollback에
    남은 경로는 두 번째 후보(agent cwd)로 여전히 풀린다.
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

// `.none`은 Optional.none과 헷갈리므로 `.unchanged`라고 부른다.
enum FileChange: Equatable { case unchanged, modified, deleted, recreated }

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
  - `nil → nil`: `.unchanged`
  - 같음: `.unchanged`
  - `a → b`(inode·크기·mtime 중 하나라도 다름): `.modified`
  - `a → nil`: `.deleted`
  - `nil → a`: `.recreated`
- 파일이 삭제되거나 rename되면 파일 source를 정리한다. 다시 생기면 새 fd로 다시 단다.
- `stop()`은 두 source를 cancel하고, cancel handler에서 fd를 닫는다.

### 5.6 창 — `MarkdownPreviewWindowController`, `MarkdownPreviewManager`

`MarkdownPreviewManager` (`@MainActor`, `static let shared`):

- `open(_ url: URL)`: 키는 `url.standardizedFileURL.resolvingSymlinksInPath().path`다. 이미 열린
  창이 있으면 `makeKeyAndOrderFront`, 없으면 새 controller를 만들어 보여 준다.
- 새 창 위치: 열린 프리뷰가 있으면 그중 가장 최근에 연(아직 열린) 프리뷰에서 한 칸 cascade한다.
  `cascadeTopLeft(from:)`은 창을 준 점에 놓고 다음 cascade 점을 돌려주므로, 최근 프리뷰의 좌상단으로
  한 번, 돌려받은 점으로 한 번 더 부른다. 열린 프리뷰가 없으면 클릭이 온 termy 창
  (`NSApp.keyWindow`)이 있는 화면의 `visibleFrame` 가운데에 놓는다(`centeredFrame(size:in:)`, 화면보다
  크면 title bar가 화면 안에 남게 위·왼쪽을 맞춘다). key window가 없으면 `NSScreen.main`, 그것도
  없으면 `center()`.
- `closeAll()`: 열린 프리뷰 창을 모두 닫는다.
- controller의 `windowWillClose`에서 목록에서 뺀다.
- `static func isPreviewWindow(_ window: NSWindow?) -> Bool`: AppDelegate가 메뉴 판정에 쓴다.

`MarkdownPreviewWindowController` (`NSWindowController`, `NSWindowDelegate`, `WKNavigationDelegate`):

- 창: titled, closable, miniaturizable, resizable. `title` = 파일 이름, `subtitle` = 상위 디렉터리
  (`~`로 줄임), `representedURL` = 파일 URL(제목 proxy 아이콘). `tabbingMode = .disallowed`,
  `isReleasedWhenClosed = false`.
- 크기: 기본 content size 820×900. 마지막으로 닫은 창의 크기를 UserDefaults
  `MarkdownPreview.contentSize`에 저장해 다음 창에 쓴다. 위치는 manager가 정한다(위).
- WKWebView 구성: `defaultWebpagePreferences.allowsContentJavaScript = false`,
  `websiteDataStore = .nonPersistent()`, `allowsLinkPreview = false`(Force Touch 미리보기는
  `decidePolicyFor`를 거치지 않고 링크 대상을 불러온다).
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
  - `.other`는 대상이 문서 자신(`file` URL이고 path가 문서 path와 같음)일 때만 허용한다. 우리가
    부른 `loadHTMLString`이 이 경우다(테스트 host에서 request URL이 baseURL, 즉 문서 URL 그대로임을
    확인했다). WebKit은 context menu의 "Open Link"와 링크·파일 drag-and-drop도 `.other`로 보내므로,
    그 밖의 `.other`는 아래 `.linkActivated`와 똑같이 처리한다. 그래서 프리뷰 창 자체가 다른
    페이지나 파일로 바뀌지 않는다.
  - `.reload`(context menu의 Reload)는 취소한다. base URL을 다시 불러오면 원본 `.md`가 plain
    text로 보이기 때문이다. live reload는 `.reload`가 아니라 `loadHTMLString`을 다시 부른다.
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
- **`x.md`라는 이름의 디렉터리·FIFO·device**: `isRegularFile`이 false라 beep(§5.2).
- **경로 뒤에 붙은 한국어 조사·문장, `**`**: 첫 `.md`/`.markdown` 뒤에서 잘라 연다(§5.2).
- **agent가 연달아 쓰기**: 150ms debounce로 한 번만 다시 그린다.
- **UTF-8이 아닌 파일**: 손실 허용 디코딩으로 보여 준다.
- **메인 창을 모두 닫음**: 프리뷰도 함께 닫히고 앱이 종료된다(§5.7).
- **앱 재시작·업데이트**: 프리뷰 창은 복원하지 않는다. session.json은 바뀌지 않는다.
- **mouse reporting 중인 TUI**: Cmd+클릭은 이미 reporting을 잠시 끄고 처리한다(기존 동작).
  링크를 열어 mouseUp을 소비한 경우에도 그 자리에서 reporting을 되돌린다(§5.3).
- **agent가 끝난 뒤 다른 프로젝트로 `cd`**: shell cwd를 먼저 보므로 이전 프로젝트의 같은 이름
  파일이 열리지 않는다(§5.3).
- **`file:///…/x.md` URL**: 기본 앱 대신 프리뷰로 연다(의도한 동작 변경).

## 8. 테스트 전략

단위 테스트(XCTest, `apps/termy-tests/Sources/`):

- `MarkdownLinkResolverTests`: 절대·`~`·상대(기준 순서)·`./`·`../`·`file://`·percent 인코딩,
  `:12`·`:12:3`·`#L12` 접미사, 앞뒤 구두점, 대문자 `.MD`, `.markdown`, 뒤에 붙은 텍스트
  (`x.md에`, `x.md에 저장했습니다.`, `x.md를`, `x.md now.`, `x.md**`, `x.md:12에서`), md 아님
  (`.mdx`, `README.md.bak` 포함) → `.notMarkdown`, 파일 없음·디렉터리 → `.missing`. 파일
  시스템은 `isRegularFile` 주입으로 흉내 내고, symlink 해석과 FIFO 거르기는 임시 디렉터리로 한 번
  확인한다.
- `TermyTerminalViewTests`에 `linkClickAction` 추가: https → `.openURL`, 있는 md →
  `.previewMarkdown`, 없는 md → `.beep`, md 아닌 경로 → `.ignore`, `file://…md` → `.previewMarkdown`.
  한국어 문장을 실제로 feed해 `terminal.link`가 돌려준 텍스트로 `.previewMarkdown`이 나오는지,
  mouse reporting 중에 링크를 연 Cmd+클릭이 이벤트를 소비하고 reporting을 되돌리는지도 본다.
- `PaneMarkdownBaseDirectoriesTests`: shell → agent → repo root 순서, 남은 agent cwd가 shell cwd를
  이기지 않음, nil·빈 값·중복 제거.
- `MarkdownHTMLRendererTests`: 텍스트·inline code·코드 블록 escape, heading slug(한글·중복·구두점),
  heading 안의 inline code, 표 정렬, 체크리스트, raw HTML escape, 링크 주소 escape, 이미지 대체
  텍스트, CSP meta, banner.
- `MarkdownFileWatcherTests`: `classify`의 다섯 경우와 inode만 바뀐 경우. 임시 파일로 실제
  수정·삭제·rename 후 재생성 이벤트를 받는지 한 번씩 확인한다(expectation, 짧은 timeout).
- `MarkdownPreviewManagerTests`: 같은 URL 두 번 → 창 하나, symlink 경로 → 같은 창,
  `closeAll` 후 비어 있음, `isPreviewWindow` 판정, `centeredFrame`, 첫 창 가운데 배치, 닫힌 창이
  아니라 아직 열린 가장 최근 프리뷰에서 cascade.
- `MarkdownPreviewWindowControllerTests`: 링크 정책(`route`)의 각 분기(`.other`가 문서 자신이면
  허용·https·다른 md·그 밖, `.reload` 취소 포함), 저장된 창 크기 읽기, 창 제목·subtitle,
  `allowsLinkPreview` 꺼짐.
- 두 프리뷰 테스트는 `UserDefaults(suiteName:)` 대신 `InMemoryUserDefaults`를 쓴다. suite 도메인은
  `removePersistentDomain` 뒤에도 cfprefsd가 빈 plist를 `~/Library/Preferences`에 다시 써서 남는다.
- `AppDelegatePreviewMenuTests`: 메뉴 판정 함수(`previewMenuState`)가 프리뷰가 key일 때 pane
  액션을 끄고 ⌘W 제목을 바꾸는지. key window를 실제로 바꾸는 부분과 `WindowManager.removeWindow`
  연결은 §10에서 확인한다.

실제 동작 검증은 §10.

## 9. 구현 전 확인 항목

1. swift-markdown 0.9.0이 termy 빌드(Xcode 26.6, Swift 6 언어 모드,
   `-skipPackagePluginValidation`)에서 resolve·컴파일되는가.
2. ~~`allowsContentJavaScript = false`인 상태에서 `.defaultClient` content world의
   `callAsyncJavaScript`가 동작하는가(스크롤 유지).~~ **확인함(2026-10-12)**: 독립 실행 probe에서
   페이지 `<script>`는 실행되지 않았고, `.defaultClient`의 `scrollTo(0, 1234)` 후 `scrollY`가
   1234로 읽혔다.
3. ~~WKWebView의 `prefers-color-scheme`가 `NSApp.appearance`를 따르는가.~~ **확인함(2026-10-12)**:
   `NSApp.appearance`가 `.darkAqua`이면 `matchMedia('(prefers-color-scheme: dark)')`가 true,
   `.aqua`이면 false였다. 앱 실행 중 테마를 바꿨을 때 따라가는지는 §10에서 확인한다.

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
- [ ] 한국어 요약 줄(`…/x.md에 저장했습니다.`)에서 경로를 Cmd+클릭 → 열린다.
- [ ] Claude Code fullscreen에서 md 경로를 Cmd+클릭한 직후 일반 클릭이 Claude Code에 제대로 전달된다.
- [ ] 프리뷰 안 링크를 우클릭 → "Open Link" → https는 브라우저, md는 새 프리뷰, 그 밖은 아무 일 없음. 프리뷰 창 자체는 다른 페이지로 바뀌지 않는다.
- [ ] 파일을 프리뷰 창에 drag → 프리뷰 창이 바뀌지 않는다(md면 새 프리뷰).
- [ ] 모니터가 둘 이상일 때 프리뷰가 클릭한 termy 창이 있는 화면에 뜬다.

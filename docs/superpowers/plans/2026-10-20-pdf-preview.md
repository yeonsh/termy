# PDF 프리뷰 창 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** termy pane에서 `.pdf` 경로를 Cmd+클릭하면 md 프리뷰처럼 파일마다 하나씩 뜨는 termy 창에 PDF를 보여 주고, agent가 PDF를 다시 만들면 보던 페이지·위치·배율을 유지한 채 갱신한다.

**Architecture:** 먼저 md·pdf가 함께 쓸 resolver·manager·watcher의 이름을 종류 중립으로 바꾼다(동작 변화 없음). 그 위에 PDFKit `PDFView`를 담은 `PDFPreviewWindowController`를 새로 만든다. 이 컨트롤러는 파일을 `Data`로 통째로 읽고, `%%EOF` 표식이 있는 완성된 판만 바꿔 끼우며, 표식이 없으면 1초 안정 대기 뒤 한 번 더 판정한다. `PreviewManager`는 확장자로 종류(`PreviewKind`)를 가려 두 컨트롤러 중 하나를 띄운다. 마지막으로 `PreviewLinkResolver`가 `.pdf`를 받으면 Cmd+클릭, md 문서 안 링크, md 창 드롭이 모두 PDF 프리뷰로 이어진다.

**Tech Stack:** Swift 6, AppKit, PDFKit(시스템 framework, 패키지 추가 없음), SwiftTerm 1.20.0(고정), XcodeGen(`project.yml`), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-20-pdf-preview-design.md`

## Global Constraints

- Swift 6 언어 모드, macOS 14 deployment target. 새 코드는 strict concurrency에서 경고 없이 컴파일돼야 한다.
- 새 패키지를 더하지 않는다. PDFKit은 `import PDFKit`만으로 자동 링크된다. `project.yml`은 고치지 않는다.
- **새 `.swift` 파일을 만들거나 파일 이름을 바꾸면 반드시 `xcodegen generate`를 실행**한다. `termy.xcodeproj/`와 `Package.resolved`는 `.gitignore` 대상이라 커밋하지 않는다.
- 테스트 명령(모든 태스크 공통):
  `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25`
  → `** TEST SUCCEEDED **`. `-derivedDataPath`와 `-skipPackagePluginValidation`을 빼면 이 환경에서 EPERM이나 plugin 검증 오류가 난다. 여러 클래스는 `-only-testing`을 반복한다. 아래 태스크의 `xcodebuild test …`는 이 명령에서 `-only-testing` 앞부분을 줄여 쓴 것이다.
- **Task 1–5에서는 termy.app을 실행하지 않는다.** `scripts/relaunch.sh`, `open termy.app`, Debug 빌드 실행 모두 금지다. 이 세션은 보통 termy 안에서 돌고(`TERMY_PANE_ID` 설정됨), 두 번째 인스턴스는 hook socket(`/tmp/termy-$UID.sock`)과 `~/Library/Application Support/termy/session.json`을 가로챈다. XCTest host로 뜨는 것은 괜찮다.
- PDF 파일은 `Data(contentsOf: fileURL)`로 옵션 없이 읽고 `PDFDocument(data:)`로 연다. `.alwaysMapped`/`.mappedIfSafe`와 `PDFDocument(url:)`는 쓰지 않는다. agent가 파일을 제자리에서 잘라 쓰면 매핑된 페이지가 사라져 SIGBUS로 죽는다.
- 앱 UI 문구는 영어이며 아래 문자열을 그대로 쓴다.
  - 첫 불러오기 실패: `"Couldn't read this PDF."`
  - 갱신 실패: `"Couldn't read the new version. Showing the previous one."`
  - 읽기 오류: `"Couldn't read this file: <error.localizedDescription>"`
  - 삭제: `"This file was deleted. The preview will reload if it comes back."` (`MarkdownPreviewWindowController.deletedBanner`를 그대로 쓴다)
  - 메뉴: `"Show in Finder"`, `"Close Preview"`
- PDF 창 크기 defaults key는 `"PDFPreview.contentSize"`, 기본 크기 820×900, 저장값이 320×240보다 작으면 기본값.
- 완성 판정: 끝 1024바이트 안에 `%%EOF`. 안정 대기 시간 기본값 1.0초(테스트에서 주입).
- 테스트가 `UserDefaults.standard`에 쓰지 않게 한다. `InMemoryUserDefaults()`(`apps/termy-tests/Sources/InMemoryUserDefaults.swift`)를 주입한다.
- 창을 여는 테스트는 기존 테스트처럼 `sentinel` 창을 하나 띄워 둔다. 마지막 창이 닫히면 앱(테스트 host)이 종료되기 때문이다.
- 커밋 메시지는 한국어, `Co-Authored-By` 라인을 넣지 않는다. 접두사는 기존 관례(`refactor(preview):`, `feat(preview):`, `docs(changelog):`)를 따른다.
- 작업은 `main`이 아닌 브랜치(`feat/pdf-preview`)에서 한다.
- 주석 밀도와 스타일은 주변 코드를 따른다. 파일 머리 주석에 "왜"를 쓰고, 타입·메서드에는 `///` 한두 줄을 붙인다.

## Review Focus

spec이 암시하지만 쉽게 놓치는 입력 가운데, 실제로 부딪히기 쉬운 순서로 적는다. 각 줄의 테스트는 해당 태스크에 들어 있다.

1. **agent가 PDF를 제자리에서 잘라 다시 쓰는 중에 갱신**: 앱이 죽지 않고 이전 판이 보이다가 다 쓰이면 새 판으로 바뀐다. → Task 2 `test_reload_inPlaceTruncateThenRewrite_keepsPreviousThenSwaps`
2. **한글 문장에 붙은 경로**(`out/report.pdf에 저장했습니다.`): 클릭하면 PDF 프리뷰가 열린다. → Task 5 `test_cmdClickOnPdfPathInKoreanSentence_opensPreview`
3. **`.pdf`로 끝나는 웹 URL**(`https://arxiv.org/pdf/x.pdf`): beep이 아니라 브라우저로 간다. → Task 5 `test_linkClickAction_webURLEndingInPdfOpensBrowser`
4. **뒤쪽 페이지를 보는 중 페이지 수가 줄어든 판으로 갱신**: 마지막 페이지로 옮겨 가고 죽지 않는다. → Task 2 `test_reload_clampsToLastPageWhenShorter`
5. **PDF 안 `file://` 링크가 앱·스크립트를 가리킴**: 아무것도 실행하지 않는다. → Task 3 `test_linkRoute_ignoresAppsScriptsAndMissingFiles`

## 파일 구조

| 파일 | 역할 | 태스크 |
|---|---|---|
| `apps/termy/Sources/PreviewLinkResolver.swift` (이름 변경, 수정) | 링크 텍스트 → md·pdf 파일. `PreviewKind` | 1, 4, 5 |
| `apps/termy/Sources/PreviewManager.swift` (이름 변경, 수정) | 파일당 창 하나, 종류별 컨트롤러 생성 | 1, 4 |
| `apps/termy/Sources/PreviewFileWatcher.swift` (이름 변경) | 파일·디렉터리 감시 | 1 |
| `apps/termy/Sources/PreviewWindowSupport.swift` (신규) | 두 창 컨트롤러 공용: 크기 저장값, Finder 판정, `PreviewWindowController` 프로토콜 | 2, 3, 4 |
| `apps/termy/Sources/PDFPreviewWindowController.swift` (신규) | PDF 창 하나: 불러오기·갱신·위치 유지·배너·링크·Show in Finder | 2, 3 |
| `apps/termy/Sources/PDFPreviewView.swift` (신규) | `PDFView` 하위 클래스, context menu hook | 3 |
| `apps/termy/Sources/MarkdownPreviewWindowController.swift` (수정) | 공용 헬퍼 사용, 프로토콜 채택 | 1–4 |
| `apps/termy/Sources/MarkdownPreviewWebView.swift` (수정) | 드롭 이름 일반화 | 1, 5 |
| `apps/termy/Sources/TermyTerminalView.swift` (수정) | `LinkClickAction.preview`, 이름 일반화 | 1, 5 |
| `apps/termy/Sources/Pane.swift`, `AppDelegate.swift`, `WindowManager.swift` (수정) | 이름 일반화, 주석 | 1, 3 |
| `CHANGELOG.md` (수정) | Unreleased 항목 | 6 |
| 테스트: `PreviewLinkResolverTests`, `PreviewManagerTests`, `PreviewFileWatcherTests`, `PanePreviewBaseDirectoriesTests`(이름 변경), `PDFPreviewWindowControllerTests`(신규), `MarkdownPreviewWindowControllerTests`, `MarkdownPreviewWebViewTests`, `TermyTerminalViewTests`, `AppDelegatePreviewMenuTests`(수정) | | 1–5 |

---

### Task 1: 공용 타입 이름 일반화 (동작 변화 없음)

**Files:**
- Rename(`git mv`): `apps/termy/Sources/MarkdownLinkResolver.swift` → `PreviewLinkResolver.swift`, `MarkdownPreviewManager.swift` → `PreviewManager.swift`, `MarkdownFileWatcher.swift` → `PreviewFileWatcher.swift`
- Rename(`git mv`): `apps/termy-tests/Sources/MarkdownLinkResolverTests.swift` → `PreviewLinkResolverTests.swift`, `MarkdownPreviewManagerTests.swift` → `PreviewManagerTests.swift`, `MarkdownFileWatcherTests.swift` → `PreviewFileWatcherTests.swift`, `PaneMarkdownBaseDirectoriesTests.swift` → `PanePreviewBaseDirectoriesTests.swift`
- Modify: 위 파일들과 `TermyTerminalView.swift`, `Pane.swift`, `AppDelegate.swift`, `WindowManager.swift`, `MarkdownPreviewWindowController.swift`, `MarkdownPreviewWebView.swift`, `TermyTerminalViewTests.swift`, `MarkdownPreviewWebViewTests.swift`

**Interfaces:**
- Produces (이름만 바뀌고 시그니처는 그대로):

| 지금 | 바꾼 뒤 |
|---|---|
| `MarkdownLinkResolver`, `MarkdownLinkResolution` | `PreviewLinkResolver`, `PreviewLinkResolution` |
| `MarkdownLinkResolution.notMarkdown` | `.notPreviewable` |
| `MarkdownLinkResolver.markdownPath(from:)` | `PreviewLinkResolver.previewPath(from:)` |
| `MarkdownPreviewManager` | `PreviewManager` |
| `MarkdownFileWatcher` | `PreviewFileWatcher` (`FileFingerprint`, `FileChange`는 그대로) |
| `LinkClickAction.previewMarkdown(URL)` | `LinkClickAction.preview(URL)` |
| `TermyTerminalView.markdownBaseDirectories`, `.onOpenMarkdownFile` | `.previewBaseDirectories`, `.onOpenPreviewFile` |
| `Pane.markdownBaseDirectories()`, `Pane.markdownBaseDirectories(agentCwd:shellCwd:workTreeRoot:)` | `Pane.previewBaseDirectories()`, `Pane.previewBaseDirectories(agentCwd:shellCwd:workTreeRoot:)` |
| `MarkdownPreviewWebView.onDropMarkdownFiles`, `markdownFiles(in:)`, `markdownFiles(in:isRegularFile:)` | `.onDropPreviewFiles`, `previewFiles(in:)`, `previewFiles(in:isRegularFile:)` |

- [ ] **Step 1: 브랜치를 만든다**

Run: `cd /Users/ysh/proj/termy && git switch -c feat/pdf-preview`

- [ ] **Step 2: 파일 7개를 `git mv`하고 위 표대로 심볼을 바꾼다**

테스트 클래스 이름도 파일 이름에 맞춘다(`PreviewLinkResolverTests`, `PreviewManagerTests`, `PreviewFileWatcherTests`, `PanePreviewBaseDirectoriesTests`). 파일 머리 주석의 파일 이름 줄도 고친다. `MarkdownHTMLRendererTests.swift` 27·32행의 `MarkdownLinkResolver`는 heading id 테스트용 문서 내용이므로 **바꾸지 않는다**. 주석 속 "markdown"이라는 단어의 의미 변경은 Task 5에서 한다.

- [ ] **Step 3: 옛 이름이 남지 않았는지 확인**

Run: `git grep -nE "MarkdownLinkResolver|MarkdownLinkResolution|notMarkdown|markdownPath\(|MarkdownPreviewManager|MarkdownFileWatcher|previewMarkdown|markdownBaseDirectories|onOpenMarkdownFile|onDropMarkdownFiles|markdownFiles\(" -- '*.swift'`
Expected: `MarkdownHTMLRendererTests.swift`의 두 줄만 나온다.

- [ ] **Step 4: 프로젝트를 다시 만들고 관련 테스트를 모두 돌린다**

Run: `xcodegen generate && xcodebuild test … -only-testing:termy-tests/PreviewLinkResolverTests -only-testing:termy-tests/PreviewManagerTests -only-testing:termy-tests/PreviewFileWatcherTests -only-testing:termy-tests/PanePreviewBaseDirectoriesTests -only-testing:termy-tests/TermyTerminalViewTests -only-testing:termy-tests/MarkdownPreviewWindowControllerTests -only-testing:termy-tests/MarkdownPreviewWebViewTests -only-testing:termy-tests/AppDelegatePreviewMenuTests -only-testing:termy-tests/MarkdownHTMLRendererTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`, 테스트 수는 이름 바꾸기 전과 같다.

- [ ] **Step 5: Commit**

```bash
git add -A apps/termy/Sources apps/termy-tests/Sources
git commit -m "refactor(preview): md와 pdf가 함께 쓸 resolver·manager·watcher 이름을 종류 중립으로 바꿈"
```

---

### Task 2: PDF 창 — 불러오기와 갱신

**Files:**
- Create: `apps/termy/Sources/PreviewWindowSupport.swift`
- Create: `apps/termy/Sources/PDFPreviewWindowController.swift`
- Modify: `apps/termy/Sources/MarkdownPreviewWindowController.swift` (`savedContentSize`가 공용 헬퍼를 부르게)
- Test: `apps/termy-tests/Sources/PDFPreviewWindowControllerTests.swift` (신규)

**Interfaces:**
- Consumes: `PreviewFileWatcher(fileURL:onChange:)`, `FileChange`, `MarkdownPreviewWindowController.deletedBanner` (Task 1)
- Produces:
  - `enum PreviewWindowSupport` — `static let defaultContentSize = NSSize(width: 820, height: 900)`, `static func savedContentSize(defaults: UserDefaults, key: String) -> NSSize`
  - `@MainActor final class PDFPreviewWindowController: NSWindowController, NSWindowDelegate`
    - `init(fileURL: URL, defaults: UserDefaults = .standard, settleInterval: TimeInterval = PDFPreviewWindowController.defaultSettleInterval)`
    - `static let defaultSettleInterval: TimeInterval = 1.0`
    - `static let contentSizeDefaultsKey = "PDFPreview.contentSize"`
    - `static let unreadableBanner = "Couldn't read this PDF."`
    - `static let staleBanner = "Couldn't read the new version. Showing the previous one."`
    - `let fileURL: URL`, `var onClose: ((PDFPreviewWindowController) -> Void)?`
    - `let pdfView: PDFView` (Task 3에서 `PDFPreviewView`로 바뀐다)
    - `private(set) var bannerText: String?`
    - `var currentPageIndex: Int?` — 보이는 페이지 번호, 문서가 없으면 nil
    - `nonisolated static func hasEndMarker(_ data: Data) -> Bool`
    - `nonisolated static func document(from data: Data, requireEndMarker: Bool) -> PDFDocument?`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

테스트용 PDF는 CoreGraphics로 만든다(이 코드는 그대로 쓴다).

```swift
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
```

`waitUntil(timeout:_:)`과 `sentinel`은 `MarkdownPreviewWindowControllerTests`의 것과 같은 모양으로 둔다. 파일은 임시 디렉터리에 `report.pdf`로 쓴다. "atomic 쓰기"는 `data.write(to:options: .atomic)`, "제자리 쓰기"는 `FileHandle(forWritingTo:)` → `truncate(atOffset: 0)` → `write(contentsOf:)`.

순수 함수:
- `test_hasEndMarker`: `makePDFData(pages: 2)` → true. 끝 20바이트를 뗀 것 → false. 뒤에 `\n` 2000바이트를 붙인 것 → false(표식이 끝 1024바이트 밖).
- `test_documentFromData`: 완성 데이터 → `requireEndMarker: true`로 `pageCount == 2`. 앞쪽 절반만 → `requireEndMarker: true`로 nil. `"not a pdf"` → 두 모드 모두 nil. 완성 데이터 + `\n` 2000바이트 → `true`면 nil, `false`면 `pageCount == 2`.

창:
- `test_windowShowsFileNameAndDirectory`: `title == "report.pdf"`, `subtitle` == `~`로 줄인 상위 디렉터리, `representedURL == url`, `tabbingMode == .disallowed`.
- `test_pdfViewSettings`: `autoScales == true`, `displayMode == .singlePageContinuous`, `displaysPageBreaks == true`.
- `test_savedContentSize`: `PreviewWindowSupport.savedContentSize(defaults:key:)`가 값 없음 → 820×900, `"{200, 100}"` → 820×900, `"{1000, 700}"` → 1000×700.
- `test_closingStoresContentSizeUnderPDFKey`: 창을 닫으면 주입한 defaults의 `"PDFPreview.contentSize"`에 값이 있고 `"MarkdownPreview.contentSize"`에는 없다.

불러오기·갱신(창을 `orderFront`, 6페이지로 시작):
- `test_firstLoad_showsDocument`: `pdfView.document?.pageCount == 6`, `bannerText == nil`.
- `test_firstLoad_unreadableFileShowsBannerAfterSettling`: 내용 `"not a pdf"`, `settleInterval: 0.3`. 열자마자 `bannerText == nil`이고 `pdfView.document == nil`; 기다리면 `bannerText == "Couldn't read this PDF."`.
- `test_firstLoad_readErrorShowsReadBanner`: 파일 권한 `0o000`. `bannerText`가 `"Couldn't read this file: "`로 시작한다. tearDown 전에 권한을 되돌린다.
- `test_reload_swapsCompleteVersionAndKeepsPage`: `pdfView.go(to: page 3)` 뒤 `currentPageIndex == 3`을 기다린다. 7페이지 atomic 쓰기 → `pageCount == 7`을 기다린 뒤 `currentPageIndex == 3`, `bannerText == nil`.
- `test_reload_clampsToLastPageWhenShorter`: 페이지 3에서 2페이지 판으로 atomic 쓰기 → `pageCount == 2` 뒤 `currentPageIndex == 1`.
- `test_reload_keepsZoomWhenNotAutoScaling`: `autoScales = false`, `scaleFactor = 1.7` → 7페이지 판 → `autoScales == false`, `scaleFactor`가 1.7(±0.01).
- `test_reload_inPlaceTruncateThenRewrite_keepsPreviousThenSwaps` (Review Focus 1): `settleInterval: 5`. 7페이지 데이터의 앞 절반만 제자리 쓰기 → 0.6초 뒤에도 `pageCount == 6`, `bannerText == nil`. 이어서 7페이지 전체를 제자리 쓰기 → `pageCount == 7`, `bannerText == nil`.
- `test_reload_unreadableAfterSettling_showsStaleBannerThenClears`: `settleInterval: 0.3`. `"broken"`을 atomic 쓰기 → `bannerText == "Couldn't read the new version. Showing the previous one."`를 기다리고 `pageCount == 6`. 7페이지 판 → `bannerText == nil`, `pageCount == 7`.
- `test_reload_endMarkerlessButParseableIsShownAfterSettling`: `settleInterval: 0.3`. 7페이지 데이터 + `\n` 2000바이트 → `pageCount == 7`, `bannerText == nil`.
- `test_reload_newEventRestartsSettleWait`: `settleInterval: 1.0`. `"broken-1"` 쓰기, 0.6초 쉬고 `"broken-two"`(크기가 다름) 쓰기, 0.6초 쉰 뒤(첫 쓰기 기준 1.2초) `bannerText == nil`. 그 뒤 기다리면 stale 배너.
- `test_deleted_showsDeletedBannerThenReloadsWhenRecreated`: 파일 삭제 → `bannerText == MarkdownPreviewWindowController.deletedBanner`, `pageCount == 6` 유지. 7페이지로 다시 만들기 → `pageCount == 7`, `bannerText == nil`.

- [ ] **Step 2: 실패를 확인한다**

Run: `xcodegen generate && xcodebuild test … -only-testing:termy-tests/PDFPreviewWindowControllerTests 2>&1 | tail -25`
Expected: `PDFPreviewWindowController`, `PreviewWindowSupport`가 없어 컴파일 실패.

- [ ] **Step 3: `PreviewWindowSupport.swift`를 만들고 md `savedContentSize(defaults:)`가 이를 부르게 한다**

검증 규칙(가로 320 이상, 세로 240 이상, 아니면 기본값)은 md의 것을 옮긴다. md의 `defaultContentSize`는 `PreviewWindowSupport.defaultContentSize`를 가리키게 한다.

- [ ] **Step 4: `PDFPreviewWindowController`를 구현한다**

창 껍데기는 md 창과 같다(styleMask, title·subtitle·representedURL, `tabbingMode = .disallowed`, `isReleasedWhenClosed = false`, `windowWillClose`에서 watcher 정지·크기 저장·`onClose`). 내용 뷰는 배너 한 줄(`NSTextField` label, 배너가 nil이면 숨김) 아래에 `pdfView`를 두는 세로 `NSStackView`다.

불러오기 흐름(`reload(after change: FileChange?)`, nil은 첫 불러오기):

```
.deleted          → 대기 중인 안정 판정 취소, bannerText = deletedBanner, 문서 유지
그 밖(nil·.modified·.recreated):
  data = try Data(contentsOf: fileURL)          // 실패 → bannerText = "Couldn't read this file: …", 문서 유지
  doc = document(from: data, requireEndMarker: true)
  doc 있음 → 대기 취소, swap(doc), bannerText = nil
  doc 없음 → 대기를 (다시) 걸고 settleInterval 뒤 settle() 호출. 배너는 건드리지 않는다
settle():
  data 다시 읽기 (실패 → 읽기 오류 배너)
  doc = document(from: data, requireEndMarker: false)
  doc 있음 → swap(doc), bannerText = nil
  doc 없음 → bannerText = (문서가 아직 없으면 unreadableBanner, 있으면 staleBanner)
```

watcher는 fingerprint가 바뀔 때만 알리므로, 알림마다 대기를 다시 거는 것이 spec의 "마지막 알림 뒤 1초 동안 fingerprint가 변하지 않으면"과 같다. 대기는 `DispatchWorkItem` 또는 `Task`로 하되 `windowWillClose`에서 취소한다.

`document(from:requireEndMarker:)`: `requireEndMarker`면 `hasEndMarker`부터 확인하고, `PDFDocument(data:)`가 nil이 아니고 `pageCount > 0`일 때만 돌려준다. `hasEndMarker`는 `data.suffix(1024)`에서 `"%%EOF"` 바이트열을 찾는다.

`swap(_ newDocument: PDFDocument)`: 문서가 없으면 그냥 넣는다. 있으면 넣기 전에 현재 페이지 번호, `currentDestination?.point`, `autoScales`, `scaleFactor`를 저장하고, 넣은 뒤 `autoScales`가 꺼져 있었으면 `scaleFactor`를 되돌리고, 페이지 번호를 `newDocument.pageCount - 1`로 자른 페이지의 같은 지점으로 `go(to: PDFDestination(page:at:))`. 좌표가 몇 줄이라도 밀리는지는 Task 6 실제 앱 확인에서 본다.

- [ ] **Step 5: 테스트 통과를 확인한다**

Run: `xcodegen generate && xcodebuild test … -only-testing:termy-tests/PDFPreviewWindowControllerTests -only-testing:termy-tests/MarkdownPreviewWindowControllerTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add apps/termy/Sources/PreviewWindowSupport.swift apps/termy/Sources/PDFPreviewWindowController.swift apps/termy/Sources/MarkdownPreviewWindowController.swift apps/termy-tests/Sources/PDFPreviewWindowControllerTests.swift
git commit -m "feat(preview): 완성된 판만 바꿔 끼우고 보던 위치를 지키는 PDF 프리뷰 창을 추가"
```

---

### Task 3: PDF 창 — 링크, Show in Finder, context menu

**Files:**
- Create: `apps/termy/Sources/PDFPreviewView.swift`
- Modify: `apps/termy/Sources/PDFPreviewWindowController.swift`, `apps/termy/Sources/PreviewWindowSupport.swift`, `apps/termy/Sources/MarkdownPreviewWindowController.swift`, `apps/termy/Sources/AppDelegate.swift` (Show in Finder 메뉴 주석)
- Test: `PDFPreviewWindowControllerTests.swift`, `MarkdownPreviewWindowControllerTests.swift`, `AppDelegatePreviewMenuTests.swift`

**Interfaces:**
- Consumes: `PreviewLinkResolver.resolve(...)`, `PreviewLinkResolver.fileExistsAsRegularFile` (Task 1), `PDFPreviewWindowController` (Task 2)
- Produces:
  - `PreviewWindowSupport.FinderReveal` (`case selectFile(URL)`, `case openFolder(URL)`), `PreviewWindowSupport.finderReveal(for: URL, exists: (String) -> Bool) -> FinderReveal?` — md 컨트롤러의 것을 옮긴다
  - `final class PDFPreviewView: PDFView` — `var onWillOpenMenu: ((NSMenu) -> Void)?`, `override func menu(for event: NSEvent) -> NSMenu?`
  - `PDFPreviewWindowController`: `PDFViewDelegate`, `NSMenuItemValidation` 채택, `let pdfView: PDFPreviewView`, `@objc func showInFinder(_ sender: Any?)`
  - `enum PDFPreviewWindowController.LinkRoute: Equatable { case openExternally(URL), preview(URL), ignore }`
  - `nonisolated static func linkRoute(for url: URL, isRegularFile: (String) -> Bool) -> LinkRoute`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`PDFPreviewWindowControllerTests`:
- `test_linkRoute_sendsWebLinksToBrowser`: `https://example.com/a`, `http://x.org`, `mailto:a@b.c` → `.openExternally(같은 URL)`.
- `test_linkRoute_opensMarkdownFileInPreview`: `file:///proj/docs/a.md`(존재) → `.preview(URL(fileURLWithPath: "/proj/docs/a.md").resolvingSymlinksInPath())`. PDF 링크 줄은 resolver가 `.pdf`를 받은 뒤인 Task 5에서 더한다.
- `test_linkRoute_ignoresAppsScriptsAndMissingFiles` (Review Focus 5): `file:///Applications/Calculator.app`, `file:///proj/run.command`(존재), `file:///proj/none.pdf`(없음), `other.pdf`(scheme 없음), `ftp://x/y`, `javascript:alert(1)` → `.ignore`.
- `test_pdfViewDelegateIsController`: `controller.pdfView.delegate === controller`.
- `test_contextMenuEndsWithShowInFinder`: `controller.pdfView.menu(for: rightMouseDown 이벤트)`의 마지막 항목이 `"Show in Finder"`, action `#selector(PDFPreviewWindowController.showInFinder(_:))`, target이 controller. PDFView 기본 항목이 있으면 그 뒤에 구분선이 있다.
- `test_showInFinderDisabledOnceFolderIsGone`: md의 같은 이름 테스트와 같은 모양.

`MarkdownPreviewWindowControllerTests`: `test_finderReveal_selectsFileAndFallsBackToItsFolder`가 `PreviewWindowSupport.finderReveal`과 `PreviewWindowSupport.FinderReveal`을 쓰도록 바꾼다(단언은 그대로).

`AppDelegatePreviewMenuTests`:
- `test_fileMenuShowInFinderReachesPDFPreview`: File 메뉴의 Show in Finder 항목 action에 `PDFPreviewWindowController.instancesRespond(to:)`가 true.

- [ ] **Step 2: 실패를 확인한다**

Run: `xcodegen generate && xcodebuild test … -only-testing:termy-tests/PDFPreviewWindowControllerTests -only-testing:termy-tests/MarkdownPreviewWindowControllerTests -only-testing:termy-tests/AppDelegatePreviewMenuTests 2>&1 | tail -25`
Expected: `linkRoute`, `PDFPreviewView`, `PreviewWindowSupport.finderReveal`이 없어 컴파일 실패.

- [ ] **Step 3: `FinderReveal`/`finderReveal`을 `PreviewWindowSupport`로 옮기고 md 컨트롤러가 그것을 쓰게 한다**

- [ ] **Step 4: `PDFPreviewView`를 만들고 컨트롤러에 링크·Show in Finder를 붙인다**

- `PDFPreviewView.menu(for:)`: `super.menu(for:) ?? NSMenu()`에 `onWillOpenMenu`를 부르고 돌려준다. 컨트롤러는 md의 `addShowInFinder(to:)`와 같은 모양으로 구분선(메뉴가 비어 있지 않을 때) + `Show in Finder`(target self)를 더한다.
- `pdfViewWillClick(onLink:with:)`: `linkRoute`가 `.openExternally`면 `NSWorkspace.shared.open`, `.preview`면 `PreviewManager.shared.open`, `.ignore`면 아무것도 하지 않는다. super를 부르지 않는다(기본 동작이 URL을 그대로 연다).
- `linkRoute`: scheme이 `http`/`https`/`mailto`면 `.openExternally`. `file`이면 `PreviewLinkResolver.resolve(linkText: url.absoluteString, baseDirectories: [], homeDirectory: NSHomeDirectory(), isRegularFile:)`가 `.file(target)`일 때 `.preview(target)`, 아니면 `.ignore`. 그 밖은 `.ignore`.
- `showInFinder(_:)`·`validateMenuItem(_:)`: md와 같은 동작, `PreviewWindowSupport.finderReveal` 사용.
- `AppDelegate`의 Show in Finder 메뉴 주석을 "the key preview (markdown or PDF) answers it"로 고친다. selector는 그대로 둔다.

- [ ] **Step 5: 테스트 통과를 확인한다**

Run: Step 2와 같은 명령
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add apps/termy/Sources apps/termy-tests/Sources
git commit -m "feat(preview): PDF 창에서 웹 링크는 브라우저로, md·pdf 링크는 프리뷰로 열고 Show in Finder를 붙임"
```

---

### Task 4: PreviewManager가 PDF 창을 띄움

**Files:**
- Modify: `apps/termy/Sources/PreviewWindowSupport.swift`, `apps/termy/Sources/PreviewManager.swift`, `apps/termy/Sources/PreviewLinkResolver.swift`, `apps/termy/Sources/MarkdownPreviewWindowController.swift`, `apps/termy/Sources/PDFPreviewWindowController.swift`, `apps/termy/Sources/Pane.swift`
- Test: `PreviewManagerTests.swift`, `PreviewLinkResolverTests.swift`

**Interfaces:**
- Consumes: `MarkdownPreviewWindowController(fileURL:defaults:)`, `PDFPreviewWindowController(fileURL:defaults:settleInterval:)` (Task 2)
- Produces:
  - `@MainActor protocol PreviewWindowController: NSWindowController { var fileURL: URL { get }; var onClose: (() -> Void)? { get set } }` — 두 컨트롤러가 채택한다. 두 컨트롤러의 `onClose` 타입을 `(() -> Void)?`로 바꾼다.
  - `enum PreviewKind: Equatable { case markdown, pdf }`, `init?(fileURL: URL)` — `PreviewLinkResolver.swift`에 둔다. 확장자 소문자 기준 `md`/`markdown` → `.markdown`, `pdf` → `.pdf`, 그 밖 nil.
  - `PreviewManager.controllers: [String: any PreviewWindowController]`
  - `@discardableResult func open(_ url: URL) -> (any PreviewWindowController)?` — 종류를 모르면 nil, 아무 창도 만들지 않는다
  - `static func isPreviewWindow(_ window: NSWindow?) -> Bool` — 두 종류 모두 true

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`PreviewManagerTests`: 기존 테스트의 `manager.open(...)` 결과를 `XCTUnwrap`으로 감싼다(`first === second` 비교는 `ObjectIdentifier`나 `===`로). `makePDF(_ name:)` 헬퍼는 Task 2의 `makePDFData`와 같은 방식으로 1페이지 PDF를 쓴다. 새 테스트:
- `test_openingPdfShowsPdfPreview`: `manager.open(report.pdf)`가 `PDFPreviewWindowController`.
- `test_openingSamePdfTwiceReusesWindow`: 같은 객체, `controllers.count == 1`.
- `test_markdownAndPdfShareCascadeAndCloseAll`: `a.md`를 연 뒤 `b.pdf`를 열면 b의 `frame.minX > a.minX`, `frame.maxY < a.maxY`. `closeAll()` 뒤 `controllers.isEmpty`.
- `test_isPreviewWindow_pdf`: PDF 창에 true.
- `test_unknownKindOpensNothing`: `notes.txt` → nil, `controllers.isEmpty`.

`PreviewLinkResolverTests`:
- `test_previewKind`: `a.md` → `.markdown`, `b.MARKDOWN` → `.markdown`, `c.Pdf` → `.pdf`, `d.txt` → nil, `Makefile` → nil.

- [ ] **Step 2: 실패를 확인한다**

Run: `xcodegen generate && xcodebuild test … -only-testing:termy-tests/PreviewManagerTests -only-testing:termy-tests/PreviewLinkResolverTests 2>&1 | tail -25`
Expected: `PreviewKind`, `PreviewWindowController`가 없어 컴파일 실패.

- [ ] **Step 3: 프로토콜·`PreviewKind`를 더하고 manager가 종류별로 컨트롤러를 만들게 한다**

`open`은 key 계산 → 기존 창 재사용 → `PreviewKind(fileURL:)`로 분기 → `onClose`에서 사전과 `openOrder` 정리 → `place` → `showWindow` 순서를 지킨다. 배치(`place`, `centeredFrame`)는 그대로 두 종류에 쓴다. `Pane`의 `onOpenPreviewFile` 클로저는 `_ = PreviewManager.shared.open(url)` 그대로다.

- [ ] **Step 4: 테스트 통과를 확인한다**

Run: `xcodegen generate && xcodebuild test … -only-testing:termy-tests/PreviewManagerTests -only-testing:termy-tests/PreviewLinkResolverTests -only-testing:termy-tests/AppDelegatePreviewMenuTests -only-testing:termy-tests/MarkdownPreviewWindowControllerTests -only-testing:termy-tests/PDFPreviewWindowControllerTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources apps/termy-tests/Sources
git commit -m "feat(preview): 프리뷰 관리자가 확장자로 종류를 가려 md 창과 PDF 창을 함께 관리함"
```

---

### Task 5: Cmd+클릭·md 링크·드롭이 PDF를 받음

**Files:**
- Modify: `apps/termy/Sources/PreviewLinkResolver.swift`, `apps/termy/Sources/TermyTerminalView.swift`(머리·doc 주석), `apps/termy/Sources/MarkdownPreviewWebView.swift`(주석)
- Test: `PreviewLinkResolverTests.swift`, `TermyTerminalViewTests.swift`, `MarkdownPreviewWindowControllerTests.swift`, `MarkdownPreviewWebViewTests.swift`

**Interfaces:**
- Consumes: `PreviewManager.open` (Task 4)
- Produces: `PreviewLinkResolver.extensions == ["md", "markdown", "pdf"]`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`PreviewLinkResolverTests`(기준 `/proj`, 존재: `/proj/out/report.pdf`):
- `test_pdfPaths`: `out/report.pdf`, `./out/report.pdf:3`, `file:///proj/out/report.pdf`, `` `out/report.pdf` ``, `(out/report.pdf).`, `out/report.pdf에 저장했습니다.`, `out/report.pdf를` → 모두 `/proj/out/report.pdf`.
- `test_uppercasePdfExtension`: 존재 `/proj/out/REPORT.PDF`, `out/REPORT.PDF` → 그 파일.
- `test_webURLEndingInPdfIsNotPreviewable`: `https://arxiv.org/pdf/2401.00001.pdf` → `.notPreviewable`.
- `test_pdfLookalikesAreNotPreviewable`: `out/report.pdfx`, `out/report.pdf.bak` → `.notPreviewable`.
- `test_missingPdf`: `out/none.pdf` → `.missing`.

`TermyTerminalViewTests`(기존 `clickAction` 헬퍼):
- `test_linkClickAction_existingPdfOpensPreview`: `out/r.pdf`(존재) → `.preview(…)`.
- `test_linkClickAction_missingPdfBeeps`: `out/none.pdf` → `.beep`.
- `test_linkClickAction_webURLEndingInPdfOpensBrowser` (Review Focus 3): `https://arxiv.org/pdf/2401.00001.pdf` → `.openURL(같은 URL)`.
- `test_cmdClickOnPdfPathInKoreanSentence_opensPreview` (Review Focus 2): 기존 `test_cmdClickOnPathInKoreanSentence_opensPreview`와 같은 모양으로 `"보고서를 out/report.pdf에 저장했습니다."`를 feed하고 경로 안 칸의 링크 텍스트로 `linkClickAction` → `.preview(/proj/out/report.pdf)`.

`MarkdownPreviewWindowControllerTests`:
- `test_route_opensPdfFileInPreview`: `.linkActivated`, `file:///proj/out/report.pdf`(존재) → `.preview(…)`.

`PDFPreviewWindowControllerTests`:
- `test_linkRoute_opensPdfFileInPreview`: `file:///proj/out/other.pdf`(존재) → `.preview(URL(fileURLWithPath: "/proj/out/other.pdf").resolvingSymlinksInPath())`.

`MarkdownPreviewWebViewTests`:
- `test_previewFiles_includesPdf`: `previewFiles(in: [a.md, b.pdf, c.txt], isRegularFile: 모두 true)` → `[a.md, b.pdf]`.

- [ ] **Step 2: 실패를 확인한다**

Run: `xcodebuild test … -only-testing:termy-tests/PreviewLinkResolverTests -only-testing:termy-tests/TermyTerminalViewTests -only-testing:termy-tests/MarkdownPreviewWindowControllerTests -only-testing:termy-tests/MarkdownPreviewWebViewTests 2>&1 | tail -25`
Expected: PDF 관련 테스트만 실패(`.notPreviewable`/`.ignore`가 나옴).

- [ ] **Step 3: resolver를 넓힌다**

`extensions`에 `"pdf"`를 더하고, 붙은 글자를 자르는 정규식을 `^.*?\.(md|markdown|pdf)(?![A-Za-z0-9._/-])`로 바꾼다. 파일 머리 주석과 `previewPath(from:)`·`resolve` doc 주석, `TermyTerminalView` 머리 주석과 `linkClickAction` doc 주석, `MarkdownPreviewWebView` 드롭 주석에서 "markdown"을 "markdown or PDF"로 고친다.

- [ ] **Step 4: 테스트 통과를 확인한다**

Run: Step 2와 같은 명령
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources apps/termy-tests/Sources
git commit -m "feat(preview): pane에서 .pdf 경로를 Cmd+클릭하면 PDF 프리뷰 창으로 엶"
```

---

### Task 6: CHANGELOG, 전체 확인, 실제 앱 확인

**Files:**
- Modify: `CHANGELOG.md` (`## Unreleased` 아래)

- [ ] **Step 1: CHANGELOG 항목을 쓴다**

기존 항목처럼 영어, 사용자 관점으로 쓴다. 예:

```markdown
- Cmd+click a PDF path in a pane to open it in a termy preview window,
  just like Markdown files. When an agent regenerates the PDF, the preview
  updates and stays on the page and zoom you were reading; while the file
  is still being written, the previous version stays on screen.
```

- [ ] **Step 2: 프리뷰 관련 테스트를 한 번에 돌린다**

Run: `xcodegen generate && xcodebuild test … -only-testing:termy-tests/PreviewLinkResolverTests -only-testing:termy-tests/PreviewManagerTests -only-testing:termy-tests/PreviewFileWatcherTests -only-testing:termy-tests/PanePreviewBaseDirectoriesTests -only-testing:termy-tests/PDFPreviewWindowControllerTests -only-testing:termy-tests/MarkdownPreviewWindowControllerTests -only-testing:termy-tests/MarkdownPreviewWebViewTests -only-testing:termy-tests/MarkdownHTMLRendererTests -only-testing:termy-tests/TermyTerminalViewTests -only-testing:termy-tests/AppDelegatePreviewMenuTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: 전체 테스트를 돌린다**

Run: `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): PDF 프리뷰 항목 추가"
```

- [ ] **Step 5: 실제 앱 확인 — 사용자에게 넘긴다**

agent는 termy를 띄우지 않는다(Global Constraints). 아래 목록을 사용자에게 전달하고 결과를 받는다. 위치 복원이 밀리면(2번) `swap`을 내부 scroll view의 clip 원점 저장·복원 방식으로 바꾸고 다시 확인한다.

1. agent 출력의 `out/report.pdf`, `out/report.pdf에 저장했습니다.` 경로를 Cmd+클릭 → PDF 창이 뜬다.
2. 중간 페이지로 스크롤하고 pinch로 확대한 상태에서 agent가 PDF를 다시 만든다 → 같은 페이지·위치·배율로 갱신된다.
3. 큰 PDF를 천천히 쓴다(예: `dd if=big.pdf of=out/report.pdf bs=64k` 사이에 `sleep`) → 앱이 죽지 않고, 쓰는 동안 이전 판이 보이다가 끝나면 새 판으로 바뀐다. 배너는 뜨지 않는다.
4. PDF 안 웹 링크 → 브라우저. ⌘W → 프리뷰만 닫힘. File ▸ Show in Finder(⌥⌘R)와 우클릭 Show in Finder → 파일 선택. ⌘C로 선택한 텍스트 복사.
5. md 프리뷰 안의 `.pdf` 링크, md 창에 PDF 드롭 → PDF 창이 뜬다.

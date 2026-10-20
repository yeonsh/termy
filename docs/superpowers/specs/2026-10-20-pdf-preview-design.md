# PDF 프리뷰 창 — 설계 문서

- 날짜: 2026-10-20
- 상태: 승인(2026-10-20), 구현 계획 `docs/superpowers/plans/2026-10-20-pdf-preview.md`
- 범위: termy pane에서 `.pdf` 파일 경로를 Cmd+클릭하면 termy 안의 프리뷰 창으로 연다
- 선행 작업: `docs/superpowers/specs/2026-10-12-markdown-preview-design.md` (md 프리뷰)

## 1. 목표와 동기

agent가 PDF 보고서를 만들고 그 경로를 출력한다. 지금은 그 경로를 Cmd+클릭해도 아무 일이
일어나지 않는다(`linkClickAction`이 md가 아닌 경로를 `.ignore`로 보낸다). 결과물을 확인하려면
Finder나 다른 앱에서 파일을 찾아가야 한다. 예외로 `file:///…/report.pdf` 형태의 링크는 지금
`openableURL`을 통과해 기본 앱(미리보기)으로 열린다. 이 작업 뒤에는 md처럼 termy 프리뷰로 열린다.

이 작업의 목표는 **agent가 만든 PDF 보고서를 그 자리에서 확인하고, agent가 다시 만들면 바로
다시 보는 것**이다. "확인 → 고쳐 달라고 요청 → agent가 다시 생성 → 다시 확인"이 반복되는 흐름을
가정한다(사용자 확인: "md처럼 termy 창에서 열고 자동 갱신되면 좋겠어").

성공 기준:

- agent 출력에 나온 `.pdf` 경로를 Cmd+클릭하면 termy 프리뷰 창에 PDF가 뜬다.
- agent가 PDF를 다시 만들면(제자리 덮어쓰기든 atomic save든) 창이 저절로 갱신된다.
- 갱신 뒤에도 보던 페이지와 그 페이지 안의 위치, 확대 배율이 유지된다.
- md 프리뷰와 같은 창 규칙을 따른다: 파일당 창 하나, ⌘W는 프리뷰만 닫음, Show in Finder.

## 2. 비목표

- 주석, 편집, 양식 채우기, 인쇄, 저장
- PDF 안 텍스트 찾기(⌘F). md 프리뷰에도 없다.
- ⌘+ / ⌘- 키보드 확대. 이 키는 터미널 글꼴 크기 액션(`increaseFontSize`/`decreaseFontSize`)이고
  프리뷰가 key일 때 꺼져 있다. 확대는 트랙패드 pinch와 PDFView 기본 context menu로 한다.
- PDF 안에서 다른 파일을 가리키는 상대 경로 링크와 remote go-to 액션(LaTeX hyperref·pandoc이
  만드는 다른 PDF 링크). 문서를 `PDFDocument(data:)`로 읽어 base URL이 없으므로 풀지 않는다.
  상대 URI는 아무것도 하지 않고, remote go-to는 PDFKit 기본 동작(beep)대로 둔다.
- 암호 걸린 PDF 열기
- PDF 창에 파일을 끌어다 놓아 여는 것(md 창에는 이미 있다. 8절 참고)
- 프리뷰 창의 세션 저장·복원, Mission Control 표시 (md와 같음)
- 슬래시 없는 파일 이름(`report.pdf`)을 Cmd+클릭으로 열기. SwiftTerm 1.20.0의 implicit link
  감지가 `dir/x`, `./x`, `/abs`, `~/x` 형태만 잡기 때문이며 md도 같다. md·pdf를 함께 고치는 별도
  작업으로 남긴다(사용자 결정, 2026-10-20). `docs/local/2026-10-12-markdown-preview-followups.md` 1번.
- `report.pdf:3` 같은 페이지 번호 위치로 이동. `:숫자` 접미사는 md처럼 떼어 내고 무시한다.
- 설정 UI

반대 목표(이렇게 되면 기능이 동작해도 실패다):

- agent가 PDF를 쓰는 도중에 Cmd+클릭하거나 갱신이 일어나서 앱이 죽는다.
- 갱신될 때마다 첫 페이지로 튀거나 배율이 초기화된다.
- PDF 안 링크 클릭이 앱이나 스크립트를 실행한다.

## 3. 현재 구조 (출발점)

md 프리뷰가 이미 같은 흐름을 갖고 있다. PDF는 이 흐름에 두 번째 종류로 끼운다.

- **Cmd+클릭**: `TermyTerminalView.openLinkUnderMouse`가 링크 텍스트를
  `linkClickAction(for:baseDirectories:homeDirectory:isRegularFile:)`(순수 함수)에 넘긴다.
  이 함수는 `MarkdownLinkResolver.resolve`의 결과로 `.previewMarkdown(URL)` / `.beep` /
  `.openURL` / `.ignore`를 고른다. `.previewMarkdown`이면 `onOpenMarkdownFile`(Pane이 설정)이
  `MarkdownPreviewManager.shared.open(url)`을 부른다.
- **경로 해석**: `MarkdownLinkResolver`(`MarkdownLinkResolver.swift`)가 앞뒤 구두점,
  `file://`, `#fragment`, `:줄[:열]`, 확장자 뒤에 붙은 한글 조사 등을 떼어 내고, pane의 cwd 후보
  (`Pane.markdownBaseDirectories()`) 가운데 파일이 있는 첫 곳을 고른다. 확장자 집합은
  `["md", "markdown"]`이고, 붙은 글자를 자르는 정규식 `^.*?\.(md|markdown)(?![A-Za-z0-9._/-])`도
  md 전용이다.
- **창 관리**: `MarkdownPreviewManager`가 symlink를 푼 경로를 key로 파일당
  `MarkdownPreviewWindowController` 하나를 둔다. 첫 창은 클릭한 창의 화면 가운데, 다음 창은 가장
  최근 프리뷰에서 cascade한다. `isPreviewWindow(_:)`, `closeAll()`을 제공한다.
- **파일 감시**: `MarkdownFileWatcher`는 이름과 달리 md에 묶인 부분이 없다. 파일과 상위
  디렉터리를 DispatchSource로 감시하고, 0.15초 debounce 뒤 stat fingerprint로
  `.modified` / `.deleted` / `.recreated`를 알린다. atomic save도 잡는다.
- **md 창 컨트롤러**: `MarkdownPreviewWindowController`가 WKWebView, 삭제 배너
  (`deletedBanner`), 창 크기 저장(`MarkdownPreview.contentSize`), Show in Finder
  (`showInFinder(_:)`, `finderReveal(for:exists:)`), 문서 안 링크 라우팅(`route`/`linkRoute`)을
  갖는다. 문서 안 `file://` 링크는 resolver를 거쳐 다른 프리뷰로 연다.
- **AppDelegate**: `MarkdownPreviewManager.isPreviewWindow(NSApp.keyWindow)`로 ⌘W를
  "Close Preview"로 바꾸고, pane 전용 액션(`paneScopedActions`)을 끈다. File ▸ Show in Finder는
  target이 nil이라 key 프리뷰의 `showInFinder(_:)`가 responder chain으로 받는다.
  Edit ▸ Copy도 target이 nil(`NSText.copy(_:)`)이다.
- **WindowManager**: 마지막 메인 창이 닫히면 `MarkdownPreviewManager.shared.closeAll()`.
- **빌드**: XcodeGen. `apps/termy/Sources` 아래 새 파일은 `xcodegen generate`로 들어간다.
  PDFKit은 시스템 framework라 패키지 추가가 없다.

## 4. 결정 사항

| 항목 | 결정 | 출처 |
|---|---|---|
| 표시 위치 | termy 안 별도 창 (md 프리뷰와 같은 방식) | 사용자 |
| 갱신 | 파일이 바뀌면 자동 갱신 | 사용자 |
| 창 규칙 | 파일당 창 하나, ⌘W는 프리뷰만, Show in Finder, 창 크기 기억 | 사용자 승인(제안) |
| 렌더링 | PDFKit `PDFView`. 새 의존성 없음 | 사용자 승인(제안) |
| 갱신 시 위치 | 페이지, 페이지 안 위치, 배율 유지 | 사용자 승인(제안) |
| 덜 쓰인 파일 | 이전 버전을 계속 보여 준다 | 사용자 승인(제안) |
| 파일 삭제 | md와 같은 삭제 배너, 다시 생기면 새로 불러옴 | 사용자 승인(제안) |
| PDF 안 웹 링크 | 브라우저로 연다 | 사용자 승인(제안) |
| 공용 부분 이름 | resolver·manager·watcher를 종류 중립 이름으로 바꾼다 (5.1) | 설계자 판단 |
| PDF 파일 읽기 | `Data`로 통째로 읽은 뒤 `PDFDocument(data:)`. `PDFDocument(url:)`·mmap 금지 | 설계자 판단 |
| 덜 쓰인 판 판정 | 끝에 `%%EOF`가 있어야 끼운다. 없으면 1초 안정 대기 뒤 한 번 더 판정 (5.5) | 설계자 판단 |
| PDF 안 상대 경로·remote go-to 링크 | 풀지 않는다 (비목표) | 설계자 판단 |
| 창 크기 key | md와 따로 `PDFPreview.contentSize` | 설계자 판단 |

## 5. 컴포넌트 설계

### 5.1 공용 부분 일반화 (동작 변화 없는 이름 바꾸기)

PDF를 받게 되면 의미가 바뀌는 타입만 이름을 바꾼다. md 전용 타입(`MarkdownHTMLRenderer`,
`MarkdownPreviewStyle`, `MarkdownPreviewWebView`, `MarkdownPreviewWindowController`)은 그대로 둔다.

| 지금 | 바꾼 뒤 |
|---|---|
| `MarkdownLinkResolver` / `MarkdownLinkResolution` | `PreviewLinkResolver` / `PreviewLinkResolution` |
| `MarkdownLinkResolution.notMarkdown` | `.notPreviewable` |
| `MarkdownLinkResolver.markdownPath(from:)` | `previewPath(from:)` |
| `MarkdownPreviewManager` | `PreviewManager` |
| `MarkdownFileWatcher` | `PreviewFileWatcher` (`FileFingerprint`, `FileChange`는 그대로) |
| `LinkClickAction.previewMarkdown(URL)` | `.preview(URL)` |
| `TermyTerminalView.markdownBaseDirectories` / `onOpenMarkdownFile` | `previewBaseDirectories` / `onOpenPreviewFile` |
| `Pane.markdownBaseDirectories` (인스턴스·static) | `previewBaseDirectories` |

파일 이름과 테스트 파일·클래스 이름도 같이 바꾼다(`git mv`). 이 단계는 동작을 바꾸지 않으며,
기존 테스트가 이름만 바뀐 채 모두 통과해야 한다. 별도 커밋으로 둔다.

### 5.2 경로 해석 — `PreviewLinkResolver`

- `extensions`를 `["md", "markdown", "pdf"]`로 넓힌다.
- 붙은 글자를 자르는 정규식을 `^.*?\.(md|markdown|pdf)(?![A-Za-z0-9._/-])`로 넓힌다.
  예: `보고서를 out/report.pdf에 저장했습니다.` → `out/report.pdf`.
- 나머지 규칙(구두점, `file://`, 웹 URL 제외, `#`, `:숫자`, 기준 디렉터리 순서, 정규 파일만)은
  그대로다. `https://…/x.pdf`는 지금처럼 `.notPreviewable` → 브라우저로 간다.
- 종류 판정 헬퍼를 하나 둔다. 확장자(대소문자 무시)로 정한다.

  ```swift
  enum PreviewKind: Equatable { case markdown, pdf }
  extension PreviewKind { init?(fileURL: URL) }   // md/markdown → .markdown, pdf → .pdf, 그 밖 nil
  ```

  Cmd+클릭 경로, md 문서 안 링크, md 창 드롭이 모두 resolver를 거치므로, 이 변경만으로 세 곳 모두
  PDF를 `.file(URL)`로 받게 된다. 종류에 따라 어느 창을 띄울지는 `PreviewManager`가 정한다.

### 5.3 클릭 연결 — `TermyTerminalView`, `Pane`

- `linkClickAction`은 `.file(url)`이면 종류와 상관없이 `.preview(url)`을 돌려준다.
  `.missing`(PDF 경로처럼 생겼는데 파일이 없음)은 md처럼 `.beep`.
- `onOpenPreviewFile`은 `PreviewManager.shared.open(url)`을 부른다. 터미널 뷰는 종류를 모른다.
- `requestOpenLink` override(SwiftTerm 기본 opener 차단)는 그대로다. 미리보기 경로는 monitor가
  먼저 소비한다.

### 5.4 창 관리 — `PreviewManager`

- 파일당 창 하나 규칙, key 계산(`key(for:)`), 배치(`centeredFrame`, cascade), `closeAll()`을
  두 종류가 함께 쓴다. md 창 다음에 PDF 창을 열면 md 창에서 cascade한다.
- `open(_ url:)`은 `PreviewKind(fileURL:)`로 `MarkdownPreviewWindowController` 또는
  `PDFPreviewWindowController`를 만든다. 종류를 알 수 없는 URL은 호출 쪽에서 오지 않지만, 오면
  아무것도 하지 않는다(반환형은 optional이 되거나 공용 타입이 된다 — 빌더 재량).
- 두 컨트롤러가 공유하는 최소 인터페이스(예: `fileURL`, `onClose`, `window`)를 프로토콜로 묶어
  `controllers` 사전에 넣는다. 형태는 빌더 재량이다.
- `isPreviewWindow(_:)`는 두 종류 모두에 `true`다. AppDelegate의 ⌘W·pane 액션 처리와
  `WindowManager.removeWindow`의 `closeAll()`은 이 변경만으로 PDF 창까지 덮는다.

### 5.5 PDF 창 — `PDFPreviewWindowController` (신규)

창 껍데기는 md 창과 같게 만든다.

- `NSWindow` styleMask `[.titled, .closable, .miniaturizable, .resizable]`, `title` = 파일 이름,
  `subtitle` = `~`로 줄인 상위 디렉터리, `representedURL` = 파일, `tabbingMode = .disallowed`,
  `isReleasedWhenClosed = false`.
- 창 크기: 닫을 때 `contentLayoutRect.size`를 주입받은 `UserDefaults`의
  `PDFPreview.contentSize`에 저장하고 다음 창에 쓴다. 저장값이 320×240보다 작거나 없으면 기본값
  820×900. 검증 규칙은 md의 `savedContentSize`와 같으니 공유해도 된다.
- `windowWillClose`에서 watcher를 멈추고 크기를 저장하고 `onClose`를 부른다.

내용은 `PDFView`다.

- `autoScales = true`(창 폭에 맞춤), `displayMode = .singlePageContinuous`,
  `displaysPageBreaks = true`. 텍스트 선택과 Edit ▸ Copy(⌘C)는 PDFView 기본 동작으로 된다.
- 문서 위에 배너 한 줄을 둘 수 있게 한다(배너가 없으면 공간을 차지하지 않는다). 배너가 떠도
  PDF는 그 아래에 계속 보인다. 배치 방식은 빌더 재량.

#### 불러오기와 갱신

watcher는 `PreviewFileWatcher`를 그대로 쓴다. 첫 불러오기와 `.modified`/`.recreated`에서:

1. `Data(contentsOf: fileURL)`로 통째로 읽는다. `.alwaysMapped`/`.mappedIfSafe`를 쓰지 않고
   `PDFDocument(url:)`도 쓰지 않는다. agent가 파일을 제자리에서 잘라 다시 쓰면 매핑된 페이지가
   사라져 SIGBUS로 죽을 수 있다(반대 목표 1).
2. **완성된 판인지 판정한다.** 끝 1024바이트 안에 `%%EOF`가 있고, `PDFDocument(data:)`가
   nil이 아니며 `pageCount > 0`이면 완성된 판이다.
   - `PDFDocument(data:)`만으로는 부족하다. CoreGraphics는 잘린 파일의 cross-reference를 복구해서
     읽어 내는 경우가 많고, ReportLab·WeasyPrint처럼 페이지 목록을 먼저 쓰는 생성기의 잘린 파일은
     페이지 수는 다 있는데 내용이 빈 채로 열린다. 그런 판을 끼우면 빈 페이지가 보이거나, 페이지 수가
     줄어 위치가 마지막 페이지로 잘린 채 돌아오지 않는다. 완성된 PDF는 `%%EOF`로 끝난다.
3. **완성되지 않은 판이면 이전 문서를 그대로 두고 기다린다.** 배너는 바로 띄우지 않는다.
   watcher 알림이 새로 오면 기다리기를 처음부터 다시 한다. 마지막 알림 뒤 1초 동안 파일
   fingerprint가 변하지 않으면 쓰기가 끝난 것으로 보고 한 번 더 판정한다.
   - 이때는 `%%EOF` 조건을 빼고 `PDFDocument(data:)`가 읽히고 `pageCount > 0`이면 끼운다.
     끝 표식이 빠진 약간 어긋난 PDF도 미리보기 앱처럼 보여 주기 위해서다.
   - 그래도 못 읽으면: 첫 불러오기라면 빈 화면에 배너 `Couldn't read this PDF.`, 갱신이라면 이전
     문서를 두고 배너 `Couldn't read the new version. Showing the previous one.`.
     다음에 완성된 판이 읽히면 배너를 내린다.
   - 이전 문서를 계속 두므로, 끼우지 않은 판 때문에 보던 위치를 잃는 일은 없다.
4. 파일을 읽다가 오류가 나면(권한 등) md와 같은 배너: `Couldn't read this file: <error.localizedDescription>`.
   갱신 중이면 이전 문서는 그대로 둔다.
5. 끼울 판이 정해지면 문서를 바꿔 끼우고 배너를 내린다. 바꿔 끼우기 전에 위치를 저장하고 뒤에 되돌린다.
   - 저장: 현재 페이지 번호(`document.index(for:)`), 그 페이지 안의 보이는 지점
     (`currentDestination`), `autoScales`와 `scaleFactor`.
   - 복원: `autoScales`가 꺼져 있었다면 `scaleFactor`를 되돌린다. 페이지 번호를 새 문서의
     `pageCount - 1`로 자른 뒤 같은 지점으로 이동한다.
   - `PDFView.go(to:)`와 `currentDestination`의 좌표가 정확히 맞물리는지는 문서만으로 확신할 수
     없다. 갱신 전후로 화면이 몇 줄이라도 밀리면 내부 scroll view의 clip 원점을 직접 저장·복원하는
     방식으로 바꾼다. 어느 쪽이든 실제 앱에서 확인한다(7절).

`.deleted`에서는 문서를 그대로 두고 md와 같은 배너
(`This file was deleted. The preview will reload if it comes back.`)를 띄운다. `.recreated`면
위 순서로 다시 불러온다.

#### PDF 안 링크

`PDFViewDelegate.pdfViewWillClick(onLink:with:)`를 구현해 PDFView 기본 동작(URL을 그대로
`NSWorkspace.open`)을 막는다. 문서 안 이동(목차, 각주 등 goto 액션)은 이 delegate를 거치지 않고
PDFView가 처리한다.

| 링크 | 동작 |
|---|---|
| `http`, `https`, `mailto` | `NSWorkspace.shared.open` |
| `file://` 이고 resolver가 `.file`을 돌려줌(md·pdf) | `PreviewManager.shared.open` |
| 그 밖(다른 scheme, 앱·스크립트 file URL, 없는 파일) | 아무것도 하지 않는다 |

결정 함수는 테스트할 수 있게 순수 static 함수로 둔다. md 창의 `linkRoute`와 겹치는 부분을
공유할지는 빌더 재량이다.

#### Show in Finder

- `@objc func showInFinder(_:)`를 md 창과 **같은 selector 이름**으로 구현한다. File 메뉴 항목은
  target이 nil이라 key인 프리뷰가 받는다. `validateMenuItem`으로 켜고 끈다.
- 판정은 md의 `finderReveal(for:exists:)`(파일이 있으면 선택, 없으면 상위 폴더, 그것도 없으면
  끔)와 같다. 두 컨트롤러가 함께 쓰게 옮긴다.
- PDFView context menu 끝에 구분선과 `Show in Finder`를 더한다(md 창과 같은 모양).
  PDFView 기본 항목(확대·축소, 보기 방식 등)은 그대로 둔다.

### 5.6 AppDelegate, WindowManager

- `isPreviewWindow`가 PDF 창을 포함하므로 ⌘W("Close Preview"), pane 액션 끄기, Show in Finder
  메뉴는 코드 변경 없이 PDF 창에도 적용된다. 이름 바꾸기(5.1)로 인한 호출 이름 변경만 있다.
- `#selector(MarkdownPreviewWindowController.showInFinder(_:))`는 선택자만 쓰이므로 그대로 둬도
  된다. 다만 PDF에도 쓰인다는 주석을 한 줄 고친다.
- `WindowManager.removeWindow`의 `closeAll()` 호출 이름만 바뀐다.

## 6. 문구

UI 문구는 영어이며 그대로 쓴다.

- 첫 불러오기 실패: `Couldn't read this PDF.`
- 갱신 실패: `Couldn't read the new version. Showing the previous one.`
- 파일 읽기 오류: `Couldn't read this file: <error.localizedDescription>` (md와 같음)
- 삭제: `This file was deleted. The preview will reload if it comes back.` (md와 같음)
- 메뉴: `Show in Finder`, `Close Preview` (md와 같음)

## 7. 테스트

단위 테스트(XCTest). 테스트는 `UserDefaults.standard`에 쓰지 않는다.

- **resolver**: `out/report.pdf`, `./report.pdf:3`, `file:///…/report.pdf`, `report.pdf에 저장했습니다.`,
  `` `report.pdf` ``가 PDF로 해석된다. `https://…/report.pdf`는 `.notPreviewable`.
  `report.pdfx`, `report.pdf.bak`은 `.notPreviewable`. 없는 PDF는 `.missing`.
  `PreviewKind(fileURL:)`가 대소문자를 무시하고 종류를 가른다.
- **linkClickAction**: 있는 PDF → `.preview`, 없는 PDF → `.beep`, `.pdf`로 끝나는 웹 URL → `.openURL`.
- **PreviewManager**: PDF를 열면 `PDFPreviewWindowController`가 뜬다. 같은 PDF를 두 번 열면 창을
  재사용한다. md와 PDF를 함께 열면 창 두 개, cascade, `closeAll()`이 둘 다 닫는다.
  `isPreviewWindow`가 PDF 창에 `true`.
- **PDF 창**: 제목·부제·`representedURL`. 창 크기 저장·복원(주입한 defaults). 읽을 수 없는 첫
  파일 → 배너. 정상 문서 뒤에 깨진 데이터로 갱신 → 이전 문서 유지 + 배너, 다시 정상 데이터 →
  배너 내려감. `%%EOF`가 없는 잘린 데이터로 갱신 → 이전 문서 유지·배너 없음, 안정 대기 뒤
  읽히면 끼움·못 읽으면 배너. 대기 중 새 알림이 오면 대기를 다시 시작. 안정 대기 시간(1초)은
  테스트에서 짧게 주입한다. 삭제 → 삭제 배너. 링크 라우팅 표의 각 줄. Show in Finder 판정과 context menu 끝 항목.
  갱신 뒤 페이지 번호 유지와 페이지 수가 줄었을 때 마지막 페이지로 자르기.
  테스트용 PDF는 코드로 만든다(예: `PDFDocument`에 `PDFPage`를 넣고 `dataRepresentation()`).
- **AppDelegate 메뉴**: PDF 창이 key일 때 ⌘W 제목이 "Close Preview", pane 액션이 꺼짐,
  File ▸ Show in Finder가 PDF 창으로 간다.

실제 앱 확인(사용자가 직접, 또는 termy 밖 세션에서). 이 저장소의 세션은 보통 termy 안에서 돌기
때문에 agent가 두 번째 termy를 띄우면 hook socket과 session.json을 가로챈다.

1. agent가 출력한 `.pdf` 경로(`out/report.pdf`처럼 `/`가 들어간 것)를 Cmd+클릭 → 창이 뜬다.
   한글 조사가 붙은 경로(`out/report.pdf에 저장했습니다.`)도.
2. 중간 페이지로 스크롤하고 확대한 상태에서 agent가 PDF를 다시 만든다 → 같은 페이지·위치·배율로
   갱신된다(5.5의 좌표 방식 확인).
3. 큰 PDF를 천천히 쓰는 상황(예: `dd`로 나눠 쓰기) → 앱이 죽지 않고, 쓰는 동안 이전 판이 그대로
   보이다가 쓰기가 끝나면 새 판으로 바뀐다. 배너는 뜨지 않는다.
4. PDF 안 웹 링크 → 브라우저. ⌘W → 프리뷰만 닫힘. Show in Finder → 파일 선택.

## 8. 따라오는 동작 (설계자 판단)

resolver가 PDF를 받게 되면서 추가 작업 없이 생기는 동작이다. 막을 이유가 없어 그대로 둔다.

- md 프리뷰 안의 `report.pdf` 링크를 클릭하면 PDF 프리뷰가 뜬다.
- md 프리뷰 창에 PDF 파일을 끌어다 놓으면 PDF 프리뷰가 뜬다.
  (`MarkdownPreviewWebView`의 `onDropMarkdownFiles`·`markdownFiles(in:)` 이름은 의미가 넓어지므로
  `onDropPreviewFiles`·`previewFiles(in:)`로 바꾼다.)

## 9. 빌더에게 맡기는 것

- 공용 프로토콜의 모양과 이름, `PreviewManager.open`의 반환형
- 배너 뷰의 배치 방식(스택 뷰, overlay 등)
- md `linkRoute`/`savedContentSize`/`finderReveal`을 공유 위치로 옮길지, 옮긴다면 어디로
- 갱신 시 위치 복원 방식(`PDFDestination` 또는 clip view 원점). 단, 실제 앱 확인을 통과해야 한다.

# 이미지 파일 미리보기 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 터미널에서 이미지 파일 경로를 Cmd+클릭하면 markdown·PDF처럼 termy 미리보기 창이 열린다.

**Architecture:** PDF 미리보기를 그대로 따른다. `PreviewKind`에 `.image`를 더하고, `PreviewLinkResolver`가 이미지 확장자를 받으며, `PreviewManager`가 새 `ImagePreviewWindowController`를 만든다. 창은 `NSScrollView`(magnification) 안의 `NSImageView`로 그림을 보여 주고, `PreviewFileWatcher`로 파일이 바뀌면 다시 읽는다. 덜 쓰인 파일은 PDF처럼 완성본만 바꿔 넣는다.

**Tech Stack:** Swift 6, AppKit(`NSScrollView`, `NSImageView`, `NSImage`), XCTest. 새 의존성 없음.

**Spec:** 별도 spec 없음. 사용자 요청(2026-11-07): "markdown 파일명을 클릭했을 때 미리보기를 보여주듯이 png 등의 이미지 파일에 대해서도 처리하자", "PDF 미리보기처럼 바로 진행해". 아래 결정은 모두 controller의 판단이고, 근거는 PDF 미리보기의 기존 동작과 아래 실측이다.

실측(2026-11-07, macOS 14+ AppKit/ImageIO):
- ImageIO는 덜 쓰인 PNG·JPEG도 `CGImageSourceGetStatus == complete`로 보고하고, `NSImage(data:)`는 반쯤 쓰인 PNG·JPEG도 전체 크기로 연다. 그래서 완성 여부는 형식별 끝 표시로 직접 본다(PDF의 `%%EOF` 규칙과 같은 자리).
- 덜 쓰인 GIF·TIFF는 `NSImage(data:)`가 크기 0으로 연다.
- SVG는 ImageIO가 모르고(`CGImageSourceGetType == nil`) `NSImage(data:)`는 읽는다(`_NSSVGImageRep`). 반쯤 쓰인 SVG는 nil.
- ImageIO 지원: webp, heic, heics, avif 포함.

## Global Constraints

- 이미지 확장자(소문자 비교): `png`, `jpg`, `jpeg`, `gif`, `webp`, `heic`, `heif`, `avif`, `tif`, `tiff`, `bmp`, `svg`.
- 창 크기 저장 키: `"ImagePreview.contentSize"`(PDF는 `"PDFPreview.contentSize"`, markdown은 `"MarkdownPreview.contentSize"`로 각자 따로).
- 배너 문구: 처음부터 못 읽음 `"Couldn't read this image."`, 새 버전을 못 읽음 `"Couldn't read the new version. Showing the previous one."`, 삭제됨은 기존 `MarkdownPreviewWindowController.deletedBanner`, 읽기 오류는 기존 `PreviewWindowSupport.readErrorBanner(_:)`.
- 기본 settle 간격 1.0초(PDF와 같음).
- PDF 미리보기와 같은 창 규칙: 제목 = 파일 이름, subtitle = `~`로 줄인 폴더 경로, `representedURL` = 파일, `tabbingMode = .disallowed`, `isReleasedWhenClosed = false`, 오른쪽 클릭 메뉴 끝에 "Show in Finder", File ▸ Show in Finder(⌥⌘R)가 responder chain으로 닿음.
- Swift 6 language mode. 새 파일을 만들면 `xcodegen generate`를 먼저 돌린다(`termy.xcodeproj`는 git에 없다).
- 테스트 명령(`-derivedDataPath`와 `-skipPackagePluginValidation`이 없으면 이 환경에서 EPERM이나 plugin 검증 오류가 난다):
  `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25` → `** TEST SUCCEEDED **`. 전체(약 887개)는 `-only-testing` 없이. 로그의 WebKit `pboard`/RBS `error:` 줄은 원래 있는 잡음이다.
- 테스트 host: 마지막으로 보이는 window가 닫히면 앱이 끝난다. 미리보기 테스트는 `PDFPreviewWindowControllerTests`처럼 sentinel window를 앞에 둔다.
- 주석은 그 파일의 언어를 따른다(미리보기 코드는 영어). 커밋 메시지는 한국어, `Co-Authored-By` 줄 없음.

## Review Focus

1. 에이전트가 스크린샷을 그 자리에서 다시 쓸 때(truncate 후 rewrite) 반쯤 그려진 그림이 보이면 안 된다. 이전 그림이 남아 있다가 완성본으로 바뀌어야 한다 → Task 1 `test_reload_inPlaceTruncateThenRewrite_keepsPreviousThenSwaps`.
2. 8000×6000 같은 큰 스크린샷은 창에 맞게 줄어 보여야 한다(1:1로 넘치지 않음) → Task 1 `test_firstLoad_bigImageFitsWindow`.
3. 16×16 아이콘 같은 작은 그림은 늘리지 않고 100%로 가운데에 보여야 한다 → Task 1 `test_fitMagnification`(1을 넘지 않음).
4. 이름만 `.png`인 빈 파일이나 다른 파일은 배너를 보여야 하고 죽으면 안 된다 → Task 1 `test_firstLoad_unreadableFileShowsBannerAfterSettling`(빈 파일 포함).
5. `https://…/a.png`, `a.png.bak`, `a.pngx`는 미리보기로 가로채면 안 된다 → Task 2 `test_imagePathsResolve`.

---

### Task 1: ImagePreviewWindowController

**Files:**
- Create: `apps/termy/Sources/ImagePreviewWindowController.swift`
- Create: `apps/termy/Sources/ImagePreviewView.swift` (`ImagePreviewScrollView`, `CenteringClipView`)
- Test: `apps/termy-tests/Sources/ImagePreviewWindowControllerTests.swift`

참고할 기존 코드: `PDFPreviewWindowController.swift`(구조·reload/settle·배너·Show in Finder·windowWillClose를 그대로 따른다), `PDFPreviewView.swift`(`onWillOpenMenu` 패턴), `PDFPreviewWindowControllerTests.swift`(sentinel, `waitUntil`, `writeInPlace`, `openPreview` helper).

**Interfaces:**
- Consumes: `PreviewWindowController` protocol, `PreviewFileWatcher`/`FileChange`, `PreviewWindowSupport`, `MarkdownPreviewWindowController.deletedBanner` (모두 기존).
- Produces (Task 2가 쓴다):
  - `@MainActor final class ImagePreviewWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, PreviewWindowController`
  - `init(fileURL: URL, defaults: UserDefaults = .standard, settleInterval: TimeInterval = ImagePreviewWindowController.defaultSettleInterval)`
  - `@objc func showInFinder(_ sender: Any?)`
  - statics: `defaultSettleInterval`, `contentSizeDefaultsKey`, `unreadableBanner`, `staleBanner`
  - `nonisolated static func hasEndMarker(_ data: Data) -> Bool`
  - `nonisolated static func image(from data: Data, requireEndMarker: Bool) -> NSImage?`
  - `nonisolated static func fitMagnification(imageSize: NSSize, viewSize: NSSize) -> CGFloat`
  - 테스트용 접근: `let scrollView: ImagePreviewScrollView`, `let imageView: NSImageView`, `private(set) var bannerText: String?`, `private(set) var fitsWindow: Bool`, `func toggleFitOrActualSize()`

동작(결정 사항):
- **끝 표시(`hasEndMarker`)** — 형식은 확장자가 아니라 data 앞부분 signature로 본다(이름과 내용이 다른 파일도 있다):
  - PNG(`89 50 4E 47 0D 0A 1A 0A`): 마지막 64바이트 안에 IEND chunk 12바이트 `00 00 00 00 49 45 4E 44 AE 42 60 82`가 통째로 있다.
  - JPEG(`FF D8 FF`): 마지막 32바이트 안에 `FF D9`.
  - GIF(`GIF87a`/`GIF89a`): 마지막 바이트가 `0x3B`.
  - WebP(`RIFF`, 8..<12가 `WEBP`): 4..<8의 little-endian UInt32 + 8 ≤ data.count.
  - BMP(`BM`): 2..<6의 little-endian UInt32 ≤ data.count.
  - 그 밖(TIFF, HEIC/HEIF, AVIF, SVG, 모르는 것): `true`(끝 표시 규칙 없음, decode가 정한다).
- **`image(from:requireEndMarker:)`**: `requireEndMarker`이고 끝 표시가 없으면 nil. 아니면 `NSImage(data:)`이 `isValid`이고 크기 가로·세로가 0보다 클 때만 그 그림.
- **`fitMagnification`**: `min(1, viewW / imageW, viewH / imageH)`. 어느 크기든 0 이하이면 1.
- **reload/settle**: `PDFPreviewWindowController.reload(after:)`/`settle()`과 같은 규칙. 처음 읽기와 변경은 `requireEndMarker: true`로만 바꿔 넣고, 아니면 settle을 예약한다. settle에서는 `requireEndMarker: false`로 한 번 더 보고, 그래도 못 읽으면 보여 준 그림이 없을 때 `unreadableBanner`, 있을 때 `staleBanner`. 삭제는 `deletedBanner`. 파일은 `Data(contentsOf:)`로 통째로 읽는다(map 금지, PDF 머리 주석과 같은 이유).
- **보기**: `scrollView.documentView`가 `imageView`. `imageView.frame.size = image.size`(point, Retina 스크린샷은 자연 크기), `imageScaling = .scaleAxesIndependently`, `animates = true`(GIF). `scrollView`는 `allowsMagnification = true`, `minMagnification = 0.01`, `maxMagnification = 16`, scroller 자동 숨김, `contentView`는 `CenteringClipView`(그림이 보이는 영역보다 작으면 가운데).
- **맞춤(fit)**: `fitsWindow`는 처음에 true. true인 동안 처음 읽기·창 크기 변경·새 버전 swap마다 `magnification = fitMagnification(image.size, scrollView.contentSize)`. 사용자가 pinch를 끝내면(`NSScrollView.didEndLiveMagnifyNotification`) false. false일 때 swap은 magnification과 보던 위치를 그대로 둔다. 그림을 더블클릭하면 `toggleFitOrActualSize()`: 맞춤 중이면 100%(`fitsWindow = false`, magnification 1), 아니면 다시 맞춤.
- **오른쪽 클릭**: `ImagePreviewScrollView.menu(for:)`가 `super.menu(for:) ?? NSMenu()`에 `onWillOpenMenu`를 불러 "Show in Finder"를 붙인다(`PDFPreviewView`와 같은 모양, 항목이 있으면 separator 먼저).
- 창 구성·banner stack·Show in Finder·`validateMenuItem`·`windowWillClose`(watcher 정지, settle 취소, `contentLayoutRect.size` 저장, `onClose`)는 PDF와 같다.

- [ ] **Step 1: 실패하는 테스트를 쓴다** — `ImagePreviewWindowControllerTests`(`@MainActor`, sentinel window). helper: `makeBitmap(width:height:type:) -> Data`(`NSBitmapImageRep`로 `.png`/`.jpeg`/`.gif`/`.bmp`/`.tiff`), `makeShot(_ data: Data, name: String = "shot.png") -> URL`, `writeInPlace`, `waitUntil`, `openPreview(_:defaults:settleInterval:)`. 테스트와 단언:

```swift
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
```

나머지 테스트(단언은 이름대로, PDF의 같은 이름 테스트를 본뜬다):
- `test_windowShowsFileNameAndDirectory`: 제목 `"shot.png"`, subtitle, `representedURL`, `.disallowed`.
- `test_viewSettings`: `imageView.animates`, `scrollView.allowsMagnification`, `scrollView.documentView === imageView`, `scrollView.contentView is CenteringClipView`.
- `test_closingStoresContentSizeUnderImageKey`: `"ImagePreview.contentSize"`가 생기고 `"PDFPreview.contentSize"`는 nil.
- `test_firstLoad_showsImage`: 120×80 PNG → `imageView.image?.size == (120, 80)`, `bannerText == nil`, `fitsWindow`, `scrollView.magnification == 1`.
- `test_firstLoad_bigImageFitsWindow`: 4000×3000 PNG → `scrollView.magnification`이 `fitMagnification(imageSize: (4000,3000), viewSize: scrollView.contentSize)`와 같다(accuracy 0.001) 그리고 1보다 작다.
- `test_firstLoad_unreadableFileShowsBannerAfterSettling`: 내용 `"not an image"`인 `shot.png`과 빈 `empty.png` 각각, `settleInterval: 0.2` → `bannerText == unreadableBanner`가 될 때까지 기다린다.
- `test_firstLoad_readErrorShowsReadBanner`: PDF 테스트와 같은 방법으로 읽기 오류 → `readErrorBanner` 문구로 시작.
- `test_reload_swapsCompleteVersion`: 다른 크기(200×100) PNG를 atomic으로 쓰면 `imageView.image?.size == (200, 100)`이 된다.
- `test_reload_inPlaceTruncateThenRewrite_keepsPreviousThenSwaps`: 120×80을 연 뒤 `writeInPlace(새 200×100 PNG의 앞 절반)` → 그동안 크기는 120×80 그대로, 이어 `writeInPlace(전체)` → 200×100.
- `test_reload_unreadableAfterSettling_showsStaleBannerThenClears`: 그 자리에 garbage → `staleBanner`(그림은 이전 것), 다시 완성 PNG → 배너 nil.
- `test_reload_keepsManualZoom`: 4000×3000을 연 뒤 `scrollView.magnification = 2`와 `NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: controller.scrollView)` → `fitsWindow == false`, 새 버전 swap 뒤에도 `magnification == 2`.
- `test_toggleFitOrActualSize`: 4000×3000에서 toggle → magnification 1·`fitsWindow == false`, 다시 toggle → fit 값·`fitsWindow == true`.
- `test_deleted_showsDeletedBannerThenReloadsWhenRecreated`.
- `test_contextMenuEndsWithShowInFinder`(`controller.scrollView.menu(for:)`), `test_showInFinderDisabledOnceFolderIsGone`.

- [ ] **Step 2: 실패를 확인한다** — `xcodegen generate && xcodebuild test … -only-testing:termy-tests/ImagePreviewWindowControllerTests` → 컴파일 실패(타입 없음).

- [ ] **Step 3: `ImagePreviewView.swift`를 만든다** — `final class ImagePreviewScrollView: NSScrollView`(`var onWillOpenMenu: ((NSMenu) -> Void)?`, `menu(for:)` override), `final class CenteringClipView: NSClipView`(`constrainBoundsRect(_:)`에서 document가 더 작은 축을 가운데로).

- [ ] **Step 4: `ImagePreviewWindowController.swift`를 만든다** — 위 "동작"대로. 더블클릭은 `scrollView`에 붙인 `NSClickGestureRecognizer`(`numberOfClicksRequired = 2`) → `toggleFitOrActualSize()`. 창 크기 변경은 `windowDidResize(_:)`에서 `fitsWindow`일 때만 다시 맞춘다. 머리 주석은 PDF 파일처럼 "왜"를 적는다(덜 쓰인 파일, 끝 표시, 맞춤 규칙).

- [ ] **Step 5: 통과를 확인한다** — `… -only-testing:termy-tests/ImagePreviewWindowControllerTests -only-testing:termy-tests/PDFPreviewWindowControllerTests` → `** TEST SUCCEEDED **`.

- [ ] **Step 6: 커밋한다** — `git add apps/termy/Sources/ImagePreviewWindowController.swift apps/termy/Sources/ImagePreviewView.swift apps/termy-tests/Sources/ImagePreviewWindowControllerTests.swift && git commit -m "feat(preview): 이미지 미리보기 창을 더한다"`

---

### Task 2: 이미지 경로를 미리보기로 연결

**Files:**
- Modify: `apps/termy/Sources/PreviewLinkResolver.swift` (`PreviewKind`, `extensions`, `previewPath(from:)`의 잘라내기 정규식, 머리·doc 주석)
- Modify: `apps/termy/Sources/PreviewManager.swift` (`open(_:)`의 switch, 주석)
- Modify (주석만, "markdown or PDF" → "markdown, PDF or image"류): `PreviewWindowSupport.swift`, `TermyTerminalView.swift`, `Pane.swift`, `MarkdownPreviewWebView.swift`, `AppDelegate.swift`, `PDFPreviewWindowController.swift`(`linkRoute` doc)
- Test: `apps/termy-tests/Sources/PreviewLinkResolverTests.swift`, `PreviewManagerTests.swift`, `AppDelegatePreviewMenuTests.swift`, 그리고 `TermyTerminalViewTests.swift`·`MarkdownPreviewWebViewTests.swift`에 markdown/PDF용 같은 모양의 테스트가 있으면 이미지 경우를 하나씩.

**Interfaces:**
- Consumes: Task 1의 `ImagePreviewWindowController(fileURL:defaults:)`, `showInFinder(_:)`.
- Produces: `PreviewKind.image`, `static let imageExtensions: Set<String>`(on `PreviewKind`, Global Constraints의 12개), `PreviewLinkResolver.extensions == ["md", "markdown", "pdf"] ∪ PreviewKind.imageExtensions`.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```swift
// PreviewLinkResolverTests
func test_imagePathsResolve() {
    let existing: Set<String> = ["/proj/shots/a.png", "/proj/a.jpeg", "/proj/a.webp", "/proj/a.svg", "/proj/b.PNG"]
    XCTAssertEqual(resolve("shots/a.png", existing: existing), .file(file("/proj/shots/a.png")))
    XCTAssertEqual(resolve("`a.jpeg`", existing: existing), .file(file("/proj/a.jpeg")))
    XCTAssertEqual(resolve("file:///proj/a.webp", existing: existing), .file(file("/proj/a.webp")))
    XCTAssertEqual(resolve("a.svg에 저장했습니다.", existing: existing), .file(file("/proj/a.svg")))
    XCTAssertEqual(resolve("./b.PNG:3", existing: existing), .file(file("/proj/b.PNG")))
    XCTAssertEqual(resolve("https://example.com/a.png", existing: existing), .notPreviewable)
    XCTAssertEqual(resolve("a.png.bak", existing: existing), .notPreviewable)
    XCTAssertEqual(resolve("a.pngx", existing: existing), .notPreviewable)
    XCTAssertEqual(resolve("shots/none.gif", existing: existing), .missing)
}

func test_previewKindForImages() {
    for name in ["a.png", "a.JPG", "a.jpeg", "a.gif", "a.webp", "a.heic", "a.heif", "a.avif", "a.tif", "a.tiff", "a.bmp", "a.svg"] {
        XCTAssertEqual(PreviewKind(fileURL: URL(fileURLWithPath: "/x/" + name)), .image, name)
    }
    XCTAssertNil(PreviewKind(fileURL: URL(fileURLWithPath: "/x/a.txt")))
}
```

(`resolve`/`file` helper와 base directory `/proj`는 이 파일의 기존 helper를 쓴다. 이름이 다르면 맞춘다.)

- `PreviewManagerTests.test_openingImageMakesImagePreview`: PNG 파일(`NSBitmapImageRep`로 만든다) → `manager.open(url) is ImagePreviewWindowController`, 두 번 열면 같은 controller, `controllers.count == 1`.
- `AppDelegatePreviewMenuTests.test_fileMenuShowInFinderReachesImagePreview`: PDF 테스트와 같은 모양으로 `ImagePreviewWindowController.instancesRespond(to: action)`.
- `TermyTerminalViewTests`/`MarkdownPreviewWebViewTests`: 기존 markdown·PDF 경우와 같은 모양으로 `.png` 경우(있을 때만).

- [ ] **Step 2: 실패를 확인한다** — `xcodebuild test … -only-testing:termy-tests/PreviewLinkResolverTests -only-testing:termy-tests/PreviewManagerTests -only-testing:termy-tests/AppDelegatePreviewMenuTests` → `.image` 없음으로 컴파일 실패.

- [ ] **Step 3: 구현한다**
  - `PreviewKind`에 `case image`와 `imageExtensions`, `init?(fileURL:)`이 그 집합이면 `.image`.
  - `PreviewLinkResolver.extensions`를 위 합집합으로. `previewPath(from:)`의 정규식은 `extensions`에서 만든다(확장자 순서는 상관없다: 뒤의 `(?![A-Za-z0-9._/-])`가 `jpg`/`jpeg`, `tif`/`tiff`를 가른다). 패턴: `^.*?\.(` + 확장자들을 `|`로 이은 것 + `)(?![A-Za-z0-9._/-])`, `.caseInsensitive`.
  - `PreviewManager.open(_:)`: `case .image: controller = ImagePreviewWindowController(fileURL: fileURL, defaults: defaults)`.
  - 주석 정리(Files의 목록).

- [ ] **Step 4: 통과를 확인한다** — Step 2의 클래스들에 `TermyTerminalViewTests`, `MarkdownPreviewWebViewTests`, `ImagePreviewWindowControllerTests`, `PDFPreviewWindowControllerTests`, `MarkdownPreviewWindowControllerTests`를 더해 실행 → `** TEST SUCCEEDED **`. 이어 전체 suite 한 번.

- [ ] **Step 5: 커밋한다** — `git commit -am "feat(preview): 이미지 파일 경로도 Cmd+클릭으로 미리보기한다"`

---

## 끝난 뒤 (controller)

- 전체 테스트를 다시 돌린다.
- live 확인은 사용자가 한다(이 세션은 termy 안에서 돌아 termy를 다시 띄울 수 없다): Debug build에서 png·jpg·gif(움직이는 것)·svg 경로를 Cmd+클릭, 큰 스크린샷은 창에 맞고 작은 아이콘은 100%로 가운데, pinch 확대·더블클릭 전환, 에이전트가 같은 파일을 다시 쓰면 새 그림으로 바뀌는지.

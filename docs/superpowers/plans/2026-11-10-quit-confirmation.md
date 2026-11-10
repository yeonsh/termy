# ⌘Q 종료 확인 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘Q로 앱을 끝낼 때 확인 대화상자를 띄우고, ⌘, 패널에서 그 확인을 끌 수 있게 한다(기본 켜짐).

**Architecture:** 판단은 순수 함수 `QuitConfirmation.shouldAsk(_:)`로 떼어 테스트하고, `applicationShouldTerminate`가 그 함수를 보고 `NSAlert`를 동기로 띄운다. 업데이트 재시작·로그아웃/시스템 종료·마지막 창 닫기는 `AppLifecycle`의 플래그/창 가시성으로 걸러 낸다.

**Tech Stack:** Swift 6, AppKit(Xcode 26 툴체인), XCTest, `UserDefaults`.

**Spec:** `docs/superpowers/specs/2026-11-10-quit-confirmation-design.md`

## Global Constraints

- Swift 6 동시성: `AppDelegate`·`AppLifecycle`은 `@MainActor`. 새 전역 상태는 `AppLifecycle`의 `@MainActor static var`로만 둔다.
- 설정 키는 `termy.quit.askBeforeQuit`, 기본값 **true**.
- 대화상자 문구는 스펙 그대로: 제목 `Quit termy?`, 본문 `Programs running in panes will be stopped.`, 버튼 `Cancel`(첫째·Return) / `Quit`.
- 사용자에게 보이는 문자열은 영어 하드코딩(이 앱의 기존 관례). 주석은 기존 코드처럼 영어/한국어 혼용 허용.
- 테스트 실행: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25`

## Review Focus

- **설정을 끈 사용자가 업데이트 재시작을 할 때**: 대화상자가 뜨면 안 되고, 뜨면 Sparkle 재시작이 멈춘다. `prepareForUpdateRelaunch`가 플래그를 켜는지 태스크 2의 테스트로 고정한다.
- **로그아웃 중 모달**: 시스템 종료 요청에 모달이 뜨면 로그아웃이 붙잡힌다. `willPowerOffNotification` 경로 테스트로 고정한다.
- **Cancel을 눌렀는데 앱이 끝나는 경우**: 확인 창의 두 번째가 아닌 응답은 모두 취소로 처리해야 한다(Esc·창 닫기 포함).
- **마지막 창을 닫은 직후 모달**: 창이 없는데 "Quit termy?"가 뜨면 안 된다.
- **확인 중 pane 출력 정지**: `runModal` 동안 PTY 드레인이 멈추는 것은 종료 직전 한 번이라 허용. 다른 경로(특히 GCD 블록 안)에 모달을 넣지 않는다.

---

### Task 1: 설정 값과 판단 함수

**Files:**
- Create: `apps/termy/Sources/QuitConfirmation.swift`
- Modify: `apps/termy/Sources/AppLifecycle.swift` (파일 끝, `enum AppLifecycle` 바깥)
- Test: `apps/termy-tests/Sources/QuitConfirmationTests.swift`

**Interfaces:**
- Produces:
  - `enum QuitSettings { static let askBeforeQuitKey: String; static func askBeforeQuit(_ defaults: UserDefaults) -> Bool; static func setAskBeforeQuit(_ enabled: Bool, _ defaults: UserDefaults) }`
  - `enum QuitConfirmation { struct Context { var isRunningUnderXCTest: Bool; var isRelaunchingForUpdate: Bool; var isPoweringOff: Bool; var hasVisibleMainWindow: Bool; var askBeforeQuit: Bool }; static func shouldAsk(_ context: Context) -> Bool }`
- 두 타입 모두 `QuitConfirmation.swift`에 두고 `QuitSettings`는 `AppLifecycle.swift`에 둔다(스펙 5.4).

- [ ] **Step 1: Write the failing test**

`apps/termy-tests/Sources/QuitConfirmationTests.swift`:

```swift
import XCTest
@testable import termy

final class QuitConfirmationTests: XCTestCase {
    private func context(
        xctest: Bool = false,
        relaunch: Bool = false,
        powerOff: Bool = false,
        visibleWindow: Bool = true,
        ask: Bool = true
    ) -> QuitConfirmation.Context {
        QuitConfirmation.Context(
            isRunningUnderXCTest: xctest,
            isRelaunchingForUpdate: relaunch,
            isPoweringOff: powerOff,
            hasVisibleMainWindow: visibleWindow,
            askBeforeQuit: ask
        )
    }

    func test_plainQuit_asks() {
        XCTAssertTrue(QuitConfirmation.shouldAsk(context()))
    }

    // protects=설정을 끈 사용자; fails_when=끈 뒤에도 대화상자가 뜬다
    func test_settingOff_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(ask: false)))
    }

    // protects=Sparkle 재시작; fails_when=업데이트 재시작이 모달에 멈춘다
    func test_updateRelaunch_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(relaunch: true)))
    }

    // protects=로그아웃/시스템 종료; fails_when=모달이 로그아웃을 붙잡는다
    func test_powerOff_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(powerOff: true)))
    }

    // protects=마지막 창을 닫은 직후; fails_when=창이 없는데 묻는다
    func test_noVisibleWindow_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(visibleWindow: false)))
    }

    func test_xctestHost_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(xctest: true)))
    }

    func test_askBeforeQuitDefaultsToTrue() {
        let defaults = InMemoryUserDefaults()
        XCTAssertTrue(QuitSettings.askBeforeQuit(defaults))
    }

    func test_askBeforeQuitRoundTrips() {
        let defaults = InMemoryUserDefaults()
        QuitSettings.setAskBeforeQuit(false, defaults)
        XCTAssertFalse(QuitSettings.askBeforeQuit(defaults))
        QuitSettings.setAskBeforeQuit(true, defaults)
        XCTAssertTrue(QuitSettings.askBeforeQuit(defaults))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate` 먼저(새 소스 파일), 그다음 위 테스트 명령에 `-only-testing:termy-tests/QuitConfirmationTests`.
Expected: 컴파일 실패 — `cannot find 'QuitConfirmation' in scope`.

- [ ] **Step 3: Implement `QuitSettings` and `QuitConfirmation.shouldAsk`**

`AppLifecycle.swift` 끝에 (import는 `AppKit`이 아니라 `Foundation` 유지 — `UserDefaults`는 Foundation):

```swift
/// ⌘Q 확인 대화상자를 띄울지. 기본은 켜짐 — pane에서 돌던 작업은 복원되지 않는다.
enum QuitSettings {
    static let askBeforeQuitKey = "termy.quit.askBeforeQuit"

    static func askBeforeQuit(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: askBeforeQuitKey) as? Bool ?? true
    }

    static func setAskBeforeQuit(_ enabled: Bool, _ defaults: UserDefaults) {
        defaults.set(enabled, forKey: askBeforeQuitKey)
    }
}
```

`QuitConfirmation.swift`:

```swift
// QuitConfirmation.swift
//
// "Quit termy?" 판단. 모든 종료 요청(⌘Q, Dock Quit, AppleScript quit)이
// applicationShouldTerminate를 지나므로 여기서 한 번만 거른다. 업데이트 재시작·
// 로그아웃·마지막 창 닫기는 사용자의 ⌘Q가 아니고, 그 자리에서 모달이 뜨면
// Sparkle 재시작이나 로그아웃이 붙잡힌다.

import AppKit

enum QuitConfirmation {
    struct Context {
        var isRunningUnderXCTest = false
        var isRelaunchingForUpdate = false
        var isPoweringOff = false
        var hasVisibleMainWindow = true
        var askBeforeQuit = true
    }

    static func shouldAsk(_ context: Context) -> Bool
}
```

`shouldAsk`는 다섯 조건 중 하나라도 걸리면 `false`, 아니면 `true`.

- [ ] **Step 4: Run test to verify it passes**

Run: 위 테스트 명령 `-only-testing:termy-tests/QuitConfirmationTests`.
Expected: `** TEST SUCCEEDED **`, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/QuitConfirmation.swift apps/termy/Sources/AppLifecycle.swift apps/termy-tests/Sources/QuitConfirmationTests.swift
git commit -m "feat(quit): ⌘Q 종료 확인 여부를 정하는 판단 함수를 더한다"
```

---

### Task 2: 종료 훅에 확인 붙이기

**Files:**
- Modify: `apps/termy/Sources/AppLifecycle.swift` (플래그 두 개)
- Modify: `apps/termy/Sources/WindowManager.swift:111` (`prepareForUpdateRelaunch`)
- Modify: `apps/termy/Sources/AppDelegate.swift:118` (`applicationShouldTerminate`) 및 `applicationDidFinishLaunching`(관찰 등록)
- Modify: `apps/termy/Sources/QuitConfirmation.swift` (`presentAlert`, `checking(_ windowManager:)` 헬퍼)
- Test: `apps/termy-tests/Sources/QuitConfirmationTests.swift` (기존 파일에 추가)

**Interfaces:**
- Consumes: Task 1의 `QuitConfirmation.shouldAsk(_:)`, `QuitSettings.askBeforeQuit(_:)`.
- Produces: `AppLifecycle.isRelaunchingForUpdate: Bool`, `AppLifecycle.isPoweringOff: Bool` (`@MainActor static var`), 둘 다 읽기/쓰기 가능해야 함(테스트가 리셋한다).
- Produces: `QuitConfirmation.presentAlert() -> Bool` (Quit이면 true), `QuitConfirmation.responseQuits(_ response: NSApplication.ModalResponse) -> Bool` (순수, `.alertSecondButtonReturn`만 true), `QuitConfirmation.observePowerOff(center: NotificationCenter)` (관찰 등록만; 테스트가 직접 `post`한다).

- [ ] **Step 1: Write the failing test**

`QuitConfirmationTests.swift`에 추가:

```swift
    // protects=Cancel/Esc/창 닫기; fails_when=두 번째 버튼이 아닌 응답이 종료로 처리된다
    func test_onlySecondButtonQuits() {
        XCTAssertTrue(QuitConfirmation.responseQuits(.alertSecondButtonReturn))
        XCTAssertFalse(QuitConfirmation.responseQuits(.alertFirstButtonReturn))
        XCTAssertFalse(QuitConfirmation.responseQuits(.abort))
        XCTAssertFalse(QuitConfirmation.responseQuits(.stop))
    }

    // protects=로그아웃/시스템 종료; fails_when=willPowerOff 알림이 플래그를 켜지 않는다
    func test_powerOffNotification_setsFlag() {
        AppLifecycle.isPoweringOff = false
        let center = NotificationCenter()
        QuitConfirmation.observePowerOff(center: center)
        center.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        XCTAssertTrue(AppLifecycle.isPoweringOff)
        AppLifecycle.isPoweringOff = false
    }

    // protects=업데이트 재시작; fails_when=prepareForUpdateRelaunch가 플래그를 켜지 않는다
    func test_prepareForUpdateRelaunch_setsFlag() {
        AppLifecycle.isRelaunchingForUpdate = false
        // WindowManager.init은 창을 만들지 않는다.
        let manager = WindowManager()
        manager.prepareForUpdateRelaunch()
        XCTAssertTrue(AppLifecycle.isRelaunchingForUpdate)
        AppLifecycle.isRelaunchingForUpdate = false
    }
```

(`AppLifecycle` 조작은 `@MainActor`이므로 테스트 클래스/메서드를 `@MainActor`로 둔다.)

- [ ] **Step 2: Run test to verify it fails**

Run: 테스트 명령 `-only-testing:termy-tests/QuitConfirmationTests`.
Expected: 컴파일 실패 — `no member 'responseQuits'` / `no member 'isRelaunchingForUpdate'`.

- [ ] **Step 3: Implement the flags, alert, and hook**

`AppLifecycle.swift`의 `enum AppLifecycle` 안에:

```swift
    /// Sparkle이 업데이트를 설치하려 앱을 다시 띄우는 중. ⌘Q 확인을 건너뛴다.
    @MainActor static var isRelaunchingForUpdate = false

    /// 사용자가 로그아웃/시스템 종료를 요청했다(`willPowerOffNotification`).
    /// 그 뒤에 오는 종료 요청에 모달을 띄우면 로그아웃이 붙잡힌다.
    @MainActor static var isPoweringOff = false
```

`WindowManager.prepareForUpdateRelaunch()` 첫 줄에 `AppLifecycle.isRelaunchingForUpdate = true`.

`QuitConfirmation.swift`에:

```swift
    /// Alert의 응답 중 앱을 끝내는 것은 두 번째 버튼(Quit)뿐.
    static func responseQuits(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }

    /// 로그아웃/시스템 종료 요청을 관찰한다. AppKit이 종료 요청보다 먼저 보낸다.
    @MainActor static func observePowerOff(center: NotificationCenter) {
        center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLifecycle.isPoweringOff = true }
        }
    }

    /// 확인 창을 띄운다. Quit이면 true.
    @MainActor static func presentAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit termy?"
        alert.informativeText = "Programs running in panes will be stopped."
        alert.addButton(withTitle: "Cancel")   // 첫 버튼 = Return
        alert.addButton(withTitle: "Quit")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalentModifierMask = []
        alert.buttons[0].keyEquivalent = "\u{1b}" // Esc도 Cancel
        return responseQuits(alert.runModal())
    }

    /// applicationShouldTerminate가 채우는 컨텍스트.
    @MainActor static func context(
        windowManager: WindowManager,
        defaults: UserDefaults = .standard
    ) -> Context {
        Context(
            isRunningUnderXCTest: TestHostDetector.isRunningUnderXCTest(),
            isRelaunchingForUpdate: AppLifecycle.isRelaunchingForUpdate,
            isPoweringOff: AppLifecycle.isPoweringOff,
            hasVisibleMainWindow: windowManager.controllers.contains { $0.window?.isVisible == true },
            askBeforeQuit: QuitSettings.askBeforeQuit(defaults)
        )
    }
```

(버튼 `keyEquivalent`는 `"\r"`/`"\u{1b}"` 하나만 유효하다 — 두 줄 중 실제로 동작하는 쪽만 남기고 주석으로 의도를 적는다. Esc는 NSAlert가 첫 버튼에 자동 매핑하지 않으므로 명시한다.)

`AppDelegate`:

```swift
    /// ⌘Q, Sparkle 업데이트 재시작, 로그아웃, 마지막 창 닫기 모두 여기를 지난다. ...(기존 주석 유지)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let context = QuitConfirmation.context(windowManager: windowManager)
        guard QuitConfirmation.shouldAsk(context) else {
            AppLifecycle.isTerminating = true
            return .terminateNow
        }
        guard QuitConfirmation.presentAlert() else { return .terminateCancel }
        AppLifecycle.isTerminating = true
        return .terminateNow
    }
```

`applicationDidFinishLaunching`에서 `installMenuBar()` 다음, XCTest 조기 반환 **앞**에 한 줄:

```swift
        QuitConfirmation.observePowerOff(center: NSWorkspace.shared.notificationCenter)
```

- [ ] **Step 4: Run test to verify it passes**

Run: 테스트 명령 `-only-testing:termy-tests/QuitConfirmationTests`.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Manual check** (모달이라 자동 테스트 불가)

`xcodebuild -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-build build` → 앱 실행 → ⌘Q: Cancel/Esc/Return 취소, Quit만 종료. 앱을 다시 띄워 설정을 끈 뒤(태스크 3 이후) ⌘Q 즉시 종료, 업데이트 재시작(`Debug ▸ Simulate Update Relaunch`)에는 대화상자가 없음을 확인.

- [ ] **Step 6: Commit**

```bash
git add -A apps/termy/Sources apps/termy-tests/Sources
git commit -m "feat(quit): ⌘Q에 종료 확인 대화상자를 붙인다"
```

---

### Task 3: 설정 체크박스와 문서

**Files:**
- Modify: `apps/termy/Sources/FontSettingsPanel.swift` (Alerts 아래 `Quitting` 섹션, 높이 432 → 488)
- Modify: `CHANGELOG.md` (Unreleased)
- Modify: `README.md:329` (⌘, 행 문구)
- Test: `apps/termy-tests/Sources/QuitConfirmationTests.swift`는 이미 설정 왕복을 덮는다(추가 없음).

**Interfaces:**
- Consumes: `QuitSettings.askBeforeQuit(_:)`, `QuitSettings.setAskBeforeQuit(_:_:)` (Task 1).

- [ ] **Step 1: 패널에 체크박스 추가**

`soundCheckbox` 옆에 `quitCheckbox` 필드, `alertsStack` 아래에 `quittingStack`:

```swift
        let quittingHeader = NSTextField(labelWithString: "Quitting")
        // 폰트/색은 alertsHeader와 같은 방식
        quitCheckbox = NSButton(
            checkboxWithTitle: "Ask before quitting",
            target: self,
            action: #selector(quitCheckboxChanged(_:))
        )
```

제약: `quittingStack.topAnchor == alertsStack.bottomAnchor + 16`, `hcStack.topAnchor == quittingStack.bottomAnchor + 16`.
`syncFromPreference()`에서 `quitCheckbox.state = QuitSettings.askBeforeQuit(.standard) ? .on : .off`.
`@objc private func quitCheckboxChanged(_ sender: NSButton) { QuitSettings.setAskBeforeQuit(sender.state == .on, .standard) }`.
패널 `contentRect` 높이 432 → 488.

- [ ] **Step 2: 빌드**

Run: `xcodegen generate && xcodebuild -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 문서**

`CHANGELOG.md` Unreleased:

```markdown
- ⌘Q now asks before it quits, since programs running in panes are stopped
  and not restored. Settings… (⌘,) has a new **Quitting** section with
  "Ask before quitting" (on by default) for turning the prompt off.
```

`README.md`의 `| <kbd>⌘</kbd><kbd>,</kbd> | Terminal font settings |` → `| <kbd>⌘</kbd><kbd>,</kbd> | Settings — font, alerts, quitting |`

- [ ] **Step 4: 전체 테스트**

Run: `xcodebuild test ... -skipPackagePluginValidation 2>&1 | tail -25` (only-testing 없이)
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/FontSettingsPanel.swift CHANGELOG.md README.md docs/superpowers
git commit -m "feat(quit): 설정에서 ⌘Q 확인을 끌 수 있다"
```

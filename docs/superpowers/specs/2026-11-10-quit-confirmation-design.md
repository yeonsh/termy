# ⌘Q 종료 확인 — 설계 문서

- 날짜: 2026-11-10
- 상태: 승인됨
- 범위: ⌘Q로 앱을 끝낼 때 확인 대화상자를 띄우고, 그 확인을 끄는 설정을 ⌘, 패널에 더한다. 기본값은 켜짐.
- 선행 문서: `docs/superpowers/specs/2026-05-18-multi-window-design.md`(창·세션 구조),
  `docs/superpowers/plans/2026-04-22-auto-update.md`(업데이트 재시작 경로)

## 1. 목표와 동기

지금은 ⌘Q가 곧바로 앱을 끝낸다. pane에서 돌던 셸과 그 자식 프로세스는 그 순간 사라지고, 되돌릴 방법이 없다.
(창·pane 배치는 `session.json`에서 복원되지만, 돌던 작업은 복원되지 않는다.) 손가락이 ⌘Q에 닿아 작업이
날아가는 것을 막는 것이 목표다.

성공 기준:

- ⌘Q → "Quit termy?" 확인 대화상자. Cancel(기본)이나 Esc면 아무것도 끝나지 않고 pane은 그대로 돈다.
- Quit을 고르면 지금과 똑같이 끝난다: 세션 autosave flush, hook daemon 정지, hc kill 대기, 로컬 프로세스 teardown.
- 업데이트 재시작(Sparkle), 로그아웃/시스템 종료, 마지막 창 닫기로 앱이 끝나는 길에는 대화상자가 끼어들지 않는다.
- ⌘, 패널에서 끄면 ⌘Q가 예전처럼 즉시 끝난다. 설정은 `UserDefaults`에 남는다.

## 2. 비목표

- pane 수·에이전트 수·mid-turn 여부에 따라 문구를 바꾸지 않는다. 업데이트 재시작은 이미
  `UpdateRelaunchGate`가 mid-turn을 붙잡고 묻는다.
- "종료 전에 실행 중인 프로세스를 보여 주는" 목록 창.
- 창 하나를 닫을 때(⌘W, ⌘⇧W)의 확인. 창·pane을 닫는 동작은 이번 범위 밖이다.

## 3. 지금 동작 (근거)

- ⌘Q 메뉴 항목은 `#selector(NSApplication.terminate(_:))` (`AppDelegate.swift:526`).
- `applicationShouldTerminate` (`AppDelegate.swift:118`)가 `AppLifecycle.isTerminating = true`만 켜고
  `.terminateNow`를 돌려준다.
- 같은 훅을 업데이트 재시작(`Updater.onWillRelaunch` → `prepareForUpdateRelaunch` → `NSApp.terminate`),
  로그아웃/시스템 종료, 마지막 창 닫기(`applicationShouldTerminateAfterLastWindowClosed == true`)도 지난다.
  그래서 확인을 무조건 넣으면 그 세 길에도 모달이 뜬다.
- 설정 UI 패턴은 `AlertSettings`(`Notifier.swift`) + `FontSettingsPanel` 체크박스가 이미 있다(커밋 `251dbee`).

## 4. 검토한 방법

1. **메뉴 항목을 자체 액션으로 바꿔 거기서 묻는다.** ⌘Q는 잡히지만 Dock의 Quit, AppleScript `quit`,
   시스템 종료 요청은 그대로 빠져나간다. 확인이 필요한 순간이 정확히 그 경로들이라 반쪽이 된다.
2. **`applicationShouldTerminate` 안에서 묻는다 (선택).** 모든 종료 요청이 한 곳을 지나므로 ⌘Q·Dock Quit·
   AppleScript가 모두 덮인다. 대신 업데이트 재시작·로그아웃·마지막 창 닫기를 플래그로 걸러야 한다.
3. **`applicationShouldTerminate`에서 `.terminateLater` + 비동기 시트.** 취소 가능하지만 종료 절차를
   비동기로 늘리는 값비싼 변경이다. 동기 모달로 충분한 곳에 쓰지 않는다.

2번을 고른다. 걸러 낼 경로가 네 개뿐이고, 그중 셋은 이미 "이건 사용자의 ⌘Q가 아니다"를 아는 지점이 있다.

## 5. 설계

### 5.1 판단을 고르는 순수 함수

`QuitConfirmation` (신규 `apps/termy/Sources/QuitConfirmation.swift`):

```swift
enum QuitConfirmation {
    struct Context {          // applicationShouldTerminate에서 채운다
        var isRunningUnderXCTest: Bool
        var isRelaunchingForUpdate: Bool
        var isPoweringOff: Bool
        var hasVisibleMainWindow: Bool
        var askBeforeQuit: Bool
    }
    static func shouldAsk(_ context: Context) -> Bool
}
```

`shouldAsk`는 위 조건 중 하나라도 해당하면 false. 테스트가 붙는 곳이 이 함수다.

### 5.2 종료 훅

`AppDelegate.applicationShouldTerminate`:

```swift
AppLifecycle.isTerminating = true
guard QuitConfirmation.shouldAsk(...) else { return .terminateNow }
return QuitConfirmation.presentAlert() ? .terminateNow : .terminateCancel
```

`presentAlert()`는 `NSAlert` + `runModal`:

```
┌─────────────────────────────────────────┐
│ Quit termy?                             │
│ Programs running in panes will be       │
│ stopped.                                │
│                     [Cancel]   [Quit]   │
└─────────────────────────────────────────┘
```

Cancel이 첫 버튼(Return)이고 Esc도 Cancel(`keyEquivalent = "\x1b"`). Quit은 `alertSecondButtonReturn`일 때만.
`isTerminating`은 확인을 받기 전에 이미 켜 두는데, 확인 중에는 teardown이 없으므로 무해하고, 취소하면
끝나지 않으므로 값이 남아도 다음 종료 시도에서 다시 켜진다. (취소 시 되돌리는 편이 더 깔끔하니 되돌린다.)

### 5.3 걸러 내는 플래그

- **업데이트 재시작**: `AppLifecycle.isRelaunchingForUpdate` — `WindowManager.prepareForUpdateRelaunch()`에서
  켠다. Sparkle 경로와 DEBUG의 `simulateUpdateRelaunch`가 모두 이 메서드를 지난다.
- **로그아웃/시스템 종료**: `AppLifecycle.isPoweringOff` — `AppDelegate.applicationDidFinishLaunching`에서
  `NSWorkspace.shared.notificationCenter`의 `NSWorkspace.willPowerOffNotification`을 관찰해 켠다.
  AppKit이 종료 요청보다 먼저 보내는 알림이라, 모달이 로그아웃을 붙잡는 일이 없다.
- **마지막 창 닫기**: `windowManager.controllers` 중 `window.isVisible`인 것이 없으면 묻지 않는다.
  이 시점엔 pane이 이미 정리돼서 잃을 것이 없고, 닫힌 창 뒤에 모달이 뜨는 그림도 이상하다.
- **테스트 호스트**: `TestHostDetector.isRunningUnderXCTest()`.
- **설정 꺼짐**: `QuitSettings.askBeforeQuit`.

### 5.4 설정

`AppLifecycle.swift`에 `enum QuitSettings`:

```swift
static let askBeforeQuitKey = "termy.quit.askBeforeQuit"
static func askBeforeQuit(_ defaults: UserDefaults) -> Bool      // 기본 true
static func setAskBeforeQuit(_ enabled: Bool, _ defaults: UserDefaults)
```

⌘, 패널(`FontSettingsPanel`)에 `Quitting` 섹션 + 체크박스 "Ask before quitting"를 Alerts 섹션 아래에 둔다.
패널 높이 432 → 488. `Restore Defaults`는 지금도 폰트 설정만 되돌리므로(알림 소리도 건드리지 않는다)
이 체크박스도 건드리지 않는다 — 기존 동작과 맞춘다.

### 5.5 문서

- `CHANGELOG.md` Unreleased 항목.
- `README.md` 단축키 표의 ⌘, 행 문구를 "Settings — font, alerts, quitting"로 넓힌다.

## 6. 남는 판단 (구현자 몫)

- 테스트 파일 이름·클래스 이름은 기존 규칙(`<Type>Tests`)을 따르되 자유.
- 대화상자 문구는 위 문장 그대로 쓴다. 다국어 리소스는 이 앱에 없다(전 UI가 영어 문자열 하드코딩).

# 본 뒤에 사라지는 WAIT · Esc/Ctrl-C 중단 감지 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) 턴이 끝나 생긴 WAIT는 사용자가 그 pane을 본 뒤에만 30초 후 IDLE로 바뀐다. (2) 7501 같은 중단 신호가 없는 agent에서 사용자가 단독 Esc/Ctrl-C를 누르면 열린 턴을 조용히 IDLE로 닫는다.

**Architecture:** (1) `HookDaemon`이 "지금 보고 있는 pane" id를 받아 `PaneSnapshot.seenAt`에 찍고, `tickIdle`은 본 시각부터 30초를 센다. 보고 있는 pane은 main actor의 `ViewedPaneTracker`가 앱 활성·key window·focus 변화를 보고 계산해 넘긴다. (2) 순수 함수 `InterruptKey.isStandaloneInterrupt(_:)`가 `TermyTerminalView.send(source:data:)`(local·hc 공통 입력 경로)에서 바이트를 보고, 맞으면 `HookDaemon.recordInterruptKey(paneId:)`가 상태를 바꾼다.

**Tech Stack:** Swift 6, AppKit, SwiftTerm(fork, kitty keyboard encoder), XCTest.

**Spec:** 별도 스펙 없음. 배경은 Paseo 분석(`docs/local/2026-11-12-paseo-analysis.md`, git 밖 로컬 파일)이고, 결정 사항은 아래 "설계 결정"에 모두 옮겼다.

## 설계 결정

- **본 것(seen)의 정의:** 앱이 활성이고, key window가 `MainWindowController`이고, 그 창의 focused pane인 경우. 보이기만 하는 그리드의 다른 pane, 비활성 창의 focused pane, Markdown/PDF 미리보기 창이 key일 때는 본 것이 아니다.
- **seen 규칙:** 대상은 `needsAttention == false`인 `.waiting`(턴 종료 WAIT. permission·question처럼 attention이 있는 WAIT는 지금처럼 timer 대상이 아님).
  - 보고 있는 동안 WAIT가 되면 → 진입 시각부터 30초 뒤 IDLE (지금 동작과 같음).
  - 보지 않은 채 WAIT가 되면 → IDLE로 바뀌지 않는다. 칩·dock badge·⌘G 대상에 남는다.
  - 나중에 그 pane을 보면(또는 보다가 떠나면) → 그 시각부터 30초 뒤 IDLE.
  - 2분 넘게 tick이 없었던 경우(sleep/wake) 일괄 IDLE을 막는 기존 `since < 120` 가드는 유지한다.
- **중단 키:** 입력 덩어리 하나가 정확히 다음 중 하나일 때만. legacy `0x1b`, `0x03`. kitty CSI-u `ESC [ 27 u`(Esc), `ESC [ 99 ; 5 u`(Ctrl-C). lock 비트(caps 64, num 128)는 무시하고, event type은 press(생략 또는 `:1`)만 받는다.
- **중단 키를 적용하는 pane:** agent가 `.claude` / `.codex` / `.antigravity`이고, `programStatusActive == false`, `turnOpen == true`, 상태가 THINK로 보이는 것(`.thinking`, `.possiblyWaiting`) 또는 `.waiting(.promotedFromPossible)`. opencode(plugin이 interrupted를 보냄)와 pi(7501)는 제외한다.
- **중단 결과:** `.idle`, attention·reason·waitSource 초기화, `turnOpen = false`, `interruptedByKey = true`. 소리 없음(IDLE은 알림 대상이 아님).
- **잘못 감지했을 때 복구:** `interruptedByKey`인 IDLE pane에 PreToolUse가 오면 조용히 THINKING으로 돌린다. PostToolUse·PostToolUseFailure는 끊긴 도구가 뒤늦게 끝난 결과라 IDLE과 플래그를 유지한다(실기: Codex 0.160.1에서 Ctrl-C로 끊은 `sleep 30`이 백그라운드로 남아 30초 뒤 PostToolUse를 보냄). 그 상태에서 Stop이 오면(Codex가 중단에도 Stop을 보내는 경우 포함) IDLE을 유지하고 소리 내지 않는다. 다른 hook 이벤트는 `interruptedByKey`를 지운다.
- **범위 밖:** 백그라운드 작업 표시(hook은 시작만 주고 끝을 주지 않음), permission WAIT 중 Esc(동작 미확인), README 외 문서 개편.

## Global Constraints

- Swift 6 동시성: `HookDaemon`은 actor, `Workspace`·`MainWindowController`·새 `ViewedPaneTracker`는 main actor.
- 새 `PaneSnapshot` 필드(`seenAt`, `interruptedByKey`)는 runtime 전용. `CodingKeys`에 넣지 않는다(`programStatusActive`와 같은 방식).
- idle 임계값은 기존 `idleThreshold = 30`, 가드는 `since < 120` 그대로.
- 사용자에게 보이는 문자열은 영어(README 포함). 커밋 메시지는 한국어, `Co-Authored-By` 줄 없음.
- 테스트 실행: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25`
- 테스트에서 창을 화면에 올리거나 닫지 않는다(test host는 마지막 창이 닫히면 종료된다). 필요하면 `WorkspaceParkingTests`의 정적 창 패턴을 쓴다.

## Review Focus

- **보다가 30초 전에 다른 pane으로 옮김:** 떠난 시각부터 30초 뒤 IDLE이 되어야 한다. 영원히 WAIT로 남으면 안 된다. 태스크 1 `test_leavingViewedPane_startsCountdownFromLeave`.
- **화살표·Option+문자·붙여넣기·마우스 보고처럼 ESC로 시작하는 입력:** 중단으로 보면 안 된다. 태스크 3 negative 테스트.
- **7501이 살아 있는 Claude pane에서 Esc:** 7501 `idle`이 상태를 정하므로 키 감지는 아무것도 바꾸면 안 된다. 태스크 4 `test_interruptKey_ignoredWhileProgramStatusActive`.
- **에이전트가 없는 pane(INIT/IDLE)이나 permission WAIT에서 Esc(vim, 셸, 대화상자):** no-op. 태스크 4 `test_interruptKey_noopOutsideOpenThinkingTurn`.
- **두 창을 띄우고 뒤쪽 창의 focused pane이 끝남:** key window가 아니므로 WAIT 유지. 태스크 2 `resolve` 테스트.

---

### Task 1: HookDaemon의 seen 기반 WAIT → IDLE

**Files:**
- Modify: `apps/termy/Sources/PaneState.swift` (`PaneSnapshot`에 `seenAt`, 헤더 다이어그램의 `WAITING ──(30s wall-clock timer)──▶ IDLE` 줄을 `(30s after seen)`으로)
- Modify: `apps/termy/Sources/HookDaemon.swift` (`viewedPaneId`, `setViewedPane`, `tickIdle(now:)`; `idleLoop`의 호출부)
- Test: `apps/termy-tests/Sources/HookDaemonSeenTests.swift` (새 파일)

**Interfaces:**
- Produces:
  - `PaneSnapshot.seenAt: Date?` (기본 nil, runtime 전용)
  - `extension PaneSnapshot { func idleCountdownStart(isViewed: Bool) -> Date? }`: 보고 있으면 `max(enteredStateAt, seenAt ?? .distantPast)`, 아니면 `seenAt >= enteredStateAt`일 때 `seenAt`, 그 외 nil.
  - `HookDaemon.setViewedPane(_ paneId: String?, now: Date = Date())`: 이전 viewed pane과 새 viewed pane 둘 다(있으면) `seenAt = now`로 찍고 `viewedPaneId`를 바꾼다. yield하지 않는다(표시가 바뀌지 않음).
  - `HookDaemon.tickIdle(now: Date = Date())`: `private`·`async`를 벗긴 internal 동기 메서드(`tickPromotePossiblyWaiting`과 같은 꼴).

- [ ] **Step 1: Write the failing tests** (`HookDaemonSeenTests`, 기존 `injectSnapshot` 사용, 모두 `.waiting` + `needsAttention == false`인 `p1`)

```swift
func test_unseenTurnEndWait_staysWaiting() async      // enteredStateAt = t0, viewed nil, tickIdle(now: t0+60) → .waiting
func test_waitEnteredWhileViewed_idlesAfter30s() async // setViewedPane("p1", now: t0-10), entered t0; tick(t0+31) → .idle; tick(t0+29)는 .waiting
func test_viewingLater_startsCountdownFromView() async // entered t0, setViewedPane("p1", now: t0+100); tick(t0+125) → .waiting, tick(t0+131) → .idle
func test_leavingViewedPane_startsCountdownFromLeave() async // viewed before t0, entered t0, setViewedPane(nil, now: t0+5); tick(t0+36) → .idle
func test_attentionWait_neverIdles() async            // needsAttention = true, viewed → tick(t0+60) → .waiting (기존 규칙 유지)
func test_sleepWakeGuard_kept() async                 // viewed, entered t0, tick(t0+500) → .waiting
```

- [ ] **Step 2: Run** `-only-testing:termy-tests/HookDaemonSeenTests` → 컴파일 실패(`setViewedPane`, `tickIdle(now:)` 없음).

- [ ] **Step 3: Implement** `seenAt`, `idleCountdownStart(isViewed:)`, `setViewedPane`, `tickIdle(now:)`. `tickIdle`은 `since`를 `idleCountdownStart(isViewed: id == viewedPaneId)`부터 재고, nil이면 건너뛴다. 나머지(attention이면 건너뜀, `since > idleThreshold && since < 120`, IDLE 전환 시 yield)는 그대로.

- [ ] **Step 4: Run** `HookDaemonSeenTests`와 `HookDaemonPossiblyWaitingTests`, `PaneStateMachineTests` → PASS.

- [ ] **Step 5: Commit** `feat(state): 끝난 턴의 WAIT는 pane을 본 뒤에만 IDLE로 바뀐다`

### Task 2: 보고 있는 pane을 데몬에 알리기

**Files:**
- Create: `apps/termy/Sources/ViewedPaneTracker.swift`
- Modify: `apps/termy/Sources/Workspace.swift` (`focusedPane`에 `didSet`, 바뀌었을 때만 notification post)
- Modify: `apps/termy/Sources/MainWindowController.swift` (`var focusedPaneId: String?` 공개 accessor. `workspace`는 private 유지)
- Modify: `apps/termy/Sources/AppDelegate.swift` (`applicationDidFinishLaunching`에서 `HookDaemon.shared.start()` 뒤 `ViewedPaneTracker.shared.start()`)
- Modify: `README.md` (`WAIT` 설명에 끝났지만 아직 보지 않은 턴 추가)
- Test: `apps/termy-tests/Sources/ViewedPaneTrackerTests.swift`

**Interfaces:**
- Consumes: `HookDaemon.setViewedPane(_:now:)` (Task 1)
- Produces:
  - `extension Workspace { static let focusedPaneDidChangeNotification = Notification.Name("termy.workspaceFocusedPaneDidChange") }`
  - `@MainActor final class ViewedPaneTracker { static let shared; func start(); func refresh(); nonisolated static func resolve(isAppActive: Bool, keyWindowFocusedPaneId: String?) -> String? }`

- [ ] **Step 1: Write the failing tests**

```swift
func test_resolve_activeAppWithKeyMainWindow_returnsFocusedPane() // resolve(true, "p1") == "p1"
func test_resolve_inactiveApp_returnsNil()                         // resolve(false, "p1") == nil
func test_resolve_keyWindowIsNotMain_returnsNil()                  // resolve(true, nil) == nil
func test_workspaceFocus_postsFocusedPaneDidChange()               // 창 없이 Workspace()에 pane 둘을 만들고 focus(pane:) → expectation(forNotification:) 충족, 같은 pane 재focus는 post 안 함
```

Workspace는 `WorkspaceParkingTests`처럼 만든다: 화면에 올리지 않는 정적 `NSWindow`(`isReleasedWhenClosed = false`)의 contentView에 붙이고, pane은 `workspace.addPane(cwd:)` + 임시 디렉터리, tearDown에서 `closePane`·`removeFromSuperview`.

- [ ] **Step 2: Run** `-only-testing:termy-tests/ViewedPaneTrackerTests` → 컴파일 실패.

- [ ] **Step 3: Implement.**
  - `start()`: `NSApplication.didBecomeActiveNotification`, `didResignActiveNotification`, `NSWindow.didBecomeKeyNotification`, `didResignKeyNotification`, `Workspace.focusedPaneDidChangeNotification`를 구독해 `refresh()`를 부르고, 마지막에 한 번 `refresh()`.
  - `refresh()`: `resolve(isAppActive: NSApp.isActive, keyWindowFocusedPaneId: (NSApp.keyWindow?.windowController as? MainWindowController)?.focusedPaneId)`. 직전 값과 같으면 아무것도 안 함.
  - 값이 바뀌면 데몬 호출이 순서를 지키도록 직전 Task를 기다리는 사슬로 보낸다:

```swift
let previous = pending
pending = Task { await previous?.value; await HookDaemon.shared.setViewedPane(id) }
```

  - README: `` - **`WAIT`** — blocked on a permission prompt or a question, or finished a turn you haven't looked at yet. Your attention needed. `` 같은 꼴로 한 줄 수정.

- [ ] **Step 4: Run** `ViewedPaneTrackerTests` + 전체 `termy-tests` → PASS.

- [ ] **Step 5: Commit** `feat(state): 보고 있는 pane을 데몬에 알려 WAIT를 본 것으로 표시한다`

### Task 3: 중단 키 감지 함수

**Files:**
- Create: `apps/termy/Sources/InterruptKey.swift`
- Test: `apps/termy-tests/Sources/InterruptKeyTests.swift`

**Interfaces:**
- Produces: `enum InterruptKey { static func isStandaloneInterrupt(_ data: ArraySlice<UInt8>) -> Bool }`

- [ ] **Step 1: Write the failing tests** (`func b(_ s: String) -> ArraySlice<UInt8> { ArraySlice(Array(s.utf8)) }`)

```swift
// true
XCTAssertTrue(InterruptKey.isStandaloneInterrupt([0x1b]))
XCTAssertTrue(InterruptKey.isStandaloneInterrupt([0x03]))
XCTAssertTrue(InterruptKey.isStandaloneInterrupt(b("\u{1b}[27u")))
XCTAssertTrue(InterruptKey.isStandaloneInterrupt(b("\u{1b}[27;1u")))
XCTAssertTrue(InterruptKey.isStandaloneInterrupt(b("\u{1b}[27;1:1u")))
XCTAssertTrue(InterruptKey.isStandaloneInterrupt(b("\u{1b}[99;5u")))
XCTAssertTrue(InterruptKey.isStandaloneInterrupt(b("\u{1b}[99;69u")))   // ctrl + caps lock
// false
for s in ["\u{1b}[A", "\u{1b}b", "\u{1b}[200~", "\u{1b}[<0;10;5M", "\u{1b}[27;2u", "\u{1b}[27;1:3u",
          "\u{1b}[27;1:2u", "\u{1b}[99;7u", "\u{1b}[99u", "\u{1b}\u{1b}", "c", "\u{03}\u{03}", ""] {
    XCTAssertFalse(InterruptKey.isStandaloneInterrupt(b(s)), s.debugDescription)
}
```

- [ ] **Step 2: Run** `-only-testing:termy-tests/InterruptKeyTests` → 컴파일 실패.

- [ ] **Step 3: Implement.** legacy는 길이 1 비교. CSI-u는 `ESC [` 로 시작하고 `u`로 끝나는 덩어리 전체를 `<key>(:<alt>)*(;<mods>(:<event>)?)?`로 파싱한다. key 27이면 `(mods-1) & ~(64|128) == 0`, key 99면 `== 4`(ctrl). event는 없거나 1. 그 밖의 모양은 false.

- [ ] **Step 4: Run** `InterruptKeyTests` → PASS.

- [ ] **Step 5: Commit** `feat(state): 단독 Esc·Ctrl-C 입력을 알아보는 함수를 더한다`

### Task 4: 중단 키로 열린 턴 닫기

**Files:**
- Modify: `apps/termy/Sources/PaneState.swift` (`PaneSnapshot.interruptedByKey`, `applyHookRules`의 시작·`.stop`·`.preToolUse`·`.postToolUse`, `applyProgramStatus`, 헤더 다이어그램에 `THINKING ──(Esc/Ctrl-C key, no 7501)──▶ IDLE (silent)` 한 줄)
- Modify: `apps/termy/Sources/HookDaemon.swift` (`recordInterruptKey`)
- Modify: `apps/termy/Sources/TermyTerminalView.swift:83` (`send(source:data:)`)
- Test: `apps/termy-tests/Sources/HookDaemonInterruptKeyTests.swift` (새 파일), `apps/termy-tests/Sources/PaneStateMachineTests.swift` (추가)

**Interfaces:**
- Consumes: `InterruptKey.isStandaloneInterrupt(_:)` (Task 3)
- Produces:
  - `PaneSnapshot.interruptedByKey: Bool = false` (runtime 전용)
  - `HookDaemon.recordInterruptKey(paneId: String, now: Date = Date())`

- [ ] **Step 1: Write the failing tests**

`HookDaemonInterruptKeyTests` (codex pane, `.thinking`, `turnOpen = true`가 기본):

```swift
func test_interruptKey_closesOpenThinkingTurn() async        // → .idle, turnOpen false, interruptedByKey true, needsAttention false
func test_interruptKey_closesPossiblyWaitingAndPromotedWait() async // .possiblyWaiting, .waiting(.promotedFromPossible, attention) 둘 다 → .idle, attention false
func test_interruptKey_ignoredWhileProgramStatusActive() async // claude, programStatusActive = true → 변화 없음
func test_interruptKey_ignoredForOpencodeAndPi() async        // agentKind .opencode / .pi → 변화 없음
func test_interruptKey_noopOutsideOpenThinkingTurn() async     // .idle, .initializing, .waiting(permission, attention), turnOpen false인 .thinking → 변화 없음
```

`PaneStateMachineTests` (이전 snapshot: codex, `.idle`, `interruptedByKey = true`):

```swift
func test_toolEventAfterInterruptKey_returnsToThinking()   // PreToolUse(Bash) → .thinking, needsAttention false; PostToolUse도 같음
func test_stopAfterInterruptKey_staysIdleSilently()        // Stop → .idle, turnOpen false, enteredStateAt 그대로
func test_otherEventClearsInterruptedByKey()               // UserPromptSubmit → .thinking, interruptedByKey false
func test_toolEventOnPlainIdle_unchanged()                 // interruptedByKey false인 .idle + PreToolUse → .idle (기존 동작)
```

- [ ] **Step 2: Run** `-only-testing:termy-tests/HookDaemonInterruptKeyTests -only-testing:termy-tests/PaneStateMachineTests` → 실패.

- [ ] **Step 3: Implement.**
  - `recordInterruptKey`: "설계 결정"의 적용 조건을 만족할 때만 결과 상태로 바꾸고 yield. 아니면 아무것도 안 함(yield도 안 함).
  - `applyHookRules`: 처음에 `next.interruptedByKey = false`. `.stop`은 맨 앞에서 `previous.interruptedByKey && previous.state == .idle`이면 `lastAssistantMessage`·`turnOpen = false`만 반영하고 상태는 IDLE 유지. `.preToolUse`/`.postToolUse`는 기존 분기 뒤 마지막 `else if previous.interruptedByKey && previous.state == .idle`에서 `.thinking` + `enteredStateAt = updatedAt`.
  - `applyProgramStatus`: `next.interruptedByKey = false`.
  - `send(source:data:)`: 기존 분기 앞에서

```swift
if let id = paneId, InterruptKey.isStandaloneInterrupt(data) {
    Task { await HookDaemon.shared.recordInterruptKey(paneId: id) }
}
```

- [ ] **Step 4: Run** 위 두 클래스 + 전체 `termy-tests` → PASS.

- [ ] **Step 5: Commit** `feat(state): 7501이 없는 agent에서 Esc·Ctrl-C로 끊은 턴을 IDLE로 닫는다`

### Task 5: 실기 확인 (사용자)

에이전트 세션이 termy 안에서 돌면 termy를 다시 띄울 수 없다(`$TERM_PROGRAM` 확인). 이 태스크는 사용자가 Debug 빌드로 확인하거나, Ghostty 세션에서 `env -i …` 로 띄워 확인한다.

- [ ] **Step 1: seen WAIT.** 두 pane에서 Claude에게 짧은 작업을 시키고, 한 pane을 보는 동안 다른 pane이 끝나게 한다. 안 본 pane은 1분 넘게 WAIT(주황)·dock badge에 남고, 그 pane을 클릭하면 30초 뒤 IDLE이 된다. 보던 pane은 끝나고 30초 뒤 IDLE이 된다.
- [ ] **Step 2: 다른 앱으로 전환.** termy를 비활성으로 둔 채 턴이 끝나면 WAIT가 남는다.
- [ ] **Step 3: Codex Esc.** Codex에 긴 작업을 시키고 Esc → 칩이 바로 IDLE, 20초 뒤 소리가 나지 않는다. Ctrl-C도 같다. `~/Library/Application Support/termy/events.jsonl`에서 Esc 뒤 Stop이 왔는지 적어 둔다(복구 규칙 확인용).
- [ ] **Step 4: Claude Esc(7501 활성).** 기존처럼 IDLE이 되고 이중 전환이 없다.
- [ ] **Step 5: 셸에서 Esc/화살표.** 에이전트 없는 pane·vim에서 상태가 바뀌지 않는다.

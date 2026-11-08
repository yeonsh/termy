# pi agent 지원(OSC 7501) 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** termy pane에서 실행한 pi(1.5.0+)가 다른 agent pane처럼 live 상태(THINK · WAIT · IDLE · ERR)와 WAIT 알림을 보여 주게 한다. 설치 단계 없이.

**Architecture:** pi는 이미 OSC 7501 program status(`app=pi`, `working`/`blocked`/`done`/`error`/`idle`)를 스스로 보고한다. termy의 local pane 7501 경로는 이미 있고, 유일한 장애물은 `ForegroundProcessWatcher.classifyAgent`가 `pi`를 모른다는 것 — 그 때문에 `accepts()`가 false라 보고가 버려지고 synthetic SessionStart도 없다. 그래서 (1) `AgentKind.pi`를 더하고, (2) 프로세스 분류에 `pi`를 넣고, (3) 7501 `idle`을 "사용자 취소"로 해석하는 앱 목록에 `pi`를 더한다. hook·plugin·설치기는 만들지 않는다.

**Tech Stack:** Swift 6 language mode, AppKit/Foundation, XCTest, XcodeGen(`project.yml`), Sparkle은 이 작업과 무관.

**Spec:** `docs/superpowers/specs/2026-11-08-pi-agent-support-design.md`

## Global Constraints

- **Swift 6 language mode** (`SWIFT_VERSION: "6.0"`). `termy.xcodeproj`는 git에 없다 — 빌드 전에 `xcodegen generate`를 돌린다.
- **테스트 명령** (이 환경에서 `-derivedDataPath`·`-skipPackagePluginValidation`이 없으면 EPERM/plugin 검증 오류):
  `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25`
  성공 표시는 `** TEST SUCCEEDED **`. 여러 클래스는 `-only-testing`을 반복한다.
- **pi의 wire 이름은 `"pi"`, display 이름은 `"Pi"`.** (`app=pi` OSC 보고와 같은 값)
- **설치기·메뉴 항목·extension 파일을 만들지 않는다.** pi는 7501만 쓴다(spec §2, D1).
- **다른 agent 동작을 바꾸지 않는다.** Claude/Codex/agy/opencode 경로의 기존 테스트가 그대로 통과해야 한다.
- **커밋 메시지는 한국어, `Co-Authored-By` 줄 없음.** 접두사는 `feat(status):` · `fix(status):` · `docs:`.
- **새 주석은 이 저장소의 최근 status 코드처럼 한국어로 쓴다**(기술 용어는 영어 그대로).
- 테스트 host 주의: XCTest host의 유일한 window를 닫거나 해제하면 앱이 종료된다. 이 계획은 뷰 테스트를 만들지 않는다.

## Review Focus

1. **`pi`는 정확히 일치할 때만 agent다.** `piano`, `pi-web`, `pip`, `spipe` 같은 이름이 agent로 분류되면 무관한 pane에 칩과 알림이 붙는다. (`pi`는 짧은 이름이라 접두사 매칭을 쓰지 않는다)
2. **argv의 `pi`는 argv[0]일 때만 agent다.** JS 런타임 프로세스에서 `node server.js pi` 같은 인자를 agent entrypoint로 오인하면 안 된다. npm 경로(`@earendil-works/pi-coding-agent`)는 어느 위치든 매칭한다.
3. **Esc 취소는 알림을 울리지 않는다.** 7501 `idle`이 열린 turn을 닫으면 소리 없는 `IDLE`이다. `done`(정상 종료)은 반대로 `WAIT` + 알림음이다.
4. **synthetic SessionStart가 THINK를 덮어쓰지 않는다.** foreground watcher의 SessionStart(agent=pi)는 7501 `working`보다 최대 1초 늦게 올 수 있다. 그때 상태가 `IDLE`로 되돌아가면 안 된다(pi는 Claude 그룹 = soft reset).
5. **`blocked` kind 매핑이 어긋나지 않는다.** `question`은 `askUserQuestion`(질문 문구), `auth`는 `permission` + reason `"auth"`, kind 없음은 `permission`.

---

## File Structure

| 파일 | 책임 | 변경 |
|---|---|---|
| `apps/termy/Sources/AgentKind.swift` | agent 종류의 단일 정의(wire 이름 · 표시 이름 · 파싱) | `.pi` case |
| `apps/termy/Sources/ForegroundProcessWatcher.swift` | foreground 프로세스를 agent로 분류 | `pi` 분류 + entrypoint |
| `apps/termy/Sources/PaneState.swift` | hook/7501 이벤트 → pane 상태 순수 reducer | 7501 idle 취소 규칙에 pi |
| `apps/termy/Sources/AgentResume.swift` | 업데이트 relaunch 뒤 재개 명령 | `.pi` 분기(지금은 도달 불가) |
| `apps/termy/Sources/AgentResumeFlags.swift` | 재개 시 옮길 argv flag 표 | `.pi`는 빈 표 |
| `README.md` | 지원 agent 목록 · 동작 설명 | pi 추가 |
| `apps/termy-tests/Sources/AgentKindTests.swift` | wire/표시 이름 | pi 케이스 |
| `apps/termy-tests/Sources/AgentResumeCommandTests.swift` | 재개 명령 문자열 | pi 케이스 |
| `apps/termy-tests/Sources/ForegroundProcessWatcherTests.swift` | 분류기 | pi 케이스(양성·음성) |
| `apps/termy-tests/Sources/PaneProgramStatusTests.swift` | 7501 상태 규칙 | pi 케이스 |

Task 1이 `AgentKind`에 case를 더하면 `AgentResume.swift`·`AgentResumeFlags.swift`의 switch가 컴파일되지 않으므로, 그 두 파일의 case도 Task 1에 함께 넣는다(빌드를 초록으로 유지).

---

### Task 1: `AgentKind.pi` + 컴파일러가 요구하는 switch 분기

**Files:**
- Modify: `apps/termy/Sources/AgentKind.swift:16-53`
- Modify: `apps/termy/Sources/AgentResume.swift:29-40`
- Modify: `apps/termy/Sources/AgentResumeFlags.swift:68-73`
- Test: `apps/termy-tests/Sources/AgentKindTests.swift`
- Test: `apps/termy-tests/Sources/AgentResumeCommandTests.swift`

**Interfaces:**
- Consumes: 없음(첫 task).
- Produces: `AgentKind.pi` (rawValue `"pi"`, `wireName` `"pi"`, `displayName` `"Pi"`), `AgentKind.from(rawAgent: "pi") == .pi`, `AgentResumeCommand.make`가 `.pi`에 대해 `pi --session <id>`를 돌려준다. `AgentResumeFlags.extract(kind: .pi, argv:)`는 `[]`.

- [ ] **Step 1: 문서 커밋**

```bash
git add docs/superpowers/specs/2026-11-08-pi-agent-support-design.md docs/superpowers/plans/2026-11-08-pi-agent-support.md
git commit -m "docs(plan): pi agent 지원 계획"
```

- [ ] **Step 2: 실패하는 테스트를 쓴다**

`apps/termy-tests/Sources/AgentKindTests.swift`의 `test_from_antigravity_returnsAntigravity` 아래에:

```swift
func test_from_pi_returnsPi() {
    XCTAssertEqual(AgentKind.from(rawAgent: "pi"), .pi)
}
```

`test_wireName_and_displayName` 아래에:

```swift
func test_pi_wireName_and_displayName() {
    XCTAssertEqual(AgentKind.pi.wireName, "pi")
    XCTAssertEqual(AgentKind.pi.displayName, "Pi")
}
```

`apps/termy-tests/Sources/AgentResumeCommandTests.swift`의 `test_antigravity_putsFlagsAfterConversationId` 아래에:

```swift
// pi는 아직 재개 기록을 만들지 않는다(7501 보고에 session id가 없다). 그래도 명령은 정해 둔다.
func test_pi_usesSessionFlag() {
    XCTAssertEqual(
        AgentResumeCommand.make(record(.pi, id: "019a-uuid")),
        "pi --session 019a-uuid"
    )
}
```

- [ ] **Step 3: 테스트가 실패하는지 확인한다**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/AgentKindTests 2>&1 | tail -25`
Expected: FAIL — `type 'AgentKind' has no member 'pi'` (컴파일 실패).

- [ ] **Step 4: `AgentKind.pi`를 더한다**

`AgentKind.swift` — enum case 목록 끝에 `case pi`, `wireName`에 `case .pi: return "pi"`, `displayName`에 `case .pi: return "Pi"`, `from(rawAgent:)`에 `case "pi": return .pi`.
파일 머리의 wire 형식 주석에 pi를 더한다(`"claude-code", "codex", "antigravity", "opencode", "pi"`).

- [ ] **Step 5: switch 두 곳을 채운다**

`AgentResume.swift`의 `make(_:)` switch에서 `.opencode` case 아래에:

```swift
case .pi:
    // pi 1.5.0 `pi --session <path|id>`. 아직 도달하지 않는다: 7501 보고에 session id가 없어
    // AgentResumeCapture가 기록을 만들지 못한다(spec D4).
    words = ["pi", "--session", id] + flags
```

`AgentResumeFlags.swift`의 `extract(kind:argv:)` switch에서 `.opencode` case를 `case .opencode, .pi:`로 바꾼다(표는 빈 채로).

- [ ] **Step 6: 테스트가 통과하는지 확인한다**

Run: `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/AgentKindTests -only-testing:termy-tests/AgentResumeCommandTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: 커밋**

```bash
git add apps/termy/Sources/AgentKind.swift apps/termy/Sources/AgentResume.swift apps/termy/Sources/AgentResumeFlags.swift apps/termy-tests/Sources/AgentKindTests.swift apps/termy-tests/Sources/AgentResumeCommandTests.swift
git commit -m "feat(status): AgentKind에 pi를 더한다"
```

---

### Task 2: foreground 프로세스 분류

**Files:**
- Modify: `apps/termy/Sources/ForegroundProcessWatcher.swift:220-275`
- Test: `apps/termy-tests/Sources/ForegroundProcessWatcherTests.swift`

**Interfaces:**
- Consumes: `AgentKind.pi` (Task 1).
- Produces: `ForegroundProcessWatcher.classifyAgent(by: "pi") == .pi`, `classifyAgent(processName: "node", arguments: ["pi"]) == .pi`, `classifyAgent(processName: "node", arguments: ["/usr/bin/node", "server.js", "pi"]) == nil`, `agentEntrypoint(in: ["pi", "--model", "x"]) == (0, .pi)`.
- 이 task가 실질적 스위치다: `Pane.localForegroundAgent()`가 non-nil이 되어 7501 `accepts()`가 true가 되고, watcher가 synthetic SessionStart(agent=pi)를 보낸다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`ForegroundProcessWatcherTests.swift`의 `test_classifyAgent_nodeBackedCodexPackage` 아래에:

```swift
func test_classifyAgent_pi() {
    XCTAssertEqual(ForegroundProcessWatcher.classifyAgent(by: "pi"), .pi)
    XCTAssertEqual(ForegroundProcessWatcher.classifyAgent(by: "PI"), .pi)
}

func test_classifyAgent_piExactNameOnly() {
    // `pi`는 짧은 이름이라 접두사 매칭을 쓰지 않는다 (spec 4.2).
    for name in ["piano", "pi-web", "pip", "spipe"] {
        XCTAssertNil(ForegroundProcessWatcher.classifyAgent(by: name), "name: \(name)")
    }
}

func test_classifyAgent_nodeBackedPiEntrypoint() {
    // 실측: pi는 shebang 스크립트라 proc_name = node, argv[0] = "pi" (spec 3.2).
    XCTAssertEqual(
        ForegroundProcessWatcher.classifyAgent(processName: "node", arguments: ["pi"]),
        .pi
    )
}

func test_classifyAgent_nodeBackedPiPackage() {
    XCTAssertEqual(
        ForegroundProcessWatcher.classifyAgent(
            processName: "bun",
            arguments: [
                "/Users/me/.bun/bin/bun",
                "/Users/me/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js",
            ]
        ),
        .pi
    )
}

func test_classifyAgent_piAsLaterArgumentIsNotAgent() {
    // Review Focus 2: `node server.js pi`의 `pi`는 entrypoint가 아니다.
    XCTAssertNil(
        ForegroundProcessWatcher.classifyAgent(
            processName: "node",
            arguments: ["/usr/bin/node", "server.js", "pi"]
        )
    )
}

func test_agentEntrypoint_piAtArgv0() {
    XCTAssertEqual(
        ForegroundProcessWatcher.agentEntrypoint(in: ["pi", "--model", "anthropic/claude"])?.index,
        0
    )
    XCTAssertEqual(
        ForegroundProcessWatcher.agentEntrypoint(in: ["pi", "--model", "x"])?.kind,
        .pi
    )
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/ForegroundProcessWatcherTests 2>&1 | tail -25`
Expected: FAIL — `test_classifyAgent_pi`, `test_classifyAgent_nodeBackedPiEntrypoint`, `test_agentEntrypoint_piAtArgv0` 등이 nil/`.opencode` 대신 `.pi`를 기대하며 실패. (`test_classifyAgent_piExactNameOnly`, `test_classifyAgent_piAsLaterArgumentIsNotAgent`는 이미 통과)

- [ ] **Step 3: `classifyAgent(by:)`에 pi를 더한다**

`normalized == "opencode"` 검사 아래에:

```swift
if normalized == "pi" { return .pi }
```

파일 머리 주석의 agent 목록(`claude`, `codex`, `agy`, `opencode`)에 `pi`를 더한다.

- [ ] **Step 4: `agentEntrypoint(in:)`에 pi를 더한다**

`.opencode` 검사 아래에:

```swift
// `pi`는 짧은 이름이라 argv[0]에서만 받는다. 그 밖의 위치는 npm 패키지 경로일 때만 인정한다.
if (basename == "pi" && index == 0)
    || normalized.contains("@earendil-works/pi-coding-agent") {
    return (index, .pi)
}
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run: `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/ForegroundProcessWatcherTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: 커밋**

```bash
git add apps/termy/Sources/ForegroundProcessWatcher.swift apps/termy-tests/Sources/ForegroundProcessWatcherTests.swift
git commit -m "feat(status): pi 프로세스를 agent로 분류한다"
```

---

### Task 3: 7501 `idle` 취소 규칙에 pi

**Files:**
- Modify: `apps/termy/Sources/PaneState.swift:220-250` (`applyProgramStatus`의 `case "done", "idle"`)
- Test: `apps/termy-tests/Sources/PaneProgramStatusTests.swift`

**Interfaces:**
- Consumes: `AgentKind.pi` (Task 1), `HcStatus(state:kind:msg:app:)`.
- Produces: `app == "pi"`인 `HcStatus`에 대해 `applyProgramStatus`가 pi를 Claude와 같은 "취소 = 소리 없는 IDLE" 규칙으로 처리한다. 그 외 상태 규칙은 불변.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`PaneProgramStatusTests.swift`의 helper `st(_:kind:)` 아래에:

```swift
private func pi(_ s: String, kind: String? = nil) -> HcStatus { HcStatus(state: s, kind: kind, msg: nil, app: "pi") }
```

`testIdleOnOpenTurnFromNonClaudeAppIsTurnEnd` 아래에:

```swift
func testPiIdleOnOpenTurnIsSilentIdle() {
    let w = PaneStateMachine.applyProgramStatus(pi("working"), to: base(), now: Date())
    let n = PaneStateMachine.applyProgramStatus(pi("idle"), to: w, now: Date())
    XCTAssertEqual(n.state, .idle)
    XCTAssertFalse(n.turnOpen)
    XCTAssertFalse(n.needsAttention)
    XCTAssertNil(n.notificationReason)
    XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(w), next: obs(n)))
}

func testPiWorkingThenDoneAlerts() {
    let w = PaneStateMachine.applyProgramStatus(pi("working"), to: base(), now: Date())
    let d = PaneStateMachine.applyProgramStatus(pi("done"), to: w, now: Date())
    XCTAssertEqual(d.state, .waiting)
    XCTAssertEqual(d.waitSource, .turnEnd)
    XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(w), next: obs(d)))
}

func testPiBlockedQuestionWaitsForAnswer() {
    let n = PaneStateMachine.applyProgramStatus(pi("blocked", kind: "question"), to: base(), now: Date())
    XCTAssertEqual(n.state, .waiting)
    XCTAssertEqual(n.waitSource, .askUserQuestion)
    XCTAssertTrue(n.needsAttention)
}

func testPiBlockedAuthKeepsReason() {
    let n = PaneStateMachine.applyProgramStatus(pi("blocked", kind: "auth"), to: base(), now: Date())
    XCTAssertEqual(n.waitSource, .permission)
    XCTAssertEqual(n.notificationReason, "auth")
}

func testPiSessionStartAfterWorkingKeepsThinking() {
    // foreground watcher의 synthetic SessionStart는 7501 working보다 최대 1초 늦다.
    // pi는 Claude 그룹이라 hard reset 하지 않는다 (spec 4.3).
    let w = PaneStateMachine.applyProgramStatus(pi("working"), to: base(), now: Date())
    let start = HookEvent(
        event: .sessionStart, paneId: "P", projectId: "app", ts: 2,
        agent: "pi", meta: HookEvent.Meta()
    )
    let n = PaneStateMachine.apply(start, to: w)
    XCTAssertEqual(n.state, .thinking)
    XCTAssertEqual(n.agentKind, .pi)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/PaneProgramStatusTests 2>&1 | tail -25`
Expected: FAIL — `testPiIdleOnOpenTurnIsSilentIdle`이 `.waiting`을 받아 실패. 다른 pi 테스트는 통과(기존 규칙으로 이미 맞음).

- [ ] **Step 3: 취소 규칙을 앱 집합으로 바꾼다**

`PaneState.swift`의 `PaneStateMachine` 안, 기존 `blockingReasons` 옆에:

```swift
/// 7501 `idle`이 열린 turn을 닫는 것을 "사용자 취소"로 해석하는 앱.
/// 둘 다 정상 종료는 `done`으로 보낸다(Claude Code 2.1.319 · pi 1.5.0 실측).
private static let idleMeansCancelApps: Set<String> = ["claude-code", "pi"]
```

`applyProgramStatus`의 `case "done", "idle":` 첫 분기 조건을 바꾼다:

```swift
if status.state == "idle", previous.turnOpen, let app = status.app,
   Self.idleMeansCancelApps.contains(app) {
```

기존 주석(Claude 전용 근거)에 pi를 더한다: pi도 취소에서만 `idle`, 정상 종료는 `done`.
`PaneState.swift` 머리의 상태 다이어그램에 `*(7501, app=pi)`가 Claude와 같은 줄을 쓴다는 한 줄을 더한다.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/PaneProgramStatusTests -only-testing:termy-tests/PaneStateMachineTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **` (Claude/Codex 규칙 회귀 없음)

- [ ] **Step 5: 커밋**

```bash
git add apps/termy/Sources/PaneState.swift apps/termy-tests/Sources/PaneProgramStatusTests.swift
git commit -m "feat(status): pi의 Esc 취소를 소리 없는 IDLE로 닫는다"
```

---

### Task 4: README에 pi 반영

**Files:**
- Modify: `README.md:7` (상단 문구), `:32` (Why termy 본문), `:83` (pane 설명), `:157-167` (What else you get), `:330-395` (How it works · Status)

**Interfaces:**
- Consumes: 없음(문서만). Task 1-3의 사실(pi는 설치 없이 7501로만 붙고, 재개는 아직 지원하지 않는다)을 그대로 적는다.
- Produces: 없음.

- [ ] **Step 1: 지원 agent 목록에 pi를 더한다**

`<strong>Mission control for Claude Code, Codex, OpenCode &amp; Antigravity.</strong>`를
`… Codex, OpenCode, Antigravity &amp; pi.</strong>`로 바꾼다.
`:32`의 `Running N coding agents — Claude Code, Codex CLI, OpenCode, Antigravity CLI, or any mix`를
`… Antigravity CLI, pi, or any mix`로 바꾼다.
`:83`의 `Claude Code, Codex CLI, OpenCode, or Antigravity CLI, mixed freely.`를 `… OpenCode, Antigravity CLI, or pi, mixed freely.`로 바꾼다.

- [ ] **Step 2: "What else you get"을 고친다**

`**Four agents, one dashboard.**`를 `**Five agents, one dashboard.**`로, 본문의 agent 목록에 pi를 더하고
`Each integration installs from the termy menu and reports live state through hooks or a plugin.` 뒤에
`pi needs no install — it reports its own state over OSC 7501.`를 덧붙인다.
`Updates that wait for you.` 문단의 재개 목록은 그대로 두고, 문장 끝에
`pi conversations are not resumed yet.`를 더한다.

- [ ] **Step 3: "How it works" 다이어그램과 설명을 고친다**

다이어그램의 `Antigravity ──hook───▶ …` 줄 아래에 한 줄을 더한다:

```
pi          ──OSC 7501─▶ pane terminal (accepts only while fg is an agent) ─┐
```

- `**\`termy-hook\`**` 문단: pi는 termy-hook을 쓰지 않는다는 한 줄을 더한다.
- `**Synthetic \`PtyExit\`**` 문단의 foreground watcher 목록
  (`when \`claude\`, \`codex\`, \`opencode\`, or \`agy\` leaves a pane`)에 `pi`를 더한다.
- Status의 `Four agents end-to-end — Claude Code, Codex CLI, OpenCode, and Antigravity CLI`를
  `Five agents end-to-end — Claude Code, Codex CLI, OpenCode, Antigravity CLI, and pi (OSC 7501, no install)`로 바꾼다.
- `Hook daemon + \`termy-hook\` + non-destructive installers for every integration`를
  `… installers for every hook-based integration`로 바꾼다.

- [ ] **Step 4: 문구 확인**

Run: `git diff README.md`
Expected: 위 항목만 바뀌고, pi가 설치기나 재개를 지원한다고 읽히는 문장이 없다.

- [ ] **Step 5: 커밋**

```bash
git add README.md
git commit -m "docs: README에 pi 지원을 적는다"
```

---

## 마지막 확인 (전체 회귀)

- [ ] `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation 2>&1 | tail -25` → `** TEST SUCCEEDED **`
- [ ] 수동 확인(가능하면): termy pane에서 `pi` 실행 → 1초 안에 IDLE 칩, prompt 전송 → THINK, Esc → 소리 없는 IDLE, 응답 완료 → WAIT + 알림음 → 30초 뒤 IDLE. termy 밖(Ghostty)에서 띄운 pi는 칩이 생기지 않는다.

## 남은 것 (다음 라운드 B)

spec §7 참고: termy 관리 pi extension(`~/.pi/agent/extensions/termy.ts`) + 설치기/메뉴/session id 기반 재개.

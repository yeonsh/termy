# 업데이트 후 agent 세션 이어가기 — 설계 문서

- 날짜: 2026-10-10
- 상태: 사용자 검토 대기
- 범위: Sparkle 업데이트 재시작 전후로 Claude Code / Codex 대화를 잃지 않게 한다

## 1. 목표와 동기

termy를 업데이트하면 Sparkle이 앱을 종료했다가 다시 띄운다. 각 pane의 PTY master fd를
termy.app 프로세스가 직접 쥐고 있으므로(`Pane.startShell`, SwiftTerm `LocalProcess`)
앱이 종료되면 셸과 그 안의 agent가 SIGHUP으로 함께 죽는다. 다시 띄운 뒤 복원되는 것은
창 배치와 pane cwd뿐이다.

이 작업은 프로세스를 살리는 대신 **대화를 이어 붙인다.** 업데이트 버튼을 언제 눌러도
대화 맥락과 진행 중이던 turn을 잃지 않는 것이 목표다.

성공 기준:

- 업데이트로 재시작한 뒤, claude 나 codex 가 돌던 pane마다 같은 대화가 자동으로
  다시 열린다(`claude --resume <id>` / `codex resume <id>`).
- 원래 실행할 때 준 권한·모델 관련 플래그가 resume 에도 이어진다.
- agent가 turn 도중이면 재시작하지 않고, 모든 turn이 끝난 뒤 재시작한다.
- agent가 없던 pane은 지금처럼 빈 셸로 뜬다.
- ⌘Q / 크래시 / 재부팅 뒤의 실행은 지금과 똑같이 동작한다(resume 하지 않는다).

## 2. 비목표

- 프로세스 자체를 살려 두는 것(PTY를 helper / daemon 으로 옮기기). 별도 작업이다.
- 스크롤백, 셸 history, 셸 환경변수 복원.
- 진행 중이던 turn을 이어서 실행하는 것. resume 은 대화 기록만 되살린다. 그래서
  turn 도중에는 재시작하지 않도록 미룬다(§5.6).
- ⌘Q / 크래시 / 재부팅 뒤의 자동 resume.
- claude / codex 외 agent(aider, gemini 등).
- 설정 UI(켜고 끄는 토글).

## 3. 현재 구조 (출발점)

- 세션 저장: `~/Library/Application Support/termy/session.json`
  (`SessionRecord` → `WindowRecord` → `rows: [[PaneRecord]]`). `PaneRecord` 는 `cwd` 만
  가진다. `SessionAutosaver` 가 500ms debounce 로 저장한다.
- ⌘K 프로젝트 레이아웃(`workspaces/<hash>.json`, `WorkspaceRecord`)도 `PaneRecord` 를
  쓴다.
- 종료 시 `applicationWillTerminate` 가 0.5초 제한이 걸린 비동기 flush 를 시도한다.
- hook 으로 받은 `session_id` 는 `PaneSnapshot.lastSessionId` 에 메모리로만 있다.
  `HookDaemon`(actor)이 원본을 갖고, `MissionControlModel`(MainActor)이 같은 snapshot
  을 `snapshotsById` 로 들고 있다.
- `ForegroundProcessWatcher` 가 `tcgetpgrp` + `proc_name` + `KERN_PROCARGS2` 로 pane의
  foreground agent 를 판별한다. argv 는 판별에만 쓰고 저장하지 않는다.
- `Updater` 는 `SPUStandardUpdaterController` 를 delegate 없이 쓴다.
  `SUAllowsAutomaticUpdates: false` 이므로 설치는 항상 사용자가 시작한다.
- pane id 는 실행할 때마다 새 UUID 다. resume 은 새 pane에서 새 프로세스를 띄우므로
  문제가 되지 않는다.
- 앱 UI 문구는 영어다.

## 4. 결정 사항

| 항목 | 결정 |
|---|---|
| resume 시점 | Sparkle 업데이트 재시작 때만 |
| 플래그 | 허용 목록에 있는 권한·모델 관련 플래그만 이어받는다. prompt 인자와 `--print` 는 절대 다시 실행하지 않는다 |
| "작업 중" 기준 | turn 이 끝나지 않은 상태 전부(THINKING, 권한 요청, AskUserQuestion, MCP 입력 대기) |
| 작업 중일 때 UX | alert 로 확인 → 기다리다가 모두 끝나면 자동 재시작. 기다리는 동안 메뉴로 강제 재시작 가능 |
| 저장 위치 | `PaneRecord` 에 optional 필드 추가, 업데이트 직전에만 기록 |
| resume 명령 실행 | 복원한 셸에 명령을 입력한다(셸 `-c` 실행이 아님) |

## 5. 컴포넌트 설계

### 5.1 스키마

```swift
struct AgentResumeRecord: Codable, Equatable {
    var kind: AgentKind      // .claude | .codex
    var sessionId: String
    var cwd: String?         // agent 프로세스의 실제 cwd. 못 읽었으면 nil
    var flags: [String]      // 허용 목록을 통과한 argv 조각, 순서 유지
}

struct PaneRecord: Codable, Equatable {
    var cwd: String
    var agentResume: AgentResumeRecord? = nil
}
```

- optional 이므로 schema 버전을 올리지 않는다(`WindowRecord.projectOrder` 와 같은 방식).
  필드가 없는 옛 `session.json` 은 그대로 읽히고, 옛 빌드는 모르는 키를 무시한다.
- `WorkspaceRecord`(⌘K)는 이 필드를 항상 nil 로 둔다.

### 5.2 수집 — `AgentResumeCapture`

`updaterWillRelaunchApplication` 에서 한 번만 실행한다. 판단 로직은 입력을 주입받는
순수 함수로 둔다.

```swift
static func record(
    foregroundAgent: AgentKind?,   // foreground PG leader 판별 결과
    argv: [String]?,               // 그 프로세스의 argv
    processCwd: String?,           // 그 프로세스의 cwd
    snapshot: PaneSnapshot?        // MissionControlModel 의 해당 pane snapshot
) -> AgentResumeRecord?
```

다음을 모두 만족할 때만 기록을 만든다. 하나라도 어긋나면 nil(그 pane은 빈 셸로 복원).

- `foregroundAgent` 가 nil 이 아니다.
- `snapshot` 이 있고, `snapshot.agentKind == foregroundAgent` 이고, `state != .initializing`
  이고, `lastSessionId` 가 비어 있지 않다.

실제 값은 pane 이 조회한다.

- foreground PID: `ForegroundProcessWatcher.currentForegroundAgent` 의 PID 조회 부분을
  `static` helper 로 분리해서 MainActor 에서도 부른다(`terminal.process.childfd`,
  `terminal.process.shellPid`).
- argv: 기존 `ForegroundProcessWatcher.processArguments(pid:)`.
- cwd: 새 `static func processCwd(pid:) -> String?` — `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
  termy 의 `Pane.currentCwd` 는 셸이 OSC 7 을 보낼 때만 갱신되고 termy 는 shell
  integration 을 주입하지 않으므로, 세션을 찾는 기준 디렉터리로 쓰기에는 믿을 수 없다.

### 5.3 플래그 허용 목록 — `AgentResumeFlags`

```swift
static func extract(kind: AgentKind, argv: [String]) -> [String]
```

- argv 에서 agent entrypoint 를 먼저 찾고 그 뒤의 인자만 본다. node / bun / deno 로 띄운
  경우 entrypoint 는 `ForegroundProcessWatcher.classifyAgent(fromArguments:)` 와 같은
  규칙(basename 이 claude/codex, 또는 `@anthropic-ai/claude-code` / `@openai/codex` 포함)
  으로 찾는다. 바로 실행한 경우는 `argv[0]` 이 entrypoint 다.
- 허용 목록(agent 별로 따로 둔다):

| agent | 값 없는 플래그 | 값 하나 | 값 여러 개 |
|---|---|---|---|
| claude | `--dangerously-skip-permissions` | `--model`, `--permission-mode` | `--allowedTools` / `--allowed-tools`, `--disallowedTools` / `--disallowed-tools`, `--add-dir` |
| codex | `--approve-for-me`, `--dangerously-bypass-approvals-and-sandbox` | `-m` / `--model`, `-s` / `--sandbox`, `-a` / `--ask-for-approval`, `-p` / `--profile`, `-c` / `--config`, `--add-dir` | — |

codex 의 값 하나짜리 플래그는 여러 번 반복될 수 있고(`-c a=1 -c b=2`), 나온 순서대로
모두 유지한다. codex 목록은 `codex resume --help`(codex-cli 0.160.1)가 받는 옵션과
대조했다. `--full-auto` 는 0.160.1 에 없어서 넣지 않았다.

**CLI 버전 변화와 유지보수.** 플래그는 실행 중인 프로세스의 argv 에서 복사하므로, 그 CLI
버전이 받아들인 플래그만 들어온다. 그래서 CLI 가 플래그를 없애도 허용 목록의 해당 항목은
쓰이지 않게 될 뿐이고, 새 플래그가 생기면 이어받지 않을 뿐이다. termy 를 고쳐야 하는
경우는 resume 명령 형태(`claude --resume`, `codex resume`)가 바뀌거나, 새 플래그를
이어받고 싶을 때뿐이다. 깨지는 경우는 하나다: 세션 도중 CLI 가 자동 업데이트되고 새
버전에서 그 플래그가 없어지면 resume 이 "unknown option" 으로 실패하고 셸로 돌아온다.
입력된 명령이 화면에 남으므로 사용자가 플래그를 지우고 다시 실행할 수 있다. 자동 재시도는
하지 않는다(사용자 결정, 2026-10-10).

- `--flag=value` 형태를 받는다. 값 여러 개를 받는 플래그는 다음 `-` 로 시작하는 인자
  직전까지를 값으로 본다.
- 목록에 없는 플래그는 버린다. 값이 있는지 모르는 플래그를 버릴 때 그 뒤 인자가 값인지
  prompt 인지 알 수 없으므로, 목록 밖 인자는 모두 버리는 것으로 충분하다.
- 위치 인자(prompt), `--print`(claude 의 `-p`), `--resume`, `--continue`, 하위 명령
  (`codex exec`, `codex resume` 등)은 결과에 절대 넣지 않는다.
- `-p` 는 claude 에서는 `--print`(버림), codex 에서는 `--profile`(유지)이다.

### 5.4 저장 — `WindowManager.prepareForUpdateRelaunch()`

`Updater` 의 `updaterWillRelaunchApplication(_:)` 에서 부른다.

1. 모든 창에 대해 `sessionWindowRecord(includeAgentResume: true)` 로 `SessionRecord` 를
   만든다. pane 마다 §5.2 수집을 실행한다.
2. `SessionPersistence.sealWithFinalRecord(_:)` 로 main thread 에서 **동기로**
   `session.json` 을 쓰고 파일을 봉인한다. 봉인 뒤의 `save(_:)` 는 아무것도 쓰지 않는다.
   - 쓰기 본문(encode → temp 파일 → rename)을 lock 으로 감싼 nonisolated 함수 하나로
     모으고, 기존 비동기 `save` 와 봉인 쓰기가 둘 다 이 함수를 지난다.
   - 그래서 종료 중에 창이 닫히면서 생기는 autosave, `applicationWillTerminate` 의 flush,
     이미 다른 스레드에서 진행 중이던 autosave 가 resume 기록을 덮어쓰지 못한다.
     autosaver 쪽을 멈추는 것만으로는 이미 진행 중인 쓰기를 막을 수 없어서 저장소
     단에서 막는다.
   - 종료 경로의 비동기 flush 에 기대지 않는다.

평소 autosave 는 `includeAgentResume: false` 로 저장하므로, resume 필드는 업데이트 직전
에만 파일에 들어간다.

### 5.5 복원과 resume 명령 입력

- `WindowManager.restoreSessionWindows` → `MainWindowController.applySessionLayout` →
  `Workspace.addPane(cwd:splitAxis:startupInput:)` → `Pane(projectId:cwd:startupInput:)`.
  - pane 시작 디렉터리는 `agentResume?.cwd ?? record.cwd`.
  - `startupInput = agentResume.map(AgentResumeCommand.make)`.
- ⌘K 프로젝트 레이아웃 복원 경로는 `startupInput` 을 넘기지 않는다.
- 복원을 마치면 `sessionAutosaver.requestSave()` 를 한 번 부른다. `session.json` 이 resume
  필드 없이 다시 쓰여서, 이후 크래시 뒤 재실행에서 같은 세션을 또 띄우지 않는다.

`AgentResumeCommand.make(_:) -> String`(순수 함수):

- claude: `claude --resume <id> <flags…>`
- codex: `codex resume <flags…> <id>` — `codex resume [OPTIONS] [SESSION_ID] [PROMPT]`
  형식이므로 플래그를 id 앞에 둬서, id 뒤에 오는 인자가 prompt 로 해석될 여지를 없앤다.
- 인자에 안전한 문자(`A-Z a-z 0-9 _ . / : = @ % + , -`)만 있으면 그대로 두고, 그 밖의
  문자가 있거나 빈 문자열이면 작은따옴표로 감싼다(값 안의 `'` 는 `'\''`). 명령이 화면에
  그대로 보이고 사용자가 고쳐 쓸 수도 있으므로, 플래그 이름까지 따옴표로 감싸지 않는다.
- 실행 파일은 이름(`claude`, `codex`)으로 부르고 PATH 에 맡긴다.

`Pane` 의 입력 타이밍:

- `TermyTerminalView.dataReceived` 에서 pane 으로 출력 도착을 알리는 callback 을 추가한다.
- 첫 출력이 온 뒤 300ms 동안 새 출력이 없으면 `terminal.send(txt: input + "\r")`.
  셸 시작 후 3초가 지나면 출력과 관계없이 보낸다. 한 번만 보낸다.
- 너무 일찍 보내도 PTY 가 입력을 보관했다가 셸이 읽으므로 동작은 같다. 기다리는 이유는
  명령이 프롬프트 위에 한 번 더 찍혀 보이는 것을 줄이기 위해서다.
- 타이머 판단은 시계·스케줄러를 주입받는 작은 타입(`StartupInputScheduler`)으로 둔다.

resume 이 실패하면(세션 파일 없음, 플래그 불일치) agent 가 오류를 출력하고 셸로
돌아온다. 재시도하지 않는다. resume 된 agent 는 `SessionStart`(source: resume)를 보내므로
Mission Control 에는 새 pane id 로 평소처럼 잡힌다.

### 5.6 "작업 중" 판별 — `PaneSnapshot.turnOpen`

기존 상태값만으로는 turn 이 끝났는지 알 수 없다. Claude 는 권한 요청 Notification 뒤에
`Stop` 이 와도 `notificationReason` 이 "permission" 으로 남는다(`PaneStateMachine` 의
`.stop` 분기가 지우지 않음). 그래서 turn 경계만 따로 추적한다.

`var turnOpen: Bool = false` 를 `PaneSnapshot` 에 추가하고 `PaneStateMachine.apply` 에서
바꾼다.

| 이벤트 | turnOpen |
|---|---|
| `UserPromptSubmit` | true |
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure` | true |
| `Stop`, `StopFailure` | false |
| `SessionEnd`, `PtyExit` | false |
| session id 변경으로 인한 reset | false |
| Codex `SessionStart`(hard reset) | false |
| Claude `SessionStart` | 그대로(auto-compact 등 turn 도중 발생) |
| 그 밖 | 그대로 |

```swift
extension PaneSnapshot {
    var isMidTurn: Bool {
        turnOpen
            && state != .initializing
            && !(state == .waiting && waitSource == .promotedFromPossible)
    }
}
```

- 권한 요청, AskUserQuestion, MCP 입력 대기는 turn 도중이므로 자연히 작업 중이다.
- tool 이벤트도 turn 을 연다. tool 은 turn 안에서만 실행되므로, `Stop` 뒤에 tool 이벤트가
  오면 agent 가 다시 일하고 있다는 뜻이다. 예: Stop hook 이 막아서 Claude 가 `Stop` 뒤에
  작업을 이어가는 경우, termy 가 turn 도중에 켜져서 `UserPromptSubmit` 을 못 본 경우.
- `.promotedFromPossible`(Codex 가 조용해서 WAIT 로 올린 상태)은 termy 가 이미 "입력
  대기"로 판단한 상태이므로 끝난 것으로 본다. 그렇지 않으면 Codex 가 `Stop` 을 빠뜨릴 때
  업데이트가 끝없이 미뤄진다.
- `MissionControlModel.sameDashboardShape` 에는 넣지 않는다(화면 갱신 횟수 불변).
- `MissionControlModel` 에 살아 있는 pane(`livePaneIds`, 즉 지금 열린 창들의 pane) 중
  `isMidTurn` 인 것을 세는 `midTurnPaneCount` 를 추가한다. 닫힌 pane 의 snapshot 은 세지
  않는다. §5.2 수집용으로 `snapshot(paneId:)` 조회도 추가한다.

### 5.7 재시작 미루기 — `UpdateRelaunchGate` 와 `Updater` delegate

`Updater` 가 `SPUUpdaterDelegate` 를 구현하고 `SPUStandardUpdaterController` 에 자신을
`updaterDelegate` 로 넘긴다.

- `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`
  - `midTurnPaneCount == 0` 이면 false(바로 재시작).
  - 아니면 handler 를 `UpdateRelaunchGate.begin(installHandler:)` 에 넘기고 true.
- `updaterWillRelaunchApplication(_:)` → `WindowManager.prepareForUpdateRelaunch()`(§5.4).

`UpdateRelaunchGate`(MainActor, 시계·스케줄러·카운터·alert 표시를 주입받음):

1. `begin` 은 다음 run loop 에서 alert 를 띄운다(Sparkle 콜백을 막지 않음).
   - 제목: "N agents are still working"(1개면 "1 agent is still working")
   - 본문: "termy will restart to install the update when they finish their current
     turn. Other programs running in panes will still be stopped."
   - 버튼: [Wait for Agents] (기본), [Restart Now]
2. alert 가 떠 있는 동안에는 자동 재시작하지 않는다.
3. [Restart Now] → handler 를 바로 호출한다.
4. [Wait for Agents] → pending 상태가 되고, 그 즉시 한 번 센다. 이후 snapshot 이 갱신될
   때마다 센다.
5. 0 이 되면 2초 뒤 다시 센다. 그때도 0 이면 handler 를 호출한다. 그 사이 새 turn 이
   열리면 취소하고 계속 기다린다. 큐에 쌓인 메시지가 `Stop` 직후 다음 turn 으로 이어지는
   경우와 겹치지 않기 위해서다.
6. handler 는 정확히 한 번만 호출한다.

pending 동안 앱 메뉴에 "Restart Now to Install Update" 항목이 보인다(평소에는 숨김).
누르면 3번과 같다.

`MissionControlModel.onSnapshotUpdate` 는 지금 Notifier 하나만 받는 closure 다.
AppDelegate 에서 Notifier 와 gate 둘 다 부르도록 바꾼다.

### 5.8 DEBUG 전용 검증 메뉴

DEBUG 빌드에만 "Debug ▸ Simulate Update Relaunch" 를 둔다. Sparkle 을 거치지 않고 같은
경로를 탄다: 작업 중인 agent 가 있으면 gate → `prepareForUpdateRelaunch()` →
`NSApp.terminate`. 다시 실행은 사람이 한다.

## 6. 전체 흐름

```
사용자: Install and Relaunch
  └ Sparkle → shouldPostponeRelaunch
       ├ 작업 중 0개 → false
       └ 1개 이상 → gate.begin, true
            └ alert ─ Restart Now ──────────────┐
                    └ Wait → 모두 끝남 + 2초 ───┤
                                                ▼
                                       installHandler()
  └ Sparkle → updaterWillRelaunchApplication
       └ prepareForUpdateRelaunch: 수집 → session.json 동기 저장 + 봉인
  └ 종료 → 설치 → 새 버전 실행
       └ restoreSessionWindows → pane 마다 startupInput 입력
            → claude --resume … / codex resume …
       └ requestSave() → resume 필드 없는 session.json
```

## 7. 엣지 케이스

- hook 이 설치되지 않아 session id 가 없음 → resume 없이 빈 셸.
- foreground 가 agent 가 아님(vim, dev server 등) → resume 없음. 그 프로그램은 지금처럼
  종료된다(alert 본문에 명시).
- agent cwd 가 복원 시점에 사라짐 → `Pane.resolveCwd` 가 `$HOME` 으로 대체, resume 은
  실패 메시지를 보이고 셸로 돌아온다.
- 두 pane 이 같은 session id 를 쓰고 있었음 → 둘 다 같은 세션으로 resume(원래 상태와 같음).
- 기다리는 중 ⌘Q → Sparkle 이 종료 시 설치만 하고 다시 띄우지 않는다. resume 하지 않는다.
- `Stop` 을 놓쳐 `turnOpen` 이 true 로 남음 → [Restart Now] / 메뉴로 빠져나간다.
- resume 필드를 쓴 뒤 설치가 실패해서 사람이 직접 다시 실행함 → 그 실행에서 resume 한다.
  원래 의도(업데이트를 위한 재시작)와 맞으므로 허용한다.
- 여러 창 → 모든 창을 같은 방식으로 처리한다.

## 8. 테스트 전략

단위 테스트(`apps/termy-tests/Sources`):

- `SessionRecordTests`: `agentResume` 왕복, 필드 없는 옛 JSON 디코드,
  `WorkspaceRecord` 에서는 nil.
- `AgentResumeFlagsTests`(신규): agent 별 허용 목록, node 로 띄운 argv, `--flag=value`,
  값 여러 개(`--add-dir a b`)가 다음 `-` 에서 멈춤, prompt / `--print` / `--resume` /
  `--continue` 제거, `-p` 의 agent 별 처리.
- `AgentResumeCommandTests`(신규): 공백·작은따옴표가 든 값의 quoting.
- `SessionPersistenceTests`: 봉인 뒤의 `save` 가 파일을 덮어쓰지 않음.
- `AgentResumeCaptureTests`(신규): §5.2 조건 조합.
- `PaneStateMachineTests`: `turnOpen` 전환 표 전체, "Claude 권한 요청 → Stop" 에서 false,
  `isMidTurn` 의 `.promotedFromPossible` 예외.
- `UpdateRelaunchGateTests`(신규): handler 한 번만 호출, 2초 재확인 중 새 turn 이 열리면
  취소, [Restart Now] 즉시 호출, alert 표시 중 자동 호출 없음.
- `StartupInputSchedulerTests`(신규): 300ms quiet / 3초 상한 / 한 번만 전송.

## 9. 구현 전 확인 항목

1. `claude --resume <id>` 가 허용 목록 플래그(`--permission-mode`,
   `--dangerously-skip-permissions` 등)와 함께 동작하는지. 임시 디렉터리에서 `claude -p` 로
   세션을 만들고 resume 해 본다.
2. claude 프로세스의 cwd 가 Bash tool 에서 `cd` 한 뒤에도 실행 디렉터리로 남는지
   (`proc_pidinfo` 로 확인).
3. `codex resume --help` 로 인자 형식과 §5.3 플래그 수용 여부 확인. Codex 는 직접 실행하지
   않는다(전역 규칙). hook `session_id` 가 `codex resume` 에 그대로 쓰이는지는 사용자 실사용
   검증으로 남긴다.

확인 결과가 설계와 다르면(예: 어떤 플래그를 resume 이 받지 않음) 허용 목록을 고치고 이
문서에 반영한다.

확인 결과(2026-10-10, Claude Code 2.1.296 / codex-cli 0.160.1):

1. 통과. `claude --resume <id> --model haiku --permission-mode default --allowedTools Read
   Grep --add-dir /tmp -p …` 가 이전 대화를 이어받았다. 값 여러 개짜리 `--allowedTools` 는
   다음 `--add-dir` 에서 멈췄다. 다른 디렉터리에서도 같은 id 로 resume 됐다. 그래도 tool 이
   일하는 디렉터리를 맞추기 위해 agent cwd 에서 resume 한다.
2. 통과. Bash tool 이 `cd /usr` 한 동안에도 claude 프로세스(`proc_name` = `claude`, native
   binary)의 cwd 는 실행 디렉터리였다. `cd` 는 자식 `zsh` 의 cwd 만 바꾼다.
3. `codex resume [OPTIONS] [SESSION_ID] [PROMPT]`. `-m`, `-s`, `-a`, `-p`, `-c`,
   `--add-dir`, `--approve-for-me`, `--dangerously-bypass-approvals-and-sandbox` 를 받는다.
   `--full-auto` 는 없다 → §5.3 반영.
4. 통과. termy journal(`events.jsonl`)의 codex hook `session_id`(`01a11516-…`)가
   `~/.codex/sessions/…/rollout-…-01a11516-….jsonl` 의 UUID 와 같다 — `codex resume` 이
   찾는 id 다. claude hook `session_id` 도 `~/.claude/projects/<dir>/<id>.jsonl` 과 같다.
   codex 는 실행하지 않고 파일만 대조했다.
5. 통과. 새 login zsh 에 프롬프트 전(0s / 0.05s / 0.5s)에 명령을 넣어도 실행됐다. 이 Mac 의
   login zsh 는 약 0.8s 에 첫 출력, 50ms 안에 출력 끝(출력 사이 최대 38ms) → 300ms quiet
   기준으로 약 1.1s 에 입력된다.
6. 통과. 고정 버전 Sparkle 2.6.4 헤더에 `shouldPostponeRelaunchForUpdate:…untilInvokingBlock:`
   와 `updaterWillRelaunchApplication:` 이 있다.

## 10. 실제 동작 검증

개발 세션이 Ghostty 에서 돌 때는 controller 가 직접 검증한다(사용자 결정, 2026-10-10).
설치본 termy 가 hook socket 과 `session.json` 을 쓰므로, 검증 동안 설치본을 종료하고
`session.json` 을 백업했다가 되돌린다. 세션이 termy 안에서 돌면 사람이 검증한다.

1. DEBUG 빌드에서 agent 둘(하나는 작업 중, 하나는 turn 종료) + 빈 셸 pane 하나를 둔다.
2. "Debug ▸ Simulate Update Relaunch" → alert 확인 → [Wait for Agents] → 작업 중이던
   agent 의 turn 이 끝나고 2초 뒤 종료되는지 확인.
3. termy 를 다시 실행 → agent pane 두 곳에서 같은 대화가 열리고, 원래 플래그가 붙었는지
   (`ps -o args`) 확인. 빈 셸 pane 은 그대로인지 확인.
4. Sparkle 경로 전체와 postpone 동안의 Sparkle 기본 UI 는 **이 기능이 들어간 버전에서 그
   다음 버전으로** 업데이트할 때 확인한다. resume 기록과 재시작 미루기는 종료되는 쪽(이전
   버전)의 코드가 하므로, 이 기능을 처음 담은 버전으로 올리는 업데이트에서는 아직 동작하지
   않는다. 릴리스 노트에도 이 점을 적는다.

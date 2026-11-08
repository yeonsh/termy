# pi agent 지원(pane 상태 표시) — 설계 문서

- 날짜: 2026-11-08
- 상태: 승인 대기
- 범위: termy pane에서 실행한 **pi**(`@earendil-works/pi-coding-agent`)의 상태(THINK · WAIT · IDLE · ERR)와 알림을
  Claude Code · Codex · agy · opencode와 같은 방식으로 보여 준다. **설치 단계 없음**(OSC 7501만 사용).
- 선행 문서: `docs/superpowers/plans/2026-11-07-local-pane-osc7501.md`(local pane 7501 연결),
  `docs/superpowers/specs/2026-10-19-opencode-support-design.md`(다른 agent 지원 형식)

## 1. 목표와 동기

pi는 이 저장소의 작업을 실제로 돌리는 agent 중 하나다(이 세션 포함). 그런데 termy pane에서 `pi`를 띄우면
상태 칩도, 알림도, 타이틀 애니메이션도 없다. 다른 agent pane과 같은 대우를 하는 것이 목표다.

성공 기준:

- pane에서 `pi`를 실행하면 1초 안에 `IDLE` 칩이 뜬다.
- prompt를 보내면 `THINK`가 되고, extension dialog · 로그인처럼 사용자를 기다리면 `WAIT` + 알림음이 울린다.
  답하면 다시 `THINK`다.
- 정상 종료(`done`)는 `WAIT`(알림음) → 30초 뒤 `IDLE`, Esc 취소(`idle`)는 **알림 없이 `IDLE`**,
  오류(`error`)는 `ERR`.
- termy 밖(Ghostty 등)에서 띄운 pi는 termy에 아무것도 보내지 않는다.
- 사용자가 설치하거나 설정할 것이 없다. 메뉴 항목도 늘지 않는다.

## 2. 비목표(범위 밖)

- **pi extension 설치기**(`~/.pi/agent/extensions/termy.ts`). session id · cwd · prompt · 마지막 답변을 hook으로
  보내는 경로. 사용자 결정(D1)으로 다음 라운드로 미룬다.
- **업데이트 relaunch 뒤 pi 세션 재개**(`pi --session <id>`). 7501 보고에 session id가 없어 기록을 만들 수 없다.
- 알림 본문에 prompt · 마지막 assistant 메시지 넣기(위와 같은 이유).
- hc pane에서 herdr-core가 `pi` foreground를 분류하도록 하는 일 — herdr-core 몫이다. herdr-core가 `app=pi`
  status를 보내면 termy는 그대로 받는다(4.3).
- `pi --print` · `pi --mode rpc` 같은 비대화형 실행의 상태(7501 보고는 interactive mode만 한다).
- pi 안에서 띄운 중첩 agent(subagent) 상태.

## 3. 확인한 사실(2026-11-08 실측 · 소스 확인)

### 3.1 pi는 이미 OSC 7501 program status를 보고한다

`dist/modes/interactive/program-status-reporter.js`(pi 1.5.0):

| 보고 | 시점 | 비고 |
|---|---|---|
| `state=working` | agent run · compaction 진행 중 | `msg`는 세션 이름 |
| `state=blocked` | extension dialog · 로그인 대기 | `kind=permission` / `question` / `auth`, `msg`는 dialog 제목 |
| `state=done` | run 정상 종료 | `msg`는 세션 이름 |
| `state=error` | 재시도 없이 끝난 오류 | `msg`는 오류 첫 줄 |
| `state=idle` | 시작 직후, 사용자가 취소(Esc) | `msg` 없음 |

- 모든 보고에 `app=pi`가 붙는다(`APP_NAME`).
- 지원 질의는 **ST 종결**(`ESC ] 7501 ; ? ST`)이고 termy의 `ProgramStatusOSC.probeReply`는 **BEL 종결**이다. pi의
  `isProgramStatusReply` 정규식이 둘 다 받으므로 termy 답으로 보고가 시작된다(2026-11-08 소스 확인).
- 프로세스가 정상 종료할 때 `ProcessTerminal.stop()`이 `state=clear`를 보낸다(지원된 경우). **2026-11-08 정정:**
  처음 이 문서를 쓸 때 "clear를 보내지 않는다"고 적었으나 소스 확인 결과 틀렸다. termy는 `clear`를
  `applyProgramStatus(nil)`로 받아 `programStatusActive`만 끄고 상태는 `SessionEnd`/`PtyExit`가 닫는다 — 동작
  문제는 없다.
- 터미널이 지원 질의에 답한 뒤에만 보고한다(`PI_PROGRAM_STATUS=0`으로 끄거나 `1`로 강제 가능).
  termy의 `ProgramStatusOSC.probeReply`가 광고하는 `states` · `kinds` 어휘가 pi가 쓰는 값과 정확히 같다.

### 3.2 지금 pi pane에서 일어나는 일

1. `Pane.startShell`이 7501 handler를 켜지만 `accepts()`가 `localForegroundAgent() != nil`을 요구한다
   (`Pane.swift:354`). 이 값은 `ForegroundProcessWatcher.classifyAgent`의 결과다.
2. `pi`는 shebang 스크립트(`#!/usr/bin/env node`)라 libproc `proc_name`이 **`node`**, argv[0]이 **`pi`**로 온다(실측:
   pid 23766 · 68829 → `proc_name()` = `node`, `KERN_PROCARGS2` argv[0] = `pi`). 참고: 같은 프로세스도 `ps -o comm`은
   `pi`로 보여 준다(ps가 argv[0]에서 이름을 만든다) — termy는 `proc_name`을 쓰므로 전자다. 두 모양 모두 분류기가
   처리한다(4.2). `classifyAgent`는 `pi`를 모르므로
   `nil`이다.
3. 그래서 pi의 7501 보고가 **버려지고**(`status == nil || accepts()`), synthetic SessionStart도 없다.
   칩 · 알림 · 타이틀 애니메이션이 모두 꺼진 상태다.

### 3.3 agent별 지원 현황

| 기능 | Claude | Codex | agy | opencode | pi(현재) |
|---|---|---|---|---|---|
| 프로세스 감지(`classifyAgent`) | ✅ | ✅ | ✅ | ✅ | ❌ |
| 상태 소스 | hook | hook | hook | plugin | **7501 내장** |
| 상태 머신 분기 | ✅ | ✅ | ✅ | ✅ | ❌ |
| 알림 문구 agent 이름(`displayName`) | ✅ | ✅ | ✅ | ✅ | ❌ |
| 업데이트 뒤 재개 | ✅ | ✅ | ✅ | 범위 밖 | 범위 밖 |
| 설치기 | `HookInstaller` | `CodexHookInstaller` | `AntigravityHookInstaller` | `OpenCodePluginInstaller` | **없음** |

## 4. 설계

### 4.1 `AgentKind` — `.pi` 추가

```swift
case pi            // wireName "pi", displayName "Pi"
```

- `from(rawAgent:)`에 `"pi"` → `.pi`. 7501의 `app=pi`, (나중에 붙을) `termy-hook --agent pi` 둘 다 같은 값을 쓴다.
- `WorkspaceRecord`의 `agentKind` 복원은 `AgentKind(rawValue:)`라 자동으로 따라온다(모르는 값은 지금처럼 nil).

### 4.2 `ForegroundProcessWatcher` — 분류

- `classifyAgent(by:)`: `normalized == "pi"` → `.pi`. (접두사 매칭은 하지 않는다. `pi`는 짧은 이름이라
  `pi-web` 같은 무관한 바이너리를 agent로 만들고 싶지 않다.)
- `agentEntrypoint(in:)`: `basename == "pi"` 또는 `normalized.contains("@earendil-works/pi-coding-agent")` → `.pi`.
  JS 런타임(`node`/`bun`/`deno`)으로 뜬 pi가 argv[0] = `pi`로 오는 경로가 이쪽이다.
- 이 변경 하나로 synthetic `SessionStart`(agent=pi) · `SessionEnd`가 생기고, `accepts()`가 true가 되며,
  `AgentResumeCapture`가 foreground 종류를 알아본다(다만 session id가 없어 기록은 만들어지지 않는다 — 4.4).

### 4.3 `PaneStateMachine` — 상태 규칙

1. **`SessionStart` 그룹**: pi는 opencode와 같은(Claude) 그룹에 둔다 — hard reset 하지 않고
   `previous.state == .initializing`일 때만 `IDLE`로 올린다. foreground watcher의 synthetic SessionStart가
   7501 `working`보다 최대 1초 늦게 도착해도 THINK를 덮어쓰지 않아야 한다. 코드 변경은 없다(현재 else 분기).
2. **`applyProgramStatus`의 취소 규칙**: 지금 `status.state == "idle" && previous.turnOpen && status.app == "claude-code"`
   일 때만 "사용자가 취소했다"로 보고 소리 없는 `IDLE`로 닫는다. 이 앱 목록에 `"pi"`를 더한다.
   ```swift
   /// idle이 열린 turn을 닫는 것을 "사용자 취소"로 해석하는 앱. 둘 다 정상 종료는 done으로 보낸다.
   private static let idleMeansCancelApps: Set<String> = ["claude-code", "pi"]
   ```
   pi는 Esc 취소에서 `idle`을, 정상 종료에서 `done`을 보내므로 같은 해석이 맞다.
3. `blocked` → `WAITING`(kind `question`은 `askUserQuestion`, 그 외 `permission`), `working` → `THINKING`,
   `done` → `WAITING(.turnEnd)`(turn이 열려 있을 때), `error` → `ERRORED`: 기존 규칙 그대로다. 코드 변경 없음.

### 4.4 `AgentResume` · `AgentResumeFlags` — 도달 불가 분기

`AgentKind`에 case가 늘면 두 switch가 컴파일되지 않는다.

- `AgentResumeCommand.make`: `.pi` → `["pi", "--session", id]`.
- `AgentResumeFlags.extract`: `.pi` → `[:]`(flag 표는 B에서 정한다).

이 분기는 **지금 도달하지 않는다.** `AgentResumeCapture.record`가 `snapshot.lastSessionId`를 요구하는데
7501 보고에는 session id가 없다. 잘못된 명령이 실행될 위험은 없고, B를 붙일 때 그대로 살아난다.
`AgentResumeCapture`의 `kind != .opencode` 예외에 pi를 넣지는 않는다(재개 지원 의사가 없을 뿐, 막을 이유는 없다).

### 4.5 README

- 상단 문구·"What else you get"·"How it works" 그림에 pi를 더한다. pi는 설치기 없이 7501로만 붙는 유일한
  agent라, 문장에서 "hooks or plugin"과 구분해 적는다(예: "pi reports through OSC 7501, no install").
- "Synthetic PtyExit" 문단의 foreground watcher 목록에 `pi`를 더한다.

## 5. 결정 기록

- **D1 — 범위는 OSC 7501만.** 사용자 결정(2026-11-08). pi extension 설치기 · session 재개 · 알림 본문 상세는
  다음 라운드로.
- **D2 — pi는 Claude 그룹(SessionStart soft reset).** opencode와 같은 이유(7501 보고가 synthetic SessionStart보다
  먼저 올 수 있다).
- **D3 — 취소 규칙은 앱 이름 집합으로.** `status.app`에 `"pi"`를 더한다. `app`이 없는 보고는 지금처럼
  `done` 쪽 규칙을 따른다.
- **D4 — `pi --session <id>`는 지금 넣되 도달 불가로 둔다.** switch 완전성만 맞춘다.

## 6. 테스트

- `AgentKindTests`: `from(rawAgent: "pi")` → `.pi`, `wireName`/`displayName`, unknown은 그대로 nil.
- `ForegroundProcessWatcherTests`: `classifyAgent(by: "pi")` → `.pi`; `classifyAgent(processName: "node", arguments: ["pi"])`
  → `.pi`; `"piano"` · `"pi-web"` 같은 이름은 nil; `agentEntrypoint` 인덱스.
- `PaneProgramStatusTests`(app: "pi"): `working` → THINKING, `blocked(permission|question|auth)` → WAITING(+attention),
  `done` → WAITING(.turnEnd), **`idle` + 열린 turn → IDLE(알림 없음)**, `error` → ERRORED.
- `AgentResumeCommandTests`: `.pi` → `pi --session <id>`.
- 전체: 기존 테스트가 그대로 통과해야 한다(Claude 경로 회귀 없음).

## 7. 남은 것 (다음 라운드, B)

- termy 관리 pi extension(`~/.pi/agent/extensions/termy.ts`) + 설치기·메뉴·stale 재작성(opencode plugin과 같은 형식).
- `session_start`/`agent_start`/`agent_settled`/`session_shutdown`을 `termy-hook --agent pi`로 보내 session id ·
  cwd · prompt · 마지막 답변을 채우고, `AgentResumeCommand`의 pi 분기를 실제로 사용한다.
- 필요하면 `PI_CODING_AGENT` · `PI_SESSION_ID` 같은 marker를 `Pane.agentSessionMarkerEnvKeys`에 추가.

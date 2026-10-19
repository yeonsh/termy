# opencode 지원(pane 상태 표시) — 설계 문서

- 날짜: 2026-10-19
- 상태: 범위 승인(2026-10-18, 결정 D1~D3), 초안 검토 중
- 범위: termy pane에서 실행한 opencode v2 TUI의 상태(THINK · WAIT · IDLE · ERR)와 알림을 Claude Code · Codex · agy와 같은 방식으로 보여 준다
- 결정 기록(gstack decision log): `1fda879c`(첫 지원 범위), `1fde11b6`(화면에 보이는 세션만 추적), `24d7757e`(interrupted는 알림 없이 IDLE), `04f28106`(세션 전환으로 생긴 WAIT는 알리지 않음), `e79a31af`(spike는 사용자 DB + 임시 XDG config)

## 1. 목표와 동기

2026-10-18에 Homebrew `anomalyco/tap/opencode-v2` 2.0.32를 설치했고, 같은 날 termy pane 5개(ttys017 · 022 · 023 · 024 · 027)에서 opencode를 쓰고 있다. 그런데 termy는 opencode를 알아보지 못한다. 이 pane들에는 상태 칩이 없고, 권한 요청이나 질문, turn 종료가 있어도 알림음 · dock badge · 배너가 뜨지 않는다.

이 작업의 목표는 **opencode pane도 다른 agent pane처럼 지금 일하는 중인지, 사용자를 기다리는지 보여 주는 것**이다.

성공 기준:

- pane에서 `opencode`를 실행하면 1초 안에 IDLE 칩이 뜬다.
- prompt를 보내면 THINK가 되고, 권한 요청이나 question 도구가 뜨면 WAIT로 바뀌며 알림음이 울린다. 답하면 다시 THINK가 된다.
- turn이 성공하면 WAIT가 되고 알림음이 울리며, 30초 뒤 IDLE이 된다. 실패하면 ERR, 사용자가 Esc로 멈추면 알림 없이 IDLE이 된다.
- termy 밖(Ghostty 등)에서 띄운 opencode는 termy에 아무것도 보내지 않는다.
- plugin은 termy ▸ OpenCode Plugin… 메뉴에서 설치하고 해제한다.

## 2. 비목표(범위 밖)

- termy 업데이트 뒤 opencode 세션 재개(`opencode --session <id>`). opencode pane은 재개 기록을 남기지 않는다.
- 첫 실행 때 설치를 묻는 알림창. 설치 경로는 메뉴 하나뿐이다(D1).
- 뒤쪽 opencode 탭의 상태. pane은 화면에 떠 있는 root 세션만 반영한다(D2).
- opencode 서버 plugin, `/api/event` SSE 직접 구독, termy가 `ses_` id를 미리 발급하는 방식.
- `opencode run`(비대화형), 사용자가 pane에서 직접 띄운 `opencode serve`. 둘 다 IDLE 칩만 뜨고 상태는 바뀌지 않는다.
- sessionID가 `"global"`인 MCP elicitation form.
- 알림 본문에 마지막 assistant 메시지 넣기. 고정 문구만 쓴다.
- `XDG_CONFIG_HOME` · `OPENCODE_CONFIG_DIR`로 opencode 설정 폴더를 옮긴 환경. 설치기는 `~/.config/opencode`만 다룬다.
- opencode v1(npm `opencode-ai`)의 plugin API.

## 3. 현재 상태(2026-10-19 확인)

### 3.1 agent별 지원 현황

| 기능 | Claude Code | Codex | agy | opencode |
|---|---|---|---|---|
| 프로세스 감지(`ForegroundProcessWatcher.classifyAgent(by:)`, `ForegroundProcessWatcher.swift:180`) | ✅ | ✅ | ✅ | ❌ 이름 매칭 없음 |
| hook / plugin 설치기 | `HookInstaller` | `CodexHookInstaller` | `AntigravityHookInstaller` | ❌ |
| 이벤트 전달(`termy-hook --agent …`) | ✅ | ✅ | ✅ | ❌ |
| 상태 머신 분기(`PaneStateMachine.apply`, `PaneState.swift:172`) | ✅ | ✅ | ✅ | ❌ |
| 알림 문구의 agent 이름(`AgentKind.displayName`, `Notifier.swift:141`) | ✅ | ✅ | ✅ | ❌ |
| 업데이트 뒤 재개(`AgentResumeCommand.make`, `AgentResume.swift:25`) | ✅ | ✅ | ✅ | 범위 밖 |
| pane 셸 env scrub(`Pane.agentSessionMarkerEnvKeys`, `Pane.swift:230`) | ✅ | ✅ | ✅ | ❌ |

opencode pane에서 지금 일어나는 일: `classifyAgent`가 `nil`을 돌려주므로 synthetic SessionStart가 없고, 상태 칩 · 알림 · 재개 기록이 모두 없다(`AgentResumeCapture.record`는 foreground agent가 있어야 기록을 만든다, `AgentResume.swift:74`).

### 3.2 agy 방식을 그대로 쓸 수 없는 이유

agy는 `~/.gemini/config/hooks.json`에 셸 명령을 등록하고, agy가 그 명령을 pane 안의 자식 프로세스로 실행한다. 그래서 `termy-hook`이 `TERMY_PANE_ID`를 물려받는다. opencode v2에는 이 경로가 없다.

1. **셸 명령 hook이 없다.** 확장 수단은 JS/TS plugin뿐이다(https://opencode.ai/v2/docs/build/plugins/).
2. **공유 서비스의 env가 엉뚱한 pane을 가리킨다.** opencode v2 TUI는 공유 서비스 `opencode serve --service`(2026-10-18 확인: pid 47713, PPID 1, `127.0.0.1:49374`)에 붙는다. 세션 · 서버 plugin · 권한은 이 서비스가 갖는다. 서비스는 처음 자신을 띄운 pane의 env를 그대로 들고 있다(`TERMY_PANE_ID`와 `TERMY_PROJECT_ID`가 다른 프로젝트의 pane 값이었고, 그 pane은 이미 닫혀 있었다). `Service.ensure`가 클라이언트 env를 물려준 채로 서비스를 spawn하기 때문이다(`packages/client/src/service.ts`). 그래서 서버 plugin이 `process.env.TERMY_PANE_ID`를 읽으면 틀린 pane을 얻는다.
3. **cwd로 pane을 찾을 수 없다.** 같은 저장소 디렉터리 하나에 TUI 두 개(pid 65252, 98771)가 동시에 떠 있었다.

반면 **TUI plugin은 pane마다 도는 TUI 프로세스 안에서 실행된다.** 그래서 `process.env.TERMY_PANE_ID`가 정확하고, 그 TUI가 화면에 띄운 세션도 안다. 이 설계는 TUI plugin을 쓴다.

### 3.3 opencode v2 TUI plugin API(소스 `anomalyco/opencode` 태그 `v2.0.32`, commit 843a6c5)

| 필요한 것 | API | 출처 |
|---|---|---|
| plugin 형식 | `export default { id: string, setup(ctx) → cleanup? }` | `packages/plugin/src/tui/plugin.ts`, `packages/tui/src/plugin/context.tsx:694,741` |
| global 자동 탐색 | `~/.config/opencode/plugins/<dir>/`, entry 파일은 `tui` | `packages/tui/src/plugin/discovery.ts`, `packages/plugin/src/host.ts:43` |
| 파일 변경 시 다시 로드 | plugin 소스를 watch | `packages/tui/src/plugin/watch.ts` |
| 화면에 떠 있는 세션 | `ctx.ui.router.current()` → `{type:"session", sessionID}` \| `{type:"home"}` \| `{type:"plugin",…}` | `packages/plugin/src/tui/context.ts:142,499` |
| 세션 계보 | `ctx.data.session.root(id)`, `ctx.data.session.family(id)` | `context.ts:63-75` |
| 실행 중 여부 | `ctx.data.session.status(id)` → `"idle"` \| `"running"`, `ctx.data.session.pending.list(id)` | `context.ts:75-80` |
| 권한 · 질문 대기 | `ctx.data.session.permission.list(id)`, `ctx.data.session.form.list(id)` | `context.ts:88-99` |
| 이벤트 | `ctx.data.on(type, handler)`, `ctx.data.listen(handler)` | `context.ts:64-68` |
| 세션 디렉터리 | `ctx.data.session.get(id)?.location?.directory` | `packages/schema/src/session.ts:53` |

opencode 자체 탭 표시도 같은 값을 쓴다(`packages/tui/src/context/session-tabs.tsx:164-173`). family 중 하나라도 permission이 걸려 있으면 `"permission"`, form이 걸려 있으면 `"question"`, 하나라도 running이거나 synthetic이 아닌 pending이 있으면 busy다.

turn이 끝난 이유는 store의 `SessionInfo.outcome` 필드가 아니라 이벤트에서 받아야 한다. data store는 `session.execution.succeeded|failed|interrupted`를 받으면 status를 `idle`로 바꾸고 outcome을 **idle 메시지**로만 넣는다(`packages/client/src/solid/data.ts:1068-1088`). `SessionInfo.outcome`은 이 시점에 갱신되지 않을 수 있다.

## 4. 설계

### 4.1 전체 구조

```
pane (TERMY_PANE_ID=P)
 └─ opencode TUI ──────────────────────── 공유 서비스 opencode serve --service
     └─ termy TUI plugin (tui.js)              (세션 실행, 권한, form)
          │ data store를 읽어 phase 계산
          │ phase가 바뀌면
          ▼
     termy-hook --agent opencode AgentStatus   (stdin: {"reason","session_id","cwd"})
          │ /tmp/termy-$UID.sock
          ▼
     HookDaemon → PaneStateMachine(.agentStatus) → Notifier · 대시보드
```

`ForegroundProcessWatcher`는 지금처럼 1초마다 foreground 프로세스를 보고, `opencode`가 들어오고 나갈 때 synthetic SessionStart · SessionEnd를 만든다.

### 4.2 TUI plugin(`apps/termy/Resources/opencode-plugin/tui.js`)

ESM 자바스크립트 파일 하나다. 외부 의존성은 `node:child_process`뿐이고 TypeScript · 빌드 단계는 없다.

**동작 규칙**

1. `setup` 첫 줄에서 `process.env.TERMY_PANE_ID`가 없으면 바로 return한다. 타이머도 구독도 만들지 않는다.
2. phase는 이벤트를 하나씩 따라가지 않고 data store에서 그때그때 계산한다(level-triggered). 동시에 걸린 permission 두 개 중 하나만 답한 경우에도 그래서 phase가 틀어지지 않는다.
3. 계산 시점은 두 가지다. `ctx.data.listen`으로 이벤트를 받을 때마다 `setTimeout(…, 0)`으로 한 번 모아서 계산한다. 그리고 1초마다 계산한다. 라우트 전환(탭 이동, home으로 가기)은 서버 이벤트를 만들지 않아서 1초 타이머가 잡는다.
4. 대상은 `ui.router.current()`가 가리키는 세션의 root 하나다(D2). 라우트가 `session`이 아니면 phase는 `idle`이고 session id는 없다.
5. turn 종료 이유는 `ctx.data.on("session.execution.succeeded" | "failed" | "interrupted")` 핸들러에서 root 세션(`root(id) === id`)에 대해 Map에 적어 두고, `session.execution.started`에서 지운다. 같은 이벤트 dispatch 안에서 핸들러가 먼저 돌고 계산은 `setTimeout(0)` 뒤에 돌기 때문에, running → idle을 계산할 때 이유가 이미 적혀 있다.
6. phase가 바뀔 때만 보낸다. 보내는 일은 직렬화한다. 앞 `termy-hook` 프로세스가 끝나야(또는 2초 timeout) 다음 프로세스를 띄운다. 두 프로세스를 동시에 띄우면 socket 도착 순서가 바뀔 수 있기 때문이다.
7. 모든 코드는 try/catch로 감싼다. spawn 실패, `termy-hook` 없음, socket 없음은 조용히 무시한다. plugin 오류가 opencode를 막아서는 안 된다.
8. 파일 첫 줄은 termy 표식 주석이다. 설치기가 이 줄로 termy가 쓴 파일인지 판단한다.

**pure 영역**(XCTest가 JavaScriptCore로 평가한다, §8)

```js
// #region termy-pure
// Phase of the routed root session. Same precedence as opencode's own tab
// badge (packages/tui/src/context/session-tabs.tsx:164-173).
function termyPhase(view) {
  if (!view.sessionID) return "idle"
  if (view.permission) return "permission"
  if (view.question) return "question"
  if (view.busy) return "running"
  return "idle"
}

// Wire reason to send when the phase moves from prev to cur, or null.
// prev/cur: { sessionID: string | null, phase }. outcome: the last
// execution outcome recorded for cur.sessionID, if any.
function termyEmission(prev, cur, outcome) {
  if (prev && prev.sessionID === cur.sessionID && prev.phase === cur.phase) return null
  if (cur.phase !== "idle") return cur.phase
  const wasActive = prev && prev.sessionID === cur.sessionID && prev.phase !== "idle"
  if (wasActive && outcome === "succeeded") return "succeeded"
  if (wasActive && outcome === "failed") return "failed"
  return "idle"
}

// What the routed root session looks like right now. Reads only the plugin
// context, so tests can pass a fake ctx.
// gstack-shortcut(dec-1fde11b6): routed root session only, background tabs ignored; upgrade when users report missed background-tab prompts
function termyView(ctx) {
  const route = ctx.ui.router.current()
  if (route.type !== "session") return { sessionID: null }
  const root = ctx.data.session.root(route.sessionID)
  const ids = [...new Set([root, ...ctx.data.session.family(root)])]
  return {
    sessionID: root,
    permission: ids.some((id) => (ctx.data.session.permission.list(id)?.length ?? 0) > 0),
    question: ids.some((id) => (ctx.data.session.form.list(id)?.length ?? 0) > 0),
    busy: ids.some((id) =>
      ctx.data.session.status(id) === "running" ||
      ctx.data.session.pending.list(id).some((item) => item.type !== "synthetic")),
    cwd: ctx.data.session.get(root)?.location?.directory,
  }
}

// stdin JSON for termy-hook. termy-hook reads stdin with one
// availableData call, so the payload stays below PIPE_BUF (512 bytes):
// cwd is dropped when keeping it would pass 480 bytes.
function termyPayload(reason, view, fallbackCwd) {
  const base = { reason, ...(view.sessionID ? { session_id: view.sessionID } : {}) }
  const full = JSON.stringify({ ...base, cwd: view.cwd ?? fallbackCwd })
  return termyUtf8Length(full) <= 480 ? full : JSON.stringify(base)
}

function termyUtf8Length(text) {
  return unescape(encodeURIComponent(text)).length
}
// #endregion termy-pure
```

`termyEmission`의 결과:

| prev | cur | outcome | 보내는 reason |
|---|---|---|---|
| 없음(plugin 시작) | 무엇이든 | — | cur.phase(시작 시 동기화) |
| `{S, running}` | `{S, permission}` | — | `permission` |
| `{S, permission}` | `{S, running}` | — | `running` |
| `{S, running}` | `{S, idle}` | `succeeded` | `succeeded` |
| `{S, running}` | `{S, idle}` | `failed` | `failed` |
| `{S, running}` | `{S, idle}` | `interrupted` 또는 없음 | `idle` |
| `{S, idle}` | `{T, running}` | — | `running`(세션 전환) |
| `{S, running}` | `{null, idle}`(home으로 이동) | — | `idle` |
| `{S, idle}` | `{S, idle}` | — | 보내지 않음 |

**glue 영역**(pure 영역 아래, 그대로 구현한다)

```js
// termy-managed opencode plugin. termy rewrites this file; do not edit.
import { spawn } from "node:child_process"

const TERMY_HOOK_PATH = "__TERMY_HOOK_PATH__"

// (termy-pure region here)

export default {
  id: "termy",
  setup(ctx) {
    if (!process.env.TERMY_PANE_ID) return
    const outcomes = new Map()
    let prev = null
    let scheduled = false
    let queue = Promise.resolve()

    const send = (reason, v) => {
      const payload = termyPayload(reason, v, process.cwd())
      queue = queue.then(() => new Promise((resolve) => {
        try {
          const child = spawn(TERMY_HOOK_PATH, ["--agent", "opencode", "AgentStatus"], {
            stdio: ["pipe", "ignore", "ignore"],
          })
          const timer = setTimeout(resolve, 2000)
          const done = () => { clearTimeout(timer); resolve() }
          child.on("error", done)
          child.on("exit", done)
          child.stdin.on("error", () => {})
          child.stdin.end(payload)
        } catch { resolve() }
      }))
    }

    const derive = () => {
      scheduled = false
      try {
        const v = termyView(ctx)
        const cur = { sessionID: v.sessionID, phase: termyPhase(v) }
        const reason = termyEmission(prev, cur, cur.sessionID ? outcomes.get(cur.sessionID) : undefined)
        prev = cur
        if (reason) send(reason, v)
      } catch {}
    }
    const schedule = () => {
      if (scheduled) return
      scheduled = true
      setTimeout(derive, 0)
    }
    const record = (outcome) => (event) => {
      try {
        const id = event.data.sessionID
        if (ctx.data.session.root(id) === id) outcomes.set(id, outcome)
      } catch {}
    }

    const offs = [
      ctx.data.on("session.execution.started", (event) => { outcomes.delete(event.data.sessionID) }),
      ctx.data.on("session.execution.succeeded", record("succeeded")),
      ctx.data.on("session.execution.failed", record("failed")),
      ctx.data.on("session.execution.interrupted", record("interrupted")),
      ctx.data.listen(schedule),
    ]
    const interval = setInterval(schedule, 1000)
    schedule()
    return () => {
      clearInterval(interval)
      for (const off of offs) off()
    }
  },
}
```

`__TERMY_HOOK_PATH__` 자리(따옴표 포함)는 설치기가 JSON 문자열 리터럴로 바꾼다(§4.6).

### 4.3 wire 형식

plugin은 기존 `termy-hook`을 그대로 쓴다. socket 기록 · 100ms deadline · 실패 로그(`/tmp/termy-hook-debug.log`)가 이미 있고, wire 형식을 만드는 곳이 한 군데로 유지된다.

- 호출: `"<termy.app>/Contents/Resources/termy-hook" --agent opencode AgentStatus`
- stdin: `{"reason":"running","session_id":"ses_…","cwd":"/abs/path"}`(`session_id`는 라우트가 세션일 때만)
- `HookCLI.parse`는 모르는 `--agent` 값을 그대로 넘기므로(`HookCLI.swift:60`) wire `agent`는 `"opencode"`가 된다. `reason` · `session_id` · `cwd`는 이미 `forwardedKeys`에 있다(`HookCLI.swift:23`). **`termy-hook` 코드는 바꾸지 않는다.** 주석의 사용 예와 테스트만 추가한다.
- `HookEventKind`에 `case agentStatus = "AgentStatus"`를 추가한다(`HookEvent.swift:16-31`). 지금은 opencode plugin만 보낸다.
- reason 어휘: `idle` · `running` · `permission` · `question` · `succeeded` · `failed`. 모르는 값은 상태를 바꾸지 않는다(새 plugin과 옛 termy가 섞여도 안전).

### 4.4 상태 머신(`PaneStateMachine.apply`, `PaneState.swift:172`)

`.agentStatus` case 하나를 추가한다. agent 종류로 분기하지 않는다. 세션 id가 바뀌면 기존 규칙(`PaneState.swift:192-200`)이 먼저 INIT으로 초기화하고, 그다음 아래 표를 적용한다.

| reason | state | needsAttention | notificationReason | waitSource | turnOpen | enteredStateAt |
|---|---|---|---|---|---|---|
| `running` | `.thinking` | false | nil | nil | true | state가 바뀔 때만 |
| `permission` | `.waiting` | true | `"permission"` | nil | true | 이전이 WAIT(`"permission"`)가 아닐 때만 |
| `question` | `.waiting` | true | `"ask_user_question"` | nil | true | 이전이 WAIT(`"ask_user_question"`)가 아닐 때만 |
| `succeeded` | `.waiting` | false | nil | nil | false | 이전이 `.waiting`이 아닐 때만 |
| `failed` | `.errored` | false | nil | nil | false | state가 바뀔 때만 |
| `idle` | `.idle` | false | nil | nil | false | state가 바뀔 때만 |
| 그 밖 | 그대로 | 그대로 | 그대로 | 그대로 | 그대로 | 그대로 |

표의 "이전"과 "바뀔 때"는 세션 id 변경 리셋(`PaneState.swift:192-200`)이 적용된 **뒤의** 상태를 기준으로 한다. 알려진 reason이면 state · needsAttention · notificationReason · waitSource · turnOpen은 항상 표의 값으로 쓰고, enteredStateAt만 조건에 따라 바꾼다. 세션 A가 WAIT(`"permission"`)인 pane에 세션 B의 `permission`이 오면, 리셋 뒤 INIT에서 다시 WAIT로 들어가 needsAttention이 true가 된다. 이 경우 알림음은 울리지 않는다(아래 "세션 전환으로 생긴 WAIT").

이 표를 따르면 기존 부품이 그대로 동작한다.

- 알림음 · dock bounce · 배너: `Notifier`는 WAITING에 **들어갈 때만** 울린다(`Notifier.swift:72`). permission · question · succeeded가 여기에 해당하고, permission → question처럼 WAIT 안에서 이유만 바뀌면 다시 울리지 않는다. 세션 전환으로 생긴 WAIT는 예외다(아래).
- 30초 뒤 IDLE: `HookDaemon.tickIdle`은 `needsAttention == false`인 WAIT만 IDLE로 바꾼다(`HookDaemon.swift:507-535`). succeeded만 해당하고, permission · question은 답할 때까지 WAIT로 남는다.
- 알림 문구(`Notifier.swift:145-173`, `displayName == "OpenCode"`): permission은 "Waiting for your approval.", question은 "OpenCode is asking a question.", succeeded는 "OpenCode is waiting for your response."
- waitSource는 Codex 전용 규칙(`PaneState.swift:285-292`)을 지켜 nil로 둔다.

**세션 전환으로 생긴 WAIT**(2026-10-19 결정): 사용자가 opencode 탭이나 세션을 바꿔 기다리는 중인 세션으로 옮겨 가면, pane은 WAIT를 보여 주지만 알림음 · dock bounce · 배너는 내지 않는다. opencode에서 세션이 바뀌는 경로는 모두 사용자 조작이다(`packages/tui/src/context/session-tabs.tsx`의 `select` · `close` · `cycle` · `cycleUnread` · `selectIndex`. 스스로 전환하는 경로는 없음). 사용자는 이미 그 pane을 보고 있다.

이 규칙이 필요한 이유: `HookDaemon.ingest`는 `PaneStateMachine.apply`의 최종 snapshot 하나만 내보낸다(`HookDaemon.swift:447-452`). `Notifier`는 직전 state만 기억한다(`Notifier.swift:34,57-58`). 그래서 지금 그대로 두면 이전 상태가 IDLE · THINK일 때는 울리고, WAIT일 때는 울리지 않는다.

규칙: `Notifier`가 pane마다 `(state, sessionId)`를 기억하고, 다음 조건을 모두 만족할 때만 알린다.

1. 새 state가 `.waiting`이다.
2. 직전 state가 `.waiting`이 아니다.
3. 직전과 새 session id가 **둘 다 있고 서로 다른** 경우가 아니다.

판정은 순수 함수(`WaitAlertRule.shouldAlert`)로 분리해 테스트한다. 규칙은 agent 종류로 분기하지 않는다. Claude · Codex · agy에서는 새 세션이 보통 SessionStart로 먼저 들어오고, SessionStart는 WAIT를 만들지 않는다(`PaneState.swift:209-233`). 그래서 이 조건에 걸리는 경우는 SessionStart 없이 다른 id의 이벤트가 곧바로 WAIT를 만들 때뿐이다. 그런 경우가 있는지는 확인하지 않았다. 생기더라도 결과는 알림음 하나가 빠지는 것이고, pane은 WAIT와 needsAttention을 그대로 보여 준다. dock badge 개수(`waitingPaneIds`)는 이 규칙과 무관하게 지금처럼 센다.

**SessionStart**: opencode의 SessionStart는 `ForegroundProcessWatcher`가 만드는 synthetic 이벤트뿐이다. Codex · agy처럼 무조건 IDLE로 초기화하는 그룹(`PaneState.swift:224`)에는 **넣지 않고** Claude처럼 INIT일 때만 IDLE로 올린다. `opencode -c --prompt …`처럼 바로 일을 시작하면 plugin의 `running`이 watcher의 synthetic SessionStart(최대 1초 늦음)보다 먼저 도착할 수 있다. 이때 무조건 초기화하면 THINK가 IDLE로 덮인다. plugin이 시작할 때 현재 phase를 한 번 보내므로(§4.2 표 첫 줄) 오래된 칩은 그쪽에서 정리된다.

turn이 열려 있는 동안(`turnOpen`)에는 기존 규칙대로 업데이트 재시작이 미뤄진다(`PaneSnapshot.isMidTurn`, `PaneState.swift:151`). 다른 agent와 같은 동작이다.

### 4.5 AgentKind와 프로세스 감지

- `AgentKind`에 `case opencode`를 추가한다(`AgentKind.swift:15-19`). `wireName == "opencode"`, `displayName == "OpenCode"`, `from(rawAgent: "opencode") == .opencode`.
- `ForegroundProcessWatcher.classifyAgent(by:)`(`ForegroundProcessWatcher.swift:180`)와 `agentEntrypoint(in:)`(`:211`)에 `opencode`, `opencode-*`를 추가한다. Homebrew 설치본은 Mach-O 단일 바이너리이고 comm은 `opencode`다(2026-10-18 `ps` 확인). 파일 첫 주석의 agent 목록도 고친다.
- Codex 전용 부품(`CodexForegroundReconciler`, `recordPtyActivity`)은 opencode에 적용하지 않는다. opencode는 turn 종료를 이벤트로 알려 주므로 침묵 추정이 필요 없다.

### 4.6 설치기(`apps/termy/Sources/OpenCodePluginInstaller.swift`)

`AntigravityHookInstaller` 구조를 따르되, 남의 설정 파일에 병합하지 않고 termy 전용 파일 하나를 통째로 쓴다.

- 템플릿: 앱 번들의 `Contents/Resources/opencode-plugin/tui.js`
- 설치 위치: `~/.config/opencode/plugins/termy/tui.js`(opencode가 자동으로 찾는 위치라서 `opencode.json`은 건드리지 않는다)
- 설치 내용: `pluginSource(template:hookPath:)`가 템플릿의 `"__TERMY_HOOK_PATH__"`를 `bundledHookURL.path`의 JSON 문자열 리터럴로 바꾼 결과. pure 함수라 테스트할 수 있다.
- 상태:

  | State | 조건 |
  |---|---|
  | `notInstalled` | `tui.js` 없음 |
  | `installedCurrent` | 파일 내용이 `pluginSource(…)` 결과와 바이트 단위로 같음 |
  | `installedStale` | 첫 줄이 termy 표식인데 내용이 다름(termy 버전이 바뀌었거나 앱이 옮겨짐) |
  | `foreign` | 파일이 있는데 첫 줄이 termy 표식이 아님. 쓰지도 지우지도 않는다 |
  | `configError` | 설치된 파일이나 번들 템플릿을 읽지 못함, 또는 템플릿에 placeholder가 정확히 한 번 있지 않음 |

- 실행 시(`AppDelegate.swift:98-101` 옆): `refreshIfInstalled()`. `installedStale`이면 조용히 다시 쓰고, 나머지 상태에서는 아무것도 하지 않는다. **알림창을 띄우지 않는다**(D1).
- 메뉴: `Antigravity Hooks…` 아래에 `OpenCode Plugin…`(`AppDelegate.swift:464-469` 패턴). `showPromptFromMenu()`는 agy의 같은 함수(`AntigravityHookInstaller.swift:203-253`)와 같은 네 갈래 알림창이다. `foreign`일 때는 "termy가 만들지 않은 파일이 있어 건드리지 않는다"고 경로와 함께 알린다.
- 쓰기: 디렉터리를 만들고 `.atomic`으로 쓴다. termy 전용 파일이라 백업은 만들지 않는다.
- 해제: termy 표식이 있는 `tui.js`만 지우고, `termy` 디렉터리가 비었으면 디렉터리도 지운다.
- opencode가 plugin 폴더를 watch하므로 설치 · 갱신 · 해제는 이미 떠 있는 TUI에 바로 반영된다(§6 S6에서 확인).
- `project.yml`: `termy` target `sources`에 `apps/termy/Resources/opencode-plugin`을 `type: folder`, `buildPhase: resources`로 추가한다. 고친 뒤 `xcodegen generate`를 실행한다.

### 4.7 그 밖의 변경

- **재개 제외**: `AgentResumeCapture.record`(`AgentResume.swift:68`)는 `kind == .opencode`면 nil을 돌려준다. switch를 빠짐없이 채우기 위해 `AgentResumeCommand.make`에는 `.opencode: ["opencode", "--session", id] + flags`를, `AgentResumeFlags.extract`(`AgentResumeFlags.swift:64`)에는 빈 표를 둔다. 재개를 켜는 후속 작업은 guard 한 줄을 지우는 것에서 시작한다.
- **env scrub**: `Pane.agentSessionMarkerEnvKeys`(`Pane.swift:230-245`)에 `OPENCODE_TERMINAL`, `OPENCODE_SESSION_ID`를 추가한다. opencode가 셸 도구 자식에게 넣는 표식이다(`packages/core/src/shell.ts:271`, `packages/core/src/tool/plugin/shell.ts:216`). opencode 안에서 termy를 띄웠을 때 pane 셸로 새지 않게 한다. 사용자가 일부러 설정하는 `OPENCODE_SERVER_PASSWORD` · `OPENCODE_CONFIG_DIR` 같은 값은 지우지 않는다.
- **CHANGELOG**: `## Unreleased`에 사용자 관점 항목 하나를 쓴다(opencode pane 상태 · 알림, termy ▸ OpenCode Plugin… 메뉴).

## 5. 실패 모드와 대응

| 상황 | 결과 | 대응 |
|---|---|---|
| plugin 미설치 | opencode pane은 IDLE 칩만 뜨고 바뀌지 않음 | 메뉴에서 설치 |
| termy 밖 터미널의 opencode | plugin이 즉시 return, 아무것도 보내지 않음 | 설계상 정상 |
| termy가 꺼져 있음 | `termy-hook`이 connect 실패를 `/tmp/termy-hook-debug.log`에 남기고 종료 | 정상. termy를 켜도 phase가 바뀔 때까지는 IDLE |
| termy.app을 옮기거나 지움 | 설치된 plugin의 경로가 틀려 spawn 실패(조용히 무시) | 다음 실행 때 `installedStale`로 판정해 다시 씀. 지웠다면 수동 해제 |
| plugin 코드 오류 | opencode는 경고를 남기고 이전 세대를 유지하거나 plugin 없이 동작(`packages/tui/src/plugin/context.tsx`) | 기능만 꺼짐. opencode 작업은 계속 |
| 공유 서비스 연결이 끊긴 동안 turn 종료 | 재연결 뒤 status가 idle로 맞춰지지만 종료 이벤트가 없어 reason은 `idle`(알림 없음) | 받아들임 |
| 뒤쪽 탭에서 권한 대기 | pane은 앞쪽 탭 상태만 보여 줌 | D2로 받아들임. opencode 자체 탭 badge가 표시 |
| 같은 세션을 두 pane에서 엶 | 두 pane 모두 같은 상태를 보여 줌 | 정상 |
| opencode가 plugin API를 바꿈(2.0.32 이후) | plugin이 예외를 삼키고 아무것도 보내지 않음 | spike 체크리스트(§6)를 새 버전으로 다시 돌림 |

## 6. 사전 확인(spike) — 구현 전 gate

아래는 소스로만 확인했고 실행으로는 확인하지 않았다. 구현 계획의 첫 태스크로 확인하고 결과를 이 절에 적는다. 사용자의 공유 서비스와 설정 폴더를 건드리지 않도록 `--standalone`과 임시 `XDG_CONFIG_HOME`을 쓴다. plugin은 임시 config의 **global plugin 위치**(`$XDG_CONFIG_HOME/opencode/plugins/<dir>/tui.js`)에 둔다. 설치기가 쓰는 `~/.config/opencode/plugins/termy/tui.js`와 같은 탐색 경로를 검증하기 위해서다. tmux 세션에서 실행하고 로그는 파일로 남긴다.

opencode DB는 사용자 것을 그대로 쓴다(2026-10-19 결정). 임시 `OPENCODE_DB`를 쓰면 DB에 저장된 provider 인증(DeepSeek)이 사라지고, 최근 model이 `deepseek/deepseek-flash`라서 첫 prompt가 실패한다(`--standalone` + 임시 DB의 `auth list`로 확인). spike는 평소 model로 짧은 prompt를 몇 번 보내고, spike 세션은 끝날 때 `opencode session delete`로 지운다.

| # | 확인할 것 | 통과 조건 |
|---|---|---|
| S1 | global plugin 위치의 `tui.js`가 탐색되고, TUI에서 로드되어 `setup`이 실행됨 | `opencode plugin list`에 그 경로가 나오고, 로그 파일에 setup 줄이 남음 |
| S2 | plugin 안에서 `process.env.TERMY_PANE_ID`가 보임 | 실행 때 준 값과 같음 |
| S3 | `node:child_process.spawn`으로 실행한 자식이 stdin JSON을 받음. 없는 경로를 spawn해도 예외가 밖으로 나가지 않고, 직렬 queue의 다음 spawn이 순서대로 실행됨 | 자식(`/bin/sh -c 'cat >> log'`)이 JSON 한 줄을 남김. 없는 경로 spawn 뒤 queue에 넣은 세 자식이 1 · 2 · 3 순서로 기록함 |
| S4 | prompt 한 번 동안 `router.current()`가 session을 가리키고, status가 running → idle로 바뀌며, `session.execution.succeeded` 핸들러가 `setTimeout(0)` 계산보다 먼저 실행됨 | 로그 순서로 확인 |
| S5 | 권한 대화상자가 떠 있는 동안 `permission.list`가, question 도구가 떠 있는 동안 `form.list`가 비어 있지 않음 | 로그로 확인 |
| S6 | 실행 중인 TUI에서 plugin 파일을 고치면 cleanup 뒤 setup이 다시 실행됨 | 로그로 확인 |

판정: S1~S3 중 하나라도 실패하면 구현을 멈추고 보고한다(서버 plugin이나 SSE 방식으로 다시 설계해야 함). S4에서 종료 이벤트가 계산보다 늦게 오면, 종료 이벤트 핸들러 안에서도 `schedule()`을 부르도록 바꾸고 그 사실을 이 절에 적는다. S5 · S6 실패는 해당 기능을 범위 밖으로 옮기고 이 문서에 적는다.

### 결과(2026-10-19, opencode v2.0.32)

임시 `XDG_CONFIG_HOME=/tmp/termy-oc-spike/config`와 `--standalone`으로 tmux(`oc-spike`)에서 확인했다. 사용자 DB는 그대로 썼고, spike 세션(`ses_eae7f6094ffeY72bscwPGnTr9b`)은 확인 뒤 지웠다.

| # | 결과 | 근거 |
|---|---|---|
| S1 | 통과 | `opencode plugin list`의 `SOURCE`에 `/tmp/termy-oc-spike/config/opencode/plugins/termy-spike`가 나왔고, TUI 기동 뒤 `log.jsonl` 첫 줄이 `{"t":"setup",…}`였다. |
| S2 | 통과 | setup 줄의 `"pane":"spike-pane"`이 `env TERMY_PANE_ID=spike-pane`과 같았다. |
| S3 | 통과 | `spawn.log`에 `{"hello":1}`이 남았고, 없는 경로 spawn은 `{"t":"missing-error","e":"Error: ENOENT…"}`로만 기록되며 예외가 나가지 않았다. 직렬 queue의 세 자식은 `order.log`에 `1`, `2`, `3` 순서로 남았다. |
| S4 | 통과 | prompt 한 번에 `started`(seq 2) → status `running` view(seq 3) → `succeeded`(seq 14) → status `idle` view(seq 15) 순서였고, 같은 이벤트(`session.execution.succeeded`)의 exec 줄이 미룬 view 줄보다 먼저였다. route는 `{"type":"session","sessionID":"ses_…"}`였다. 종료 이벤트가 계산보다 늦지 않아 glue에 `schedule()`을 더 넣지 않았다. |
| S5 | 통과 | 권한 창이 떠 있는 동안 `permission.list`가 1, 승인 뒤 0이었다. question 도구가 떠 있는 동안 `form.list`가 1, 답한 뒤 0이었다. Esc는 TUI가 "esc again to interrupt"를 요구해 두 번 눌렀고, `session.execution.interrupted`가 `reason:"user"`로 왔다. |
| S6 | 통과 | TUI가 떠 있는 채로 `tui.js` 끝에 빈 줄을 더하자 `{"t":"cleanup"}` 다음 `{"t":"setup"}`이 다시 찍혔다. |

추가 관찰: plugin이 로드된 직후에는 data store 이벤트가 없어 `ctx.data.listen`이 불리지 않았다. glue의 시작 시 `schedule()`이 현재 phase를 한 번 보내므로 문제되지 않는다. `process.cwd()`는 symlink가 풀린 `/private/tmp/…`로 보였다(payload의 cwd로만 쓰인다).

## 7. 수용 기준

1. `AgentKind.from(rawAgent: "opencode") == .opencode`, `wireName == "opencode"`, `displayName == "OpenCode"`.
2. `classifyAgent(by:)`가 `"opencode"`, `"opencode-dev"`, `"OpenCode"`에 `.opencode`를, `"opencoder"`에 nil을 돌려준다.
3. `HookEvent`가 `{"event":"AgentStatus","agent":"opencode","meta":{"reason":"running","session_id":"ses_x"}}`를 디코드하고 `agentKind == .opencode`다.
4. §4.4 표의 여섯 reason이 각각 표대로 state · needsAttention · notificationReason · waitSource · turnOpen을 만든다. 모르는 reason은 snapshot을 바꾸지 않는다(updatedAt 제외).
5. WAIT(`"permission"`)에 `permission`이 또 오면 enteredStateAt이 바뀌지 않는다. WAIT에 `succeeded`가 또 와도 마찬가지다.
6. session_id가 다른 `running`이 오면 상태가 INIT으로 초기화된 뒤 THINK가 되고 `lastSessionId`가 새 id가 된다.
7. opencode pane에서 synthetic SessionStart는 INIT만 IDLE로 올리고, THINK인 pane은 THINK로 둔다.
8. `termyPhase` · `termyEmission`이 §4.2 표의 아홉 줄을 모두 만족한다. `termyView`는 자식 세션의 permission, synthetic이 아닌 pending, session이 아닌 라우트를 반영하고, `termyPayload`는 480바이트를 넘으면 cwd를 뺀다(모두 JavaScriptCore로 평가).
9. `pluginSource(template:hookPath:)`의 결과에 placeholder가 남지 않고, 따옴표 · 공백 · 역슬래시가 들어간 경로도 올바른 JS 문자열 리터럴이 된다.
10. 설치기가 §4.6 상태 표의 다섯 상태를 정확히 판정한다. `foreign` 파일은 install · uninstall 모두 내용을 바꾸지 않는다.
11. uninstall은 `tui.js`를 지우고, 빈 `termy` 디렉터리를 지우며, 같은 폴더의 다른 파일은 남긴다.
12. `AgentResumeCapture.record`는 opencode foreground + session id가 있어도 nil을 돌려준다.
13. `Pane.shellEnvironment`가 `OPENCODE_TERMINAL` · `OPENCODE_SESSION_ID`를 지우고 `OPENCODE_CONFIG_DIR`은 남긴다.
14. §6의 S1~S6 결과가 이 문서에 적혀 있다.
15. 실제 termy 빌드에서 수동 확인(구현 계획 마지막 태스크): opencode 실행 → IDLE, prompt → THINK, 권한 요청 → WAIT + 알림음, 승인 → THINK, 완료 → WAIT + 알림음 → 30초 뒤 IDLE, Esc 중단 → 알림 없이 IDLE, 기다리는 탭으로 전환 → WAIT이지만 알림음 없음, termy 밖 터미널의 opencode → termy 변화 없음.
16. §8 표의 각 행(테스트 class 또는 class 안의 opencode 구역)은 머리 주석에 그 행의 card(`protects` / `fails_when` / `no_claim`)를 적는다. 행의 card와 다른 것을 지키는 테스트에만 개별 card를 붙인다.
17. 기존 테스트가 모두 통과한다(`xcodebuild test`, 전체 suite).
18. `WaitAlertRule.shouldAlert`는 (a) 같은 세션에서 WAIT로 들어오면 true, (b) 이미 WAIT면 false, (c) 직전 id와 새 id가 둘 다 있고 다르면 false, (d) 직전 id가 없으면(첫 이벤트, agent 전환 뒤) true다. `Notifier.handle`은 알림음 · dock bounce · 배너를 이 함수가 true일 때만 낸다.

## 8. 테스트 계획

| 층 | 무엇 | 위치 | 개수 |
|---|---|---|---|
| Unit | `AgentKind` opencode 매핑 | `apps/termy-tests/Sources/AgentKindTests.swift` | +2 |
| Unit | `AgentStatus` 디코드, reason 여섯 개 + 모르는 값, 중복 시 enteredStateAt 유지, permission 뒤 question, 세션 전환, synthetic SessionStart | `AgentKindTests.swift` | +12 |
| Unit | 프로세스 이름 · argv 감지 | `ForegroundProcessWatcherTests.swift` | +2 |
| Unit | `--agent opencode` 파싱, payload slim | `HookCLITests.swift` | +2 |
| Unit | 재개 제외 | `AgentResumeCaptureTests.swift` | +1 |
| Unit | `make` opencode 명령 | `AgentResumeCommandTests.swift` | +1 |
| Unit | env scrub | `PaneShellEnvironmentTests.swift` | +1 |
| Unit | 알림 판정 `WaitAlertRule.shouldAlert` | `NotifierWaitAlertRuleTests.swift`(신규) | +4 |
| Unit | 설치기 상태 다섯 개 · install · uninstall · foreign · 경로 escape | `OpenCodePluginInstallerTests.swift`(신규) | +9 |
| Unit | plugin 템플릿 형식, pure 영역(JavaScriptCore) | `OpenCodePluginScriptTests.swift`(신규) | +12 |
| Integration | spike S1~S6(tmux, standalone, 임시 XDG config) | 수동 스크립트, 결과는 §6 | 6 체크 |
| Integration | 실제 plugin + fake hook, spawn 실패 뒤 복구 포함 | 구현 계획 Task 4 Step 7 | 6 체크 |
| E2E | 수용 기준 15번 | 사용자 수동 확인 | 9 체크 |

행별 card(수용 기준 16):

| 행 | protects | fails_when | no_claim |
|---|---|---|---|
| AgentKind 매핑 | wire 문자열 ↔ `.opencode` 대응, 표시 이름 | 다른 kind로 매핑되거나 이름이 다름 | 실제 opencode가 그 문자열을 보내는지(plugin이 정함) |
| AgentStatus 상태 머신 | §4.4 표의 전이와 enteredStateAt 규칙 | 표와 다른 state · 필드, 중복 이벤트에 enteredStateAt이 바뀜 | plugin이 그 reason을 언제 보내는지(S4 · S5, Task 4 Step 7) |
| 프로세스 감지 | `opencode` 바이너리 이름과 argv 진입점 인식 | `opencode`를 놓치거나 `opencoder`를 잡음 | 실제 foreground pgrp leader 이름(E2E M1) |
| HookCLI | `--agent opencode`와 reason · session_id · cwd가 그대로 전달됨 | agent가 바뀌거나 필드가 빠짐 | socket 전달(기존 `termy-hook` 경로) |
| 재개 제외 / make | opencode는 재개 기록을 만들지 않음, switch 유지용 명령 형식 | 기록이 생김 | 재개 동작(범위 밖) |
| env scrub | opencode 표식은 지우고 사용자 설정은 남김 | 표식이 남거나 설정이 지워짐 | opencode가 다른 표식을 더 넣는지 |
| 알림 판정 | WAIT 진입 · 세션 전환 · 첫 이벤트에서의 알림 여부 | 세션 전환에 알림, 같은 세션 진입에 알림 없음 | 실제 소리 · 배너(E2E M2~M4, M9) |
| 설치기 | 파일 상태 판정과 쓰기 · 지우기 | foreign 파일을 덮어쓰거나 다른 파일을 지움, 읽기 실패를 다른 상태로 판정 | opencode가 그 위치에서 plugin을 로드하는지(S1). 임시 디렉터리를 home 대신 씀 |
| plugin pure 영역 | phase 계산, emission 규칙, view · payload 구성 | §4.2 표와 다른 reason, 자식 세션 · pending 누락, 480바이트 초과 | opencode API 이름과 이벤트 순서(S4, Task 4 Step 7). JavaScriptCore에 opencode 런타임이 없음 |

JavaScriptCore 테스트는 번들의 `tui.js`를 읽어 `// #region termy-pure`와 `// #endregion termy-pure` 사이만 `JSContext`로 평가한다. ESM `import` · `export`는 그 영역 밖에 두므로 JSContext가 파싱할 수 있다.

## 9. 구현 agent 규칙

1. 수용 기준은 각 테스트의 `protects` / `fails_when` / `no_claim`이다. "테스트를 통과시키는 것"이 목표가 아니다.
2. 실제 코드와 실제 테스트를 같은 변경에 넣는다. placeholder, 빈 assertion, 나중으로 미룬 테스트는 완료가 아니다.
3. 테스트 · 검증 단계 · timeout · 허용 오차 · threshold · snapshot · 경고 억제를 바꿨다면, 요약 맨 앞에 한 줄씩 이유와 함께 적는다.
4. 실행했다고 보고하는 명령은 명령과 관찰 결과(종료 코드, 개수, 실패한 줄)를 함께 적는다. 실행하지 않은 명령은 보고하지 않고, 인용하는 명령의 stderr를 숨기지 않는다.
5. 보고는 상위 agent가 다시 실행해 보기 전까지 주장이다. 확인한 것, 재사용한 것, 확인하지 못한 것을 나눠 적는다.

## 10. 롤백

- 코드: 커밋을 revert한다. 디스크 형식은 바뀌지 않는다. `session.json`에서 `AgentKind`를 담는 곳은 `WorkspaceRecord.agentResume`(`AgentResumeRecord`, `WorkspaceRecord.swift:76`)뿐이다. opencode는 이 기록을 만들지 않으므로(§4.7), revert한 빌드가 `"opencode"` 값을 디코드할 일이 없다. `PaneSnapshot`은 메모리에만 있고, `events.jsonl`은 쓰기만 하고 다시 읽지 않는다(`HookDaemon.swift:457-465`).
- 사용자 환경: 메뉴에서 해제하거나 `~/.config/opencode/plugins/termy/`를 지운다. opencode가 파일 변경을 watch하므로 떠 있는 TUI에서도 곧 빠진다.

## 11. 작업량

| 부분 | human | CC |
|---|---|---|
| spike S1~S6 | 1h | 15m |
| plugin `tui.js` + JavaScriptCore 테스트 | 3h | 30m |
| AgentKind · HookEvent · 상태 머신 · watcher · 재개 제외 · env scrub + 테스트 | 3h | 30m |
| 알림 판정(`WaitAlertRule`) + 테스트 | 1h | 10m |
| 설치기 · 메뉴 · `project.yml` + 테스트 | 3h | 30m |
| 실제 빌드 수동 확인 | 1h | 20m(사용자 참여) |
| CHANGELOG · 문서 반영 | 0.5h | 5m |
| 합계 | 12.5h | 약 2h 20m |

## 12. 파일 목록

| 파일 | 변경 |
|---|---|
| `apps/termy/Resources/opencode-plugin/tui.js` | 신규. TUI plugin(§4.2) |
| `apps/termy/Sources/OpenCodePluginInstaller.swift` | 신규. 설치기(§4.6) |
| `apps/termy/Sources/AgentKind.swift:15-49` | `.opencode` case, wireName · displayName · from |
| `apps/termy/Sources/HookEvent.swift:16-31` | `HookEventKind.agentStatus` |
| `apps/termy/Sources/PaneState.swift:172-488` | `.agentStatus` case. 머리 주석의 전이 목록에 opencode 줄 추가 |
| `apps/termy/Sources/ForegroundProcessWatcher.swift:1-27,180-233` | `opencode` 감지, 머리 주석 |
| `apps/termy/Sources/AgentResume.swift:25-40,68-92` | `make` opencode case, capture에서 opencode 제외 |
| `apps/termy/Sources/AgentResumeFlags.swift:64-75` | opencode 빈 표 |
| `apps/termy/Sources/Pane.swift:230-245` | `OPENCODE_TERMINAL`, `OPENCODE_SESSION_ID` |
| `apps/termy/Sources/AppDelegate.swift:98-101,281-287,455-469` | `refreshIfInstalled()` 호출, IBAction, 메뉴 항목 |
| `apps/termy/Sources/Notifier.swift:34,56-72,97` | `WaitAlertRule`, pane마다 `(state, sessionId)` 기억 |
| `apps/termy-hook/Sources/HookCLI.swift:37-42` | 사용 예 주석만 |
| `apps/termy-hook/Sources/main.swift:8-15` | 사용 예 주석만 |
| `project.yml:75-77` | `termy` target `sources`에 `opencode-plugin` 폴더 리소스 |
| `apps/termy-tests/Sources/AgentKindTests.swift` | +14 테스트 |
| `apps/termy-tests/Sources/ForegroundProcessWatcherTests.swift` | +2 |
| `apps/termy-tests/Sources/HookCLITests.swift` | +2 |
| `apps/termy-tests/Sources/AgentResumeCaptureTests.swift` | +1 |
| `apps/termy-tests/Sources/AgentResumeCommandTests.swift` | +1 |
| `apps/termy-tests/Sources/PaneShellEnvironmentTests.swift` | +1 |
| `apps/termy-tests/Sources/NotifierWaitAlertRuleTests.swift` | 신규 +4 |
| `apps/termy-tests/Sources/OpenCodePluginInstallerTests.swift` | 신규 +9 |
| `apps/termy-tests/Sources/OpenCodePluginScriptTests.swift` | 신규 +12 |
| `CHANGELOG.md` | `## Unreleased` 항목 |

## 13. 관련

- 0e49cc8 `feat(agent): Antigravity CLI(agy)를 세 번째 에이전트로 지원`: 이 작업이 따르는 패턴
- `docs/superpowers/specs/2026-10-10-agent-resume-after-update-design.md`: 재개(범위 밖) 설계
- `docs/superpowers/plans/2026-04-26-codex-possibly-waiting-state.md`: opencode에 적용하지 않는 Codex 침묵 추정
- opencode v2 문서: https://opencode.ai/v2/docs/build/plugins/ , https://opencode.ai/v2/docs/build/plugins/cli/

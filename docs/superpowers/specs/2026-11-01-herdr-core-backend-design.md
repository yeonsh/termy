# herdr-core 백엔드 — 설계 문서

- 날짜: 2026-11-01
- 상태: 사용자 검토 대기
- 범위: termy가 herdr-core(`hc`)의 클라이언트가 되어 원격 머신의 pane을 연다. 로컬 pane은
  기본으로 지금의 local PTY를 쓰고, 설정을 켜면 로컬 pane도 hc에서 돌린다.
  hc를 **지원**하되 **의존하지는** 않는다. hc 없이도 termy는 지금처럼 동작한다.

## 1. 목표와 동기

사용자는 Herdr.app + herdr-core로 이미 여러 원격 머신(bdpc01, backend-1, bdweb-*,
mac-builder, Windows 박스)을 붙여 쓰고 있다. termy에서도 원격에 편하게 접속해 agent를
돌리고 싶다.

core(터미널을 띄우고 살려 두는 데몬)를 termy가 직접 만들지 않고, Herdr.app처럼
herdr-core의 클라이언트가 된다. 이유:

- herdr-core는 다른 앱이 붙도록 만든 core다. `hc schema`가 OpenRPC 문서를 "for app
  builders"로 내주고, Herdr 문서도 "The Herdr app is one client of it"이라고 쓴다.
  프로토콜은 generation으로 버전을 관리하고 "API only grows" 정책을 테스트로 지킨다.
- termy에 필요한 기능이 이미 있다: attach 스트림, events, 원격 머신(ssh, 원격 설치,
  재연결), 프로그램 상태(OSC 7501), foreground 프로세스와 cwd.
- Apache-2.0(`herdrdev/herdr-core`). 방향이 틀어지면 fork할 수 있다.
- 직접 만들면 데몬, 서버 쪽 VT 상태, ssh 연결·재연결, 원격 설치·업데이트, Windows까지
  다시 만들어야 한다. 그동안 mission control 작업이 멈춘다.

덤으로, hc에서 도는 pane은 termy를 끄거나 업데이트하거나 termy가 죽어도 안의 프로그램이
계속 돈다.

**의존하지 않는 이유.** hc는 아직 preview(0.1.x, protocol generation 1)이고 다른 회사가
로드맵을 정한다. 로컬 pane까지 hc에 맡기면 termy가 공들인 입력 처리(IME, kitty keyboard)가
전부 hc의 VT 계층(질의 응답, 다시 attach할 때의 첫 화면)을 거치게 되고, 거기서 생긴
문제는 termy가 고칠 수 없다. Herdr를 쓰지 않는 사용자에게 데몬 설치를 강요하게도 된다.
그래서 원격은 hc(원격에는 core가 꼭 필요하다), 로컬은 기본 local PTY로 하고, 로컬 hc는
설정으로 켠다. hc가 안정되면 기본값만 바꾼다.

성공 기준:

- 원격 project의 pane과, 설정을 켰을 때의 로컬 pane은 hc terminal 위에서 돈다. 입력·IME·
  붙여넣기·마우스·크기 조절은 local PTY pane과 같게 느껴진다.
- 설정을 끈 기본 상태에서 hc가 없거나 꺼져 있어도 로컬 pane은 지금과 똑같이 동작한다.
- termy를 ⌘Q로 끄거나 죽이거나 Sparkle로 업데이트한 뒤 다시 켜면, hc pane은 같은 배치로
  같은 프로세스에 다시 붙고 화면 내용이 돌아온다. 돌던 agent는 멈추지 않았다. local PTY
  pane은 지금처럼 동작한다(업데이트 때는 AgentResume).
- ⌘K에서 원격 project(머신 + 폴더)를 열면 그 머신의 그 폴더에서 셸이 뜬다. 그 안의
  Claude Code 상태(working / blocked / idle / done / error)가 로컬 pane과 같은 방식으로
  mission control과 알림에 나온다.
- 로컬 Claude Code / Codex / Antigravity / opencode의 mission control 정보(상태, prompt,
  마지막 응답, resume용 sessionId)는 지금과 같다.

## 2. 비목표

- termy 자체 core 구현.
- local PTY를 없애거나, 첫 실행 때 hc 설치를 요구하는 것.
- termy가 꺼져 있는 동안 온 hook 이벤트를 모아 두었다가 다시 재생하는 것.
- Windows 원격 머신의 pane(§6.8).
- 원격 agent의 세부 정보(prompt, 마지막 응답, sessionId, resume). 1차는 상태만 보여 준다.
- termy UI에서 머신 추가·로그인·삭제. `hc machine add` 또는 Herdr.app에 맡긴다. termy는
  이미 추가된 머신을 보여 주기만 한다.
- Herdr.app과 레이아웃 공유. 같은 core를 쓰지만 서로의 터미널은 건드리지 않는다.
- herdr-core 수정이나 fork, termy에 hc를 번들하는 것.
- termy가 hc를 자동 업데이트하는 것(Herdr.app은 한다).
- 재부팅 뒤 agent 자동 resume(지금도 하지 않는다).
- 원격 파일 브라우징(원격 폴더 선택기, 원격 markdown/PDF 미리보기).

## 3. 현재 구조 (출발점)

경로는 `apps/termy/Sources/` 기준.

- **프로세스 생성:** `Pane.startShell()`(`Pane.swift:268-303`)이 `$SHELL -l`을 SwiftTerm
  `LocalProcess`로 띄운다. cwd는 프로세스 전역 `chdir`로 맞춘다. 환경은
  `Pane.shellEnvironment`(`:252-266`)가 만든다: agent 세션 표식 변수 제거
  (`agentSessionMarkerEnvKeys`, `:235-249`), 새어 들어온 `GIT_EDITOR=true` 제거,
  `TERMY_PANE_ID`, `TERMY_PROJECT_ID`, `TERM=xterm-256color`, `COLORTERM=truecolor`,
  `LC_ALL`. `TERM_PROGRAM`은 설정하지 않는다.
- **뷰:** `TermyTerminalView`(`TermyTerminalView.swift:30`)가 `LocalProcessTerminalView`를
  상속한다. `dataReceived(slice:)`(`:907`)는 LocalProcess 읽기 콜백이고, 여기서
  `recordPtyActivity`를 부른다. 크기 freeze/thaw(`:52-82`)는 TIOCSWINSZ를 늦춘다.
  SwiftTerm의 `send(source:data:)` → `process.send`, `sizeChanged` → `setWinSize(childfd)`
  경로에 termy의 모든 입력(Shift+Return, Option+화살표, IME/kitty 우회, 드래그 경로, 스크롤
  휠, 붙여넣기, 마우스)이 기대고 있다.
- **pid/fd 사용:** `ForegroundProcessWatcher`가 1초마다 `tcgetpgrp`, `proc_name`,
  `KERN_PROCARGS2`, `proc_pidinfo`로 foreground agent·argv·cwd를 읽어 synthetic
  SessionStart/End를 만들고, Codex pane에는 `reconcileCodexForeground`(8초 silence →
  POSSIBLY_WAITING)를 돌린다. `Pane.agentResumeRecord`(`:323-343`)도 커널에서 직접 읽는다.
- **종료:** `processTerminated`(`Pane.swift:473-490`) → `HookDaemon.postPtyExit`(synthetic
  `PtyExit`, 0이 아니면 ERRORED) → `onShellExited` → Workspace가 pane을 닫는다.
  `Workspace.teardown`(`:627-632`)은 `process.terminate()`.
- **cwd:** OSC 7 → `currentCwd` → `refreshHeader`(GitBranch) → project drift(`Pane.swift:387-409`)
  → `GitHeadWatcher` 재설정.
- **pane id:** 실행할 때마다 새 `UUID()`(`Pane.swift:93`)이고 저장하지 않는다.
  HookDaemon snapshot은 메모리에만 있고 이 id로 찾는다.
- **세션 저장:** `SessionRecord → WindowRecord → rows: [[PaneRecord]]`,
  `PaneRecord{cwd, agentResume?}`. 복원(`WindowManager.restoreSessionWindows` →
  `applySessionLayout`)은 항상 새 셸을 띄운다. ⌘K 레이아웃은 `WorkspaceRecord{canonicalPath,
  displayLabel, updatedAt, panes, rows?}`.
- **project:** 저장되는 개체가 아니다. cwd의 worktree root basename에서 계산하고
  (`ProjectIdentity.derive`, `MainWindowController.swift:589-628`), `canonicalPath`가
  저장 키다. `Pane.projectId`는 `cd`할 때 바뀐다. ⌘K(`ProjectSwitcherPanel`)는 저장된
  `WorkspaceRecord`만 보여 준다. 숨긴 project의 pane은 계속 돌고, 다시 보일 때 다시 그린다.
- **hook:** `termy-hook`이 환경의 `TERMY_PANE_ID`/`TERMY_PROJECT_ID`를 붙여
  `/tmp/termy-$UID.sock`로 보낸다(opencode plugin `tui.js`도 같은 변수를 읽는다).
  `HookDaemon.ingest` → `PaneStateMachine.apply`. `PaneState`: `initializing`, `thinking`,
  `possiblyWaiting`, `waiting`, `idle`, `errored`.
- **업데이트:** `UpdateRelaunchGate`가 turn 중인 pane이 있으면 Sparkle 재시작을 미룬다.
  `prepareForUpdateRelaunch`가 `AgentResume` 기록과 함께 session.json을 봉인하고, 재시작
  뒤 `StartupInputScheduler`가 `claude --resume` 등을 타이핑한다. 둘 다 "재시작하면 PTY
  자식이 죽는다"는 전제 위에 있다(`docs/superpowers/specs/2026-10-10-agent-resume-after-update-design.md`
  §2가 "PTY를 daemon으로 옮기기"를 별도 작업으로 남겨 두었다. 이 문서가 그 작업이다).
- 종료 확인(⌘Q, 창 닫기, pane 닫기)은 없다. `applicationShouldTerminateAfterLastWindowClosed`가
  `true`라서(`AppDelegate.swift:138`) 마지막 창을 닫으면 앱이 종료된다.
- `PaneSnapshot`(상태, prompt, 마지막 응답, `lastSessionId`, agentKind)은 메모리에만 있다.
  termy가 꺼져 있으면 `termy-hook`은 socket 연결에 실패하고 로그만 남긴 채 0으로 끝난다.
- Debug 빌드와 release termy를 함께 띄우는 일이 잦다(지금도 session.json을 같이 쓴다).
  XCTest host도 `AppDelegate`를 거쳐 시작한다.

## 4. herdr-core 요약 (2026-11-01, hc 0.1.16, protocol generation 1)

기준 문서는 `herdrdev/herdr-core`의 `schema/README.md`(연결 방식, framed 형식, attach,
events, documents)와 `hc schema`(OpenRPC)다. 빌더는 원문을 읽는다. 여기는 설계에 쓰는
사실만 적는다.

- **연결:** Unix socket. 이 Mac에서는 `~/.local/state/herdr-core/default/default.sock`
  (경로 규칙은 `docs/security.md`의 "state and endpoints"). 처음에는 plain mode(줄 단위
  JSON-RPC 2.0). `hello {framed: true, generation: 1}`로 framed mode로 바꾼다. attach는
  framed mode에서만 된다.
- **framed 형식:** `[channel u32 LE][kind u8][len u32 LE][payload]`. kind: 0 DATA,
  1 CREDIT, 2 CLOSE, 3 RESIZE(u16 cols, u16 rows), 4 FOCUS(1/0), 5 FACTS(JSON `Display`).
  channel 0은 JSON-RPC(여러 호출이 동시에 진행된다).
- **attach:** `terminal.attach {terminal, cols, rows, display, history}` → channel. 먼저
  first paint(현재 화면, 선택한 history 줄 수, 마지막 상태 보고와 title,
  `CSI ?9001h/l`), 그다음 프로그램의 raw 출력(core가 이미 답한 터미널 질의는 뺀다).
  키는 같은 channel에 DATA로 보낸다. core는 키를 인코딩하지 않는다. 마지막으로 활동한
  viewer가 크기를 정한다. 흐름 제어: 256 KiB credit으로 시작하고, viewer가 소비한 바이트를
  CREDIT으로 돌려준다. 4 MiB 넘게 밀리면 backlog 대신 새로 그린 화면을 받는다. 프로그램이
  끝나면 `CLOSE {"reason":"exited","exit_code":0,"signal":null}`.
- **events:** `events.subscribe` → snapshot(`seq`, terminals) + 이벤트(`created`, `lost`,
  `restarted`, `keep`, `finished`, `removed`, `status`, `turn`, `title`, `labels`, `size`,
  `foreground`, `doc`), 15초마다 `heartbeat`, 뒤처지면 `missed` + 새 snapshot. 원격 머신
  terminal도 같은 스트림에 `machine/t7` 주소로 온다. `seq`는 core 프로세스마다 새로
  시작한다.
- **terminal.run 파라미터:** `argv` 또는 `line`(없으면 그 머신의 셸), `cwd`, `env`(core
  환경 위에 **덧붙이기만** 한다), `labels`(`k=v`), `keep`, `on`(원격 머신), `no_parent`,
  `no_notify`, `name`.
- **foreground:** 약 0.5초마다 `{pid, name, argv, cwd}`(foreground process group leader와
  그 폴더). 원격 terminal도 온다.
- **status:** 프로그램이 보낸 OSC 7501만 쓴다(`idle`, `working`, `done`, `blocked`(kind:
  `permission`/`question`/`auth`), `error`, 그리고 `msg`, `progress`, `app`). 화면을 보고
  추측하지 않는다. `reported`는 한 번이라도 보고했는지. `turn`은 status가 `working`을
  벗어날 때마다 오른다.
- **keep:** 신호로 죽거나 holder를 잃으면 같은 자리에서 그 머신의 셸을 다시 띄운다(원래
  명령은 다시 실행하지 않는다). 그동안 attach가 끊기고, `restarted` 뒤 다시 attach한다.
  `server stop`은 kept terminal을 park하고, 다음 core 시작 때 새 셸을 준다. 종료 코드가
  있는 exit와 명시적 kill은 최종이다.
- **documents:** `doc.get/doc.set`(1 MiB JSON, version 검사). Herdr.app은 `herdr-app`
  문서에 레이아웃을 둔다.
- **machines:** `machine.list` → `{name, host, state: connecting|connected|needs_login|unreachable, why, ...}`.

직접 확인한 것(2026-11-01):

- Claude Code 2.1.316은 hc 안에서 시작하자마자 7501을 보낸다(`blocked`, msg `dialog open`).
  터미널에 `OSC 7501 ; ?`로 지원 여부를 묻고, hc가 답하면 보고를 시작한다.
- Codex 0.160.1은 `--no-daemon`으로 한 turn을 끝까지 돌려도 7501을 한 번도 보내지 않았다.
  Fut 문서(<https://fut.sh/agents/codex/>)는 "최근 Codex"가 idle/working/blocked를 보내고
  turn 완료는 보내지 않는다고 한다.
- Antigravity, opencode는 확인하지 않았다.

## 5. 결정 사항

| 항목 | 결정 | 누가 |
|---|---|---|
| core | herdr-core를 쓴다. termy core를 만들지 않는다 | 사용자 |
| 지원 vs 의존 | 지원한다. hc 없이도 termy는 동작한다 | 사용자 |
| 원격 project의 pane | 항상 hc | 사용자 |
| 로컬 pane | 기본 local PTY. 설정 "Run local panes in herdr-core"를 켜면 hc | 사용자 |
| 상태 정보 | 두 경로: events(7501)가 기본, hook이 보충 | 사용자 |
| 원격 agent | 1차는 상태만 | 사용자 |
| 머신 추가 | `hc machine add` / Herdr.app에 맡긴다 | 사용자(제안을 승인) |
| 원격 지정 단위 | project = 머신 + 폴더 | 사용자(제안을 승인) |
| hc가 없을 때 | 원격 project를 처음 만들거나 로컬 hc 설정을 켤 때 설치를 안내하거나 대신 설치한다 | 사용자(제안을 승인) |
| Herdr.app 공존 | 같은 core를 써도 서로의 터미널을 건드리지 않는다 | 사용자(제안을 승인) |
| pane 닫기 / 창 닫기 / 마지막 창 닫기 | hc terminal을 kill한다. 마지막 창 닫기도 사용자가 pane을 닫는 것이다 | 사용자 |
| ⌘Q / 크래시 / 업데이트 | hc terminal을 그대로 둔다. 다음 실행 때 다시 붙는다 | 내 판단(사용자가 확인) |
| 상태 우선순위 | 7501을 보고한 terminal은 7501이 상태를 정하고, hook은 세부 정보만 채운다 | 내 판단 |
| hook 세부 정보 보존 | pane id별로 session.json에 저장한다. termy가 꺼진 동안의 hook 이벤트는 잃는다 | 내 판단 |
| 여러 termy instance | terminal에 `termy.instance=<bundle id>` label. 각 termy는 자기 instance terminal에만 붙는다 | 내 판단 |
| hc를 쓸 수 없을 때의 hc pane | local로 바꾸지 않는다. "herdr-core unavailable" 상태로 두고 다시 연결을 시도한다 | 내 판단 |
| pane별 backend | `PaneRecord`에 기록한다. 설정을 바꿔도 이미 열린 pane의 backend는 그대로 | 내 판단 |
| keep | termy가 만드는 terminal은 `keep: true` | 내 판단 |
| 레이아웃 저장 위치 | 지금처럼 로컬 `session.json` / `workspaces/*.json`. hc `doc`은 쓰지 않는다 | 내 판단 |
| 원격 pane의 git branch, project drift | 1차는 없다 | 내 판단 |
| Windows 원격 머신 | 1차는 지원하지 않는다(§6.8) | 내 판단 |

## 6. 설계

### 6.1 전체 구조

```
termy.app
 ├─ HcConnection (actor)        ─ socket, hello, framed codec, channel 0 JSON-RPC, 재연결
 │   ├─ HcEventStore             ─ events.subscribe snapshot + 이벤트 적용(seq/missed)
 │   └─ attach channel들         ─ pane 하나에 channel 하나
 ├─ PaneBackend (protocol)
 │   ├─ LocalPtyBackend          ─ 지금의 SwiftTerm LocalProcess 경로(로컬 pane 기본)
 │   └─ HcPaneBackend            ─ terminal.run / attach / DATA / RESIZE / FOCUS / FACTS / kill
 ├─ TermyTerminalView            ─ TerminalView 상속(LocalProcessTerminalView 아님), 입출력은 backend로
 ├─ HookDaemon                   ─ hook 이벤트 + hc 상태/foreground/종료를 합쳐 PaneSnapshot 생성
 └─ ⌘K / Workspace               ─ 원격 project(머신 + 폴더)
          │
          ▼ Unix socket (JSON-RPC + framed)
 herdr-core (hc serve) ── ssh ──► 원격 머신의 hc
```

### 6.2 hc 연결 계층

- termy 프로세스당 hc 연결 하나. **필요할 때만 연결한다:** 복원할 hc pane이 있거나,
  원격 project를 열거나, ⌘K가 머신 목록을 보여 주거나, 로컬 hc 설정이 켜져 있을 때.
  hc를 한 번도 쓰지 않는 사용자는 hc를 건드리지 않는다.
- 연결하면 `hello {framed: true, generation: 1}`을 보내고, 응답의 `generation`과
  `methods`를 검사한다(§6.10).
- frame codec은 부분 읽기와 여러 frame이 한 번에 오는 경우를 처리한다. channel 0의
  JSON-RPC는 id로 응답을 짝짓는다. 알림(`event`, `heartbeat`, `missed`)은 HcEventStore로
  보낸다.
- 흐름 제어: attach channel마다 SwiftTerm에 넣은 바이트만큼 CREDIT을 돌려준다. 이것을
  빠뜨리면 256 KiB 뒤 스트림이 멈춘다.
- 재연결: socket이 끊기면(core 재시작·업데이트) 단계적으로 늘어나는 간격으로 다시
  연결하고, 다시 subscribe한 뒤 살아 있는 pane을 모두 다시 attach한다. 그동안 pane에는
  "reconnecting" 상태를 보여 주고 입력을 막는다. `seq`는 새로 시작하므로 snapshot을 새로
  받는다.
- events 구독은 필터 없이 하나만 하고, termy가 `termy.*` label로 거른다(원격 terminal도
  같은 스트림으로 온다).

### 6.3 pane backend 경계

`PaneBackend`가 pane 하나의 프로세스를 대표한다. 기능: 시작, 바이트 보내기, 크기,
포커스, display facts, kill, 그리고 콜백(출력 바이트, 종료, foreground, cwd, title, 연결
상태). `HcPaneBackend`와 `LocalPtyBackend` 두 구현을 둔다.

- `TermyTerminalView`는 `LocalProcessTerminalView` 대신 SwiftTerm `TerminalView`를
  상속하고, `TerminalViewDelegate`의 `send`와 `sizeChanged`를 backend로 넘긴다. 출력은
  backend 콜백에서 `feed` + `recordPtyActivity`. 지금 LocalProcess에 기대는
  `dataReceived`와 freeze/thaw의 TIOCSWINSZ는 backend의 resize 호출로 바꾼다. 나머지
  override(IME, 링크, 드래그, 키 재매핑)는 그대로 옮긴다.
- `LocalPtyBackend`는 지금 `Pane.startShell`이 하던 일을 SwiftTerm `LocalProcess`로
  직접 한다. 로컬 pane의 기본 경로이므로 동작이 지금과 바이트 단위로 같아야 한다
  (`ForegroundProcessWatcher`, OSC 7, `PtyExit`, AgentResume, UpdateRelaunchGate 모두
  그대로).
- 새 pane의 backend: 원격 project면 hc, 로컬이면 설정을 따른다. 정해진 backend는
  `PaneRecord`에 남고, 설정을 바꿔도 이미 열린 pane은 그대로다.

### 6.4 pane 생성과 attach (hc)

`terminal.run`:

- 로컬: `argv`는 로그인 셸(지금처럼 `$SHELL -l`). `cwd`는 처음 cwd. 원격: `argv` 없이
  (그 머신의 셸), `on: <machine>`, `cwd: <project 폴더>`.
- `env`: `TERMY_PANE_ID`, `TERMY_PROJECT_ID`, `TERM=xterm-256color`, `COLORTERM=truecolor`,
  `LC_ALL`(지금 규칙). `TERM_PROGRAM` 처리는 §8 spike에서 정한다. hc는 이 값으로
  XTVERSION에 답하고, Claude Code는 이 값을 보고 터미널 기능을 고른다.
- **agent 세션 표식 변수:** `env`는 덧붙이기만 하므로 core 환경에 `CLAUDECODE` 같은
  변수가 있으면 모든 hc pane이 물려받는다(core를 agent 안에서 처음 띄우면 생긴다). 로컬
  pane은 셸을 `/usr/bin/env -u VAR ... $SHELL -l` 같은 방식으로 감싸 지금의
  `agentSessionMarkerEnvKeys`와 `GIT_EDITOR=true`를 지운다. termy가 core를 직접 띄울 때도
  깨끗한 환경으로 띄운다(§6.10).
- `labels`: `termy.pane=<paneId>`, `termy.project=<project 키>`,
  `termy.instance=<bundle identifier>`. instance label이 있어서 Debug termy와 release
  termy가 같은 core를 써도 서로의 terminal에 붙거나 kill하지 않는다. 원격 머신 목록은
  core 단위라서 Debug도 같은 머신을 본다.
- `keep: true`, `no_parent: true`, `no_notify: true`.

`terminal.attach`: pane의 cols/rows, `display`(배경·전경·커서 색, 셀 크기),
`history`(복원할 때만, SwiftTerm scrollback 범위 안에서). 이후:

- 키·붙여넣기·마우스: DATA.
- 크기: RESIZE(freeze/thaw 규칙은 유지하고, thaw할 때 보낸다).
- pane 포커스: FOCUS.
- 테마·글꼴 변경: FACTS.
- `CSI ?9001h`(win32-input-mode)를 받으면: §6.8의 Windows 규칙.

### 6.5 pane identity와 복원

- **pane id를 저장한다.** `TERMY_PANE_ID`는 hc terminal이 시작될 때 환경에 고정되고,
  hook은 그 값을 그대로 보낸다. 따라서 다시 실행해도 pane id가 같아야 한다.
  `PaneRecord`에 `paneId`를 추가하고 복원 때 재사용한다. 예전 session.json(필드 없음)은
  새 id를 만든다.
- **pane별 backend를 저장한다.** `PaneRecord`에 `backend`(local / hc)를 추가한다. 없으면
  local(예전 파일).
- **pane ↔ terminal 대응은 label이 기준이다.** `termy.pane=<paneId>` +
  `termy.instance=<자기 bundle id>`. 주소(`t7`, `bdpc01/t3`)는 저장해도 캐시로만 쓴다.
- **실행 순서:** 저장된 레이아웃을 그린다 → local pane은 지금처럼 새 셸 → hc pane이
  하나라도 있으면 연결 → subscribe(snapshot) → hc pane마다 살아 있는 terminal을 label로
  찾아 attach(history 포함), 없거나 끝났으면 같은 pane id·cwd(원격은 같은 머신·폴더)로
  hc에 새 셸을 띄운다.
- **hc를 쓸 수 없으면(연결 실패, generation 불일치) hc pane을 local로 바꾸지 않는다.**
  바꾸면 같은 pane id를 가진 agent가 hc에서 계속 돌면서 hook이 새 local pane 상태에
  섞이고, hc가 돌아오면 대응이 겹친다. 그 pane에는 "herdr-core unavailable"과 이유를
  보여 주고 다시 연결을 시도한다. 사용자가 pane을 닫으면 그때 정리한다(연결되면 kill).
- **고아 terminal:** 자기 instance label과 `termy.pane` label이 있는데 저장된 레이아웃에
  없는 살아 있는 terminal(autosave 전에 죽은 경우 등)은 `termy.project` label대로 pane으로
  열어 붙인다. 보이지 않는 곳에서 agent가 도는 일을 막는다.
- **상태 초기값:** snapshot의 `status`/`foreground`로 PaneSnapshot의 상태를 바로 채운다.
  termy가 꺼져 있던 동안 바뀐 상태도 7501을 보내는 agent라면 켜자마자 맞는다.
- **hook 세부 정보 보존:** `PaneSnapshot`의 hook 정보(`lastSessionId`, prompt,
  `lastAssistantMessage`, agentKind, `lastCwd`)를 hc pane에 한해 pane id별로 session.json에
  저장하고, 복원할 때 되살린다. termy가 꺼진 동안 온 hook 이벤트는 잃는다(§2). 그래서
  7501을 보내지 않는 agent(지금의 Codex)는 다시 켠 뒤 다음 hook이 올 때까지 상태를 모르고,
  foreground 이름으로 "codex 실행 중"까지만 보여 준다. 그사이 승인 대기에 들어가 있었다면
  알림이 오지 않는다.
- ⌘K 레이아웃(`WorkspaceRecord`)은 지금 규칙을 따른다. project를 닫으면 그 pane들은 kill,
  다시 열면 새 셸이다. `PaneRecord.paneId`는 여기에도 저장한다(같은 타입).

### 6.6 상태: 두 경로

PaneSnapshot의 입력은 셋이다. hook 이벤트(로컬만), hc `status`/`turn`(7501), hc
`foreground`/종료.

- **7501을 보고한 terminal(`reported == true`):** 상태는 7501이 정한다.
  - `working` → `thinking`
  - `blocked`(permission / question / auth) → `waiting`(사유는 kind)
  - `idle` → `idle`
  - `done` → turn 끝(지금 Stop과 같은 처리: 알림, `idle`)
  - `error` → `errored`
  - `turn` 이벤트(working에서 벗어남)도 turn 끝으로 본다. Codex처럼 `done`을 보내지
    않는 agent가 나중에 7501을 지원해도 완료를 잡기 위해서다. 같은 turn을 두 번 알리지
    않는다.
  - hook 이벤트는 세부 정보(`lastSessionId`, prompt, `lastAssistantMessage`, toolName,
    cwd)만 갱신하고 상태는 바꾸지 않는다.
- **보고하지 않은 terminal:** 지금 hook 상태 머신 그대로. 그 입력을 바꾼다.
  - synthetic SessionStart/End: `ForegroundProcessWatcher` 대신 hc `foreground` 이벤트의
    name/argv로 만든다(지금 `classifyAgent` 재사용).
  - Codex reconciler: foreground는 hc 이벤트, 출력 활동은 attach 스트림 바이트로 판단한다.
  - `PtyExit`: attach CLOSE / `finished` 이벤트의 exit_code로 만든다.
- **원격 pane:** hook이 닿지 않으므로 7501만 쓴다. 7501을 보내지 않는 agent(지금의
  Codex)는 원격에서 상태가 없다. foreground 이름으로 "codex 실행 중"까지만 보여 준다.
- 한 pane에서 agent가 바뀌면(claude 종료 후 codex 실행) `reported`가 유지될 수 있다.
  7501 `status`가 null로 지워지고 foreground가 바뀌는 시점에 hook 경로로 돌아가는지
  spike에서 확인한다(§8).

### 6.7 foreground, cwd, 종료, title

- hc pane은 `ForegroundProcessWatcher`를 쓰지 않는다. hc `foreground` 이벤트가 같은
  정보(pid, name, argv, cwd)를 준다. `agentResumeRecord`도 이 값을 쓴다(local 백엔드에서만
  필요, §6.9).
- cwd: hc `foreground.cwd`가 기준이고, 스트림에 OSC 7이 오면 그것도 받는다. 다시 attach한
  first paint에는 OSC 7이 없을 수 있기 때문이다. 로컬 pane은 그 cwd로 지금처럼
  `GitBranch` / `GitHeadWatcher` / project drift를 돌린다.
- 종료: CLOSE의 `reason`이 `exited`/`killed`면 지금 `processTerminated` 경로
  (`PtyExit` → pane 닫기). kept terminal의 `lost`는 종료가 아니다. pane에 "restarting
  shell"을 보여 주고 `restarted`에서 다시 attach한다. `server_stop`, `holder_lost` 등은
  pane을 닫지 않고 상태로 보여 준다.
- title: 지금처럼 쓰지 않는다(바꾸는 것은 범위 밖).

### 6.8 원격 project

- project에 머신을 붙인다. `WorkspaceRecord`에 `machine: String?`을 추가하고, 원격
  project의 저장 키는 `<machine>:<folder>`처럼 로컬 경로와 겹치지 않게 한다.
- ⌘K에 "New Remote Project…"를 넣는다. `machine.list`에서 머신을 고르고(상태 표시:
  connected / connecting / needs_login / unreachable), 폴더 경로를 입력한다. 폴더는
  `machine.exec` 등으로 존재를 확인한다. 원격 project는 ⌘K 목록에 머신 이름과 함께 나온다.
- 원격 project의 새 pane: `terminal.run {on: machine, cwd: folder}`. pane 헤더에 머신
  이름을 보여 준다.
- 원격 pane의 project는 고정이다(`cd`해도 바뀌지 않는다). git branch 표시와 미리보기
  링크 해석은 1차에 없다.
- 머신이 `unreachable`/`needs_login`이면 ⌘K와 pane에 그 상태를 보여 주고, 새 pane은
  만들지 않는다. `needs_login`은 "터미널에서 `hc machine login <name>`을 실행하라"고
  안내한다.
- **Windows 머신:** ConPTY는 win32-input-mode(`CSI ?9001h`)를 요구하고, viewer가 키를
  그 형식으로 직접 인코딩해야 한다. SwiftTerm에는 그 인코더가 없다. 1차는 Windows 머신을
  ⌘K 머신 목록에서 비활성으로 보여 준다(이유 표시). 머신의 OS는 `machine.exec`로
  확인하거나 9001 수신으로 감지한다.

### 6.9 닫기, 종료, 업데이트

- pane 닫기·창 닫기·**마지막 창 닫기**·⌘K project 닫기: `terminal.kill`(지금처럼
  프로세스가 끝난다). 마지막 창을 닫으면 앱도 종료되지만, 사용자가 pane을 닫은 것이므로
  kill한다(사용자 결정).
- ⌘Q, 크래시, Sparkle 업데이트 재시작: hc terminal은 그대로 둔다. 다음 실행 때 §6.5로
  다시 붙는다.
- 따라서 teardown은 "사용자가 창/pane을 닫음"과 "앱 종료 중에 창이 닫힘"을 구분해야
  한다. ⌘Q와 업데이트 재시작에서 창이 정리될 때는 kill하지 않는다. 마지막 창 닫기는
  창 닫기가 먼저 일어나고 그 결과로 앱이 종료되므로 kill 쪽이다.
- `UpdateRelaunchGate`와 `AgentResume`/`StartupInputScheduler` 경로는 local 백엔드 pane에만
  적용한다. hc pane은 업데이트해도 죽지 않으므로 기다리거나 resume할 이유가 없다. gate는
  turn 중인 **local** pane 수만 센다.
- 재부팅: hc도 함께 끝난다. kept terminal은 다음 core 시작 때 마지막 폴더에서 새 셸을
  받고, termy는 그 셸에 다시 붙는다. agent resume은 하지 않는다(지금과 같다).

### 6.10 hc 찾기, 시작, 설치, 버전

- 찾기: `PATH`, `~/.local/bin/herdr-core`, Homebrew 경로. socket 경로는 hc 규칙을 따른다.
- core가 안 떠 있으면 termy가 `herdr-core server start`로 띄운다. 이때 termy 자신의 환경이
  아니라 최소 환경(`HOME`, `USER`, `SHELL`, `PATH`, `LANG`)으로 띄워 agent 표식 변수가
  core로 새지 않게 한다.
- 설치 안내는 hc가 필요해지는 순간에만 띄운다: ⌘K에서 원격 project를 처음 만들 때,
  또는 설정에서 "Run local panes in herdr-core"를 켤 때. 첫 실행이나 로컬 pane만 쓰는
  사용자에게는 띄우지 않는다.
- 시트 내용: 원격 pane과 살아남는 로컬 pane은 herdr-core가 필요하다는 설명, Install 버튼
  (공식 설치 스크립트 `https://releases.herdr.dev/core/install.sh`를 실행하고 출력을 보여
  준다), Cancel. Cancel하면 원격 project를 만들지 않거나 설정을 켜지 않는다.
- `hello` 검사: generation이 1이 아니면(core가 더 새것) "update termy"를, 필요한 method가
  없으면(core가 더 오래됨) `hc update`를 안내한다. 어느 경우든 새 hc pane은 만들지 않고,
  이미 있는 hc pane은 §6.5의 unavailable 상태로 둔다. local pane은 영향을 받지 않는다.
- 설정에 hc 버전과 연결 상태를 보여 준다.

### 6.11 Herdr.app과 공존

- termy는 `termy.pane` label이 있는 terminal에만 attach하고, `herdr.*` label과
  `herdr-app` 문서는 읽지도 쓰지도 않는다.
- Herdr.app이 termy의 terminal을 어떻게 보여 주는지(목록에 나오는지, adopt하는지,
  지우는지)는 spike에서 확인한다(§8). termy의 terminal을 Herdr가 지우거나 바꾸면 이 설계를
  다시 본다.
- 두 앱이 같은 terminal에 attach하면 마지막으로 활동한 쪽이 크기를 정한다. 허용한다.

## 7. 실패 모드와 대응

| 상황 | 대응 |
|---|---|
| core가 재시작·업데이트로 socket을 닫음 | 재연결 → 다시 subscribe → 모든 hc pane 다시 attach. 그동안 pane에 상태 표시, 입력 막음 |
| CREDIT 누락 | 스트림이 256 KiB에서 멈춘다. codec 테스트로 막는다 |
| viewer가 4 MiB 넘게 밀림 | hc가 새로 그린 화면을 보낸다. 받아서 그대로 그린다 |
| kept terminal `lost` | pane 유지, "restarting shell", `restarted`에서 다시 attach |
| 원격 머신 연결 끊김 | 그 머신 pane에 상태 표시. 다시 연결되면 hc가 `created`를 다시 보내고, termy가 다시 attach |
| core 환경에 agent 표식 변수 | 셸을 `env -u`로 감싼다. termy가 core를 띄울 때는 최소 환경 |
| 예전 session.json(paneId·backend 없음) | 새 pane id, local 백엔드, 새 셸(지금 동작) |
| hc 없음 / 설치 거절 | 원격 project와 로컬 hc 설정을 쓸 수 없다. local pane은 그대로 |
| 실행 중 또는 복원 때 hc를 쓸 수 없음(generation 불일치, 연결 실패) | hc pane은 local로 바꾸지 않고 "herdr-core unavailable" + 재연결 시도 |
| Debug termy와 release termy가 같은 core 사용 | `termy.instance` label로 서로의 terminal을 무시한다 |
| 마지막 창 닫기와 ⌘Q를 혼동 | teardown이 둘을 구분한다(§6.9). 마지막 창 닫기는 kill, ⌘Q는 유지 |
| 같은 terminal에 Herdr와 termy가 attach | 크기 경쟁. 허용 |
| 7501을 보내던 agent가 끝나고 다른 agent가 시작 | §6.6 마지막 항목. spike에서 확인 |

## 8. 사전 확인(spike) — 구현 전 gate

버리는 코드로 확인하고, 결과를 이 문서에 적은 뒤 구현에 들어간다.

1. **attach 기본:** Swift로 hc에 연결해 `terminal.run` + `terminal.attach`를 하고 SwiftTerm
   `TerminalView`에 붙인다. 타이핑, 붙여넣기, 크기 조절, 포커스, 마우스, 스크롤, CREDIT,
   타이핑 지연감.
2. **다시 attach:** 클라이언트를 죽였다가 다시 붙는다. first paint가 맞는지, `history`,
   alt screen 앱(vim, Claude Code TUI), 그리고 **키보드 모드(kitty keyboard flags,
   bracketed paste, mouse reporting)가 다시 붙은 뒤에도 SwiftTerm에 살아 있는지.** 살아
   있지 않으면 Shift+Return, IME 커밋 우회, 붙여넣기가 깨진다.
3. **IME:** 한글 조합 입력이 hc를 거쳐 Claude Code에 정상 입력되는지(실제로 띄워서 확인).
4. **Claude 7501 값:** permission prompt, AskUserQuestion, turn 끝, 오류일 때 실제로 오는
   state/kind/msg.
5. **agent 교체:** 한 pane에서 claude를 끝내고 codex를 띄울 때 `status`/`reported`가
   어떻게 바뀌는지.
6. **`TERM_PROGRAM`:** 비워 둘 때와 `termy`로 줄 때 Claude Code 동작 차이.
7. **Herdr.app 공존:** termy label이 붙은 terminal이 있을 때 Herdr.app이 무엇을 하는지.
8. **core 환경:** 이 Mac의 core 환경에 agent 표식 변수가 있는지, `env -u` 감싸기가 잘
   되는지.

## 9. 수용 기준

- 기본 설정(로컬 hc 꺼짐)에서 hc를 지우거나 꺼도, 로컬 pane만 쓰는 동안 termy는 지금과
  똑같이 동작하고 hc 관련 안내를 띄우지 않는다.
- 로컬 hc 설정을 켜면 그 뒤 새 로컬 pane은 `termy.pane`/`termy.instance` label을 단 hc
  terminal이다. 입력·IME·붙여넣기·마우스·크기 조절이 local pane과 같다. 이미 열린 pane은
  그대로다.
- ⌘Q 후 다시 실행: hc pane은 같은 배치, 같은 프로세스, 화면 내용 복원. 돌던 Claude turn은
  끊기지 않았고, mission control 상태가 켜자마자 맞다. prompt·마지막 응답·sessionId도
  보인다.
- termy 프로세스를 강제 종료 후 다시 실행: 위와 같다.
- Sparkle 업데이트: turn 중인 local pane이 없으면 gate 없이 재시작하고, hc pane의 agent는
  계속 돈다. local pane은 지금처럼 gate와 AgentResume.
- 마지막 창을 닫으면 그 창의 hc terminal이 끝난다(`hc ls`에서 사라진다). ⌘Q는 남긴다.
- Debug termy를 release termy와 함께 띄워도 서로의 hc terminal에 붙거나 kill하지 않는다.
- hc pane이 있는 상태에서 hc를 멈추고 termy를 다시 실행하면, 그 pane은 local 셸로
  바뀌지 않고 "herdr-core unavailable"로 보인다. hc를 다시 띄우면 원래 terminal에 붙는다.
- 원격 project(bdpc01 + 폴더)를 만들면 그 머신 그 폴더에서 셸이 뜬다. 그 안의 Claude
  Code 상태가 mission control과 알림에 나온다.
- 원격 머신이 끊기면 상태가 보이고, 돌아오면 다시 붙는다.
- Windows 머신은 ⌘K 목록에서 비활성으로 이유와 함께 보인다.
- hc가 없을 때 원격 project를 만들거나 로컬 hc 설정을 켜면 설치 시트가 뜬다. Cancel하면
  아무것도 바뀌지 않는다.
- 로컬 Claude / Codex의 prompt, 마지막 응답, sessionId가 local pane과 hc pane 모두에서
  지금처럼 보인다.
- pane을 닫으면 hc terminal이 끝난다(`hc ls`에서 사라진다).
- Herdr.app을 함께 띄워도 서로의 terminal이 사라지거나 바뀌지 않는다.

## 10. 테스트 계획

- **단위:** frame codec(부분 읽기, 여러 frame, 16 MiB 상한), channel 0 JSON-RPC 짝짓기,
  CREDIT 계산, HcEventStore(snapshot, seq, `missed`, 원격 `created` 재전송), 7501→PaneState
  매핑과 hook 병합 규칙(§6.6), turn 중복 알림 방지, `PaneRecord.paneId`/`backend`
  마이그레이션, label 대응(`termy.instance` 거르기 포함)과 고아 terminal 처리, hook 세부
  정보 저장·복원, hc를 쓸 수 없을 때 local로 바꾸지 않는 복원 규칙, teardown의 "창 닫기
  vs 앱 종료" 구분, UpdateRelaunchGate가 local pane만 세는지, `env -u` argv 생성.
- **회귀:** local PTY 경로는 기본 경로이므로 backend 경계로 옮긴 뒤에도 기존 테스트가
  전부 통과해야 한다.
- **통합:** 실제 hc를 테스트 전용 `HC_SESSION`과 임시 XDG 경로로 띄워(hc 문서의 권고)
  run/attach/kill/keep/restarted를 확인한다. 사용자의 core를 건드리지 않는다.
- **실제 동작 확인:** 입력·IME·kitty 경로는 단위 테스트로 증명되지 않는다. 실제 termy를
  띄워 확인한다. 이 세션이 termy 안에서 돌고 있으면 termy를 다시 띄울 수 없으니 사용자에게
  요청한다.

## 11. 빌더에게 맡기는 것

- 타입·파일 이름과 나누는 방식, HcConnection의 동시성 구조.
- 재연결 간격, `history` 줄 수, 숨긴 project pane을 attach한 채로 둘지 떼었다가 보일 때
  다시 붙일지.
- UI 문구(앱 UI는 영어), 시트·설정 화면 배치, ⌘K에서 원격 project를 보여 주는 모양.
- hc 실행 파일·socket 찾기의 세부 규칙.
- Windows 머신 판별 방법.

## 12. 롤백

기본값이 local PTY이므로, 로컬 hc 설정을 끄고 원격 project를 쓰지 않으면 지금 동작과
같다. 문제가 생기면 이 둘을 쓰지 않는 것으로 롤백한다. 이미 띄운 hc terminal은 hc에 남고,
`hc ls` / `hc kill`로 정리할 수 있다.

## 13. 작업량

큰 작업이다. 계층이 여럿이다: hc 연결·codec, backend 경계와 뷰 재구성(local 경로 회귀
없이), 상태 병합, 세션 저장·복원, ⌘K 원격 project, 설치·버전 처리. spike를 먼저 하고,
계획은 spike 결과를 반영해 쓴다. 순서는 backend 경계(local만, 동작 변화 없음) → hc 연결과
원격 project → 로컬 hc 설정이 자연스럽다(빌더 판단).

## 14. 영향 파일

- `Pane.swift`: 생성, 환경, delegate, resume 기록, 시작 입력.
- `TermyTerminalView.swift`: 상속 대상, `dataReceived`, `send`, 크기.
- `ForegroundProcessWatcher.swift`: hc pane에서는 hc foreground로 대체.
- `HookDaemon.swift` / `HookEvent.swift` / `PaneState.swift`: 7501 병합, PtyExit, synthetic
  이벤트 입력.
- `Workspace.swift`: teardown, 셸 종료 시 pane 닫기, 원격 project의 새 pane.
- `MainWindowController.swift` / `SessionRecord.swift` / `WorkspaceRecord.swift` /
  `WindowManager.swift`: paneId·backend·hook 세부 정보 저장, label 기반 복원, `machine` 필드.
- `ProjectSwitcherPanel.swift`: 원격 project, 머신 목록, 설치 시트 진입.
- `AgentResume.swift` / `StartupInputScheduler.swift` / `UpdateRelaunchGate.swift` /
  `Updater.swift`: local 백엔드 pane에만 적용.
- `AppDelegate.swift`: 종료 중 표시(teardown 구분), hc 연결의 지연 시작.
- 설정 화면: "Run local panes in herdr-core", hc 버전·연결 상태.
- 새 파일: hc 연결·codec·event store·backend.
- `apps/termy-hook/Sources/main.swift`, `apps/termy/Resources/opencode-plugin/tui.js`:
  바뀌지 않는다(환경 변수는 그대로 들어온다). 확인만.

## 15. 관련

- `herdrdev/herdr-core`: `schema/README.md`, `docs/security.md`, `docs/machines.md`.
- `docs/superpowers/specs/2026-10-10-agent-resume-after-update-design.md`.
- Fut, Codex integration: <https://fut.sh/agents/codex/>.
- 메모: SwiftTerm fork 주의점, IME/kitty 변경은 실제 동작으로 확인할 것.

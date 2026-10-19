# opencode 지원(pane 상태 표시) — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** termy pane에서 실행한 opencode v2 TUI의 상태(THINK · WAIT · IDLE · ERR)와 알림을 Claude Code · Codex · agy처럼 보여 준다.

**Architecture:** termy가 앱 번들에 넣어 둔 opencode TUI plugin(`tui.js`)을 `~/.config/opencode/plugins/termy/`에 설치한다. plugin은 pane마다 도는 TUI 프로세스 안에서 화면에 떠 있는 root 세션의 phase를 계산하고, phase가 바뀔 때 기존 `termy-hook --agent opencode AgentStatus`를 실행한다. termy는 새 wire 이벤트 `AgentStatus` 하나를 `PaneStateMachine`의 case 하나로 처리하고, 나머지(알림음, 30초 IDLE 타이머, 대시보드)는 기존 부품을 그대로 쓴다.

**Tech Stack:** Swift 6, AppKit, XCTest, JavaScriptCore(테스트 전용 시스템 프레임워크), XcodeGen(`project.yml`), opencode v2 2.0.32 TUI plugin API(ESM JavaScript, Bun 런타임), tmux(spike · 통합 확인용).

**Spec:** `docs/superpowers/specs/2026-10-19-opencode-support-design.md`

## Global Constraints

- Swift 6 언어 모드, macOS 14 deployment target. 새 코드는 strict concurrency에서 경고 없이 컴파일돼야 한다.
- SwiftTerm `exactVersion: "1.20.0"`, Sparkle `2.6.4`, TOMLKit `from: "0.6.0"`, swift-markdown `exactVersion: "0.9.0"`은 그대로 둔다. **새 패키지를 추가하지 않는다.** JavaScriptCore는 테스트 target에서만 `import`한다.
- **새 `.swift` 파일을 만들거나 `project.yml`을 고치면 반드시 `xcodegen generate`를 실행**한다. `termy.xcodeproj/`와 `Package.resolved`는 커밋하지 않는다.
- 테스트 명령(모든 태스크 공통):
  `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25`
  → `** TEST SUCCEEDED **`. `-derivedDataPath`와 `-skipPackagePluginValidation`을 빼면 이 환경에서 EPERM이나 plugin 검증 오류가 난다. 여러 클래스는 `-only-testing`을 반복한다.
- **Task 1–5에서는 termy.app을 실행하지 않는다.** `scripts/relaunch.sh`, `open termy.app`, Debug 빌드 실행 모두 금지다. 이 세션은 termy pane 안에서 돌고 있고(`TERMY_PANE_ID` 설정됨), 두 번째 인스턴스는 hook socket(`/tmp/termy-$UID.sock`)과 `session.json`을 가로챈다. XCTest host로 뜨는 것은 괜찮다(`AppDelegate.swift:55`의 `TestHostDetector` guard).
- **Task 1–5에서는 사용자의 `~/.config/opencode`와 공유 opencode 서비스(`opencode serve --service`)를 건드리지 않는다.** opencode는 `--standalone`과 임시 `XDG_CONFIG_HOME=/tmp/termy-oc-spike/config`로만 띄우고, plugin은 그 임시 config의 global plugin 위치(`/tmp/termy-oc-spike/config/opencode/plugins/<dir>/tui.js`)에 둔다. 설치기 테스트는 임시 디렉터리를 쓴다.
- **opencode DB는 사용자 것을 그대로 쓴다**(결정 `e79a31af`). `OPENCODE_DB`를 지정하지 않는다. 임시 DB를 쓰면 DB에 저장된 DeepSeek 인증이 사라지고, 최근 model이 `deepseek/deepseek-flash`라서 첫 prompt가 실패한다. spike 세션은 Task 1 Step 7과 Task 4 Step 7 끝에서 `opencode session delete`로 지운다.
- 테스트 card(spec 수용 기준 16): 새 테스트 파일은 머리 주석에, 기존 파일에 추가하는 opencode 테스트는 그 파일 끝에 새로 만드는 `// MARK: - OpenCode…` 구역 바로 아래 주석에 spec §8 "행별 card"의 해당 행을 `protects=… fails_when=… no_claim=…` 한 줄로 적는다. 행의 card와 다른 것을 지키는 테스트에만 개별 card를 붙인다.
- 확인 기준 opencode 버전은 `opencode --version` → `opencode v2.0.32`다. 다르면 Task 1 결과에 버전을 적는다.
- wire 값(그대로 쓴다): event `"AgentStatus"`, agent `"opencode"`, reason `"idle"` · `"running"` · `"permission"` · `"question"` · `"succeeded"` · `"failed"`. `AgentKind.opencode.displayName`은 `"OpenCode"`.
- plugin 파일 고정 문자열(그대로 쓴다):
  - 첫 줄: `// termy-managed opencode plugin. termy rewrites this file; do not edit.`
  - 경로 placeholder(따옴표 포함): `"__TERMY_HOOK_PATH__"`
  - pure 영역 경계: `// #region termy-pure`, `// #endregion termy-pure`
- 앱 UI 문구는 영어이며 Task 5의 문자열을 그대로 쓴다. 메뉴 항목은 `"OpenCode Plugin…"`(말줄임표는 U+2026).
- 커밋 메시지는 한국어, `Co-Authored-By` 라인을 넣지 않는다. 접두사는 기존 관례(`feat(agent):`, `test(agent):`, `docs(spec):`, `docs(changelog):`)를 따른다.
- 주석 밀도와 스타일은 주변 코드를 따른다. 파일 머리 주석에 "왜"를 쓰고, 타입 · 메서드에는 `///` 한두 줄을 붙인다.

## Review Focus

spec이 암시하지만 수용 기준이 직접 짚지 않는 입력 가운데, 실제로 부딪히기 쉬운 순서로 적는다. 각 줄의 테스트는 해당 태스크에 들어 있다.

1. **subagent(자식 세션)가 권한을 묻는 경우**: root가 running이어도 pane은 WAIT가 돼야 한다. → Task 4 `testView_childSessionPermission_countsForRoot`
2. **prompt를 큐에 넣어 둔 경우**(status는 idle, synthetic이 아닌 pending 있음): THINK여야 한다. synthetic pending만 있으면 idle이다. → Task 4 `testView_pendingNonSyntheticIsBusy_syntheticIsNot`
3. **권한과 question이 동시에 걸렸다가 권한만 답한 경우**: WAIT를 유지하고 알림음이 다시 울리지 않아야 한다(이유만 `ask_user_question`으로 바뀜). → Task 4 `testPhase_precedence_permissionQuestionRunningIdle`, Task 3 `test_opencodeAgentStatus_questionAfterPermission_staysWaiting`
4. **긴 경로나 한글 경로의 cwd**: payload가 PIPE_BUF 아래로 유지돼야 한다(480바이트를 넘으면 cwd를 뺀다). UTF-16 단위가 아니라 UTF-8 바이트로 잰다. → Task 4 `testPayload_dropsCwdPast480Bytes`, `testPayload_countsUtf8BytesNotUtf16Units`
5. **`termy-hook`이 없거나 spawn이 실패하는 경우**(termy를 지웠거나 옮김): plugin이 예외를 밖으로 내지 않고, 뒤에 넣은 전송이 순서대로 나가야 한다. JavaScriptCore에서는 spawn을 돌릴 수 없어 live로 확인한다. → Task 1 S3(spike queue), Task 4 Step 7의 "spawn 실패 뒤 복구" sub-case(실제 plugin의 `send`)

## 파일 구조

| 파일 | 역할 | 태스크 |
|---|---|---|
| `docs/superpowers/specs/2026-10-19-opencode-support-design.md` (수정) | §6 spike 결과, 상태 줄 | 1, 6 |
| `apps/termy/Sources/AgentKind.swift` (수정) | `.opencode` case | 2 |
| `apps/termy/Sources/ForegroundProcessWatcher.swift` (수정) | `opencode` 프로세스 감지 | 2 |
| `apps/termy/Sources/AgentResume.swift` (수정) | `make` opencode case, capture에서 opencode 제외 | 2 |
| `apps/termy/Sources/AgentResumeFlags.swift` (수정) | opencode 빈 표 | 2 |
| `apps/termy/Sources/Pane.swift` (수정) | `OPENCODE_TERMINAL`, `OPENCODE_SESSION_ID` scrub | 2 |
| `apps/termy/Sources/HookEvent.swift` (수정) | `HookEventKind.agentStatus` | 3 |
| `apps/termy/Sources/PaneState.swift` (수정) | `.agentStatus` 전이 | 3 |
| `apps/termy/Sources/Notifier.swift` (수정) | `WaitAlertRule`, 세션 전환으로 생긴 WAIT는 알리지 않음 | 3 |
| `apps/termy-hook/Sources/HookCLI.swift`, `main.swift` (수정) | 사용 예 주석만 | 3 |
| `apps/termy/Resources/opencode-plugin/tui.js` (신규) | opencode TUI plugin | 4 |
| `project.yml` (수정) | `opencode-plugin` 폴더를 리소스로 복사 | 4 |
| `apps/termy/Sources/OpenCodePluginInstaller.swift` (신규) | 설치 · 갱신 · 해제, 메뉴 알림창 | 5 |
| `apps/termy/Sources/AppDelegate.swift` (수정) | 실행 시 갱신, 메뉴 항목 | 5 |
| `CHANGELOG.md` (수정) | Unreleased 항목 | 6 |
| 테스트 (수정) `AgentKindTests`, `ForegroundProcessWatcherTests`, `AgentResumeCaptureTests`, `AgentResumeCommandTests`, `PaneShellEnvironmentTests`, `HookCLITests` | | 2, 3 |
| 테스트 (신규) `NotifierWaitAlertRuleTests` | | 3 |
| 테스트 (신규) `OpenCodePluginScriptTests`, `OpenCodePluginInstallerTests` | | 4, 5 |

의존 관계: Task 1(gate) → Task 2 → Task 3. Task 4는 Task 1 뒤 언제든 할 수 있고, Task 5는 Task 4의 템플릿이 있어야 한다. Task 6은 마지막이다.

---

### Task 1: spike — opencode v2 TUI plugin 동작 확인(gate)

소스로만 확인한 가정(spec §6 S1~S6)을 실제 opencode 2.0.32로 확인한다. spike 코드는 커밋하지 않고 결과만 spec에 적는다. **S1~S3 중 하나라도 실패하면 Task 2 이후를 진행하지 않고 보고한다.**

**Files:**
- Create(커밋 안 함): `/tmp/termy-oc-spike/config/opencode/plugins/termy-spike/tui.js`, `/tmp/termy-oc-spike/work/.env`
- Modify: `docs/superpowers/specs/2026-10-19-opencode-support-design.md` §6
- Commit(Step 1): `docs/superpowers/specs/2026-10-19-opencode-support-design.md`, `docs/superpowers/plans/2026-10-19-opencode-support.md`

**Interfaces:**
- Produces: spike harness 디렉터리 `/tmp/termy-oc-spike/`(Task 4 Step 7이 다시 쓴다)와 tmux 실행 형식. `TERMY_PANE_ID`는 이 세션이 도는 pane의 실제 값을 tmux server가 물려받으므로 반드시 덮어쓴다.
  `tmux new-session -d -s oc-spike -x 200 -y 50 "cd /tmp/termy-oc-spike/work && env TERMY_PANE_ID=spike-pane XDG_CONFIG_HOME=/tmp/termy-oc-spike/config opencode --standalone"`

- [x] **Step 1: 문서 커밋**(2026-10-19 완료, `feat/opencode-support` 브랜치)

spec과 이 plan을 구현 전에 먼저 커밋한다.

```bash
git add docs/superpowers/specs/2026-10-19-opencode-support-design.md docs/superpowers/plans/2026-10-19-opencode-support.md
git commit -m "docs(opencode): opencode 지원 설계 문서와 구현 계획을 추가"
```

- [x] **Step 2: harness 준비**

```bash
SPIKE=/tmp/termy-oc-spike
rm -rf "$SPIKE" && mkdir -p "$SPIKE/work" "$SPIKE/config/opencode/plugins/termy-spike"
git -C "$SPIKE/work" init -q
printf 'SPIKE_VALUE=1\n' > "$SPIKE/work/.env"
opencode --version
(cd "$SPIKE/work" && opencode auth list --standalone)
```

Expected: `opencode v2.0.32`. `auth list --standalone`에 평소 쓰는 provider(DeepSeek `stored`)가 보인다. 사용자 DB를 그대로 쓰기 때문이다(`--standalone` 없이 실행하면 공유 서비스의 결과가 나오므로 반드시 붙인다). 보이지 않으면 멈추고 보고한다.

- [x] **Step 3: logging plugin 작성**

`termy-spike/tui.js`는 `export default { id: "termy-spike", setup(ctx) { … } }` 형식이고, 모든 기록을 `/tmp/termy-oc-spike/log.jsonl`에 JSON 한 줄씩 덧붙인다(`node:fs`의 `appendFileSync`). 기록할 것:

1. setup 직후: `{"t":"setup","pane":process.env.TERMY_PANE_ID,"pid":process.pid,"cwd":process.cwd()}`
2. S3: setup에서 `node:child_process.spawn("/bin/sh", ["-c", "cat >> /tmp/termy-oc-spike/spawn.log"], {stdio: ["pipe","ignore","ignore"]})`의 stdin에 `{"hello":1}`을 쓰고 닫는다. 이어서 `/nonexistent/termy-hook`을 spawn한다(`error` 핸들러를 달고 try/catch로 감싼다). 그다음 spec §4.2 glue와 같은 방식의 promise queue로 `sh -c 'sleep 0.2; echo N >> /tmp/termy-oc-spike/order.log'`를 N=1, 2, 3 차례로 넣는다.
3. `ctx.data.on("session.execution.started" | "succeeded" | "failed" | "interrupted")` 핸들러: `{"t":"exec","type":…,"sessionID":event.data.sessionID,"reason":event.data.reason,"seq":n}`. `seq`는 plugin 안의 단조 증가 카운터다.
4. `ctx.data.listen` 핸들러에서 `setTimeout(…, 0)`으로 미룬 뒤: `{"t":"view","seq":n,"event":event.details.type,"route":ctx.ui.router.current(),"status":…,"permissions":…,"forms":…}`. route가 session이면 그 root와 family의 `status`, `permission.list(id)?.length`, `form.list(id)?.length`를 담는다.
5. cleanup: `{"t":"cleanup"}`

- [x] **Step 4: S1 · S2 · S3 확인**

먼저 TUI 없이 탐색 경로를 확인한다. TUI와 같은 탐색 함수(`localPluginDirectories(process.cwd(), global.config)`)를 쓰는 명령이다.

```bash
(cd /tmp/termy-oc-spike/work && XDG_CONFIG_HOME=/tmp/termy-oc-spike/config opencode plugin list)
```

Expected: `SOURCE`에 `/tmp/termy-oc-spike/config/opencode/plugins/termy-spike`가 나온다. 이어서 tmux 형식(Interfaces)으로 띄우고 5초 기다린 뒤:

```bash
tmux capture-pane -p -t oc-spike | tail -15
cat /tmp/termy-oc-spike/log.jsonl | head -5
cat /tmp/termy-oc-spike/spawn.log /tmp/termy-oc-spike/order.log
```

Expected: `log.jsonl`에 setup 줄이 있고 `"pane":"spike-pane"`이다(S1, S2). `spawn.log`는 `{"hello":1}`, `order.log`는 `1`, `2`, `3` 순서다(S3). TUI 화면에 plugin 오류나 신뢰 확인 창이 떠 있으면 그 내용을 결과에 적는다.

- [x] **Step 5: S4 확인(turn 하나)**

```bash
tmux send-keys -t oc-spike 'Reply with the single word ok.' Enter
sleep 20
```

Expected(`log.jsonl`): `exec started` → `view`(status running) → `exec succeeded` → 그 뒤의 `view`(status idle). 같은 이벤트에서 `exec` 줄의 seq가 `view` 줄보다 작아야 한다(핸들러가 미룬 계산보다 먼저 돎). route는 `{"type":"session","sessionID":"ses_…"}`다.

- [x] **Step 6: S5 확인(권한, question, Esc)**

```bash
tmux send-keys -t oc-spike 'Read the file .env and tell me its first line.' Enter
sleep 15; tmux capture-pane -p -t oc-spike | tail -20
```

권한 대화상자가 뜨면 `view` 줄의 `permissions`가 1 이상인지 확인하고, tmux로 승인한다(화면에 보이는 승인 키를 `tmux send-keys`로 보냄). 이어서:

```bash
tmux send-keys -t oc-spike 'Use the question tool to ask me to choose between A and B.' Enter
```

question 화면이 떠 있는 동안 `forms`가 1 이상이어야 한다. 답한 뒤에는 0이어야 한다. 마지막으로 오래 걸리는 prompt(`Count from 1 to 300, one number per line.`)를 보내고 2초 뒤 `tmux send-keys -t oc-spike Escape`를 보내, `exec interrupted`와 `reason`(예: `user`)을 확인한다. 권한 창이 뜨지 않으면 opencode v2 permission 문서(https://opencode.ai/v2/docs/config/)를 보고 `work/opencode.json`에서 read를 `ask`로 설정해 다시 해 본다.

- [x] **Step 7: S6 확인(파일 갱신 시 다시 로드)**

TUI가 떠 있는 상태에서 `/tmp/termy-oc-spike/config/opencode/plugins/termy-spike/tui.js` 끝에 공백 줄을 하나 덧붙이고 5초 기다린다.

Expected: `log.jsonl`에 `cleanup` 다음 `setup`이 새로 찍힌다.

- [x] **Step 8: 정리와 기록**

```bash
tmux kill-session -t oc-spike
cd /tmp/termy-oc-spike/work && opencode session list
```

`session list`에 나온 spike 세션(이 디렉터리에서 만든 것)을 하나씩 `opencode session delete <id>`로 지우고, 다시 `session list`로 비었는지 확인한다. 이 디렉터리 밖의 세션은 건드리지 않는다.

spec §6 표 아래에 `### 결과(2026-MM-DD, opencode vX)` 절을 추가하고 S1~S6마다 통과 여부와 근거(로그 줄 요약)를 적는다. S4에서 종료 이벤트가 미룬 계산보다 늦게 왔다면 spec §6 판정 규칙대로 "종료 이벤트 핸들러에서도 `schedule()`을 부른다"를 §4.2 glue에 반영하고 그 사실을 적는다. S5 · S6이 실패했다면 해당 기능을 spec §2로 옮기고 §7의 관련 수용 기준을 고친다. `/tmp/termy-oc-spike`는 Task 4 Step 7을 위해 남겨 둔다(logging plugin 폴더만 지운다: `rm -rf /tmp/termy-oc-spike/config/opencode/plugins/termy-spike`).

- [x] **Step 9: Commit**

```bash
git add docs/superpowers/specs/2026-10-19-opencode-support-design.md
git commit -m "docs(spec): opencode TUI plugin spike 결과를 설계 문서에 기록"
```

---

### Task 2: AgentKind.opencode, 프로세스 감지, 재개 제외, env scrub

`AgentKind`에 case를 추가하면 exhaustive switch 세 곳(`AgentKind.swift`, `AgentResume.swift:29`, `AgentResumeFlags.swift:68`)이 함께 바뀌어야 컴파일된다. 그래서 한 태스크로 묶는다.

**Files:**
- Modify: `apps/termy/Sources/AgentKind.swift:1-49`
- Modify: `apps/termy/Sources/ForegroundProcessWatcher.swift:1-27,180-233`
- Modify: `apps/termy/Sources/AgentResume.swift:25-40,68-92`
- Modify: `apps/termy/Sources/AgentResumeFlags.swift:64-75`
- Modify: `apps/termy/Sources/Pane.swift:226-245`
- Test: `apps/termy-tests/Sources/AgentKindTests.swift`, `ForegroundProcessWatcherTests.swift`, `AgentResumeCaptureTests.swift`, `AgentResumeCommandTests.swift`, `PaneShellEnvironmentTests.swift`

**Interfaces:**
- Produces: `AgentKind.opencode`(`wireName == "opencode"`, `displayName == "OpenCode"`), `AgentKind.from(rawAgent: "opencode") == .opencode`. Task 3이 쓴다.

- [x] **Step 1: 실패하는 테스트 작성**

각 파일 끝에 `// MARK: - OpenCode` 구역을 만들고 그 아래에 둔다(card 주석은 Global Constraints). `AgentKindTests.swift`:

```swift
    func test_from_opencode_returnsOpenCode() {
        XCTAssertEqual(AgentKind.from(rawAgent: "opencode"), .opencode)
    }

    func test_opencode_wireNameAndDisplayName() {
        XCTAssertEqual(AgentKind.opencode.wireName, "opencode")
        XCTAssertEqual(AgentKind.opencode.displayName, "OpenCode")
    }
```

`ForegroundProcessWatcherTests.swift`:

```swift
    func test_classifyAgent_opencode() {
        XCTAssertEqual(ForegroundProcessWatcher.classifyAgent(by: "opencode"), .opencode)
        XCTAssertEqual(ForegroundProcessWatcher.classifyAgent(by: "opencode-dev"), .opencode)
        XCTAssertEqual(ForegroundProcessWatcher.classifyAgent(by: "OpenCode"), .opencode)
        XCTAssertNil(ForegroundProcessWatcher.classifyAgent(by: "opencoder"))
    }

    func test_agentEntrypoint_opencodeNativeBinary_isIndexZero() {
        // Homebrew opencode-v2 is a single Mach-O binary; the Cellar path
        // contains "opencode-v2" but the basename is "opencode".
        let argv = ["/opt/homebrew/Cellar/opencode-v2/2.0.32/bin/opencode", "-c"]
        let entry = ForegroundProcessWatcher.agentEntrypoint(in: argv)
        XCTAssertEqual(entry?.index, 0)
        XCTAssertEqual(entry?.kind, .opencode)
    }
```

`AgentResumeCaptureTests.swift`:

```swift
    func test_opencodeForeground_isNil() {
        // termy does not resume opencode sessions yet (spec 2026-10-19 §2).
        XCTAssertNil(capture(
            agent: .opencode,
            argv: ["opencode", "-c"],
            snapshot: snapshot(kind: .opencode, sessionId: "ses_0123456789abcdefABCDEFGHIJ")
        ))
    }
```

`AgentResumeCommandTests.swift`:

```swift
    // Unreachable today: AgentResumeCapture never records opencode. The case
    // exists to keep `make`'s switch exhaustive; this pins the command a later
    // resume task would turn on.
    func test_opencode_unreachableCommand_usesSessionFlag() {
        XCTAssertEqual(
            AgentResumeCommand.make(record(.opencode, id: "ses_0123456789abcdefABCDEFGHIJ")),
            "opencode --session ses_0123456789abcdefABCDEFGHIJ"
        )
    }
```

`PaneShellEnvironmentTests.swift`: `markers` 배열 끝에 `"OPENCODE_TERMINAL", "OPENCODE_SESSION_ID",`를 추가하고(`testStripsEverySessionMarker`가 함께 확인함), 새 테스트:

```swift
    func testKeepsOpenCodeUserConfiguration() {
        let env = make([
            "OPENCODE_CONFIG_DIR": "/Users/x/oc",
            "OPENCODE_SERVER_PASSWORD": "pw",
            "OPENCODE_TERMINAL": "1",
        ])
        XCTAssertEqual(env["OPENCODE_CONFIG_DIR"], "/Users/x/oc")
        XCTAssertEqual(env["OPENCODE_SERVER_PASSWORD"], "pw")
        XCTAssertNil(env["OPENCODE_TERMINAL"])
    }
```

- [x] **Step 2: 실패 확인**

Run: 테스트 명령, `-only-testing:termy-tests/AgentKindTests -only-testing:termy-tests/ForegroundProcessWatcherTests -only-testing:termy-tests/AgentResumeCaptureTests -only-testing:termy-tests/AgentResumeCommandTests -only-testing:termy-tests/PaneShellEnvironmentTests`
Expected: 컴파일 실패, `type 'AgentKind' has no member 'opencode'`

- [x] **Step 3: 구현**

- `AgentKind.swift`: `case opencode` 추가. `wireName` → `"opencode"`, `displayName` → `"OpenCode"`, `from(rawAgent:)`에 `case "opencode": return .opencode`. 머리 주석의 wire 문자열 목록에 `"antigravity"`, `"opencode"`를 넣는다.
- `ForegroundProcessWatcher.swift`: `classifyAgent(by:)`와 `agentEntrypoint(in:)`에서 agy 검사 바로 뒤, claude 검사 앞에 `name == "opencode" || name.hasPrefix("opencode-")`(소문자화한 값, `agentEntrypoint`에서는 basename)를 `.opencode`로 매칭한다. 머리 주석 4-6행의 agent 목록을 `claude`, `codex`, `agy`, `opencode`로 고친다.
- `AgentResume.swift`: `make`에 `case .opencode: words = ["opencode", "--session", id] + flags`. `AgentResumeCapture.record`의 guard에 `kind != .opencode`를 추가하고 한 줄 주석을 단다: `// termy does not resume opencode sessions yet (spec 2026-10-19 §2).`
- `AgentResumeFlags.swift`: switch에 `case .opencode: table = [:]`.
- `Pane.swift`: `agentSessionMarkerEnvKeys` 끝에 `"OPENCODE_TERMINAL", "OPENCODE_SESSION_ID",`를 추가하고, 배열 위 주석에 opencode가 셸 도구 자식에게 넣는 표식이라는 말을 덧붙인다.

- [x] **Step 4: 통과 확인**

Run: Step 2와 같은 명령
Expected: `** TEST SUCCEEDED **`

- [x] **Step 5: Commit**

```bash
git add apps/termy/Sources/{AgentKind,ForegroundProcessWatcher,AgentResume,AgentResumeFlags,Pane}.swift apps/termy-tests/Sources/{AgentKindTests,ForegroundProcessWatcherTests,AgentResumeCaptureTests,AgentResumeCommandTests,PaneShellEnvironmentTests}.swift
git commit -m "feat(agent): opencode를 AgentKind로 추가하고 프로세스를 감지함"
```

---

### Task 3: AgentStatus wire 이벤트, 상태 머신, 알림 판정

**Files:**
- Modify: `apps/termy/Sources/HookEvent.swift:13-31,65`
- Modify: `apps/termy/Sources/PaneState.swift:1-43,208-233,481-488`
- Modify: `apps/termy/Sources/Notifier.swift:34,56-72,97`
- Modify: `apps/termy-hook/Sources/HookCLI.swift:37-42`, `apps/termy-hook/Sources/main.swift:8-15`(주석만)
- Test: `apps/termy-tests/Sources/AgentKindTests.swift`, `apps/termy-tests/Sources/HookCLITests.swift`, `apps/termy-tests/Sources/NotifierWaitAlertRuleTests.swift`(신규)

**Interfaces:**
- Consumes: `AgentKind.opencode`(Task 2)
- Produces: `HookEventKind.agentStatus`(raw `"AgentStatus"`). Task 4의 plugin이 이 이름과 reason 어휘로 보낸다.
- Produces: `Notifier.swift` 최상위의 판정 타입(`@MainActor`가 아님):

```swift
enum WaitAlertRule {
    struct Observation: Equatable {
        var state: PaneState
        var sessionId: String?
    }
    /// True when a pane starts needing the user: it enters WAITING from a
    /// non-WAITING state without switching between two known sessions.
    static func shouldAlert(previous: Observation?, next: Observation) -> Bool
}
```

- [x] **Step 1: 실패하는 테스트 작성**

`AgentKindTests.swift` 끝에 `// MARK: - OpenCode AgentStatus`와 helper:

```swift
    private func opencodeStatus(_ reason: String?, sessionId: String? = "ses_a") -> HookEvent {
        var meta = HookEvent.Meta()
        meta.reason = reason
        meta.sessionId = sessionId
        return HookEvent(event: .agentStatus, paneId: "p1", projectId: nil, ts: 1.0, agent: "opencode", meta: meta)
    }

    private func opencodeSnapshot(
        _ state: PaneState, reason: String? = nil, attention: Bool = false, turnOpen: Bool = false
    ) -> PaneSnapshot {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .opencode)
        s.state = state
        s.notificationReason = reason
        s.needsAttention = attention
        s.turnOpen = turnOpen
        s.lastSessionId = "ses_a"
        s.enteredStateAt = Date(timeIntervalSince1970: 100)
        return s
    }
```

테스트(각각 spec §4.4 표 한 줄씩):

```swift
    func test_hookEvent_decodesOpenCodeAgentStatus() throws {
        let json = #"{"event":"AgentStatus","pane_id":"p1","project_id":null,"ts":1,"agent":"opencode","meta":{"reason":"running","session_id":"ses_x"}}"#
        let e = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.event, .agentStatus)
        XCTAssertEqual(e.agentKind, .opencode)
        XCTAssertEqual(e.meta.reason, "running")
        XCTAssertEqual(e.meta.sessionId, "ses_x")
    }

    func test_opencodeAgentStatus_running_setsThinking() {
        let after = PaneStateMachine.apply(opencodeStatus("running"),
                                           to: opencodeSnapshot(.waiting, reason: "permission", attention: true, turnOpen: true))
        XCTAssertEqual(after.state, .thinking)
        XCTAssertFalse(after.needsAttention)
        XCTAssertNil(after.notificationReason)
        XCTAssertNil(after.waitSource)
        XCTAssertTrue(after.turnOpen)
    }

    // protects=permission wait raises attention; fails_when=state stays THINK or attention false;
    // no_claim=that the plugin detects permissions (Task 1 S5, Task 6 M3)
    func test_opencodeAgentStatus_permission_entersWaitingWithAttention() {
        let after = PaneStateMachine.apply(opencodeStatus("permission"), to: opencodeSnapshot(.thinking, turnOpen: true))
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "permission")
        XCTAssertNil(after.waitSource)
        XCTAssertTrue(after.turnOpen)
    }

    func test_opencodeAgentStatus_question_entersWaitingAskUserQuestion() {
        let after = PaneStateMachine.apply(opencodeStatus("question"), to: opencodeSnapshot(.thinking, turnOpen: true))
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "ask_user_question")
        XCTAssertTrue(after.turnOpen)
    }

    func test_opencodeAgentStatus_succeeded_entersTurnEndWaiting() {
        let after = PaneStateMachine.apply(opencodeStatus("succeeded"), to: opencodeSnapshot(.thinking, turnOpen: true))
        XCTAssertEqual(after.state, .waiting)
        XCTAssertFalse(after.needsAttention)   // lets HookDaemon.tickIdle move it to IDLE after 30s
        XCTAssertNil(after.notificationReason)
        XCTAssertNil(after.waitSource)
        XCTAssertFalse(after.turnOpen)
    }

    func test_opencodeAgentStatus_failed_setsErrored() {
        let after = PaneStateMachine.apply(opencodeStatus("failed"), to: opencodeSnapshot(.thinking, turnOpen: true))
        XCTAssertEqual(after.state, .errored)
        XCTAssertFalse(after.needsAttention)
        XCTAssertFalse(after.turnOpen)
    }

    func test_opencodeAgentStatus_idle_setsIdleWithoutAttention() {
        let after = PaneStateMachine.apply(opencodeStatus("idle"), to: opencodeSnapshot(.thinking, turnOpen: true))
        XCTAssertEqual(after.state, .idle)
        XCTAssertFalse(after.needsAttention)
        XCTAssertNil(after.notificationReason)
        XCTAssertFalse(after.turnOpen)
    }

    func test_opencodeAgentStatus_unknownReason_keepsState() {
        let before = opencodeSnapshot(.thinking, turnOpen: true)
        let after = PaneStateMachine.apply(opencodeStatus("compacting"), to: before)
        XCTAssertEqual(after.state, .thinking)
        XCTAssertTrue(after.turnOpen)
        XCTAssertEqual(after.enteredStateAt, before.enteredStateAt)
    }

    func test_opencodeAgentStatus_repeatedWait_keepsEnteredStateAt() {
        let entered = Date(timeIntervalSince1970: 100)
        let perm = PaneStateMachine.apply(opencodeStatus("permission"),
                                          to: opencodeSnapshot(.waiting, reason: "permission", attention: true, turnOpen: true))
        XCTAssertEqual(perm.enteredStateAt, entered)
        let done = PaneStateMachine.apply(opencodeStatus("succeeded"), to: opencodeSnapshot(.waiting))
        XCTAssertEqual(done.enteredStateAt, entered)
    }

    func test_opencodeAgentStatus_questionAfterPermission_staysWaiting() {
        let after = PaneStateMachine.apply(opencodeStatus("question"),
                                           to: opencodeSnapshot(.waiting, reason: "permission", attention: true, turnOpen: true))
        XCTAssertEqual(after.state, .waiting)   // Notifier chimes only on entering WAITING
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "ask_user_question")
    }

    func test_opencodeAgentStatus_newSessionId_resetsThenApplies() {
        let before = opencodeSnapshot(.thinking, turnOpen: true)
        let after = PaneStateMachine.apply(opencodeStatus("running", sessionId: "ses_b"), to: before)
        XCTAssertEqual(after.state, .thinking)
        XCTAssertEqual(after.lastSessionId, "ses_b")
        // Same-session THINK → THINK keeps enteredStateAt; a reset to INIT
        // first makes this a fresh entry into THINK.
        XCTAssertGreaterThan(after.enteredStateAt, before.enteredStateAt)

        // The reset clears attention, so a new session's permission must
        // raise it again even though the pane was already WAIT(permission).
        let waiting = opencodeSnapshot(.waiting, reason: "permission", attention: true, turnOpen: true)
        let other = PaneStateMachine.apply(opencodeStatus("permission", sessionId: "ses_b"), to: waiting)
        XCTAssertEqual(other.state, .waiting)
        XCTAssertTrue(other.needsAttention)
        XCTAssertEqual(other.notificationReason, "permission")
        XCTAssertEqual(other.lastSessionId, "ses_b")
    }

    func test_opencodeSyntheticSessionStart_promotesOnlyFromInit() {
        let start = HookEvent(event: .sessionStart, paneId: "p1", projectId: nil, ts: 1.0,
                              agent: "opencode", meta: HookEvent.Meta())
        let fresh = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .opencode)
        XCTAssertEqual(PaneStateMachine.apply(start, to: fresh).state, .idle)
        XCTAssertEqual(PaneStateMachine.apply(start, to: opencodeSnapshot(.thinking, turnOpen: true)).state, .thinking)
    }
```

`HookCLITests.swift`:

```swift
    func test_agentOpenCode_passesThroughAsWireName() {
        XCTAssertEqual(
            HookCLI.parse(["termy-hook", "--agent", "opencode", "AgentStatus"]),
            ParsedHookArgs(agent: "opencode", event: "AgentStatus")
        )
    }

    func test_slimMeta_keepsOpenCodeAgentStatusFields() {
        let raw: [String: Any] = ["reason": "permission", "session_id": "ses_x", "cwd": "/w"]
        XCTAssertEqual(HookCLI.slimMeta(raw), ["reason": "permission", "session_id": "ses_x", "cwd": "/w"])
    }
```

`NotifierWaitAlertRuleTests.swift`(신규). 머리 주석에 spec §8 "알림 판정" 행의 card를 적는다.

```swift
import XCTest
@testable import termy

final class NotifierWaitAlertRuleTests: XCTestCase {
    private func obs(_ state: PaneState, _ session: String?) -> WaitAlertRule.Observation {
        WaitAlertRule.Observation(state: state, sessionId: session)
    }

    func test_enteringWaitInSameSession_alerts() {
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(.thinking, "s1"), next: obs(.waiting, "s1")))
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(.idle, "s1"), next: obs(.waiting, "s1")))
    }

    func test_stayingInWait_doesNotAlert() {
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(.waiting, "s1"), next: obs(.waiting, "s1")))
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(.thinking, "s1"), next: obs(.thinking, "s1")))
    }

    // protects=a tab/session switch onto a waiting session stays silent whatever the prior state;
    // fails_when=IDLE(A) → WAIT(B) or WAIT(A) → WAIT(B) alerts
    func test_waitReachedBySwitchingSessions_doesNotAlert() {
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(.idle, "s1"), next: obs(.waiting, "s2")))
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(.thinking, "s1"), next: obs(.waiting, "s2")))
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(.waiting, "s1"), next: obs(.waiting, "s2")))
    }

    func test_firstObservationOrUnknownSession_alerts() {
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: nil, next: obs(.waiting, "s1")))
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(.initializing, nil), next: obs(.waiting, "s1")))
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(.thinking, "s1"), next: obs(.waiting, nil)))
    }
}
```

- [x] **Step 2: 실패 확인**

Run: `xcodegen generate` 뒤 테스트 명령, `-only-testing:termy-tests/AgentKindTests -only-testing:termy-tests/HookCLITests -only-testing:termy-tests/NotifierWaitAlertRuleTests`
Expected: 컴파일 실패, `type 'HookEventKind' has no member 'agentStatus'`와 `cannot find 'WaitAlertRule' in scope`. (HookCLI 두 테스트는 코드 변경 없이 통과하는 것이 정상이다. 지금 동작을 고정하는 테스트다.)

- [x] **Step 3: 구현**

- `HookEvent.swift`: `HookEventKind`에 `case agentStatus = "AgentStatus" // opencode TUI plugin: derived pane status in meta.reason`. `Meta.reason` 주석에 `AgentStatus: "idle" | "running" | "permission" | "question" | "succeeded" | "failed"`를 덧붙인다.
- `PaneState.swift`: `apply`의 switch에 `case .agentStatus: applyAgentStatus(event.meta.reason, to: &next)`를 넣고, `private static func applyAgentStatus(_ reason: String?, to next: inout PaneSnapshot)`를 spec §4.4 표 그대로 구현한다. **비교 기준은 `previous`가 아니라 세션 리셋이 적용된 뒤의 `next`다**(함수 시작 시점의 `next.state` · `next.notificationReason`). 알려진 reason이면 state · needsAttention · notificationReason · waitSource · turnOpen을 항상 표의 값으로 쓰고, enteredStateAt만 표의 조건일 때 `next.updatedAt`으로 바꾼다. 모르는 reason이면 아무것도 바꾸지 않는다. agent 종류로 분기하지 않는다.
- `PaneState.swift` 머리 주석의 전이 목록에 다섯 줄을 추가한다:
  ```
  //   *(opencode) ──(AgentStatus running)─────────────▶ THINKING
  //   *(opencode) ──(AgentStatus permission|question)─▶ WAITING ♪
  //   *(opencode) ──(AgentStatus succeeded)───────────▶ WAITING ♪ (→ IDLE after 30s)
  //   *(opencode) ──(AgentStatus failed)──────────────▶ ERRORED
  //   *(opencode) ──(AgentStatus idle)────────────────▶ IDLE (no chime)
  ```
- `.sessionStart` case의 주석에 한 문단을 추가한다: opencode는 일부러 hard-reset 그룹에 넣지 않는다. 바로 일을 시작하면 plugin의 `running`이 watcher의 synthetic SessionStart(최대 1초 늦음)보다 먼저 올 수 있고, 시작 시 동기화는 plugin이 맡는다. **조건문은 바꾸지 않는다.** opencode는 이미 else 분기(INIT일 때만 IDLE)로 간다.
- `HookCLI.swift` `parse` 주석의 지원 형식에 `termy-hook --agent opencode AgentStatus → agent="opencode"`를, `main.swift` 머리 주석 사용 예에 `termy-hook --agent opencode AgentStatus   # opencode TUI plugin`을 추가한다.
- `Notifier.swift`: Interfaces의 `WaitAlertRule`을 파일 최상위(클래스 밖)에 둔다. `shouldAlert`는 `next.state == .waiting`, `previous?.state != .waiting`, 그리고 "직전 id와 새 id가 둘 다 있고 서로 다름"이 아닐 때 true다. `Notifier`의 `previousStates: [String: PaneState]`(`:34`)를 `[String: WaitAlertRule.Observation]`으로 바꾸고, `handle(_:)`(`:56-72`)에서 `guard isWaiting, prev != .waiting else { return }` 대신 `guard WaitAlertRule.shouldAlert(previous: prev, next: current) else { return }`를 쓴다(`current = Observation(state: snap.state, sessionId: snap.lastSessionId)`). `waitingPaneIds`와 dock badge 갱신은 바꾸지 않는다. `pruneWaitingPanes`(`:97`)의 `removeValue`는 타입만 따라간다. `WaitAlertRule` 위 주석에 spec §4.4 "세션 전환으로 생긴 WAIT"의 이유(세션 전환은 사용자 조작, `ingest`는 최종 snapshot만 냄)를 두세 줄로 적는다.

- [x] **Step 4: 통과 확인**

Run: Step 2와 같은 명령, 이어서 `-only-testing:termy-tests/PaneStateMachineTests`도 실행
Expected: 모두 `** TEST SUCCEEDED **`

- [x] **Step 5: Commit**

```bash
git add apps/termy/Sources/{HookEvent,PaneState,Notifier}.swift apps/termy-hook/Sources/{HookCLI,main}.swift apps/termy-tests/Sources/{AgentKindTests,HookCLITests,NotifierWaitAlertRuleTests}.swift
git commit -m "feat(agent): opencode AgentStatus 이벤트로 pane 상태를 바꾸고, 세션 전환으로 생긴 WAIT는 알리지 않음"
```

---

### Task 4: TUI plugin 파일과 JavaScriptCore 테스트

**Files:**
- Create: `apps/termy/Resources/opencode-plugin/tui.js`
- Modify: `project.yml:75-77`(`termy` target `sources`)
- Test: `apps/termy-tests/Sources/OpenCodePluginScriptTests.swift`(신규)

**Interfaces:**
- Consumes: wire 이름과 reason 어휘(Task 3, Global Constraints)
- Produces: 번들 리소스 `Contents/Resources/opencode-plugin/tui.js`. `Bundle.main.url(forResource: "tui", withExtension: "js", subdirectory: "opencode-plugin")`로 찾는다. Task 5가 이 템플릿을 읽어 첫 줄 표식과 placeholder `"__TERMY_HOOK_PATH__"`를 쓴다.

- [x] **Step 1: 실패하는 테스트 작성**

`OpenCodePluginScriptTests.swift` 머리 주석: plugin의 pure 영역만 JavaScriptCore로 평가한다는 설명과 spec §8 "plugin pure 영역" 행의 card. opencode 런타임, spawn, 이벤트 순서는 증명하지 않는다(Task 1 S4, Task 4 Step 7이 담당).

```swift
import JavaScriptCore
import XCTest
@testable import termy

final class OpenCodePluginScriptTests: XCTestCase {
    private static let marker = "// termy-managed opencode plugin. termy rewrites this file; do not edit."

    private func template() throws -> String {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "tui", withExtension: "js", subdirectory: "opencode-plugin"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var js: JSContext!

    override func setUpWithError() throws {
        let source = try template()
        let start = try XCTUnwrap(source.range(of: "// #region termy-pure"))
        let end = try XCTUnwrap(source.range(of: "// #endregion termy-pure"))
        js = try XCTUnwrap(JSContext())
        js.evaluateScript(String(source[start.upperBound..<end.lowerBound]))
        XCTAssertNil(js.exception, "pure region must evaluate in JavaScriptCore")
        js.evaluateScript("""
        function fakeCtx(o) {
          return {
            ui: { router: { current: () => o.route } },
            data: { session: {
              root: (id) => o.root ?? id,
              family: (id) => o.family ?? [id],
              status: (id) => (o.running ?? []).includes(id) ? "running" : "idle",
              pending: { list: (id) => (o.pending ?? {})[id] ?? [] },
              permission: { list: (id) => (o.permissions ?? {})[id] },
              form: { list: (id) => (o.forms ?? {})[id] },
              get: (id) => o.directory ? { location: { directory: o.directory } } : undefined,
            } },
          }
        }
        """)
    }

    private func eval(_ source: String) -> String? {
        let value = js.evaluateScript("String(\(source))")
        XCTAssertNil(js.exception, source)
        return value?.toString()
    }
}
```

테스트(12개):

```swift
    func testTemplate_firstLineIsTermyMarker() throws {
        XCTAssertEqual(try template().split(separator: "\n", maxSplits: 1).first.map(String.init), Self.marker)
    }

    func testTemplate_hasExactlyOnePlaceholder() throws {
        XCTAssertEqual(try template().components(separatedBy: "\"__TERMY_HOOK_PATH__\"").count, 2)
    }

    func testPhase_withoutSession_isIdle() {
        XCTAssertEqual(eval("termyPhase({ sessionID: null, permission: true, busy: true })"), "idle")
    }

    func testPhase_precedence_permissionQuestionRunningIdle() {
        XCTAssertEqual(eval("termyPhase({ sessionID: 'S', permission: true, question: true, busy: true })"), "permission")
        XCTAssertEqual(eval("termyPhase({ sessionID: 'S', question: true, busy: true })"), "question")
        XCTAssertEqual(eval("termyPhase({ sessionID: 'S', busy: true })"), "running")
        XCTAssertEqual(eval("termyPhase({ sessionID: 'S' })"), "idle")
    }

    // protects=the spec §4.2 emission table; fails_when=any row returns a different reason;
    // no_claim=that opencode fires events in this order (Task 1 S4)
    func testEmission_matchesSpecTable() {
        let rows: [(String, String)] = [
            ("termyEmission(null, { sessionID: 'S', phase: 'running' })", "running"),
            ("termyEmission(null, { sessionID: null, phase: 'idle' })", "idle"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: 'S', phase: 'permission' })", "permission"),
            ("termyEmission({ sessionID: 'S', phase: 'permission' }, { sessionID: 'S', phase: 'running' })", "running"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: 'S', phase: 'idle' }, 'succeeded')", "succeeded"),
            ("termyEmission({ sessionID: 'S', phase: 'question' }, { sessionID: 'S', phase: 'idle' }, 'succeeded')", "succeeded"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: 'S', phase: 'idle' }, 'failed')", "failed"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: 'S', phase: 'idle' }, 'interrupted')", "idle"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: 'S', phase: 'idle' })", "idle"),
            ("termyEmission({ sessionID: 'S', phase: 'idle' }, { sessionID: 'T', phase: 'running' })", "running"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: null, phase: 'idle' }, 'succeeded')", "idle"),
            ("termyEmission({ sessionID: 'S', phase: 'idle' }, { sessionID: 'S', phase: 'idle' })", "null"),
        ]
        for (source, expected) in rows {
            XCTAssertEqual(eval(source), expected, source)
        }
    }

    func testView_nonSessionRoute_hasNoSession() {
        XCTAssertEqual(eval("JSON.stringify(termyView(fakeCtx({ route: { type: 'home' } })))"), #"{"sessionID":null}"#)
        XCTAssertEqual(eval("JSON.stringify(termyView(fakeCtx({ route: { type: 'plugin', id: 'x', name: 'y' } })))"), #"{"sessionID":null}"#)
    }

    func testView_childSessionPermission_countsForRoot() {
        XCTAssertEqual(eval("""
        JSON.stringify(termyView(fakeCtx({
          route: { type: 'session', sessionID: 'ses_child' }, root: 'ses_root',
          family: ['ses_root', 'ses_child'], running: ['ses_root'],
          permissions: { ses_child: [{ id: 'per_1' }] } })))
        """), #"{"sessionID":"ses_root","permission":true,"question":false,"busy":true}"#)
    }

    func testView_pendingNonSyntheticIsBusy_syntheticIsNot() {
        XCTAssertEqual(eval("""
        termyView(fakeCtx({ route: { type: 'session', sessionID: 'S' }, pending: { S: [{ type: 'user' }] } })).busy
        """), "true")
        XCTAssertEqual(eval("""
        termyView(fakeCtx({ route: { type: 'session', sessionID: 'S' }, pending: { S: [{ type: 'synthetic' }] } })).busy
        """), "false")
    }

    func testView_cwdComesFromRootLocation() {
        XCTAssertEqual(eval("termyView(fakeCtx({ route: { type: 'session', sessionID: 'S' }, directory: '/w/proj' })).cwd"), "/w/proj")
    }

    func testPayload_includesSessionIdOnlyWhenPresent() {
        XCTAssertEqual(eval("termyPayload('idle', { sessionID: null }, '/fallback')"), #"{"reason":"idle","cwd":"/fallback"}"#)
        XCTAssertEqual(eval("termyPayload('running', { sessionID: 'ses_a', cwd: '/p' }, '/fallback')"),
                       #"{"reason":"running","session_id":"ses_a","cwd":"/p"}"#)
    }

    func testPayload_dropsCwdPast480Bytes() {
        let long = "/" + String(repeating: "a", count: 470)
        XCTAssertEqual(eval("termyPayload('running', { sessionID: 'ses_a', cwd: '\(long)' }, '/w')"),
                       #"{"reason":"running","session_id":"ses_a"}"#)
    }

    func testPayload_countsUtf8BytesNotUtf16Units() {
        // 150 Hangul syllables: 150 UTF-16 units but 450 UTF-8 bytes → over 480 with the JSON around it.
        let hangul = "/" + String(repeating: "가", count: 150)
        XCTAssertEqual(eval("termyPayload('running', { sessionID: 'ses_a', cwd: '\(hangul)' }, '/w')"),
                       #"{"reason":"running","session_id":"ses_a"}"#)
    }
```

- [x] **Step 2: 실패 확인**

Run: `xcodegen generate` 뒤 테스트 명령, `-only-testing:termy-tests/OpenCodePluginScriptTests`
Expected: FAIL, `XCTUnwrap failed` (번들에 `opencode-plugin/tui.js`가 없음)

- [x] **Step 3: plugin 파일 작성**

`apps/termy/Resources/opencode-plugin/tui.js`를 spec §4.2의 코드로 만든다. 파일 순서: (1) Global Constraints의 첫 줄 표식, (2) `import { spawn } from "node:child_process"`, (3) `const TERMY_HOOK_PATH = "__TERMY_HOOK_PATH__"`, (4) `// #region termy-pure` ~ `// #endregion termy-pure`(`termyPhase`, `termyEmission`, `termyView`, `termyPayload`, `termyUtf8Length`), (5) `export default { id: "termy", setup(ctx) { … } }` glue. ESM `import` · `export`는 pure 영역 밖에만 둔다. Task 1에서 S4 대응을 바꿨다면 바뀐 spec §4.2를 따른다.

- [x] **Step 4: 리소스 복사 설정**

`project.yml`의 `termy` target `sources`, `- path: apps/termy/Resources/Assets.xcassets` 아래에:

```yaml
      - path: apps/termy/Resources/opencode-plugin
        type: folder
        buildPhase: resources
```

Run: `xcodegen generate`

- [x] **Step 5: 문법 확인과 통과 확인**

Run: `node --check apps/termy/Resources/opencode-plugin/tui.js; echo "exit=$?"`
Expected: `exit=0`

Run: 테스트 명령, `-only-testing:termy-tests/OpenCodePluginScriptTests`
Expected: `** TEST SUCCEEDED **`, 12 tests

Run: `ls build/DerivedData-tests/Build/Products/Debug/termy.app/Contents/Resources/opencode-plugin/`
Expected: `tui.js`

- [x] **Step 6: Commit**

```bash
git add apps/termy/Resources/opencode-plugin/tui.js project.yml apps/termy-tests/Sources/OpenCodePluginScriptTests.swift
git commit -m "feat(agent): opencode TUI plugin을 앱 번들에 넣음"
```

- [x] **Step 7: 실제 opencode에서 plugin 통합 확인(fake hook)**

termy 없이 진짜 plugin을 Task 1 harness에서 돌린다. 설치기가 쓸 위치와 같은 global plugin 경로(임시 XDG config 아래 `opencode/plugins/termy/tui.js`)에 두고, `termy-hook` 대신 받은 것을 기록하는 스크립트를 쓴다.

```bash
SPIKE=/tmp/termy-oc-spike
mkdir -p "$SPIKE/config/opencode/plugins/termy"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$*" "$(cat)" >> /tmp/termy-oc-spike/hook.log\n' > "$SPIKE/fake-hook.sh"
chmod +x "$SPIKE/fake-hook.sh"; : > "$SPIKE/hook.log"
sed 's#"__TERMY_HOOK_PATH__"#"/tmp/termy-oc-spike/fake-hook.sh"#' apps/termy/Resources/opencode-plugin/tui.js \
  > "$SPIKE/config/opencode/plugins/termy/tui.js"
(cd "$SPIKE/work" && XDG_CONFIG_HOME="$SPIKE/config" opencode plugin list)
```

Expected: `SOURCE`에 `/tmp/termy-oc-spike/config/opencode/plugins/termy`가 나온다.

Task 1 tmux 형식(Interfaces)으로 띄우고 아래 순서로 보낸다. 단계마다 `tmux capture-pane -p -t oc-spike | tail -15`로 끝났는지 확인한 뒤 다음으로 간다.

1. `Reply with the single word ok.`
2. `Read the file .env and tell me its first line.` → 권한 승인
3. `Count from 1 to 300, one number per line.` → 2초 뒤 `tmux send-keys -t oc-spike Escape`
4. spawn 실패 뒤 복구(Review Focus 5): `mv "$SPIKE/fake-hook.sh" "$SPIKE/fake-hook.sh.off"` → `Reply with the single word ok.` → 끝나면 `mv "$SPIKE/fake-hook.sh.off" "$SPIKE/fake-hook.sh"` → `Reply with the single word yes.`

이어서 세션을 끄고 `TERMY_PANE_ID` 없이 한 번 더 띄운 뒤 prompt 하나(`Reply with the single word ok.`)를 보낸다. tmux server는 이 세션이 도는 pane의 실제 `TERMY_PANE_ID`를 물려받으므로 반드시 `-u`로 지운다.

```bash
tmux kill-session -t oc-spike
tmux new-session -d -s oc-spike -x 200 -y 50 \
  "cd /tmp/termy-oc-spike/work && env -u TERMY_PANE_ID XDG_CONFIG_HOME=/tmp/termy-oc-spike/config opencode --standalone"
```

Expected `hook.log`(각 줄 앞부분은 `--agent opencode AgentStatus`):
1. 시작 직후 `{"reason":"idle","cwd":"…"}`
2. 단계 1: `running` → `succeeded`
3. 단계 2: `running` → `permission` → `running` → `succeeded`
4. 단계 3: `running` → `idle`
5. 단계 4: hook을 치운 동안의 prompt는 아무 줄도 남기지 않고, TUI는 계속 응답한다. 되돌린 뒤의 prompt는 `running` → `succeeded`를 순서대로 남긴다.
6. `TERMY_PANE_ID` 없는 실행: 새 줄이 없다.

결과(로그 원문 요약)를 Task 보고에 적는다. 기대와 다르면 spec §4.2와 대조해 원인을 적고 멈춘다. 끝나면 정리한다.

```bash
tmux kill-session -t oc-spike
cd /tmp/termy-oc-spike/work && opencode session list
```

이 디렉터리의 spike 세션을 `opencode session delete <id>`로 모두 지우고 `session list`가 비었는지 확인한 뒤 `rm -rf /tmp/termy-oc-spike`.

---

### Task 5: 설치기와 메뉴

**Files:**
- Create: `apps/termy/Sources/OpenCodePluginInstaller.swift`
- Modify: `apps/termy/Sources/AppDelegate.swift:97-102,281-287,461-469`
- Test: `apps/termy-tests/Sources/OpenCodePluginInstallerTests.swift`(신규)

**Interfaces:**
- Consumes: 번들 템플릿(Task 4), `Contents/Resources/termy-hook`
- Produces:

```swift
enum OpenCodePluginInstaller {
    static let marker: String                 // Global Constraints의 첫 줄 표식
    static let hookPathPlaceholder: String    // "\"__TERMY_HOOK_PATH__\""
    static var bundledHookURL: URL            // Bundle.main.bundleURL + Contents/Resources/termy-hook
    static var templateURL: URL?              // Bundle.main.url(forResource: "tui", withExtension: "js", subdirectory: "opencode-plugin")
    static var pluginFileURL: URL             // ~/.config/opencode/plugins/termy/tui.js

    enum State: Equatable {
        case notInstalled, installedCurrent, installedStale
        case foreign(path: String)
        case configError(message: String)
    }

    static func pluginSource(template: String, hookPath: String) -> String
    static func currentState() -> State
    static func currentState(pluginFileURL: URL, expected: String, fileManager: FileManager = .default) -> State
    static func install() throws
    static func install(pluginFileURL: URL, contents: String, fileManager: FileManager = .default) throws
    static func uninstall() throws
    static func uninstall(pluginFileURL: URL, fileManager: FileManager = .default) throws
    @MainActor static func refreshIfInstalled()
    @MainActor static func showPromptFromMenu()
}

enum OpenCodePluginInstallerError: LocalizedError {
    case hookBinaryMissing(String)
    case templateUnavailable(String)
    case foreignFile(String)
}
```

- [x] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import termy

final class OpenCodePluginInstallerTests: XCTestCase {
    private var root: URL!
    private var pluginFile: URL { root.appendingPathComponent("plugins/termy/tui.js") }
    private let template = """
    // termy-managed opencode plugin. termy rewrites this file; do not edit.
    const TERMY_HOOK_PATH = "__TERMY_HOOK_PATH__"

    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodePluginInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func expected(_ hook: String = "/Applications/termy.app/Contents/Resources/termy-hook") -> String {
        OpenCodePluginInstaller.pluginSource(template: template, hookPath: hook)
    }

    private func contents() throws -> String { try String(contentsOf: pluginFile, encoding: .utf8) }
}
```

테스트(9개). 파일 머리 주석에 spec §8 "설치기" 행의 card를 적는다:

```swift
    func test_pluginSource_writesHookPathAsJSONStringLiteral() {
        let s = OpenCodePluginInstaller.pluginSource(template: template, hookPath: #"/Volumes/x y/"q"\b/termy-hook"#)
        XCTAssertFalse(s.contains("__TERMY_HOOK_PATH__"))
        XCTAssertTrue(s.contains(#"const TERMY_HOOK_PATH = "/Volumes/x y/\"q\"\\b/termy-hook""#))
    }

    func test_state_missingFile_isNotInstalled() {
        XCTAssertEqual(OpenCodePluginInstaller.currentState(pluginFileURL: pluginFile, expected: expected()), .notInstalled)
    }

    func test_state_sameBytes_isInstalledCurrent() throws {
        try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected())
        XCTAssertEqual(OpenCodePluginInstaller.currentState(pluginFileURL: pluginFile, expected: expected()), .installedCurrent)
    }

    func test_state_termyFileWithOtherContents_isInstalledStale() throws {
        try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected("/old/termy.app/Contents/Resources/termy-hook"))
        XCTAssertEqual(OpenCodePluginInstaller.currentState(pluginFileURL: pluginFile, expected: expected()), .installedStale)
    }

    func test_state_unreadablePath_isConfigError() throws {
        // A directory where tui.js should be: fileExists is true, reading fails.
        try FileManager.default.createDirectory(at: pluginFile, withIntermediateDirectories: true)
        guard case .configError = OpenCodePluginInstaller.currentState(pluginFileURL: pluginFile, expected: expected()) else {
            return XCTFail("expected .configError")
        }
    }

    func test_state_fileWithoutMarker_isForeign() throws {
        try FileManager.default.createDirectory(at: pluginFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default {}\n".write(to: pluginFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(OpenCodePluginInstaller.currentState(pluginFileURL: pluginFile, expected: expected()),
                       .foreign(path: pluginFile.path))
    }

    func test_install_createsDirectoriesAndWritesExactContents() throws {
        try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected())
        XCTAssertEqual(try contents(), expected())
    }

    // protects=never overwrite or delete a file termy didn't write; fails_when=foreign bytes change;
    // no_claim=what opencode does with the folder (Task 1 S1)
    func test_installAndUninstall_refuseForeignFile() throws {
        try FileManager.default.createDirectory(at: pluginFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default {}\n".write(to: pluginFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected()))
        XCTAssertThrowsError(try OpenCodePluginInstaller.uninstall(pluginFileURL: pluginFile))
        XCTAssertEqual(try contents(), "export default {}\n")
    }

    func test_uninstall_removesFileAndEmptyDir_keepsSiblings() throws {
        let fm = FileManager.default
        let sibling = root.appendingPathComponent("plugins/other/tui.js")
        try fm.createDirectory(at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: sibling, atomically: true, encoding: .utf8)
        try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected())
        try OpenCodePluginInstaller.uninstall(pluginFileURL: pluginFile)
        XCTAssertFalse(fm.fileExists(atPath: pluginFile.deletingLastPathComponent().path))
        XCTAssertTrue(fm.fileExists(atPath: sibling.path))

        // A non-empty termy folder keeps everything except tui.js.
        try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected())
        let note = pluginFile.deletingLastPathComponent().appendingPathComponent("notes.txt")
        try "keep".write(to: note, atomically: true, encoding: .utf8)
        try OpenCodePluginInstaller.uninstall(pluginFileURL: pluginFile)
        XCTAssertFalse(fm.fileExists(atPath: pluginFile.path))
        XCTAssertTrue(fm.fileExists(atPath: note.path))
    }
```

- [x] **Step 2: 실패 확인**

Run: `xcodegen generate` 뒤 테스트 명령, `-only-testing:termy-tests/OpenCodePluginInstallerTests`
Expected: 컴파일 실패, `cannot find 'OpenCodePluginInstaller' in scope`

- [x] **Step 3: 설치기 구현**

`AntigravityHookInstaller.swift`의 구조(머리 주석, `// MARK:` 순서, `@MainActor` 알림창, `showError`)를 따른다. 정해진 동작:

- `pluginSource`: placeholder를 `JSONEncoder`(`outputFormatting = [.withoutEscapingSlashes]`)로 인코딩한 `hookPath` 문자열 리터럴로 바꾼다.
- `currentState(pluginFileURL:expected:fileManager:)`: 파일 없음 → `.notInstalled`. 읽기 실패 → `.configError(message: error.localizedDescription)`. 첫 줄(첫 `\n` 앞)이 `marker`가 아님 → `.foreign(path:)`. 내용이 `expected`와 같음 → `.installedCurrent`, 다르면 `.installedStale`.
- `currentState()`: `templateURL`이 nil이거나 읽기 실패 → `.configError(message: "termy's OpenCode plugin template is missing from the app bundle.")`. placeholder가 정확히 한 번이 아님 → `.configError(message: "termy's OpenCode plugin template has no hook path placeholder.")`. 그 밖에는 `pluginSource(template:hookPath: bundledHookURL.path)`를 expected로 위임한다.
- `install(pluginFileURL:contents:)`: 파일이 있고 첫 줄이 marker가 아니면 `throw .foreignFile(path)`. 부모 디렉터리를 만들고 `.atomic`으로 쓴다. 백업은 만들지 않는다.
- `install()`: `bundledHookURL`에 파일이 없으면 `throw .hookBinaryMissing(path)`, 템플릿을 읽지 못하면 `throw .templateUnavailable(message)`.
- `uninstall(pluginFileURL:)`: 파일 없음 → return. 첫 줄이 marker가 아님 → `throw .foreignFile(path)`. 파일을 지우고, 부모 디렉터리가 비었으면 디렉터리도 지운다.
- `refreshIfInstalled()`: `.installedStale`일 때만 `try? install()`. 다른 상태는 아무것도 하지 않는다. 알림창 없음.
- 오류 문구: `hookBinaryMissing` → `"termy-hook not found at \(path). Reinstall termy or rebuild in Xcode."`, `templateUnavailable(msg)` → `msg`, `foreignFile(path)` → `"\(path) was not created by termy, so termy leaves it alone."`

`showPromptFromMenu()` 알림창 문구(그대로 쓴다):

| State | messageText | informativeText | 버튼 |
|---|---|---|---|
| `.installedCurrent` | `OpenCode plugin is installed` | `termy reads OpenCode's session state through a plugin at:\n\n\(pluginFileURL.path)\n\nClick Uninstall to remove it. Your other OpenCode plugins stay untouched.` | `OK`, `Uninstall`(두 번째 → uninstall) |
| `.installedStale` | `OpenCode plugin updated` | `termy rewrote its OpenCode plugin so it points at:\n\n\(bundledHookURL.path)` | `OK`(먼저 `try? install()`) |
| `.foreign(path)` | `termy won't touch this OpenCode plugin file` | `A file termy didn't create is already at:\n\n\(path)\n\nMove or delete it, then reopen this dialog.` | `OK`(`.warning`) |
| `.configError(msg)` | `OpenCode plugin can't be set up` | `msg` | `OK`(`.warning`) |
| `.notInstalled` | `Install the termy plugin into OpenCode?` | `termy reads OpenCode's session state through a TUI plugin to show live pane state (WAITING / THINKING / IDLE). This writes one file:\n\n\(pluginFileURL.path)\n\nOpenCode sessions that are already open pick it up too. You can uninstall anytime from this menu.` | `Install`, `Cancel` |

install · uninstall 실패 알림 제목은 `OpenCode plugin install failed` / `OpenCode plugin uninstall failed`, 본문은 `error.localizedDescription`.

- [x] **Step 4: AppDelegate 연결**

- `AppDelegate.swift:97-102` asyncAfter 블록의 `AntigravityHookInstaller.promptIfNeeded()` 다음 줄에 `OpenCodePluginInstaller.refreshIfInstalled()`.
- `openAntigravityHookInstallerPrompt(_:)` 아래에 `@IBAction func openOpenCodePluginInstallerPrompt(_ sender: Any?) { OpenCodePluginInstaller.showPromptFromMenu() }`.
- 메뉴: `antigravityInstaller.target = self` 다음에 같은 형식으로 `"OpenCode Plugin…"` 항목(`#selector(AppDelegate.openOpenCodePluginInstallerPrompt(_:))`, `keyEquivalent: ""`, `target = self`).

- [x] **Step 5: 통과 확인**

Run: 테스트 명령, `-only-testing:termy-tests/OpenCodePluginInstallerTests -only-testing:termy-tests/OpenCodePluginScriptTests`
Expected: `** TEST SUCCEEDED **`

- [x] **Step 6: Commit**

```bash
git add apps/termy/Sources/{OpenCodePluginInstaller,AppDelegate}.swift apps/termy-tests/Sources/OpenCodePluginInstallerTests.swift
git commit -m "feat(agent): termy 메뉴에서 opencode plugin을 설치하고 해제함"
```

---

### Task 6: 마무리 — 전체 테스트, CHANGELOG, 실제 앱 확인(controller 담당)

**Files:**
- Modify: `CHANGELOG.md`(`## Unreleased`)
- Modify: `docs/superpowers/specs/2026-10-19-opencode-support-design.md`(머리의 상태 줄)

- [x] **Step 1: 전체 테스트**

Run: `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`. 보고에 실행한 테스트 수와 실패 수를 적는다.

- [x] **Step 2: CHANGELOG**

`## Unreleased` 아래에 그대로 쓴다. Task 1 S6이 실패했다면 마지막 문장("OpenCode sessions that are already open…")을 뺀다.

```markdown
- OpenCode now works with termy alongside Claude Code, Codex and
  Antigravity CLI. Panes running `opencode` show their live state (IDLE,
  THINK, WAIT, ERR) in the dashboard and on the pane header, and play
  notifications when OpenCode asks for permission, asks a question, or
  finishes a turn.
- Install the termy plugin for OpenCode from termy ▸ OpenCode Plugin….
  It adds one file, `~/.config/opencode/plugins/termy/tui.js`. OpenCode
  sessions that are already open pick it up right away.
```

- [x] **Step 3: spec 상태 줄 갱신과 commit**

spec 머리의 `- 상태:` 줄을 `- 상태: 구현 완료(YYYY-MM-DD), 실제 앱 수동 확인 대기`로 바꾼다.

```bash
git add CHANGELOG.md docs/superpowers/specs/2026-10-19-opencode-support-design.md
git commit -m "docs(changelog): opencode pane 상태 표시 항목을 추가"
```

- [ ] **Step 4: 실제 앱 수동 확인(사용자)**

이 세션은 termy 안에서 돌기 때문에 agent가 새 빌드를 띄울 수 없다. 사용자에게 아래 절차를 넘기고 결과를 받는다.

1. 빌드: `xcodebuild build -project termy.xcodeproj -scheme termy -configuration Debug -derivedDataPath build/DerivedData-debug -skipPackagePluginValidation 2>&1 | tail -5` → `** BUILD SUCCEEDED **`
2. `cp ~/Library/Application\ Support/termy/session.json ~/termy-session.json.bak`, 실행 중인 termy를 ⌘Q로 끄고 `build/DerivedData-debug/Build/Products/Debug/termy.app`을 Finder에서 연다. Debug 빌드는 실행할 때 `~/.claude` hook 경로를 자기 `termy-hook`으로 바꾼다. 나중에 `/Applications/termy.app`을 다시 열면 원래대로 돌아온다.
3. termy ▸ OpenCode Plugin… → Install. `head -3 ~/.config/opencode/plugins/termy/tui.js`에 첫 줄 표식과 Debug 빌드의 `termy-hook` 경로가 있다.
4. 확인 항목:

| # | 동작 | 기대 결과 |
|---|---|---|
| M1 | pane에서 `opencode` 실행 | 1초 안에 IDLE 칩 |
| M2 | `Reply with the single word ok.` | THINK → WAIT + Glass 알림음, 배너 "OpenCode is waiting for your response." → 약 30초 뒤 IDLE |
| M3 | `.env`가 있는 저장소에서 `Read the file .env` | WAIT + 알림음, 배너 "Waiting for your approval." → 승인하면 THINK |
| M4 | `Use the question tool to ask me to choose between A and B.` | WAIT + 알림음, 배너 "OpenCode is asking a question." → 답하면 THINK |
| M5 | 긴 작업 중 Esc | 알림음 없이 IDLE |
| M6 | `/exit` 또는 Ctrl+C | INIT(칩이 사라짐) |
| M7 | 같은 저장소의 다른 pane에서도 opencode 실행 | 두 pane이 각자의 상태를 보여 줌 |
| M8 | Ghostty 등 termy 밖에서 opencode로 prompt 하나 | termy 변화 없음, `/tmp/termy-hook-debug.log`에 새 줄 없음 |
| M9 | 한 pane에서 탭 두 개를 쓰고, 뒤쪽 탭이 권한을 기다리는 동안 그 탭으로 전환 | pane이 WAIT로 바뀌지만 알림음 · 배너 없음(앞쪽 탭이 IDLE이었을 때와 WAIT였을 때 둘 다) |

`failed`(ERR)는 일부러 만들기 어려워 단위 테스트(`test_opencodeAgentStatus_failed_setsErrored`)로만 확인한다. 이 사실을 결과에 적는다.

5. 끝나면 Debug 빌드를 끄고 `/Applications/termy.app`을 다시 연다. 0.2.15에는 opencode 설치기가 없어서 plugin 파일은 Debug 빌드 경로를 계속 가리킨다. 그대로 둬도 0.2.15는 `AgentStatus`를 디코드하지 못해 무시할 뿐이다. 새 버전을 배포하기 전에는 Debug 빌드 메뉴에서 Uninstall하거나 `rm -rf ~/.config/opencode/plugins/termy`로 지운다.

- [ ] **Step 5: 결과 기록**

M1~M9 결과를 spec 머리 상태 줄과 §7 수용 기준 15번 옆에 적고 commit한다(`docs(spec): opencode 실제 앱 확인 결과를 기록`). 실패한 항목이 있으면 원인을 조사하고 수정 태스크를 따로 만든다.

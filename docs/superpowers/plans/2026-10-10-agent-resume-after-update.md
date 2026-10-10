# 업데이트 후 agent 세션 이어가기 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sparkle 업데이트로 termy 가 재시작될 때, agent 가 turn 도중이면 재시작을 미루고, 재시작 직전에 각 pane 의 Claude Code / Codex 세션을 저장해 새 버전이 `claude --resume` / `codex resume` 으로 같은 대화를 다시 연다.

**Architecture:** `PaneRecord` 에 optional `agentResume` 를 추가하고, Sparkle 의 `updaterWillRelaunchApplication` 에서만 채워 `session.json` 을 동기로 쓰고 봉인한다. 복원 시 pane 이 셸 준비를 기다렸다가 resume 명령을 입력한다. `PaneSnapshot.turnOpen` 으로 turn 경계를 추적하고, `UpdateRelaunchGate` 가 Sparkle 의 install handler 를 붙잡아 모든 turn 이 끝난 뒤 놓아준다.

**Tech Stack:** Swift 6, AppKit, Sparkle 2.6.4, SwiftTerm 1.20.0(고정), XcodeGen(`project.yml`), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-10-agent-resume-after-update-design.md`

## Global Constraints

- Swift 6 언어 모드, macOS 14 deployment target. 새 코드는 strict concurrency 에서 경고 없이 컴파일돼야 한다.
- SwiftTerm 은 `exactVersion: "1.20.0"`, Sparkle 은 `2.6.4` 그대로 둔다. `project.yml` 의 package 항목을 건드리지 않는다.
- **새 `.swift` 파일을 만들면 반드시 `xcodegen generate` 를 실행**한다. XcodeGen 은 `apps/termy/Sources` · `apps/termy-tests/Sources` 를 generate 시점에 열거한다.
- 테스트 명령(모든 태스크 공통):
  `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25`
  → `** TEST SUCCEEDED **`. `-derivedDataPath` 와 `-skipPackagePluginValidation` 을 빼면 이 환경에서 EPERM 이나 plugin 검증 오류가 난다.
- 전체 테스트: 위 명령에서 `-only-testing` 을 뺀다.
- **termy.app 을 실행하지 않는다.** `scripts/relaunch.sh`, `open termy.app`, Debug 빌드 실행 모두 금지다. 개발 세션 자체가 termy 안에서 돌고 있어서, 실행하면 사용자 세션이 죽거나 hook socket 을 빼앗긴다. XCTest host 로 뜨는 것은 괜찮다(`TestHostDetector` 가 막는다).
- 앱 UI 문구는 영어다. alert 문구는 spec §5.7 그대로:
  - 제목: `"1 agent is still working"` / `"N agents are still working"`
  - 본문: `"termy will restart to install the update when they finish their current turn. Other programs running in panes will still be stopped."`
  - 버튼: `"Wait for Agents"`(첫 번째, 기본), `"Restart Now"`
  - 메뉴: `"Restart Now to Install Update"`, DEBUG 메뉴 `"Debug"` ▸ `"Simulate Update Relaunch"`
- resume 은 대화만 되살린다. **prompt 위치 인자와 `--print` 는 어떤 경우에도 resume 명령에 들어가면 안 된다.**
- 커밋 메시지는 한국어, `Co-Authored-By` 라인을 넣지 않는다.
- 주석 밀도와 스타일은 주변 코드를 따른다: 파일 머리 주석에 "왜", 타입·메서드에 `///` 한두 줄.

## Review Focus

테스트가 직접 다루지 않는 입력 중 실제로 사람을 물 가능성이 높은 순서다. 각 줄의 테스트는 해당 태스크에 들어가 있다.

1. **Stop hook 이 막아서 Claude 가 `Stop` 뒤에도 일을 이어감** → tool 이벤트가 turn 을 다시 열어 업데이트가 미뤄져야 한다. (Task 3: `test_turnOpen_toolUseAfterStop_reopensTurn`)
2. **기다리는 중에 작업 중이던 pane 이 있는 창을 닫음** → 집계에서 빠져 재시작이 진행돼야 한다. (Task 3: `test_midTurnPaneCount_dropsWhenBusyWindowCloses`, `test_removeWindow_firesOnLivePanesChanged`)
3. **`--allowedTools "Bash(git log:*)"` 처럼 공백·괄호가 든 플래그 값** → 따옴표로 감싸 셸이 쪼개지 않아야 한다. (Task 1: `test_quotesToolPatternWithSpacesAndParens`)
4. **이미 다른 스레드에서 진행 중이던 autosave 가 봉인 쓰기 뒤에 도착** → resume 기록이 남아 있어야 한다. (Task 4: `test_seal_writesRecordAndDropsLaterSaves`)
5. **p10k instant prompt 처럼 셸이 3초 넘게 계속 출력** → 3초에 한 번만 입력해야 한다. (Task 5: `test_firesAtDeadlineEvenWhileOutputKeepsFlowing`)

## 파일 구조

**신규:**

| 파일 | 책임 |
|---|---|
| `apps/termy/Sources/AgentResume.swift` | `AgentResumeRecord`(스키마), `AgentResumeCommand`(명령 문자열), `AgentResumeCapture`(기록 여부 판단) |
| `apps/termy/Sources/AgentResumeFlags.swift` | argv 에서 이어받을 플래그 고르기 |
| `apps/termy/Sources/MainQueueTimer.swift` | 취소 가능한 main-queue 일회성 타이머, `ScheduleAfter` 타입 |
| `apps/termy/Sources/StartupInputScheduler.swift` | 복원된 셸에 명령을 입력할 시점 결정 |
| `apps/termy/Sources/UpdateRelaunchGate.swift` | 작업 중인 agent 가 있으면 Sparkle relaunch 붙잡기 |
| `apps/termy-tests/Sources/ManualScheduler.swift` | 테스트용 수동 시계(`ManualScheduler`), `Counter` |
| `apps/termy-tests/Sources/AgentResumeCommandTests.swift` | 명령 문자열 / quoting |
| `apps/termy-tests/Sources/AgentResumeFlagsTests.swift` | 플래그 고르기 |
| `apps/termy-tests/Sources/AgentResumeCaptureTests.swift` | 기록 여부 판단 |
| `apps/termy-tests/Sources/StartupInputSchedulerTests.swift` | 입력 시점 |
| `apps/termy-tests/Sources/UpdateRelaunchGateTests.swift` | gate 동작 |

**수정:**

| 파일 | 변경 |
|---|---|
| `apps/termy/Sources/WorkspaceRecord.swift` | `PaneRecord.agentResume` |
| `apps/termy/Sources/ForegroundProcessWatcher.swift` | `foregroundProcessGroupLeader`, `agentEntrypoint(in:)`, `processCwd(pid:)` |
| `apps/termy/Sources/PaneState.swift` | `PaneSnapshot.turnOpen`, `isMidTurn`, 상태 머신 전환 |
| `apps/termy/Sources/MissionControlModel.swift` | `applySnapshot`, `snapshot(paneId:)`, `midTurnPaneCount`, `onLivePanesChanged` |
| `apps/termy/Sources/SessionPersistence.swift` | 잠금으로 감싼 쓰기, `sealWithFinalRecord` |
| `apps/termy/Sources/Pane.swift` | `agentResumeRecord(snapshot:)`, `startupInput` |
| `apps/termy/Sources/TermyTerminalView.swift` | `onOutput` |
| `apps/termy/Sources/Workspace.swift` | `addPane(…startupInput:)` |
| `apps/termy/Sources/MainWindowController.swift` | `sessionWindowRecord(includeAgentResume:)`, 복원 시 resume |
| `apps/termy/Sources/WindowManager.swift` | `prepareForUpdateRelaunch()`, 복원 후 저장 요청 |
| `apps/termy/Sources/Updater.swift` | `SPUUpdaterDelegate`, gate 소유 |
| `apps/termy/Sources/AppDelegate.swift` | gate 연결, 메뉴 항목, DEBUG 메뉴 |
| `CHANGELOG.md` | Unreleased 항목 |

---

## Task 1: resume 기록 스키마와 명령 생성

**Files:**
- Create: `apps/termy/Sources/AgentResume.swift`
- Modify: `apps/termy/Sources/WorkspaceRecord.swift:68-72` (`PaneRecord`)
- Test: `apps/termy-tests/Sources/SessionRecordTests.swift`, `apps/termy-tests/Sources/AgentResumeCommandTests.swift`

**Interfaces:**
- Consumes: `AgentKind`(`.claude` / `.codex`, `Codable`) — `apps/termy/Sources/AgentKind.swift`
- Produces:
  - `struct AgentResumeRecord: Codable, Equatable { var kind: AgentKind; var sessionId: String; var cwd: String?; var flags: [String] }`
  - `PaneRecord.agentResume: AgentResumeRecord?` (기본값 nil, `PaneRecord(cwd:)` 호출부는 그대로 동작)
  - `enum AgentResumeCommand { static func make(_ record: AgentResumeRecord) -> String; static func shellQuote(_ word: String) -> String }`

- [ ] **Step 1: 실패하는 테스트 작성**

`apps/termy-tests/Sources/SessionRecordTests.swift` 의 클래스 끝(`test_frameRecord_convertsToAndFromCGRect` 뒤)에 추가:

```swift
    func test_paneRecord_withAgentResume_roundTrips() throws {
        let pane = PaneRecord(
            cwd: "/a",
            agentResume: AgentResumeRecord(
                kind: .codex,
                sessionId: "019a-session",
                cwd: "/a/sub",
                flags: ["-m", "gpt-5"]
            )
        )
        let data = try JSONEncoder().encode(pane)
        XCTAssertEqual(try JSONDecoder().decode(PaneRecord.self, from: data), pane)
    }

    func test_paneRecord_decodesLegacyJSONWithoutAgentResume() throws {
        let legacy = #"{"cwd": "/legacy"}"#
        let pane = try JSONDecoder().decode(PaneRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(pane.cwd, "/legacy")
        XCTAssertNil(pane.agentResume)
    }

    func test_paneRecord_withoutAgentResume_omitsKey() throws {
        let data = try JSONEncoder().encode(PaneRecord(cwd: "/a"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("agentResume"))
    }
```

새 파일 `apps/termy-tests/Sources/AgentResumeCommandTests.swift`:

```swift
import XCTest
@testable import termy

final class AgentResumeCommandTests: XCTestCase {
    private func record(
        _ kind: AgentKind,
        id: String = "bb69d2e4-e5f1-4f4c-bc03-e7fa9e29b2fe",
        flags: [String] = []
    ) -> AgentResumeRecord {
        AgentResumeRecord(kind: kind, sessionId: id, cwd: nil, flags: flags)
    }

    func test_claude_noFlags() {
        XCTAssertEqual(
            AgentResumeCommand.make(record(.claude)),
            "claude --resume bb69d2e4-e5f1-4f4c-bc03-e7fa9e29b2fe"
        )
    }

    func test_claude_putsFlagsAfterSessionId() {
        let r = record(.claude, flags: ["--model", "opus", "--dangerously-skip-permissions"])
        XCTAssertEqual(
            AgentResumeCommand.make(r),
            "claude --resume bb69d2e4-e5f1-4f4c-bc03-e7fa9e29b2fe --model opus --dangerously-skip-permissions"
        )
    }

    func test_codex_putsFlagsBeforeSessionId() {
        let r = record(.codex, id: "019a-uuid", flags: ["-m", "gpt-5", "-c", "model_reasoning_effort=high"])
        XCTAssertEqual(
            AgentResumeCommand.make(r),
            "codex resume -m gpt-5 -c model_reasoning_effort=high 019a-uuid"
        )
    }

    // Review Focus 3
    func test_quotesToolPatternWithSpacesAndParens() {
        let r = record(.claude, id: "s1", flags: ["--allowedTools", "Bash(git log:*)", "Edit"])
        XCTAssertEqual(
            AgentResumeCommand.make(r),
            "claude --resume s1 --allowedTools 'Bash(git log:*)' Edit"
        )
    }

    func test_shellQuote_leavesSafeWordsBare() {
        XCTAssertEqual(AgentResumeCommand.shellQuote("--permission-mode"), "--permission-mode")
        XCTAssertEqual(AgentResumeCommand.shellQuote("/Users/u/proj"), "/Users/u/proj")
        XCTAssertEqual(AgentResumeCommand.shellQuote("model=o3"), "model=o3")
    }

    func test_shellQuote_escapesSingleQuote() {
        XCTAssertEqual(AgentResumeCommand.shellQuote("it's"), #"'it'\''s'"#)
    }

    func test_shellQuote_quotesShellSyntax() {
        XCTAssertEqual(AgentResumeCommand.shellQuote(""), "''")
        // zsh expands a leading `=` (EQUALS option) and `~`.
        XCTAssertEqual(AgentResumeCommand.shellQuote("=x"), "'=x'")
        XCTAssertEqual(AgentResumeCommand.shellQuote("~/x"), "'~/x'")
        XCTAssertEqual(AgentResumeCommand.shellQuote("$HOME"), "'$HOME'")
        XCTAssertEqual(
            AgentResumeCommand.shellQuote(#"sandbox_permissions=["disk-full-read-access"]"#),
            #"'sandbox_permissions=["disk-full-read-access"]'"#
        )
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `xcodegen generate` 후 테스트 명령을 `-only-testing:termy-tests/SessionRecordTests -only-testing:termy-tests/AgentResumeCommandTests` 로 실행.
Expected: 컴파일 실패 — `cannot find 'AgentResumeRecord' in scope`, `extra argument 'agentResume' in call`.

- [ ] **Step 3: 구현**

`apps/termy/Sources/WorkspaceRecord.swift` 의 `PaneRecord` 를 다음으로 바꾼다:

```swift
struct PaneRecord: Codable, Equatable {
    /// Last-known cwd of the pane. Stored as an absolute path; restore falls
    /// back to `$HOME` if the folder no longer exists at restore time.
    var cwd: String
    /// Agent session to resume in this pane. Written only by the
    /// update-relaunch save (`WindowManager.prepareForUpdateRelaunch`); nil
    /// in every other session save and in ⌘K workspace records, so the key
    /// is absent from those files.
    var agentResume: AgentResumeRecord? = nil
}
```

새 파일 `apps/termy/Sources/AgentResume.swift`:

```swift
// AgentResume.swift
//
// What termy records about a running agent right before a Sparkle update
// relaunch, and the shell command that reopens the same conversation in
// the restored pane. The relaunch kills every PTY child (termy.app owns
// the PTY master fds), so the process can't survive — the conversation
// can, through `claude --resume` / `codex resume`.
// See docs/superpowers/specs/2026-10-10-agent-resume-after-update-design.md.

import Foundation

/// One pane's agent session, captured at update-relaunch time only.
struct AgentResumeRecord: Codable, Equatable {
    var kind: AgentKind
    var sessionId: String
    /// The agent process's own cwd as the kernel reports it. nil when it
    /// couldn't be read — restore then uses the pane's saved cwd.
    var cwd: String?
    /// argv pieces that passed `AgentResumeFlags`, in original order.
    var flags: [String]
}

/// Builds the command typed into a restored pane's shell.
enum AgentResumeCommand {
    static func make(_ record: AgentResumeRecord) -> String {
        let id = shellQuote(record.sessionId)
        let flags = record.flags.map(shellQuote)
        let words: [String]
        switch record.kind {
        case .claude:
            words = ["claude", "--resume", id] + flags
        case .codex:
            // `codex resume [OPTIONS] [SESSION_ID] [PROMPT]` — options go
            // first so nothing after the id can read as a prompt.
            words = ["codex", "resume"] + flags + [id]
        }
        return words.joined(separator: " ")
    }

    private static let safeCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:=@%+,-"
    )

    /// Leave shell-safe words bare so the visible command stays readable;
    /// single-quote everything else. A leading `=` is quoted too because
    /// zsh's EQUALS option expands it.
    static func shellQuote(_ word: String) -> String {
        if !word.isEmpty,
           !word.hasPrefix("="),
           word.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return word
        }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: Step 2 와 같은 명령.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: 커밋**

```bash
git add apps/termy/Sources/AgentResume.swift apps/termy/Sources/WorkspaceRecord.swift \
  apps/termy-tests/Sources/SessionRecordTests.swift apps/termy-tests/Sources/AgentResumeCommandTests.swift
git commit -m "feat(update): agent resume 기록 스키마와 resume 명령 생성을 추가"
```

---

## Task 2: 프로세스 조회 helper와 플래그 허용 목록

**Files:**
- Modify: `apps/termy/Sources/ForegroundProcessWatcher.swift` (`currentForegroundAgent` 127-140행, `classifyAgent(fromArguments:)` 184-200행, 파일 끝에 helper 추가)
- Create: `apps/termy/Sources/AgentResumeFlags.swift`
- Test: `apps/termy-tests/Sources/ForegroundProcessWatcherTests.swift`, `apps/termy-tests/Sources/AgentResumeFlagsTests.swift`

**Interfaces:**
- Consumes: `AgentKind`
- Produces:
  - `ForegroundProcessWatcher.foregroundProcessGroupLeader(masterFd: Int32, shellPid: pid_t) -> pid_t?` (static, nonisolated)
  - `ForegroundProcessWatcher.agentEntrypoint(in arguments: [String]) -> (index: Int, kind: AgentKind)?` (static)
  - `ForegroundProcessWatcher.processCwd(pid: pid_t) -> String?` (static)
  - 기존 `ForegroundProcessWatcher.processName(pid:)`, `processArguments(pid:)`, `classifyAgent(processName:arguments:)` 는 시그니처 그대로
  - `enum AgentResumeFlags { static func extract(kind: AgentKind, argv: [String]) -> [String] }`

- [ ] **Step 1: 실패하는 테스트 작성**

`apps/termy-tests/Sources/ForegroundProcessWatcherTests.swift` 클래스 끝에 추가:

```swift
    // MARK: - agentEntrypoint

    func test_agentEntrypoint_nativeBinary_isIndexZero() {
        let entry = ForegroundProcessWatcher.agentEntrypoint(
            in: ["/Users/u/.local/bin/claude", "--model", "opus"]
        )
        XCTAssertEqual(entry?.index, 0)
        XCTAssertEqual(entry?.kind, .claude)
    }

    func test_agentEntrypoint_nodeLauncher_findsScript() {
        let entry = ForegroundProcessWatcher.agentEntrypoint(
            in: ["node", "/opt/homebrew/bin/codex", "-m", "o3"]
        )
        XCTAssertEqual(entry?.index, 1)
        XCTAssertEqual(entry?.kind, .codex)
    }

    func test_agentEntrypoint_unrelatedScript_isNil() {
        XCTAssertNil(ForegroundProcessWatcher.agentEntrypoint(in: ["node", "server.js"]))
    }

    // MARK: - processCwd

    func test_processCwd_ofCurrentProcess_matchesFileManager() {
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        let actual = ForegroundProcessWatcher.processCwd(pid: getpid())
        XCTAssertEqual(actual.map(resolved), resolved(FileManager.default.currentDirectoryPath))
    }

    func test_processCwd_ofMissingProcess_isNil() {
        // macOS pids stay below 100_000.
        XCTAssertNil(ForegroundProcessWatcher.processCwd(pid: 999_999))
    }
```

새 파일 `apps/termy-tests/Sources/AgentResumeFlagsTests.swift`:

```swift
import XCTest
@testable import termy

final class AgentResumeFlagsTests: XCTestCase {
    private func claude(_ argv: [String]) -> [String] {
        AgentResumeFlags.extract(kind: .claude, argv: argv)
    }

    private func codex(_ argv: [String]) -> [String] {
        AgentResumeFlags.extract(kind: .codex, argv: argv)
    }

    func test_claude_keepsPermissionAndModelFlags() {
        XCTAssertEqual(
            claude(["claude", "--dangerously-skip-permissions", "--model", "opus", "--permission-mode", "plan"]),
            ["--dangerously-skip-permissions", "--model", "opus", "--permission-mode", "plan"]
        )
    }

    func test_claude_dropsPositionalPrompt() {
        XCTAssertEqual(claude(["claude", "--model", "opus", "fix the login bug"]), ["--model", "opus"])
    }

    func test_claude_dropsPrintAndSessionSelection() {
        XCTAssertEqual(
            claude(["claude", "-p", "--resume", "old-id", "--continue", "--verbose", "--model", "sonnet"]),
            ["--model", "sonnet"]
        )
    }

    func test_claude_variadicStopsAtNextFlag() {
        XCTAssertEqual(
            claude(["claude", "--allowedTools", "Read", "Bash(git log:*)", "--add-dir", "/a", "/b", "--model", "opus"]),
            ["--allowedTools", "Read", "Bash(git log:*)", "--add-dir", "/a", "/b", "--model", "opus"]
        )
    }

    func test_claude_equalsForm() {
        XCTAssertEqual(
            claude(["claude", "--model=opus", "--permission-mode=plan", "--debug=api"]),
            ["--model=opus", "--permission-mode=plan"]
        )
    }

    func test_claude_nodeLauncher() {
        XCTAssertEqual(
            claude(["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--model", "opus", "hello"]),
            ["--model", "opus"]
        )
    }

    func test_claude_valueFlagWithoutValue_isDropped() {
        XCTAssertEqual(claude(["claude", "--model"]), [])
        XCTAssertEqual(claude(["claude", "--add-dir"]), [])
    }

    func test_codex_keepsRepeatedConfigInOrder() {
        XCTAssertEqual(
            codex(["node", "/opt/homebrew/bin/codex", "-c", "model_reasoning_effort=high", "-m", "gpt-5",
                   "-c", "sandbox_mode=workspace-write", "--search", "write tests"]),
            ["-c", "model_reasoning_effort=high", "-m", "gpt-5", "-c", "sandbox_mode=workspace-write"]
        )
    }

    func test_pIsProfileForCodexButPrintForClaude() {
        XCTAssertEqual(codex(["codex", "-p", "work"]), ["-p", "work"])
        XCTAssertEqual(claude(["claude", "-p", "work"]), [])
    }

    func test_codex_dropsSubcommandAndOldSessionId() {
        XCTAssertEqual(
            codex(["codex", "resume", "019a-old", "--dangerously-bypass-approvals-and-sandbox", "--approve-for-me"]),
            ["--dangerously-bypass-approvals-and-sandbox", "--approve-for-me"]
        )
    }

    func test_codex_fullAutoIsNotCarried() {
        // Not accepted by codex-cli 0.160.1's `codex resume`.
        XCTAssertEqual(codex(["codex", "--full-auto"]), [])
    }

    func test_noAgentEntrypoint_returnsEmpty() {
        XCTAssertEqual(claude(["node", "server.js", "--model", "x"]), [])
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `xcodegen generate` 후 `-only-testing:termy-tests/ForegroundProcessWatcherTests -only-testing:termy-tests/AgentResumeFlagsTests`.
Expected: 컴파일 실패 — `type 'ForegroundProcessWatcher' has no member 'agentEntrypoint'`, `cannot find 'AgentResumeFlags' in scope`.

- [ ] **Step 3: `ForegroundProcessWatcher` 리팩터링과 helper 추가**

`currentForegroundAgent(masterFd:shellPid:)` 전체를 다음 두 함수로 바꾼다(첫 번째는 `// MARK: - Pure helpers (testable)` 바로 위, 기존 위치):

```swift
    /// Read the foreground PG of `masterFd`, look up the PG leader, and
    /// classify it. Returns `nil` for the shell prompt, for unknown binaries
    /// (vim, less, etc.), and on syscall failure.
    private func currentForegroundAgent(masterFd: Int32, shellPid: pid_t) -> AgentKind? {
        guard let pid = Self.foregroundProcessGroupLeader(masterFd: masterFd, shellPid: shellPid),
              let name = Self.processName(pid: pid)
        else { return nil }
        return Self.classifyAgent(
            processName: name,
            arguments: Self.processArguments(pid: pid) ?? []
        )
    }

    /// PID of the PTY's foreground process-group leader, or nil when the
    /// shell itself owns the foreground (or on syscall failure). The pgrp ID
    /// equals the leader's PID. Static so `Pane` can call it synchronously
    /// on the main actor for the update-relaunch capture.
    static func foregroundProcessGroupLeader(masterFd: Int32, shellPid: pid_t) -> pid_t? {
        let fgPgrp = tcgetpgrp(masterFd)
        guard fgPgrp > 0 else { return nil }
        // If the foreground PG is the shell's own PG, no agent is running.
        // (Shell-builtins still run in the shell's PG, hence comparing PG
        // and not "exact PID == shell".)
        let shellPgrp = getpgid(shellPid)
        if shellPgrp > 0 && shellPgrp == fgPgrp { return nil }
        return fgPgrp
    }
```

`classifyAgent(processName:arguments:)` 의 마지막 줄 `return classifyAgent(fromArguments: arguments)` 를 다음으로 바꾼다:

```swift
        return agentEntrypoint(in: arguments)?.kind
```

`private static func classifyAgent(fromArguments arguments: [String]) -> AgentKind?` 전체를 다음으로 바꾼다:

```swift
    /// Find the argument that names the agent CLI — `argv[0]` for a native
    /// binary, the script path after `node` / `bun` / `deno` for JS
    /// launchers. Shared with `AgentResumeFlags`, which keeps only the
    /// arguments after the entrypoint.
    static func agentEntrypoint(in arguments: [String]) -> (index: Int, kind: AgentKind)? {
        for (index, argument) in arguments.enumerated() {
            let normalized = argument.lowercased()
            let basename = (normalized as NSString).lastPathComponent
            if basename == "codex"
                || basename.hasPrefix("codex-")
                || normalized.contains("@openai/codex") {
                return (index, .codex)
            }
            if basename == "claude"
                || basename.hasPrefix("claude-")
                || normalized.contains("@anthropic-ai/claude-code") {
                return (index, .claude)
            }
        }
        return nil
    }
```

`processArguments(pid:)` 뒤(타입의 닫는 `}` 앞)에 추가:

```swift
    /// The process's current working directory via
    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. Returns nil if the process is
    /// gone or the call fails. Used instead of the pane's OSC 7 cwd, which
    /// only updates when the user's shell config emits it.
    static func processCwd(pid: pid_t) -> String? {
        #if canImport(Darwin)
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
        #else
        return nil
        #endif
    }
```

- [ ] **Step 4: `AgentResumeFlags` 작성**

새 파일 `apps/termy/Sources/AgentResumeFlags.swift`:

```swift
// AgentResumeFlags.swift
//
// Picks the argv pieces worth carrying into `claude --resume` /
// `codex resume`: permission and model flags only. Everything else —
// positional prompts above all — is dropped, so a resume never replays
// the prompt the agent was launched with.
//
// The argv comes from the running agent process, so every flag in it was
// accepted by the CLI version that is running. A stale entry in these
// tables just never matches, and a new CLI flag just isn't carried; only
// a change to the resume command itself needs a termy update.

import Foundation

enum AgentResumeFlags {
    private enum Arity {
        /// Boolean switch.
        case none
        /// Exactly one value. May repeat (`-c a=1 -c b=2`); every
        /// occurrence is kept in order.
        case one
        /// Variadic (commander `<values...>`): every following argument up
        /// to the next one starting with `-`.
        case many
    }

    private static let claude: [String: Arity] = [
        "--dangerously-skip-permissions": .none,
        "--model": .one,
        "--permission-mode": .one,
        "--allowedTools": .many,
        "--allowed-tools": .many,
        "--disallowedTools": .many,
        "--disallowed-tools": .many,
        "--add-dir": .many,
    ]

    /// Checked against `codex resume --help` (codex-cli 0.160.1). `-p` is
    /// `--profile` here, unlike claude's `-p` / `--print`.
    private static let codex: [String: Arity] = [
        "--approve-for-me": .none,
        "--dangerously-bypass-approvals-and-sandbox": .none,
        "-m": .one, "--model": .one,
        "-s": .one, "--sandbox": .one,
        "-a": .one, "--ask-for-approval": .one,
        "-p": .one, "--profile": .one,
        "-c": .one, "--config": .one,
        "--add-dir": .one,
    ]

    static func extract(kind: AgentKind, argv: [String]) -> [String] {
        guard let entry = ForegroundProcessWatcher.agentEntrypoint(in: argv) else { return [] }
        let args = Array(argv.dropFirst(entry.index + 1))
        let table = (kind == .claude) ? claude : codex
        var kept: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                // `--flag=value` carries its value inline.
                if let arity = table[String(arg[..<eq])], arity != .none {
                    kept.append(arg)
                }
                i += 1
                continue
            }
            guard let arity = table[arg] else {
                i += 1
                continue
            }
            switch arity {
            case .none:
                kept.append(arg)
                i += 1
            case .one:
                if i + 1 < args.count {
                    kept.append(contentsOf: [arg, args[i + 1]])
                }
                i += 2
            case .many:
                var j = i + 1
                while j < args.count, !args[j].hasPrefix("-") { j += 1 }
                if j > i + 1 {
                    kept.append(contentsOf: args[i..<j])
                }
                i = j
            }
        }
        return kept
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: Step 2 와 같은 명령.
Expected: `** TEST SUCCEEDED **`. 기존 `test_classifyAgent_*` 도 그대로 통과해야 한다(리팩터링 회귀 확인).

- [ ] **Step 6: 커밋**

```bash
git add apps/termy/Sources/ForegroundProcessWatcher.swift apps/termy/Sources/AgentResumeFlags.swift \
  apps/termy-tests/Sources/ForegroundProcessWatcherTests.swift apps/termy-tests/Sources/AgentResumeFlagsTests.swift
git commit -m "feat(update): agent 프로세스 cwd·entrypoint 조회와 resume 플래그 허용 목록을 추가"
```

---

## Task 3: turn 경계 추적과 작업 중 집계

**Files:**
- Modify: `apps/termy/Sources/PaneState.swift` (`PaneSnapshot` 69-92행, `PaneStateMachine.apply` 125-310행)
- Modify: `apps/termy/Sources/MissionControlModel.swift` (`rebuildGlobalOrder` 99-111행, `pumpUpdates` 140-149행)
- Test: `apps/termy-tests/Sources/PaneStateMachineTests.swift`, `apps/termy-tests/Sources/MissionControlModelTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `PaneSnapshot.turnOpen: Bool` (기본 false)
  - `PaneSnapshot.isMidTurn: Bool` (extension)
  - `MissionControlModel.applySnapshot(_ snapshot: PaneSnapshot)`
  - `MissionControlModel.snapshot(paneId: String) -> PaneSnapshot?`
  - `MissionControlModel.midTurnPaneCount: Int`
  - `MissionControlModel.onLivePanesChanged: (() -> Void)?`

- [ ] **Step 1: 실패하는 테스트 작성**

`apps/termy-tests/Sources/PaneStateMachineTests.swift` 클래스 끝에 추가. 기존 `makeEvent` helper(agent `"claude-code"`)와 `empty()` 를 쓴다.

```swift
    // MARK: - turnOpen / isMidTurn

    private func codexEvent(_ kind: HookEventKind, session: String? = "s1") -> HookEvent {
        var meta = HookEvent.Meta()
        meta.sessionId = session
        return HookEvent(event: kind, paneId: "p1", projectId: "proj", ts: 1.0, agent: "codex", meta: meta)
    }

    private func open() -> PaneSnapshot {
        PaneStateMachine.apply(makeEvent(.userPromptSubmit, prompt: "go"), to: empty())
    }

    func test_turnOpen_defaultsToFalse() {
        XCTAssertFalse(empty().turnOpen)
    }

    func test_turnOpen_userPromptSubmit_opens() {
        XCTAssertTrue(open().turnOpen)
        XCTAssertTrue(open().isMidTurn)
    }

    func test_turnOpen_stop_closes() {
        let after = PaneStateMachine.apply(makeEvent(.stop, last: "done"), to: open())
        XCTAssertFalse(after.turnOpen)
        XCTAssertFalse(after.isMidTurn)
    }

    func test_turnOpen_stopFailure_closes() {
        XCTAssertFalse(PaneStateMachine.apply(makeEvent(.stopFailure), to: open()).turnOpen)
    }

    func test_turnOpen_sessionEndAndPtyExit_close() {
        XCTAssertFalse(PaneStateMachine.apply(makeEvent(.sessionEnd), to: open()).turnOpen)
        XCTAssertFalse(PaneStateMachine.apply(makeEvent(.ptyExit, exitCode: 0), to: open()).turnOpen)
        XCTAssertFalse(PaneStateMachine.apply(makeEvent(.ptyExit, exitCode: 1), to: open()).turnOpen)
    }

    func test_turnOpen_toolEvents_open() {
        for kind in [HookEventKind.preToolUse, .postToolUse, .postToolUseFailure] {
            var s = empty()
            s.state = .idle
            XCTAssertTrue(
                PaneStateMachine.apply(makeEvent(kind, toolName: "Bash"), to: s).turnOpen,
                "\(kind) should open the turn"
            )
        }
    }

    // Review Focus 1
    func test_turnOpen_toolUseAfterStop_reopensTurn() {
        let stopped = PaneStateMachine.apply(makeEvent(.stop, last: "done"), to: open())
        let resumed = PaneStateMachine.apply(makeEvent(.preToolUse, toolName: "Bash"), to: stopped)
        XCTAssertTrue(resumed.isMidTurn)
    }

    func test_turnOpen_sessionIdChange_resets() {
        var s = open()
        s.lastSessionId = "s1"
        let after = PaneStateMachine.apply(makeEvent(.notification, session: "s2", reason: "idle"), to: s)
        XCTAssertFalse(after.turnOpen)
    }

    func test_turnOpen_codexSessionStart_closes() {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: "proj", agentKind: .codex)
        s.state = .thinking
        s.turnOpen = true
        XCTAssertFalse(PaneStateMachine.apply(codexEvent(.sessionStart), to: s).turnOpen)
    }

    func test_turnOpen_claudeSessionStart_keepsTurn() {
        // Auto-compact fires SessionStart mid-turn.
        let after = PaneStateMachine.apply(makeEvent(.sessionStart), to: open())
        XCTAssertTrue(after.turnOpen)
    }

    func test_isMidTurn_permissionWait_isTrue() {
        let waiting = PaneStateMachine.apply(makeEvent(.notification, reason: "permission"), to: open())
        XCTAssertEqual(waiting.state, .waiting)
        XCTAssertTrue(waiting.isMidTurn)
    }

    func test_isMidTurn_claudePermissionThenStop_isFalse() {
        // notificationReason stays "permission" after Stop, which is why the
        // gate reads turnOpen instead of the wait reason.
        let waiting = PaneStateMachine.apply(makeEvent(.notification, reason: "permission"), to: open())
        let stopped = PaneStateMachine.apply(makeEvent(.stop, last: "done"), to: waiting)
        XCTAssertEqual(stopped.notificationReason, "permission")
        XCTAssertFalse(stopped.isMidTurn)
    }

    func test_isMidTurn_promotedFromPossible_isFalse() {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: "proj", agentKind: .codex)
        s.turnOpen = true
        s.state = .waiting
        s.waitSource = .promotedFromPossible
        XCTAssertFalse(s.isMidTurn)
    }

    func test_isMidTurn_possiblyWaiting_isTrue() {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: "proj", agentKind: .codex)
        s.turnOpen = true
        s.state = .possiblyWaiting
        XCTAssertTrue(s.isMidTurn)
    }

    func test_isMidTurn_initializing_isFalse() {
        var s = empty()
        s.turnOpen = true
        XCTAssertFalse(s.isMidTurn)
    }

    func test_paneSnapshot_codableRoundTrip_preservesTurnOpen() throws {
        var s = empty()
        s.turnOpen = true
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(decoded.turnOpen)
    }
```

`apps/termy-tests/Sources/MissionControlModelTests.swift` 클래스 끝에 추가:

```swift
    private func snap(_ id: String, turnOpen: Bool, state: PaneState = .thinking) -> PaneSnapshot {
        var s = PaneSnapshot.empty(paneId: id, projectId: "proj")
        s.state = state
        s.turnOpen = turnOpen
        return s
    }

    func test_midTurnPaneCount_countsOnlyLiveMidTurnPanes() {
        let model = MissionControlModel(startPump: false)
        model.setLivePaneIds(["p1", "p2", "p3"], forWindow: UUID())
        model.applySnapshot(snap("p1", turnOpen: true))
        model.applySnapshot(snap("p2", turnOpen: false, state: .waiting))
        model.applySnapshot(snap("p3", turnOpen: true, state: .waiting))   // permission wait
        model.applySnapshot(snap("closed", turnOpen: true))                // not live
        XCTAssertEqual(model.midTurnPaneCount, 2)
    }

    // Review Focus 2
    func test_midTurnPaneCount_dropsWhenBusyWindowCloses() {
        let model = MissionControlModel(startPump: false)
        let winA = UUID()
        let winB = UUID()
        model.setLivePaneIds(["a1"], forWindow: winA)
        model.setLivePaneIds(["b1"], forWindow: winB)
        model.applySnapshot(snap("a1", turnOpen: true))
        model.applySnapshot(snap("b1", turnOpen: false, state: .idle))
        XCTAssertEqual(model.midTurnPaneCount, 1)
        model.removeWindow(winA)
        XCTAssertEqual(model.midTurnPaneCount, 0)
    }

    func test_removeWindow_firesOnLivePanesChanged() {
        let model = MissionControlModel(startPump: false)
        let win = UUID()
        var calls = 0
        model.onLivePanesChanged = { calls += 1 }
        model.setLivePaneIds(["p1"], forWindow: win)
        model.removeWindow(win)
        XCTAssertEqual(calls, 2)
    }

    func test_snapshotLookup_returnsLatest() {
        let model = MissionControlModel(startPump: false)
        model.applySnapshot(snap("p1", turnOpen: false, state: .idle))
        model.applySnapshot(snap("p1", turnOpen: true))
        XCTAssertEqual(model.snapshot(paneId: "p1")?.turnOpen, true)
        XCTAssertNil(model.snapshot(paneId: "nope"))
    }

    func test_applySnapshot_notifiesSubscriber() {
        let model = MissionControlModel(startPump: false)
        var seen: [String] = []
        model.onSnapshotUpdate = { seen.append($0.paneId) }
        model.applySnapshot(snap("p1", turnOpen: true))
        XCTAssertEqual(seen, ["p1"])
    }
```

> `var calls` / `var seen` 를 closure 에서 바꾸는 것이 Swift 6 에서 "mutation of captured var" 오류를 내면, Task 5 의 `Counter` 같은 `@MainActor final class` 상자로 바꾼다. 이 테스트 클래스는 `@MainActor` 이고 `onLivePanesChanged` / `onSnapshotUpdate` 는 non-Sendable closure 이므로 보통은 그대로 컴파일된다.

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `-only-testing:termy-tests/PaneStateMachineTests -only-testing:termy-tests/MissionControlModelTests`.
Expected: 컴파일 실패 — `value of type 'PaneSnapshot' has no member 'turnOpen'`, `has no member 'applySnapshot'`.

- [ ] **Step 3: `PaneSnapshot` 에 필드 추가**

`PaneState.swift` 의 `var lastPtyActivityAt: Date?` 선언 바로 뒤에 추가:

```swift
    /// True between the start of an agent turn and its end. Opened by
    /// UserPromptSubmit and by any tool event (tools only run inside a
    /// turn — this also catches Claude continuing after a blocking Stop
    /// hook), closed by Stop / StopFailure / SessionEnd / PtyExit and by
    /// session resets. Feeds `isMidTurn`, which holds update relaunches.
    var turnOpen: Bool = false
```

`CodingKeys` 의 마지막 줄을 다음으로 바꾼다:

```swift
        case updatedAt, enteredStateAt, agentKind, lastPtyActivityAt, turnOpen
```

`extension PaneSnapshot { static func empty(...) }` 블록 뒤에 추가:

```swift
extension PaneSnapshot {
    /// The agent is inside a turn, so restarting now would kill work that
    /// `claude --resume` / `codex resume` can't bring back. Permission and
    /// question waits count — they happen mid-turn. A Codex pane promoted
    /// to WAIT by the silence heuristic doesn't: termy already treats it as
    /// waiting for input, and a missed Codex Stop would otherwise hold an
    /// update forever.
    var isMidTurn: Bool {
        turnOpen
            && state != .initializing
            && !(state == .waiting && waitSource == .promotedFromPossible)
    }
}
```

- [ ] **Step 4: 상태 머신 전환 추가**

`PaneStateMachine.apply` 안에서 아래 위치에 한 줄씩 추가한다.

session id 변경 reset 블록(`next.enteredStateAt = next.updatedAt` 다음, 닫는 `}` 앞):

```swift
            next.turnOpen = false
```

`.sessionStart` 의 Codex 분기(`if resolvedKind == .codex {` 안, `next.enteredStateAt = next.updatedAt` 다음):

```swift
                next.turnOpen = false
```

`.userPromptSubmit` 케이스 끝(`next.enteredStateAt = next.updatedAt` 다음):

```swift
            next.turnOpen = true
```

`.stop` 케이스 끝(`next.enteredStateAt = next.updatedAt` 다음):

```swift
            next.turnOpen = false
```

`.stopFailure` 케이스 끝:

```swift
            next.turnOpen = false
```

`.postToolUseFailure` 케이스의 `break` 를 다음으로 바꾼다(주석은 유지):

```swift
            next.turnOpen = true
```

`.sessionEnd, .ptyExit` 케이스 끝(`next.enteredStateAt = next.updatedAt` 다음):

```swift
            next.turnOpen = false
```

`.preToolUse` 케이스의 첫 줄로(`if event.meta.toolName == "AskUserQuestion" {` 앞):

```swift
            next.turnOpen = true
```

`.postToolUse` 케이스의 첫 줄로(`if event.meta.toolName == "AskUserQuestion",` 앞):

```swift
            next.turnOpen = true
```

파일 머리 주석의 상태 표 아래(`// ♪ = Notifier plays ...` 문단 뒤)에 추가:

```swift
//
// Orthogonal to the state: `turnOpen` tracks turn boundaries
// (UserPromptSubmit / tool events open, Stop / StopFailure / SessionEnd /
// PtyExit / resets close) for the update-relaunch gate.
```

- [ ] **Step 5: `MissionControlModel` 확장**

`var onSnapshotUpdate: ((PaneSnapshot) -> Void)?` 선언 뒤에 추가:

```swift
    /// Called after the set of live panes changes (window registered,
    /// re-registered, or closed). `UpdateRelaunchGate` re-counts mid-turn
    /// panes on it, since closing a busy window changes the count without
    /// any snapshot update.
    var onLivePanesChanged: (() -> Void)?
```

`rebuildGlobalOrder()` 의 마지막 `recomputeItems()` 뒤에 추가:

```swift
        onLivePanesChanged?()
```

`pumpUpdates()` 의 `MainActor.run` 안 세 줄(`self.snapshotsById[...] = ...`, `self.recomputeItems()`, `self.onSnapshotUpdate?(...)`)을 다음 한 줄로 바꾼다:

```swift
                self.applySnapshot(update.snapshot)
```

`pumpUpdates()` 바로 앞에 추가:

```swift
    /// Fold one daemon update into the model. The pump calls this for every
    /// HookDaemon update; tests call it directly.
    func applySnapshot(_ snapshot: PaneSnapshot) {
        snapshotsById[snapshot.paneId] = snapshot
        recomputeItems()
        onSnapshotUpdate?(snapshot)
    }

    /// Latest snapshot for a pane, or nil before its first hook event.
    func snapshot(paneId: String) -> PaneSnapshot? {
        snapshotsById[paneId]
    }

    /// Live panes whose agent is mid-turn. `UpdateRelaunchGate` holds an
    /// update relaunch until this reaches zero.
    var midTurnPaneCount: Int {
        snapshotsById.values.reduce(0) { count, snapshot in
            count + (livePaneIds.contains(snapshot.paneId) && snapshot.isMidTurn ? 1 : 0)
        }
    }
```

`sameDashboardShape` 에는 `turnOpen` 을 넣지 않는다(spec §5.6 — 대시보드 재측정 횟수 불변).

- [ ] **Step 6: 테스트 통과 확인**

Run: Step 2 와 같은 명령. 그다음 `-only-testing:termy-tests/HookDaemonPossiblyWaitingTests -only-testing:termy-tests/MissionControlDashboardShapeTests -only-testing:termy-tests/AgentKindTests` 로 주변 회귀 확인.
Expected: 모두 `** TEST SUCCEEDED **`.

- [ ] **Step 7: 커밋**

```bash
git add apps/termy/Sources/PaneState.swift apps/termy/Sources/MissionControlModel.swift \
  apps/termy-tests/Sources/PaneStateMachineTests.swift apps/termy-tests/Sources/MissionControlModelTests.swift
git commit -m "feat(update): turn 경계를 추적하고 작업 중인 pane 수를 집계"
```

---

## Task 4: 업데이트 직전 수집과 봉인 저장

**Files:**
- Modify: `apps/termy/Sources/AgentResume.swift` (`AgentResumeCapture` 추가)
- Modify: `apps/termy/Sources/SessionPersistence.swift` (`save` 59-89행)
- Modify: `apps/termy/Sources/Pane.swift` (`startShell` 뒤에 메서드 추가)
- Modify: `apps/termy/Sources/MainWindowController.swift:256-280` (`sessionWindowRecord`)
- Modify: `apps/termy/Sources/WindowManager.swift` (`restoreSessionWindows` 뒤에 메서드 추가)
- Test: `apps/termy-tests/Sources/AgentResumeCaptureTests.swift`, `apps/termy-tests/Sources/SessionPersistenceTests.swift`

**Interfaces:**
- Consumes: Task 1 `AgentResumeRecord`, `PaneRecord(cwd:agentResume:)`; Task 2 `ForegroundProcessWatcher.foregroundProcessGroupLeader/processName/processArguments/processCwd/classifyAgent(processName:arguments:)`, `AgentResumeFlags.extract`; Task 3 `MissionControlModel.snapshot(paneId:)`
- Produces:
  - `enum AgentResumeCapture { static func record(foregroundAgent: AgentKind?, argv: [String]?, processCwd: String?, snapshot: PaneSnapshot?) -> AgentResumeRecord? }`
  - `SessionPersistence.sealWithFinalRecord(_ record: SessionRecord) throws` (nonisolated, 동기)
  - `Pane.agentResumeRecord(snapshot: PaneSnapshot?) -> AgentResumeRecord?`
  - `MainWindowController.sessionWindowRecord(includeAgentResume: Bool = false) -> WindowRecord?`
  - `WindowManager.prepareForUpdateRelaunch()`

- [ ] **Step 1: 실패하는 테스트 작성**

새 파일 `apps/termy-tests/Sources/AgentResumeCaptureTests.swift`:

```swift
import XCTest
@testable import termy

final class AgentResumeCaptureTests: XCTestCase {
    private func snapshot(
        kind: AgentKind = .claude,
        state: PaneState = .idle,
        sessionId: String? = "sess-1"
    ) -> PaneSnapshot {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: "proj", agentKind: kind)
        s.state = state
        s.lastSessionId = sessionId
        return s
    }

    private func capture(
        agent: AgentKind? = .claude,
        argv: [String]? = ["claude", "--model", "opus", "do it"],
        cwd: String? = "/proj",
        snapshot: PaneSnapshot?
    ) -> AgentResumeRecord? {
        AgentResumeCapture.record(foregroundAgent: agent, argv: argv, processCwd: cwd, snapshot: snapshot)
    }

    func test_liveAgentWithSession_recordsKindIdCwdAndFlags() {
        XCTAssertEqual(
            capture(snapshot: snapshot()),
            AgentResumeRecord(kind: .claude, sessionId: "sess-1", cwd: "/proj", flags: ["--model", "opus"])
        )
    }

    func test_noForegroundAgent_isNil() {
        XCTAssertNil(capture(agent: nil, snapshot: snapshot()))
    }

    func test_noSnapshot_isNil() {
        XCTAssertNil(capture(snapshot: nil))
    }

    func test_noSessionId_isNil() {
        // Hooks not installed: no session id ever arrived.
        XCTAssertNil(capture(snapshot: snapshot(sessionId: nil)))
        XCTAssertNil(capture(snapshot: snapshot(sessionId: "")))
    }

    func test_agentKindMismatch_isNil() {
        // Snapshot still describes an earlier claude; codex is in front now.
        XCTAssertNil(capture(agent: .codex, argv: ["codex"], snapshot: snapshot(kind: .claude)))
    }

    func test_initializingSnapshot_isNil() {
        // The agent's session ended (SessionEnd / PtyExit → INIT).
        XCTAssertNil(capture(snapshot: snapshot(state: .initializing)))
    }

    func test_unreadableArgvAndCwd_stillRecordsSession() {
        XCTAssertEqual(
            capture(argv: nil, cwd: nil, snapshot: snapshot()),
            AgentResumeRecord(kind: .claude, sessionId: "sess-1", cwd: nil, flags: [])
        )
    }
}
```

`apps/termy-tests/Sources/SessionPersistenceTests.swift` 클래스 끝에 추가:

```swift
    // Review Focus 4
    func test_seal_writesRecordAndDropsLaterSaves() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SessionPersistence(rootDir: root)
        let final = SessionRecord(windows: [
            WindowRecord(
                frame: FrameRecord(x: 0, y: 0, width: 100, height: 100),
                rows: [[PaneRecord(
                    cwd: "/x",
                    agentResume: AgentResumeRecord(kind: .claude, sessionId: "s1", cwd: "/x", flags: [])
                )]]
            )
        ])
        try persistence.sealWithFinalRecord(final)
        // An autosave arriving after the seal (e.g. already in flight) must not win.
        try await persistence.save(SessionRecord(windows: []))
        guard case .loaded(let loaded) = await persistence.load() else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(loaded, final)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `xcodegen generate` 후 `-only-testing:termy-tests/AgentResumeCaptureTests -only-testing:termy-tests/SessionPersistenceTests`.
Expected: 컴파일 실패 — `cannot find 'AgentResumeCapture' in scope`, `has no member 'sealWithFinalRecord'`.

- [ ] **Step 3: `AgentResumeCapture` 추가**

`apps/termy/Sources/AgentResume.swift` 끝에 추가:

```swift
/// Decides whether a pane gets an `AgentResumeRecord`. Pure — `Pane`
/// reads the live process info and passes it in.
enum AgentResumeCapture {
    /// A record only when an agent owns the PTY foreground right now and
    /// termy's hook snapshot has a session id for that same agent.
    static func record(
        foregroundAgent: AgentKind?,
        argv: [String]?,
        processCwd: String?,
        snapshot: PaneSnapshot?
    ) -> AgentResumeRecord? {
        guard let kind = foregroundAgent,
              let snapshot,
              snapshot.agentKind == kind,
              snapshot.state != .initializing,
              let sessionId = snapshot.lastSessionId,
              !sessionId.isEmpty
        else { return nil }
        return AgentResumeRecord(
            kind: kind,
            sessionId: sessionId,
            cwd: processCwd,
            flags: AgentResumeFlags.extract(kind: kind, argv: argv ?? [])
        )
    }
}
```

- [ ] **Step 4: `SessionPersistence` 봉인 쓰기**

파일 상단 `import Foundation` 아래에 `import os` 를 추가한다.

`actor SessionPersistence {` 의 `nonisolated let quarantineDir: URL` 다음에 추가:

```swift
    /// Serializes every write and holds the sealed flag, so the final
    /// update-relaunch write can't be overtaken by an autosave already in
    /// flight on the actor.
    private nonisolated let writeLock = OSAllocatedUnfairLock(initialState: false)
```

기존 `func save(_ record: SessionRecord) throws { ... }` 를 통째로 다음 세 함수로 바꾼다. `writeFile` 의 본문은 기존 `save` 본문(encode → temp → setAttributes → rename) 그대로다:

```swift
    /// Atomic write: encode → temp → `rename(2)`. Final file is `0600`.
    /// Dropped once `sealWithFinalRecord` has run.
    func save(_ record: SessionRecord) throws {
        try write(record, seal: false)
    }

    /// Final write before a Sparkle update relaunch. Synchronous on the
    /// caller's thread — the terminate path's async flush can't be relied on
    /// — and every later `save` is dropped, so window closes and the
    /// shutdown flush can't replace the agent-resume records.
    nonisolated func sealWithFinalRecord(_ record: SessionRecord) throws {
        try write(record, seal: true)
    }

    private nonisolated func write(_ record: SessionRecord, seal: Bool) throws {
        try writeLock.withLockUnchecked { sealed in
            guard !sealed else { return }
            try writeFile(record)
            if seal { sealed = true }
        }
    }

    private nonisolated func writeFile(_ record: SessionRecord) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(record)
        } catch {
            throw SessionPersistenceError.encodeFailed(error)
        }

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp-session-\(UUID().uuidString).json")
        do {
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tempURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw SessionPersistenceError.writeFailed(error)
        }

        let ok = rename(tempURL.path, fileURL.path)
        if ok != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: tempURL)
            throw SessionPersistenceError.renameFailed(code)
        }
    }
```

- [ ] **Step 5: `Pane` 에서 실제 프로세스 정보 읽기**

`apps/termy/Sources/Pane.swift` 의 `startShell()` 바로 뒤(`func focusTerminal()` 앞)에 추가:

```swift
    /// Live agent session in this pane for the update-relaunch save. nil
    /// when no agent owns the PTY foreground or termy has no session id for
    /// it (see `AgentResumeCapture`).
    func agentResumeRecord(snapshot: PaneSnapshot?) -> AgentResumeRecord? {
        let masterFd = terminal.process.childfd
        let shellPid = terminal.process.shellPid
        guard masterFd >= 0, shellPid > 0,
              let pid = ForegroundProcessWatcher.foregroundProcessGroupLeader(
                  masterFd: masterFd,
                  shellPid: shellPid
              ),
              let name = ForegroundProcessWatcher.processName(pid: pid)
        else { return nil }
        let argv = ForegroundProcessWatcher.processArguments(pid: pid)
        return AgentResumeCapture.record(
            foregroundAgent: ForegroundProcessWatcher.classifyAgent(
                processName: name,
                arguments: argv ?? []
            ),
            argv: argv,
            processCwd: ForegroundProcessWatcher.processCwd(pid: pid),
            snapshot: snapshot
        )
    }
```

- [ ] **Step 6: 세션 레코드에 resume 포함 옵션**

`MainWindowController.sessionWindowRecord()` 의 선언과 `rows` 계산을 다음으로 바꾼다(나머지 본문은 그대로):

```swift
    /// Snapshot this window's restorable state. Returns nil for a paneless
    /// window (nothing worth restoring). `includeAgentResume` adds each
    /// pane's live agent session — only the update-relaunch save asks.
    func sessionWindowRecord(includeAgentResume: Bool = false) -> WindowRecord? {
        guard let window, !workspace.panes.isEmpty else { return nil }
        let rows: [[PaneRecord]] = workspace.rows.map { row in
            row.map { pane in
                PaneRecord(
                    cwd: pane.currentCwd,
                    agentResume: includeAgentResume
                        ? pane.agentResumeRecord(
                            snapshot: missionControlModel.snapshot(paneId: pane.paneId)
                        )
                        : nil
                )
            }
        }
```

- [ ] **Step 7: `WindowManager.prepareForUpdateRelaunch`**

`apps/termy/Sources/WindowManager.swift` 의 `restoreSessionWindows()` 뒤에 추가:

```swift
    /// Final session save before a Sparkle update relaunch: snapshot every
    /// window with each pane's live agent session and seal session.json so
    /// nothing written during shutdown replaces it. The next launch reopens
    /// those conversations (`MainWindowController.applySessionLayout`).
    func prepareForUpdateRelaunch() {
        guard let sessionPersistence else { return }
        let records = controllers.compactMap { $0.sessionWindowRecord(includeAgentResume: true) }
        try? sessionPersistence.sealWithFinalRecord(SessionRecord(windows: records))
    }
```

- [ ] **Step 8: 테스트 통과 확인**

Run: Step 2 와 같은 명령, 이어서 `-only-testing:termy-tests/WindowManagerTests -only-testing:termy-tests/SessionRecordTests`.
Expected: 모두 `** TEST SUCCEEDED **`.

- [ ] **Step 9: 커밋**

```bash
git add apps/termy/Sources/AgentResume.swift apps/termy/Sources/SessionPersistence.swift \
  apps/termy/Sources/Pane.swift apps/termy/Sources/MainWindowController.swift apps/termy/Sources/WindowManager.swift \
  apps/termy-tests/Sources/AgentResumeCaptureTests.swift apps/termy-tests/Sources/SessionPersistenceTests.swift
git commit -m "feat(update): 업데이트 직전에 pane별 agent 세션을 모아 session.json을 봉인 저장"
```

---

## Task 5: 복원 시 resume 명령 입력

**Files:**
- Create: `apps/termy/Sources/MainQueueTimer.swift`, `apps/termy/Sources/StartupInputScheduler.swift`
- Create: `apps/termy-tests/Sources/ManualScheduler.swift`, `apps/termy-tests/Sources/StartupInputSchedulerTests.swift`
- Modify: `apps/termy/Sources/TermyTerminalView.swift:684-700` (`dataReceived`)
- Modify: `apps/termy/Sources/Pane.swift:84-123` (`init`), 프로퍼티 추가
- Modify: `apps/termy/Sources/Workspace.swift:451-472` (`addPane`)
- Modify: `apps/termy/Sources/MainWindowController.swift:284-291` (`applySessionLayout`)
- Modify: `apps/termy/Sources/WindowManager.swift:30-40` (`restoreSessionWindows`)

**Interfaces:**
- Consumes: Task 1 `AgentResumeCommand.make`, `PaneRecord.agentResume`
- Produces:
  - `typealias ScheduleAfter = @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void`
  - `enum MainQueueTimer { @MainActor static func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void }`
  - `final class StartupInputScheduler` (`init(schedule:fire:)`, `start()`, `outputReceived()`, `hasFired`, `quietInterval = 0.3`, `deadline = 3.0`)
  - 테스트 지원: `ManualScheduler`(`schedule: ScheduleAfter`, `advance(by:)`, `pendingCount`), `Counter`(`value: Int`) — Task 6 도 쓴다
  - `TermyTerminalView.onOutput: (@MainActor () -> Void)?`
  - `Workspace.addPane(cwd:splitAxis:startupInput:)`, `Pane.init(projectId:cwd:startupInput:)` (`startupInput` 기본 nil)

- [ ] **Step 1: 테스트 지원 코드와 실패하는 테스트 작성**

새 파일 `apps/termy-tests/Sources/ManualScheduler.swift`:

```swift
import Foundation
@testable import termy

/// Test double for `ScheduleAfter`: records scheduled actions and runs them
/// only when the test advances the clock.
@MainActor
final class ManualScheduler {
    private struct Entry {
        let id: Int
        let fireAt: TimeInterval
        let action: @MainActor () -> Void
    }

    private var entries: [Entry] = []
    private var nextId = 0
    private(set) var now: TimeInterval = 0

    var pendingCount: Int { entries.count }

    var schedule: ScheduleAfter {
        { [unowned self] delay, action in
            let id = self.nextId
            self.nextId += 1
            self.entries.append(Entry(id: id, fireAt: self.now + delay, action: action))
            return { [weak self] in self?.entries.removeAll { $0.id == id } }
        }
    }

    /// Move the clock forward, firing due actions in time order.
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = entries
            .filter({ $0.fireAt <= target })
            .min(by: { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }) {
            entries.removeAll { $0.id == next.id }
            now = next.fireAt
            next.action()
        }
        now = target
    }
}

/// Mutable counter that `@MainActor` closures can capture.
@MainActor
final class Counter {
    var value = 0
}
```

새 파일 `apps/termy-tests/Sources/StartupInputSchedulerTests.swift`:

```swift
import XCTest
@testable import termy

@MainActor
final class StartupInputSchedulerTests: XCTestCase {
    private func make() -> (StartupInputScheduler, ManualScheduler, Counter) {
        let clock = ManualScheduler()
        let fired = Counter()
        let scheduler = StartupInputScheduler(schedule: clock.schedule) { fired.value += 1 }
        return (scheduler, clock, fired)
    }

    func test_firesAfterOutputGoesQuiet() {
        let (scheduler, clock, fired) = make()
        scheduler.start()
        clock.advance(by: 0.1)
        scheduler.outputReceived()
        clock.advance(by: 0.2)
        scheduler.outputReceived()          // restarts the quiet window
        clock.advance(by: 0.29)
        XCTAssertEqual(fired.value, 0)
        clock.advance(by: 0.02)
        XCTAssertEqual(fired.value, 1)
    }

    func test_firesAtDeadlineWithoutOutput() {
        let (scheduler, clock, fired) = make()
        scheduler.start()
        clock.advance(by: 2.99)
        XCTAssertEqual(fired.value, 0)
        clock.advance(by: 0.02)
        XCTAssertEqual(fired.value, 1)
    }

    // Review Focus 5
    func test_firesAtDeadlineEvenWhileOutputKeepsFlowing() {
        let (scheduler, clock, fired) = make()
        scheduler.start()
        for _ in 0..<50 {
            clock.advance(by: 0.1)
            scheduler.outputReceived()
        }
        XCTAssertEqual(fired.value, 1)
        XCTAssertTrue(scheduler.hasFired)
    }

    func test_firesOnlyOnceAndLeavesNoTimers() {
        let (scheduler, clock, fired) = make()
        scheduler.start()
        scheduler.outputReceived()
        clock.advance(by: 0.3)
        XCTAssertEqual(fired.value, 1)
        scheduler.outputReceived()
        clock.advance(by: 5)
        XCTAssertEqual(fired.value, 1)
        XCTAssertEqual(clock.pendingCount, 0)
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `xcodegen generate` 후 `-only-testing:termy-tests/StartupInputSchedulerTests`.
Expected: 컴파일 실패 — `cannot find type 'ScheduleAfter' in scope`, `cannot find 'StartupInputScheduler' in scope`.

- [ ] **Step 3: `MainQueueTimer` 와 `StartupInputScheduler` 작성**

새 파일 `apps/termy/Sources/MainQueueTimer.swift`:

```swift
// MainQueueTimer.swift
//
// One-shot main-queue timer with a cancel handle. `StartupInputScheduler`
// and `UpdateRelaunchGate` take a `ScheduleAfter` instead of calling this
// directly, so tests can drive time by hand (`ManualScheduler`).

import Foundation

/// Run `action` after `delay`; the returned closure cancels it.
typealias ScheduleAfter = @MainActor (
    _ delay: TimeInterval,
    _ action: @escaping @MainActor () -> Void
) -> @MainActor () -> Void

enum MainQueueTimer {
    @MainActor
    static func schedule(
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }
}
```

> 컴파일러가 `DispatchWorkItem` 블록에서 `action` 캡처를 Sendable 문제로 거부하면, `action` 파라미터 타입을 `@escaping @MainActor @Sendable () -> Void` 로 바꾸고 `ScheduleAfter` 의 같은 자리도 맞춘다.

새 파일 `apps/termy/Sources/StartupInputScheduler.swift`:

```swift
// StartupInputScheduler.swift
//
// Decides when a restored pane types its agent-resume command into the
// fresh shell: once output has been quiet for `quietInterval` after any
// bytes (the prompt has most likely drawn), or at `deadline` after start
// no matter what. Early input would still work — the PTY buffers it until
// the shell reads — waiting only keeps the command from echoing above the
// prompt.

import Foundation

@MainActor
final class StartupInputScheduler {
    static let quietInterval: TimeInterval = 0.3
    static let deadline: TimeInterval = 3.0

    private let schedule: ScheduleAfter
    private let fire: @MainActor () -> Void
    private var cancelQuiet: (@MainActor () -> Void)?
    private var cancelDeadline: (@MainActor () -> Void)?
    private(set) var hasFired = false

    init(schedule: @escaping ScheduleAfter, fire: @escaping @MainActor () -> Void) {
        self.schedule = schedule
        self.fire = fire
    }

    /// Call right after the shell process starts.
    func start() {
        cancelDeadline = schedule(Self.deadline) { [weak self] in self?.fireOnce() }
    }

    /// Call for every chunk of PTY output.
    func outputReceived() {
        guard !hasFired else { return }
        cancelQuiet?()
        cancelQuiet = schedule(Self.quietInterval) { [weak self] in self?.fireOnce() }
    }

    private func fireOnce() {
        guard !hasFired else { return }
        hasFired = true
        cancelQuiet?()
        cancelDeadline?()
        cancelQuiet = nil
        cancelDeadline = nil
        fire()
    }
}
```

- [ ] **Step 4: 스케줄러 테스트 통과 확인**

Run: Step 2 와 같은 명령.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: 터미널 출력 callback**

`apps/termy/Sources/TermyTerminalView.swift` 에서 `dataReceived(slice:)` 바로 위에 프로퍼티를 추가:

```swift
    /// Called after every chunk of PTY output has been rendered. `Pane`
    /// uses it to time a restored pane's agent-resume command.
    var onOutput: (@MainActor () -> Void)?
```

`dataReceived(slice:)` 에서 `super.dataReceived(slice: slice)` 바로 다음 줄에 추가:

```swift
        onOutput?()
```

- [ ] **Step 6: `Pane` 에 startup input**

`apps/termy/Sources/Pane.swift` 에서 `nonisolated(unsafe) private var fontPreferenceObserver` 선언 뒤에 추가:

```swift
    /// Pending agent-resume command for a pane restored after an update
    /// relaunch. nil once typed (or when there is none).
    private var startupInputScheduler: StartupInputScheduler?
```

`init(projectId:cwd:)` 시그니처를 다음으로 바꾼다:

```swift
    init(
        projectId: String,
        cwd: String? = nil,
        startupInput: String? = nil
    ) {
```

`init` 의 마지막 줄 `startShell()` 다음에 추가:

```swift
        if let startupInput {
            scheduleStartupInput(startupInput)
        }
```

`startShell()` 뒤(Task 4 에서 추가한 `agentResumeRecord(snapshot:)` 앞)에 추가:

```swift
    /// Type `input` into the fresh shell once it looks ready (see
    /// `StartupInputScheduler`). Used to resume an agent after an update
    /// relaunch.
    private func scheduleStartupInput(_ input: String) {
        let scheduler = StartupInputScheduler(schedule: MainQueueTimer.schedule) { [weak self] in
            guard let self else { return }
            self.terminal.onOutput = nil
            self.startupInputScheduler = nil
            self.terminal.send(txt: input + "\r")
        }
        startupInputScheduler = scheduler
        terminal.onOutput = { [weak scheduler] in scheduler?.outputReceived() }
        scheduler.start()
    }
```

- [ ] **Step 7: 복원 경로 연결**

`apps/termy/Sources/Workspace.swift` 의 `addPane` 시그니처와 `Pane(` 생성을 다음으로 바꾼다:

```swift
    @discardableResult
    func addPane(
        cwd: String? = nil,
        splitAxis: SplitAxis = .balanced,
        startupInput: String? = nil
    ) -> Pane {
```

```swift
        let pane = Pane(
            projectId: projectId,
            cwd: cwd ?? focusedPane?.currentCwd,
            startupInput: startupInput
        )
```

`apps/termy/Sources/MainWindowController.swift` 의 `applySessionLayout(_:)` 에서 안쪽 루프를 다음으로 바꾼다:

```swift
        for savedRow in record.rows {
            for (colIdx, paneRec) in savedRow.enumerated() {
                let axis: SplitAxis = (colIdx == 0) ? .row : .column
                // An update relaunch saved this pane's live agent session —
                // reopen the conversation where the agent was running.
                let resume = paneRec.agentResume
                workspace.addPane(
                    cwd: resume?.cwd ?? paneRec.cwd,
                    splitAxis: axis,
                    startupInput: resume.map(AgentResumeCommand.make)
                )
            }
        }
```

`apps/termy/Sources/WindowManager.swift` 의 `restoreSessionWindows()` 에서 `for windowRecord in record.windows { ... }` 뒤, `return true` 앞에 추가:

```swift
        // Rewrite session.json now. Restored windows replay their panes
        // before `windowManager` is wired, so no save has fired yet — and an
        // update relaunch's agent-resume records must not resume again on a
        // later launch.
        sessionAutosaver?.requestSave()
```

- [ ] **Step 8: 빌드와 회귀 확인**

Run: `-only-testing:termy-tests/StartupInputSchedulerTests -only-testing:termy-tests/WindowManagerTests -only-testing:termy-tests/TermyTerminalViewTests -only-testing:termy-tests/PaneGridOrderTests`.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: 커밋**

```bash
git add apps/termy/Sources/MainQueueTimer.swift apps/termy/Sources/StartupInputScheduler.swift \
  apps/termy/Sources/TermyTerminalView.swift apps/termy/Sources/Pane.swift apps/termy/Sources/Workspace.swift \
  apps/termy/Sources/MainWindowController.swift apps/termy/Sources/WindowManager.swift \
  apps/termy-tests/Sources/ManualScheduler.swift apps/termy-tests/Sources/StartupInputSchedulerTests.swift
git commit -m "feat(update): 복원된 pane에서 셸이 준비되면 agent resume 명령을 입력"
```

---

## Task 6: 작업 중이면 업데이트 재시작 미루기

**Files:**
- Create: `apps/termy/Sources/UpdateRelaunchGate.swift`
- Create: `apps/termy-tests/Sources/UpdateRelaunchGateTests.swift`
- Modify: `apps/termy/Sources/Updater.swift` (전체)
- Modify: `apps/termy/Sources/AppDelegate.swift` (`applicationDidFinishLaunching` 70-73행, `installMenuBar` 305-315행, `makeAppMenu` 317-333행, DEBUG 메뉴 추가)

**Interfaces:**
- Consumes: Task 3 `MissionControlModel.shared.midTurnPaneCount`, `onSnapshotUpdate`, `onLivePanesChanged`; Task 4 `WindowManager.prepareForUpdateRelaunch()`; Task 5 `ScheduleAfter`, `MainQueueTimer.schedule`, 테스트용 `ManualScheduler`, `Counter`
- Produces:
  - `enum UpdateRelaunchChoice { case waitForAgents, restartNow }`
  - `final class UpdateRelaunchGate` — `init(midTurnCount:schedule:presentPrompt:)`, `begin(installHandler:) -> Bool`, `reevaluate()`, `restartNow()`, `isPending`, `onPendingChanged`, `static settleDelay = 2`, `static promptTitle(busyCount:) -> String`, `static presentAlert(busyCount:completion:)`
  - `Updater.gate`, `Updater.onWillRelaunch`, `Updater.restartNowToInstallUpdate(_:)`

- [ ] **Step 1: 실패하는 테스트 작성**

새 파일 `apps/termy-tests/Sources/UpdateRelaunchGateTests.swift`:

```swift
import XCTest
@testable import termy

@MainActor
private final class Harness {
    var busy = 0
    let clock = ManualScheduler()
    var promptCounts: [Int] = []
    var answer: (@MainActor (UpdateRelaunchChoice) -> Void)?
    let installs = Counter()
    let pendingChanges = Counter()
    private(set) lazy var gate: UpdateRelaunchGate = {
        let gate = UpdateRelaunchGate(
            midTurnCount: { [unowned self] in self.busy },
            schedule: clock.schedule,
            presentPrompt: { [unowned self] count, completion in
                self.promptCounts.append(count)
                self.answer = completion
            }
        )
        gate.onPendingChanged = { [pendingChanges] in pendingChanges.value += 1 }
        return gate
    }()

    @discardableResult
    func begin() -> Bool {
        gate.begin { [installs] in installs.value += 1 }
    }
}

@MainActor
final class UpdateRelaunchGateTests: XCTestCase {
    func test_noBusyAgents_relaunchesWithoutPrompt() {
        let h = Harness()
        XCTAssertFalse(h.begin())
        XCTAssertEqual(h.promptCounts, [])
        XCTAssertFalse(h.gate.isPending)
    }

    func test_busyAgents_promptWithCountAndPostpone() {
        let h = Harness()
        h.busy = 2
        XCTAssertTrue(h.begin())
        XCTAssertEqual(h.promptCounts, [2])
        XCTAssertTrue(h.gate.isPending)
        XCTAssertEqual(h.installs.value, 0)
    }

    func test_restartNowChoice_installsImmediately() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.restartNow)
        XCTAssertEqual(h.installs.value, 1)
        XCTAssertFalse(h.gate.isPending)
    }

    func test_wait_releasesAfterSettleDelayOnceIdle() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.waitForAgents)
        h.busy = 0
        h.gate.reevaluate()
        h.clock.advance(by: UpdateRelaunchGate.settleDelay - 0.01)
        XCTAssertEqual(h.installs.value, 0)
        h.clock.advance(by: 0.02)
        XCTAssertEqual(h.installs.value, 1)
    }

    func test_wait_newTurnDuringSettle_keepsWaiting() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.waitForAgents)
        h.busy = 0
        h.gate.reevaluate()
        h.clock.advance(by: 1)
        h.busy = 1
        h.gate.reevaluate()
        h.clock.advance(by: 5)
        XCTAssertEqual(h.installs.value, 0)
        h.busy = 0
        h.gate.reevaluate()
        h.clock.advance(by: UpdateRelaunchGate.settleDelay)
        XCTAssertEqual(h.installs.value, 1)
    }

    func test_wait_settleRecheckSeesNewTurnWithoutReevaluate() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.waitForAgents)
        h.busy = 0
        h.gate.reevaluate()
        h.busy = 1                       // no reevaluate call in between
        h.clock.advance(by: UpdateRelaunchGate.settleDelay)
        XCTAssertEqual(h.installs.value, 0)
        XCTAssertTrue(h.gate.isPending)
    }

    func test_noAutoReleaseWhilePromptIsShowing() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.busy = 0
        h.gate.reevaluate()
        h.clock.advance(by: 10)
        XCTAssertEqual(h.installs.value, 0)
        h.answer?(.waitForAgents)        // already idle → settle starts now
        h.clock.advance(by: UpdateRelaunchGate.settleDelay)
        XCTAssertEqual(h.installs.value, 1)
    }

    func test_menuRestartNow_whileWaiting_installs() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.waitForAgents)
        h.gate.restartNow()
        XCTAssertEqual(h.installs.value, 1)
    }

    func test_handlerRunsOnlyOnce() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.waitForAgents)
        h.gate.restartNow()
        h.gate.restartNow()
        h.busy = 0
        h.gate.reevaluate()
        h.clock.advance(by: 10)
        h.answer?(.restartNow)           // late alert answer
        XCTAssertEqual(h.installs.value, 1)
    }

    func test_onPendingChanged_firesOnEnterAndExitOnly() {
        let h = Harness()
        h.busy = 1
        h.begin()                        // idle → prompting
        h.answer?(.waitForAgents)        // prompting → waiting (still pending)
        h.gate.restartNow()              // waiting → released
        XCTAssertEqual(h.pendingChanges.value, 2)
    }

    func test_promptTitle_singularAndPlural() {
        XCTAssertEqual(UpdateRelaunchGate.promptTitle(busyCount: 1), "1 agent is still working")
        XCTAssertEqual(UpdateRelaunchGate.promptTitle(busyCount: 3), "3 agents are still working")
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `xcodegen generate` 후 `-only-testing:termy-tests/UpdateRelaunchGateTests`.
Expected: 컴파일 실패 — `cannot find 'UpdateRelaunchGate' in scope`.

- [ ] **Step 3: `UpdateRelaunchGate` 작성**

새 파일 `apps/termy/Sources/UpdateRelaunchGate.swift`:

```swift
// UpdateRelaunchGate.swift
//
// Holds a Sparkle update relaunch while any agent is mid-turn
// (`PaneSnapshot.isMidTurn`). Restarting mid-turn kills work that
// `claude --resume` / `codex resume` can't bring back; between turns the
// resumed conversation loses nothing.
//
// Flow: Sparkle asks to relaunch → `begin` → agents busy? ask the user
// (Wait for Agents / Restart Now) → while waiting, re-count on every
// snapshot or live-pane change → zero, and still zero `settleDelay` later
// → run Sparkle's install handler exactly once.

import AppKit

enum UpdateRelaunchChoice {
    case waitForAgents
    case restartNow
}

@MainActor
final class UpdateRelaunchGate {
    /// Re-check this long after the count first reaches zero, so a queued
    /// message that starts the next turn right after Stop isn't cut off.
    static let settleDelay: TimeInterval = 2

    typealias PresentPrompt = @MainActor (
        _ busyCount: Int,
        _ completion: @escaping @MainActor (UpdateRelaunchChoice) -> Void
    ) -> Void

    private enum Phase {
        case idle
        case prompting
        case waiting
        case released
    }

    private let midTurnCount: @MainActor () -> Int
    private let schedule: ScheduleAfter
    private let presentPrompt: PresentPrompt
    private var phase: Phase = .idle
    private var installHandler: (@MainActor () -> Void)?
    private var cancelSettle: (@MainActor () -> Void)?

    /// Fires when `isPending` flips, so the app menu can show or hide
    /// "Restart Now to Install Update".
    var onPendingChanged: (@MainActor () -> Void)?

    /// True while a relaunch is held: the prompt is up or we're waiting.
    var isPending: Bool { phase == .prompting || phase == .waiting }

    init(
        midTurnCount: @escaping @MainActor () -> Int,
        schedule: @escaping ScheduleAfter,
        presentPrompt: @escaping PresentPrompt
    ) {
        self.midTurnCount = midTurnCount
        self.schedule = schedule
        self.presentPrompt = presentPrompt
    }

    /// Sparkle's `shouldPostponeRelaunchForUpdate`. Returns false (relaunch
    /// now) when no agent is mid-turn; otherwise keeps `installHandler`,
    /// asks the user, and returns true.
    func begin(installHandler: @escaping @MainActor () -> Void) -> Bool {
        if isPending {
            self.installHandler = installHandler
            return true
        }
        let busy = midTurnCount()
        guard busy > 0 else { return false }
        self.installHandler = installHandler
        setPhase(.prompting)
        presentPrompt(busy) { [weak self] choice in
            self?.handle(choice)
        }
        return true
    }

    /// Call whenever pane snapshots or the set of live panes change. No
    /// effect unless the user chose to wait.
    func reevaluate() {
        guard phase == .waiting else { return }
        if midTurnCount() == 0 {
            guard cancelSettle == nil else { return }
            cancelSettle = schedule(Self.settleDelay) { [weak self] in self?.settleElapsed() }
        } else {
            cancelSettle?()
            cancelSettle = nil
        }
    }

    /// "Restart Now to Install Update" in the app menu.
    func restartNow() {
        guard isPending else { return }
        release()
    }

    static func promptTitle(busyCount: Int) -> String {
        busyCount == 1 ? "1 agent is still working" : "\(busyCount) agents are still working"
    }

    /// The production prompt: an NSAlert on the next run-loop turn, so
    /// Sparkle's delegate callback returns before the modal starts.
    static func presentAlert(
        busyCount: Int,
        completion: @escaping @MainActor (UpdateRelaunchChoice) -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = promptTitle(busyCount: busyCount)
                alert.informativeText = "termy will restart to install the update when they finish their current turn. Other programs running in panes will still be stopped."
                alert.addButton(withTitle: "Wait for Agents")
                alert.addButton(withTitle: "Restart Now")
                let response = alert.runModal()
                completion(response == .alertFirstButtonReturn ? .waitForAgents : .restartNow)
            }
        }
    }

    private func handle(_ choice: UpdateRelaunchChoice) {
        guard phase == .prompting else { return }
        switch choice {
        case .restartNow:
            release()
        case .waitForAgents:
            setPhase(.waiting)
            reevaluate()
        }
    }

    private func settleElapsed() {
        cancelSettle = nil
        guard phase == .waiting else { return }
        if midTurnCount() == 0 {
            release()
        }
    }

    private func release() {
        cancelSettle?()
        cancelSettle = nil
        let handler = installHandler
        installHandler = nil
        setPhase(.released)
        handler?()
    }

    private func setPhase(_ next: Phase) {
        let wasPending = isPending
        phase = next
        if wasPending != isPending {
            onPendingChanged?()
        }
    }
}
```

- [ ] **Step 4: gate 테스트 통과 확인**

Run: Step 2 와 같은 명령.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: `Updater` 에 delegate 연결**

`apps/termy/Sources/Updater.swift` 전체를 다음으로 바꾼다:

```swift
// Updater.swift
//
// Wrapper around Sparkle's SPUStandardUpdaterController. Instantiated once
// on first access (the app menu); takes over the "Check for Updates…" menu
// item target. Sparkle's defaults cover prompt UX, signature verification,
// and error dialogs. The delegate adds two things so updates don't cost
// agent sessions (docs/superpowers/specs/2026-10-10-agent-resume-after-update-design.md):
//   * hold the relaunch while an agent is mid-turn (`UpdateRelaunchGate`)
//   * right before relaunching, save each pane's agent session so the new
//     version resumes it (`onWillRelaunch` → `WindowManager`)

import AppKit
import Sparkle

@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController!

    let gate: UpdateRelaunchGate

    /// Set by AppDelegate: the final session save before Sparkle relaunches.
    var onWillRelaunch: (() -> Void)?

    override private init() {
        gate = UpdateRelaunchGate(
            midTurnCount: { MissionControlModel.shared.midTurnPaneCount },
            schedule: MainQueueTimer.schedule,
            presentPrompt: UpdateRelaunchGate.presentAlert(busyCount:completion:)
        )
        super.init()
        // `self` is the delegate, so the controller is created after
        // super.init. Sparkle holds the delegate weakly; `shared` keeps it.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    @objc func restartNowToInstallUpdate(_ sender: Any?) {
        gate.restartNow()
    }
}

extension Updater: SPUUpdaterDelegate {
    // Sparkle calls its delegate on the main thread.

    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        nonisolated(unsafe) let handler = installHandler
        return MainActor.assumeIsolated {
            gate.begin { handler() }
        }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            onWillRelaunch?()
        }
    }
}
```

> 로컬 `nonisolated(unsafe) let` 이 거부되면 같은 파일에 `private struct UncheckedHandler: @unchecked Sendable { let run: () -> Void }` 를 두고 `let handler = UncheckedHandler(run: installHandler)` / `gate.begin { handler.run() }` 로 바꾼다. 목적은 같다: Sparkle 이 main thread 에서 부르는 non-Sendable 블록을 MainActor 상태에 저장하는 것.

- [ ] **Step 6: `AppDelegate` 연결과 메뉴**

`applicationDidFinishLaunching` 의 기존 블록

```swift
        MissionControlModel.shared.onSnapshotUpdate = { snapshot in
            Notifier.shared.handle(snapshot)
        }
```

을 다음으로 바꾼다:

```swift
        MissionControlModel.shared.onSnapshotUpdate = { snapshot in
            Notifier.shared.handle(snapshot)
            Updater.shared.gate.reevaluate()
        }
        MissionControlModel.shared.onLivePanesChanged = {
            Updater.shared.gate.reevaluate()
        }
        Updater.shared.onWillRelaunch = { [weak self] in
            self?.windowManager.prepareForUpdateRelaunch()
        }
```

(이 블록은 `guard !TestHostDetector.isRunningUnderXCTest()` 뒤에 있으므로 테스트 host 에서는 연결되지 않는다. 그대로 둔다.)

`makeAppMenu()` 에서 `update.target = Updater.shared` 다음 줄에 추가:

```swift
        let restartToUpdate = menu.addItem(
            withTitle: "Restart Now to Install Update",
            action: #selector(Updater.restartNowToInstallUpdate(_:)),
            keyEquivalent: ""
        )
        restartToUpdate.target = Updater.shared
        restartToUpdate.isHidden = true
        Updater.shared.gate.onPendingChanged = { [weak restartToUpdate] in
            restartToUpdate?.isHidden = !Updater.shared.gate.isPending
        }
```

`installMenuBar()` 에서 `mainMenu.addItem(makeWindowMenu())` 와 `mainMenu.addItem(makeHelpMenu())` 사이에 추가:

```swift
        #if DEBUG
        mainMenu.addItem(makeDebugMenu())
        #endif
```

`makeAppMenu()` 함수 뒤에 추가:

```swift
    #if DEBUG
    private func makeDebugMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Debug")
        let simulate = menu.addItem(
            withTitle: "Simulate Update Relaunch",
            action: #selector(AppDelegate.simulateUpdateRelaunch(_:)),
            keyEquivalent: ""
        )
        simulate.target = self
        item.submenu = menu
        return item
    }

    /// The update-relaunch path without Sparkle: hold for mid-turn agents,
    /// save each pane's agent session, quit. Relaunch by hand to check
    /// that the panes resume.
    @objc private func simulateUpdateRelaunch(_ sender: Any?) {
        let finish: @MainActor () -> Void = { [weak self] in
            self?.windowManager.prepareForUpdateRelaunch()
            NSApp.terminate(nil)
        }
        if !Updater.shared.gate.begin(installHandler: finish) {
            finish()
        }
    }
    #endif
```

- [ ] **Step 7: 전체 테스트와 Debug 빌드 확인**

Run: 전체 테스트(`-only-testing` 없이).
Expected: `** TEST SUCCEEDED **`.

Run: `xcodebuild build -project termy.xcodeproj -scheme termy -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData-debug -skipPackagePluginValidation 2>&1 | grep -E "warning: .*(Updater|UpdateRelaunchGate|MainQueueTimer|StartupInputScheduler|AgentResume|SessionPersistence)|error:|BUILD" | tail -20`
Expected: `** BUILD SUCCEEDED **`, 새 파일에서 나온 concurrency 경고 없음. **빌드한 앱을 실행하지 않는다.**

- [ ] **Step 8: 커밋**

```bash
git add apps/termy/Sources/UpdateRelaunchGate.swift apps/termy/Sources/Updater.swift apps/termy/Sources/AppDelegate.swift \
  apps/termy-tests/Sources/UpdateRelaunchGateTests.swift
git commit -m "feat(update): agent가 turn 도중이면 업데이트 재시작을 미루고 재시작 직전에 세션을 저장"
```

---

## Task 7: CHANGELOG 와 사람 검증 준비

**Files:**
- Modify: `CHANGELOG.md` (`## Unreleased` 아래)

**Interfaces:**
- Consumes: Task 1–6 결과
- Produces: 릴리스 노트 항목(`scripts/render-release-notes.py` 가 버전 섹션을 appcast 로 옮긴다)

- [ ] **Step 1: CHANGELOG 항목 추가**

`CHANGELOG.md` 의 `## Unreleased` 바로 아래에 빈 줄 하나 뒤 추가:

```markdown
- Updating termy no longer ends your Claude Code and Codex sessions. When
  you choose Install and Relaunch while an agent is in the middle of a turn,
  termy asks whether to wait and restarts once every agent has finished.
  After the restart, each pane that was running an agent reopens the same
  conversation with `claude --resume` or `codex resume`, keeping flags such
  as `--model` and `--dangerously-skip-permissions`. The version doing the
  restart must have this feature, so it takes effect from the update after
  this one.
```

- [ ] **Step 2: 전체 테스트 재확인**

Run: 전체 테스트.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: 커밋**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): 업데이트 후 agent 세션 이어가기 항목을 추가"
```

- [ ] **Step 4: 사람 검증 안내 (에이전트는 실행하지 않는다)**

아래는 사용자가 직접 한다(spec §10). 에이전트는 이 목록을 최종 보고에 그대로 옮긴다.

1. 실행 중인 termy 를 모두 종료한 상태에서 Debug 빌드(`build/DerivedData-debug/Build/Products/Debug/termy.app`)만 띄운다.
2. pane 셋: (a) `claude --model sonnet` 에 오래 걸리는 작업을 시켜 둔 pane, (b) `claude --permission-mode plan` 으로 한 턴을 끝낸 pane, (c) 빈 셸.
3. Debug ▸ Simulate Update Relaunch → "1 agent is still working" alert → Wait for Agents → 앱 메뉴에 "Restart Now to Install Update" 가 보이는지 → (a) 의 turn 이 끝나고 약 2초 뒤 termy 가 종료되는지.
4. 같은 Debug 빌드를 다시 실행 → (a)(b) 에서 같은 대화가 열리는지, `ps -o args= -p <pid>` 로 `--model sonnet` / `--permission-mode plan` 이 붙었는지, (c) 는 빈 셸인지.
5. 한 번 더 종료·실행해서 resume 이 반복되지 않는지(복원 후 저장으로 resume 기록이 지워짐).
6. 이 기능이 들어간 버전 다음 릴리스를 설치할 때 Sparkle 경로 전체와 postpone 중 Sparkle 기본 UI 를 확인한다.

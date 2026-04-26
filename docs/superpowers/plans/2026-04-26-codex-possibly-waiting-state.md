# Codex `POSSIBLY_WAITING` State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the noisy 8s-silence Codex fake-WAIT with a two-stage WAIT — a silent `POSSIBLY_WAITING` interim state that promotes to a real `WAITING` only after additional silence with no PTY activity. Real WAIT keeps c80d2c4's hook-based recovery as a final safety net.

**Architecture:**
- **Layer 1 (interim):** `CodexForegroundReconciler` enters `POSSIBLY_WAITING` (silent, displays as THINK) instead of `WAITING`. Pre/PostToolUse hooks revert it to THINK; PTY byte arrival also reverts it to THINK (proof of life).
- **Layer 2 (promotion):** `HookDaemon`'s 5s tick promotes `POSSIBLY_WAITING` → `WAITING(.promotedFromPossible)` after `codexPromotionThreshold` (12s) with no recovery. Promotion fires sound + dock badge.
- **Layer 3 (recovery, preserved):** Real `WAITING(.promotedFromPossible)` still recovers to THINK on the next Pre/PostToolUse — c80d2c4's logic, re-keyed on `waitSource` instead of `notificationReason == nil`.
- New `WaitSource` enum makes `WAITING` entry causes explicitly typed (`.permission` / `.askUserQuestion` / `.turnEnd` / `.promotedFromPossible`).
- PTY activity is published via `TermyTerminalView.dataReceived` override → `HookDaemon.recordPtyActivity(paneId:)`.

**Tech Stack:** Swift 5.10, AppKit + SwiftUI, SwiftTerm (`LocalProcessTerminalView` subclass), XCTest. Codex CLI 0.125.0.

---

## File Structure

| File | Responsibility | Status |
|---|---|---|
| `apps/termy/Sources/PaneState.swift` | `PaneState` enum + `WaitSource` + `PaneSnapshot` fields + transition function | Modify |
| `apps/termy/Sources/HookDaemon.swift` | `recordPtyActivity`, promotion tick, threshold constants | Modify |
| `apps/termy/Sources/TermyTerminalView.swift` | Override `dataReceived(slice:)` to ping daemon | Modify |
| `apps/termy/Sources/Pane.swift` | Wire `paneId` into terminal subclass for ping | Modify |
| `apps/termy/Sources/MissionControlView.swift` | Render `.possiblyWaiting` as THINK chip | Modify |
| `apps/termy/Sources/Notifier.swift` | Honour `waitSource` for body text (fallback to `notificationReason`) | Modify |
| `apps/termy-tests/Sources/PaneStateMachineTests.swift` | Transition tests for new states/sources | Modify |
| `apps/termy-tests/Sources/AgentKindTests.swift` | Codex-specific tests for the two-stage WAIT | Modify |
| `apps/termy-tests/Sources/CodexForegroundReconcilerTests.swift` | Reconciler now produces possibly-state | Modify |
| `apps/termy-tests/Sources/HookDaemonPossiblyWaitingTests.swift` | Promotion timer + PTY revert | Create |
| `CHANGELOG.md` | One-line entry under "Unreleased" | Modify |
| `TODOS.md` | Move "Codex follow-ups" item to done; add v1.1 polish notes | Modify |

---

## Parameters

| Constant | Value | Where |
|---|---|---|
| `codexThinkingSilenceThreshold` | `8` (existing) | `HookDaemon.swift:99` — THINK → POSSIBLY entry |
| `codexPromotionThreshold` | `12` (NEW) | `HookDaemon.swift` — POSSIBLY → WAIT promotion |

Total silence before sound: 8 + 12 = ~20s. Tune via these two constants only.

---

## Task 1: Extend `PaneState` model with `WaitSource` and `possiblyWaiting`

**Files:**
- Modify: `apps/termy/Sources/PaneState.swift`
- Modify: `apps/termy-tests/Sources/PaneStateMachineTests.swift`

- [ ] **Step 1: Write the failing model tests**

Append to `apps/termy-tests/Sources/PaneStateMachineTests.swift` (inside `final class PaneStateMachineTests`):

```swift
// MARK: - Model: WaitSource + possiblyWaiting

func test_possiblyWaitingState_rawValue() {
    XCTAssertEqual(PaneState.possiblyWaiting.rawValue, "POSSIBLY_WAITING")
}

func test_waitSource_rawValues_areKebabStable() {
    XCTAssertEqual(WaitSource.permission.rawValue, "permission")
    XCTAssertEqual(WaitSource.askUserQuestion.rawValue, "ask_user_question")
    XCTAssertEqual(WaitSource.turnEnd.rawValue, "turn_end")
    XCTAssertEqual(WaitSource.promotedFromPossible.rawValue, "promoted_from_possible")
}

func test_emptySnapshot_hasNilWaitSourceAndNilLastPtyActivityAt() {
    let s = PaneSnapshot.empty(paneId: "p1", projectId: nil)
    XCTAssertNil(s.waitSource)
    XCTAssertNil(s.lastPtyActivityAt)
}

func test_paneSnapshot_codableRoundTrip_preservesNewFields() throws {
    var s = PaneSnapshot.empty(paneId: "p1", projectId: "proj")
    s.state = .waiting
    s.waitSource = .promotedFromPossible
    s.lastPtyActivityAt = Date(timeIntervalSince1970: 42)
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: data)
    XCTAssertEqual(decoded.state, .waiting)
    XCTAssertEqual(decoded.waitSource, .promotedFromPossible)
    XCTAssertEqual(decoded.lastPtyActivityAt, Date(timeIntervalSince1970: 42))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/PaneStateMachineTests 2>&1 | tail -30`
Expected: FAIL with `Cannot find 'WaitSource'` and `Type 'PaneState' has no member 'possiblyWaiting'`.

- [ ] **Step 3: Add the new state and enum**

In `apps/termy/Sources/PaneState.swift`, replace the existing `enum PaneState` (lines 35-41) with:

```swift
enum PaneState: String, Sendable, Codable {
    case initializing    = "INIT"
    case thinking        = "THINKING"
    case possiblyWaiting = "POSSIBLY_WAITING"
    case waiting         = "WAITING"
    case idle            = "IDLE"
    case errored         = "ERRORED"
}

/// Why a pane is in `.waiting`. Codex paths set this; Claude paths leave nil
/// and rely on `notificationReason` for the legacy reason strings.
enum WaitSource: String, Sendable, Codable {
    /// Codex emitted PermissionRequest — user must approve a tool call.
    case permission           = "permission"
    /// Codex called AskUserQuestion — user must pick an option.
    case askUserQuestion      = "ask_user_question"
    /// Codex's Stop hook fired — turn naturally ended.
    case turnEnd              = "turn_end"
    /// Reconciler-induced POSSIBLY_WAITING aged out without recovery —
    /// promoted to real WAITING by the daemon's tick. Eligible for
    /// hook-based recovery on next Pre/PostToolUse.
    case promotedFromPossible = "promoted_from_possible"
}
```

- [ ] **Step 4: Add new fields to `PaneSnapshot`**

In `apps/termy/Sources/PaneState.swift`, replace the `PaneSnapshot` struct fields (lines 44-67) with:

```swift
struct PaneSnapshot: Sendable, Codable {
    let paneId: String
    let projectId: String?
    var state: PaneState
    var needsAttention: Bool
    var notificationReason: String?     // Claude legacy: "permission" | "idle" | "mcp_elicit" or nil
    /// Codex-only typed reason for `.waiting`. nil for Claude and for non-waiting states.
    var waitSource: WaitSource?
    var lastSessionId: String?
    var lastCwd: String?
    var lastPrompt: String?
    var lastAssistantMessage: String?
    var updatedAt: Date
    var enteredStateAt: Date
    var agentKind: AgentKind = .claude
    /// Last time PTY produced output for this pane. Updated by
    /// TermyTerminalView.dataReceived → HookDaemon.recordPtyActivity.
    /// Used as a liveness signal during POSSIBLY_WAITING.
    var lastPtyActivityAt: Date?

    private enum CodingKeys: String, CodingKey {
        case paneId, projectId, state, needsAttention, notificationReason, waitSource
        case lastSessionId, lastCwd, lastPrompt, lastAssistantMessage
        case updatedAt, enteredStateAt, agentKind, lastPtyActivityAt
    }
}
```

And update `PaneSnapshot.empty` (line 70-92) to initialize the new fields:

```swift
extension PaneSnapshot {
    static func empty(
        paneId: String,
        projectId: String?,
        agentKind: AgentKind = .claude
    ) -> PaneSnapshot {
        let now = Date()
        return PaneSnapshot(
            paneId: paneId,
            projectId: projectId,
            state: .initializing,
            needsAttention: false,
            notificationReason: nil,
            waitSource: nil,
            lastSessionId: nil,
            lastCwd: nil,
            lastPrompt: nil,
            lastAssistantMessage: nil,
            updatedAt: now,
            enteredStateAt: now,
            agentKind: agentKind,
            lastPtyActivityAt: nil
        )
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/PaneStateMachineTests/test_possiblyWaitingState_rawValue -only-testing:termy-tests/PaneStateMachineTests/test_waitSource_rawValues_areKebabStable -only-testing:termy-tests/PaneStateMachineTests/test_emptySnapshot_hasNilWaitSourceAndNilLastPtyActivityAt -only-testing:termy-tests/PaneStateMachineTests/test_paneSnapshot_codableRoundTrip_preservesNewFields 2>&1 | tail -20`
Expected: 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/termy/Sources/PaneState.swift apps/termy-tests/Sources/PaneStateMachineTests.swift
git commit -m "feat(codex): add WaitSource enum and possiblyWaiting PaneState"
```

---

## Task 2: Wire `WaitSource` on existing real-WAIT entry events

**Files:**
- Modify: `apps/termy/Sources/PaneState.swift:160-170` (Stop)
- Modify: `apps/termy/Sources/PaneState.swift:217-226` (PermissionRequest)
- Modify: `apps/termy/Sources/PaneState.swift:235-239` (PreToolUse AskUserQuestion)
- Modify: `apps/termy-tests/Sources/PaneStateMachineTests.swift`

- [ ] **Step 1: Write failing tests for waitSource on entry**

Append to `PaneStateMachineTests`:

```swift
// MARK: - WaitSource on real-WAIT entry

func test_codexStop_setsWaitSourceTurnEnd() {
    var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
    s.state = .thinking
    let event = HookEvent(
        event: .stop, paneId: "p1", projectId: nil, ts: 1.0,
        agent: "codex",
        meta: { var m = HookEvent.Meta(); m.lastAssistantMessage = "ok"; return m }()
    )
    let after = PaneStateMachine.apply(event, to: s)
    XCTAssertEqual(after.state, .waiting)
    XCTAssertEqual(after.waitSource, .turnEnd)
    XCTAssertEqual(after.lastAssistantMessage, "ok")
}

func test_codexPermissionRequest_setsWaitSourcePermission() {
    var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
    s.state = .thinking
    let event = HookEvent(
        event: .permissionRequest, paneId: "p1", projectId: nil, ts: 1.0,
        agent: "codex",
        meta: { var m = HookEvent.Meta(); m.toolName = "Bash"; return m }()
    )
    let after = PaneStateMachine.apply(event, to: s)
    XCTAssertEqual(after.state, .waiting)
    XCTAssertEqual(after.waitSource, .permission)
    XCTAssertTrue(after.needsAttention)
}

func test_codexPreToolUseAskUserQuestion_setsWaitSourceAskUserQuestion() {
    var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
    s.state = .thinking
    let event = HookEvent(
        event: .preToolUse, paneId: "p1", projectId: nil, ts: 1.0,
        agent: "codex",
        meta: { var m = HookEvent.Meta(); m.toolName = "AskUserQuestion"; return m }()
    )
    let after = PaneStateMachine.apply(event, to: s)
    XCTAssertEqual(after.state, .waiting)
    XCTAssertEqual(after.waitSource, .askUserQuestion)
    XCTAssertTrue(after.needsAttention)
}
```

- [ ] **Step 2: Verify tests fail**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/PaneStateMachineTests/test_codexStop_setsWaitSourceTurnEnd -only-testing:termy-tests/PaneStateMachineTests/test_codexPermissionRequest_setsWaitSourcePermission -only-testing:termy-tests/PaneStateMachineTests/test_codexPreToolUseAskUserQuestion_setsWaitSourceAskUserQuestion 2>&1 | tail -20`
Expected: FAIL — `waitSource` is nil because nothing sets it.

- [ ] **Step 3: Set `waitSource` on entry**

In `apps/termy/Sources/PaneState.swift`, replace the `case .stop:` block (lines 160-170) with:

```swift
case .stop:
    next.lastAssistantMessage = event.meta.lastAssistantMessage
    next.state = .waiting
    next.waitSource = .turnEnd
    next.enteredStateAt = next.updatedAt
```

Replace the `case .permissionRequest:` block (lines 217-226) with:

```swift
case .permissionRequest:
    next.state = .waiting
    next.needsAttention = true
    next.notificationReason = "permission"
    next.waitSource = .permission
    next.enteredStateAt = next.updatedAt
```

Replace the AskUserQuestion branch inside `case .preToolUse:` (lines 235-239) with:

```swift
if event.meta.toolName == "AskUserQuestion" {
    next.state = .waiting
    next.needsAttention = true
    next.notificationReason = "ask_user_question"
    next.waitSource = .askUserQuestion
    next.enteredStateAt = next.updatedAt
}
```

- [ ] **Step 4: Verify new tests pass and existing tests still pass**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/PaneStateMachineTests 2>&1 | tail -30`
Expected: All PaneStateMachineTests PASS (existing tests are agnostic to the new field).

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/AgentKindTests 2>&1 | tail -30`
Expected: All AgentKindTests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/PaneState.swift apps/termy-tests/Sources/PaneStateMachineTests.swift
git commit -m "feat(codex): tag real-WAIT entries with WaitSource"
```

---

## Task 3: Convert reconciler-induced WAIT to `.possiblyWaiting`

**Files:**
- Modify: `apps/termy/Sources/HookDaemon.swift:45-65` (CodexForegroundReconciler)
- Modify: `apps/termy-tests/Sources/CodexForegroundReconcilerTests.swift`

- [ ] **Step 1: Update reconciler tests for new state**

Replace `apps/termy-tests/Sources/CodexForegroundReconcilerTests.swift` test bodies:

```swift
func test_quietForegroundCodexThinkingPaneBecomesPossiblyWaiting() {
    let updatedAt = Date(timeIntervalSince1970: 100)
    let now = Date(timeIntervalSince1970: 109)

    let reconciled = CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(
        snapshot(updatedAt: updatedAt),
        now: now,
        silenceThreshold: 8
    )

    XCTAssertEqual(reconciled?.state, .possiblyWaiting)
    XCTAssertNil(reconciled?.waitSource)
    XCTAssertFalse(reconciled?.needsAttention ?? true)
    XCTAssertEqual(reconciled?.updatedAt, now)
    XCTAssertEqual(reconciled?.enteredStateAt, now)
}

func test_recentCodexActivityStaysThinking() {
    let updatedAt = Date(timeIntervalSince1970: 100)
    let now = Date(timeIntervalSince1970: 107)

    let reconciled = CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(
        snapshot(updatedAt: updatedAt),
        now: now,
        silenceThreshold: 8
    )

    XCTAssertNil(reconciled)
}

func test_attentionWaitIsNotOverwritten() {
    let updatedAt = Date(timeIntervalSince1970: 100)
    let now = Date(timeIntervalSince1970: 120)

    let reconciled = CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(
        snapshot(needsAttention: true, updatedAt: updatedAt),
        now: now,
        silenceThreshold: 8
    )

    XCTAssertNil(reconciled)
}

func test_claudeThinkingPaneIsIgnored() {
    let updatedAt = Date(timeIntervalSince1970: 100)
    let now = Date(timeIntervalSince1970: 120)

    let reconciled = CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(
        snapshot(agentKind: .claude, updatedAt: updatedAt),
        now: now,
        silenceThreshold: 8
    )

    XCTAssertNil(reconciled)
}
```

- [ ] **Step 2: Verify tests fail**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/CodexForegroundReconcilerTests 2>&1 | tail -20`
Expected: FAIL — `possiblyWaitingSnapshotIfQuiet` does not exist.

- [ ] **Step 3: Rename and adjust the reconciler**

In `apps/termy/Sources/HookDaemon.swift`, replace the `enum CodexForegroundReconciler` (lines 45-65) with:

```swift
enum CodexForegroundReconciler {
    /// Returns a `.possiblyWaiting` snapshot if a foreground Codex pane has
    /// been silent on hooks for at least `silenceThreshold` seconds while in
    /// THINKING. Returns nil if it should be left alone (recent activity,
    /// already attention-seeking, non-Codex, or wrong base state).
    static func possiblyWaitingSnapshotIfQuiet(
        _ snapshot: PaneSnapshot,
        now: Date,
        silenceThreshold: TimeInterval
    ) -> PaneSnapshot? {
        guard snapshot.agentKind == .codex,
              snapshot.state == .thinking,
              !snapshot.needsAttention
        else { return nil }

        let quietFor = now.timeIntervalSince(snapshot.updatedAt)
        guard quietFor >= silenceThreshold else { return nil }

        var updated = snapshot
        updated.state = .possiblyWaiting
        updated.waitSource = nil
        updated.updatedAt = now
        updated.enteredStateAt = now
        return updated
    }
}
```

Replace the call site in `HookDaemon.reconcileCodexForeground` (lines 203-215) with:

```swift
func reconcileCodexForeground(paneId: String, now: Date = Date()) {
    guard let current = panes[paneId],
          let snapshot = CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(
            current,
            now: now,
            silenceThreshold: codexThinkingSilenceThreshold
          )
    else { return }

    panes[paneId] = snapshot
    seq &+= 1
    updateContinuation.yield(DaemonUpdate(seq: seq, snapshot: snapshot))
}
```

- [ ] **Step 4: Verify reconciler tests pass**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/CodexForegroundReconcilerTests 2>&1 | tail -20`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/HookDaemon.swift apps/termy-tests/Sources/CodexForegroundReconcilerTests.swift
git commit -m "feat(codex): reconciler now produces possiblyWaiting instead of waiting"
```

---

## Task 4: Recovery transitions for `.possiblyWaiting` and `.promotedFromPossible`

**Files:**
- Modify: `apps/termy/Sources/PaneState.swift:228-290` (preToolUse, postToolUse, stop)
- Modify: `apps/termy-tests/Sources/AgentKindTests.swift`

- [ ] **Step 1: Write failing recovery tests**

Append to `AgentKindTests`:

```swift
// MARK: - POSSIBLY_WAITING recovery

func test_codexPreToolUse_inPossiblyWaiting_recoversToThinking_silently() {
    var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
    s.state = .possiblyWaiting
    s.needsAttention = false
    s.waitSource = nil
    let event = HookEvent(
        event: .preToolUse, paneId: "p1", projectId: nil, ts: 1.0,
        agent: "codex",
        meta: { var m = HookEvent.Meta(); m.toolName = "Bash"; return m }()
    )
    let after = PaneStateMachine.apply(event, to: s)
    XCTAssertEqual(after.state, .thinking)
    XCTAssertFalse(after.needsAttention)
    XCTAssertNil(after.waitSource)
}

func test_codexPostToolUse_inPossiblyWaiting_recoversToThinking_silently() {
    var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
    s.state = .possiblyWaiting
    let event = HookEvent(
        event: .postToolUse, paneId: "p1", projectId: nil, ts: 1.0,
        agent: "codex",
        meta: { var m = HookEvent.Meta(); m.toolName = "Bash"; return m }()
    )
    let after = PaneStateMachine.apply(event, to: s)
    XCTAssertEqual(after.state, .thinking)
}

func test_codexPostToolUse_inPromotedFromPossibleWaiting_recoversToThinking() {
    var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
    s.state = .waiting
    s.needsAttention = true
    s.waitSource = .promotedFromPossible
    let event = HookEvent(
        event: .postToolUse, paneId: "p1", projectId: nil, ts: 1.0,
        agent: "codex",
        meta: { var m = HookEvent.Meta(); m.toolName = "Bash"; return m }()
    )
    let after = PaneStateMachine.apply(event, to: s)
    XCTAssertEqual(after.state, .thinking)
    XCTAssertFalse(after.needsAttention)
    XCTAssertNil(after.waitSource)
}

func test_codexStop_inPossiblyWaiting_promotesToTurnEndWaiting() {
    // Stop arriving during POSSIBLY_WAITING is a real turn end — promote
    // to WAITING(.turnEnd) so the user gets the sound.
    var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
    s.state = .possiblyWaiting
    let event = HookEvent(
        event: .stop, paneId: "p1", projectId: nil, ts: 1.0,
        agent: "codex",
        meta: { var m = HookEvent.Meta(); m.lastAssistantMessage = "done"; return m }()
    )
    let after = PaneStateMachine.apply(event, to: s)
    XCTAssertEqual(after.state, .waiting)
    XCTAssertEqual(after.waitSource, .turnEnd)
    XCTAssertEqual(after.lastAssistantMessage, "done")
}

func test_codexPermissionRequest_inPossiblyWaiting_promotesToPermissionWaiting() {
    var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
    s.state = .possiblyWaiting
    let event = HookEvent(
        event: .permissionRequest, paneId: "p1", projectId: nil, ts: 1.0,
        agent: "codex",
        meta: { var m = HookEvent.Meta(); m.toolName = "Bash"; return m }()
    )
    let after = PaneStateMachine.apply(event, to: s)
    XCTAssertEqual(after.state, .waiting)
    XCTAssertEqual(after.waitSource, .permission)
    XCTAssertTrue(after.needsAttention)
}
```

- [ ] **Step 2: Verify tests fail**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/AgentKindTests 2>&1 | tail -30`
Expected: 5 new tests FAIL — possiblyWaiting → thinking branch is missing.

- [ ] **Step 3: Add recovery branches**

In `apps/termy/Sources/PaneState.swift`, replace the existing `case .preToolUse:` block (lines 228-252) with:

```swift
case .preToolUse:
    if event.meta.toolName == "AskUserQuestion" {
        next.state = .waiting
        next.needsAttention = true
        next.notificationReason = "ask_user_question"
        next.waitSource = .askUserQuestion
        next.enteredStateAt = next.updatedAt
    } else if (event.agentKind ?? previous.agentKind) == .codex,
              previous.state == .possiblyWaiting {
        // Possible-WAIT recovery: hook activity proves the model is working.
        // Silent — no needsAttention was raised on possibly entry.
        next.state = .thinking
        next.enteredStateAt = next.updatedAt
    } else if (event.agentKind ?? previous.agentKind) == .codex,
              previous.state == .waiting,
              previous.waitSource == .promotedFromPossible {
        // Real-WAIT recovery (preserved c80d2c4 logic, re-keyed on waitSource).
        // The promotion timer fired but a real Pre/PostToolUse arrived after,
        // so the model was working all along — flip back to THINKING.
        next.state = .thinking
        next.needsAttention = false
        next.waitSource = nil
        next.enteredStateAt = next.updatedAt
    }
```

Replace the existing `case .postToolUse:` block (lines 254-284) with:

```swift
case .postToolUse:
    if event.meta.toolName == "AskUserQuestion",
       previous.state == .waiting,
       previous.waitSource == .askUserQuestion {
        next.state = .thinking
        next.needsAttention = false
        next.notificationReason = nil
        next.waitSource = nil
        next.enteredStateAt = next.updatedAt
    } else if (event.agentKind ?? previous.agentKind) == .codex,
              previous.state == .waiting,
              previous.waitSource == .permission {
        next.state = .thinking
        next.needsAttention = false
        next.notificationReason = nil
        next.waitSource = nil
        next.enteredStateAt = next.updatedAt
    } else if (event.agentKind ?? previous.agentKind) == .codex,
              previous.state == .possiblyWaiting {
        next.state = .thinking
        next.enteredStateAt = next.updatedAt
    } else if (event.agentKind ?? previous.agentKind) == .codex,
              previous.state == .waiting,
              previous.waitSource == .promotedFromPossible {
        next.state = .thinking
        next.needsAttention = false
        next.waitSource = nil
        next.enteredStateAt = next.updatedAt
    }
```

The existing `case .stop:` block (Task 2) already does the right thing for `.thinking → .waiting(.turnEnd)`. Stop arriving in `.possiblyWaiting` is also a turn end — the same code already handles it because the assignment to `.waiting` is unconditional. Confirm by re-reading the post-Task-2 stop case:

```swift
case .stop:
    next.lastAssistantMessage = event.meta.lastAssistantMessage
    next.state = .waiting
    next.waitSource = .turnEnd
    next.enteredStateAt = next.updatedAt
```

Good — `.possiblyWaiting → .waiting(.turnEnd)` works without further changes.

- [ ] **Step 4: Update the state-table doc comment**

In `apps/termy/Sources/PaneState.swift`, replace the doc-comment header block (lines 1-31) with:

```swift
// PaneState.swift
//
// Per-pane state machine driven by HookEvents. ERRORED is driven by
// PtyExit (exit_code != 0) or StopFailure — NOT by PostToolUseFailure, which
// fires on routine tool errors that Claude recovers from within the same turn.
//
//   INIT             ──(UserPromptSubmit)─────────▶ THINKING
//   INIT             ──(SessionStart)──────────────▶ INIT          (informational)
//   THINKING         ──(Stop)───────────────────────▶ WAITING(.turnEnd)
//   THINKING         ──(SessionEnd)─────────────────▶ INIT
//   THINKING         ──(PtyExit, exit != 0)─────────▶ ERRORED
//   THINKING         ──(reconciler 8s silence)──────▶ POSSIBLY_WAITING (silent)
//   POSSIBLY_WAITING ──(Pre/PostToolUse)─────────────▶ THINKING       (silent recovery)
//   POSSIBLY_WAITING ──(PTY byte)────────────────────▶ THINKING       (PTY proof of life)
//   POSSIBLY_WAITING ──(Stop)────────────────────────▶ WAITING(.turnEnd)         ♪
//   POSSIBLY_WAITING ──(PermissionRequest)───────────▶ WAITING(.permission)      ♪
//   POSSIBLY_WAITING ──(AskUserQuestion)─────────────▶ WAITING(.askUserQuestion) ♪
//   POSSIBLY_WAITING ──(promote timer 12s elapsed)───▶ WAITING(.promotedFromPossible) ♪
//   WAITING          ──(UserPromptSubmit)───────────▶ THINKING
//   WAITING          ──(30s wall-clock timer)───────▶ IDLE
//   WAITING          ──(SessionEnd | PtyExit)───────▶ INIT
//   WAITING(.permission)         ──(PostToolUse)──▶ THINKING (Codex resumed)
//   WAITING(.askUserQuestion)    ──(PostToolUse AskUserQuestion)──▶ THINKING
//   WAITING(.promotedFromPossible) ──(Pre/PostToolUse)──▶ THINKING (recovery, c80d2c4 lineage)
//   IDLE      ──(UserPromptSubmit)──────▶ THINKING
//   IDLE      ──(SessionEnd | PtyExit)──▶ INIT
//   ERRORED   ──(UserPromptSubmit)──────▶ THINKING
//   ERRORED   ──(Stop)───────────────────▶ WAITING(.turnEnd)
//   ERRORED   ──(SessionStart)───────────▶ INIT
//   *(codex)  ──(SessionStart)───────────▶ IDLE          (hard reset)
//
// ♪ = Notifier plays a sound and raises needsAttention.
//
// POSSIBLY_WAITING is rendered as THINK in the dashboard chip — invisible to
// the user. The two-stage WAIT is documented in
// docs/superpowers/plans/2026-04-26-codex-possibly-waiting-state.md.
```

- [ ] **Step 5: Verify recovery tests pass and existing tests still pass**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/AgentKindTests -only-testing:termy-tests/PaneStateMachineTests 2>&1 | tail -30`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/termy/Sources/PaneState.swift apps/termy-tests/Sources/AgentKindTests.swift
git commit -m "feat(codex): possiblyWaiting recovery branches and waitSource-keyed real-WAIT recovery"
```

---

## Task 5: Add `HookDaemon.recordPtyActivity` and PTY-revert from possiblyWaiting

**Files:**
- Modify: `apps/termy/Sources/HookDaemon.swift` (add method, threshold constant)
- Create: `apps/termy-tests/Sources/HookDaemonPossiblyWaitingTests.swift`

- [ ] **Step 1: Write failing tests for the new daemon method**

Create `apps/termy-tests/Sources/HookDaemonPossiblyWaitingTests.swift`:

```swift
// HookDaemonPossiblyWaitingTests.swift
//
// Unit tests for the daemon-side mechanics of the two-stage Codex WAIT:
// recordPtyActivity reverts POSSIBLY_WAITING to THINKING; tickPromotePossibly
// promotes POSSIBLY_WAITING to WAITING(.promotedFromPossible) after the
// silence threshold elapses.

import XCTest
@testable import termy

final class HookDaemonPossiblyWaitingTests: XCTestCase {

    func test_recordPtyActivity_revertsPossiblyWaitingToThinking() async {
        let daemon = HookDaemon.testInstance()
        let snap = await daemon.injectSnapshot {
            var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
            s.state = .possiblyWaiting
            return s
        }
        XCTAssertEqual(snap.state, .possiblyWaiting)

        let now = Date()
        await daemon.recordPtyActivity(paneId: "p1", at: now)

        let after = await daemon.snapshot(paneId: "p1")
        XCTAssertEqual(after?.state, .thinking)
        XCTAssertEqual(after?.lastPtyActivityAt, now)
    }

    func test_recordPtyActivity_inThinking_onlyUpdatesTimestamp() async {
        let daemon = HookDaemon.testInstance()
        _ = await daemon.injectSnapshot {
            var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
            s.state = .thinking
            return s
        }

        let now = Date()
        await daemon.recordPtyActivity(paneId: "p1", at: now)

        let after = await daemon.snapshot(paneId: "p1")
        XCTAssertEqual(after?.state, .thinking)
        XCTAssertEqual(after?.lastPtyActivityAt, now)
    }

    func test_recordPtyActivity_inWaiting_onlyUpdatesTimestamp() async {
        let daemon = HookDaemon.testInstance()
        _ = await daemon.injectSnapshot {
            var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
            s.state = .waiting
            s.waitSource = .permission
            s.needsAttention = true
            return s
        }

        let now = Date()
        await daemon.recordPtyActivity(paneId: "p1", at: now)

        let after = await daemon.snapshot(paneId: "p1")
        XCTAssertEqual(after?.state, .waiting)
        XCTAssertEqual(after?.waitSource, .permission)
        XCTAssertTrue(after?.needsAttention ?? false)
        XCTAssertEqual(after?.lastPtyActivityAt, now)
    }

    func test_recordPtyActivity_unknownPane_isNoop() async {
        let daemon = HookDaemon.testInstance()
        await daemon.recordPtyActivity(paneId: "ghost", at: Date())
        let after = await daemon.snapshot(paneId: "ghost")
        XCTAssertNil(after)
    }
}
```

- [ ] **Step 2: Verify tests fail**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/HookDaemonPossiblyWaitingTests 2>&1 | tail -30`
Expected: FAIL — `HookDaemon.testInstance`, `injectSnapshot`, `recordPtyActivity` do not exist.

- [ ] **Step 3: Add test seam helpers and the new method**

In `apps/termy/Sources/HookDaemon.swift`, add a `testInstance` static and `injectSnapshot` helper (place these immediately after the existing `init()` block at line 116):

```swift
    /// Test seam — spins up a daemon without binding the socket. The
    /// production path goes through `start()`; tests skip that and drive
    /// the actor directly.
    static func testInstance() -> HookDaemon {
        HookDaemon()
    }

    /// Test seam — set or replace a pane's snapshot and return it. Used by
    /// tests to bootstrap state before exercising actor methods.
    @discardableResult
    func injectSnapshot(_ build: () -> PaneSnapshot) -> PaneSnapshot {
        let snap = build()
        panes[snap.paneId] = snap
        return snap
    }
```

Add `recordPtyActivity` near `reconcileCodexForeground` (after line 215):

```swift
    /// Called by TermyTerminalView every time the PTY produces output.
    /// Updates `lastPtyActivityAt` and reverts a `.possiblyWaiting` Codex
    /// pane to `.thinking` — PTY bytes are proof the model is working
    /// (reasoning summary text prints to the PTY even between hook events).
    /// No-op on unknown paneId.
    func recordPtyActivity(paneId: String, at now: Date = Date()) {
        guard var snapshot = panes[paneId] else { return }
        snapshot.lastPtyActivityAt = now
        if snapshot.state == .possiblyWaiting {
            snapshot.state = .thinking
            snapshot.enteredStateAt = now
        }
        snapshot.updatedAt = now
        panes[paneId] = snapshot
        seq &+= 1
        updateContinuation.yield(DaemonUpdate(seq: seq, snapshot: snapshot))
    }
```

- [ ] **Step 4: Verify tests pass**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/HookDaemonPossiblyWaitingTests 2>&1 | tail -30`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/HookDaemon.swift apps/termy-tests/Sources/HookDaemonPossiblyWaitingTests.swift
git commit -m "feat(codex): HookDaemon.recordPtyActivity reverts possiblyWaiting on PTY bytes"
```

---

## Task 6: Add promotion timer to `HookDaemon.tickIdle`

**Files:**
- Modify: `apps/termy/Sources/HookDaemon.swift:99` (constant) and `tickIdle` (lines 419-445)
- Modify: `apps/termy-tests/Sources/HookDaemonPossiblyWaitingTests.swift`

- [ ] **Step 1: Write failing promotion tests**

Append to `HookDaemonPossiblyWaitingTests`:

```swift
func test_tickPromote_underThreshold_doesNothing() async {
    let daemon = HookDaemon.testInstance()
    let enteredAt = Date(timeIntervalSince1970: 1000)
    _ = await daemon.injectSnapshot {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        s.state = .possiblyWaiting
        s.enteredStateAt = enteredAt
        s.updatedAt = enteredAt
        return s
    }

    // 11s after entering possibly — below the 12s threshold.
    let now = Date(timeIntervalSince1970: 1011)
    await daemon.tickPromotePossiblyWaiting(now: now)

    let after = await daemon.snapshot(paneId: "p1")
    XCTAssertEqual(after?.state, .possiblyWaiting)
    XCTAssertNil(after?.waitSource)
    XCTAssertFalse(after?.needsAttention ?? true)
}

func test_tickPromote_pastThreshold_promotesToWaiting() async {
    let daemon = HookDaemon.testInstance()
    let enteredAt = Date(timeIntervalSince1970: 1000)
    _ = await daemon.injectSnapshot {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        s.state = .possiblyWaiting
        s.enteredStateAt = enteredAt
        s.updatedAt = enteredAt
        return s
    }

    // 12s after entering possibly — at threshold.
    let now = Date(timeIntervalSince1970: 1012)
    await daemon.tickPromotePossiblyWaiting(now: now)

    let after = await daemon.snapshot(paneId: "p1")
    XCTAssertEqual(after?.state, .waiting)
    XCTAssertEqual(after?.waitSource, .promotedFromPossible)
    XCTAssertTrue(after?.needsAttention ?? false)
    XCTAssertEqual(after?.enteredStateAt, now)
}

func test_tickPromote_thinkingPane_isUntouched() async {
    let daemon = HookDaemon.testInstance()
    _ = await daemon.injectSnapshot {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        s.state = .thinking
        s.enteredStateAt = Date(timeIntervalSince1970: 0)
        return s
    }

    await daemon.tickPromotePossiblyWaiting(now: Date(timeIntervalSince1970: 100_000))

    let after = await daemon.snapshot(paneId: "p1")
    XCTAssertEqual(after?.state, .thinking)
}
```

- [ ] **Step 2: Verify tests fail**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/HookDaemonPossiblyWaitingTests 2>&1 | tail -30`
Expected: FAIL — `tickPromotePossiblyWaiting` does not exist.

- [ ] **Step 3: Add the constant and the tick function**

In `apps/termy/Sources/HookDaemon.swift`, immediately after `codexThinkingSilenceThreshold` (line 99) add:

```swift
    /// POSSIBLY_WAITING → WAITING(.promotedFromPossible) after this many
    /// seconds elapsed since entering possibly with no recovery. Total
    /// silence-to-sound is `codexThinkingSilenceThreshold` + this value
    /// (default 8 + 12 = ~20s).
    private let codexPromotionThreshold: TimeInterval = 12
```

Add the new actor method right above `tickIdle` (line 419):

```swift
    /// Walk POSSIBLY_WAITING Codex panes; promote any that have been in
    /// the state for `codexPromotionThreshold` seconds with no hook or
    /// PTY recovery. Promotion sets `waitSource = .promotedFromPossible`
    /// and `needsAttention = true`, which Notifier turns into a sound +
    /// dock badge. Called from `idleLoop`.
    func tickPromotePossiblyWaiting(now: Date = Date()) {
        for (id, snapshot) in panes where snapshot.state == .possiblyWaiting {
            let elapsed = now.timeIntervalSince(snapshot.enteredStateAt)
            guard elapsed >= codexPromotionThreshold else { continue }
            var updated = snapshot
            updated.state = .waiting
            updated.waitSource = .promotedFromPossible
            updated.needsAttention = true
            updated.updatedAt = now
            updated.enteredStateAt = now
            panes[id] = updated
            seq &+= 1
            updateContinuation.yield(DaemonUpdate(seq: seq, snapshot: updated))
        }
    }
```

Wire it into the existing `idleLoop` by replacing the loop body (lines 412-417) with:

```swift
    private func idleLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000) // 5s tick
            await tickPromotePossiblyWaiting()
            await tickIdle()
        }
    }
```

- [ ] **Step 4: Verify all daemon tests pass**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/HookDaemonPossiblyWaitingTests 2>&1 | tail -30`
Expected: 7 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/HookDaemon.swift apps/termy-tests/Sources/HookDaemonPossiblyWaitingTests.swift
git commit -m "feat(codex): tick promotion of possiblyWaiting to waiting(.promotedFromPossible)"
```

---

## Task 7: Wire PTY data through `TermyTerminalView` to the daemon

**Files:**
- Modify: `apps/termy/Sources/TermyTerminalView.swift`
- Modify: `apps/termy/Sources/Pane.swift`

- [ ] **Step 1: Add a paneId hook on the terminal view**

In `apps/termy/Sources/TermyTerminalView.swift`, near the top of the `final class TermyTerminalView: LocalProcessTerminalView` body (line 18), add:

```swift
    /// Set by Pane after construction — used to attribute PTY-byte pings
    /// to the right snapshot inside HookDaemon. nil before assignment.
    var paneId: String?
```

Override `dataReceived(slice:)` at the bottom of the class body, just before the closing brace of `final class TermyTerminalView`:

```swift
    /// PTY produced bytes — forward to SwiftTerm's renderer (via super) and
    /// publish a liveness ping to HookDaemon. The ping reverts a Codex pane
    /// out of POSSIBLY_WAITING because reasoning-summary text prints to the
    /// PTY even between hook events.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        guard let paneId else { return }
        Task { await HookDaemon.shared.recordPtyActivity(paneId: paneId) }
    }
```

- [ ] **Step 2: Stamp the paneId from Pane**

In `apps/termy/Sources/Pane.swift`, in the `init(projectId:cwd:)` method, after the line `self.terminal = TermyTerminalView(frame: .zero)` (line 92), add:

```swift
        self.terminal.paneId = self.paneId
```

- [ ] **Step 3: Build the app to confirm wiring compiles**

Run: `xcodebuild -scheme termy -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Document the live-verification step**

This wiring cannot be unit-tested cleanly (PTY bytes are real I/O). Document the live-verification steps required by the project's IME/PTY policy. Append to `apps/termy/Sources/TermyTerminalView.swift` immediately above the new `dataReceived` override:

```swift
    // Live verification (required per memory `feedback_termy_live_verify.md`):
    //   1. Build & launch termy with `xcodebuild -scheme termy -destination
    //      'platform=macOS' run`.
    //   2. Open a pane, run `codex` with a reasoning-heavy prompt
    //      ("think carefully and explain X in 5 paragraphs").
    //   3. Verify dashboard chip stays on THINK during the long reasoning
    //      period — should NOT flicker to WAIT (silent POSSIBLY_WAITING).
    //   4. Trigger an actual permission prompt (e.g. `codex` asks to run
    //      Bash); verify chip flips to WAIT with sound.
    //   5. After ~20s of model hang (kill -STOP `pidof codex`), confirm
    //      promotion to WAIT(.promotedFromPossible) with sound.
```

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/TermyTerminalView.swift apps/termy/Sources/Pane.swift
git commit -m "feat(codex): forward PTY byte arrivals to HookDaemon as liveness pings"
```

---

## Task 8: Render `.possiblyWaiting` as THINK in the chip and feed `waitSource` into the notification body

**Files:**
- Modify: `apps/termy/Sources/MissionControlView.swift:397-419`
- Modify: `apps/termy/Sources/Notifier.swift:140-160`

- [ ] **Step 1: Update the chip styling switch sites**

In `apps/termy/Sources/MissionControlView.swift`, replace `shouldBlink` (line 397-399), `stateColor` (lines 401-409), and `stateLabel` (lines 411-419) with:

```swift
    private var shouldBlink: Bool {
        state == .thinking || state == .waiting || state == .possiblyWaiting
    }

    private var stateColor: Color {
        switch state {
        case .thinking, .possiblyWaiting:
            // POSSIBLY_WAITING is rendered as THINK — invisible to the user.
            return Color(nsColor: .systemBlue)
        case .waiting:      return Color(nsColor: .systemOrange)
        case .errored:      return Color(nsColor: .systemRed)
        case .idle:         return Color(nsColor: .systemGray)
        case .initializing: return Color(nsColor: .systemGray)
        }
    }

    private var stateLabel: String {
        switch state {
        case .initializing:    return "INIT"
        case .thinking,
             .possiblyWaiting: return "THINK"
        case .waiting:         return "WAIT"
        case .idle:            return "IDLE"
        case .errored:         return "ERR"
        }
    }
```

- [ ] **Step 2: Honour `waitSource` in the notification body**

In `apps/termy/Sources/Notifier.swift`, replace `notificationBody(for:)` (lines 145-159) with:

```swift
    private func notificationBody(for snap: PaneSnapshot) -> String {
        // Codex panes carry waitSource; map it to user-facing copy first.
        if let source = snap.waitSource {
            switch source {
            case .permission:           return "Waiting for your approval."
            case .askUserQuestion:      return "Codex is asking a question."
            case .turnEnd:
                if let msg = snap.lastAssistantMessage, !msg.isEmpty {
                    return String(msg.prefix(140))
                }
                return "Codex finished — your turn."
            case .promotedFromPossible: return "Codex has been quiet for a while — check on it."
            }
        }
        if let reason = snap.notificationReason {
            switch reason {
            case "permission":         return "Waiting for your approval."
            case "idle":               return "Still idle — check what's pending."
            case "mcp_elicit":         return "An MCP tool is asking for input."
            case "ask_user_question":  return "Claude is asking a question."
            default:                   break
            }
        }
        if let msg = snap.lastAssistantMessage, !msg.isEmpty {
            return String(msg.prefix(140))
        }
        return "Claude is waiting for your response."
    }
```

- [ ] **Step 3: Build to confirm exhaustive-switch coverage**

Run: `xcodebuild -scheme termy -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED`. (If any other PaneState switch is missing the new case, the build will fail with a non-exhaustive-switch warning escalated to error.)

- [ ] **Step 4: Run the full test suite as a regression check**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `** TEST SUCCEEDED **`. All existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/MissionControlView.swift apps/termy/Sources/Notifier.swift
git commit -m "feat(codex): render possiblyWaiting as THINK chip; map waitSource to notification body"
```

---

## Task 9: Documentation, changelog, TODOs

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `TODOS.md`

- [ ] **Step 1: Add a CHANGELOG entry**

In `CHANGELOG.md`, under the Unreleased section (or create one if missing), add a single bullet:

```markdown
- Codex: replace 8s fake-WAIT heuristic with two-stage POSSIBLY_WAITING → WAITING(.promotedFromPossible). Reasoning-model silence (GPT-5/o-series) no longer triggers spurious WAIT chips or sounds; PTY byte arrival reverts the silent interim state. Total silence-to-sound is now ~20s.
```

- [ ] **Step 2: Update TODOS.md**

In `TODOS.md`, under the "Codex follow-ups" section, mark the fake-WAIT prevention item as DONE and add any small polish work that fell out of this plan:

```markdown
- ~~**Fake-WAIT prevention** — reasoning-model silence shouldn't trip the 8s reconciler.~~ Shipped 2026-04-26 via two-stage WAIT (POSSIBLY_WAITING + PTY-activity gate + promotion timer). See `docs/superpowers/plans/2026-04-26-codex-possibly-waiting-state.md`.
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md TODOS.md
git commit -m "docs(codex): record possiblyWaiting two-stage WAIT under Unreleased"
```

---

## Self-Review

**Spec coverage** — every requirement from the design discussion is mapped to a task:
- ✅ Two states (Real WAIT vs Possible WAIT) → Task 1 (`possiblyWaiting` + `WaitSource`)
- ✅ PTY activity gates promotion / reverts to THINK → Tasks 5, 7
- ✅ Time-based promotion to Real WAIT → Task 6 (`tickPromotePossiblyWaiting`, 12s threshold)
- ✅ Sound + WAIT chip on promotion → Task 6 sets `needsAttention=true`; Notifier sounds on .waiting entry (already correct, exercised by Task 8)
- ✅ Existing recovery preserved on Real WAIT → Task 4 (`waitSource == .promotedFromPossible` recovery branches)
- ✅ Stop direct to Real WAIT (not via Possible) — covered by `case .stop:` after Task 2 (unconditional WAIT entry, Task 4 confirms `.possiblyWaiting → .waiting(.turnEnd)` works without extra code)

**Placeholder scan:** No "TBD", "etc.", or "similar to" in any step. Every code block is complete.

**Type consistency:** `WaitSource` enum used identically across PaneState, Notifier, and tests. `recordPtyActivity` signature stable across Tasks 5-7. `tickPromotePossiblyWaiting` matches between definition (Task 6) and call site (Task 6 idleLoop edit).

**Build-error coverage:** Exhaustive-switch sites (`MissionControlView` 2 sites + `PaneState.swift` line 162 already uses `default`) are all updated in Task 8 — Step 3 build will catch any miss.

---

## Execution Notes

- The plan touches public types in `PaneState.swift` (`PaneSnapshot` Codable round-trip). Task 1 includes a Codable round-trip test to lock the wire format. Existing journal files written before this change have `waitSource: nil` and `lastPtyActivityAt: nil` — Codable's optional handling reads them cleanly.
- `HookDaemon.testInstance()` deliberately skips socket setup so tests don't bind `/tmp/termy-$UID.sock`. Production callers must continue to use `HookDaemon.shared` and `start()`.
- `codexPromotionThreshold = 12` is a knob. Live testing per Task 7 step 4 is the place to tune it.

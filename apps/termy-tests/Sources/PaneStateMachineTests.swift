// PaneStateMachineTests.swift
//
// Deterministic transition coverage for the state table documented in
// PaneState.swift. Every transition arc is one test, every guarded case
// (session-id reset, exit-code branch, needsAttention overlay) is another.

import XCTest
@testable import termy

final class PaneStateMachineTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        _ kind: HookEventKind,
        session: String? = "s1",
        exitCode: Int32? = nil,
        prompt: String? = nil,
        last: String? = nil,
        reason: String? = nil,
        notificationType: String? = nil,
        toolName: String? = nil
    ) -> HookEvent {
        var meta = HookEvent.Meta()
        meta.sessionId = session
        meta.exitCode = exitCode
        meta.prompt = prompt
        meta.lastAssistantMessage = last
        meta.reason = reason
        meta.notificationType = notificationType
        meta.toolName = toolName
        return HookEvent(
            event: kind,
            paneId: "p1",
            projectId: "proj",
            ts: 1.0,
            agent: "claude-code",
            meta: meta
        )
    }

    private func empty() -> PaneSnapshot {
        PaneSnapshot.empty(paneId: "p1", projectId: "proj")
    }

    // MARK: - Happy path

    func test_sessionStart_onInit_promotesToIdle() {
        let after = PaneStateMachine.apply(makeEvent(.sessionStart), to: empty())
        XCTAssertEqual(after.state, .idle)
    }

    func test_userPromptSubmit_onInit_toThinking() {
        let after = PaneStateMachine.apply(
            makeEvent(.userPromptSubmit, prompt: "hi"),
            to: empty()
        )
        XCTAssertEqual(after.state, .thinking)
        XCTAssertEqual(after.lastPrompt, "hi")
        XCTAssertFalse(after.needsAttention)
    }

    func test_stop_onThinking_toWaiting_withLastMessage() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(
            makeEvent(.stop, last: "done"),
            to: s
        )
        XCTAssertEqual(after.state, .waiting)
        XCTAssertEqual(after.lastAssistantMessage, "done")
    }

    func test_userPromptSubmit_onWaiting_toThinking() {
        var s = empty()
        s.state = .waiting
        let after = PaneStateMachine.apply(makeEvent(.userPromptSubmit, prompt: "again"), to: s)
        XCTAssertEqual(after.state, .thinking)
    }

    // MARK: - Error arcs

    func test_stopFailure_toErrored() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(makeEvent(.stopFailure), to: s)
        XCTAssertEqual(after.state, .errored)
    }

    func test_postToolUseFailure_keepsThinking() {
        // A single tool failure (Read of missing file, Glob with no matches,
        // Bash exit 1, …) is recoverable — Claude handles the error response
        // and continues. Pane must stay THINKING, not flip to ERRORED.
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(makeEvent(.postToolUseFailure), to: s)
        XCTAssertEqual(after.state, .thinking)
    }

    func test_errored_recovers_onStop() {
        var s = empty()
        s.state = .errored
        let after = PaneStateMachine.apply(makeEvent(.stop, last: "recovered"), to: s)
        XCTAssertEqual(after.state, .waiting)
    }

    func test_errored_recovers_onUserPrompt() {
        var s = empty()
        s.state = .errored
        let after = PaneStateMachine.apply(makeEvent(.userPromptSubmit, prompt: "retry"), to: s)
        XCTAssertEqual(after.state, .thinking)
    }

    // MARK: - PtyExit

    func test_ptyExit_nonzero_toErrored() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(makeEvent(.ptyExit, exitCode: -9), to: s)
        XCTAssertEqual(after.state, .errored)
    }

    func test_ptyExit_zero_toInit() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(makeEvent(.ptyExit, exitCode: 0), to: s)
        XCTAssertEqual(after.state, .initializing)
    }

    func test_sessionEnd_toInit_clearsAttention() {
        var s = empty()
        s.state = .waiting
        s.needsAttention = true
        s.notificationReason = "permission"
        let after = PaneStateMachine.apply(makeEvent(.sessionEnd), to: s)
        XCTAssertEqual(after.state, .initializing)
        XCTAssertFalse(after.needsAttention)
        XCTAssertNil(after.notificationReason)
    }

    // MARK: - Notification overlay

    func test_notification_permission_whileThinking_flipsToWaiting() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(makeEvent(.notification, reason: "permission"), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "permission")
    }

    func test_notification_mcpElicit_whileThinking_flipsToWaiting() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(makeEvent(.notification, reason: "mcp_elicit"), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
    }

    func test_notification_authSuccess_preservesState() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(makeEvent(.notification, reason: "auth_success"), to: s)
        XCTAssertEqual(after.state, .thinking)
        XCTAssertTrue(after.needsAttention)
    }

    func test_notification_whileWaiting_preservesWaiting() {
        var s = empty()
        s.state = .waiting
        let after = PaneStateMachine.apply(makeEvent(.notification, reason: "permission"), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
    }

    // A pane that the WAITING→IDLE timer has already demoted can still get a
    // fresh blocking notification (permission / mcp_elicit / idle reminder).
    // That must flip state back to WAITING — otherwise the chip renders as
    // "IDLE label on accent-blue background", a visual contradiction the
    // bottom dashboard showed before this fix.
    func test_notification_permission_whileIdle_flipsToWaiting() {
        var s = empty()
        s.state = .idle
        let after = PaneStateMachine.apply(makeEvent(.notification, reason: "permission"), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "permission")
    }

    func test_notification_mcpElicit_whileIdle_flipsToWaiting() {
        var s = empty()
        s.state = .idle
        let after = PaneStateMachine.apply(makeEvent(.notification, reason: "mcp_elicit"), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
    }

    func test_notification_idleReminder_whileIdle_preservesIdle() {
        var s = empty()
        s.state = .idle
        let after = PaneStateMachine.apply(makeEvent(.notification, reason: "idle"), to: s)
        // idle_prompt means the turn already ended — nothing new to announce.
        XCTAssertEqual(after.state, .idle)
        XCTAssertFalse(after.needsAttention)
    }

    // MARK: - Claude notification_type

    private func claudeNotification(_ type: String) -> HookEvent {
        makeEvent(.notification, notificationType: type)
    }

    func test_claude_permissionPrompt_whileThinking_flipsToWaiting_turnStaysOpen() {
        var s = empty()
        s.state = .thinking
        s.turnOpen = true
        let after = PaneStateMachine.apply(claudeNotification("permission_prompt"), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "permission")
        XCTAssertTrue(after.turnOpen)
    }

    func test_claude_permissionCycle_recoversOnPostToolUse_thenStopWaits() {
        var s = PaneStateMachine.apply(makeEvent(.userPromptSubmit, prompt: "hi"), to: empty())
        s = PaneStateMachine.apply(claudeNotification("permission_prompt"), to: s)
        XCTAssertEqual(s.state, .waiting)
        s = PaneStateMachine.apply(makeEvent(.postToolUse, toolName: "Bash"), to: s)
        XCTAssertEqual(s.state, .thinking)
        XCTAssertFalse(s.needsAttention)
        XCTAssertNil(s.notificationReason)
        s = PaneStateMachine.apply(makeEvent(.stop, last: "done"), to: s)
        XCTAssertEqual(s.state, .waiting)
    }

    func test_claude_preToolUse_whileWaitingOnPermission_doesNotRecover() {
        var s = empty()
        s.state = .thinking
        s = PaneStateMachine.apply(claudeNotification("permission_prompt"), to: s)
        s = PaneStateMachine.apply(makeEvent(.preToolUse, toolName: "Read"), to: s)
        XCTAssertEqual(s.state, .waiting)
        XCTAssertTrue(s.needsAttention)
        XCTAssertEqual(s.notificationReason, "permission")
    }

    func test_claude_idlePrompt_whileThinking_flipsToWaiting_closesTurn() {
        var s = empty()
        s.state = .thinking
        s.turnOpen = true
        let after = PaneStateMachine.apply(claudeNotification("idle_prompt"), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "idle")
        XCTAssertFalse(after.turnOpen)
        XCTAssertFalse(after.isMidTurn)
    }

    func test_claude_idlePrompt_afterStop_leavesWaitingUntouched() {
        var s = empty()
        s.state = .thinking
        s = PaneStateMachine.apply(makeEvent(.stop, last: "done"), to: s)
        XCTAssertEqual(s.state, .waiting)
        let before = s
        let after = PaneStateMachine.apply(claudeNotification("idle_prompt"), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertEqual(after.needsAttention, before.needsAttention)
        XCTAssertEqual(after.notificationReason, before.notificationReason)
        XCTAssertFalse(after.turnOpen)
    }

    func test_claude_idlePrompt_whileIdle_staysIdle() {
        var s = empty()
        s.state = .idle
        let after = PaneStateMachine.apply(claudeNotification("idle_prompt"), to: s)
        XCTAssertEqual(after.state, .idle)
        XCTAssertFalse(after.needsAttention)
    }

    func test_claude_elicitationResponse_doesNotOverwriteMcpElicit() {
        var s = empty()
        s.state = .thinking
        s = PaneStateMachine.apply(makeEvent(.preToolUse, toolName: "mcp__x"), to: s)
        s = PaneStateMachine.apply(claudeNotification("elicitation_dialog"), to: s)
        s = PaneStateMachine.apply(claudeNotification("elicitation_response"), to: s)
        XCTAssertEqual(s.state, .waiting)
        XCTAssertEqual(s.notificationReason, "mcp_elicit")
        XCTAssertTrue(s.needsAttention)
        s = PaneStateMachine.apply(makeEvent(.postToolUse, toolName: "mcp__x"), to: s)
        XCTAssertEqual(s.state, .thinking)
        XCTAssertNil(s.notificationReason)
        XCTAssertFalse(s.needsAttention)
    }

    func test_claude_informationalNotification_duringPermissionWait_keepsReason() {
        var s = empty()
        s.state = .thinking
        s = PaneStateMachine.apply(claudeNotification("permission_prompt"), to: s)
        s = PaneStateMachine.apply(claudeNotification("agent_completed"), to: s)
        XCTAssertEqual(s.notificationReason, "permission")
        XCTAssertTrue(s.needsAttention)
        s = PaneStateMachine.apply(makeEvent(.postToolUse, toolName: "Bash"), to: s)
        XCTAssertEqual(s.state, .thinking)
    }

    func test_claude_informationalNotification_whileThinking_storesAsBefore() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(claudeNotification("agent_completed"), to: s)
        XCTAssertEqual(after.state, .thinking)
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "agent_completed")
    }

    func test_claude_postToolUseFailure_afterPermission_recovers() {
        var s = empty()
        s.state = .thinking
        s = PaneStateMachine.apply(claudeNotification("permission_prompt"), to: s)
        s = PaneStateMachine.apply(makeEvent(.postToolUseFailure, toolName: "Bash"), to: s)
        XCTAssertEqual(s.state, .thinking)
        XCTAssertFalse(s.needsAttention)
        XCTAssertNil(s.notificationReason)
        XCTAssertTrue(s.turnOpen)
    }

    func test_claude_idlePrompt_onStalePermissionWait_clearsAttentionKeepsWaiting() {
        var s = empty()
        s.state = .thinking
        s.turnOpen = true
        s = PaneStateMachine.apply(claudeNotification("permission_prompt"), to: s)
        let entered = s.enteredStateAt
        let after = PaneStateMachine.apply(claudeNotification("idle_prompt"), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertFalse(after.needsAttention)
        XCTAssertNil(after.notificationReason)
        XCTAssertFalse(after.turnOpen)
        XCTAssertFalse(after.isMidTurn)
        XCTAssertEqual(after.enteredStateAt, entered)
    }

    func test_claude_elicitationDialog_waitsThenPostToolUseRecovers() {
        var s = empty()
        s.state = .thinking
        s = PaneStateMachine.apply(claudeNotification("elicitation_dialog"), to: s)
        XCTAssertEqual(s.state, .waiting)
        XCTAssertEqual(s.notificationReason, "mcp_elicit")
        s = PaneStateMachine.apply(makeEvent(.postToolUse, toolName: "mcp__x"), to: s)
        XCTAssertEqual(s.state, .thinking)
        XCTAssertFalse(s.needsAttention)
    }

    func test_notification_authSuccess_whileIdle_preservesIdle() {
        var s = empty()
        s.state = .idle
        let after = PaneStateMachine.apply(makeEvent(.notification, reason: "auth_success"), to: s)
        // auth_success is not a blocking reason — it doesn't gate Claude on
        // the user, so the state should stay IDLE. needsAttention still flips
        // on for the dock-badge overlay.
        XCTAssertEqual(after.state, .idle)
        XCTAssertTrue(after.needsAttention)
    }

    func test_userPromptSubmit_clearsAttention() {
        var s = empty()
        s.state = .waiting
        s.needsAttention = true
        s.notificationReason = "permission"
        let after = PaneStateMachine.apply(makeEvent(.userPromptSubmit, prompt: "go"), to: s)
        XCTAssertFalse(after.needsAttention)
        XCTAssertNil(after.notificationReason)
    }

    // MARK: - Session-id reset

    func test_newSessionId_resetsState() {
        var s = empty()
        s.state = .waiting
        s.lastSessionId = "old"
        s.needsAttention = true
        let after = PaneStateMachine.apply(makeEvent(.sessionStart, session: "new"), to: s)
        // SessionStart on a (now-reset) INIT pane promotes to IDLE per the
        // refined state machine, but regardless: it must NOT preserve
        // WAITING across sessions.
        XCTAssertNotEqual(after.state, .waiting)
        XCTAssertFalse(after.needsAttention)
        XCTAssertEqual(after.lastSessionId, "new")
    }

    // MARK: - Informational events are no-ops for state

    func test_preToolUse_regularTool_doesNotChangeState() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(makeEvent(.preToolUse, toolName: "Bash"), to: s)
        XCTAssertEqual(after.state, .thinking)
    }

    func test_postToolUse_regularTool_doesNotChangeState() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(makeEvent(.postToolUse, toolName: "Bash"), to: s)
        XCTAssertEqual(after.state, .thinking)
    }

    func test_preToolUse_askUserQuestion_flipsToWaiting() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(
            makeEvent(.preToolUse, toolName: "AskUserQuestion"),
            to: s
        )
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "ask_user_question")
    }

    func test_postToolUse_askUserQuestion_resumesThinking() {
        // Claude path — entry sets notificationReason but NOT waitSource (which
        // is reserved for Codex). Recovery must therefore match on either key.
        var s = empty()
        s.state = .waiting
        s.needsAttention = true
        s.notificationReason = "ask_user_question"
        let after = PaneStateMachine.apply(
            makeEvent(.postToolUse, toolName: "AskUserQuestion"),
            to: s
        )
        XCTAssertEqual(after.state, .thinking)
        XCTAssertFalse(after.needsAttention)
        XCTAssertNil(after.notificationReason)
        XCTAssertNil(after.waitSource)
    }

    func test_claudeStop_doesNotSetWaitSource() {
        // waitSource is Codex-only — a Claude Stop must not tag the WAIT
        // with .turnEnd, otherwise Notifier reads it as Codex and mis-attributes
        // the banner copy.
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(
            makeEvent(.stop, last: "ok"),
            to: s
        )
        XCTAssertEqual(after.state, .waiting)
        XCTAssertNil(after.waitSource)
        XCTAssertEqual(after.lastAssistantMessage, "ok")
    }

    func test_claudePreToolUseAskUserQuestion_doesNotSetWaitSource() {
        // Same gating rationale as Stop — Claude AskUserQuestion uses the
        // legacy notificationReason path, never waitSource.
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(
            makeEvent(.preToolUse, toolName: "AskUserQuestion"),
            to: s
        )
        XCTAssertEqual(after.state, .waiting)
        XCTAssertNil(after.waitSource)
        XCTAssertEqual(after.notificationReason, "ask_user_question")
        XCTAssertTrue(after.needsAttention)
    }

    func test_subagentStop_doesNotChangeState() {
        var s = empty()
        s.state = .thinking
        let after = PaneStateMachine.apply(makeEvent(.subagentStop), to: s)
        XCTAssertEqual(after.state, .thinking)
    }

    // MARK: - Timestamps advance

    func test_enteredStateAt_updatesOnTransition() {
        let s = empty()
        let t0 = s.enteredStateAt
        // Sleep briefly to ensure Date resolution advances
        Thread.sleep(forTimeInterval: 0.01)
        let after = PaneStateMachine.apply(makeEvent(.userPromptSubmit, prompt: "x"), to: s)
        XCTAssertGreaterThan(after.enteredStateAt, t0)
    }

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

    // MARK: - Agent switch

    private func claudeSession(_ id: String) -> PaneSnapshot {
        var s = empty()
        s.state = .idle
        s.lastSessionId = id
        return s
    }

    func test_agentKindChange_clearsLastSessionId() {
        // claude exited, codex started with hooks off: only the
        // ForegroundProcessWatcher's synthetic SessionStart (no id) arrives.
        let after = PaneStateMachine.apply(codexEvent(.sessionStart, session: nil), to: claudeSession("claude-1"))
        XCTAssertEqual(after.agentKind, .codex)
        XCTAssertNil(after.lastSessionId)
    }

    func test_sameAgentKind_keepsLastSessionId() {
        let after = PaneStateMachine.apply(makeEvent(.sessionStart, session: nil), to: claudeSession("claude-1"))
        XCTAssertEqual(after.agentKind, .claude)
        XCTAssertEqual(after.lastSessionId, "claude-1")
    }

    func test_agentSwitch_thenCodexEventWithOwnId_endsWithNewId() {
        let switched = PaneStateMachine.apply(codexEvent(.sessionStart, session: nil), to: claudeSession("claude-1"))
        let after = PaneStateMachine.apply(codexEvent(.userPromptSubmit, session: "codex-1"), to: switched)
        XCTAssertEqual(after.lastSessionId, "codex-1")
    }

    func test_agentSwitch_eventCarryingNewId_endsWithNewId() {
        let after = PaneStateMachine.apply(codexEvent(.sessionStart, session: "codex-1"), to: claudeSession("claude-1"))
        XCTAssertEqual(after.agentKind, .codex)
        XCTAssertEqual(after.lastSessionId, "codex-1")
    }
}

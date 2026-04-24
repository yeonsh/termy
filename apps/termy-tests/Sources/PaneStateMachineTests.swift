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
        toolName: String? = nil
    ) -> HookEvent {
        var meta = HookEvent.Meta()
        meta.sessionId = session
        meta.exitCode = exitCode
        meta.prompt = prompt
        meta.lastAssistantMessage = last
        meta.reason = reason
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

    func test_notification_idleReminder_whileIdle_flipsToWaiting() {
        var s = empty()
        s.state = .idle
        let after = PaneStateMachine.apply(makeEvent(.notification, reason: "idle"), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
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
}

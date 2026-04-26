// AgentKindTests.swift
//
// Phase 0 coverage for the AgentKind enum, the new `permissionRequest` hook
// event case, and the `agentKind` field on PaneSnapshot. These tests pin
// down the type surface — Phase 1+ will add the behavior tests.

import XCTest
@testable import termy

final class AgentKindTests: XCTestCase {

    // MARK: - Wire mapping

    func test_from_claudeCode_returnsClaude() {
        XCTAssertEqual(AgentKind.from(rawAgent: "claude-code"), .claude)
    }

    func test_from_codex_returnsCodex() {
        XCTAssertEqual(AgentKind.from(rawAgent: "codex"), .codex)
    }

    func test_from_termy_returnsNil() {
        // Synthetic events leave kind unresolved — daemon inherits from snapshot.
        XCTAssertNil(AgentKind.from(rawAgent: "termy"))
    }

    func test_from_unknown_returnsNil() {
        XCTAssertNil(AgentKind.from(rawAgent: "aider"))
    }

    // MARK: - HookEvent

    func test_hookEvent_decodesPermissionRequest() throws {
        let json = """
        {
          "event": "PermissionRequest",
          "pane_id": "p1",
          "project_id": "proj",
          "ts": 1.0,
          "agent": "codex",
          "meta": { "tool_name": "Bash" }
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.event, .permissionRequest)
        XCTAssertEqual(event.agentKind, .codex)
        XCTAssertEqual(event.meta.toolName, "Bash")
    }

    func test_hookEvent_agentKindFromClaudeCode() throws {
        let json = """
        {
          "event": "Stop",
          "pane_id": "p1",
          "project_id": null,
          "ts": 1.0,
          "agent": "claude-code",
          "meta": {}
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.agentKind, .claude)
    }

    func test_hookEvent_syntheticAgent_resolvesNil() throws {
        // PtyExit and other synthetic events use agent="termy"; the daemon
        // should keep the pane's prior kind rather than coerce.
        let json = """
        {
          "event": "PtyExit",
          "pane_id": "p1",
          "project_id": null,
          "ts": 1.0,
          "agent": "termy",
          "meta": { "exit_code": 0 }
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertNil(event.agentKind)
    }

    // MARK: - PaneSnapshot

    func test_emptySnapshot_defaultsToClaude() {
        let s = PaneSnapshot.empty(paneId: "p1", projectId: nil)
        XCTAssertEqual(s.agentKind, .claude)
    }

    func test_emptySnapshot_acceptsCodex() {
        let s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        XCTAssertEqual(s.agentKind, .codex)
    }

    func test_paneSnapshot_roundTripsAgentKind() throws {
        let original = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: data)
        XCTAssertEqual(decoded.agentKind, .codex)
    }

    // MARK: - PaneStateMachine — agentKind tracking

    func test_anyEvent_stampsAgentKindOnSnapshot() {
        let s = PaneSnapshot.empty(paneId: "p1", projectId: nil) // defaults to .claude
        let event = HookEvent(
            event: .sessionStart,
            paneId: "p1",
            projectId: nil,
            ts: 1.0,
            agent: "codex",
            meta: HookEvent.Meta()
        )
        let after = PaneStateMachine.apply(event, to: s)
        XCTAssertEqual(after.agentKind, .codex)
    }

    func test_syntheticEvent_preservesAgentKind() {
        // Synthetic events use agent="termy" → agentKind nil → don't reset.
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        s.state = .thinking
        let event = HookEvent(
            event: .ptyExit,
            paneId: "p1",
            projectId: nil,
            ts: 1.0,
            agent: "termy",
            meta: { var m = HookEvent.Meta(); m.exitCode = 0; return m }()
        )
        let after = PaneStateMachine.apply(event, to: s)
        XCTAssertEqual(after.agentKind, .codex)
    }

    // MARK: - PaneStateMachine — permissionRequest

    func test_permissionRequest_fromThinking_toWaiting() {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        s.state = .thinking
        let after = PaneStateMachine.apply(makePermissionRequest(), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "permission")
    }

    func test_permissionRequest_fromIdle_alsoFlipsToWaiting() {
        // Drift correction: 30s timer flipped pane to IDLE while permission
        // was outstanding. PermissionRequest snaps it back to WAIT.
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        s.state = .idle
        let after = PaneStateMachine.apply(makePermissionRequest(), to: s)
        XCTAssertEqual(after.state, .waiting)
    }

    func test_permissionRequest_fromInit_flipsToWaiting() {
        // First command from a fresh codex pane that triggers a sandbox
        // escalation immediately.
        let s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        let after = PaneStateMachine.apply(makePermissionRequest(), to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
    }

    func test_codexPostToolUse_afterPermissionRequest_resumesThinking() {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        s.state = .waiting
        s.needsAttention = true
        s.notificationReason = "permission"
        let after = PaneStateMachine.apply(makeCodexPostToolUse(), to: s)
        XCTAssertEqual(after.state, .thinking)
        XCTAssertFalse(after.needsAttention)
        XCTAssertNil(after.notificationReason)
    }

    func test_claudePostToolUse_afterPermissionNotification_preservesWaiting() {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .claude)
        s.state = .waiting
        s.needsAttention = true
        s.notificationReason = "permission"
        let event = HookEvent(
            event: .postToolUse,
            paneId: "p1",
            projectId: nil,
            ts: 1.0,
            agent: "claude-code",
            meta: { var m = HookEvent.Meta(); m.toolName = "Bash"; return m }()
        )
        let after = PaneStateMachine.apply(event, to: s)
        XCTAssertEqual(after.state, .waiting)
        XCTAssertTrue(after.needsAttention)
        XCTAssertEqual(after.notificationReason, "permission")
    }

    // MARK: - PaneStateMachine — SessionStart branching

    func test_codexSessionStart_resetsFromAnyState() {
        // Codex has no SessionEnd hook event; SessionStart must clear stale
        // state from the prior session unconditionally.
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .codex)
        s.state = .thinking
        s.needsAttention = true
        s.notificationReason = "permission"
        let event = HookEvent(
            event: .sessionStart,
            paneId: "p1",
            projectId: nil,
            ts: 1.0,
            agent: "codex",
            meta: HookEvent.Meta()
        )
        let after = PaneStateMachine.apply(event, to: s)
        XCTAssertEqual(after.state, .idle)
        XCTAssertFalse(after.needsAttention)
        XCTAssertNil(after.notificationReason)
    }

    func test_claudeSessionStart_preservesNonInitState() {
        // Regression coverage — Claude Code's SessionStart fires on every
        // resume; flipping THINK to IDLE there would cause chip flicker.
        var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .claude)
        s.state = .thinking
        let event = HookEvent(
            event: .sessionStart,
            paneId: "p1",
            projectId: nil,
            ts: 1.0,
            agent: "claude-code",
            meta: HookEvent.Meta()
        )
        let after = PaneStateMachine.apply(event, to: s)
        XCTAssertEqual(after.state, .thinking)
    }

    // MARK: - Helpers

    private func makePermissionRequest() -> HookEvent {
        var meta = HookEvent.Meta()
        meta.toolName = "Bash"
        return HookEvent(
            event: .permissionRequest,
            paneId: "p1",
            projectId: nil,
            ts: 1.0,
            agent: "codex",
            meta: meta
        )
    }

    private func makeCodexPostToolUse() -> HookEvent {
        var meta = HookEvent.Meta()
        meta.toolName = "Bash"
        meta.toolUseId = "tool-1"
        return HookEvent(
            event: .postToolUse,
            paneId: "p1",
            projectId: nil,
            ts: 1.0,
            agent: "codex",
            meta: meta
        )
    }
}

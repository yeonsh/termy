import XCTest
@testable import termy

final class PaneProgramStatusTests: XCTestCase {
    private func base() -> PaneSnapshot { .empty(paneId: "P", projectId: "app", agentKind: .claude) }
    private func st(_ s: String, kind: String? = nil) -> HcStatus { HcStatus(state: s, kind: kind, msg: nil, app: "claude-code") }
    private func obs(_ s: PaneSnapshot) -> WaitAlertRule.Observation { .init(state: s.state, sessionId: nil) }
    private func hook(_ kind: HookEventKind, _ edit: (inout HookEvent.Meta) -> Void = { _ in }) -> HookEvent {
        var m = HookEvent.Meta(); edit(&m)
        return HookEvent(event: kind, paneId: "P", projectId: "app", ts: 1, agent: kind == .ptyExit || kind == .sessionEnd ? "termy" : "claude-code", meta: m)
    }

    func testWorkingThinks() {
        let n = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: Date())
        XCTAssertEqual(n.state, .thinking); XCTAssertTrue(n.turnOpen); XCTAssertTrue(n.programStatusActive)
    }
    func testBlockedQuestionWaitsForAnswer() {
        let n = PaneStateMachine.applyProgramStatus(st("blocked", kind: "question"), to: base(), now: Date())
        XCTAssertEqual(n.state, .waiting); XCTAssertEqual(n.waitSource, .askUserQuestion); XCTAssertTrue(n.needsAttention)
    }
    func testBlockedAuthUsesPermissionWithReason() {
        let n = PaneStateMachine.applyProgramStatus(st("blocked", kind: "auth"), to: base(), now: Date())
        XCTAssertEqual(n.waitSource, .permission); XCTAssertEqual(n.notificationReason, "auth")
    }
    func testKindlessBlockedIsPermission() {
        let n = PaneStateMachine.applyProgramStatus(st("blocked"), to: base(), now: Date())
        XCTAssertEqual(n.state, .waiting); XCTAssertEqual(n.waitSource, .permission); XCTAssertEqual(n.notificationReason, "permission")
    }
    func testDoneEndsTurn() {
        var p = base(); p.turnOpen = true
        let n = PaneStateMachine.applyProgramStatus(st("done"), to: p, now: Date())
        XCTAssertEqual(n.state, .waiting); XCTAssertEqual(n.waitSource, .turnEnd); XCTAssertFalse(n.turnOpen)
    }
    func testErrorErrors() {
        let n = PaneStateMachine.applyProgramStatus(st("error"), to: base(), now: Date())
        XCTAssertEqual(n.state, .errored); XCTAssertFalse(n.turnOpen)
    }
    func testUnknownStateKeepsState() {
        let w = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: Date())
        let n = PaneStateMachine.applyProgramStatus(st("weird"), to: w, now: Date())
        XCTAssertEqual(n.state, .thinking); XCTAssertTrue(n.programStatusActive)
    }
    func testIdleAfterWorkingIsSilentIdle() {
        let working = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: Date(timeIntervalSince1970: 1000))
        let idle1 = PaneStateMachine.applyProgramStatus(st("idle"), to: working, now: Date(timeIntervalSince1970: 1001))
        let idle2 = PaneStateMachine.applyProgramStatus(st("idle"), to: idle1, now: Date(timeIntervalSince1970: 1060))
        XCTAssertEqual(idle1.state, .idle)
        XCTAssertFalse(idle1.turnOpen)
        XCTAssertFalse(idle1.needsAttention)
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(working), next: obs(idle1)))
        XCTAssertEqual(idle2.state, .idle)
        XCTAssertEqual(idle2.enteredStateAt, idle1.enteredStateAt)
    }
    func testIdleWhileBlockedIsSilentIdle() {
        let blocked = PaneStateMachine.applyProgramStatus(st("blocked", kind: "permission"), to: base(), now: Date())
        let n = PaneStateMachine.applyProgramStatus(st("idle"), to: blocked, now: Date())
        XCTAssertEqual(n.state, .idle)
        XCTAssertFalse(n.needsAttention)
        XCTAssertNil(n.notificationReason)
        XCTAssertNil(n.waitSource)
        XCTAssertFalse(n.turnOpen)
    }
    func testIdleWithoutTurnIsIdle() {
        let n = PaneStateMachine.applyProgramStatus(st("idle"), to: base(), now: Date())
        XCTAssertEqual(n.state, .idle)
    }
    func testNilStatusHandsBackToHooks() {
        let a = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: Date())
        let n = PaneStateMachine.applyProgramStatus(nil, to: a, now: Date())
        XCTAssertFalse(n.programStatusActive); XCTAssertEqual(n.state, .thinking)
    }
    func testHookUpdatesDetailsOnlyWhileActive() {
        var p = base(); p.state = .idle; p.programStatusActive = true
        let n = PaneStateMachine.apply(hook(.userPromptSubmit) { $0.prompt = "hi" }, to: p)
        XCTAssertEqual(n.state, .idle); XCTAssertEqual(n.lastPrompt, "hi"); XCTAssertTrue(n.programStatusActive)
        XCTAssertFalse(n.turnOpen)
    }
    func testPtyExitAppliesWhileProgramStatusActive() {
        var p = base(); p.state = .thinking; p.programStatusActive = true
        let n = PaneStateMachine.apply(hook(.ptyExit) { $0.exitCode = 1 }, to: p)
        XCTAssertEqual(n.state, .errored); XCTAssertFalse(n.programStatusActive)
    }
    func testExitSequenceEndsNotThinking() {
        let w = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: Date())
        let off = PaneStateMachine.applyProgramStatus(nil, to: w, now: Date())
        XCTAssertEqual(off.state, .thinking)
        let end = PaneStateMachine.apply(hook(.sessionEnd), to: off)
        XCTAssertNotEqual(end.state, .thinking)
    }
    func testResentStatusDoesNotReAlert() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = PaneStateMachine.applyProgramStatus(st("blocked", kind: "permission"), to: base(), now: t0)
        let b = PaneStateMachine.applyProgramStatus(st("blocked", kind: "permission"), to: a, now: t0.addingTimeInterval(60))
        XCTAssertEqual(b.enteredStateAt, a.enteredStateAt)
        XCTAssertEqual(b.state, a.state)
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(a), next: obs(b)))
    }

    func testWorkingThenDoneAlerts() {
        let w = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: Date())
        let d = PaneStateMachine.applyProgramStatus(st("done"), to: w, now: Date())
        XCTAssertEqual(d.state, .waiting); XCTAssertEqual(d.waitSource, .turnEnd)
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(w), next: obs(d)))
    }
    func testDoneOnIdleWithoutTurnStaysIdle() {
        var p = base(); p.state = .idle; p.turnOpen = false
        let n = PaneStateMachine.applyProgramStatus(st("done"), to: p, now: Date())
        XCTAssertEqual(n.state, .idle)
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(p), next: obs(n)))
    }
    func testResentDoneOnWaitingTurnEndUnchanged() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let w = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: t0)
        let d1 = PaneStateMachine.applyProgramStatus(st("done"), to: w, now: t0)
        let d2 = PaneStateMachine.applyProgramStatus(st("done"), to: d1, now: t0.addingTimeInterval(90))
        XCTAssertEqual(d2.enteredStateAt, d1.enteredStateAt)
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(d1), next: obs(d2)))
    }
    func testResentIdleOnIdleNoChange() {
        let a = PaneStateMachine.applyProgramStatus(st("idle"), to: base(), now: Date(timeIntervalSince1970: 1000))
        let b = PaneStateMachine.applyProgramStatus(st("idle"), to: a, now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(b.state, .idle); XCTAssertEqual(b.enteredStateAt, a.enteredStateAt)
    }
    func testReconcilerSkipsActiveProgramStatus() {
        var p = PaneSnapshot.empty(paneId: "P", projectId: "app", agentKind: .codex)
        p.state = .thinking
        let now = p.updatedAt.addingTimeInterval(60)
        XCTAssertNotNil(CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(p, now: now, silenceThreshold: 8))
        p.programStatusActive = true
        XCTAssertNil(CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(p, now: now, silenceThreshold: 8))
    }
}

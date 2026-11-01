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
    func testIdleAfterWorkingEndsTurnOnce() {
        let working = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: Date())
        let idle1 = PaneStateMachine.applyProgramStatus(st("idle"), to: working, now: Date())
        let idle2 = PaneStateMachine.applyProgramStatus(st("idle"), to: idle1, now: Date())
        XCTAssertEqual(idle1.state, .waiting); XCTAssertEqual(idle2.state, .waiting)
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(working), next: obs(idle1)))
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(idle1), next: obs(idle2)))
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
}

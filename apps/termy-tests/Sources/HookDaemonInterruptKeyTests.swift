// HookDaemonInterruptKeyTests.swift
//
// recordInterruptKey closes an open THINK turn to a silent IDLE for agents that
// send no hook on interrupt, and leaves every other pane untouched.

import XCTest
@testable import termy

final class HookDaemonInterruptKeyTests: XCTestCase {

    private func make(
        _ kind: AgentKind = .codex,
        state: PaneState = .thinking,
        turnOpen: Bool = true,
        programStatusActive: Bool = false,
        waitSource: WaitSource? = nil,
        attention: Bool = false,
        reason: String? = nil
    ) async -> HookDaemon {
        let daemon = HookDaemon.testInstance()
        _ = await daemon.injectSnapshot {
            var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: kind)
            s.state = state
            s.turnOpen = turnOpen
            s.programStatusActive = programStatusActive
            s.waitSource = waitSource
            s.needsAttention = attention
            s.notificationReason = reason
            return s
        }
        return daemon
    }

    private func assertUnchanged(_ daemon: HookDaemon, state: PaneState, file: StaticString = #filePath, line: UInt = #line) async {
        await daemon.recordInterruptKey(paneId: "p1")
        let after = await daemon.snapshot(paneId: "p1")
        XCTAssertEqual(after?.state, state, file: file, line: line)
        XCTAssertEqual(after?.interruptedByKey, false, file: file, line: line)
    }

    func test_interruptKey_closesOpenThinkingTurn() async {
        let daemon = await make()
        await daemon.recordInterruptKey(paneId: "p1")
        let after = await daemon.snapshot(paneId: "p1")
        XCTAssertEqual(after?.state, .idle)
        XCTAssertEqual(after?.turnOpen, false)
        XCTAssertEqual(after?.interruptedByKey, true)
        XCTAssertEqual(after?.needsAttention, false)
    }

    func test_interruptKey_closesPossiblyWaitingAndPromotedWait() async {
        let d1 = await make(state: .possiblyWaiting)
        await d1.recordInterruptKey(paneId: "p1")
        let a1 = await d1.snapshot(paneId: "p1")
        XCTAssertEqual(a1?.state, .idle)
        XCTAssertEqual(a1?.interruptedByKey, true)

        let d2 = await make(state: .waiting, waitSource: .promotedFromPossible, attention: true)
        await d2.recordInterruptKey(paneId: "p1")
        let a2 = await d2.snapshot(paneId: "p1")
        XCTAssertEqual(a2?.state, .idle)
        XCTAssertEqual(a2?.needsAttention, false)
        XCTAssertNil(a2?.waitSource)
        XCTAssertEqual(a2?.interruptedByKey, true)
    }

    func test_interruptKey_ignoredWhileProgramStatusActive() async {
        let daemon = await make(.claude, programStatusActive: true)
        await assertUnchanged(daemon, state: .thinking)
    }

    func test_interruptKey_ignoredForOpencodeAndPi() async {
        let d1 = await make(.opencode)
        await assertUnchanged(d1, state: .thinking)
        let d2 = await make(.pi)
        await assertUnchanged(d2, state: .thinking)
    }

    func test_interruptKey_noopOutsideOpenThinkingTurn() async {
        await assertUnchanged(await make(state: .idle, turnOpen: false), state: .idle)
        await assertUnchanged(await make(state: .initializing, turnOpen: false), state: .initializing)
        await assertUnchanged(
            await make(state: .waiting, waitSource: .permission, attention: true, reason: "permission"),
            state: .waiting)
        await assertUnchanged(await make(state: .thinking, turnOpen: false), state: .thinking)
    }
}

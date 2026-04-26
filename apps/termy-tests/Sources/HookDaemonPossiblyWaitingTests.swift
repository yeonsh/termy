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

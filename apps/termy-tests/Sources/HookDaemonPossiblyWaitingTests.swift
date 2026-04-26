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
}

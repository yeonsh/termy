// HookDaemonSeenTests.swift
//
// A turn-end WAIT turns IDLE 30s after the user has seen the pane, never
// while it is unseen.

import XCTest
@testable import termy

final class HookDaemonSeenTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeDaemon(entered: Date, attention: Bool = false) async -> HookDaemon {
        let daemon = HookDaemon.testInstance()
        let t = entered
        _ = await daemon.injectSnapshot {
            var s = PaneSnapshot.empty(paneId: "p1", projectId: nil, agentKind: .claude)
            s.state = .waiting
            s.waitSource = .turnEnd
            s.needsAttention = attention
            s.enteredStateAt = t
            return s
        }
        return daemon
    }

    private func state(_ d: HookDaemon) async -> PaneState? {
        await d.snapshot(paneId: "p1")?.state
    }

    func test_unseenTurnEndWait_staysWaiting() async {
        let d = await makeDaemon(entered: t0)
        await d.tickIdle(now: t0.addingTimeInterval(60))
        let s = await state(d)
        XCTAssertEqual(s, .waiting)
    }

    func test_waitEnteredWhileViewed_idlesAfter30s() async {
        let d = await makeDaemon(entered: t0)
        await d.setViewedPane("p1", now: t0.addingTimeInterval(-10))
        await d.tickIdle(now: t0.addingTimeInterval(29))
        let early = await state(d)
        XCTAssertEqual(early, .waiting)
        await d.tickIdle(now: t0.addingTimeInterval(31))
        let late = await state(d)
        XCTAssertEqual(late, .idle)
    }

    func test_viewingLater_startsCountdownFromView() async {
        let d = await makeDaemon(entered: t0)
        await d.setViewedPane("p1", now: t0.addingTimeInterval(100))
        await d.tickIdle(now: t0.addingTimeInterval(125))
        let early = await state(d)
        XCTAssertEqual(early, .waiting)
        await d.tickIdle(now: t0.addingTimeInterval(131))
        let late = await state(d)
        XCTAssertEqual(late, .idle)
    }

    func test_leavingViewedPane_startsCountdownFromLeave() async {
        let d = await makeDaemon(entered: t0)
        await d.setViewedPane("p1", now: t0.addingTimeInterval(-20))
        await d.setViewedPane(nil, now: t0.addingTimeInterval(5))
        await d.tickIdle(now: t0.addingTimeInterval(36))
        let s = await state(d)
        XCTAssertEqual(s, .idle)
    }

    func test_attentionWait_neverIdles() async {
        let d = await makeDaemon(entered: t0, attention: true)
        await d.setViewedPane("p1", now: t0.addingTimeInterval(-10))
        await d.tickIdle(now: t0.addingTimeInterval(60))
        let s = await state(d)
        XCTAssertEqual(s, .waiting)
    }

    func test_sleepWakeGuard_kept() async {
        let d = await makeDaemon(entered: t0)
        await d.setViewedPane("p1", now: t0.addingTimeInterval(-10))
        await d.tickIdle(now: t0.addingTimeInterval(500))
        let s = await state(d)
        XCTAssertEqual(s, .waiting)
    }
}

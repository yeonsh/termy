// NotifierWaitAlertRuleTests.swift
//
// Pure decision for whether entering WAITING should play a sound, bounce the
// dock, and post a banner.
//
// protects=WAIT-entry, session-switch, and first-event alerting;
// fails_when=a session switch alerts or a same-session WAIT entry stays silent;
// no_claim=the actual sound/banner (E2E M2–M4, M9).

import XCTest
@testable import termy

final class NotifierWaitAlertRuleTests: XCTestCase {
    private func obs(_ state: PaneState, _ session: String?) -> WaitAlertRule.Observation {
        WaitAlertRule.Observation(state: state, sessionId: session)
    }

    func test_enteringWaitInSameSession_alerts() {
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(.thinking, "s1"), next: obs(.waiting, "s1")))
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(.idle, "s1"), next: obs(.waiting, "s1")))
    }

    func test_stayingInWait_doesNotAlert() {
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(.waiting, "s1"), next: obs(.waiting, "s1")))
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(.thinking, "s1"), next: obs(.thinking, "s1")))
    }

    // protects=a tab/session switch onto a waiting session stays silent whatever the prior state;
    // fails_when=IDLE(A) → WAIT(B) or WAIT(A) → WAIT(B) alerts
    func test_waitReachedBySwitchingSessions_doesNotAlert() {
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(.idle, "s1"), next: obs(.waiting, "s2")))
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(.thinking, "s1"), next: obs(.waiting, "s2")))
        XCTAssertFalse(WaitAlertRule.shouldAlert(previous: obs(.waiting, "s1"), next: obs(.waiting, "s2")))
    }

    func test_firstObservationOrUnknownSession_alerts() {
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: nil, next: obs(.waiting, "s1")))
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(.initializing, nil), next: obs(.waiting, "s1")))
        XCTAssertTrue(WaitAlertRule.shouldAlert(previous: obs(.thinking, "s1"), next: obs(.waiting, nil)))
    }
}

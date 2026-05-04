// MissionControlDashboardShapeTests.swift
//
// Pins the contract that protects the SwiftUI graph from timestamp-only
// hook updates: `MissionControlModel.haveSameDashboardShape` must ignore
// fields the chip view doesn't render (timestamps, session/prompt history)
// and must flip on fields it does (state, needsAttention, waitSource,
// labels). Without this, every PTY chunk / hook event re-assigned `items`
// on the @Observable model and forced a full re-measure of the bar.

import XCTest
@testable import termy

final class MissionControlDashboardShapeTests: XCTestCase {

    private func snapshot(
        paneId: String = "pane-1",
        projectId: String? = "api",
        state: PaneState = .idle,
        needsAttention: Bool = false,
        notificationReason: String? = nil,
        waitSource: WaitSource? = nil,
        lastSessionId: String? = "sess-1",
        lastCwd: String? = "/x",
        lastPrompt: String? = nil,
        lastAssistantMessage: String? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000),
        enteredStateAt: Date = Date(timeIntervalSince1970: 1_000),
        agentKind: AgentKind = .claude,
        lastPtyActivityAt: Date? = nil
    ) -> PaneSnapshot {
        PaneSnapshot(
            paneId: paneId,
            projectId: projectId,
            state: state,
            needsAttention: needsAttention,
            notificationReason: notificationReason,
            waitSource: waitSource,
            lastSessionId: lastSessionId,
            lastCwd: lastCwd,
            lastPrompt: lastPrompt,
            lastAssistantMessage: lastAssistantMessage,
            updatedAt: updatedAt,
            enteredStateAt: enteredStateAt,
            agentKind: agentKind,
            lastPtyActivityAt: lastPtyActivityAt
        )
    }

    // MARK: - Ignored fields (timestamp / history)

    func test_timestampOnlyChange_isSameShape() {
        let a = snapshot()
        let b = snapshot(
            updatedAt: Date(timeIntervalSince1970: 9_999),
            enteredStateAt: Date(timeIntervalSince1970: 9_999),
            lastPtyActivityAt: Date(timeIntervalSince1970: 9_999)
        )
        XCTAssertTrue(MissionControlModel.sameDashboardShape(a, b))
    }

    func test_sessionAndTranscriptChange_isSameShape() {
        let a = snapshot(
            lastSessionId: "sess-1",
            lastPrompt: "old prompt",
            lastAssistantMessage: "old reply"
        )
        let b = snapshot(
            lastSessionId: "sess-2",
            lastPrompt: "new prompt",
            lastAssistantMessage: "new reply"
        )
        XCTAssertTrue(MissionControlModel.sameDashboardShape(a, b))
    }

    // MARK: - Visible fields

    func test_stateChange_flipsShape() {
        let a = snapshot(state: .thinking)
        let b = snapshot(state: .waiting)
        XCTAssertFalse(MissionControlModel.sameDashboardShape(a, b))
    }

    func test_needsAttentionChange_flipsShape() {
        let a = snapshot(needsAttention: false)
        let b = snapshot(needsAttention: true)
        XCTAssertFalse(MissionControlModel.sameDashboardShape(a, b))
    }

    func test_waitSourceChange_flipsShape() {
        let a = snapshot(state: .waiting, waitSource: .askUserQuestion)
        let b = snapshot(state: .waiting, waitSource: .turnEnd)
        XCTAssertFalse(MissionControlModel.sameDashboardShape(a, b))
    }

    func test_notificationReasonChange_flipsShape() {
        let a = snapshot(notificationReason: nil)
        let b = snapshot(notificationReason: "permission")
        XCTAssertFalse(MissionControlModel.sameDashboardShape(a, b))
    }

    func test_projectIdChange_flipsShape() {
        let a = snapshot(projectId: "api")
        let b = snapshot(projectId: "web")
        XCTAssertFalse(MissionControlModel.sameDashboardShape(a, b))
    }

    func test_lastCwdChange_flipsShape() {
        let a = snapshot(lastCwd: "/repo/api")
        let b = snapshot(lastCwd: "/repo/web")
        XCTAssertFalse(MissionControlModel.sameDashboardShape(a, b))
    }

    func test_agentKindChange_flipsShape() {
        let a = snapshot(agentKind: .claude)
        let b = snapshot(agentKind: .codex)
        XCTAssertFalse(MissionControlModel.sameDashboardShape(a, b))
    }

    // MARK: - Array-level

    func test_arrays_differentLength_areNotSameShape() {
        let a = [snapshot(paneId: "p1"), snapshot(paneId: "p2")]
        let b = [snapshot(paneId: "p1")]
        XCTAssertFalse(MissionControlModel.haveSameDashboardShape(a, b))
    }

    func test_arrays_sameVisibleShape_butDifferentTimestamps_areSameShape() {
        let a = [
            snapshot(paneId: "p1", updatedAt: Date(timeIntervalSince1970: 1)),
            snapshot(paneId: "p2", updatedAt: Date(timeIntervalSince1970: 1))
        ]
        let b = [
            snapshot(paneId: "p1", updatedAt: Date(timeIntervalSince1970: 999)),
            snapshot(paneId: "p2", updatedAt: Date(timeIntervalSince1970: 999))
        ]
        XCTAssertTrue(MissionControlModel.haveSameDashboardShape(a, b))
    }

    func test_arrays_oneVisibleFieldFlipped_areNotSameShape() {
        let a = [
            snapshot(paneId: "p1", state: .thinking),
            snapshot(paneId: "p2", state: .idle)
        ]
        let b = [
            snapshot(paneId: "p1", state: .thinking),
            snapshot(paneId: "p2", state: .waiting)
        ]
        XCTAssertFalse(MissionControlModel.haveSameDashboardShape(a, b))
    }
}

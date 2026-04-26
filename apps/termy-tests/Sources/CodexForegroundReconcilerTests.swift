import XCTest
@testable import termy

final class CodexForegroundReconcilerTests: XCTestCase {
    private func snapshot(
        state: PaneState = .thinking,
        agentKind: AgentKind = .codex,
        needsAttention: Bool = false,
        updatedAt: Date
    ) -> PaneSnapshot {
        var snapshot = PaneSnapshot.empty(
            paneId: "p1",
            projectId: "proj",
            agentKind: agentKind
        )
        snapshot.state = state
        snapshot.needsAttention = needsAttention
        snapshot.updatedAt = updatedAt
        snapshot.enteredStateAt = updatedAt
        return snapshot
    }

    func test_quietForegroundCodexThinkingPaneBecomesPossiblyWaiting() {
        let updatedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 109)

        let reconciled = CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(
            snapshot(updatedAt: updatedAt),
            now: now,
            silenceThreshold: 8
        )

        XCTAssertEqual(reconciled?.state, .possiblyWaiting)
        XCTAssertNil(reconciled?.waitSource)
        XCTAssertFalse(reconciled?.needsAttention ?? true)
        XCTAssertEqual(reconciled?.updatedAt, now)
        XCTAssertEqual(reconciled?.enteredStateAt, now)
    }

    func test_recentCodexActivityStaysThinking() {
        let updatedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 107)

        let reconciled = CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(
            snapshot(updatedAt: updatedAt),
            now: now,
            silenceThreshold: 8
        )

        XCTAssertNil(reconciled)
    }

    func test_attentionWaitIsNotOverwritten() {
        let updatedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 120)

        let reconciled = CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(
            snapshot(needsAttention: true, updatedAt: updatedAt),
            now: now,
            silenceThreshold: 8
        )

        XCTAssertNil(reconciled)
    }

    func test_claudeThinkingPaneIsIgnored() {
        let updatedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 120)

        let reconciled = CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(
            snapshot(agentKind: .claude, updatedAt: updatedAt),
            now: now,
            silenceThreshold: 8
        )

        XCTAssertNil(reconciled)
    }
}

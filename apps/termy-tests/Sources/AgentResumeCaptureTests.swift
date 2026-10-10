import XCTest
@testable import termy

final class AgentResumeCaptureTests: XCTestCase {
    private func snapshot(
        kind: AgentKind = .claude,
        state: PaneState = .idle,
        sessionId: String? = "sess-1"
    ) -> PaneSnapshot {
        var s = PaneSnapshot.empty(paneId: "p1", projectId: "proj", agentKind: kind)
        s.state = state
        s.lastSessionId = sessionId
        return s
    }

    private func capture(
        agent: AgentKind? = .claude,
        argv: [String]? = ["claude", "--model", "opus", "do it"],
        cwd: String? = "/proj",
        snapshot: PaneSnapshot?
    ) -> AgentResumeRecord? {
        AgentResumeCapture.record(foregroundAgent: agent, argv: argv, processCwd: cwd, snapshot: snapshot)
    }

    func test_liveAgentWithSession_recordsKindIdCwdAndFlags() {
        XCTAssertEqual(
            capture(snapshot: snapshot()),
            AgentResumeRecord(kind: .claude, sessionId: "sess-1", cwd: "/proj", flags: ["--model", "opus"])
        )
    }

    func test_noForegroundAgent_isNil() {
        XCTAssertNil(capture(agent: nil, snapshot: snapshot()))
    }

    func test_noSnapshot_isNil() {
        XCTAssertNil(capture(snapshot: nil))
    }

    func test_noSessionId_isNil() {
        // Hooks not installed: no session id ever arrived.
        XCTAssertNil(capture(snapshot: snapshot(sessionId: nil)))
        XCTAssertNil(capture(snapshot: snapshot(sessionId: "")))
    }

    func test_agentKindMismatch_isNil() {
        // Snapshot still describes an earlier claude; codex is in front now.
        XCTAssertNil(capture(agent: .codex, argv: ["codex"], snapshot: snapshot(kind: .claude)))
    }

    func test_initializingSnapshot_isNil() {
        // The agent's session ended (SessionEnd / PtyExit → INIT).
        XCTAssertNil(capture(snapshot: snapshot(state: .initializing)))
    }

    func test_unreadableArgvAndCwd_stillRecordsSession() {
        XCTAssertEqual(
            capture(argv: nil, cwd: nil, snapshot: snapshot()),
            AgentResumeRecord(kind: .claude, sessionId: "sess-1", cwd: nil, flags: [])
        )
    }
}

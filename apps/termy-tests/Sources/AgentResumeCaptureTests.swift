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

    // The command is typed as keystrokes, so a control character would act
    // as a line-editor key (^U, ^C, ESC …) instead of text.
    func test_sessionIdWithUnsafeCharacters_isNil() {
        XCTAssertNil(capture(snapshot: snapshot(sessionId: "sess 1")))
        XCTAssertNil(capture(snapshot: snapshot(sessionId: "sess\u{15}1")))
    }

    func test_flagWithControlCharacter_dropsAllFlags() {
        XCTAssertEqual(
            capture(
                argv: ["claude", "--dangerously-skip-permissions", "--model", "op\u{1b}us"],
                snapshot: snapshot()
            ),
            AgentResumeRecord(kind: .claude, sessionId: "sess-1", cwd: "/proj", flags: [])
        )
    }

    // MARK: - restorePlan

    private let resumeRecord = AgentResumeRecord(kind: .claude, sessionId: "sess-1", cwd: "/agent", flags: [])

    private func plan(
        paneCwd: String = "/pane",
        resume: AgentResumeRecord?,
        existing: Set<String>
    ) -> (cwd: String, startupInput: String?) {
        AgentResumeCapture.restorePlan(paneCwd: paneCwd, resume: resume, directoryExists: existing.contains)
    }

    func test_restorePlan_agentCwdExists_startsThereWithCommand() {
        let p = plan(resume: resumeRecord, existing: ["/agent", "/pane"])
        XCTAssertEqual(p.cwd, "/agent")
        XCTAssertEqual(p.startupInput, "claude --resume sess-1")
    }

    func test_restorePlan_agentCwdMissing_fallsBackToPaneCwdWithCommand() {
        let p = plan(resume: resumeRecord, existing: ["/pane"])
        XCTAssertEqual(p.cwd, "/pane")
        XCTAssertEqual(p.startupInput, "claude --resume sess-1")
    }

    func test_restorePlan_agentCwdNil_usesPaneCwdWithCommand() {
        var resume = resumeRecord
        resume.cwd = nil
        let p = plan(resume: resume, existing: ["/pane"])
        XCTAssertEqual(p.cwd, "/pane")
        XCTAssertEqual(p.startupInput, "claude --resume sess-1")
    }

    func test_restorePlan_bothMissing_noResume() {
        // Never resume an agent in the `$HOME` fallback.
        let p = plan(resume: resumeRecord, existing: [])
        XCTAssertEqual(p.cwd, "/pane")
        XCTAssertNil(p.startupInput)
    }

    func test_restorePlan_noRecord_paneCwdOnly() {
        let p = plan(resume: nil, existing: ["/pane"])
        XCTAssertEqual(p.cwd, "/pane")
        XCTAssertNil(p.startupInput)
    }
}

// HookCLITests.swift
//
// Argument parsing for the termy-hook CLI. The binary lives in a separate
// target, but `HookCLI.swift` is shared into this bundle (see project.yml)
// so the parsing rules stay testable without spawning the executable.

import XCTest
@testable import termy

final class HookCLITests: XCTestCase {

    func test_defaultsToClaudeCode_whenNoFlag() {
        let parsed = HookCLI.parse(["termy-hook", "SessionStart"])
        XCTAssertEqual(parsed?.agent, "claude-code")
        XCTAssertEqual(parsed?.event, "SessionStart")
    }

    func test_agentCodex_setsCodex() {
        let parsed = HookCLI.parse(["termy-hook", "--agent", "codex", "PermissionRequest"])
        XCTAssertEqual(parsed?.agent, "codex")
        XCTAssertEqual(parsed?.event, "PermissionRequest")
    }

    func test_agentClaude_normalizesToClaudeCode() {
        // "claude" is the typed name developers will type; the wire format
        // expects "claude-code". The CLI normalizes for ergonomics.
        let parsed = HookCLI.parse(["termy-hook", "--agent", "claude", "Stop"])
        XCTAssertEqual(parsed?.agent, "claude-code")
    }

    func test_agentFlagAfterEvent_stillParsed() {
        // We don't enforce flag-before-positional ordering — both work.
        let parsed = HookCLI.parse(["termy-hook", "Stop", "--agent", "codex"])
        XCTAssertEqual(parsed?.agent, "codex")
        XCTAssertEqual(parsed?.event, "Stop")
    }

    func test_unknownAgentValue_passesThroughVerbatim() {
        // Daemon resolves agent → AgentKind via from(rawAgent:); unknown
        // values become nil there and the pane's prior kind sticks.
        let parsed = HookCLI.parse(["termy-hook", "--agent", "aider", "SessionStart"])
        XCTAssertEqual(parsed?.agent, "aider")
    }

    func test_missingFlagValue_returnsNil() {
        // `--agent` with no following value is a malformed invocation;
        // bail silently rather than guess.
        XCTAssertNil(HookCLI.parse(["termy-hook", "--agent"]))
    }

    func test_noEvent_returnsNil() {
        XCTAssertNil(HookCLI.parse(["termy-hook"]))
        XCTAssertNil(HookCLI.parse(["termy-hook", "--agent", "codex"]))
    }
}

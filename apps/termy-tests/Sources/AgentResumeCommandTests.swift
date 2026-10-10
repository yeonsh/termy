import XCTest
@testable import termy

final class AgentResumeCommandTests: XCTestCase {
    private func record(
        _ kind: AgentKind,
        id: String = "bb69d2e4-e5f1-4f4c-bc03-e7fa9e29b2fe",
        flags: [String] = []
    ) -> AgentResumeRecord {
        AgentResumeRecord(kind: kind, sessionId: id, cwd: nil, flags: flags)
    }

    func test_claude_noFlags() {
        XCTAssertEqual(
            AgentResumeCommand.make(record(.claude)),
            "claude --resume bb69d2e4-e5f1-4f4c-bc03-e7fa9e29b2fe"
        )
    }

    func test_claude_putsFlagsAfterSessionId() {
        let r = record(.claude, flags: ["--model", "opus", "--dangerously-skip-permissions"])
        XCTAssertEqual(
            AgentResumeCommand.make(r),
            "claude --resume bb69d2e4-e5f1-4f4c-bc03-e7fa9e29b2fe --model opus --dangerously-skip-permissions"
        )
    }

    func test_codex_putsFlagsBeforeSessionId() {
        let r = record(.codex, id: "019a-uuid", flags: ["-m", "gpt-5", "-c", "model_reasoning_effort=high"])
        XCTAssertEqual(
            AgentResumeCommand.make(r),
            "codex resume -m gpt-5 -c model_reasoning_effort=high 019a-uuid"
        )
    }

    // Review Focus 3
    func test_quotesToolPatternWithSpacesAndParens() {
        let r = record(.claude, id: "s1", flags: ["--allowedTools", "Bash(git log:*)", "Edit"])
        XCTAssertEqual(
            AgentResumeCommand.make(r),
            "claude --resume s1 --allowedTools 'Bash(git log:*)' Edit"
        )
    }

    func test_shellQuote_leavesSafeWordsBare() {
        XCTAssertEqual(AgentResumeCommand.shellQuote("--permission-mode"), "--permission-mode")
        XCTAssertEqual(AgentResumeCommand.shellQuote("/Users/u/proj"), "/Users/u/proj")
        XCTAssertEqual(AgentResumeCommand.shellQuote("model=o3"), "model=o3")
    }

    func test_shellQuote_escapesSingleQuote() {
        XCTAssertEqual(AgentResumeCommand.shellQuote("it's"), #"'it'\''s'"#)
    }

    func test_shellQuote_quotesShellSyntax() {
        XCTAssertEqual(AgentResumeCommand.shellQuote(""), "''")
        // zsh expands a leading `=` (EQUALS option) and `~`.
        XCTAssertEqual(AgentResumeCommand.shellQuote("=x"), "'=x'")
        XCTAssertEqual(AgentResumeCommand.shellQuote("~/x"), "'~/x'")
        XCTAssertEqual(AgentResumeCommand.shellQuote("$HOME"), "'$HOME'")
        XCTAssertEqual(
            AgentResumeCommand.shellQuote(#"sandbox_permissions=["disk-full-read-access"]"#),
            #"'sandbox_permissions=["disk-full-read-access"]'"#
        )
    }
}

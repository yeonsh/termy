import XCTest
@testable import termy

final class AgentResumeFlagsTests: XCTestCase {
    private func claude(_ argv: [String]) -> [String] {
        AgentResumeFlags.extract(kind: .claude, argv: argv)
    }

    private func codex(_ argv: [String]) -> [String] {
        AgentResumeFlags.extract(kind: .codex, argv: argv)
    }

    func test_claude_keepsPermissionAndModelFlags() {
        XCTAssertEqual(
            claude(["claude", "--dangerously-skip-permissions", "--model", "opus", "--permission-mode", "plan"]),
            ["--dangerously-skip-permissions", "--model", "opus", "--permission-mode", "plan"]
        )
    }

    func test_claude_dropsPositionalPrompt() {
        XCTAssertEqual(claude(["claude", "--model", "opus", "fix the login bug"]), ["--model", "opus"])
    }

    func test_claude_dropsPrintAndSessionSelection() {
        XCTAssertEqual(
            claude(["claude", "-p", "--resume", "old-id", "--continue", "--verbose", "--model", "sonnet"]),
            ["--model", "sonnet"]
        )
    }

    func test_claude_variadicStopsAtNextFlag() {
        XCTAssertEqual(
            claude(["claude", "--allowedTools", "Read", "Bash(git log:*)", "--add-dir", "/a", "/b", "--model", "opus"]),
            ["--allowedTools", "Read", "Bash(git log:*)", "--add-dir", "/a", "/b", "--model", "opus"]
        )
    }

    func test_claude_equalsForm() {
        XCTAssertEqual(
            claude(["claude", "--model=opus", "--permission-mode=plan", "--debug=api"]),
            ["--model=opus", "--permission-mode=plan"]
        )
    }

    func test_claude_nodeLauncher() {
        XCTAssertEqual(
            claude(["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--model", "opus", "hello"]),
            ["--model", "opus"]
        )
    }

    func test_claude_valueFlagWithoutValue_isDropped() {
        XCTAssertEqual(claude(["claude", "--model"]), [])
        XCTAssertEqual(claude(["claude", "--add-dir"]), [])
    }

    func test_codex_keepsRepeatedConfigInOrder() {
        XCTAssertEqual(
            codex(["node", "/opt/homebrew/bin/codex", "-c", "model_reasoning_effort=high", "-m", "gpt-5",
                   "-c", "sandbox_mode=workspace-write", "--search", "write tests"]),
            ["-c", "model_reasoning_effort=high", "-m", "gpt-5", "-c", "sandbox_mode=workspace-write"]
        )
    }

    func test_pIsProfileForCodexButPrintForClaude() {
        XCTAssertEqual(codex(["codex", "-p", "work"]), ["-p", "work"])
        XCTAssertEqual(claude(["claude", "-p", "work"]), [])
    }

    func test_codex_dropsSubcommandAndOldSessionId() {
        XCTAssertEqual(
            codex(["codex", "resume", "019a-old", "--dangerously-bypass-approvals-and-sandbox", "--approve-for-me"]),
            ["--dangerously-bypass-approvals-and-sandbox", "--approve-for-me"]
        )
    }

    func test_codex_fullAutoIsNotCarried() {
        // Not accepted by codex-cli 0.160.1's `codex resume`.
        XCTAssertEqual(codex(["codex", "--full-auto"]), [])
    }

    func test_noAgentEntrypoint_returnsEmpty() {
        XCTAssertEqual(claude(["node", "server.js", "--model", "x"]), [])
    }

    func test_claude_nativeInstallArgv0_extractsFlags() {
        XCTAssertEqual(
            claude(["claude", "--model", "sonnet", "--allowedTools", "Bash(sleep:*)"]),
            ["--model", "sonnet", "--allowedTools", "Bash(sleep:*)"]
        )
    }
}

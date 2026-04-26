// ForegroundProcessWatcherTests.swift
//
// Pure-function coverage for the agent classifier. The actor's polling
// path (tcgetpgrp + proc_name) needs a real PTY + child process, so it
// stays a Phase-5 integration smoke test rather than an XCTest unit.

import XCTest
@testable import termy

final class ForegroundProcessWatcherTests: XCTestCase {

    func test_classifyAgent_codex() {
        XCTAssertEqual(ForegroundProcessWatcher.classifyAgent(by: "codex"), .codex)
    }

    func test_classifyAgent_codexWithSuffix() {
        // The macOS proc_name buffer truncates to ~16 chars; some Rust
        // builds expose `codex-cli`. Treat any `codex-*` prefix as Codex.
        XCTAssertEqual(ForegroundProcessWatcher.classifyAgent(by: "codex-cli"), .codex)
    }

    func test_classifyAgent_claude() {
        XCTAssertEqual(ForegroundProcessWatcher.classifyAgent(by: "claude"), .claude)
    }

    func test_classifyAgent_caseInsensitive() {
        XCTAssertEqual(ForegroundProcessWatcher.classifyAgent(by: "Codex"), .codex)
        XCTAssertEqual(ForegroundProcessWatcher.classifyAgent(by: "CLAUDE"), .claude)
    }

    func test_classifyAgent_shell_returnsNil() {
        for name in ["zsh", "bash", "fish", "sh"] {
            XCTAssertNil(ForegroundProcessWatcher.classifyAgent(by: name), "shell name: \(name)")
        }
    }

    func test_classifyAgent_unrelatedBinary_returnsNil() {
        for name in ["vim", "less", "git", "ssh", "tmux"] {
            XCTAssertNil(ForegroundProcessWatcher.classifyAgent(by: name), "unrelated: \(name)")
        }
    }

    func test_classifyAgent_emptyString_returnsNil() {
        XCTAssertNil(ForegroundProcessWatcher.classifyAgent(by: ""))
    }

    func test_classifyAgent_codexAlone_doesNotMatchCodecov() {
        // Defensive: a substring like "codecov" must not classify as codex.
        // We require either exact match or a `codex-` prefix.
        XCTAssertNil(ForegroundProcessWatcher.classifyAgent(by: "codecov"))
        XCTAssertNil(ForegroundProcessWatcher.classifyAgent(by: "codespell"))
    }

    func test_classifyAgent_nodeBackedCodexEntrypoint() {
        // npm/Homebrew Codex installs can run as a Node shebang, so proc_name
        // reports `node` until the first hook event arrives. argv still
        // exposes the Codex entrypoint; classify it immediately so a new
        // dashboard chip appears before the user submits a prompt.
        XCTAssertEqual(
            ForegroundProcessWatcher.classifyAgent(
                processName: "node",
                arguments: ["/opt/homebrew/bin/node", "/opt/homebrew/bin/codex"]
            ),
            .codex
        )
    }

    func test_classifyAgent_nodeBackedCodexPackage() {
        XCTAssertEqual(
            ForegroundProcessWatcher.classifyAgent(
                processName: "node",
                arguments: [
                    "/opt/homebrew/bin/node",
                    "/Users/me/.npm/_npx/abc/node_modules/@openai/codex/bin/codex.js",
                ]
            ),
            .codex
        )
    }

    func test_classifyAgent_nodeBackedClaudePackage() {
        XCTAssertEqual(
            ForegroundProcessWatcher.classifyAgent(
                processName: "node",
                arguments: [
                    "/opt/homebrew/bin/node",
                    "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                ]
            ),
            .claude
        )
    }

    func test_classifyAgent_nodeDoesNotMatchIncidentalCodexFlag() {
        XCTAssertNil(
            ForegroundProcessWatcher.classifyAgent(
                processName: "node",
                arguments: ["/opt/homebrew/bin/node", "server.js", "--codex-mode"]
            )
        )
    }

    func test_classifyAgent_nonRuntimeDoesNotInspectArguments() {
        XCTAssertNil(
            ForegroundProcessWatcher.classifyAgent(
                processName: "vim",
                arguments: ["/tmp/codex"]
            )
        )
    }

    // MARK: - processName smoke

    func test_processName_currentProcess_returnsNonNil() {
        // Using getpid() — the test runner is a live process, so its
        // name should be readable. Mostly a smoke test that the libproc
        // bridge compiles and doesn't crash.
        guard let name = ForegroundProcessWatcher.processName(pid: getpid()) else {
            XCTFail("expected a name for the current process")
            return
        }
        XCTAssertFalse(name.isEmpty)
    }

    func test_processName_invalidPid_returnsNil() {
        // PID 0 is the kernel; libproc returns 0 bytes.
        XCTAssertNil(ForegroundProcessWatcher.processName(pid: 0))
    }

    func test_processArguments_currentProcess_returnsArgv() {
        guard let arguments = ForegroundProcessWatcher.processArguments(pid: getpid()) else {
            XCTFail("expected argv for the current process")
            return
        }
        XCTAssertFalse(arguments.isEmpty)
    }
}

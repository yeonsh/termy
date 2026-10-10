// PaneShellEnvironmentTests.swift
//
// Pins down Pane.shellEnvironment: pane shells must not inherit the session
// markers of an agent that happened to launch termy, but must keep the user's
// own configuration.

import XCTest
@testable import termy

@MainActor
final class PaneShellEnvironmentTests: XCTestCase {

    private let markers = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_EXECPATH", "CLAUDE_PID",
        "CLAUDE_EFFORT", "CLAUDE_PLUGIN_DATA", "AI_AGENT",
        "CODEX_COMPANION_SESSION_ID", "CODEX_SANDBOX",
        "CODEX_SANDBOX_NETWORK_DISABLED",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CODEX_THREAD_ID",
    ]

    private func make(_ base: [String: String]) -> [String: String] {
        Pane.shellEnvironment(base: base, paneId: "p1", projectId: "proj1")
    }

    func testStripsEverySessionMarker() {
        var base = ["PATH": "/usr/bin", "HOME": "/Users/x"]
        for key in markers { base[key] = "1" }
        let env = make(base)
        for key in markers {
            XCTAssertNil(env[key], "\(key) should be stripped")
        }
    }

    func testStripsGitEditorOnlyWhenTrue() {
        XCTAssertNil(make(["GIT_EDITOR": "true"])["GIT_EDITOR"])
        XCTAssertEqual(make(["GIT_EDITOR": "vim"])["GIT_EDITOR"], "vim")
    }

    func testKeepsUserConfiguration() {
        let env = make([
            "CLAUDE_CODE_NO_FLICKER": "1",
            "ANTHROPIC_BASE_URL": "https://example.test",
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/x",
            "CLAUDECODE": "1",
        ])
        XCTAssertEqual(env["CLAUDE_CODE_NO_FLICKER"], "1")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://example.test")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }

    func testSetsTermyIdsOverridingStaleValues() {
        let env = make(["TERMY_PANE_ID": "old", "TERMY_PROJECT_ID": "oldproj"])
        XCTAssertEqual(env["TERMY_PANE_ID"], "p1")
        XCTAssertEqual(env["TERMY_PROJECT_ID"], "proj1")
    }

    func testSetsTermAndColorterm() {
        let env = make(["TERM": "dumb", "COLORTERM": "no"])
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
    }

    func testLcAllDefaultsWhenAbsent() {
        XCTAssertEqual(make([:])["LC_ALL"], "en_US.UTF-8")
    }

    func testLcAllPreservedWhenPresent() {
        XCTAssertEqual(make(["LC_ALL": "ko_KR.UTF-8"])["LC_ALL"], "ko_KR.UTF-8")
    }
}

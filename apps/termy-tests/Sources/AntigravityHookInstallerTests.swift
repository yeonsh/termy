// AntigravityHookInstallerTests.swift
//
// Coverage for AntigravityHookInstaller (`~/.gemini/config/hooks.json`).
// Antigravity's hook config is a JSON map of named top-level hook groups;
// termy owns the `"termy"` group while leaving sibling groups (such as
// `"claude-context-loader"`) untouched.

import XCTest
@testable import termy

final class AntigravityHookInstallerTests: XCTestCase {

    private let path = "/Applications/termy.app/Contents/Resources/termy-hook"

    func test_install_intoEmptySettings_writesTermyHookGroupWithFiveEvents() {
        var settings: [String: Any] = [:]
        AntigravityHookInstaller.applyInstall(to: &settings, hookPath: path)

        let termyGroup = settings[AntigravityHookInstaller.hookName] as? [String: Any]
        XCTAssertNotNil(termyGroup)
        XCTAssertEqual(termyGroup?["enabled"] as? Bool, true)

        for event in AntigravityHookInstaller.lifecycleEvents {
            let handlers = termyGroup?[event] as? [[String: Any]]
            XCTAssertEqual(handlers?.count, 1, "lifecycle event \(event) should have 1 handler")
            XCTAssertEqual(handlers?[0]["type"] as? String, "command")
            XCTAssertEqual(
                handlers?[0]["command"] as? String,
                "\"\(path)\" --agent antigravity \(event)"
            )
            // Ensure no unrecognized keys (like _termy_managed) are injected into
            // Antigravity's strict protojson HookHandler objects.
            XCTAssertEqual(Set(handlers?[0].keys.map { $0 } ?? []), ["type", "command"])
        }

        for event in AntigravityHookInstaller.toolEvents {
            let matchers = termyGroup?[event] as? [[String: Any]]
            XCTAssertEqual(matchers?.count, 1, "tool event \(event) should have 1 matcher group")
            XCTAssertEqual(matchers?[0]["matcher"] as? String, "*")
            let handlers = matchers?[0]["hooks"] as? [[String: Any]]
            XCTAssertEqual(handlers?.count, 1)
            XCTAssertEqual(handlers?[0]["type"] as? String, "command")
            XCTAssertEqual(
                handlers?[0]["command"] as? String,
                "\"\(path)\" --agent antigravity \(event)"
            )
            XCTAssertEqual(Set(matchers?[0].keys.map { $0 } ?? []), ["matcher", "hooks"])
            XCTAssertEqual(Set(handlers?[0].keys.map { $0 } ?? []), ["type", "command"])
        }

        XCTAssertEqual(AntigravityHookInstaller.findInstalledPath(in: settings), path)
    }

    func test_install_doesNotRegisterPreToolUse() {
        // agy treats a PreToolUse reply without `decision` as a deny, and
        // termy-hook only replies `{}` — registering it blocks every tool call.
        var settings: [String: Any] = [:]
        AntigravityHookInstaller.applyInstall(to: &settings, hookPath: path)

        let termyGroup = settings[AntigravityHookInstaller.hookName] as? [String: Any]
        XCTAssertNil(termyGroup?["PreToolUse"])
        XCTAssertNotNil(termyGroup?["PostToolUse"])
    }

    func test_currentState_legacyPreToolUseInstall_isStale_andReinstallDropsIt() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hooksURL = dir.appendingPathComponent("hooks.json")

        // An install written before PreToolUse was dropped.
        var settings: [String: Any] = [:]
        AntigravityHookInstaller.applyInstall(to: &settings, hookPath: path)
        var termyGroup = settings[AntigravityHookInstaller.hookName] as! [String: Any]
        termyGroup["PreToolUse"] = [[
            "matcher": "*",
            "hooks": [[
                "type": "command",
                "command": "\"\(path)\" --agent antigravity PreToolUse"
            ]]
        ]]
        settings[AntigravityHookInstaller.hookName] = termyGroup
        let data = try JSONSerialization.data(withJSONObject: settings)
        try data.write(to: hooksURL)

        XCTAssertEqual(
            AntigravityHookInstaller.currentState(hooksJSONURL: hooksURL, hookPath: path),
            .installedStale(existingPath: path)
        )

        try AntigravityHookInstaller.install(hooksJSONURL: hooksURL, hookPath: path)
        let rewritten = try JSONSerialization.jsonObject(
            with: Data(contentsOf: hooksURL)
        ) as? [String: Any]
        let rewrittenGroup = rewritten?[AntigravityHookInstaller.hookName] as? [String: Any]
        XCTAssertNil(rewrittenGroup?["PreToolUse"])
        XCTAssertEqual(
            AntigravityHookInstaller.currentState(hooksJSONURL: hooksURL, hookPath: path),
            .installedCurrent
        )
    }

    func test_install_preservesSiblingHookGroups() {
        var settings: [String: Any] = [
            "claude-context-loader": [
                "enabled": true,
                "SessionStart": [[
                    "type": "command",
                    "command": "python3 ~/.gemini/config/hooks/claude_context_loader.py"
                ]]
            ]
        ]

        AntigravityHookInstaller.applyInstall(to: &settings, hookPath: path)

        let sibling = settings["claude-context-loader"] as? [String: Any]
        let siblingStart = sibling?["SessionStart"] as? [[String: Any]]
        XCTAssertEqual(
            siblingStart?[0]["command"] as? String,
            "python3 ~/.gemini/config/hooks/claude_context_loader.py"
        )
        XCTAssertEqual(AntigravityHookInstaller.findInstalledPath(in: settings), path)
    }

    func test_uninstall_removesTermyGroup_preservesSiblingHookGroups() {
        var settings: [String: Any] = [
            "claude-context-loader": [
                "enabled": true,
                "SessionStart": [[
                    "type": "command",
                    "command": "python3 ~/.gemini/config/hooks/claude_context_loader.py"
                ]]
            ]
        ]
        AntigravityHookInstaller.applyInstall(to: &settings, hookPath: path)

        AntigravityHookInstaller.applyUninstall(from: &settings)

        XCTAssertNil(settings[AntigravityHookInstaller.hookName])
        XCTAssertNotNil(settings["claude-context-loader"])
        XCTAssertNil(AntigravityHookInstaller.findInstalledPath(in: settings))
    }

    func test_currentState_lifecycleOnDisk() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hooksURL = dir.appendingPathComponent("hooks.json")

        // 1. Missing file -> .notInstalled
        XCTAssertEqual(
            AntigravityHookInstaller.currentState(hooksJSONURL: hooksURL, hookPath: path),
            .notInstalled
        )

        // 2. Install -> .installedCurrent
        try AntigravityHookInstaller.install(hooksJSONURL: hooksURL, hookPath: path)
        XCTAssertEqual(
            AntigravityHookInstaller.currentState(hooksJSONURL: hooksURL, hookPath: path),
            .installedCurrent
        )

        // 3. Different bundle path -> .installedStale
        let newPath = "/Users/u/Downloads/termy.app/Contents/Resources/termy-hook"
        XCTAssertEqual(
            AntigravityHookInstaller.currentState(hooksJSONURL: hooksURL, hookPath: newPath),
            .installedStale(existingPath: path)
        )

        // 4. Uninstall -> .notInstalled
        try AntigravityHookInstaller.uninstall(hooksJSONURL: hooksURL)
        XCTAssertEqual(
            AntigravityHookInstaller.currentState(hooksJSONURL: hooksURL, hookPath: path),
            .notInstalled
        )
    }

    func test_currentState_malformedJSON_returnsConfigError() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hooksURL = dir.appendingPathComponent("hooks.json")
        try "{ not valid json".write(to: hooksURL, atomically: true, encoding: .utf8)

        if case .configError = AntigravityHookInstaller.currentState(hooksJSONURL: hooksURL, hookPath: path) {
            // expected
        } else {
            XCTFail("Expected .configError for malformed hooks.json")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

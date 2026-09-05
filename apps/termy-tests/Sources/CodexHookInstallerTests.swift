// CodexHookInstallerTests.swift
//
// Pure-function coverage for the TOML merge logic. Drives applyInstall /
// applyUninstall on in-memory TOMLTables — the file I/O path
// (read/write/backup) is left to manual smoke-test in Phase 5 since it
// touches the real ~/.codex/config.toml.

import XCTest
import TOMLKit
@testable import termy

final class CodexHookInstallerTests: XCTestCase {

    private let path = "/Applications/termy.app/Contents/Resources/termy-hook"

    // MARK: - Empty starting config

    func test_install_intoEmptyConfig_writesAllSixEvents() {
        let config = TOMLTable()
        CodexHookInstaller.applyInstall(to: config, hookPath: path)

        // [features] hooks = true
        XCTAssertEqual(config["features"]?.table?["hooks"]?.bool, true)
        XCTAssertNil(config["features"]?.table?["codex_hooks"])

        // hooks.<Event> arrays populated for each of the 6 events
        let hooks = config["hooks"]?.table
        XCTAssertNotNil(hooks)
        for event in CodexHookInstaller.allEvents {
            let blocks = hooks?[event]?.array
            XCTAssertEqual(blocks?.count, 1, "event \(event) should have 1 block")
            let block = blocks?[0].table
            XCTAssertEqual(block?[CodexHookInstaller.markerKey]?.bool, true)
            let inner = block?["hooks"]?.array
            XCTAssertEqual(inner?.count, 1)
            let cmd = inner?[0].table
            XCTAssertEqual(cmd?["type"]?.string, "command")
            XCTAssertEqual(
                cmd?["command"]?.string,
                "\"\(path)\" --agent codex \(event)"
            )
        }
    }

    func test_install_migratesDeprecatedFeature_preservesUnrelatedFeatures() throws {
        let config = try TOMLTable(string: """
            [features]
            codex_hooks = true
            hooks = false
            multi_agent = true
            """)

        CodexHookInstaller.applyInstall(to: config, hookPath: path)

        let reparsed = try TOMLTable(string: config.convert(to: .toml))
        let features = reparsed["features"]?.table
        XCTAssertEqual(features?["hooks"]?.bool, true)
        XCTAssertNil(features?["codex_hooks"])
        XCTAssertEqual(features?["multi_agent"]?.bool, true)
    }

    // MARK: - Preserve user blocks

    func test_install_preservesExistingUserBlock() {
        let config = TOMLTable()
        let hooks = TOMLTable()
        let permissionRequest = TOMLArray()
        let userBlock = TOMLTable()
        let userInner = TOMLArray()
        let userCmd = TOMLTable()
        userCmd["type"] = "command"
        userCmd["command"] = "/usr/local/bin/my-script"
        userInner.append(userCmd)
        userBlock["hooks"] = userInner
        permissionRequest.append(userBlock)
        hooks["PermissionRequest"] = permissionRequest
        config["hooks"] = hooks

        CodexHookInstaller.applyInstall(to: config, hookPath: path)

        let blocks = config["hooks"]?.table?["PermissionRequest"]?.array
        XCTAssertEqual(blocks?.count, 2, "user block + termy block")

        // User block survives unchanged.
        let firstCmd = blocks?[0].table?["hooks"]?.array?[0].table?["command"]?.string
        XCTAssertEqual(firstCmd, "/usr/local/bin/my-script")
        XCTAssertNil(blocks?[0].table?[CodexHookInstaller.markerKey]?.bool)

        // termy block appended.
        XCTAssertEqual(blocks?[1].table?[CodexHookInstaller.markerKey]?.bool, true)
    }

    // MARK: - Re-install replaces, doesn't duplicate

    func test_install_reapplied_doesNotDuplicate() {
        let config = TOMLTable()
        CodexHookInstaller.applyInstall(to: config, hookPath: path)
        CodexHookInstaller.applyInstall(to: config, hookPath: "/new/path/termy-hook")

        for event in CodexHookInstaller.allEvents {
            let blocks = config["hooks"]?.table?[event]?.array
            XCTAssertEqual(blocks?.count, 1, "no duplication on \(event)")
            let cmd = blocks?[0].table?["hooks"]?.array?[0].table?["command"]?.string
            XCTAssertEqual(cmd, "\"/new/path/termy-hook\" --agent codex \(event)")
        }
    }

    // MARK: - hooks.json

    func test_jsonInstall_preservesExistingHooksAndWritesTermyBlocks() {
        var settings: [String: Any] = [
            "hooks": [
                "SessionStart": [[
                    "hooks": [[
                        "type": "command",
                        "command": "/usr/local/bin/omx session-start"
                    ]]
                ]]
            ],
            "other": "kept"
        ]

        CodexHookInstaller.applyInstall(toHooksJSON: &settings, hookPath: path)

        XCTAssertEqual(settings["other"] as? String, "kept")
        let hooks = settings["hooks"] as? [String: Any]
        let sessionStart = hooks?["SessionStart"] as? [[String: Any]]
        XCTAssertEqual(sessionStart?.count, 2)
        XCTAssertEqual(
            ((sessionStart?[0]["hooks"] as? [[String: Any]])?[0]["command"] as? String),
            "/usr/local/bin/omx session-start"
        )
        XCTAssertEqual(sessionStart?[1][CodexHookInstaller.markerKey] as? Bool, true)
        XCTAssertEqual(CodexHookInstaller.findInstalledPath(inHooksJSON: settings), path)
    }

    func test_jsonInstall_reappliedDoesNotDuplicate() {
        var settings: [String: Any] = [:]

        CodexHookInstaller.applyInstall(toHooksJSON: &settings, hookPath: path)
        CodexHookInstaller.applyInstall(toHooksJSON: &settings, hookPath: "/new/path/termy-hook")

        let hooks = settings["hooks"] as? [String: Any]
        for event in CodexHookInstaller.allEvents {
            let blocks = hooks?[event] as? [[String: Any]]
            XCTAssertEqual(blocks?.count, 1, event)
            let cmd = (blocks?[0]["hooks"] as? [[String: Any]])?[0]["command"] as? String
            XCTAssertEqual(cmd, "\"/new/path/termy-hook\" --agent codex \(event)")
        }
    }

    func test_jsonUninstall_removesTermyBlocksPreservesUserBlocks() {
        var settings: [String: Any] = [
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": "echo stop"
                    ]]
                ]]
            ]
        ]
        CodexHookInstaller.applyInstall(toHooksJSON: &settings, hookPath: path)

        CodexHookInstaller.applyUninstall(fromHooksJSON: &settings)

        let hooks = settings["hooks"] as? [String: Any]
        let stop = hooks?["Stop"] as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1)
        XCTAssertEqual(
            ((stop?[0]["hooks"] as? [[String: Any]])?[0]["command"] as? String),
            "echo stop"
        )
        XCTAssertNil(hooks?["PermissionRequest"])
    }

    func test_installWhenHooksJSONExists_migratesTermyHooksOutOfToml() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.toml")
        let hooksJSONURL = dir.appendingPathComponent("hooks.json")
        try """
            [features]
            hooks = false

            [hooks.state]
            "config.toml:session_start:0:0" = { status = "trusted" }

            [[hooks.SessionStart]]
            _termy_managed = true
                [[hooks.SessionStart.hooks]]
                type = "command"
                command = "\\"/old/path/termy-hook\\" --agent codex SessionStart"
            """.write(to: configURL, atomically: true, encoding: .utf8)
        try """
            {
              "hooks": {
                "SessionStart": [
                  {
                    "hooks": [
                      {
                        "type": "command",
                        "command": "/usr/local/bin/omx session-start"
                      }
                    ]
                  }
                ]
              }
            }
            """.write(to: hooksJSONURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            CodexHookInstaller.currentState(
                configURL: configURL,
                hooksJSONURL: hooksJSONURL,
                hookPath: path
            ),
            .installedNeedsMigration(existingPath: "/old/path/termy-hook")
        )

        try CodexHookInstaller.install(
            configURL: configURL,
            hooksJSONURL: hooksJSONURL,
            hookPath: path
        )

        let config = try TOMLTable(string: String(contentsOf: configURL, encoding: .utf8))
        XCTAssertEqual(config["features"]?.table?["hooks"]?.bool, true)
        XCTAssertNotNil(config["hooks"]?.table?["state"])
        XCTAssertNil(config["hooks"]?.table?["SessionStart"])

        let data = try Data(contentsOf: hooksJSONURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = json["hooks"] as? [String: Any]
        let sessionStart = hooks?["SessionStart"] as? [[String: Any]]
        XCTAssertEqual(sessionStart?.count, 2)
        XCTAssertEqual(CodexHookInstaller.findInstalledPath(inHooksJSON: json), path)
        XCTAssertEqual(
            CodexHookInstaller.currentState(
                configURL: configURL,
                hooksJSONURL: hooksJSONURL,
                hookPath: path
            ),
            .installedCurrent
        )
    }

    func test_installWhenHooksJSONMalformed_leavesFilesUnchanged() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.toml")
        let hooksJSONURL = dir.appendingPathComponent("hooks.json")
        let originalConfig = """
            [features]
            hooks = true
            """
        let originalJSON = "{ malformed"
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try originalJSON.write(to: hooksJSONURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try CodexHookInstaller.install(
                configURL: configURL,
                hooksJSONURL: hooksJSONURL,
                hookPath: path
            )
        )
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), originalConfig)
        XCTAssertEqual(try String(contentsOf: hooksJSONURL, encoding: .utf8), originalJSON)
    }

    func test_installWhenHooksJSONShapeMalformed_leavesFilesUnchanged() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.toml")
        let hooksJSONURL = dir.appendingPathComponent("hooks.json")
        let originalConfig = """
            [features]
            hooks = true
            """
        let originalJSON = """
            {
              "hooks": {
                "Stop": "not an array"
              }
            }
            """
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try originalJSON.write(to: hooksJSONURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try CodexHookInstaller.install(
                configURL: configURL,
                hooksJSONURL: hooksJSONURL,
                hookPath: path
            )
        )
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), originalConfig)
        XCTAssertEqual(try String(contentsOf: hooksJSONURL, encoding: .utf8), originalJSON)
    }

    func test_uninstallWhenHooksJSONExists_removesJsonAndTomlTermyBlocks() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.toml")
        let hooksJSONURL = dir.appendingPathComponent("hooks.json")
        let config = TOMLTable()
        CodexHookInstaller.applyInstall(to: config, hookPath: path)
        try config.convert(to: .toml).write(to: configURL, atomically: true, encoding: .utf8)
        var json: [String: Any] = [:]
        CodexHookInstaller.applyInstall(toHooksJSON: &json, hookPath: path)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: hooksJSONURL)

        try CodexHookInstaller.uninstall(configURL: configURL, hooksJSONURL: hooksJSONURL)

        let reparsed = try TOMLTable(string: String(contentsOf: configURL, encoding: .utf8))
        XCTAssertNil(reparsed["hooks"])
        let reloaded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksJSONURL)) as? [String: Any]
        )
        XCTAssertNil(CodexHookInstaller.findInstalledPath(inHooksJSON: reloaded))
        XCTAssertNotNil(reloaded["hooks"] as? [String: Any])
    }

    func test_reinstallAfterJsonUninstall_remainsValid() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.toml")
        let hooksJSONURL = dir.appendingPathComponent("hooks.json")
        try #"{ "hooks": {} }"#.write(to: hooksJSONURL, atomically: true, encoding: .utf8)

        try CodexHookInstaller.install(
            configURL: configURL,
            hooksJSONURL: hooksJSONURL,
            hookPath: path
        )
        try CodexHookInstaller.uninstall(configURL: configURL, hooksJSONURL: hooksJSONURL)
        try CodexHookInstaller.install(
            configURL: configURL,
            hooksJSONURL: hooksJSONURL,
            hookPath: path
        )

        let reloaded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksJSONURL)) as? [String: Any]
        )
        XCTAssertEqual(CodexHookInstaller.findInstalledPath(inHooksJSON: reloaded), path)
    }

    // MARK: - Deprecated [features].codex_hooks left behind by older writers

    /// termy 0.2.2 and `omx setup` both write `codex_hooks = true`. When the
    /// hook path already matches, an early-return "installed, current" would
    /// leave Codex warning on every launch, so this must be its own state.
    func test_currentState_tomlHooksCurrentWithDeprecatedFlag_needsFeatureFlagMigration() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.toml")
        let hooksJSONURL = dir.appendingPathComponent("hooks.json")
        try deprecatedFlagTomlWithTermyHooks.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            CodexHookInstaller.currentState(
                configURL: configURL,
                hooksJSONURL: hooksJSONURL,
                hookPath: path
            ),
            .installedNeedsFeatureFlagMigration
        )
    }

    func test_currentState_jsonHooksCurrentWithDeprecatedFlag_needsFeatureFlagMigration() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.toml")
        let hooksJSONURL = dir.appendingPathComponent("hooks.json")
        try """
            [features]
            codex_hooks = true
            hooks = true
            """.write(to: configURL, atomically: true, encoding: .utf8)
        try writeTermyHooksJSON(to: hooksJSONURL)

        XCTAssertEqual(
            CodexHookInstaller.currentState(
                configURL: configURL,
                hooksJSONURL: hooksJSONURL,
                hookPath: path
            ),
            .installedNeedsFeatureFlagMigration
        )
    }

    func test_installFromDeprecatedFlagState_toml_removesFlagAndBecomesCurrent() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.toml")
        let hooksJSONURL = dir.appendingPathComponent("hooks.json")
        try deprecatedFlagTomlWithTermyHooks.write(to: configURL, atomically: true, encoding: .utf8)

        try CodexHookInstaller.install(
            configURL: configURL,
            hooksJSONURL: hooksJSONURL,
            hookPath: path
        )

        let config = try TOMLTable(string: String(contentsOf: configURL, encoding: .utf8))
        XCTAssertNil(config["features"]?.table?["codex_hooks"])
        XCTAssertEqual(config["features"]?.table?["hooks"]?.bool, true)
        XCTAssertEqual(
            CodexHookInstaller.currentState(
                configURL: configURL,
                hooksJSONURL: hooksJSONURL,
                hookPath: path
            ),
            .installedCurrent
        )
    }

    func test_installFromDeprecatedFlagState_json_removesFlagAndBecomesCurrent() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.toml")
        let hooksJSONURL = dir.appendingPathComponent("hooks.json")
        try """
            [features]
            codex_hooks = true
            """.write(to: configURL, atomically: true, encoding: .utf8)
        try writeTermyHooksJSON(to: hooksJSONURL)

        try CodexHookInstaller.install(
            configURL: configURL,
            hooksJSONURL: hooksJSONURL,
            hookPath: path
        )

        let config = try TOMLTable(string: String(contentsOf: configURL, encoding: .utf8))
        XCTAssertNil(config["features"]?.table?["codex_hooks"])
        XCTAssertEqual(config["features"]?.table?["hooks"]?.bool, true)
        XCTAssertEqual(
            CodexHookInstaller.currentState(
                configURL: configURL,
                hooksJSONURL: hooksJSONURL,
                hookPath: path
            ),
            .installedCurrent
        )
    }

    /// config.toml as left by an older writer: current termy hook path plus
    /// the deprecated feature alias next to the canonical flag.
    private var deprecatedFlagTomlWithTermyHooks: String {
        """
        [features]
        codex_hooks = true
        hooks = true

        [[hooks.SessionStart]]
        _termy_managed = true
            [[hooks.SessionStart.hooks]]
            type = "command"
            command = "\\"\(path)\\" --agent codex SessionStart"
        """
    }

    private func writeTermyHooksJSON(to url: URL) throws {
        var json: [String: Any] = [:]
        CodexHookInstaller.applyInstall(toHooksJSON: &json, hookPath: path)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: url)
    }

    // MARK: - Uninstall

    func test_uninstall_removesTermyBlocks_preservesUserBlocks() {
        // Seed config with a user block + termy install.
        let config = TOMLTable()
        let hooks = TOMLTable()
        let stop = TOMLArray()
        let userBlock = TOMLTable()
        let userInner = TOMLArray()
        let userCmd = TOMLTable()
        userCmd["type"] = "command"
        userCmd["command"] = "echo bye"
        userInner.append(userCmd)
        userBlock["hooks"] = userInner
        stop.append(userBlock)
        hooks["Stop"] = stop
        config["hooks"] = hooks
        CodexHookInstaller.applyInstall(to: config, hookPath: path)

        CodexHookInstaller.applyUninstall(from: config)

        // User Stop block survives; PermissionRequest et al. are gone
        // entirely (they had only termy blocks).
        let stopBlocks = config["hooks"]?.table?["Stop"]?.array
        XCTAssertEqual(stopBlocks?.count, 1)
        XCTAssertEqual(
            stopBlocks?[0].table?["hooks"]?.array?[0].table?["command"]?.string,
            "echo bye"
        )
        XCTAssertNil(config["hooks"]?.table?["PermissionRequest"])
    }

    func test_uninstall_emptyHooksKey_isRemoved() {
        // No user blocks anywhere; after uninstall the entire `hooks`
        // key should disappear so the file stays minimal.
        let config = TOMLTable()
        CodexHookInstaller.applyInstall(to: config, hookPath: path)

        CodexHookInstaller.applyUninstall(from: config)

        XCTAssertNil(config["hooks"])
    }

    func test_uninstall_leavesFeaturesAlone() {
        // [features] hooks gets enabled by install but uninstall
        // shouldn't touch it — user might have flipped it on for other
        // reasons.
        let config = TOMLTable()
        CodexHookInstaller.applyInstall(to: config, hookPath: path)

        CodexHookInstaller.applyUninstall(from: config)

        XCTAssertEqual(config["features"]?.table?["hooks"]?.bool, true)
    }

    // MARK: - isTermyBlock

    func test_isTermyBlock_byMarker() {
        let block = TOMLTable()
        block[CodexHookInstaller.markerKey] = true
        block["hooks"] = TOMLArray()
        XCTAssertTrue(CodexHookInstaller.isTermyBlock(block))
    }

    func test_isTermyBlock_byCommandFallback() {
        // Marker stripped by hand-edit, but the command still references
        // termy-hook → still ours.
        let block = TOMLTable()
        let inner = TOMLArray()
        let cmd = TOMLTable()
        cmd["type"] = "command"
        cmd["command"] = "/some/where/termy-hook --agent codex Stop"
        inner.append(cmd)
        block["hooks"] = inner
        XCTAssertTrue(CodexHookInstaller.isTermyBlock(block))
    }

    func test_isTermyBlock_userBlock_returnsFalse() {
        let block = TOMLTable()
        let inner = TOMLArray()
        let cmd = TOMLTable()
        cmd["type"] = "command"
        cmd["command"] = "/usr/local/bin/somebody-elses-script"
        inner.append(cmd)
        block["hooks"] = inner
        XCTAssertFalse(CodexHookInstaller.isTermyBlock(block))
    }

    // MARK: - extractExecPath

    func test_extractExecPath_quoted() {
        let path = CodexHookInstaller.extractExecPath(
            from: "\"/Applications/termy.app/Contents/Resources/termy-hook\" --agent codex Stop"
        )
        XCTAssertEqual(path, "/Applications/termy.app/Contents/Resources/termy-hook")
    }

    func test_extractExecPath_unquoted() {
        let path = CodexHookInstaller.extractExecPath(
            from: "/usr/local/bin/termy-hook SessionStart"
        )
        XCTAssertEqual(path, "/usr/local/bin/termy-hook")
    }

    // MARK: - findInstalledPath

    func test_findInstalledPath_returnsTermyHookPath() {
        let config = TOMLTable()
        CodexHookInstaller.applyInstall(to: config, hookPath: path)
        XCTAssertEqual(CodexHookInstaller.findInstalledPath(in: config), path)
    }

    func test_findInstalledPath_emptyConfig_returnsNil() {
        XCTAssertNil(CodexHookInstaller.findInstalledPath(in: TOMLTable()))
    }

    // MARK: - Round-trip through TOML serialization

    func test_install_serializedToToml_reparsesWithSameStructure() throws {
        // The on-disk path is: applyInstall → table.convert(to: .toml) →
        // write file → next launch reads it and parses again. Verify the
        // emitted TOML round-trips through TOMLKit so an `installedCurrent`
        // detection still works after a save/load cycle.
        let config = TOMLTable()
        CodexHookInstaller.applyInstall(to: config, hookPath: path)

        let toml = config.convert(to: .toml)
        let reparsed = try TOMLTable(string: toml)

        XCTAssertEqual(
            CodexHookInstaller.findInstalledPath(in: reparsed),
            path
        )
        XCTAssertEqual(reparsed["features"]?.table?["hooks"]?.bool, true)
        for event in CodexHookInstaller.allEvents {
            XCTAssertEqual(reparsed["hooks"]?.table?[event]?.array?.count, 1, event)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

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

        // [features] codex_hooks = true
        XCTAssertEqual(config["features"]?.table?["codex_hooks"]?.bool, true)

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
        // [features] codex_hooks gets enabled by install but uninstall
        // shouldn't touch it — user might have flipped it on for other
        // reasons.
        let config = TOMLTable()
        CodexHookInstaller.applyInstall(to: config, hookPath: path)

        CodexHookInstaller.applyUninstall(from: config)

        XCTAssertEqual(config["features"]?.table?["codex_hooks"]?.bool, true)
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
        XCTAssertEqual(reparsed["features"]?.table?["codex_hooks"]?.bool, true)
        for event in CodexHookInstaller.allEvents {
            XCTAssertEqual(reparsed["hooks"]?.table?[event]?.array?.count, 1, event)
        }
    }
}

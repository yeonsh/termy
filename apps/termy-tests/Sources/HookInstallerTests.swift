// HookInstallerTests.swift
//
// Exercise the pure merge logic — install, uninstall, user-hook preservation,
// marker detection, and path extraction. File I/O and NSAlert flow are out
// of scope; we test the dict transforms that determine whether user configs
// survive intact.

@testable import termy
import XCTest

final class HookInstallerTests: XCTestCase {
    private let hookPath = "/Applications/termy.app/Contents/Resources/termy-hook"

    // MARK: - Install

    func test_installIntoEmptySettings_populatesAllEvents() {
        var settings: [String: Any] = [:]
        HookInstaller.applyInstall(to: &settings, hookPath: hookPath)

        let hooks = settings["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks)
        for event in HookInstaller.allEvents {
            XCTAssertNotNil(hooks?[event], "missing event \(event)")
        }
    }

    func test_installedEntryHasMarkerAndQuotedCommand() {
        var settings: [String: Any] = [:]
        HookInstaller.applyInstall(to: &settings, hookPath: hookPath)

        let hooks = settings["hooks"] as! [String: Any]
        let block = (hooks["SessionStart"] as! [[String: Any]]).first!
        XCTAssertEqual(block[HookInstaller.markerKey] as? Bool, true)
        XCTAssertNil(block["matcher"], "lifecycle events take no matcher")

        let inner = block["hooks"] as! [[String: Any]]
        let cmd = inner[0]["command"] as! String
        XCTAssertEqual(cmd, "\"\(hookPath)\" SessionStart")
    }

    func test_installAddsMatcherToToolEvents() {
        var settings: [String: Any] = [:]
        HookInstaller.applyInstall(to: &settings, hookPath: hookPath)

        let hooks = settings["hooks"] as! [String: Any]
        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
            let block = (hooks[event] as! [[String: Any]]).first!
            XCTAssertEqual(block["matcher"] as? String, "*", "\(event) should carry matcher=*")
        }
    }

    // MARK: - Preservation of user hooks

    func test_installPreservesExistingUserHooks() {
        let userBlock: [String: Any] = [
            "matcher": "Edit",
            "hooks": [["type": "command", "command": "/usr/local/bin/my-edit-hook"]]
        ]
        var settings: [String: Any] = [
            "hooks": ["PreToolUse": [userBlock]]
        ]

        HookInstaller.applyInstall(to: &settings, hookPath: hookPath)

        let blocks = (settings["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks.contains { ($0["matcher"] as? String) == "Edit" })
        XCTAssertTrue(blocks.contains { HookInstaller.isTermyBlock($0) })
    }

    func test_reinstallReplacesExistingTermyBlockOnly() {
        var settings: [String: Any] = [:]
        HookInstaller.applyInstall(to: &settings, hookPath: "/old/path/termy-hook")
        let userBlock: [String: Any] = [
            "matcher": "Bash",
            "hooks": [["type": "command", "command": "/usr/local/bin/audit"]]
        ]
        var hooks = settings["hooks"] as! [String: Any]
        var preTool = hooks["PreToolUse"] as! [[String: Any]]
        preTool.append(userBlock)
        hooks["PreToolUse"] = preTool
        settings["hooks"] = hooks

        HookInstaller.applyInstall(to: &settings, hookPath: hookPath)

        let final = (settings["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        let termyBlocks = final.filter { HookInstaller.isTermyBlock($0) }
        XCTAssertEqual(termyBlocks.count, 1, "should have exactly one termy block, not duplicates")
        let cmd = ((termyBlocks[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)
        XCTAssertTrue(cmd.contains(hookPath), "termy block should point at the new path")
        XCTAssertTrue(final.contains { ($0["matcher"] as? String) == "Bash" }, "user's Bash block preserved")
    }

    // MARK: - Uninstall

    func test_uninstallFromCleanInstall_removesHooksKey() {
        var settings: [String: Any] = [:]
        HookInstaller.applyInstall(to: &settings, hookPath: hookPath)
        HookInstaller.applyUninstall(from: &settings)
        XCTAssertNil(settings["hooks"], "hooks dict should be removed when empty after uninstall")
    }

    func test_uninstallPreservesUserHooks() {
        let userBlock: [String: Any] = [
            "matcher": "Edit",
            "hooks": [["type": "command", "command": "/usr/local/bin/audit"]]
        ]
        var settings: [String: Any] = [
            "hooks": ["PreToolUse": [userBlock]],
            "model": "claude-sonnet-4-6"
        ]
        HookInstaller.applyInstall(to: &settings, hookPath: hookPath)
        HookInstaller.applyUninstall(from: &settings)

        let hooks = settings["hooks"] as! [String: Any]
        let preTool = hooks["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(preTool.count, 1)
        XCTAssertEqual(preTool[0]["matcher"] as? String, "Edit")
        XCTAssertEqual(settings["model"] as? String, "claude-sonnet-4-6", "non-hooks keys untouched")
    }

    // MARK: - Marker detection

    func test_isTermyBlock_detectsMarker() {
        let block: [String: Any] = [
            HookInstaller.markerKey: true,
            "hooks": [["type": "command", "command": "/unrelated/binary"]]
        ]
        XCTAssertTrue(HookInstaller.isTermyBlock(block))
    }

    func test_isTermyBlock_fallsBackToCommandSubstring() {
        let block: [String: Any] = [
            "hooks": [["type": "command", "command": "/some/path/termy-hook Stop"]]
        ]
        XCTAssertTrue(HookInstaller.isTermyBlock(block), "must detect termy-hook even if marker was stripped")
    }

    func test_isTermyBlock_rejectsUnrelated() {
        let block: [String: Any] = [
            "matcher": "Edit",
            "hooks": [["type": "command", "command": "/usr/local/bin/my-own-hook"]]
        ]
        XCTAssertFalse(HookInstaller.isTermyBlock(block))
    }

    // MARK: - Path extraction

    func test_extractExecPath_quoted() {
        let cmd = "\"/Applications/My App/Contents/Resources/termy-hook\" SessionStart"
        XCTAssertEqual(
            HookInstaller.extractExecPath(from: cmd),
            "/Applications/My App/Contents/Resources/termy-hook"
        )
    }

    func test_extractExecPath_unquoted() {
        let cmd = "/Applications/termy.app/Contents/Resources/termy-hook Stop"
        XCTAssertEqual(
            HookInstaller.extractExecPath(from: cmd),
            "/Applications/termy.app/Contents/Resources/termy-hook"
        )
    }

    // MARK: - Stale-path detection

    func test_findInstalledPath_returnsTermyPath() {
        var settings: [String: Any] = [:]
        HookInstaller.applyInstall(to: &settings, hookPath: hookPath)
        XCTAssertEqual(HookInstaller.findInstalledPath(in: settings), hookPath)
    }

    func test_findInstalledPath_nilWhenOnlyUserHooks() {
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "matcher": "Edit",
                    "hooks": [["type": "command", "command": "/usr/local/bin/other"]]
                ]]
            ]
        ]
        XCTAssertNil(HookInstaller.findInstalledPath(in: settings))
    }
}

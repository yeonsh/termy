// HookInstaller.swift
//
// Registers termy-hook in ~/.claude/settings.json so Claude Code invokes it
// for every hook event. First launch asks the user for consent; subsequent
// launches self-heal if the app has moved (bundle path changed).
//
// Design choices:
// - Non-destructive merge: user's existing hooks are preserved. We add one
//   matcher block per event and mark it with `_termy_managed: true` so
//   uninstall / update is surgical.
// - Backup-before-write: the previous settings.json is copied to
//   settings.json.backup-<ts> before any mutation.
// - Bundle-path source of truth: hook command uses Bundle.main.bundleURL,
//   so dev builds out of DerivedData and the shipped /Applications copy
//   both work without manual reconfiguration.
// - Silent re-registration when stale: if an old termy-hook path is already
//   installed but doesn't match the running bundle, we assume the user moved
//   the app and rewrite in place without a prompt (they already opted in).

import AppKit
import Foundation

enum HookInstaller {
    /// UserDefaults key — track whether we've shown the first-run prompt so
    /// users who declined aren't pestered on every launch.
    private static let promptedKey = "termy.hookInstaller.prompted.v1"

    /// Marker field stamped on each matcher block we create. Lets us
    /// identify and remove exactly our entries during uninstall without
    /// touching the user's own hooks.
    static let markerKey = "_termy_managed"

    /// Hook events that take a "matcher" field (apply per-tool).
    private static let toolEvents = ["PreToolUse", "PostToolUse", "PostToolUseFailure"]

    /// Hook events without a matcher (lifecycle / notifications).
    private static let lifecycleEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "Stop", "StopFailure", "Notification"
    ]

    static var allEvents: [String] { lifecycleEvents + toolEvents }

    // MARK: - Paths

    static var bundledHookURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/termy-hook")
    }

    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
    }

    // MARK: - State

    enum State: Equatable {
        case notInstalled
        case installedCurrent
        case installedStale(existingPath: String)
    }

    static func currentState() -> State {
        guard
            let data = try? Data(contentsOf: settingsURL),
            !data.isEmpty,
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .notInstalled
        }
        guard let existing = findInstalledPath(in: obj) else {
            return .notInstalled
        }
        return existing == bundledHookURL.path ? .installedCurrent : .installedStale(existingPath: existing)
    }

    /// Walks the hooks dict and returns the first termy-managed entry's
    /// executable path, if any. Used for stale-path detection.
    static func findInstalledPath(in settings: [String: Any]) -> String? {
        guard let hooks = settings["hooks"] as? [String: Any] else { return nil }
        for event in allEvents {
            guard let blocks = hooks[event] as? [[String: Any]] else { continue }
            for block in blocks where isTermyBlock(block) {
                guard let inner = block["hooks"] as? [[String: Any]] else { continue }
                for hook in inner {
                    if let cmd = hook["command"] as? String,
                       let path = extractExecPath(from: cmd),
                       path.hasSuffix("/termy-hook") {
                        return path
                    }
                }
            }
        }
        return nil
    }

    // MARK: - First-launch prompt

    @MainActor
    static func promptIfNeeded() {
        switch currentState() {
        case .installedCurrent:
            return
        case .installedStale:
            // App path changed (likely moved). Silent rewrite — they opted in already.
            try? install()
        case .notInstalled:
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: promptedKey) { return }
            showPrompt(firstLaunch: true)
            defaults.set(true, forKey: promptedKey)
        }
    }

    /// Manually re-invokable via the app menu. Shows current state with
    /// Install or Uninstall options as appropriate.
    @MainActor
    static func showPromptFromMenu() {
        switch currentState() {
        case .installedCurrent:
            let alert = NSAlert()
            alert.messageText = "Claude Code hooks are installed"
            alert.informativeText = """
                termy is wired into Claude Code at:

                \(bundledHookURL.path)

                Click Uninstall to remove the termy entries from \
                ~/.claude/settings.json (your other hooks stay untouched).
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Uninstall")
            if alert.runModal() == .alertSecondButtonReturn {
                performUninstall()
            }
        case .installedStale(let oldPath):
            try? install()
            let alert = NSAlert()
            alert.messageText = "Hooks updated"
            alert.informativeText = """
                The termy binary moved. Hooks used to point at:

                \(oldPath)

                They now point at:

                \(bundledHookURL.path)
                """
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .notInstalled:
            showPrompt(firstLaunch: false)
        }
    }

    @MainActor
    private static func showPrompt(firstLaunch: Bool) {
        let alert = NSAlert()
        alert.messageText = "Install termy hooks into Claude Code?"
        alert.informativeText = """
            termy reads Claude Code's hook events to show live pane state \
            (WAITING / THINKING / IDLE). This adds a few entries to \
            ~/.claude/settings.json pointing at:

            \(bundledHookURL.path)

            Your existing hooks (if any) are preserved. The previous file is \
            backed up before writing, and you can uninstall anytime from the \
            termy menu.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: firstLaunch ? "Not now" : "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            performInstall()
        }
    }

    // MARK: - Install / Uninstall (I/O)

    @MainActor
    private static func performInstall() {
        do {
            try install()
        } catch {
            showError("Install failed", error: error)
        }
    }

    @MainActor
    private static func performUninstall() {
        do {
            try uninstall()
        } catch {
            showError("Uninstall failed", error: error)
        }
    }

    static func install() throws {
        guard FileManager.default.fileExists(atPath: bundledHookURL.path) else {
            throw HookInstallerError.hookBinaryMissing(bundledHookURL.path)
        }
        try backupIfExists()
        var settings = try readSettings()
        applyInstall(to: &settings, hookPath: bundledHookURL.path)
        try writeSettings(settings)
    }

    static func uninstall() throws {
        var settings = try readSettings()
        guard settings["hooks"] is [String: Any] else { return }
        try backupIfExists()
        applyUninstall(from: &settings)
        try writeSettings(settings)
    }

    // MARK: - Pure merge logic (testable)

    /// Merge termy hook entries into `settings` at `hookPath`. Existing
    /// termy blocks are replaced, user blocks are preserved.
    static func applyInstall(to settings: inout [String: Any], hookPath: String) {
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in lifecycleEvents {
            hooks[event] = mergedBlocks(
                for: event,
                hookPath: hookPath,
                existing: hooks[event] as? [[String: Any]] ?? [],
                withMatcher: false
            )
        }
        for event in toolEvents {
            hooks[event] = mergedBlocks(
                for: event,
                hookPath: hookPath,
                existing: hooks[event] as? [[String: Any]] ?? [],
                withMatcher: true
            )
        }
        settings["hooks"] = hooks
    }

    /// Remove termy-managed blocks, preserving user blocks. Empties out
    /// event arrays if no user blocks remain, and removes the top-level
    /// `hooks` key entirely if every event is gone.
    static func applyUninstall(from settings: inout [String: Any]) {
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in allEvents {
            guard let blocks = hooks[event] as? [[String: Any]] else { continue }
            let kept = blocks.filter { !isTermyBlock($0) }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
    }

    private static func mergedBlocks(
        for event: String,
        hookPath: String,
        existing: [[String: Any]],
        withMatcher: Bool
    ) -> [[String: Any]] {
        var kept = existing.filter { !isTermyBlock($0) }
        var ourBlock: [String: Any] = [
            markerKey: true,
            "hooks": [[
                "type": "command",
                "command": "\"\(hookPath)\" \(event)"
            ]]
        ]
        if withMatcher {
            ourBlock["matcher"] = "*"
        }
        kept.append(ourBlock)
        return kept
    }

    /// A block is ours if it carries our marker, or if its inner command
    /// references `termy-hook`. The command fallback catches blocks whose
    /// marker was stripped by a user hand-editing settings.json.
    static func isTermyBlock(_ block: [String: Any]) -> Bool {
        if block[markerKey] as? Bool == true { return true }
        guard let inner = block["hooks"] as? [[String: Any]] else { return false }
        for hook in inner {
            if let cmd = hook["command"] as? String, cmd.contains("/termy-hook") {
                return true
            }
        }
        return false
    }

    /// Extract the executable path from a shell command string. Handles
    /// both `"/path with spaces/termy-hook" SessionStart` (quoted) and
    /// `/path/termy-hook SessionStart` (unquoted) forms.
    static func extractExecPath(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") {
            let rest = trimmed.dropFirst()
            if let end = rest.firstIndex(of: "\"") {
                return String(rest[..<end])
            }
            return nil
        }
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    // MARK: - File I/O

    private static func readSettings() throws -> [String: Any] {
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.settingsNotJSONObject
        }
        return obj
    }

    private static func writeSettings(_ dict: [String: Any]) throws {
        let url = settingsURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    private static func backupIfExists() throws {
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = url.appendingPathExtension("backup-\(ts)")
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    @MainActor
    private static func showError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum HookInstallerError: LocalizedError {
    case hookBinaryMissing(String)
    case settingsNotJSONObject

    var errorDescription: String? {
        switch self {
        case .hookBinaryMissing(let path):
            return "termy-hook not found at \(path). Reinstall termy or rebuild in Xcode."
        case .settingsNotJSONObject:
            return "~/.claude/settings.json is not a JSON object. If it contains comments, remove them or edit the file manually."
        }
    }
}

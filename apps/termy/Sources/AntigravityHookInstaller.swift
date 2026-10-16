// AntigravityHookInstaller.swift
//
// Mirror of HookInstaller / CodexHookInstaller for the Antigravity CLI (`agy`).
// Antigravity loads global hooks from ~/.gemini/config/hooks.json, where each
// top-level key is a named hook group:
//
//   {
//     "termy": {
//       "enabled": true,
//       "SessionStart": [
//         { "type": "command", "command": "\".../termy-hook\" --agent antigravity SessionStart" }
//       ],
//       "PostToolUse": [
//         {
//           "matcher": "*",
//           "hooks": [
//             { "type": "command", "command": "\".../termy-hook\" --agent antigravity PostToolUse" }
//           ]
//         }
//       ]
//     }
//   }
//
// Design rules:
// - Non-destructive merge: user's other top-level hook groups (e.g.
//   "claude-context-loader") are preserved untouched. termy owns only the
//   top-level "termy" key.
// - Strict schema compliance: Antigravity unmarshals hook definitions into
//   Go structs/protobufs, so we do NOT inject custom keys like `_termy_managed`
//   inside handler objects.
// - Backup-before-write: previous hooks.json is copied to
//   hooks.json.backup-<ts> before any mutation.
// - Silent re-registration when stale: if the "termy" hook entry points at a
//   moved bundle path, rewrite in place without prompting again.

import AppKit
import Foundation

enum AntigravityHookInstaller {
    private static let promptedKey = "termy.antigravityHookInstaller.prompted.v1"

    /// Dedicated top-level key in ~/.gemini/config/hooks.json owned by termy.
    static let hookName = "termy"

    /// Lifecycle events take a flat array of command handlers.
    static let lifecycleEvents = [
        "SessionStart",
        "PreInvocation",
        "PostInvocation",
        "Stop",
    ]

    /// Tool events take an array of `{ "matcher": "*", "hooks": [...] }` groups.
    ///
    /// No `PreToolUse`: agy requires its reply to carry a `decision`
    /// ("allow" / "deny" / "ask" / "force_ask") and treats a reply without
    /// one as a deny, so termy-hook's `{}` blocked every tool call with
    /// "tool call denied by pre-tool hook: ". termy only observes, so it
    /// must not vote on permissions — tool activity comes from PostToolUse.
    static let toolEvents = [
        "PostToolUse",
    ]

    static var allEvents: [String] { lifecycleEvents + toolEvents }

    // MARK: - Paths

    static var bundledHookURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/termy-hook")
    }

    static var hooksJSONURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/config/hooks.json")
    }

    // MARK: - State

    enum State: Equatable {
        case notInstalled
        case installedCurrent
        case installedStale(existingPath: String)
        case configError(message: String)
    }

    static func currentState() -> State {
        currentState(
            hooksJSONURL: hooksJSONURL,
            hookPath: bundledHookURL.path
        )
    }

    static func currentState(
        hooksJSONURL: URL,
        hookPath: String,
        fileManager: FileManager = .default
    ) -> State {
        let settings: [String: Any]
        do {
            settings = try readHooksJSON(at: hooksJSONURL, fileManager: fileManager)
        } catch {
            return .configError(message: error.localizedDescription)
        }
        guard let existingPath = findInstalledPath(in: settings) else {
            return .notInstalled
        }
        guard existingPath == hookPath,
              isCompleteInstall(in: settings, hookPath: hookPath)
        else {
            return .installedStale(existingPath: existingPath)
        }
        return .installedCurrent
    }

    /// Inspects the top-level `"termy"` group in `hooks.json` and returns the
    /// first `termy-hook` executable path found, if any.
    static func findInstalledPath(in settings: [String: Any]) -> String? {
        guard let termyGroup = settings[hookName] as? [String: Any] else { return nil }
        for event in lifecycleEvents {
            guard let handlers = termyGroup[event] as? [[String: Any]] else { continue }
            for handler in handlers {
                if let cmd = handler["command"] as? String,
                   let path = extractExecPath(from: cmd),
                   path.hasSuffix("/termy-hook") {
                    return path
                }
            }
        }
        for event in toolEvents {
            guard let groups = termyGroup[event] as? [[String: Any]] else { continue }
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
                for handler in handlers {
                    if let cmd = handler["command"] as? String,
                       let path = extractExecPath(from: cmd),
                       path.hasSuffix("/termy-hook") {
                        return path
                    }
                }
            }
        }
        return nil
    }

    private static func isCompleteInstall(in settings: [String: Any], hookPath: String) -> Bool {
        guard let termyGroup = settings[hookName] as? [String: Any] else { return false }
        if let enabled = termyGroup["enabled"] as? Bool, !enabled {
            return false
        }
        // Events termy no longer registers (e.g. PreToolUse from earlier
        // builds) make the install stale so launch-time repair rewrites it.
        let knownKeys = Set(allEvents + ["enabled"])
        if termyGroup.keys.contains(where: { !knownKeys.contains($0) }) {
            return false
        }
        for event in lifecycleEvents {
            guard let handlers = termyGroup[event] as? [[String: Any]] else { return false }
            let expected = expectedCommand(hookPath: hookPath, event: event)
            let hasMatch = handlers.contains { ($0["command"] as? String) == expected }
            if !hasMatch { return false }
        }
        for event in toolEvents {
            guard let groups = termyGroup[event] as? [[String: Any]] else { return false }
            let expected = expectedCommand(hookPath: hookPath, event: event)
            let hasMatch = groups.contains { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                return handlers.contains { ($0["command"] as? String) == expected }
            }
            if !hasMatch { return false }
        }
        return true
    }

    private static func expectedCommand(hookPath: String, event: String) -> String {
        "\"\(hookPath)\" --agent antigravity \(event)"
    }

    // MARK: - First-launch prompt

    @MainActor
    static func promptIfNeeded() {
        switch currentState() {
        case .installedCurrent:
            return
        case .installedStale:
            try? install()
        case .configError:
            return
        case .notInstalled:
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: promptedKey) { return }
            guard antigravityCLIAppearsInstalled() else {
                defaults.set(true, forKey: promptedKey)
                return
            }
            showPrompt(firstLaunch: true)
            defaults.set(true, forKey: promptedKey)
        }
    }

    @MainActor
    static func showPromptFromMenu() {
        switch currentState() {
        case .installedCurrent:
            let alert = NSAlert()
            alert.messageText = "Antigravity hooks are installed"
            alert.informativeText = """
                termy is wired into Antigravity CLI at:

                \(bundledHookURL.path)

                Click Uninstall to remove the termy entry from \
                ~/.gemini/config/hooks.json (your other hooks stay untouched).
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
            alert.messageText = "Antigravity hooks updated"
            alert.informativeText = """
                The termy binary moved. Antigravity hooks used to point at:

                \(oldPath)

                They now point at:

                \(bundledHookURL.path)
                """
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .configError(let msg):
            let alert = NSAlert()
            alert.messageText = "Antigravity hook configuration can't be parsed"
            alert.informativeText = """
                termy won't touch ~/.gemini/config/hooks.json until you fix it:

                \(msg)

                Fix the file by hand, then reopen this dialog.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .notInstalled:
            showPrompt(firstLaunch: false)
        }
    }

    @MainActor
    private static func showPrompt(firstLaunch: Bool) {
        let alert = NSAlert()
        alert.messageText = "Install termy hooks into Antigravity CLI?"
        alert.informativeText = """
            termy reads Antigravity CLI's hook events to show live pane state \
            (WAITING / THINKING / IDLE). This adds a "termy" entry to \
            ~/.gemini/config/hooks.json pointing at:

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
            showError("Antigravity install failed", error: error)
        }
    }

    @MainActor
    private static func performUninstall() {
        do {
            try uninstall()
        } catch {
            showError("Antigravity uninstall failed", error: error)
        }
    }

    static func install() throws {
        guard FileManager.default.fileExists(atPath: bundledHookURL.path) else {
            throw AntigravityHookInstallerError.hookBinaryMissing(bundledHookURL.path)
        }
        try install(hooksJSONURL: hooksJSONURL, hookPath: bundledHookURL.path)
    }

    static func install(
        hooksJSONURL: URL,
        hookPath: String,
        fileManager: FileManager = .default
    ) throws {
        var settings = try readHooksJSON(at: hooksJSONURL, fileManager: fileManager)
        applyInstall(to: &settings, hookPath: hookPath)
        try backupIfExists(hooksJSONURL, fileManager: fileManager)
        try writeHooksJSON(settings, to: hooksJSONURL, fileManager: fileManager)
    }

    static func uninstall() throws {
        try uninstall(hooksJSONURL: hooksJSONURL)
    }

    static func uninstall(
        hooksJSONURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: hooksJSONURL.path) else { return }
        var settings = try readHooksJSON(at: hooksJSONURL, fileManager: fileManager)
        guard settings[hookName] != nil else { return }
        applyUninstall(from: &settings)
        try backupIfExists(hooksJSONURL, fileManager: fileManager)
        try writeHooksJSON(settings, to: hooksJSONURL, fileManager: fileManager)
    }

    // MARK: - Pure merge logic (testable)

    static func applyInstall(to settings: inout [String: Any], hookPath: String) {
        var termyGroup: [String: Any] = ["enabled": true]
        for event in lifecycleEvents {
            termyGroup[event] = [[
                "type": "command",
                "command": expectedCommand(hookPath: hookPath, event: event)
            ]]
        }
        for event in toolEvents {
            termyGroup[event] = [[
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": expectedCommand(hookPath: hookPath, event: event)
                ]]
            ]]
        }
        settings[hookName] = termyGroup
    }

    static func applyUninstall(from settings: inout [String: Any]) {
        settings.removeValue(forKey: hookName)
    }

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

    private static func readHooksJSON(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AntigravityHookInstallerError.hooksJSONRootInvalid
            }
            return obj
        } catch let error as AntigravityHookInstallerError {
            throw error
        } catch {
            throw AntigravityHookInstallerError.hooksJSONParseFailed(error)
        }
    }

    private static func writeHooksJSON(
        _ settings: [String: Any],
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var output = data
        output.append(0x0A)
        try output.write(to: url, options: .atomic)
    }

    private static func backupIfExists(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = url.appendingPathExtension("backup-\(ts)-\(UUID().uuidString)")
        try fileManager.copyItem(at: url, to: dest)
    }

    private static func antigravityCLIAppearsInstalled() -> Bool {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.gemini/antigravity-cli",
            "\(home)/.gemini/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "\(home)/.local/bin/agy",
            "\(home)/bin/agy",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return true }
        }
        return false
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

enum AntigravityHookInstallerError: LocalizedError {
    case hookBinaryMissing(String)
    case hooksJSONRootInvalid
    case hooksJSONParseFailed(Error)

    var errorDescription: String? {
        switch self {
        case .hookBinaryMissing(let path):
            return "termy-hook not found at \(path). Reinstall termy or rebuild in Xcode."
        case .hooksJSONRootInvalid:
            return "~/.gemini/config/hooks.json is not a JSON object."
        case .hooksJSONParseFailed(let err):
            return "Failed to parse ~/.gemini/config/hooks.json: \(err.localizedDescription)"
        }
    }
}

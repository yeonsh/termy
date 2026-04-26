// CodexHookInstaller.swift
//
// Mirror of HookInstaller for the Codex CLI. Codex stores its hook
// configuration in TOML at ~/.codex/config.toml (or repo-local
// .codex/config.toml). The schema, per developers.openai.com/codex/hooks:
//
//   [features]
//   codex_hooks = true
//
//   [[hooks.PermissionRequest]]
//   _termy_managed = true
//
//   [[hooks.PermissionRequest.hooks]]
//   type = "command"
//   command = "\"/Applications/termy.app/Contents/Resources/termy-hook\" --agent codex PermissionRequest"
//
// Design rules — parallel to HookInstaller:
// - Non-destructive merge: user's existing hook blocks are preserved.
//   Each managed block carries `_termy_managed = true`.
// - Backup-before-write: previous config.toml is copied to
//   config.toml.backup-<ts> before any mutation.
// - Bundle-path source of truth: hook command uses Bundle.main.bundleURL,
//   so dev builds and the shipped /Applications copy both work.
// - Silent re-registration when stale: if our marker exists but points at
//   a different path, rewrite without asking (the user already opted in).
//
// Codex differs from Claude Code in two ways that matter here:
//   1. TOML, not JSON. We use TOMLKit (toml++ wrapper) for parsing /
//      serializing. round-tripping a TOMLTable preserves structure but
//      does NOT preserve user comments — see the hand-edit warning in the
//      install prompt.
//   2. There's no SessionEnd event. We don't register one; the foreground-
//      process detector synthesizes it.

import AppKit
import Foundation
import TOMLKit

enum CodexHookInstaller {
    /// UserDefaults key — mirror HookInstaller's pattern, separate key so
    /// the Codex prompt and the Claude Code prompt don't share state.
    private static let promptedKey = "termy.codexHookInstaller.prompted.v1"

    /// Marker field stamped on each managed hook block.
    static let markerKey = "_termy_managed"

    /// Hook events termy registers for. Codex's six-event set per its
    /// official docs. No `SessionEnd` (doesn't exist) and no `*Failure`
    /// variants — Codex doesn't surface error info in its hook payloads,
    /// so termy infers ERRORED from the PTY exit code instead.
    static let allEvents = [
        "SessionStart",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "UserPromptSubmit",
        "Stop",
    ]

    // MARK: - Paths

    static var bundledHookURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/termy-hook")
    }

    static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/config.toml")
    }

    // MARK: - State

    enum State: Equatable {
        case notInstalled
        case installedCurrent
        case installedStale(existingPath: String)
        /// Parse failure on ~/.codex/config.toml. We refuse to auto-prompt or
        /// install when the user's config is malformed — overwriting it would
        /// destroy hand edits. Surface the message so the user can fix it.
        case configError(message: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.notInstalled, .notInstalled),
                 (.installedCurrent, .installedCurrent):
                return true
            case let (.installedStale(a), .installedStale(b)):
                return a == b
            case let (.configError(a), .configError(b)):
                return a == b
            default:
                return false
            }
        }
    }

    static func currentState() -> State {
        let table: TOMLTable
        do {
            table = try readConfig()
        } catch {
            return .configError(message: error.localizedDescription)
        }
        guard let existing = findInstalledPath(in: table) else {
            return .notInstalled
        }
        return existing == bundledHookURL.path
            ? .installedCurrent
            : .installedStale(existingPath: existing)
    }

    /// Walk the hooks tables and return the first termy-managed entry's
    /// executable path, if any. Used for stale-path detection.
    static func findInstalledPath(in config: TOMLTable) -> String? {
        guard let hooksValue = config["hooks"],
              let hooks = hooksValue.table else { return nil }
        for event in allEvents {
            guard let blocks = hooks[event]?.array else { continue }
            for i in 0..<blocks.count {
                guard let block = blocks[i].table else { continue }
                guard isTermyBlock(block) else { continue }
                guard let inner = block["hooks"]?.array else { continue }
                for j in 0..<inner.count {
                    guard let hook = inner[j].table,
                          let cmd = hook["command"]?.string,
                          let path = extractExecPath(from: cmd),
                          path.hasSuffix("/termy-hook")
                    else { continue }
                    return path
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
            // App path changed (likely moved). Silent rewrite — the user
            // already opted in.
            try? install()
        case .configError:
            // User's config has a syntax error. Never auto-prompt — we'd
            // either overwrite their hand edits or pop a scary alert at
            // launch. The menu item still surfaces the error on demand.
            return
        case .notInstalled:
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: promptedKey) { return }
            // Only ask if the user has Codex installed at all. Asking
            // every termy launch when the user only runs Claude Code is
            // noise; the menu item stays available for opt-in later.
            guard codexCLIAppearsInstalled() else {
                defaults.set(true, forKey: promptedKey)
                return
            }
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
            alert.messageText = "Codex hooks are installed"
            alert.informativeText = """
                termy is wired into Codex CLI at:

                \(bundledHookURL.path)

                Click Uninstall to remove the termy entries from \
                ~/.codex/config.toml (your other config stays untouched).
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
            alert.messageText = "Codex hooks updated"
            alert.informativeText = """
                The termy binary moved. Codex hooks used to point at:

                \(oldPath)

                They now point at:

                \(bundledHookURL.path)
                """
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .configError(let msg):
            let alert = NSAlert()
            alert.messageText = "Codex config can't be parsed"
            alert.informativeText = """
                ~/.codex/config.toml has a syntax error and termy won't \
                touch it until you fix it:

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
        alert.messageText = "Install termy hooks into Codex CLI?"
        alert.informativeText = """
            termy reads Codex's hook events to show live pane state \
            (WAITING / THINKING / IDLE). This adds a few entries to \
            ~/.codex/config.toml pointing at:

            \(bundledHookURL.path)

            It also enables `codex_hooks = true` under [features] if it \
            isn't already on. Your existing config is preserved and the \
            previous file is backed up before writing. You can uninstall \
            anytime from the termy menu.

            ⚠ TOML hand-edits and comments outside the termy-managed \
            blocks survive the merge, but TOMLKit doesn't round-trip \
            comments inside the blocks it rewrites. If you keep notes in \
            this file, back it up first.
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
            showError("Codex install failed", error: error)
        }
    }

    @MainActor
    private static func performUninstall() {
        do {
            try uninstall()
        } catch {
            showError("Codex uninstall failed", error: error)
        }
    }

    static func install() throws {
        guard FileManager.default.fileExists(atPath: bundledHookURL.path) else {
            throw CodexHookInstallerError.hookBinaryMissing(bundledHookURL.path)
        }
        // Parse first — fail closed if the user's config is malformed.
        // Backing up + writing on a parse failure would silently turn a
        // syntax error into "the file now contains only termy's blocks."
        let table = try readConfig()
        try backupIfExists()
        applyInstall(to: table, hookPath: bundledHookURL.path)
        try writeConfig(table)
    }

    static func uninstall() throws {
        // Same fail-closed contract as install(). If the config can't be
        // parsed, we have no idea what's safe to remove; surface the error.
        let table = try readConfig()
        try backupIfExists()
        applyUninstall(from: table)
        try writeConfig(table)
    }

    // MARK: - Pure merge logic (testable)

    /// Add termy hook blocks for every event in `allEvents`. Existing
    /// termy-managed blocks are replaced, user blocks are preserved.
    /// `[features] codex_hooks` is force-enabled.
    ///
    /// Implementation note: TOMLKit's `subscript = value` deep-copies on
    /// assignment, so any pattern that mutates a sub-value AFTER inserting
    /// it into a parent silently loses the mutation. Everything below
    /// builds inside-out and assigns top-down.
    static func applyInstall(to config: TOMLTable, hookPath: String) {
        // [features] codex_hooks = true — build fully, then assign.
        let features = (config["features"]?.table) ?? TOMLTable()
        features["codex_hooks"] = true
        config["features"] = features

        // Build the new hooks table fresh, carrying over any user blocks.
        let prior = config["hooks"]?.table ?? TOMLTable()
        let hooks = TOMLTable()

        // Preserve any non-termy event entries that the user already had,
        // and any unrelated keys under [hooks] (e.g. nested tables we
        // don't recognize). Iterate keys we know about first to keep a
        // predictable file layout.
        for key in prior.keys where !allEvents.contains(key) {
            if let value = prior[key] {
                hooks[key] = value
            }
        }

        for event in allEvents {
            // Carry over user blocks (filter out previous termy entries).
            let newBlocks = TOMLArray()
            if let existing = prior[event]?.array {
                for i in 0..<existing.count {
                    guard let block = existing[i].table else { continue }
                    if !isTermyBlock(block) {
                        newBlocks.append(block)
                    }
                }
            }

            // Build our managed block fully, then append.
            //   [[hooks.<Event>]]
            //   _termy_managed = true
            //   [[hooks.<Event>.hooks]]
            //   type = "command"
            //   command = "<hook> --agent codex <Event>"
            let cmd = TOMLTable()
            cmd["type"] = "command"
            cmd["command"] = "\"\(hookPath)\" --agent codex \(event)"
            let inner = TOMLArray()
            inner.append(cmd)
            let block = TOMLTable()
            block[markerKey] = true
            block["hooks"] = inner
            newBlocks.append(block)

            hooks[event] = newBlocks
        }

        config["hooks"] = hooks
    }

    /// Remove termy-managed blocks. Empties out event arrays if no user
    /// blocks remain, and removes the `hooks` key entirely if every event
    /// is gone. `[features] codex_hooks` is left alone — if the user had
    /// it on for other reasons, we don't want to break those.
    static func applyUninstall(from config: TOMLTable) {
        guard let prior = config["hooks"]?.table else { return }

        // Same inside-out rebuild — see applyInstall for why direct
        // mutation of sub-tables silently fails.
        let hooks = TOMLTable()

        // Carry over unrelated keys verbatim.
        for key in prior.keys where !allEvents.contains(key) {
            if let value = prior[key] {
                hooks[key] = value
            }
        }

        for event in allEvents {
            guard let existing = prior[event]?.array else { continue }
            let kept = TOMLArray()
            for i in 0..<existing.count {
                guard let block = existing[i].table else { continue }
                if !isTermyBlock(block) {
                    kept.append(block)
                }
            }
            if !kept.isEmpty {
                hooks[event] = kept
            }
        }

        if hooks.isEmpty {
            config.remove(at: "hooks")
        } else {
            config["hooks"] = hooks
        }
    }

    /// A block is ours if it carries our marker, or if its inner command
    /// references `termy-hook`. The command fallback catches blocks whose
    /// marker was stripped by a user hand-editing the config.
    static func isTermyBlock(_ block: TOMLTable) -> Bool {
        if block[markerKey]?.bool == true { return true }
        guard let inner = block["hooks"]?.array else { return false }
        for i in 0..<inner.count {
            guard let hook = inner[i].table,
                  let cmd = hook["command"]?.string
            else { continue }
            if cmd.contains("/termy-hook") { return true }
        }
        return false
    }

    /// Extract the executable path from a shell command string. Handles
    /// both `"/path with spaces/termy-hook" --agent codex SessionStart`
    /// (quoted) and `/path/termy-hook --agent codex SessionStart` (unquoted).
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

    private static func readConfig() throws -> TOMLTable {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TOMLTable()
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return TOMLTable() }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexHookInstallerError.configNotUTF8
        }
        do {
            return try TOMLTable(string: text)
        } catch {
            throw CodexHookInstallerError.configParseFailed(error)
        }
    }

    private static func writeConfig(_ table: TOMLTable) throws {
        let url = configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let toml = table.convert(to: .toml)
        try toml.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func backupIfExists() throws {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = url.appendingPathExtension("backup-\(ts)")
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    /// Heuristic: skip the first-launch Codex prompt for users who have no
    /// sign of Codex CLI on disk. Keeps the prompt off for Claude-only
    /// users. The menu item still works, so opt-in stays one click away.
    ///
    /// macOS apps launched from Finder/Dock get a minimal sanitized PATH
    /// (~/usr/bin:/bin:/usr/sbin:/sbin), so we can't `which codex` —
    /// `ProcessInfo.environment["PATH"]` would not contain Homebrew, mise,
    /// asdf, npm, cargo, etc. Instead, probe the well-known install spots
    /// and the `~/.codex` directory codex creates on first run regardless
    /// of where the binary lives.
    private static func codexCLIAppearsInstalled() -> Bool {
        let home = NSHomeDirectory()
        let candidates = [
            // Strongest signal: codex creates this on first run.
            "\(home)/.codex",
            // Homebrew (Apple Silicon, Intel).
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            // npm global installs.
            "/opt/homebrew/lib/node_modules/.bin/codex",
            "/usr/local/lib/node_modules/.bin/codex",
            // Rust / cargo.
            "\(home)/.cargo/bin/codex",
            // Version managers.
            "\(home)/.mise/shims/codex",
            "\(home)/.asdf/shims/codex",
            // Common user-local install spots.
            "\(home)/.local/bin/codex",
            "\(home)/bin/codex",
            "\(home)/n/bin/codex",
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

enum CodexHookInstallerError: LocalizedError {
    case hookBinaryMissing(String)
    case configNotUTF8
    case configParseFailed(Error)

    var errorDescription: String? {
        switch self {
        case .hookBinaryMissing(let path):
            return "termy-hook not found at \(path). Reinstall termy or rebuild in Xcode."
        case .configNotUTF8:
            return "~/.codex/config.toml is not valid UTF-8. Move or fix the file and try again."
        case .configParseFailed(let underlying):
            return "~/.codex/config.toml failed to parse: \(underlying). Fix the syntax and try again."
        }
    }
}

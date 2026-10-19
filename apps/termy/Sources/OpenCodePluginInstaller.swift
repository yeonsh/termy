// OpenCodePluginInstaller.swift
//
// Installs the termy-owned TUI plugin that lets opencode report pane state.
// opencode v2 discovers global plugins under
// ~/.config/opencode/plugins/<dir>/ with an entry file named `tui`, so termy
// owns exactly one file and never edits opencode.json:
//
//   ~/.config/opencode/plugins/termy/tui.js
//
// The bundled template carries a `"__TERMY_HOOK_PATH__"` placeholder (quotes
// included), replaced with the current app bundle's termy-hook path on write.
// A moved or updated termy.app is repaired silently at launch.
//
// Design rules:
// - Never merge into another tool's file: a file without termy's first-line
//   marker is `foreign`, and install/uninstall leave it untouched.
// - Atomic writes, no backups: termy can regenerate the whole file.
// - Uninstall removes the empty `termy` directory but keeps siblings.

import AppKit
import Foundation

enum OpenCodePluginInstaller {
    /// First line of every file termy writes. Used to tell our file from a
    /// user's or another plugin's.
    static let marker = "// termy-managed opencode plugin. termy rewrites this file; do not edit."

    /// Path placeholder including the surrounding quotes, replaced by a JSON
    /// string literal.
    static let hookPathPlaceholder = "\"__TERMY_HOOK_PATH__\""

    // MARK: - Paths

    static var bundledHookURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/termy-hook")
    }

    static var templateURL: URL? {
        Bundle.main.url(forResource: "tui", withExtension: "js", subdirectory: "opencode-plugin")
    }

    static var pluginFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/opencode/plugins/termy/tui.js")
    }

    // MARK: - State

    enum State: Equatable {
        case notInstalled
        case installedCurrent
        case installedStale
        case foreign(path: String)
        case configError(message: String)
    }

    static func currentState() -> State {
        guard let templateURL else {
            return .configError(message: "termy's OpenCode plugin template is missing from the app bundle.")
        }
        let template: String
        do {
            template = try String(contentsOf: templateURL, encoding: .utf8)
        } catch {
            return .configError(message: error.localizedDescription)
        }
        guard template.components(separatedBy: hookPathPlaceholder).count == 2 else {
            return .configError(message: "termy's OpenCode plugin template has no hook path placeholder.")
        }
        return currentState(
            pluginFileURL: pluginFileURL,
            expected: pluginSource(template: template, hookPath: bundledHookURL.path)
        )
    }

    static func currentState(
        pluginFileURL: URL,
        expected: String,
        fileManager: FileManager = .default
    ) -> State {
        guard fileManager.fileExists(atPath: pluginFileURL.path) else {
            return .notInstalled
        }
        let contents: String
        do {
            contents = try String(contentsOf: pluginFileURL, encoding: .utf8)
        } catch {
            return .configError(message: error.localizedDescription)
        }
        guard firstLine(of: contents) == marker else {
            return .foreign(path: pluginFileURL.path)
        }
        return contents == expected ? .installedCurrent : .installedStale
    }

    // MARK: - Pure

    /// Replaces the template's hook-path placeholder with `hookPath` encoded
    /// as a JSON/JS string literal (quotes, spaces, and backslashes escaped).
    static func pluginSource(template: String, hookPath: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(hookPath),
              let literal = String(data: data, encoding: .utf8) else {
            return template
        }
        return template.replacingOccurrences(of: hookPathPlaceholder, with: literal)
    }

    private static func firstLine(of contents: String) -> String {
        contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    // MARK: - Install / Uninstall (I/O)

    static func install() throws {
        guard FileManager.default.fileExists(atPath: bundledHookURL.path) else {
            throw OpenCodePluginInstallerError.hookBinaryMissing(bundledHookURL.path)
        }
        guard let templateURL else {
            throw OpenCodePluginInstallerError.templateUnavailable(
                "termy's OpenCode plugin template is missing from the app bundle."
            )
        }
        let template: String
        do {
            template = try String(contentsOf: templateURL, encoding: .utf8)
        } catch {
            throw OpenCodePluginInstallerError.templateUnavailable(error.localizedDescription)
        }
        guard template.components(separatedBy: hookPathPlaceholder).count == 2 else {
            throw OpenCodePluginInstallerError.templateUnavailable(
                "termy's OpenCode plugin template has no hook path placeholder."
            )
        }
        try install(
            pluginFileURL: pluginFileURL,
            contents: pluginSource(template: template, hookPath: bundledHookURL.path)
        )
    }

    static func install(
        pluginFileURL: URL,
        contents: String,
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: pluginFileURL.path) {
            let existing = try String(contentsOf: pluginFileURL, encoding: .utf8)
            guard firstLine(of: existing) == marker else {
                throw OpenCodePluginInstallerError.foreignFile(pluginFileURL.path)
            }
        }
        try fileManager.createDirectory(
            at: pluginFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: pluginFileURL, atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        try uninstall(pluginFileURL: pluginFileURL)
    }

    static func uninstall(
        pluginFileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: pluginFileURL.path) else { return }
        let existing = try String(contentsOf: pluginFileURL, encoding: .utf8)
        guard firstLine(of: existing) == marker else {
            throw OpenCodePluginInstallerError.foreignFile(pluginFileURL.path)
        }
        try fileManager.removeItem(at: pluginFileURL)

        let directory = pluginFileURL.deletingLastPathComponent()
        if let entries = try? fileManager.contentsOfDirectory(atPath: directory.path), entries.isEmpty {
            try? fileManager.removeItem(at: directory)
        }
    }

    // MARK: - Launch / Menu

    /// Rewrites a stale install (termy moved or updated). Other states are
    /// left alone; in particular, this never prompts.
    @MainActor
    static func refreshIfInstalled() {
        guard case .installedStale = currentState() else { return }
        try? install()
    }

    @MainActor
    static func showPromptFromMenu() {
        switch currentState() {
        case .installedCurrent:
            let alert = NSAlert()
            alert.messageText = "OpenCode plugin is installed"
            alert.informativeText = """
                termy reads OpenCode's session state through a plugin at:

                \(pluginFileURL.path)

                Click Uninstall to remove it. Your other OpenCode plugins stay untouched.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Uninstall")
            if alert.runModal() == .alertSecondButtonReturn {
                performUninstall()
            }

        case .installedStale:
            try? install()
            let alert = NSAlert()
            alert.messageText = "OpenCode plugin updated"
            alert.informativeText = """
                termy rewrote its OpenCode plugin so it points at:

                \(bundledHookURL.path)
                """
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .foreign(let path):
            let alert = NSAlert()
            alert.messageText = "termy won't touch this OpenCode plugin file"
            alert.informativeText = """
                A file termy didn't create is already at:

                \(path)

                Move or delete it, then reopen this dialog.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .configError(let msg):
            let alert = NSAlert()
            alert.messageText = "OpenCode plugin can't be set up"
            alert.informativeText = msg
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .notInstalled:
            let alert = NSAlert()
            alert.messageText = "Install the termy plugin into OpenCode?"
            alert.informativeText = """
                termy reads OpenCode's session state through a TUI plugin to show live pane state (WAITING / THINKING / IDLE). This writes one file:

                \(pluginFileURL.path)

                OpenCode sessions that are already open pick it up too. You can uninstall anytime from this menu.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                performInstall()
            }
        }
    }

    @MainActor
    private static func performInstall() {
        do {
            try install()
        } catch {
            showError("OpenCode plugin install failed", error: error)
        }
    }

    @MainActor
    private static func performUninstall() {
        do {
            try uninstall()
        } catch {
            showError("OpenCode plugin uninstall failed", error: error)
        }
    }

    @MainActor
    private static func showError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum OpenCodePluginInstallerError: LocalizedError {
    case hookBinaryMissing(String)
    case templateUnavailable(String)
    case foreignFile(String)

    var errorDescription: String? {
        switch self {
        case .hookBinaryMissing(let path):
            return "termy-hook not found at \(path). Reinstall termy or rebuild in Xcode."
        case .templateUnavailable(let message):
            return message
        case .foreignFile(let path):
            return "\(path) was not created by termy, so termy leaves it alone."
        }
    }
}

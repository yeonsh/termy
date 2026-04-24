// FullDiskAccess.swift
//
// First-launch guidance for macOS TCC (Transparency, Consent, Control).
// termy is non-sandboxed (must be, to spawn zsh / claude as children), so
// every time the child shell touches ~/Desktop, ~/Documents, ~/Downloads,
// ~/Music, etc., macOS prompts the PARENT APP for consent. That's a miserable
// first-run experience.
//
// The fix is one-time Full Disk Access: System Settings ▸ Privacy & Security
// ▸ Full Disk Access ▸ add termy. We can't grant it programmatically, but we
// can detect whether it's already granted and deep-link to the correct pane.

import AppKit
import Foundation

enum FullDiskAccess {
    /// UserDefaults key — track whether we've shown the first-run prompt so
    /// returning users aren't pestered.
    private static let promptedKey = "termy.fullDiskAccess.prompted.v1"

    /// Canary read of ~/Library/Safari — that directory is TCC-protected on
    /// every macOS since 10.15. If `contentsOfDirectory` succeeds we have
    /// Full Disk Access (or the equivalent per-folder grants); if it throws
    /// a permission error, we don't.
    static var isGranted: Bool {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// Deep-link to the Full Disk Access pane in System Settings (macOS 13+).
    static func openSettingsPane() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Show the first-launch prompt if it hasn't been shown before AND
    /// access isn't already granted. Safe to call from applicationDidFinishLaunching.
    @MainActor
    static func promptIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: promptedKey) { return }
        if isGranted { return }
        showPrompt(firstLaunch: true)
        defaults.set(true, forKey: promptedKey)
    }

    /// Manually re-invokable via the app menu. Shows the same dialog and,
    /// if access is already granted, says so.
    @MainActor
    static func showPromptFromMenu() {
        if isGranted {
            let alert = NSAlert()
            alert.messageText = "Full Disk Access is already granted."
            alert.informativeText = "termy can read files across your Mac without macOS prompts. If you ever see a permission dialog from termy, it's for something outside the usual Desktop / Documents / Downloads / Music folders."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        showPrompt(firstLaunch: false)
    }

    @MainActor
    private static func showPrompt(firstLaunch: Bool) {
        let alert = NSAlert()
        alert.messageText = "Grant termy Full Disk Access"
        alert.informativeText = """
            termy is a terminal, so it spawns your shell (\(shellName())) and Claude Code as \
            child processes. Any file those children read in ~/Desktop, ~/Documents, \
            ~/Downloads, ~/Music, or similar folders triggers a macOS permission prompt \
            targeting termy — there will be a lot of them unless you grant Full Disk Access \
            once.

            Click "Open System Settings," then drag termy into the Full Disk Access list \
            (or click +, then find termy.app). You'll need to relaunch termy after.

            This is the same one-time setup Terminal.app, iTerm2, and every other non-\
            sandboxed Mac terminal needs.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: firstLaunch ? "Skip for now" : "Close")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSettingsPane()
        }
    }

    private static func shellName() -> String {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return (shellPath as NSString).lastPathComponent
    }
}

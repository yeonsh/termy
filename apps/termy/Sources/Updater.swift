// Updater.swift
//
// Thin wrapper around Sparkle's SPUStandardUpdaterController. Instantiated
// once from AppDelegate.applicationDidFinishLaunching; takes over the
// "Check for Updates…" menu item target. No delegate methods — Sparkle's
// defaults cover prompt UX, signature verification, and error dialogs.

import AppKit
import Sparkle

@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    override private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}

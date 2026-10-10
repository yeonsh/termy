// Updater.swift
//
// Wrapper around Sparkle's SPUStandardUpdaterController. Instantiated once
// on first access (the app menu); takes over the "Check for Updates…" menu
// item target. Sparkle's defaults cover prompt UX, signature verification,
// and error dialogs. The delegate adds two things so updates don't cost
// agent sessions (docs/superpowers/specs/2026-10-10-agent-resume-after-update-design.md):
//   * hold the relaunch while an agent is mid-turn (`UpdateRelaunchGate`)
//   * right before relaunching, save each pane's agent session so the new
//     version resumes it (`onWillRelaunch` → `WindowManager`)

import AppKit
import Sparkle

@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController!

    let gate: UpdateRelaunchGate

    /// Set by AppDelegate: the final session save before Sparkle relaunches.
    var onWillRelaunch: (() -> Void)?

    override private init() {
        gate = UpdateRelaunchGate(
            midTurnCount: { MissionControlModel.shared.midTurnPaneCount },
            schedule: MainQueueTimer.schedule,
            presentPrompt: UpdateRelaunchGate.presentAlert(busyCount:completion:)
        )
        super.init()
        // `self` is the delegate, so the controller is created after
        // super.init. Sparkle holds the delegate weakly; `shared` keeps it.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    @objc func restartNowToInstallUpdate(_ sender: Any?) {
        gate.restartNow()
    }
}

extension Updater: SPUUpdaterDelegate {
    // Sparkle calls its delegate on the main thread.

    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        nonisolated(unsafe) let handler = installHandler
        return MainActor.assumeIsolated {
            gate.begin { handler() }
        }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            onWillRelaunch?()
        }
    }
}

// UpdateRelaunchGate.swift
//
// Holds a Sparkle update relaunch while any agent is mid-turn
// (`PaneSnapshot.isMidTurn`). Restarting mid-turn kills work that
// `claude --resume` / `codex resume` can't bring back; between turns the
// resumed conversation loses nothing.
//
// Flow: Sparkle asks to relaunch → `begin` → agents busy? ask the user
// (Wait for Agents / Restart Now) → while waiting, re-count on every
// snapshot or live-pane change → zero, and still zero `settleDelay` later
// → run Sparkle's install handler exactly once.

import AppKit

enum UpdateRelaunchChoice {
    case waitForAgents
    case restartNow
}

@MainActor
final class UpdateRelaunchGate {
    /// Re-check this long after the count first reaches zero, so a queued
    /// message that starts the next turn right after Stop isn't cut off.
    static let settleDelay: TimeInterval = 2

    typealias PresentPrompt = @MainActor (
        _ busyCount: Int,
        _ completion: @escaping @MainActor (UpdateRelaunchChoice) -> Void
    ) -> Void

    private enum Phase {
        case idle
        case prompting
        case waiting
        case released
    }

    private let midTurnCount: @MainActor () -> Int
    private let schedule: ScheduleAfter
    private let presentPrompt: PresentPrompt
    private var phase: Phase = .idle
    private var installHandler: (@MainActor () -> Void)?
    private var cancelSettle: (@MainActor () -> Void)?

    /// Fires when `isPending` flips, so the app menu can show or hide
    /// "Restart Now to Install Update".
    var onPendingChanged: (@MainActor () -> Void)?

    /// True while a relaunch is held: the prompt is up or we're waiting.
    var isPending: Bool { phase == .prompting || phase == .waiting }

    init(
        midTurnCount: @escaping @MainActor () -> Int,
        schedule: @escaping ScheduleAfter,
        presentPrompt: @escaping PresentPrompt
    ) {
        self.midTurnCount = midTurnCount
        self.schedule = schedule
        self.presentPrompt = presentPrompt
    }

    /// Sparkle's `shouldPostponeRelaunchForUpdate`. Returns false (relaunch
    /// now) when no agent is mid-turn; otherwise keeps `installHandler`,
    /// asks the user, and returns true.
    func begin(installHandler: @escaping @MainActor () -> Void) -> Bool {
        if isPending {
            self.installHandler = installHandler
            return true
        }
        let busy = midTurnCount()
        guard busy > 0 else { return false }
        self.installHandler = installHandler
        setPhase(.prompting)
        presentPrompt(busy) { [weak self] choice in
            self?.handle(choice)
        }
        return true
    }

    /// Call whenever pane snapshots or the set of live panes change. No
    /// effect unless the user chose to wait.
    func reevaluate() {
        guard phase == .waiting else { return }
        if midTurnCount() == 0 {
            guard cancelSettle == nil else { return }
            cancelSettle = schedule(Self.settleDelay) { [weak self] in self?.settleElapsed() }
        } else {
            cancelSettle?()
            cancelSettle = nil
        }
    }

    /// "Restart Now to Install Update" in the app menu.
    func restartNow() {
        guard isPending else { return }
        release()
    }

    static func promptTitle(busyCount: Int) -> String {
        busyCount == 1 ? "1 agent is still working" : "\(busyCount) agents are still working"
    }

    /// The production prompt: an NSAlert on the next run-loop turn, so
    /// Sparkle's delegate callback returns before the modal starts.
    static func presentAlert(
        busyCount: Int,
        completion: @escaping @MainActor (UpdateRelaunchChoice) -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = promptTitle(busyCount: busyCount)
                alert.informativeText = "termy will restart to install the update when they finish their current turn. Other programs running in panes will still be stopped."
                alert.addButton(withTitle: "Wait for Agents")
                alert.addButton(withTitle: "Restart Now")
                let response = alert.runModal()
                completion(response == .alertFirstButtonReturn ? .waitForAgents : .restartNow)
            }
        }
    }

    private func handle(_ choice: UpdateRelaunchChoice) {
        guard phase == .prompting else { return }
        switch choice {
        case .restartNow:
            release()
        case .waitForAgents:
            setPhase(.waiting)
            reevaluate()
        }
    }

    private func settleElapsed() {
        cancelSettle = nil
        guard phase == .waiting else { return }
        if midTurnCount() == 0 {
            release()
        }
    }

    private func release() {
        cancelSettle?()
        cancelSettle = nil
        let handler = installHandler
        installHandler = nil
        setPhase(.released)
        handler?()
    }

    private func setPhase(_ next: Phase) {
        let wasPending = isPending
        phase = next
        if wasPending != isPending {
            onPendingChanged?()
        }
    }
}

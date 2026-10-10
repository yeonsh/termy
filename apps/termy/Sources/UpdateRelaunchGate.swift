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
// → run Sparkle's install handler exactly once. Still busy after
// `reminderInterval` → ask again (an Esc-interrupted Claude turn sends no
// Stop, so the wait can otherwise sit unseen until the next prompt).

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

    /// While waiting, ask again this often. Claude sends no Stop after an
    /// Esc interrupt, so the wait can last until the next prompt.
    static let reminderInterval: TimeInterval = 600

    /// Names the menu escape, since an interrupted turn can hold the update
    /// with nothing else on screen saying so.
    static let promptBody = "termy will restart to install the update when they finish their current turn. To restart sooner, choose termy ▸ Restart Now to Install Update. Other programs running in panes will still be stopped."

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
    private var cancelReminder: (@MainActor () -> Void)?

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
        prompt(busyCount: busy)
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

    /// Only the explicit "Restart Now" button restarts; an aborted or
    /// stopped modal must never kill agents.
    static func choice(for response: NSApplication.ModalResponse) -> UpdateRelaunchChoice {
        response == .alertSecondButtonReturn ? .restartNow : .waitForAgents
    }

    /// The production prompt: an NSAlert on the next run-loop turn, so
    /// Sparkle's delegate callback returns before the modal starts.
    /// Scheduled with `RunLoop.main.perform`, not GCD: a `runModal()` inside a
    /// `DispatchQueue.main.async` block keeps the serial main queue busy, so
    /// PTY drains and hook deliveries stall until the alert closes. A run-loop
    /// callout lets the modal run loop keep draining the main queue.
    static func presentAlert(
        busyCount: Int,
        completion: @escaping @MainActor (UpdateRelaunchChoice) -> Void
    ) {
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = promptTitle(busyCount: busyCount)
                alert.informativeText = promptBody
                alert.addButton(withTitle: "Wait for Agents")
                alert.addButton(withTitle: "Restart Now")
                let response = alert.runModal()
                completion(choice(for: response))
            }
        }
    }

    /// Show the prompt; the answer goes to `handle`. Used by `begin` and by
    /// the reminder, so both answers take the same path.
    private func prompt(busyCount: Int) {
        setPhase(.prompting)
        presentPrompt(busyCount) { [weak self] choice in
            self?.handle(choice)
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
            cancelReminder?()
            cancelReminder = schedule(Self.reminderInterval) { [weak self] in self?.reminderElapsed() }
        }
    }

    private func settleElapsed() {
        cancelSettle = nil
        guard phase == .waiting else { return }
        if midTurnCount() == 0 {
            release()
        }
    }

    /// Ask again while agents are still busy. At zero the settle timer
    /// already owns the release.
    private func reminderElapsed() {
        cancelReminder = nil
        guard phase == .waiting else { return }
        let busy = midTurnCount()
        guard busy > 0 else { return }
        prompt(busyCount: busy)
    }

    private func release() {
        cancelSettle?()
        cancelSettle = nil
        cancelReminder?()
        cancelReminder = nil
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

// MainQueueTimer.swift
//
// One-shot main-queue timer with a cancel handle. `StartupInputScheduler`
// and `UpdateRelaunchGate` take a `ScheduleAfter` instead of calling this
// directly, so tests can drive time by hand (`ManualScheduler`).

import Foundation

/// Run `action` after `delay`; the returned closure cancels it.
typealias ScheduleAfter = @MainActor (
    _ delay: TimeInterval,
    _ action: @escaping @MainActor () -> Void
) -> @MainActor () -> Void

enum MainQueueTimer {
    @MainActor
    static func schedule(
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }
}

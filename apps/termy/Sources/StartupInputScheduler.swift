// StartupInputScheduler.swift
//
// Decides when a restored pane types its agent-resume command into the
// fresh shell: once output has been quiet for `quietInterval` after any
// bytes (the prompt has most likely drawn), or at `deadline` after start
// no matter what. Early input would still work — the PTY buffers it until
// the shell reads — waiting only keeps the command from echoing above the
// prompt.

import Foundation

@MainActor
final class StartupInputScheduler {
    static let quietInterval: TimeInterval = 0.3
    static let deadline: TimeInterval = 3.0

    private let schedule: ScheduleAfter
    private let fire: @MainActor () -> Void
    private var cancelQuiet: (@MainActor () -> Void)?
    private var cancelDeadline: (@MainActor () -> Void)?
    private(set) var hasFired = false

    init(schedule: @escaping ScheduleAfter, fire: @escaping @MainActor () -> Void) {
        self.schedule = schedule
        self.fire = fire
    }

    /// Call right after the shell process starts.
    func start() {
        cancelDeadline = schedule(Self.deadline) { [weak self] in self?.fireOnce() }
    }

    /// Call for every chunk of PTY output.
    func outputReceived() {
        guard !hasFired else { return }
        cancelQuiet?()
        cancelQuiet = schedule(Self.quietInterval) { [weak self] in self?.fireOnce() }
    }

    private func fireOnce() {
        guard !hasFired else { return }
        hasFired = true
        cancelQuiet?()
        cancelDeadline?()
        cancelQuiet = nil
        cancelDeadline = nil
        fire()
    }
}

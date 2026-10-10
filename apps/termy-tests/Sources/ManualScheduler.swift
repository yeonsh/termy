import Foundation
@testable import termy

/// Test double for `ScheduleAfter`: records scheduled actions and runs them
/// only when the test advances the clock.
@MainActor
final class ManualScheduler {
    private struct Entry {
        let id: Int
        let fireAt: TimeInterval
        let action: @MainActor () -> Void
    }

    private var entries: [Entry] = []
    private var nextId = 0
    private(set) var now: TimeInterval = 0

    var pendingCount: Int { entries.count }

    var schedule: ScheduleAfter {
        { [unowned self] delay, action in
            let id = self.nextId
            self.nextId += 1
            self.entries.append(Entry(id: id, fireAt: self.now + delay, action: action))
            return { [weak self] in self?.entries.removeAll { $0.id == id } }
        }
    }

    /// Move the clock forward, firing due actions in time order.
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = entries
            .filter({ $0.fireAt <= target })
            .min(by: { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }) {
            entries.removeAll { $0.id == next.id }
            now = next.fireAt
            next.action()
        }
        now = target
    }
}

/// Mutable counter that `@MainActor` closures can capture.
@MainActor
final class Counter {
    var value = 0
}

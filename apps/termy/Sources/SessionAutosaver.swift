// SessionAutosaver.swift
//
// Debounced bridge between live window/pane mutations and the on-disk
// `SessionPersistence`. Mirrors `WorkspaceAutosaver`'s 500ms coalescing:
// pane added/closed, window moved/resized, and window added/closed all
// call `requestSave()`, which collapses bursts into one write.

import Foundation

@MainActor
final class SessionAutosaver {
    let persistence: SessionPersistence
    private weak var windowManager: WindowManager?
    private let debounceNanos: UInt64
    private var pendingTask: Task<Void, Never>?
    private var inFlightFlush: Task<Void, Never>?

    init(
        persistence: SessionPersistence,
        windowManager: WindowManager,
        debounceMillis: Int = 500
    ) {
        self.persistence = persistence
        self.windowManager = windowManager
        self.debounceNanos = UInt64(debounceMillis) * 1_000_000
    }

    /// Coalescing save request — call on any session-relevant mutation.
    func requestSave() {
        pendingTask?.cancel()
        let nanos = debounceNanos
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.performSave()
        }
    }

    /// Synchronous flush for shutdown. Joins an in-flight flush instead of
    /// starting a redundant second write.
    func flushSync() async {
        if let inFlight = inFlightFlush {
            await inFlight.value
            return
        }
        pendingTask?.cancel()
        pendingTask = nil
        let task = Task { @MainActor in await self.performSave() }
        inFlightFlush = task
        await task.value
        inFlightFlush = nil
    }

    private func performSave() async {
        guard let windowManager else { return }
        let records = windowManager.controllers.compactMap { $0.sessionWindowRecord() }
        let session = SessionRecord(windows: records)
        try? await persistence.save(session)
    }
}

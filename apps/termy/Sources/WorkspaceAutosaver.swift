// WorkspaceAutosaver.swift
//
// Debounced bridge between live Workspace/Pane mutations and the on-disk
// `WorkspacePersistence` actor. Every mutation signal calls `requestSave()`;
// the autosaver collapses bursts into a single save 500ms after the last
// signal. Grouping per canonical project path happens here, not in
// `WorkspacePersistence` — the persistence layer only knows about one
// record at a time.
//
// Why 500ms:
//   `cd` into a deep subtree can emit a flurry of OSC-7 events across N
//   panes in a few milliseconds. Writing N files per pane-drift would
//   pound the disk and race the previous writer. 500ms is the smallest
//   window that feels "instant" to a human but coalesces a burst cleanly.
//
// Thread discipline:
//   The autosaver is @MainActor. It captures pane / cwd / label info while
//   on the main actor (reading from `Workspace.panes` and `Pane.currentCwd`),
//   then hops onto the serial `WorkspacePersistence` actor for the actual
//   write. No two writes to the same record run in parallel because
//   `WorkspacePersistence` is an actor.

import Foundation

@MainActor
final class WorkspaceAutosaver {
    let persistence: WorkspacePersistence
    private weak var workspace: Workspace?
    private let debounceNanos: UInt64
    private var pendingTask: Task<Void, Never>?

    init(
        persistence: WorkspacePersistence,
        workspace: Workspace,
        debounceMillis: Int = 500
    ) {
        self.persistence = persistence
        self.workspace = workspace
        self.debounceNanos = UInt64(debounceMillis) * 1_000_000
    }

    /// Call on any mutation that might change pane state: pane added/closed,
    /// cwd drifted. Coalesces bursts.
    func requestSave() {
        pendingTask?.cancel()
        let nanos = debounceNanos
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.performSave()
        }
    }

    /// Synchronous flush for `applicationWillTerminate` — cancels any
    /// pending debounce and writes the current snapshot before returning.
    func flushSync() async {
        pendingTask?.cancel()
        pendingTask = nil
        await performSave()
    }

    // MARK: - Save pipeline

    private func performSave() async {
        guard let workspace else { return }

        // Snapshot the live grid structure into a Sendable payload.
        struct PaneInfo: Sendable {
            let paneId: String
            let cwd: String
            let canonical: String
            let label: String
        }
        // rows[i] is the workspace's i-th horizontal row.
        let wsRows: [[PaneInfo]] = workspace.rows.map { row in
            row.map { pane in
                let cwd = pane.currentCwd
                return PaneInfo(
                    paneId: pane.paneId,
                    cwd: cwd,
                    canonical: ProjectIdentity.canonicalPath(for: cwd),
                    label: ProjectIdentity.derive(for: cwd)
                )
            }
        }
        // Empty workspace — nothing to save. Don't write an empty record.
        if wsRows.flatMap({ $0 }).isEmpty { return }

        // Per-project aggregation that preserves the row structure: for each
        // workspace row, we split it by project and append each project's
        // slice as a row in that project's record. A project whose panes
        // straddle multiple workspace rows gets its own multi-row record.
        struct ProjectAccum {
            var displayLabel: String
            var rows: [[PaneRecord]] = []
        }
        var perProject: [String: ProjectAccum] = [:]

        for wsRow in wsRows {
            var sliceByProject: [String: [PaneRecord]] = [:]
            var encounterOrder: [String] = []
            for info in wsRow {
                let rec = PaneRecord(cwd: info.cwd)
                if sliceByProject[info.canonical] == nil {
                    encounterOrder.append(info.canonical)
                    sliceByProject[info.canonical] = [rec]
                } else {
                    sliceByProject[info.canonical]!.append(rec)
                }
                perProject[info.canonical, default: ProjectAccum(displayLabel: info.label)]
                    .displayLabel = info.label
            }
            for canonical in encounterOrder {
                let slice = sliceByProject[canonical]!
                perProject[canonical]!.rows.append(slice)
            }
        }

        for (canonical, accum) in perProject {
            let flatPanes = accum.rows.flatMap { $0 }
            let record = WorkspaceRecord(
                canonicalPath: canonical,
                displayLabel: accum.displayLabel,
                panes: flatPanes,
                rows: accum.rows
            )
            try? await persistence.save(record)
        }
    }
}

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
//
// 원격 pane은 cwd가 그 머신의 경로라 이 Mac의 worktree로 묶을 수 없다(묶으면 로컬로 다시 열리는 가짜 project가
// 생긴다). 그래서 만들 때 정한 project 키(`<machine>:<folder>`)로 묶어 원격 기록으로 남긴다. pane id는 ⌘K
// 기록에 남기지 않는다: 창을 닫으면 그 terminal은 kill되므로 다시 붙을 것이 없다.

import Foundation

@MainActor
final class WorkspaceAutosaver {
    let persistence: WorkspacePersistence
    private weak var workspace: Workspace?
    private let debounceNanos: UInt64
    private var pendingTask: Task<Void, Never>?
    /// Tracks the currently running `flushSync` so a pre-emptive flush from
    /// `MainWindowController` (kicked when the last pane closes) and the
    /// shutdown flush in `applicationWillTerminate` coalesce into one save
    /// instead of writing the same snapshot twice.
    private var inFlightFlush: Task<Void, Never>?

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

    /// Synchronous flush for shutdown — cancels any pending debounce and
    /// writes the current snapshot before returning. If a flush is already
    /// in flight (e.g. `MainWindowController` pre-emptively started one when
    /// the last pane closed), join that task instead of starting a second
    /// redundant write.
    func flushSync() async {
        if let inFlight = inFlightFlush {
            await inFlight.value
            return
        }
        pendingTask?.cancel()
        pendingTask = nil
        let task = Task { @MainActor in
            await self.performSave()
        }
        inFlightFlush = task
        await task.value
        inFlightFlush = nil
    }

    // MARK: - Save pipeline

    private func performSave() async {
        guard let workspace else { return }

        // Snapshot the live grid structure into a Sendable payload.
        // rows[i] is the workspace's i-th horizontal row.
        let wsRows: [[PaneInfo]] = workspace.rows.map { row in row.map { PaneInfo(pane: $0) } }
        for record in Self.records(rows: wsRows, now: Date()) {
            try? await persistence.save(record)
        }
    }
}

extension WorkspaceAutosaver {
    /// pane 하나가 ⌘K 기록에 남기는 것.
    struct PaneInfo: Sendable, Equatable {
        var cwd: String
        /// 이 pane이 들어갈 기록의 키: local은 cwd의 worktree root, 원격은 project 키(`<machine>:<folder>`).
        var key: String
        var label: String
        /// 원격 pane의 머신. local(로컬 hc 포함)은 nil.
        var machine: String?

        @MainActor init(pane: Pane) {
            let cwd = pane.currentCwd
            if let machine = pane.launch.machine {
                self.init(cwd: cwd, key: pane.projectKey, label: pane.projectId, machine: machine)
            } else {
                self.init(cwd: cwd, key: ProjectIdentity.canonicalPath(for: cwd), label: ProjectIdentity.derive(for: cwd),
                          machine: nil)
            }
        }

        init(cwd: String, key: String, label: String, machine: String?) {
            self.cwd = cwd
            self.key = key
            self.label = label
            self.machine = machine
        }

        /// local pane은 지금처럼 cwd만 남긴다(다시 열 때 지금 설정을 따른다). 원격 pane은 다시 열 머신과 project를 남긴다.
        var paneRecord: PaneRecord {
            guard let machine else { return PaneRecord(cwd: cwd) }
            return PaneRecord(cwd: cwd, backend: .hc, machine: machine, projectId: label, projectKey: key)
        }
    }

    /// Per-project aggregation that preserves the row structure: for each
    /// workspace row, we split it by project and append each project's
    /// slice as a row in that project's record. A project whose panes
    /// straddle multiple workspace rows gets its own multi-row record.
    /// An empty workspace gives no records (never write an empty one).
    nonisolated static func records(rows wsRows: [[PaneInfo]], now: Date) -> [WorkspaceRecord] {
        struct ProjectAccum {
            var displayLabel: String
            var machine: String?
            var rows: [[PaneRecord]] = []
        }
        var perProject: [String: ProjectAccum] = [:]

        for wsRow in wsRows {
            var sliceByProject: [String: [PaneRecord]] = [:]
            var encounterOrder: [String] = []
            for info in wsRow {
                let rec = info.paneRecord
                if sliceByProject[info.key] == nil {
                    encounterOrder.append(info.key)
                    sliceByProject[info.key] = [rec]
                } else {
                    sliceByProject[info.key]!.append(rec)
                }
                perProject[info.key, default: ProjectAccum(displayLabel: info.label, machine: info.machine)]
                    .displayLabel = info.label
            }
            for key in encounterOrder {
                let slice = sliceByProject[key]!
                perProject[key]!.rows.append(slice)
            }
        }

        return perProject.map { key, accum in
            WorkspaceRecord(
                canonicalPath: key,
                displayLabel: accum.displayLabel,
                updatedAt: now,
                panes: accum.rows.flatMap { $0 },
                rows: accum.rows,
                machine: accum.machine
            )
        }
    }
}

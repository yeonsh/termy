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

        // project마다 보이는 분할 tree를 Sendable 값으로 떠 둔다(떠난 잎은 없다).
        let layouts = workspace.layoutSnapshot().map { $0.tree.map { PaneInfo(pane: $0) } }
        for record in Self.records(layouts: layouts, now: Date()) {
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

    /// 기록 키별로 묶는다: project tree마다 그 키의 pane만 남긴 tree(빼기 규칙, 비율 유지)가 그 키 기록의 `layout`이고,
    /// `panes`는 잎 읽는 순서, `rows`는 예전 빌드가 읽을 열 근사다. 한 키가 project tree 여럿에서 나오면(드문 경우)
    /// 그 tree들을 좌우로 균등하게 묶는다. pane이 없으면 기록도 없다(빈 기록은 쓰지 않는다).
    nonisolated static func records(layouts: [PaneLayoutNode<PaneInfo>], now: Date) -> [WorkspaceRecord] {
        struct ProjectAccum {
            var displayLabel: String
            var machine: String?
            var trees: [PaneLayoutNode<PaneInfo>] = []
        }
        var perProject: [String: ProjectAccum] = [:]

        for tree in layouts {
            var keys: [String] = []
            for info in tree.leaves {
                if !keys.contains(info.key) { keys.append(info.key) }
                perProject[info.key, default: ProjectAccum(displayLabel: info.label, machine: info.machine)]
                    .displayLabel = info.label
            }
            for key in keys {
                guard let pruned = tree.removing(where: { $0.key != key }) else { continue }
                perProject[key]!.trees.append(pruned)
            }
        }

        return perProject.compactMap { key, accum in
            let joined: PaneLayoutNode<PaneInfo>
            switch accum.trees.count {
            case 0: return nil
            case 1: joined = accum.trees[0]
            default:
                let weight = 1 / Double(accum.trees.count)
                joined = PaneLayoutNode.split(.leftToRight, accum.trees.map { .init(node: $0, weight: weight) }).normalized()
            }
            let layout = joined.map(\.paneRecord)
            return WorkspaceRecord(
                canonicalPath: key,
                displayLabel: accum.displayLabel,
                updatedAt: now,
                panes: layout.leaves,
                rows: layout.approximateColumns(),
                machine: accum.machine,
                layout: layout
            )
        }
    }
}

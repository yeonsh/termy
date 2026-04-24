// MissionControlModel.swift
//
// Bridges HookDaemon (actor, concurrency-isolated) to the SwiftUI view layer.
// Drains HookDaemon.updates on a background task, applies changes to a
// @MainActor @Observable snapshot array, and publishes a sorted view that the
// MissionControlView renders directly.
//
// Sort order: fixed position by pane creation order. State-priority sorting
// was reshuffling chips whenever a pane transitioned (THINK→IDLE→WAIT), which
// made the user lose track of which chip was which. With a stable position,
// state changes only alter a chip's color/label; its slot on the bar doesn't
// move. INIT-without-attention still hidden as before.

import AppKit
import Foundation
import Observation

/// Per-pane display label sourced from the pane's live header (project folder
/// basename + git branch). Kept in the mission-control model so chips can
/// read "api / main" instead of a meaningless UUID fragment.
struct PaneDisplayLabel: Equatable, Sendable {
    var project: String
    var branch: String?
}

@MainActor
@Observable
final class MissionControlModel {
    /// Displayed snapshots, already sorted.
    private(set) var items: [PaneSnapshot] = []

    /// Pane header labels pushed by Workspace each time a pane's header
    /// recomputes (OSC 7 cd's, project reassignment). The view reads via
    /// `label(for:)` — which falls back to the snapshot's projectId / cwd
    /// basename when no header has fired yet (e.g. on very first render).
    private(set) var labelsByPaneId: [String: PaneDisplayLabel] = [:]

    /// Known pane IDs that the window controller thinks exist. Lets us filter
    /// out snapshots for panes that were closed (daemon hasn't dropped them
    /// from its map, but we don't want zombie items on the bar).
    private var livePaneIds: Set<String> = []

    /// Stable ordering — position on the bar is fixed by pane creation order.
    /// Sourced from `Workspace.panes` (a creation-order array) via
    /// `setLivePaneIds`, so a new pane always gets appended on the right and
    /// existing chips never shuffle on state change.
    private var paneOrder: [String: Int] = [:]

    /// Raw snapshot map keyed by paneId, overwritten on each DaemonUpdate.
    private var snapshotsById: [String: PaneSnapshot] = [:]

    /// Keeps a strong ref so ARC doesn't cancel it; [weak self] in the body
    /// means the pump exits naturally when the model deallocates.
    private var pumpTask: Task<Void, Never>?

    /// Called on the main actor after each HookDaemon update is folded into
    /// our snapshot map. The window controller forwards this to Notifier —
    /// we route through a single subscriber of HookDaemon.updates because
    /// AsyncStream has a single consumer (two `for await`s would race and
    /// silently split events).
    var onSnapshotUpdate: ((PaneSnapshot) -> Void)?

    init() {
        pumpTask = Task { [weak self] in
            await self?.pumpUpdates()
        }
    }

    /// Called by the window controller whenever a pane is added or removed.
    /// `orderedIds` is the workspace's pane list in creation order — used to
    /// assign stable positions on the dashboard bar.
    func setLivePaneIds(_ orderedIds: [String]) {
        livePaneIds = Set(orderedIds)
        paneOrder = Dictionary(
            uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) }
        )
        // Drop labels for panes that no longer exist.
        labelsByPaneId = labelsByPaneId.filter { livePaneIds.contains($0.key) }
        recomputeItems()
    }

    /// Pushed by Workspace whenever a pane's header recomputes.
    func setLabel(paneId: String, project: String, branch: String?) {
        let new = PaneDisplayLabel(project: project, branch: branch)
        if labelsByPaneId[paneId] != new {
            labelsByPaneId[paneId] = new
        }
    }

    /// Best-effort display label for a snapshot. Prefers the live header
    /// label pushed from the pane; falls back to snapshot's projectId, then
    /// to the cwd basename, then to a short UUID so something always shows.
    func label(for snapshot: PaneSnapshot) -> PaneDisplayLabel {
        if let pushed = labelsByPaneId[snapshot.paneId] {
            return pushed
        }
        if let project = snapshot.projectId, !project.isEmpty {
            return PaneDisplayLabel(project: project, branch: nil)
        }
        if let cwd = snapshot.lastCwd, !cwd.isEmpty {
            let basename = (cwd as NSString).lastPathComponent
            if !basename.isEmpty {
                return PaneDisplayLabel(project: basename, branch: nil)
            }
        }
        return PaneDisplayLabel(project: String(snapshot.paneId.prefix(8)), branch: nil)
    }

    private func pumpUpdates() async {
        for await update in HookDaemon.shared.updates {
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.snapshotsById[update.snapshot.paneId] = update.snapshot
                self.recomputeItems()
                self.onSnapshotUpdate?(update.snapshot)
            }
        }
    }

    /// Hard cap on dashboard items. Beyond this, the UI can't render chips
    /// legibly even at maximum compression — older items (creation order)
    /// win, newer ones are hidden from the bar. 32 also matches the outer
    /// per-window pane limit we expect in practice.
    static let maxDashboardItems = 32

    private func recomputeItems() {
        let visible = snapshotsById.values.filter { snap in
            guard livePaneIds.contains(snap.paneId) else { return false }
            // Hide panes that haven't left INIT unless they have attention.
            return snap.state != .initializing || snap.needsAttention
        }
        let sorted = visible.sorted { a, b in
            let oa = paneOrder[a.paneId] ?? Int.max
            let ob = paneOrder[b.paneId] ?? Int.max
            if oa != ob { return oa < ob }
            return a.paneId < b.paneId
        }
        items = Array(sorted.prefix(Self.maxDashboardItems))
    }
}

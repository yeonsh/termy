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

    /// Union of every registered window's pane IDs. Drives chip filtering.
    private(set) var livePaneIds: Set<String> = []

    /// Global chip position: window-registration order, then pane order
    /// within each window. Flattened from `paneIdsByWindow` on every change.
    private(set) var paneOrder: [String: Int] = [:]

    /// Window registration order — windows appear on the bar in the order
    /// they were first registered.
    private var windowOrder: [UUID] = []

    /// Per-window ordered pane IDs, keyed by `MainWindowController.windowId`.
    private var paneIdsByWindow: [UUID: [String]] = [:]

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

    /// Single app-wide instance. Every window's `MissionControlView`
    /// observes this one model, and it is the sole consumer of
    /// `HookDaemon.shared.updates` (an AsyncStream allows only one).
    static let shared = MissionControlModel()

    /// `startPump: false` is used by unit tests so a throwaway model does
    /// not race the shared instance for `HookDaemon.updates` events.
    init(startPump: Bool = true) {
        if startPump {
            pumpTask = Task { [weak self] in
                await self?.pumpUpdates()
            }
        }
    }

    /// Register (or replace) one window's ordered pane list. Called by each
    /// `MainWindowController` whenever its workspace pane set changes.
    /// `windowId` is `MainWindowController.windowId`.
    func setLivePaneIds(_ orderedIds: [String], forWindow windowId: UUID) {
        if !windowOrder.contains(windowId) {
            windowOrder.append(windowId)
        }
        paneIdsByWindow[windowId] = orderedIds
        rebuildGlobalOrder()
    }

    /// Drop a window's panes from the dashboard when its window closes.
    func removeWindow(_ windowId: UUID) {
        windowOrder.removeAll { $0 == windowId }
        paneIdsByWindow.removeValue(forKey: windowId)
        rebuildGlobalOrder()
    }

    /// Flatten every window's pane list into the global `livePaneIds` /
    /// `paneOrder`, then drop stale labels and recompute the chips.
    private func rebuildGlobalOrder() {
        var flat: [String] = []
        for windowId in windowOrder {
            flat.append(contentsOf: paneIdsByWindow[windowId] ?? [])
        }
        livePaneIds = Set(flat)
        paneOrder = Dictionary(
            uniqueKeysWithValues: flat.enumerated().map { ($1, $0) }
        )
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
    /// win, newer ones are hidden from the bar. With multi-window this is a
    /// global cap across every window's panes combined.
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
        let next = Array(sorted.prefix(Self.maxDashboardItems))
        // @Observable invalidates on every assignment, regardless of value
        // equality. Most hook events stamp `updatedAt`/`lastPtyActivityAt`
        // without changing what the dashboard actually renders, so reusing
        // a synthesized PaneSnapshot Equatable here would still flip on
        // every event — and a flip costs an entire SwiftUI re-measure
        // (CenteredFlow × ViewThatFits's 4 variants + measurement probe),
        // which is what was pegging the main thread on 9-pane windows.
        // Compare only the fields the chips actually read.
        if !Self.haveSameDashboardShape(items, next) {
            items = next
        }
    }

    /// Compares two `items` arrays using the subset of `PaneSnapshot`
    /// fields that the dashboard actually renders. Excludes timestamps
    /// (`updatedAt`, `enteredStateAt`, `lastPtyActivityAt`) and identity
    /// fields the chip view never reads (`lastSessionId`, `lastPrompt`,
    /// `lastAssistantMessage`) so timestamp-only updates don't trigger a
    /// SwiftUI re-measure. Internal so unit tests can verify which fields
    /// participate.
    nonisolated static func haveSameDashboardShape(
        _ a: [PaneSnapshot],
        _ b: [PaneSnapshot]
    ) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices where !sameDashboardShape(a[i], b[i]) {
            return false
        }
        return true
    }

    nonisolated static func sameDashboardShape(_ a: PaneSnapshot, _ b: PaneSnapshot) -> Bool {
        a.paneId == b.paneId
            && a.projectId == b.projectId
            && a.state == b.state
            && a.needsAttention == b.needsAttention
            && a.notificationReason == b.notificationReason
            && a.waitSource == b.waitSource
            && a.lastCwd == b.lastCwd
            && a.agentKind == b.agentKind
    }
}

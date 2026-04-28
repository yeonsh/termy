// Workspace.swift
//
// Replaces the NSTabView + PaneContainer model. A single grid of all panes
// in the window, with a project filter (`.all` | `.project(id)`) controlling
// which panes are visible. Same project → same color (via PaneStyling) now
// does double duty as both visual identity AND filter key.
//
// Layout: nested NSSplitView — outer vertical (rows), each row is a
// horizontal NSSplitView of panes. Row assignment is explicit: column split
// (⌘D) appends to the focused pane's row, row split (⇧⌘D) inserts a new row
// right after it. Rebuilt on every visibility change. Moving an NSView
// between superviews preserves its state, so the pty and SwiftTerm renderer
// keep running across filter switches.
//
//   Workspace (NSView)
//     └── rootSplit (NSSplitView, vertical)
//           ├── rowSplit₁ (horizontal) — [pane, pane, pane]
//           ├── rowSplit₂ (horizontal) — [pane, pane]
//           └── ...

import AppKit
import Foundation
import QuartzCore

enum WorkspaceFilter: Equatable {
    case all
    case project(String)

    var isAll: Bool { if case .all = self { return true } else { return false } }
}

enum WorkspaceFilterOptions {
    static func options(projectIds: [String]) -> [WorkspaceFilter] {
        let projectOptions = projectIds.map { WorkspaceFilter.project($0) }
        guard projectIds.count > 1 else { return projectOptions }
        return [.all] + projectOptions
    }

    static func allShortcutTarget(projectIds: [String]) -> WorkspaceFilter? {
        options(projectIds: projectIds).contains(.all) ? .all : nil
    }

    static func projectShortcutTarget(projectIds: [String], number: Int) -> WorkspaceFilter? {
        guard number >= 1, number <= projectIds.count else { return nil }
        return .project(projectIds[number - 1])
    }

    static func shortcutHint(for option: WorkspaceFilter, projectIds: [String]) -> String? {
        switch option {
        case .all:
            return "0"
        case .project(let id):
            guard let index = projectIds.firstIndex(of: id) else { return nil }
            return "\(index + 1)"
        }
    }
}

enum SplitAxis {
    case column
    case row
    case balanced
}

struct BalancedPaneLayoutRow: Equatable {
    var index: Int
    var paneCount: Int
}

enum BalancedPanePlacement: Equatable {
    case append(toRow: Int)
    case insertRow(after: Int)
}

enum BalancedPanePlacementPlanner {
    static func placement(
        rows: [BalancedPaneLayoutRow],
        workspaceSize: CGSize,
        preferredRow _: Int?
    ) -> BalancedPanePlacement? {
        let candidates = rows.filter { $0.paneCount > 0 }
        guard !candidates.isEmpty else { return nil }

        let leastFilledCount = candidates.map(\.paneCount).min() ?? 0
        let leastFilledRows = candidates.filter { $0.paneCount == leastFilledCount }
        guard let target = leastFilledRows.min(by: { $0.index < $1.index }) else {
            return nil
        }

        let rowCount = max(CGFloat(candidates.count), 1)
        let width = max(workspaceSize.width, 1) / rowCount
        let height = max(workspaceSize.height, 1) / CGFloat(target.paneCount)

        if width >= height {
            let rightmostEqualSizedRow = leastFilledRows.map(\.index).max() ?? target.index
            return .insertRow(after: rightmostEqualSizedRow)
        }
        return .append(toRow: target.index)
    }
}

struct PaneFocusHistory {
    private var paneIds: [String] = []

    mutating func markFocused(_ paneId: String) {
        paneIds.removeAll { $0 == paneId }
        paneIds.append(paneId)
    }

    mutating func remove(_ paneId: String) {
        paneIds.removeAll { $0 == paneId }
    }

    func mostRecent(in candidateIds: [String]) -> String? {
        for paneId in paneIds.reversed() where candidateIds.contains(paneId) {
            return paneId
        }
        return nil
    }

    func focusAfterVisibilityChange(
        currentPaneId: String?,
        visiblePaneIds: [String]
    ) -> String? {
        guard !visiblePaneIds.isEmpty else { return nil }
        if let currentPaneId, visiblePaneIds.contains(currentPaneId) {
            return currentPaneId
        }
        return mostRecent(in: visiblePaneIds) ?? visiblePaneIds.first
    }
}

struct FilterNavigationHistory {
    private var filters: [WorkspaceFilter] = []

    mutating func markVisited(_ filter: WorkspaceFilter) {
        filters.removeAll { $0 == filter }
        filters.append(filter)
    }

    mutating func popMostRecentValid(in options: [WorkspaceFilter]) -> WorkspaceFilter? {
        while let last = filters.popLast() {
            if options.contains(last) {
                return last
            }
        }
        return nil
    }

    mutating func remove(_ filter: WorkspaceFilter) {
        filters.removeAll { $0 == filter }
    }

    mutating func filterToRestore(in options: [WorkspaceFilter]) -> WorkspaceFilter? {
        popMostRecentValid(in: options) ?? options.first
    }
}

final class Workspace: NSView, NSSplitViewDelegate {
    /// Source of truth for pane layout: ordered rows of ordered panes. A
    /// column split appends to the focused pane's row; a row split inserts a
    /// fresh row immediately after it.
    private(set) var rows: [[Pane]] = []
    private var paneCreationOrder: [Pane] = []
    private var focusHistory = PaneFocusHistory()
    var panes: [Pane] { paneCreationOrder }
    private(set) var focusedPane: Pane?
    var filter: WorkspaceFilter = .all {
        didSet {
            guard oldValue != filter else { return }
            // A filter change implicitly exits "single-pane focus" — if we
            // kept maximizedPane set, relayout() would still short-circuit to
            // [maximizedPane] and the user would see one pane under ALL.
            maximizedPane = nil
            relayout()
            onFilterChanged?()
        }
    }

    /// Notifies MainWindowController when the pane set changes (add/close)
    /// so it can refresh the mission-control model's live-pane set AND the
    /// toolbar's filter segments.
    var onPanesChanged: (() -> Void)?
    /// Separate callback so the toolbar can repaint the selected segment
    /// when filter changes from within Workspace (e.g. dashboard click
    /// jumping to another project auto-switches the filter).
    var onFilterChanged: (() -> Void)?
    /// Fires when a pane's derived header label (project folder + git branch)
    /// changes — on init and on every `cd`. The mission-control bar listens
    /// so chips read "api / main" instead of "pane-<uuid>".
    var onPaneHeaderChanged: ((_ paneId: String, _ project: String, _ branch: String?) -> Void)?

    private var rootSplit: NSSplitView?
    private var maximizedPane: Pane?
    private let hiddenPaneParkingView = NSView(frame: .zero)
    private var parkedPaneFrames: [ObjectIdentifier: CGRect] = [:]
    private var needsPostRelayoutEqualize = false
    private var isEqualizingSplits = false
    /// Each `installRootSplit` that wraps panes in a freeze adds one token.
    /// Tokens are drained either when the deferred equalize pass runs in
    /// `layout()` or by an async fallback — whichever fires first.
    private var pendingTerminalThaws = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupHiddenPaneParking()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layout() {
        super.layout()
        guard needsPostRelayoutEqualize, !isEqualizingSplits else { return }
        guard let rootSplit, rootSplit.bounds.width > 1, rootSplit.bounds.height > 1 else {
            needsPostRelayoutEqualize = true
            return
        }
        needsPostRelayoutEqualize = false
        withoutRelayoutAnimation {
            equalizeSplits()
        }
        flushPendingTerminalThaws()
    }

    /// Drain every outstanding freeze token: each pending thaw releases one
    /// freeze layer on every pane's terminal, and the last release fires one
    /// `setFrameSize` with the captured final size — pushing one stable
    /// SIGWINCH to the PTY instead of the burst of intermediate ones AppKit
    /// generates while NSSplitView reparents arranged subviews.
    private func flushPendingTerminalThaws() {
        while pendingTerminalThaws > 0 {
            pendingTerminalThaws -= 1
            for pane in panes {
                pane.terminal.thawSizePropagation()
            }
        }
        // A pane parked under `hiddenPaneParkingView` keeps receiving PTY
        // writes (and SwiftTerm clears its `refreshStart/refreshEnd` after
        // each `updateDisplay` tick), but AppKit doesn't draw a hidden
        // ancestor. When the pane is reparented back into the visible split
        // tree, only cells the PTY *next* writes get repainted — earlier
        // updates show through as fragments on a blank background. Force a
        // full redraw at the transaction boundary so unparked panes catch up
        // to the buffer. Cheap, idempotent, and panes that didn't change
        // parent just re-paint identical pixels.
        for pane in panes {
            pane.terminal.terminal.updateFullScreen()
            pane.terminal.setNeedsDisplay(pane.terminal.bounds)
        }
    }

    // MARK: - Filter helpers

    /// Sorted, unique list of project ids currently represented by an open
    /// pane. Used by the toolbar to build filter segments. Order is by
    /// first-pane-opened so segments don't reshuffle when user opens more.
    var knownProjectIds: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for pane in panes where seen.insert(pane.projectId).inserted {
            out.append(pane.projectId)
        }
        return out
    }

    private func isVisible(_ pane: Pane) -> Bool {
        switch filter {
        case .all: return true
        case .project(let id): return pane.projectId == id
        }
    }

    private var visiblePanes: [Pane] {
        panes.filter(isVisible)
    }

    // MARK: - Add / close

    @discardableResult
    func addPane(
        cwd: String? = nil,
        splitAxis: SplitAxis = .balanced
    ) -> Pane {
        // Project id = focused pane's project if available, else derive
        // from cwd or the current filter.
        let projectId: String = {
            if let cwd, !cwd.isEmpty {
                return ProjectIdentity.derive(for: cwd)
            }
            if let focused = focusedPane {
                return focused.projectId
            }
            if case .project(let id) = filter { return id }
            return ProjectIdentity.derive(for: FileManager.default.homeDirectoryForCurrentUser.path)
        }()

        let pane = Pane(
            projectId: projectId,
            cwd: cwd ?? focusedPane?.currentCwd
        )
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.onPaneClicked = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.focus(pane: pane)
        }
        pane.onProjectChanged = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.handlePaneProjectChanged(pane)
        }
        pane.onHeaderChanged = { [weak self, weak pane] project, branch in
            guard let self, let pane else { return }
            self.onPaneHeaderChanged?(pane.paneId, project, branch)
        }
        pane.onShellExited = { [weak self, weak pane] _ in
            guard let self, let pane else { return }
            self.closePane(pane)
        }

        paneCreationOrder.append(pane)
        place(pane, splitAxis: splitAxis)

        // Any new pane exits maximize mode — otherwise ⌘N silently creates
        // the pane but relayout() keeps showing only the previously
        // maximized one, which reads as "⌘N is broken".
        maximizedPane = nil

        // If adding a pane that doesn't match the current filter, switch
        // the filter to show it. Otherwise the user would be confused by a
        // "⌘N did nothing" experience.
        if !isVisible(pane) {
            filter = .project(projectId)
        } else {
            relayout()
        }
        focus(pane: pane)
        onPanesChanged?()
        return pane
    }

    private func place(_ pane: Pane, splitAxis: SplitAxis) {
        // Place the new pane relative to the focused pane per the requested
        // split axis. With no focused pane (first pane or after closing the
        // last one) start a fresh row.
        guard let focused = focusedPane, let (r, _) = locate(focused) else {
            rows.append([pane])
            return
        }

        switch splitAxis {
        case .column:
            rows[r].append(pane)
        case .row:
            rows.insert([pane], at: r + 1)
        case .balanced:
            placeBalanced(pane, preferredRow: r)
        }
    }

    private func placeBalanced(_ pane: Pane, preferredRow: Int?) {
        let visibleRows = rows.enumerated().compactMap { index, row -> BalancedPaneLayoutRow? in
            let count = row.filter(isVisible).count
            guard count > 0 else { return nil }
            return BalancedPaneLayoutRow(index: index, paneCount: count)
        }
        guard let placement = BalancedPanePlacementPlanner.placement(
            rows: visibleRows,
            workspaceSize: bounds.size,
            preferredRow: preferredRow
        ) else {
            rows.append([pane])
            return
        }

        switch placement {
        case .append(toRow: let rowIndex):
            rows[rowIndex].append(pane)
        case .insertRow(after: let rowIndex):
            rows.insert([pane], at: rowIndex + 1)
        }
    }

    private func locate(_ pane: Pane) -> (row: Int, col: Int)? {
        for (r, row) in rows.enumerated() {
            if let c = row.firstIndex(where: { $0 === pane }) {
                return (r, c)
            }
        }
        return nil
    }

    /// Closes the focused pane. Returns true if the workspace is now empty
    /// (caller should close the window).
    @discardableResult
    func closeFocusedPane() -> Bool {
        guard let focused = focusedPane else { return panes.isEmpty }
        return closePaneInternal(focused, wasFocused: true)
    }

    /// Closes an arbitrary pane — used by the shell-exit auto-close path so a
    /// pty that died (user typed `exit`, hit Ctrl-D, shell crashed) doesn't
    /// leave behind a blank rectangle. Re-entry safe: if the pane has already
    /// been torn down (e.g. closeFocusedPane already fired teardown and the
    /// resulting processTerminated is calling us back), this is a no-op.
    func closePane(_ pane: Pane) {
        guard locate(pane) != nil else { return }
        _ = closePaneInternal(pane, wasFocused: focusedPane === pane)
    }

    @discardableResult
    private func closePaneInternal(_ pane: Pane, wasFocused: Bool) -> Bool {
        teardown(pane: pane)

        if panes.isEmpty {
            onPanesChanged?()
            return true
        }

        if wasFocused {
            // If the current filter no longer has any panes, fall back to .all.
            if visiblePanes.isEmpty {
                filter = .all
            } else {
                relayout()
            }
            let fallbackPaneId = focusHistory.mostRecent(in: visiblePanes.map(\.paneId))
            focusedPane = visiblePanes.first { $0.paneId == fallbackPaneId } ?? visiblePanes.first
            if let focusedPane {
                focusHistory.markFocused(focusedPane.paneId)
            }
            updateActivePaneAppearance()
            focusedPane?.focusTerminal()
        } else {
            relayout()
        }
        onPanesChanged?()
        return false
    }

    private func teardown(pane: Pane) {
        // Clear the shell-exit callback first — teardown calls terminate()
        // which fires processTerminated → onShellExited; we'd otherwise
        // recurse right back into closePane.
        pane.onShellExited = nil
        pane.terminal.process.terminate()
        pane.removeFromSuperview()
        if maximizedPane === pane { maximizedPane = nil }
        parkedPaneFrames.removeValue(forKey: ObjectIdentifier(pane))
        focusHistory.remove(pane.paneId)
        paneCreationOrder.removeAll { $0 === pane }
        for r in 0..<rows.count {
            rows[r].removeAll { $0 === pane }
        }
        rows.removeAll { $0.isEmpty }
    }

    /// Invoked when a pane's projectId drifted (user `cd`d to another
    /// project folder). Rebuilds the filter bar; follows the drifted pane
    /// in two cases:
    ///   • the active filter now points at a project with zero panes, OR
    ///   • the focused pane itself is what drifted — the user actively
    ///     typed `cd` into that pane, so its view disappearing reads as
    ///     "pane died" rather than a filter change. Following keeps the
    ///     pane visible; user can swap filters back manually if desired.
    private func handlePaneProjectChanged(_ pane: Pane) {
        if case .project(let id) = filter {
            let filterWouldBeEmpty = !panes.contains(where: { $0.projectId == id })
            let focusedPaneDriftedOut = (pane === focusedPane) && pane.projectId != id
            if filterWouldBeEmpty || focusedPaneDriftedOut {
                filter = .project(pane.projectId)
                return
            }
        }
        // Filter still valid. If the drifted pane no longer matches the
        // active filter, relayout so it moves out of view; otherwise just
        // rebuild the toolbar segments.
        if !isVisible(pane) {
            relayout()
        }
        onPanesChanged?()
    }

    // MARK: - Focus

    func focus(pane: Pane) {
        // Focusing a different pane exits maximize mode — so a click /
        // dashboard jump / arrow-key navigation to another pane doesn't
        // keep the old single-pane layout rendered.
        let exitedMaximize = maximizedPane != nil && maximizedPane !== pane
        if exitedMaximize {
            maximizedPane = nil
        }

        // Target pane may be in a filtered-out project. Widen the filter
        // (or switch to its project) so the user actually sees it.
        if !isVisible(pane) {
            filter = .project(pane.projectId) // relayout via filter didSet
        } else if exitedMaximize {
            relayout()
        }
        focusedPane = pane
        focusHistory.markFocused(pane.paneId)
        updateActivePaneAppearance()
        pane.focusTerminal()
    }

    func focusFirstPane() {
        if let pane = visiblePanes.first {
            focus(pane: pane)
        }
    }

    func focusPane(byId paneId: String) -> Bool {
        guard let pane = panes.first(where: { $0.paneId == paneId }) else { return false }
        focus(pane: pane)
        return true
    }

    func cycleFocus(delta: Int) {
        let vis = visiblePanes
        guard !vis.isEmpty, let current = focusedPane,
              let idx = vis.firstIndex(where: { $0 === current }) else {
            vis.first.map { focus(pane: $0) }
            return
        }
        let next = (idx + delta + vis.count) % vis.count
        focus(pane: vis[next])
    }

    func focusPaneInDirection(_ direction: FocusDirection) {
        let vis = visiblePanes
        guard let current = focusedPane, vis.count > 1 else { return }
        let origin = current.convert(
            CGPoint(x: current.bounds.midX, y: current.bounds.midY),
            to: self
        )

        var best: (pane: Pane, score: CGFloat)? = nil
        for candidate in vis where candidate !== current {
            let c = candidate.convert(
                CGPoint(x: candidate.bounds.midX, y: candidate.bounds.midY),
                to: self
            )
            let dx = c.x - origin.x
            let dy = c.y - origin.y
            let inDirection: Bool
            let along: CGFloat
            let across: CGFloat
            switch direction {
            case .left:  inDirection = dx < -1; along = -dx; across = abs(dy)
            case .right: inDirection = dx >  1; along =  dx; across = abs(dy)
            case .up:    inDirection = dy >  1; along =  dy; across = abs(dx)
            case .down:  inDirection = dy < -1; along = -dy; across = abs(dx)
            }
            guard inDirection else { continue }
            let score = along + across * 2
            if best == nil || score < best!.score {
                best = (candidate, score)
            }
        }
        if let winner = best?.pane {
            focus(pane: winner)
        }
    }

    // MARK: - Filter cycling (⌘⇧[ / ⌘⇧])

    /// Filter options in display order. ALL appears only when there are
    /// multiple project filters to collapse into a single view.
    var filterOptions: [WorkspaceFilter] {
        WorkspaceFilterOptions.options(projectIds: knownProjectIds)
    }

    func cycleFilter(delta: Int) {
        let opts = filterOptions
        guard opts.count > 1 else { return }
        let idx = opts.firstIndex(of: filter) ?? 0
        let next = (idx + delta + opts.count) % opts.count
        filter = opts[next]
    }

    func selectAllFilter() {
        guard let target = WorkspaceFilterOptions.allShortcutTarget(
            projectIds: knownProjectIds
        ) else {
            return
        }
        filter = target
    }

    func selectProjectFilter(at index: Int) {
        guard let target = WorkspaceFilterOptions.projectShortcutTarget(
            projectIds: knownProjectIds,
            number: index + 1
        ) else {
            return
        }
        filter = target
    }

    // MARK: - Maximize / restore (⌘↵)

    func toggleMaximize() {
        if maximizedPane != nil {
            maximizedPane = nil
            relayout()
        } else {
            guard let focused = focusedPane else { return }
            maximizedPane = focused
            relayout()
        }
    }

    // MARK: - Layout

    /// Rebuild the grid from the current row structure. Moves existing Pane
    /// NSViews between superviews — their pty/terminal state persists.
    private func relayout() {
        let visibleRows: [[Pane]] = {
            if let m = maximizedPane, isVisible(m) { return [[m]] }
            return rows.map { $0.filter(isVisible) }.filter { !$0.isEmpty }
        }()
        guard !visibleRows.isEmpty else {
            installRootSplit(nil)
            return
        }

        // Re-focus the pane that was last active inside this filter. If this
        // filter has never had focus, fall back to the first visible pane.
        let visiblePaneList = visibleRows.flatMap { $0 }
        let visiblePaneIds = visiblePaneList.map(\.paneId)
        let nextFocusedPaneId = focusHistory.focusAfterVisibilityChange(
            currentPaneId: focusedPane?.paneId,
            visiblePaneIds: visiblePaneIds
        )
        if focusedPane?.paneId != nextFocusedPaneId {
            focusedPane = visiblePaneList.first { $0.paneId == nextFocusedPaneId }
            if let focusedPane {
                focusHistory.markFocused(focusedPane.paneId)
            }
        }

        let outer = makeSplit(vertical: true)
        installRootSplit(outer, visiblePanes: visiblePaneList) {
            self.populate(outer: outer, visibleRows: visibleRows)
        }

        updateActivePaneAppearance()
        // Always re-assert firstResponder on the focused pane's terminal:
        // removeFromSuperview() above broke the window's firstResponder
        // chain, so without this the user types and hears the system beep
        // until they click a pane. Affects ⌘↵ (maximize) and filter switches.
        focusedPane?.focusTerminal()
    }

    private func setupHiddenPaneParking() {
        hiddenPaneParkingView.isHidden = true
        hiddenPaneParkingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hiddenPaneParkingView)
        NSLayoutConstraint.activate([
            hiddenPaneParkingView.topAnchor.constraint(equalTo: topAnchor),
            hiddenPaneParkingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hiddenPaneParkingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hiddenPaneParkingView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    private func populate(outer: NSSplitView, visibleRows: [[Pane]]) {
        let outerFrame = bounds.insetBy(dx: 4, dy: 4)
        outer.frame = outerFrame

        let projectIds = Set(visibleRows.flatMap { $0.map(\.projectId) })
        if filter.isAll && projectIds.count > 1 {
            populateProjectGrid(outer: outer, frame: outerFrame, visibleRows: visibleRows)
        } else {
            populateColumns(outer: outer, frame: outerFrame, visibleRows: visibleRows)
        }
    }

    private func populateColumns(outer: NSSplitView, frame: CGRect, visibleRows: [[Pane]]) {
        outer.isVertical = true
        let columnCount = max(visibleRows.count, 1)
        let columnWidth = frame.width / CGFloat(columnCount)
        for (rowIndex, rowPanes) in visibleRows.enumerated() {
            let row = makeSplit(vertical: false)
            row.frame = CGRect(
                x: CGFloat(rowIndex) * columnWidth,
                y: 0,
                width: columnWidth,
                height: frame.height
            )
            outer.addArrangedSubview(row)

            let paneCount = max(rowPanes.count, 1)
            let paneHeight = frame.height / CGFloat(paneCount)
            for (paneIndex, pane) in rowPanes.enumerated() {
                pane.frame = CGRect(
                    x: 0,
                    y: frame.height - CGFloat(paneIndex + 1) * paneHeight,
                    width: columnWidth,
                    height: paneHeight
                )
                row.addArrangedSubview(pane)
            }
        }
    }

    /// ALL 뷰에서 프로젝트가 둘 이상일 때, 각 프로젝트의 row/column 배치를
    /// 보존한 채 프로젝트 셀들을 √N 그리드(예: 4 → 2×2)에 균등 배치한다.
    /// 기존 단일 프로젝트 경로(`populateColumns`)와 달리 4단계 split이 된다:
    ///   outer(grid-rows) → grid-row(cells) → cell(columns) → column(panes)
    private func populateProjectGrid(outer: NSSplitView, frame: CGRect, visibleRows: [[Pane]]) {
        let clusters = clusterRowsByProject(visibleRows: visibleRows)
        guard !clusters.isEmpty else {
            populateColumns(outer: outer, frame: frame, visibleRows: visibleRows)
            return
        }

        let n = clusters.count
        let cols = max(Int(ceil(Double(n).squareRoot())), 1)
        let gridRows = (n + cols - 1) / cols
        let cellHeight = frame.height / CGFloat(gridRows)

        outer.isVertical = false

        for gridRow in 0..<gridRows {
            let start = gridRow * cols
            let end = min(start + cols, n)
            let clustersInRow = Array(clusters[start..<end])
            guard !clustersInRow.isEmpty else { continue }

            let rowSplit = makeSplit(vertical: true)
            rowSplit.frame = CGRect(
                x: 0,
                y: frame.height - CGFloat(gridRow + 1) * cellHeight,
                width: frame.width,
                height: cellHeight
            )
            outer.addArrangedSubview(rowSplit)

            let cellCount = max(clustersInRow.count, 1)
            let cellWidth = frame.width / CGFloat(cellCount)

            for (cellIdx, cluster) in clustersInRow.enumerated() {
                let cell = makeSplit(vertical: true)
                cell.frame = CGRect(
                    x: CGFloat(cellIdx) * cellWidth,
                    y: 0,
                    width: cellWidth,
                    height: cellHeight
                )
                rowSplit.addArrangedSubview(cell)

                let columnCount = max(cluster.count, 1)
                let columnWidth = cellWidth / CGFloat(columnCount)
                for (colIdx, columnPanes) in cluster.enumerated() {
                    let column = makeSplit(vertical: false)
                    column.frame = CGRect(
                        x: CGFloat(colIdx) * columnWidth,
                        y: 0,
                        width: columnWidth,
                        height: cellHeight
                    )
                    cell.addArrangedSubview(column)

                    let paneCount = max(columnPanes.count, 1)
                    let paneHeight = cellHeight / CGFloat(paneCount)
                    for (paneIdx, pane) in columnPanes.enumerated() {
                        pane.frame = CGRect(
                            x: 0,
                            y: cellHeight - CGFloat(paneIdx + 1) * paneHeight,
                            width: columnWidth,
                            height: paneHeight
                        )
                        column.addArrangedSubview(pane)
                    }
                }
            }
        }
    }

    /// 각 visibleRow를 (보통 동일한) projectId 기준으로 쪼갠 뒤, 같은 프로젝트의
    /// row 조각들을 묶어 클러스터([컬럼들의 배열])로 만든다. 클러스터 순서는
    /// `knownProjectIds`를 따라가서 토올바와 일치한다. 한 row가 여러 프로젝트를
    /// 섞고 있을 경우(드물다)에도 각 projectId의 panes만 모아서 별도 클러스터로
    /// 할당한다.
    private func clusterRowsByProject(visibleRows: [[Pane]]) -> [[[Pane]]] {
        var byProject: [String: [[Pane]]] = [:]
        for row in visibleRows {
            var bucket: [String: [Pane]] = [:]
            var orderInRow: [String] = []
            for pane in row {
                if bucket[pane.projectId] == nil {
                    orderInRow.append(pane.projectId)
                }
                bucket[pane.projectId, default: []].append(pane)
            }
            for projectId in orderInRow {
                if let panes = bucket[projectId], !panes.isEmpty {
                    byProject[projectId, default: []].append(panes)
                }
            }
        }
        return knownProjectIds.compactMap { byProject[$0] }
    }

    private func installRootSplit(
        _ outer: NSSplitView?,
        visiblePanes: [Pane] = [],
        configure: (() -> Void)? = nil
    ) {
        let oldRoot = rootSplit
        window?.disableScreenUpdatesUntilFlush()

        // Freeze size propagation across every pane (not just visible — parked
        // panes also get touched by the AppKit layout pass and we don't want
        // their PTYs to see the parking-view geometry either). Each freeze is
        // matched by a thaw drained in `layout()` after the deferred equalize
        // settles, plus an async fallback in case that pass never fires.
        let needsFreeze = outer != nil
        if needsFreeze {
            for pane in panes { pane.terminal.freezeSizePropagation() }
            pendingTerminalThaws += 1
        }

        withoutRelayoutAnimation {
            if oldRoot.map({ !root($0, containsAny: visiblePanes) }) != true {
                parkHiddenPanes(except: visiblePanes)
            }
            if let outer {
                outer.translatesAutoresizingMaskIntoConstraints = false
                outer.frame = bounds.insetBy(dx: 4, dy: 4)
                if let oldRoot {
                    addSubview(outer, positioned: .above, relativeTo: oldRoot)
                } else {
                    addSubview(outer)
                }
                // Match the dashboard's outer insets (horizontal 8, vertical 4)
                // so the pane grid reads aligned with the bar above it.
                NSLayoutConstraint.activate([
                    outer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                    outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
                    outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                    outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
                ])
                rootSplit = outer
                configure?()
                layoutSubtreeIfNeeded()
                equalizeSplits()
                needsPostRelayoutEqualize = true
                needsLayout = true
            } else {
                rootSplit = nil
                needsPostRelayoutEqualize = false
            }
            oldRoot?.removeFromSuperview()
        }

        if needsFreeze {
            DispatchQueue.main.async { [weak self] in
                self?.flushPendingTerminalThaws()
            }
        }
    }

    private func root(_ root: NSView, containsAny panesToFind: [Pane]) -> Bool {
        panesToFind.contains { pane in
            var current = pane.superview
            while let view = current {
                if view === root { return true }
                current = view.superview
            }
            return false
        }
    }

    private func parkHiddenPanes(except visiblePanes: [Pane]) {
        let visibleIds = Set(visiblePanes.map { ObjectIdentifier($0) })
        hiddenPaneParkingView.layoutSubtreeIfNeeded()

        for pane in panes where !visibleIds.contains(ObjectIdentifier(pane)) {
            let id = ObjectIdentifier(pane)
            let frameInWorkspace: CGRect
            if let superview = pane.superview {
                frameInWorkspace = superview.convert(pane.frame, to: self)
            } else {
                frameInWorkspace = parkedPaneFrames[id] ?? bounds
            }

            parkedPaneFrames[id] = frameInWorkspace
            guard pane.superview !== hiddenPaneParkingView else { continue }
            hiddenPaneParkingView.addSubview(pane)
            pane.frame = hiddenPaneParkingView.convert(frameInWorkspace, from: self)
        }
    }

    private func withoutRelayoutAnimation(_ updates: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updates()
            CATransaction.commit()
        }
    }

    private func updateActivePaneAppearance() {
        for pane in panes {
            pane.applyActiveAppearance(pane === focusedPane)
        }
    }

    private func equalizeSplits() {
        guard let outer = rootSplit else { return }
        guard !isEqualizingSplits else { return }
        isEqualizingSplits = true
        defer { isEqualizingSplits = false }
        equalizeRecursively(outer)
    }

    private func equalizeRecursively(_ split: NSSplitView) {
        equalize(split)
        for sub in split.arrangedSubviews.compactMap({ $0 as? NSSplitView }) {
            equalizeRecursively(sub)
        }
    }

    private func equalize(_ split: NSSplitView) {
        split.adjustSubviews()
        split.layoutSubtreeIfNeeded()
        let n = split.arrangedSubviews.count
        guard n > 1 else { return }
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        guard total > 1 else { return }
        for i in 0..<(n - 1) {
            let pos = total * CGFloat(i + 1) / CGFloat(n)
            split.setPosition(pos, ofDividerAt: i)
        }
    }

    private func makeSplit(vertical: Bool) -> NSSplitView {
        let split = GapSplitView(frame: .zero)
        split.isVertical = vertical
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        return split
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    /// Widened, transparent NSSplitView so the gap between panes reads as a
    /// breathing-room inset (matching the dashboard's padding rhythm) rather
    /// than a hairline divider. Panes keep their rounded corners clean
    /// because each sits 4pt away from its neighbor.
    private final class GapSplitView: NSSplitView {
        override var dividerThickness: CGFloat { 8 }
        override func drawDivider(in rect: NSRect) { /* transparent */ }
    }

}

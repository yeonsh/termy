// Workspace.swift
//
// Replaces the NSTabView + PaneContainer model. A single grid of all panes
// in the window, with a project filter (`.all` | `.project(id)`) controlling
// which panes are visible. Same project → same color (via PaneStyling) now
// does double duty as both visual identity AND filter key.
//
// Layout: one split tree per project (`ProjectPaneLayout`, leaves = pane
// ids, each split child carries a weight). A project view — or ALL with a
// single project — draws that project's tree as nested NSSplitViews; ALL
// with several projects draws an equal grid instead. ⌘D / ⇧⌘D split only
// the focused pane (right / down); other new panes go where
// `PanePlacement.balanced` picks. Rebuilt on every visibility change. Moving
// an NSView between superviews preserves its state, so the pty and SwiftTerm
// renderer keep running across filter switches.
//
//   Workspace (NSView)
//     └── rootSplit (NSSplitView) — the project tree's root split
//           ├── pane
//           ├── split (other axis) — [pane, split, …]
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

/// Index math behind drag-to-reorder of the titlebar project chips. The
/// user's arrangement is stored as a plain id list and layered over the
/// discovery order (first-pane-opened) rather than replacing it, so a
/// project the user never dragged still shows up, and one whose last pane
/// closed drops out on its own.
enum ProjectOrder {
    /// Display order for `discovered`, honoring the user's arrangement.
    /// Ids in `preferred` come first in that order; anything the user has
    /// not placed follows in discovery order. Stale and duplicate entries
    /// in `preferred` are ignored.
    static func effective(discovered: [String], preferred: [String]) -> [String] {
        let live = Set(discovered)
        var placed: [String] = []
        var seen = Set<String>()
        for id in preferred where live.contains(id) && seen.insert(id).inserted {
            placed.append(id)
        }
        return placed + discovered.filter { !seen.contains($0) }
    }

    /// `ids` with the element at `from` lifted out and reinserted so it ends
    /// up at index `to`. `to` is clamped into range; an out-of-range `from`
    /// leaves the order untouched.
    static func moving(_ ids: [String], from: Int, to: Int) -> [String] {
        guard ids.indices.contains(from) else { return ids }
        var out = ids
        let moved = out.remove(at: from)
        let destination = min(max(to, 0), out.count)
        out.insert(moved, at: destination)
        return out
    }

    /// Slot a dragged chip should drop into, given where its center sits and
    /// how the remaining chips are laid out. `otherOrigins`/`otherWidths` are
    /// the other chips in strip order, positioned as if the dragged chip were
    /// already gone; the result is an insertion index into that list. It never
    /// goes below `firstMovable`, which is what keeps a pinned leading chip
    /// (the ALL filter) from being displaced.
    static func insertionIndex(
        draggedCenterX: CGFloat,
        otherOrigins: [CGFloat],
        otherWidths: [CGFloat],
        firstMovable: Int
    ) -> Int {
        var insertion = firstMovable
        for position in otherOrigins.indices {
            guard position < otherWidths.count else { break }
            // Passing a neighbour's midpoint is what claims its slot — the
            // same threshold AppKit's own reordering uses.
            if otherOrigins[position] + otherWidths[position] / 2 < draggedCenterX {
                insertion = position + 1
            }
        }
        return min(max(insertion, firstMovable), otherOrigins.count)
    }
}

/// Where `addPane` puts a new pane. `.row` (⌘D) splits the focused pane and
/// puts the new one on its right, `.column` (⌘⇧D) below it; `.balanced` (and
/// either split when the focused pane is in another project) lets
/// `PanePlacement.balanced` pick a spot in the new pane's project tree.
enum SplitAxis {
    case column
    case row
    case balanced
}

/// pane을 Workspace에서 뺄 때 그 프로세스에 하는 일. hc terminal은 사용자가 pane이나 창을 닫았을 때만 끝낸다:
/// ⌘Q·업데이트 재시작처럼 앱이 끝나며 정리될 때는 남겨 두고 다음 실행 때 다시 붙는다.
enum TeardownAction: Equatable {
    case terminateLocal, killHc, none
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

/// On-screen order of the pane grid, shared by the layout pass and ⌘[ / ⌘]
/// so focus cycling walks panes the way the user sees them rather than the
/// order they were opened in. `columns` are the workspace's `rows`: each one
/// renders as a vertical stack, and the stacks sit left to right.
enum PaneGridOrder {
    /// Splits each column by project and gathers a project's pieces into one
    /// cluster (an array of columns). Clusters follow `projectOrder` — the
    /// chip order the ALL grid lays panes out in. A column that mixes
    /// projects (rare; a pane `cd`d away) lands in each project's cluster.
    static func clusters<Item>(
        columns: [[Item]],
        projectOrder: [String],
        projectId: (Item) -> String
    ) -> [[[Item]]] {
        var byProject: [String: [[Item]]] = [:]
        for column in columns {
            var bucket: [String: [Item]] = [:]
            var orderInColumn: [String] = []
            for item in column {
                let id = projectId(item)
                if bucket[id] == nil {
                    orderInColumn.append(id)
                }
                bucket[id, default: []].append(item)
            }
            for id in orderInColumn {
                if let items = bucket[id] {
                    byProject[id, default: []].append(items)
                }
            }
        }
        return projectOrder.compactMap { byProject[$0] }
    }

    /// Reading order: projects in chip order; inside a project, columns left
    /// to right and each column top to bottom. With one project on screen
    /// that is simply the columns in order. The ALL grid fills its rows in
    /// this same order, so it is also that grid's left-to-right,
    /// top-to-bottom order.
    static func readingOrder<Item>(
        columns: [[Item]],
        projectOrder: [String],
        projectId: (Item) -> String
    ) -> [Item] {
        clusters(columns: columns, projectOrder: projectOrder, projectId: projectId)
            .flatMap { $0.flatMap { $0 } }
    }

    /// Panes per row of the ALL grid, top to bottom. ⌈√N⌉ columns, as many
    /// rows as that needs, and the panes spread so rows differ by at most
    /// one — every pane gets (nearly) the same area regardless of which
    /// project it belongs to. Extra panes go to the top rows.
    static func equalRowSizes(paneCount: Int) -> [Int] {
        guard paneCount > 0 else { return [] }
        let columns = Int(ceil(Double(paneCount).squareRoot()))
        let rowCount = (paneCount + columns - 1) / columns
        let base = paneCount / rowCount
        let extra = paneCount % rowCount
        return (0..<rowCount).map { $0 < extra ? base + 1 : base }
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
    /// 배치의 출처: project마다 분할 tree 하나(잎 = pane id). 모든 pane은 자기 `projectId`의 layout에 보이는 잎으로
    /// 정확히 한 번 있다. 다른 project로 `cd`한 pane의 잎은 옛 project layout에 "떠난" 잎으로만 남는다.
    private var layouts: [String: ProjectPaneLayout] = [:] {
        didSet { layoutGeneration &+= 1 }
    }
    /// 배치가 바뀔 때마다 늘어난다: relayout, `layouts` 변경, Workspace 크기 변경. 끌기는 시작할 때 값을 잡아 두고,
    /// 놓을 때 달라졌으면(끄는 도중 pane이 닫힘·새 pane·필터 전환·창 크기 변경) 그때 계산한 계획을 버린다.
    private(set) var layoutGeneration = 0
    private var paneCreationOrder: [Pane] = []
    /// Project ids the user arranged by dragging the titlebar chips. Layered
    /// over the discovery order by `knownProjectIds`; see `ProjectOrder`.
    private var preferredProjectOrder: [String] = []
    private var focusHistory = PaneFocusHistory()
    private var filterHistory = FilterNavigationHistory()
    /// Set during the close-fallback path so the dying filter doesn't get
    /// pushed back onto `filterHistory` by the `filter` didSet.
    private var suppressFilterHistoryPush = false
    var panes: [Pane] { paneCreationOrder }
    private(set) var focusedPane: Pane? {
        didSet {
            guard oldValue !== focusedPane else { return }
            NotificationCenter.default.post(name: Workspace.focusedPaneDidChangeNotification, object: self)
        }
    }
    var filter: WorkspaceFilter = .all {
        didSet {
            guard oldValue != filter else { return }
            if !suppressFilterHistoryPush {
                filterHistory.markVisited(oldValue)
            }
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
    /// pane 집합은 그대로이고 배치만 바뀌었을 때(경계선을 끌어 크기를 바꿈 등). 저장만 하면 된다.
    var onLayoutChanged: (() -> Void)?

    private(set) var rootSplit: NSSplitView?
    private var maximizedPane: Pane?
    private let hiddenPaneParkingView = NSView(frame: .zero)
    private var parkedPaneFrames: [ObjectIdentifier: CGRect] = [:]
    /// 그린 split마다 자식 비율(그리기 때 등록). `applySplitWeights`가 divider 위치로 옮긴다. 없으면 균등.
    private var splitWeights: [ObjectIdentifier: [Double]] = [:]
    /// project tree를 그린 split마다 그 split의 tree path(root부터 자식 index). 경계선을 끌면 이 path의 비율을 바꾼다.
    /// 여러 project ALL 그리드와 최대화(잎 하나)는 tree의 split이 아니라 등록하지 않는다.
    private var splitPaths: [ObjectIdentifier: [Int]] = [:]
    private var needsPostRelayoutSplitWeights = false
    private var isApplyingSplitWeights = false
    /// Each `installRootSplit` that wraps panes in a freeze adds one token.
    /// Tokens are drained either when the deferred split-weights pass runs in
    /// `layout()` or by an async fallback — whichever fires first.
    private var pendingTerminalThaws = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupHiddenPaneParking()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { layoutGeneration &+= 1 }
    }

    override func layout() {
        super.layout()
        guard needsPostRelayoutSplitWeights, !isApplyingSplitWeights else { return }
        guard let rootSplit, rootSplit.bounds.width > 1, rootSplit.bounds.height > 1 else {
            needsPostRelayoutSplitWeights = true
            return
        }
        needsPostRelayoutSplitWeights = false
        withoutRelayoutAnimation {
            applySplitWeights()
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

    /// Unique list of project ids currently represented by an open pane, in
    /// the order the user dragged the titlebar chips into. Projects the user
    /// never placed follow in first-pane-opened order, so opening a new one
    /// doesn't reshuffle the chips. This single order drives the filter bar,
    /// the ⌘1–9 numbering, and the pane order of the ALL grid.
    var knownProjectIds: [String] {
        ProjectOrder.effective(
            discovered: discoveredProjectIds,
            preferred: preferredProjectOrder
        )
    }

    /// Project ids in first-pane-opened order, before the user's arrangement
    /// is layered on top.
    private var discoveredProjectIds: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for pane in panes where seen.insert(pane.projectId).inserted {
            out.append(pane.projectId)
        }
        return out
    }

    /// Move the project chip at `from` to `to` within `knownProjectIds`.
    /// Both indices address the project list — the leading ALL chip is not a
    /// project and never participates.
    func moveProject(from: Int, to: Int) {
        let current = knownProjectIds
        let reordered = ProjectOrder.moving(current, from: from, to: to)
        guard reordered != current else { return }
        preferredProjectOrder = reordered
        // Pane order in the ALL grid reads straight off knownProjectIds.
        relayout()
        onPanesChanged?()
    }

    /// Restore a saved arrangement. Ids no longer backed by a pane are
    /// harmless — `knownProjectIds` filters them out.
    func applyProjectOrder(_ order: [String]) {
        guard preferredProjectOrder != order else { return }
        preferredProjectOrder = order
        relayout()
        onPanesChanged?()
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

    /// Visible panes as laid out on screen — what ⌘[ / ⌘] walk. Ignores
    /// maximize: cycling to another pane exits it (see `focus(pane:)`).
    private var visiblePanesInLayoutOrder: [Pane] {
        panesInReadingOrder(where: isVisible)
    }

    /// 읽는 순서: 칩 순서대로 project, project 안에서는 보이는 tree의 잎 순서. ⌘[ / ⌘]와 여러 project ALL 그리드가 쓴다.
    private func panesInReadingOrder(where include: (Pane) -> Bool) -> [Pane] {
        let byId = paneLookup
        let projectIds = knownProjectIds
        return PaneGridOrder.readingOrder(
            columns: projectIds.map { (paneTree(forProject: $0, byId: byId)?.leaves ?? []).filter(include) },
            projectOrder: projectIds,
            projectId: \.projectId
        )
    }

    // MARK: - Layout trees

    /// tree를 그리는 project: 프로젝트 필터, 또는 project가 하나뿐인 ALL. 여러 project ALL(균등 그리드)이면 nil.
    var displayedProjectId: String? {
        switch filter {
        case .project(let id):
            return id
        case .all:
            let ids = knownProjectIds
            return ids.count == 1 ? ids[0] : nil
        }
    }

    /// 그 project의 보이는 tree(떠난 잎 제외). 잎은 pane id.
    func layoutTree(forProject projectId: String) -> PaneLayoutNode<String>? {
        layouts[projectId]?.visibleTree
    }

    /// project마다 보이는 tree. `knownProjectIds` 순서.
    func layoutSnapshot() -> [(projectId: String, tree: PaneLayoutNode<Pane>)] {
        let byId = paneLookup
        return knownProjectIds.compactMap { id in
            paneTree(forProject: id, byId: byId).map { (projectId: id, tree: $0) }
        }
    }

    /// 저장된 배치를 세운다. 잎들의 실제 `projectId`마다 그 project의 잎만 남긴 tree를 만들고, 그 project에 지금 보이는
    /// pane 집합이 그 잎 집합과 같을 때만 그 project의 layout으로 바꾼다. 다르면(같은 project에 이미 다른 pane이 있음 등)
    /// 자동 배치를 그대로 둔다 — 어느 쪽이든 모든 pane이 자기 project layout에 한 번씩 있다.
    func applyRestoredLayout(_ tree: PaneLayoutNode<Pane>) {
        var projectIds: [String] = []
        for pane in tree.leaves where !projectIds.contains(pane.projectId) {
            projectIds.append(pane.projectId)
        }
        for projectId in projectIds {
            guard let restored = tree.removing(where: { $0.projectId != projectId })?.map({ $0.paneId }),
                  var layout = layouts[projectId] else { continue }
            let restoredIds = restored.leaves
            let placedIds = Set(layout.visibleTree?.leaves ?? [])
            guard Set(restoredIds) == placedIds, restoredIds.count == placedIds.count else { continue }
            layout.replaceVisibleTree(restored)
            layouts[projectId] = layout
        }
        relayout()
    }

    private var paneLookup: [String: Pane] {
        Dictionary(panes.map { ($0.paneId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 그 project의 보이는 tree를 pane으로 바꾼 것. 열린 pane이 아닌 잎은 뺀다.
    private func paneTree(forProject projectId: String, byId: [String: Pane]) -> PaneLayoutNode<Pane>? {
        guard let tree = layouts[projectId]?.visibleTree?.removing(where: { byId[$0] == nil }) else { return nil }
        return tree.map { byId[$0]! }
    }

    // MARK: - Add / close

    /// 사용자가 만드는 새 pane(⌘N·split·새 창의 첫 pane)의 backend와 자리. 포커스된 pane이 원격이면 같은 머신·
    /// cwd·project의 원격 pane이다(원격 project 안에서 만든 pane이 이 Mac의 셸이 되면 안 된다). 아니면 "Run local
    /// panes in herdr-core" 설정과 hc를 쓸 수 있는지(`PaneLaunch.forNewLocalPane`)가 backend를 정하고, cwd와 project는
    /// addPane이 지금 규칙(포커스된 pane)으로 정한다.
    nonisolated static func launchForNewPane(
        focused: (launch: PaneLaunch, cwd: String, projectId: String, projectKey: String)?,
        defaults: UserDefaults,
        hcAllowsNewPanes: Bool
    ) -> (launch: PaneLaunch, cwd: String?, projectId: String?, projectKey: String?) {
        if let focused, focused.launch.machine != nil {
            return (focused.launch, focused.cwd, focused.projectId, focused.projectKey)
        }
        return (PaneLaunch.forNewLocalPane(defaults: defaults, hcAllowsNewPanes: hcAllowsNewPanes), nil, nil, nil)
    }

    /// 사용자가 만드는 새 pane. `launchForNewPane`의 규칙을 따른다.
    @discardableResult
    func addNewPane(splitAxis: SplitAxis = .balanced, defaults: UserDefaults) -> Pane {
        let focused = focusedPane.map {
            (launch: $0.launch, cwd: $0.currentCwd, projectId: $0.projectId, projectKey: $0.projectKey)
        }
        let next = Self.launchForNewPane(focused: focused, defaults: defaults,
                                         hcAllowsNewPanes: HcSessionManager.allowsNewLocalPanes(defaults: defaults))
        return addPane(cwd: next.cwd, splitAxis: splitAxis, launch: next.launch,
                       projectId: next.projectId, projectKey: next.projectKey)
    }

    /// - Parameters:
    ///   - paneId: 복원할 pane의 id(hc terminal을 label로 다시 찾는다). nil이면 새 id.
    ///   - launch: local PTY 셸 또는 herdr-core terminal.
    ///   - projectId, projectKey: 원격 project처럼 cwd로 정할 수 없을 때 호출하는 쪽이 준다. 원격 pane에 주지
    ///     않으면 그 머신의 cwd로 정한다(`<basename>@<machine>`, `<machine>:<cwd>`).
    @discardableResult
    func addPane(
        cwd: String? = nil,
        splitAxis: SplitAxis = .balanced,
        startupInput: String? = nil,
        paneId: String? = nil,
        launch: PaneLaunch = .local,
        projectId: String? = nil,
        projectKey: String? = nil
    ) -> Pane {
        // 원격 pane의 cwd는 그 머신의 경로다. 원격 pane은 포커스된 pane의 cwd를 빌리지 않고, local pane은 포커스된
        // 원격 pane의 cwd·project(그 머신의 것)를 빌리지 않는다.
        let remoteMachine = launch.machine
        let remoteFocus = focusedPane?.isRemote == true
        let localFocus = remoteFocus ? nil : focusedPane
        let paneCwd = remoteMachine == nil ? (cwd ?? localFocus?.currentCwd) : cwd
        // Project id = focused pane's project if available, else derive
        // from cwd or the current filter.
        let projectId: String = projectId ?? {
            if let remoteMachine {
                return RemoteProject.projectId(machine: remoteMachine, folder: cwd ?? "~")
            }
            if let cwd, !cwd.isEmpty {
                return ProjectIdentity.derive(for: cwd)
            }
            if let focused = localFocus {
                return focused.projectId
            }
            if !remoteFocus, case .project(let id) = filter { return id }
            return ProjectIdentity.derive(for: FileManager.default.homeDirectoryForCurrentUser.path)
        }()

        let pane = Pane(
            projectId: projectId,
            cwd: paneCwd,
            startupInput: startupInput,
            paneId: paneId ?? UUID().uuidString,
            launch: launch,
            projectKey: projectKey
        )
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.onPaneClicked = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.focus(pane: pane)
        }
        pane.onHeaderMouseDown = { [weak self, weak pane] event in
            guard let self, let pane else { return }
            self.handleHeaderMouseDown(on: pane, event: event)
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

    /// 새 pane을 자기 project의 tree에 넣는다. ⌘D(`.row`)·⌘⇧D(`.column`)는 같은 project의 포커스된 pane만 오른쪽·
    /// 아래로 나눈다. 그 밖(`.balanced`, 포커스 없음, 포커스가 다른 project)은 `PanePlacement.balanced`가 자리를 고른다.
    /// 어느 쪽이든 보이는 tree에 적용하므로 그 project의 떠난 잎은 사라진다.
    private func place(_ pane: Pane, splitAxis: SplitAxis) {
        let projectId = pane.projectId
        var layout = layouts[projectId] ?? ProjectPaneLayout()
        let visible = layout.visibleTree
        let edge: PaneEdge?
        switch splitAxis {
        case .row: edge = .right
        case .column: edge = .bottom
        case .balanced: edge = nil
        }
        if let edge, let visible, let focused = focusedPane,
           focused.projectId == projectId, visible.contains(focused.paneId) {
            layout.replaceVisibleTree(visible.splitting(focused.paneId, edge: edge, with: pane.paneId))
        } else {
            layout.replaceVisibleTree(PanePlacement.balanced(pane.paneId, into: visible, workspaceSize: bounds.size))
        }
        layouts[projectId] = layout
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
        guard paneCreationOrder.contains(where: { $0 === pane }) else { return }
        _ = closePaneInternal(pane, wasFocused: focusedPane === pane)
    }

    @discardableResult
    private func closePaneInternal(_ pane: Pane, wasFocused: Bool) -> Bool {
        teardown(pane: pane)

        if panes.isEmpty {
            onPanesChanged?()
            return true
        }

        // If the current filter no longer has any panes, restore the most
        // recently visited still-valid filter (the project the user was on
        // before this one). This runs regardless of `wasFocused` because a
        // background pane that exits last in its project (e.g., a Codex pane
        // calling `exit` while the user types in another pane) leaves the
        // filter equally stranded as a foregrounded close. Falls back to
        // filterOptions.first — `.all` when multiple projects remain, or the
        // sole remaining project. The `?? .all` tail is defensive; it's
        // unreachable while panes remain.
        if visiblePanes.isEmpty {
            let target = filterHistory.filterToRestore(in: filterOptions) ?? .all
            // suppressFilterHistoryPush prevents `filter`'s didSet from
            // pushing the dying filter back onto history. Invariant: callers
            // reachable from `onFilterChanged?()` must not assign to `filter`,
            // otherwise that nested set is also silently suppressed.
            suppressFilterHistoryPush = true
            filter = target
            suppressFilterHistoryPush = false
        } else {
            relayout()
        }

        if wasFocused {
            let fallbackPaneId = focusHistory.mostRecent(in: visiblePanes.map(\.paneId))
            focusedPane = visiblePanes.first { $0.paneId == fallbackPaneId } ?? visiblePanes.first
            if let focusedPane {
                focusHistory.markFocused(focusedPane.paneId)
            }
            updateActivePaneAppearance()
            focusedPane?.focusTerminal()
        }
        onPanesChanged?()
        return false
    }

    nonisolated static func teardownAction(kind: PaneBackendKind, isTerminating: Bool) -> TeardownAction {
        switch kind {
        case .local: return .terminateLocal
        case .hc: return isTerminating ? .none : .killHc
        }
    }

    private func teardown(pane: Pane) {
        // Clear the shell-exit callback first — teardown calls terminate()
        // which fires processTerminated → onShellExited; we'd otherwise
        // recurse right back into closePane.
        pane.onShellExited = nil
        switch Self.teardownAction(kind: pane.launch.backendKind, isTerminating: AppLifecycle.isTerminating) {
        case .terminateLocal:
            pane.terminal.process.terminate()
        case .killHc:
            pane.killHcTerminal()
        case .none:
            // terminal은 살려 둔다. backend는 viewer로서만 떠난다(연결·writer task를 놓는다).
            pane.detachHcTerminal()
        }
        pane.removeFromSuperview()
        if maximizedPane === pane { maximizedPane = nil }
        parkedPaneFrames.removeValue(forKey: ObjectIdentifier(pane))
        focusHistory.remove(pane.paneId)
        let removedProjectId = pane.projectId
        paneCreationOrder.removeAll { $0 === pane }
        // 보이는 잎이 있는 layout(자기 project)에서는 빼고 형제가 그 몫을 나눈다. 다른 layout에 남은 떠난 잎도 지운다.
        let paneId = pane.paneId
        for projectId in Array(layouts.keys) {
            guard var layout = layouts[projectId] else { continue }
            if layout.visibleTree?.contains(paneId) == true {
                layout.removePane(paneId)
            } else {
                layout.forgetAway(paneId)
            }
            layouts[projectId] = layout.isEmpty ? nil : layout
        }
        if !paneCreationOrder.contains(where: { $0.projectId == removedProjectId }) {
            filterHistory.remove(.project(removedProjectId))
            // Drop the dead id so a project reopened later lands at the end
            // rather than silently reclaiming its old slot.
            preferredProjectOrder.removeAll { $0 == removedProjectId }
        }
    }

    /// 이 Workspace의 모든 hc terminal을 끝낸다(사용자가 창을 닫았다). pane은 창과 함께 사라진다.
    func killHcPanes() {
        for pane in panes { pane.killHcTerminal() }
    }

    /// hc terminal은 남기고 viewer만 떠난다(앱 종료 중에 창이 정리될 때).
    func detachHcPanes() {
        for pane in panes { pane.detachHcTerminal() }
    }

    /// 창이 닫힌다. 사용자가 닫았으면(마지막 창 닫기 포함) hc terminal을 끝내고, 앱 종료 중이면 남긴다.
    func windowWillClose() {
        if AppLifecycle.isTerminating {
            detachHcPanes()
        } else {
            killHcPanes()
        }
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
        // 닫힌 pane의 늦은 cwd 알림이 잎을 다시 넣거나 필터를 옮기지 않게.
        guard paneCreationOrder.contains(where: { $0 === pane }) else { return }
        let oldProjectId = moveLayoutLeaf(of: pane)
        if case .project(let id) = filter {
            let filterWouldBeEmpty = !panes.contains(where: { $0.projectId == id })
            let focusedPaneDriftedOut = (pane === focusedPane) && pane.projectId != id
            if filterWouldBeEmpty || focusedPaneDriftedOut {
                filter = .project(pane.projectId)
                return
            }
        }
        // Filter still valid. Redraw when the drifted pane left or joined the
        // project on screen (ALL: the grid's order or the single-project tree
        // changed); otherwise just rebuild the toolbar segments.
        let shownLayoutChanged: Bool
        switch filter {
        case .all: shownLayoutChanged = true
        case .project(let id): shownLayoutChanged = id == oldProjectId || id == pane.projectId
        }
        if shownLayoutChanged {
            relayout()
        }
        onPanesChanged?()
    }

    /// `cd`로 project가 바뀐 pane의 잎을 옮긴다: 옛 project layout에는 "떠난" 잎으로 남기고, 새 project에 그 pane의
    /// 떠난 잎이 있으면 그 자리·크기로 되살리고, 없으면 `PanePlacement.balanced`로 넣는다. 옛 project id를 돌려준다.
    private func moveLayoutLeaf(of pane: Pane) -> String? {
        let paneId = pane.paneId
        let newProjectId = pane.projectId
        let oldProjectId = layouts.first { entry in
            entry.key != newProjectId && entry.value.visibleTree?.contains(paneId) == true
        }?.key
        if let oldProjectId {
            layouts[oldProjectId]?.markAway(paneId)
        }
        var layout = layouts[newProjectId] ?? ProjectPaneLayout()
        if !layout.returnFromAway(paneId), layout.visibleTree?.contains(paneId) != true {
            layout.replaceVisibleTree(
                PanePlacement.balanced(paneId, into: layout.visibleTree, workspaceSize: bounds.size)
            )
        }
        layouts[newProjectId] = layout
        return oldProjectId
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
        let vis = visiblePanesInLayoutOrder
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

    // MARK: - Drag to rearrange

    private static let paneDragThreshold: CGFloat = 4
    private static let escapeKeyCode: UInt16 = 53

    /// 지금 그리는 project tree(보이는 잎만). 여러 project ALL 그리드면 nil.
    private var displayedTree: PaneLayoutNode<String>? {
        displayedProjectId.flatMap { layoutTree(forProject: $0) }
    }

    /// header를 끌어 옮길 수 있는가: 최대화 중이 아니고, project tree를 그리고 있고(여러 project ALL 그리드가 아님),
    /// 그 tree에 이 pane과 다른 pane이 함께 있다.
    func canBeginPaneDrag(_ pane: Pane) -> Bool {
        guard maximizedPane == nil, let leaves = displayedTree?.leaves else { return false }
        return leaves.count >= 2 && leaves.contains(pane.paneId)
    }

    /// `point`(Workspace 기준 y-아래)에 `pane`을 놓으면 생길 배치. nil = 작업 영역 밖이거나 제자리.
    func dragPlan(moving pane: Pane, toFlippedPoint point: CGPoint) -> PaneDropPlan? {
        guard let tree = displayedTree, tree.contains(pane.paneId) else { return nil }
        return PaneDropPlanner.plan(moving: pane.paneId, to: point, bounds: bounds.size, layout: tree)
    }

    /// 끌기를 놓았다. `plan`을 계산한 뒤 배치가 바뀌었으면(`generation`이 지금과 다름) 아무것도 하지 않고 false.
    /// 아니면 보이는 tree를 결과로 바꿔 한 번 relayout하고(PTY 크기도 이때 한 번만 바뀐다), 끌린 pane에 포커스를
    /// 주고 저장을 요청한다.
    @discardableResult
    func applyDrop(_ plan: PaneDropPlan, generation: Int) -> Bool {
        guard generation == layoutGeneration, maximizedPane == nil,
              let projectId = displayedProjectId, var layout = layouts[projectId],
              let visible = layout.visibleTree,
              visible.leaves.sorted() == plan.result.leaves.sorted() else { return false }
        // 끌린 pane = 결과 배치에서 미리보기 frame을 차지하는 잎. 같은 bounds에 같은 식으로 계산하므로 정확히 같다.
        let draggedId = plan.result
            .frames(in: PaneDropPlanner.contentRect(for: bounds.size), gap: PaneDropPlanner.gap)
            .leaves.first { $0.frame == plan.previewFrame }?.leaf
        layout.replaceVisibleTree(plan.result)
        layouts[projectId] = layout
        relayout()
        if let draggedId, let dragged = paneLookup[draggedId] {
            focus(pane: dragged)
        }
        onLayoutChanged?()
        return true
    }

    /// header를 눌렀다. 먼저 포커스를 주고(클릭), 끌 수 있는 화면이면 마우스를 놓을 때까지 따라간다
    /// (`ProjectFilterBar.handleMouseDown`과 같은 모양). 4pt 넘게 움직이면 끌기가 시작된다: 원래 pane을 흐리게 하고
    /// 맨 위 overlay에 놓일 자리(그림자 상자)와 header 글자 칩을 그린다. 끄는 동안에는 배치를 건드리지 않고
    /// (relayout·SIGWINCH 없음), 놓을 때 마지막으로 보여 준 계획을 한 번 적용한다. Esc, 작업 영역 밖에서 놓기,
    /// 끄는 도중 배치가 바뀜(세대가 다름)은 취소다. 어느 쪽으로 끝나든 overlay·흐림·커서를 한 번씩 되돌린다.
    private func handleHeaderMouseDown(on pane: Pane, event: NSEvent) {
        focus(pane: pane)
        guard canBeginPaneDrag(pane), let window else { return }
        let generation = layoutGeneration
        let start = event.locationInWindow
        var overlay: PaneDragOverlayView?
        var shownPlan: PaneDropPlan?
        var drop: PaneDropPlan?

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
            timeout: .infinity,
            mode: .eventTracking
        ) { tracked, stop in
            guard let tracked else { return }
            // 셸 종료로 pane이 닫힘, 새 pane, 필터 전환, 창 크기 변경: 계획이 가리키던 배치가 이제 없다.
            guard generation == self.layoutGeneration else {
                stop.pointee = true
                return
            }
            switch tracked.type {
            case .keyDown:
                if tracked.keyCode == Self.escapeKeyCode { stop.pointee = true }
            case .leftMouseUp:
                stop.pointee = true
                let released = self.convert(tracked.locationInWindow, from: nil)
                if overlay != nil, self.bounds.contains(released) { drop = shownPlan }
            default:
                if overlay == nil {
                    let travel = hypot(tracked.locationInWindow.x - start.x, tracked.locationInWindow.y - start.y)
                    guard travel > Self.paneDragThreshold else { return }
                    overlay = self.beginPaneDrag(pane)
                }
                let point = self.flippedPoint(fromWindow: tracked.locationInWindow)
                shownPlan = self.dragPlan(moving: pane, toFlippedPoint: point)
                overlay?.showPreview(shownPlan?.previewFrame)
                overlay?.showChip(title: pane.headerTitle, at: point)
            }
        }

        if let overlay {
            endPaneDrag(pane, overlay: overlay)
        }
        if let drop {
            applyDrop(drop, generation: generation)
        }
    }

    private func beginPaneDrag(_ pane: Pane) -> PaneDragOverlayView {
        pane.alphaValue = 0.35
        let overlay = PaneDragOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .above, relativeTo: nil)
        NSCursor.closedHand.push()
        return overlay
    }

    private func endPaneDrag(_ pane: Pane, overlay: PaneDragOverlayView) {
        overlay.removeFromSuperview()
        pane.alphaValue = 1
        // 끄는 도중 포커스가 다른 pane으로 갔으면(새 pane 등) 흐리지 않은 비활성 모양으로 되돌린다.
        pane.applyActiveAppearance(pane === focusedPane)
        NSCursor.pop()
    }

    /// 창 좌표 → Workspace 기준 y-아래 좌표(`PaneDropPlanner`·overlay가 쓰는 좌표).
    private func flippedPoint(fromWindow point: NSPoint) -> CGPoint {
        let local = convert(point, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    // MARK: - Layout

    /// What one relayout puts on screen.
    private enum LayoutDrawing {
        /// A project tree (or the maximized pane as a lone leaf).
        case tree(PaneLayoutNode<Pane>)
        /// ALL with several projects: an equal grid filled in reading order.
        case grid([Pane])

        var panes: [Pane] {
            switch self {
            case .tree(let tree): return tree.leaves
            case .grid(let panes): return panes
            }
        }
    }

    private func currentDrawing() -> LayoutDrawing? {
        if let m = maximizedPane, isVisible(m) { return .tree(.leaf(m)) }
        if let projectId = displayedProjectId {
            return paneTree(forProject: projectId, byId: paneLookup).map { .tree($0) }
        }
        let ordered = panesInReadingOrder(where: isVisible)
        return ordered.isEmpty ? nil : .grid(ordered)
    }

    /// Rebuild the split views from the layout trees. Moves existing Pane
    /// NSViews between superviews — their pty/terminal state persists.
    private func relayout() {
        layoutGeneration &+= 1
        // Weights belong to the splits about to be replaced; drop them so a
        // recycled ObjectIdentifier can't pick up a stale entry.
        splitWeights = [:]
        splitPaths = [:]
        guard let drawing = currentDrawing() else {
            installRootSplit(nil)
            return
        }

        // Re-focus the pane that was last active inside this filter. If this
        // filter has never had focus, fall back to the first visible pane.
        let visiblePaneList = drawing.panes
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
            self.populate(outer: outer, drawing: drawing)
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

    private func populate(outer: NSSplitView, drawing: LayoutDrawing) {
        let outerFrame = bounds.insetBy(dx: PaneDropPlanner.inset, dy: PaneDropPlanner.inset)
        outer.frame = outerFrame

        switch drawing {
        case .tree(let tree):
            populateTree(tree, in: outer, size: outerFrame.size)
        case .grid(let ordered):
            populateEqualGrid(outer: outer, frame: outerFrame, ordered: ordered)
        }
    }

    /// project tree를 중첩 split으로 그린다(잎이 root면 자식 하나인 split). 비율은 `splitWeights`에 등록해
    /// `applySplitWeights`가 divider로 옮기고, 초기 frame은 `frames(in:gap:)`로 미리 넣어 첫 배치가 흔들리지 않게 한다.
    private func populateTree(_ tree: PaneLayoutNode<Pane>, in outer: NSSplitView, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        switch tree {
        case .leaf(let pane):
            outer.isVertical = true
            splitWeights[ObjectIdentifier(outer)] = [1]
            pane.frame = rect
            arrange(pane, in: outer)
        case .split(let axis, let branches):
            let frames = tree.frames(in: rect, gap: PaneDropPlanner.gap)
            let childFrames = Dictionary(
                frames.splits.map { ($0.path, $0.childFrames) },
                uniquingKeysWith: { first, _ in first }
            )
            populateSplit(outer, axis: axis, branches: branches, rect: rect, path: [], childFrames: childFrames)
        }
    }

    private func populateSplit(
        _ split: NSSplitView,
        axis: PaneLayoutAxis,
        branches: [PaneLayoutBranch<Pane>],
        rect: CGRect,
        path: [Int],
        childFrames: [[Int]: [CGRect]]
    ) {
        split.isVertical = axis == .leftToRight
        splitWeights[ObjectIdentifier(split)] = branches.map(\.weight)
        splitPaths[ObjectIdentifier(split)] = path
        let frames = childFrames[path] ?? []
        for (index, branch) in branches.enumerated() {
            let childRect = frames.indices.contains(index) ? frames[index] : rect
            let local = frameInSplit(childRect, splitRect: rect, split: split)
            switch branch.node {
            case .leaf(let pane):
                pane.frame = local
                arrange(pane, in: split)
            case .split(let childAxis, let grandchildren):
                let child = makeSplit(vertical: childAxis == .leftToRight)
                child.frame = local
                split.addArrangedSubview(child)
                populateSplit(child, axis: childAxis, branches: grandchildren,
                              rect: childRect, path: path + [index], childFrames: childFrames)
            }
        }
    }

    /// 순수 배치 좌표(y-아래, root 기준)의 `rect`를 `split` 안의 frame으로. flipped가 아닌 split이면 y를 뒤집는다.
    private func frameInSplit(_ rect: CGRect, splitRect: CGRect, split: NSSplitView) -> CGRect {
        let y = split.isFlipped ? rect.minY - splitRect.minY : splitRect.maxY - rect.maxY
        return CGRect(x: rect.minX - splitRect.minX, y: y, width: rect.width, height: rect.height)
    }

    /// ALL 뷰에서 프로젝트가 둘 이상일 때, 프로젝트별로 칸을 나누지 않고
    /// 모든 pane을 하나의 균등 그리드(`PaneGridOrder.equalRowSizes`)에 놓아
    /// pane마다 같은 면적을 준다. 채우는 순서(`ordered`)는 읽는 순서
    /// (칩 순서 → 프로젝트 안 tree 잎 순서)라서 같은 프로젝트 pane은 붙어 있고
    /// ⌘[ / ⌘] 순서와도 맞는다. 프로젝트 tree는 건드리지 않으므로 프로젝트
    /// 뷰에서는 사용자가 만든 배치가 그대로 보인다. split은 2단계이고 비율을
    /// 등록하지 않아 균등이다:
    ///   outer(grid-rows) → grid-row(panes)
    private func populateEqualGrid(outer: NSSplitView, frame: CGRect, ordered: [Pane]) {
        let rowSizes = PaneGridOrder.equalRowSizes(paneCount: ordered.count)
        guard !rowSizes.isEmpty else { return }

        outer.isVertical = false
        let rowHeight = frame.height / CGFloat(rowSizes.count)
        var start = 0

        for (gridRow, size) in rowSizes.enumerated() {
            let rowSplit = makeSplit(vertical: true)
            rowSplit.frame = CGRect(
                x: 0,
                y: frame.height - CGFloat(gridRow + 1) * rowHeight,
                width: frame.width,
                height: rowHeight
            )
            outer.addArrangedSubview(rowSplit)

            let paneWidth = frame.width / CGFloat(size)
            for (paneIdx, pane) in ordered[start..<start + size].enumerated() {
                pane.frame = CGRect(
                    x: CGFloat(paneIdx) * paneWidth,
                    y: 0,
                    width: paneWidth,
                    height: rowHeight
                )
                arrange(pane, in: rowSplit)
            }
            start += size
        }
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
        // matched by a thaw drained in `layout()` after the deferred split
        // weights settle, plus an async fallback in case that pass never fires.
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
                applySplitWeights()
                needsPostRelayoutSplitWeights = true
                needsLayout = true
            } else {
                rootSplit = nil
                needsPostRelayoutSplitWeights = false
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
            // Panes are constraint-sized inside the splits, and the parking
            // view adds no constraints, so Auto Layout would shrink a parked
            // pane to its header's fitting size and push a ~5×1 PTY to the
            // agent still running in it (claude-hud then cuts every
            // status-line row to that width). Let the frame set here hold
            // while the pane is parked; `arrange(_:in:)` undoes it.
            pane.translatesAutoresizingMaskIntoConstraints = true
            pane.autoresizingMask = []
            hiddenPaneParkingView.addSubview(pane)
            pane.frame = hiddenPaneParkingView.convert(frameInWorkspace, from: self)
        }
    }

    /// Put `pane` into a split, constraint-sized like every split member —
    /// undoing the frame-held layout `parkHiddenPanes` gives a parked pane.
    private func arrange(_ pane: Pane, in split: NSSplitView) {
        pane.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(pane)
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

    /// Put every split's dividers where its registered weights say (equal
    /// when none are registered, e.g. the ALL grid).
    private func applySplitWeights() {
        guard let outer = rootSplit else { return }
        guard !isApplyingSplitWeights else { return }
        isApplyingSplitWeights = true
        defer { isApplyingSplitWeights = false }
        applySplitWeightsRecursively(outer)
    }

    private func applySplitWeightsRecursively(_ split: NSSplitView) {
        applySplitWeights(to: split)
        for sub in split.arrangedSubviews.compactMap({ $0 as? NSSplitView }) {
            applySplitWeightsRecursively(sub)
        }
    }

    /// divider i = start + Σ(total·w₀…wᵢ) + i·gap, total = 길이 − gap·(n−1) — `frames(in:gap:)`와 같은 식이라
    /// 그린 frame이 순수 계산(미리보기)과 맞는다.
    private func applySplitWeights(to split: NSSplitView) {
        split.adjustSubviews()
        split.layoutSubtreeIfNeeded()
        let n = split.arrangedSubviews.count
        guard n > 1 else { return }
        let gap = split.dividerThickness
        let length = split.isVertical ? split.bounds.width : split.bounds.height
        let total = length - gap * CGFloat(n - 1)
        guard total > 1 else { return }
        let registered = splitWeights[ObjectIdentifier(split)] ?? []
        let weights = registered.count == n ? registered : Array(repeating: 1 / Double(n), count: n)
        let start = split.isVertical ? split.bounds.minX : split.bounds.minY
        var sum: CGFloat = 0
        for i in 0..<(n - 1) {
            sum += total * CGFloat(weights[i])
            split.setPosition(start + sum + CGFloat(i) * gap, ofDividerAt: i)
        }
    }

    /// 사용자가 `split`의 경계선을 끌어 놓았다. project tree를 그린 split이면 자식들의 축 방향 길이 비율을 그 tree
    /// path의 비율로 기억해 다음 relayout도 그 크기로 그리고, `onLayoutChanged`로 저장을 요청한다. 1pt 넘게 움직인
    /// 자식이 없으면(누르기만 함) 아무것도 바꾸지 않는다 — 떠난 잎의 자리도 그대로 남는다.
    func captureUserResize(of split: NSSplitView) {
        guard !isApplyingSplitWeights,
              let path = splitPaths[ObjectIdentifier(split)],
              let projectId = displayedProjectId,
              var layout = layouts[projectId],
              let visible = layout.visibleTree else { return }
        let lengths = split.arrangedSubviews.map { split.isVertical ? $0.frame.width : $0.frame.height }
        let total = lengths.reduce(0, +)
        guard lengths.count > 1, total > 1 else { return }
        let current = splitWeights[ObjectIdentifier(split)] ?? []
        let moved = current.count != lengths.count
            || zip(current, lengths).contains { abs(total * CGFloat($0) - $1) >= 1 }
        guard moved else { return }
        let weights = lengths.map { Double($0 / total) }
        let updated = visible.settingWeights(weights, atSplitPath: path)
        guard updated != visible else { return }
        layout.replaceVisibleTree(updated)
        layouts[projectId] = layout
        splitWeights[ObjectIdentifier(split)] = weights
        onLayoutChanged?()
    }

    private func makeSplit(vertical: Bool) -> NSSplitView {
        let split = GapSplitView(frame: .zero)
        split.isVertical = vertical
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        split.onUserResizeEnded = { [weak self] split in
            self?.captureUserResize(of: split)
        }
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
        /// 경계선 끌기가 끝났을 때(놓음). NSSplitView는 경계선 위 클릭만 받는다(나머지는 자식 view가 덮는다).
        var onUserResizeEnded: ((NSSplitView) -> Void)?

        override var dividerThickness: CGFloat { PaneDropPlanner.gap }
        override func drawDivider(in rect: NSRect) { /* transparent */ }

        override func mouseDown(with event: NSEvent) {
            // NSSplitView의 경계선 추적 루프는 마우스를 놓을 때 돌아온다.
            super.mouseDown(with: event)
            onUserResizeEnded?(self)
        }
    }

}

extension Workspace {
    /// Posted when the focused pane changes, so `ViewedPaneTracker` can tell the
    /// hook daemon which pane the user is looking at.
    static let focusedPaneDidChangeNotification = Notification.Name("termy.workspaceFocusedPaneDidChange")
}

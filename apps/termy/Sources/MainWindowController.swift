// MainWindowController.swift
//
// Owns the window, the mission-control dashboard strip, the Workspace (all
// panes in a single grid), and the top-mounted project filter. No tabs.
// Every pane in the window lives in Workspace; the filter bar decides which
// ones are visible.

import AppKit
import SwiftUI

/// NSWindow subclass that lets the main menu intercept ⌘-combos BEFORE the
/// terminal view sees them. Without this override, SwiftTerm's terminal
/// view consumes `⌘N` / `⌘W` / `⌘↵` as terminal keystrokes and the menu
/// items never fire.
final class TermyWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class MainWindowController: NSWindowController, NSMenuItemValidation, NSWindowDelegate {
    private let workspace = Workspace()
    /// Stable identity for this window — keys the shared `MissionControlModel`
    /// pane registry and the session record.
    let windowId = UUID()
    /// Shared app-wide dashboard model — every window observes the same one.
    private var missionControlModel: MissionControlModel { .shared }
    private var missionControlHost: NSHostingView<MissionControlView>?
    /// Debounced on-disk workspace saver. Exposed so `AppDelegate` can
    /// `flushSync()` before the process exits; otherwise private.
    private(set) var autosaver: WorkspaceAutosaver?
    private var projectSwitcher: ProjectSwitcherPanel?
    private var shortcutsPanel: KeyboardShortcutsPanel?
    private var fontSettingsPanel: FontSettingsPanel?
    /// Live heightAnchor for the mission-control hosting view, updated from
    /// SwiftUI whenever the bar wants to switch between its 44pt compact and
    /// 80pt two-row heights.
    private var missionControlHeight: NSLayoutConstraint?

    /// Top-row project filter. Strong ref so we can rebuild it when
    /// the pane set changes.
    private var filterBar: ProjectFilterBar?

    /// Set by `WindowManager` when this controller is registered. Used to
    /// route cross-window pane focus.
    weak var windowManager: WindowManager?

    private var rootContentView: AppearanceAwareView? {
        window?.contentView as? AppearanceAwareView
    }

    /// Convenience for callers that want a default-placed, freshly-seeded
    /// window. `WindowManager` uses the designated init directly.
    convenience init() {
        self.init(initialFrame: nil, sessionLayout: nil)
    }

    convenience init(initialFrame: NSRect?, sessionLayout: WindowRecord?) {
        // WorkspacePersistence init can fail if the app-support dir is
        // unwritable (FDA denied, disk full). Autosave silently degrades to
        // no-op in that case — the feature is best-effort, not load-bearing.
        self.init(initialFrame: initialFrame, sessionLayout: sessionLayout,
                  workspacePersistence: try? WorkspacePersistence())
    }

    /// - Parameters:
    ///   - initialFrame: window frame to apply; `nil` centers the window.
    ///   - sessionLayout: when present, the window replays this saved pane
    ///     layout instead of seeding a single HOME pane.
    ///   - workspacePersistence: where ⌘K layouts are autosaved; nil turns
    ///     autosave off. Tests pass a temporary folder.
    init(initialFrame: NSRect?, sessionLayout: WindowRecord?, workspacePersistence: WorkspacePersistence?) {
        let window = TermyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "termy"
        window.minSize = NSSize(width: 800, height: 480)
        if let initialFrame {
            window.setFrame(initialFrame, display: false)
        } else {
            window.center()
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .none

        let rootView = AppearanceAwareView(
            frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        )
        rootView.autoresizingMask = [.width, .height]
        rootView.wantsLayer = true
        window.contentView = rootView

        super.init(window: window)
        self.window?.delegate = self

        rootView.onAppearanceChange = { [weak self] appearance in
            self?.applyTheme(appearance: appearance)
        }
        applyTheme(appearance: rootView.effectiveAppearance)

        installFilterBar()
        setupMissionControlBar()
        setupWorkspace()

        if let workspacePersistence {
            self.autosaver = WorkspaceAutosaver(persistence: workspacePersistence, workspace: workspace)
        }

        workspace.onPanesChanged = { [weak self] in
            self?.onPanesChanged()
            self?.autosaver?.requestSave()
            self?.windowManager?.sessionAutosaver?.requestSave()
        }
        workspace.onFilterChanged = { [weak self] in self?.filterBar?.rebuild() }
        workspace.onPaneHeaderChanged = { [weak self] paneId, project, branch in
            self?.missionControlModel.setLabel(paneId: paneId, project: project, branch: branch)
            // `cd` drifted the pane's cwd — persist the new location.
            self?.autosaver?.requestSave()
            self?.windowManager?.sessionAutosaver?.requestSave()
        }
        // Seed the first pane, or replay a saved layout for a restored window.
        if let sessionLayout {
            applySessionLayout(sessionLayout)
        } else {
            workspace.addPane(launch: newPaneLaunch)
        }
    }

    /// 사용자가 만드는 새 local pane(새 창의 첫 pane·새 pane·split)의 backend. "Run local panes in herdr-core"를 따른다.
    private var newPaneLaunch: PaneLaunch { PaneLaunch.forNewLocalPane(defaults: .standard) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Project filter (top row)

    private func installFilterBar() {
        guard let contentView = rootContentView else { return }
        let bar = ProjectFilterBar(workspace: workspace)
        filterBar = bar

        bar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bar)
        NSLayoutConstraint.activate([
            // Pinned to the actual top of contentView (under the traffic-light
            // cluster) so the filter row absorbs the titlebar zone, Chrome-style.
            // `.fullSizeContentView` lets the system still render the traffic
            // lights on top; `78` clears their cluster width.
            bar.topAnchor.constraint(equalTo: contentView.topAnchor),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 78),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    // MARK: - Layout

    private func setupMissionControlBar() {
        guard let contentView = rootContentView else { return }
        let view = MissionControlView(
            model: missionControlModel,
            onFocusPane: { [weak self] paneId in
                self?.focusPane(byId: paneId)
            },
            onBarHeightChange: { [weak self] height in
                // Constraint.constant assignment always invalidates parent
                // layout — even when the value didn't change. Combined with
                // the SwiftUI measurement probe that drives the height,
                // an unconditional assign here can establish a feedback
                // loop where each layout pass re-stamps the same value.
                guard let constraint = self?.missionControlHeight,
                      abs(constraint.constant - height) > 0.5 else { return }
                constraint.constant = height
            }
        )
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host)

        // Pinned to the bottom — top row is for navigation control (filter),
        // bottom row is ambient agent state, matching the "status bar" layout
        // familiar from IDEs. Glanceable without stealing attention from the
        // active pane.
        let heightConstraint = host.heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([
            host.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            heightConstraint
        ])
        missionControlHost = host
        missionControlHeight = heightConstraint
    }

    private func setupWorkspace() {
        guard let contentView = rootContentView,
              let filterBar = filterBar,
              let missionBar = missionControlHost else { return }
        workspace.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(workspace)
        NSLayoutConstraint.activate([
            workspace.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            workspace.bottomAnchor.constraint(equalTo: missionBar.topAnchor),
            workspace.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            workspace.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }

    private func applyTheme(appearance: NSAppearance) {
        let theme = PaneStyling.theme(for: appearance)
        window?.backgroundColor = theme.windowBackgroundColor
        rootContentView?.layer?.backgroundColor = theme.contentBackgroundColor.cgColor
    }

    // MARK: - Pane bookkeeping

    private func onPanesChanged() {
        filterBar?.rebuild()
        let orderedIds = workspace.panes.map(\.paneId)
        // 업데이트 재시작 gate는 hc pane을 세지 않는다. setLivePaneIds가 gate를 다시 세게 하므로 먼저 알린다.
        missionControlModel.setHcPaneIds(
            Set(workspace.panes.filter { $0.launch.backendKind == .hc }.map(\.paneId)),
            forWindow: windowId
        )
        missionControlModel.setLivePaneIds(orderedIds, forWindow: windowId)
        Notifier.shared.pruneWaitingPanes(livePaneIds: Set(orderedIds))
        if workspace.panes.isEmpty {
            // Pre-emptively kick the autosave flush so the disk write is
            // already in flight (often complete) by the time
            // `applicationWillTerminate` blocks on it. Without this, the
            // WillTerminate semaphore wait stalls window finalization and
            // the close visibly lags.
            if let autosaver {
                Task { await autosaver.flushSync() }
            }
            window?.performClose(nil)
        }
    }

    /// Dashboard-click / banner-tap routing. Delegates to `WindowManager` so
    /// a pane in another window brings that window forward. Falls back to a
    /// local focus when this controller isn't registered (single-window).
    func focusPane(byId paneId: String) {
        if let windowManager {
            windowManager.focusPane(byId: paneId)
        } else {
            _ = workspace.focusPane(byId: paneId)
        }
    }

    /// Focus a pane known to live in *this* window's workspace. Called by
    /// `WindowManager.focusPane(byId:)` after fronting the window — never
    /// re-routes, so it can't recurse.
    @discardableResult
    func focusLocalPane(byId paneId: String) -> Bool {
        workspace.focusPane(byId: paneId)
    }

    /// True when this window's workspace owns the pane.
    func containsPane(id paneId: String) -> Bool {
        workspace.panes.contains { $0.paneId == paneId }
    }

    /// This window's panes in creation order.
    var panes: [Pane] { workspace.panes }

    /// Forward an agent state to the pane if this window owns it.
    @discardableResult
    func applyAgentState(_ state: PaneState, toPaneId paneId: String) -> Bool {
        guard let pane = workspace.panes.first(where: { $0.paneId == paneId }) else { return false }
        pane.applyAgentState(state)
        return true
    }

    /// Snapshot this window's restorable state. Returns nil for a paneless
    /// window (nothing worth restoring). `includeAgentResume` adds each
    /// pane's live agent session — only the update-relaunch save asks.
    ///
    /// 모든 pane에 id·backend·project를 남기고, hc pane에만 hook 세부 정보를 남긴다(hc pane은 다시 켜면 같은
    /// terminal에 다시 붙고, 그사이 HookDaemon이 비어 있기 때문이다). agent resume은 local pane만 한다.
    func sessionWindowRecord(includeAgentResume: Bool = false) -> WindowRecord? {
        guard let window, !workspace.panes.isEmpty else { return nil }
        let rows: [[PaneRecord]] = workspace.rows.map { row in
            row.map { pane in
                let snapshot = missionControlModel.snapshot(paneId: pane.paneId)
                var record = PaneRecord(
                    cwd: pane.currentCwd,
                    agentResume: includeAgentResume ? pane.agentResumeRecord(snapshot: snapshot) : nil
                )
                record.paneId = pane.paneId
                record.backend = pane.launch.backendKind
                if case .hc(let machine) = pane.launch {
                    record.machine = machine
                    record.hookDetails = PaneHookDetails(snapshot: snapshot) ?? pane.restoredHookDetails
                }
                record.projectId = pane.projectId
                record.projectKey = pane.projectKey
                return record
            }
        }
        if rows.flatMap({ $0 }).isEmpty { return nil }
        let filterProjectId: String?
        switch workspace.filter {
        case .all: filterProjectId = nil
        case .project(let id): filterProjectId = id
        }
        let focusedIndex = workspace.focusedPane.flatMap { focused in
            workspace.panes.firstIndex { $0 === focused }
        }
        return WindowRecord(
            frame: FrameRecord(window.frame),
            rows: rows,
            filterProjectId: filterProjectId,
            focusedPaneIndex: focusedIndex,
            projectOrder: workspace.knownProjectIds
        )
    }

    /// Rebuild this window's panes from a saved `WindowRecord`. Mirrors the
    /// row/column replay used by the ⌘K project switcher: the first pane of
    /// each saved row goes in with `.row` axis, the rest with `.column`.
    private func applySessionLayout(_ record: WindowRecord) {
        for savedRow in record.rows {
            for (colIdx, paneRec) in savedRow.enumerated() {
                let axis: SplitAxis = (colIdx == 0) ? .row : .column
                // An update relaunch saved this pane's live agent session —
                // reopen the conversation where the agent was running.
                let plan = AgentResumeCapture.restorePlan(
                    paneCwd: paneRec.cwd,
                    resume: paneRec.agentResume,
                    directoryExists: { FileManager.default.directoryExists(atPath: $0) }
                )
                addRestoredPane(paneRec, cwd: plan.cwd, splitAxis: axis, startupInput: plan.startupInput)
            }
        }
        // Defensive: an empty saved record would leave a paneless window.
        if workspace.panes.isEmpty {
            workspace.addPane()
            return
        }
        // Restore the chip arrangement before the filter so the bar rebuilds
        // once, already in the user's order.
        if let projectOrder = record.projectOrder {
            workspace.applyProjectOrder(projectOrder)
        }
        if let projectId = record.filterProjectId {
            workspace.filter = .project(projectId)
        }
        if let idx = record.focusedPaneIndex,
           idx >= 0, idx < workspace.panes.count {
            workspace.focus(pane: workspace.panes[idx])
        }
    }

    /// 저장된 pane 하나를 다시 만든다. 저장된 id와 backend를 그대로 쓰므로 hc pane은 label로 자기 terminal을 찾아
    /// 다시 붙고, hc를 쓸 수 없어도 local로 바뀌지 않는다(backend가 unavailable로 두고 다시 연결한다).
    /// hc pane은 저장된 project를 쓰고(원격 project는 cwd로 정할 수 없다) hook 세부 정보를 되살린다. local pane의
    /// project는 지금처럼 cwd로 정한다(agent resume이 cwd를 바꿀 수 있다). 기록에 없는 값은 지금 동작 그대로다.
    @discardableResult
    private func addRestoredPane(
        _ record: PaneRecord, cwd: String, splitAxis: SplitAxis, startupInput: String?, launch launchOverride: PaneLaunch? = nil
    ) -> Pane {
        let launch = launchOverride ?? record.launch
        let isHc = launch.backendKind == .hc
        let paneId = reusablePaneId(record.paneId)
        let pane = workspace.addPane(
            cwd: cwd,
            splitAxis: splitAxis,
            startupInput: startupInput,
            paneId: paneId,
            launch: launch,
            projectId: isHc ? record.projectId : nil,
            projectKey: isHc ? record.projectKey : nil
        )
        if isHc, paneId != nil, let details = record.hookDetails {
            pane.restoreHookDetails(details)
        }
        return pane
    }

    /// 저장된 pane id를 다시 써도 되면 그 값, 아니면 nil(새 id). 같은 id의 pane이 이미 어느 창에 있으면(⌘K 기록의
    /// pane이 `cd`로 다른 project에 옮겨 가 살아 있는 경우 등) 다시 쓰지 않는다. hc pane 둘이 한 terminal에 붙는다.
    private func reusablePaneId(_ saved: String?) -> String? {
        guard let saved, !saved.isEmpty,
              !missionControlModel.livePaneIds.contains(saved),
              !workspace.panes.contains(where: { $0.paneId == saved })
        else { return nil }
        return saved
    }

    /// hc에 살아 있는데 저장된 레이아웃에 없던 terminal을 이 창의 pane으로 연다. 같은 pane id로 만들므로
    /// backend가 label로 그 terminal을 찾아 붙는다. 이미 그 id의 pane이 있으면 아무것도 하지 않는다.
    func adoptHcOrphan(_ orphan: HcOrphan) {
        guard let paneId = reusablePaneId(orphan.paneId) else { return }
        workspace.addPane(
            cwd: orphan.cwd,
            paneId: paneId,
            launch: .hc(machine: orphan.machine),
            projectId: HcRestorePlanner.projectId(for: orphan),
            projectKey: orphan.projectKey
        )
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newPane(_:)),
             #selector(closePane(_:)),
             #selector(toggleMaximizePane(_:)),
             #selector(focusPrevPane(_:)),
             #selector(focusNextPane(_:)),
             #selector(cycleFilterPrev(_:)),
             #selector(cycleFilterNext(_:)):
            return true
        default:
            return true
        }
    }

    // MARK: - Menu actions

    @IBAction func newPane(_ sender: Any?) {
        workspace.addPane(launch: newPaneLaunch)
    }

    /// ⌘/ — open (or toggle) the keyboard-shortcuts overlay.
    @IBAction func showKeyboardShortcuts(_ sender: Any?) {
        let panel = shortcutsPanel ?? {
            let p = KeyboardShortcutsPanel()
            self.shortcutsPanel = p
            return p
        }()
        panel.toggle(over: window)
    }

    /// ⌘, — open (or toggle) the terminal font settings panel.
    @IBAction func showFontSettings(_ sender: Any?) {
        let panel = fontSettingsPanel ?? {
            let p = FontSettingsPanel()
            self.fontSettingsPanel = p
            return p
        }()
        panel.toggle(over: window)
    }

    /// ⌘+ / ⌘- — bump the terminal font size by 1pt. The preference setter
    /// clamps to [minPointSize, maxPointSize], so we don't guard the bounds
    /// here. `update(...)` posts the change notification that every Pane
    /// listens for, so all live terminals re-render at the new size.
    @IBAction func increaseFontSize(_ sender: Any?) {
        adjustFontSize(by: 1)
    }

    @IBAction func decreaseFontSize(_ sender: Any?) {
        adjustFontSize(by: -1)
    }

    private func adjustFontSize(by delta: CGFloat) {
        let pref = TerminalFontPreference.shared
        pref.update(
            primaryName: pref.primaryFontName,
            pointSize: pref.pointSize + delta,
            cjkFallbackName: pref.cjkFallbackName
        )
    }

    /// ⌘K — open the fuzzy project switcher, or toggle-close it if the user
    /// hit ⌘K reflexively on an already-open empty palette. Silently no-ops
    /// if autosave init failed (can't show a project list without persistence).
    @IBAction func showProjectSwitcher(_ sender: Any?) {
        guard let persistence = autosaver?.persistence else { return }
        let panel = projectSwitcher ?? {
            let p = ProjectSwitcherPanel()
            p.onPick = { [weak self] record in
                self?.restore(workspace: record)
            }
            p.onDelete = { record in
                Task { await persistence.delete(canonicalPath: record.canonicalPath) }
            }
            self.projectSwitcher = p
            return p
        }()

        // Projects with live panes in any window. The autosaver writes their
        // records back on its next save, so the panel offers no remove for them.
        let openPaths = Set((windowManager?.controllers ?? [self])
            .flatMap { $0.workspace.panes }
            .map { ProjectIdentity.canonicalPath(for: $0.currentCwd) })

        // persistence.all() is async — hop off MainActor, grab the list,
        // then toggle the panel from the main actor with the result.
        Task { @MainActor in
            let records = await persistence.all()
            panel.toggle(records: records, openPaths: openPaths, over: self.window)
        }
    }

    /// Take a saved workspace record and bring it onscreen.
    /// * Alive panes for that canonical project → just switch the filter
    ///   (keeps the live agents untouched).
    /// * No alive panes → create new shells following the saved row grid.
    ///   First pane of each saved row goes in with `.row` axis so it lands
    ///   in its own horizontal row; subsequent panes in that saved row use
    ///   `.column` axis to sit beside the prior one. This reproduces
    ///   vertical splits (multiple rows) vs horizontal splits (panes within
    ///   one row) the way the user left them.
    private func restore(workspace record: WorkspaceRecord) {
        let ws = workspace
        let alive = ws.panes.filter { pane in
            ProjectIdentity.canonicalPath(for: pane.currentCwd) == record.canonicalPath
        }
        if !alive.isEmpty {
            ws.filter = .project(record.displayLabel)
            if let first = alive.first {
                ws.focus(pane: first)
            }
            return
        }
        // Replay the saved row structure. `addPane` uses the currently-
        // focused pane + axis to decide placement; we drive that by choosing
        // `.row` for the first pane of each saved row and `.column` for
        // each pane that follows on the same row.
        for savedRow in record.effectiveRows {
            for (colIdx, paneRec) in savedRow.enumerated() {
                let axis: SplitAxis = (colIdx == 0) ? .row : .column
                addRestoredPane(
                    paneRec, cwd: paneRec.cwd, splitAxis: axis, startupInput: nil,
                    launch: PaneLaunch.forReopenedRecord(paneRec, defaults: .standard))
            }
        }
        // All new panes belong to the restored project — lock the filter to it.
        ws.filter = .project(record.displayLabel)
    }

    @IBAction func splitColumn(_ sender: Any?) {
        workspace.addPane(splitAxis: .column, launch: newPaneLaunch)
    }

    @IBAction func splitRow(_ sender: Any?) {
        workspace.addPane(splitAxis: .row, launch: newPaneLaunch)
    }

    @IBAction func closePane(_ sender: Any?) {
        let empty = workspace.closeFocusedPane()
        if empty { window?.performClose(nil) }
    }

    @IBAction func toggleMaximizePane(_ sender: Any?) {
        workspace.toggleMaximize()
    }

    @IBAction func focusPrevPane(_ sender: Any?) {
        workspace.cycleFocus(delta: -1)
    }

    @IBAction func focusNextPane(_ sender: Any?) {
        workspace.cycleFocus(delta: 1)
    }

    func focusPane(direction: FocusDirection) {
        workspace.focusPaneInDirection(direction)
    }

    /// Repurposed from the old tab-cycling shortcut (⌘⇧[).
    @IBAction func cycleFilterPrev(_ sender: Any?) {
        workspace.cycleFilter(delta: -1)
    }

    /// Repurposed from the old tab-cycling shortcut (⌘⇧]).
    @IBAction func cycleFilterNext(_ sender: Any?) {
        workspace.cycleFilter(delta: 1)
    }

    /// Direct filter jump — ⌘0 = ALL when available.
    func selectAllFilter() {
        workspace.selectAllFilter()
    }

    /// Direct project-filter jump — ⌘1 starts at the first project segment.
    func selectProjectFilter(at index: Int) {
        workspace.selectProjectFilter(at: index)
    }

    /// Dashboard cycling — ⌘⌥[ / ⌘⌥]. Walks the mission-control bar in
    /// pane-creation order (left to right as rendered), wrapping around.
    /// Separate from ⌘[/] (layout order within the workspace) and
    /// ⌘⇧[/] (filter cycle).
    func cycleDashboardItem(delta: Int) {
        let items = missionControlModel.items
        guard !items.isEmpty else { return }
        let currentId = workspace.focusedPane?.paneId
        let currentIndex = items.firstIndex { $0.paneId == currentId }
        let next: Int
        if let idx = currentIndex {
            next = (idx + delta + items.count) % items.count
        } else {
            // Focused pane isn't on the dashboard (e.g. INIT, no attention).
            // Pick the head for forward, tail for backward.
            next = delta >= 0 ? 0 : items.count - 1
        }
        focusPane(byId: items[next].paneId)
    }

    /// Direct dashboard jump — ⌘⌥1..⌘⌥9. Index into the dashboard's
    /// creation-order items so ⌘⌥N is always "the Nth pane from the left",
    /// independent of state.
    func selectDashboardItem(at index: Int) {
        let items = missionControlModel.items
        guard index >= 0, index < items.count else { return }
        focusPane(byId: items[index].paneId)
    }

    /// ⌘G — jump to the next pane in WAITING state, wrapping around.
    /// With fixed creation-order chips, WAITING panes no longer float to the
    /// front; this shortcut is the "which agent needs me right now" jump.
    /// No-op when nothing is waiting.
    func cycleWaitingPane() {
        let waiting = missionControlModel.items.filter { $0.state == .waiting }
        guard !waiting.isEmpty else { return }
        let currentId = workspace.focusedPane?.paneId
        if let idx = waiting.firstIndex(where: { $0.paneId == currentId }) {
            let next = (idx + 1) % waiting.count
            focusPane(byId: waiting[next].paneId)
        } else {
            focusPane(byId: waiting[0].paneId)
        }
    }

    // MARK: - Window delegate

    func windowDidResize(_ notification: Notification) {
        windowManager?.sessionAutosaver?.requestSave()
    }

    func windowDidMove(_ notification: Notification) {
        windowManager?.sessionAutosaver?.requestSave()
    }

    /// Deregister from the app-wide window/dashboard registries when this
    /// window closes. `removeWindow` is idempotent, so a close triggered by
    /// the last-pane path and an explicit ⌘⇧W both land here safely.
    ///
    /// hc pane: 사용자가 창을 닫으면(마지막 창이라 앱이 곧 끝나도) terminal을 끝내고, 앱 종료 중(⌘Q·업데이트
    /// 재시작)에 창이 정리되면 남긴다. `Workspace.windowWillClose`가 `AppLifecycle.isTerminating`으로 가른다.
    func windowWillClose(_ notification: Notification) {
        workspace.windowWillClose()
        windowManager?.removeWindow(self)
    }
}

// MARK: - Focus direction

enum FocusDirection {
    case left, right, up, down
}

// MARK: - Project identity

enum ProjectIdentity {
    /// Display label for the project this cwd belongs to. Basename of the
    /// containing worktree root (first ancestor with `.git`), or of the cwd
    /// itself if no `.git` is found.
    ///
    /// ⚠️ NOT a persistence key — basename collides between two unrelated
    /// repos that happen to share a name (`~/code/api` vs `~/other/api`).
    /// For persistence, use `canonicalPath(for:)`.
    static func derive(for cwd: String) -> String {
        let root = worktreeRoot(for: cwd)
        return (root as NSString).lastPathComponent
    }

    /// Symlink-resolved absolute path of the worktree root — the persistence
    /// key for `WorkspacePersistence`. Distinct between two unrelated repos
    /// sharing a basename, distinct between a worktree and its main repo
    /// (git worktrees write their own `.git` file in the worktree dir), and
    /// equal across symlinks pointing at the same location.
    static func canonicalPath(for cwd: String) -> String {
        worktreeRoot(for: cwd)
    }

    /// Walk up from `cwd` looking for the first ancestor containing a `.git`
    /// entry (file or directory — git worktrees use `.git` as a file), and
    /// return that ancestor's symlink-resolved absolute path. Falls back to
    /// the resolved cwd when no `.git` is found.
    private static func worktreeRoot(for cwd: String) -> String {
        let fm = FileManager.default
        let resolvedCwd = URL(fileURLWithPath: cwd, isDirectory: true).resolvingSymlinksInPath().path
        var path = resolvedCwd
        while path != "/" {
            let gitPath = (path as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitPath) {
                return path
            }
            path = (path as NSString).deletingLastPathComponent
        }
        return resolvedCwd
    }
}

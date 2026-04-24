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
    private let missionControlModel = MissionControlModel()
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
    private var rootContentView: AppearanceAwareView? {
        window?.contentView as? AppearanceAwareView
    }

    init() {
        let window = TermyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "termy"
        window.minSize = NSSize(width: 800, height: 480)
        window.center()
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

        // WorkspacePersistence init can fail if the app-support dir is
        // unwritable (FDA denied, disk full). Autosave silently degrades to
        // no-op in that case — the feature is best-effort, not load-bearing.
        if let persistence = try? WorkspacePersistence() {
            self.autosaver = WorkspaceAutosaver(persistence: persistence, workspace: workspace)
        }

        workspace.onPanesChanged = { [weak self] in
            self?.onPanesChanged()
            self?.autosaver?.requestSave()
        }
        workspace.onFilterChanged = { [weak self] in self?.filterBar?.rebuild() }
        workspace.onPaneHeaderChanged = { [weak self] paneId, project, branch in
            self?.missionControlModel.setLabel(paneId: paneId, project: project, branch: branch)
            // `cd` drifted the pane's cwd — persist the new location.
            self?.autosaver?.requestSave()
        }
        // Single funnel for pane-state updates: HookDaemon → MissionControlModel
        // → Notifier. AsyncStream only supports one `for await`, so Notifier
        // receives events via this forward instead of subscribing directly.
        missionControlModel.onSnapshotUpdate = { snap in
            Notifier.shared.handle(snap)
        }

        // Seed the first pane using HOME.
        workspace.addPane()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Project filter (top row)

    private func installFilterBar() {
        guard let window = window, let contentView = rootContentView else { return }
        let bar = ProjectFilterBar(workspace: workspace)
        filterBar = bar

        bar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bar)
        let topAnchor: NSLayoutYAxisAnchor = {
            if let guide = window.contentLayoutGuide as? NSLayoutGuide {
                return guide.topAnchor
            }
            return contentView.topAnchor
        }()
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 32)
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
                self?.missionControlHeight?.constant = height
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
        missionControlModel.setLivePaneIds(orderedIds)
        Notifier.shared.pruneWaitingPanes(livePaneIds: Set(orderedIds))
        if workspace.panes.isEmpty {
            window?.performClose(nil)
        }
    }

    /// Dashboard-click routing: find the pane by id, focus it (auto-switches
    /// filter if needed).
    func focusPane(byId paneId: String) {
        _ = workspace.focusPane(byId: paneId)
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
        workspace.addPane()
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
            self.projectSwitcher = p
            return p
        }()

        // persistence.all() is async — hop off MainActor, grab the list,
        // then toggle the panel from the main actor with the result.
        Task { @MainActor in
            let records = await persistence.all()
            panel.toggle(records: records, over: self.window)
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
                ws.addPane(cwd: paneRec.cwd, splitAxis: axis)
            }
        }
        // All new panes belong to the restored project — lock the filter to it.
        ws.filter = .project(record.displayLabel)
    }

    @IBAction func splitColumn(_ sender: Any?) {
        workspace.addPane(splitAxis: .column)
    }

    @IBAction func splitRow(_ sender: Any?) {
        workspace.addPane(splitAxis: .row)
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

    func windowDidResize(_ notification: Notification) {}
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

// WindowManager.swift
//
// App-level owner of every MainWindowController. Creates windows (⌘N and
// session restore), routes cross-window pane focus, and — once wired in
// Task 5 — drives session save/restore. Owned by AppDelegate; exactly one
// instance exists.

import AppKit
import os

@MainActor
final class WindowManager {
    private(set) var controllers: [MainWindowController] = []
    private let sessionPersistence: SessionPersistence?
    private(set) var sessionAutosaver: SessionAutosaver?
    /// Each new window's ⌘K autosave target.
    private let workspacePersistence: () -> WorkspacePersistence?
    private let defaults: UserDefaults

    convenience init() {
        // Persistence init can fail if app-support is unwritable — session
        // restore/save then silently degrades to no-op (best-effort feature).
        self.init(sessionPersistence: try? SessionPersistence(),
                  workspacePersistence: { try? WorkspacePersistence() },
                  defaults: .standard)
    }

    /// Tests pass a temporary folder's persistence and in-memory defaults so
    /// nothing reaches the user's ~/Library/Application Support/termy.
    init(sessionPersistence: SessionPersistence?,
         workspacePersistence: @escaping () -> WorkspacePersistence?,
         defaults: UserDefaults) {
        self.sessionPersistence = sessionPersistence
        self.workspacePersistence = workspacePersistence
        self.defaults = defaults
        self.sessionAutosaver = nil
        if let sessionPersistence {
            self.sessionAutosaver = SessionAutosaver(
                persistence: sessionPersistence,
                windowManager: self
            )
        }
    }

    /// Restore saved windows. Returns true if at least one window opened.
    /// 다른 instance(Debug ↔ release)가 남긴 hc pane은 빼고 열고, 그래서 pane이 남지 않는 창은 열지 않는다
    /// (`WindowRecord.restorable`).
    func restoreSessionWindows() async -> Bool {
        guard let sessionPersistence else { return false }
        guard case .loaded(let record) = await sessionPersistence.load() else {
            return false
        }
        let windows = record.windows.compactMap { $0.restorable(instance: HcSessionManager.instanceLabel) }
        guard !windows.isEmpty else { return false }
        for windowRecord in windows {
            restoreWindow(from: windowRecord)
        }
        // Rewrite session.json now. Restored windows replay their panes
        // before `windowManager` is wired, so no save has fired yet — and an
        // update relaunch's agent-resume records must not resume again on a
        // later launch.
        sessionAutosaver?.requestSave()
        return true
    }

    // MARK: - hc 고아 terminal

    /// 고아 정리에 hc를 연결할지. hc pane이 있거나 로컬 hc 설정이 켜져 있을 때만이다: local pane만 쓰는 사용자는
    /// herdr-core를 띄우지도, 연결하지도 않는다.
    nonisolated static func shouldAdoptHcOrphans(paneKinds: [PaneBackendKind], defaults: UserDefaults) -> Bool {
        paneKinds.contains(.hc) || HcFeatureSettings.localPanesEnabled(defaults)
    }

    /// `restoreSessionWindows` 뒤에 부른다. 자기 instance label이 있는데 어느 창에도 pane이 없는 살아 있는 hc
    /// terminal(autosave 전에 꺼진 경우 등)을 첫 창에 pane으로 열어 붙인다. 보이지 않는 곳에서 agent가 도는 일을
    /// 막는다. 연결하지 못하면 아무것도 하지 않는다(복원한 hc pane은 각자 unavailable로 남아 다시 연결한다).
    func adoptHcOrphans() async {
        let kinds = controllers.flatMap(\.panes).map(\.launch.backendKind)
        guard !controllers.isEmpty, Self.shouldAdoptHcOrphans(paneKinds: kinds, defaults: defaults) else { return }
        let manager = HcSessionManager.shared
        do {
            try await manager.ensureConnected()
        } catch {
            return
        }
        // 연결을 기다리는 사이 창과 pane이 바뀌었을 수 있다. 지금 것으로 다시 본다.
        guard let target = controllers.first else { return }
        let known = Set(controllers.flatMap(\.panes).map(\.paneId))
        let live = manager.store.termyTerminals(instance: HcSessionManager.instanceLabel)
            .filter { !manager.isKilling(address: $0.address) }   // 방금 닫은 pane의 terminal(kill 응답 대기)
        for orphan in HcRestorePlanner.orphans(live: live, knownPaneIds: known) {
            target.adoptHcOrphan(orphan)
        }
    }

    /// hook 세부 정보가 바뀐 pane이 hc pane이면 session 저장을 요청한다(SessionAutosaver가 debounce한다). hc pane의
    /// 세부 정보는 session.json에만 남는데(다시 켜면 HookDaemon이 비어 있다) hook은 레이아웃을 바꾸지 않아 다른 저장
    /// 요청이 오지 않고, 종료 때의 저장에는 기댈 수 없다. local pane은 세부 정보를 남기지 않으므로 저장하지 않는다.
    func hookDetailsChanged(paneId: String) {
        let isHcPane = controllers.contains { controller in
            controller.panes.contains { $0.paneId == paneId && $0.launch.backendKind == .hc }
        }
        guard isHcPane else { return }
        sessionAutosaver?.requestSave()
    }

    /// Final session save before a Sparkle update relaunch: snapshot every
    /// window with each pane's live agent session and seal session.json so
    /// nothing written during shutdown replaces it. The next launch reopens
    /// those conversations (`MainWindowController.applySessionLayout`).
    func prepareForUpdateRelaunch() {
        guard let sessionPersistence else { return }
        let records = controllers.compactMap { $0.sessionWindowRecord(includeAgentResume: true) }
        do {
            try sessionPersistence.sealWithFinalRecord(SessionRecord(windows: records))
        } catch {
            // The relaunch goes ahead regardless; the log says why nothing
            // resumed afterwards.
            Self.updateLog.error("update relaunch session seal failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static let updateLog = Logger(subsystem: "app.termy", category: "update")

    // MARK: - Window creation

    /// Open a fresh window with a single HOME pane, cascaded off the
    /// front-most existing window so it doesn't land exactly on top.
    @discardableResult
    func newWindow() -> MainWindowController {
        let previousFrame = controllers.last?.window?.frame
        let frame = previousFrame.map { WindowManager.nextCascadeFrame(after: $0) }
        let controller = MainWindowController(initialFrame: frame, sessionLayout: nil,
                                              workspacePersistence: workspacePersistence())
        register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sessionAutosaver?.requestSave()
        return controller
    }

    /// Recreate a window from a saved `WindowRecord`, clamping its frame to
    /// the currently visible screen area.
    @discardableResult
    func restoreWindow(from record: WindowRecord) -> MainWindowController {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let frame = WindowManager.clampedFrame(record.frame.cgRect, toVisible: visibleFrames)
        let controller = MainWindowController(initialFrame: frame, sessionLayout: record,
                                              workspacePersistence: workspacePersistence())
        register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private func register(_ controller: MainWindowController) {
        controller.windowManager = self
        controllers.append(controller)
    }

    /// Called from `MainWindowController.windowWillClose`.
    func removeWindow(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        MissionControlModel.shared.removeWindow(controller.windowId)
        // The closed window's panes are gone — drop any WAITING entries for
        // panes that no longer exist anywhere.
        Notifier.shared.pruneWaitingPanes(livePaneIds: MissionControlModel.shared.livePaneIds)
        sessionAutosaver?.requestSave()
        // Previews belong to the main windows. With none left, close them
        // too so "closing the last window quits termy" still holds.
        if controllers.isEmpty {
            PreviewManager.shared.closeAll()
        }
    }

    // MARK: - Cross-window routing

    /// Focus the pane with `paneId` wherever it lives: bring its window to
    /// the front, activate the app, then focus the pane inside that window.
    /// No-op when no window owns the pane.
    func focusPane(byId paneId: String) {
        guard let owner = controllers.first(where: { $0.containsPane(id: paneId) }) else {
            return
        }
        owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = owner.focusLocalPane(byId: paneId)
    }

    /// Route a pane's agent state to whichever window owns the pane.
    func applyAgentState(_ state: PaneState, toPaneId paneId: String) {
        for controller in controllers where controller.applyAgentState(state, toPaneId: paneId) {
            return
        }
    }

    // MARK: - Cascade / clamp (pure helpers — unit tested)

    static let defaultWindowSize = CGSize(width: 1200, height: 760)
    static let cascadeStep: CGFloat = 28

    /// Frame for the next window: stepped down-right from `previous`.
    static func nextCascadeFrame(after previous: CGRect) -> CGRect {
        CGRect(
            x: previous.origin.x + cascadeStep,
            y: previous.origin.y - cascadeStep,
            width: previous.width,
            height: previous.height
        )
    }

    /// Clamp `frame` to the visible screen area. If it already intersects
    /// some visible screen it is returned unchanged; otherwise it is
    /// re-centered on the first visible screen (size capped to that screen).
    static func clampedFrame(_ frame: CGRect, toVisible visibleFrames: [CGRect]) -> CGRect {
        guard let primary = visibleFrames.first else { return frame }
        if visibleFrames.contains(where: { $0.intersects(frame) }) {
            return frame
        }
        let width = min(frame.width, primary.width)
        let height = min(frame.height, primary.height)
        return CGRect(
            x: primary.origin.x + (primary.width - width) / 2,
            y: primary.origin.y + (primary.height - height) / 2,
            width: width,
            height: height
        )
    }
}

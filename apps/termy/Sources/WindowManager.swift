// WindowManager.swift
//
// App-level owner of every MainWindowController. Creates windows (⌘N and
// session restore), routes cross-window pane focus, and — once wired in
// Task 5 — drives session save/restore. Owned by AppDelegate; exactly one
// instance exists.

import AppKit

@MainActor
final class WindowManager {
    private(set) var controllers: [MainWindowController] = []

    init() {}

    // MARK: - Window creation

    /// Open a fresh window with a single HOME pane, cascaded off the
    /// front-most existing window so it doesn't land exactly on top.
    @discardableResult
    func newWindow() -> MainWindowController {
        let previousFrame = controllers.last?.window?.frame
        let frame = previousFrame.map { WindowManager.nextCascadeFrame(after: $0) }
        let controller = MainWindowController(initialFrame: frame, sessionLayout: nil)
        register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    /// Recreate a window from a saved `WindowRecord`, clamping its frame to
    /// the currently visible screen area.
    @discardableResult
    func restoreWindow(from record: WindowRecord) -> MainWindowController {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let frame = WindowManager.clampedFrame(record.frame.cgRect, toVisible: visibleFrames)
        let controller = MainWindowController(initialFrame: frame, sessionLayout: record)
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

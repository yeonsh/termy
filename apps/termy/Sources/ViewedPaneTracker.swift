import AppKit

/// Tells the hook daemon which pane the user is looking at: the focused pane
/// of the key window, while termy is the active app. A turn-end WAIT only
/// decays to IDLE after it has been seen, so this is what lets finished
/// panes settle.
@MainActor
final class ViewedPaneTracker {
    static let shared = ViewedPaneTracker()

    private var observers: [NSObjectProtocol] = []
    private var lastSent: String??
    /// Daemon calls are chained so they arrive in the order the changes happened.
    private var pending: Task<Void, Never>?

    /// The viewed pane id, or nil when the user isn't looking at any pane.
    nonisolated static func resolve(isAppActive: Bool, keyWindowFocusedPaneId: String?) -> String? {
        isAppActive ? keyWindowFocusedPaneId : nil
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            Workspace.focusedPaneDidChangeNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        let id = Self.resolve(
            isAppActive: NSApp.isActive,
            keyWindowFocusedPaneId: (NSApp.keyWindow?.windowController as? MainWindowController)?.focusedPaneId
        )
        if let lastSent, lastSent == id { return }
        lastSent = .some(id)
        let previous = pending
        pending = Task {
            await previous?.value
            await HookDaemon.shared.setViewedPane(id)
        }
    }
}

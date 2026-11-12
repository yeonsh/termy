import AppKit

/// Tells the hook daemon which pane the user is looking at: the focused pane
/// of the key window, while termy is the active app. A turn-end WAIT only
/// decays to IDLE after it has been seen, so this is what lets finished
/// panes settle.
@MainActor
final class ViewedPaneTracker {
    static let shared = ViewedPaneTracker(
        schedule: MainQueueTimer.schedule,
        resolver: {
            resolve(
                isAppActive: NSApp.isActive,
                keyWindowFocusedPaneId: (NSApp.keyWindow?.windowController as? MainWindowController)?.focusedPaneId
            )
        },
        sender: { id in ViewedPaneTracker.sendToDaemon(id) }
    )

    /// Programmatic jumps (⌘G, chips, banner taps) pass through intermediate
    /// focus states; only the state that survives this long counts as seen.
    static let settleDelay: TimeInterval = 0.3

    private let schedule: ScheduleAfter
    private let resolver: @MainActor () -> String?
    private let sender: @MainActor (String?) -> Void
    private var cancelPending: (@MainActor () -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastSent: String??
    /// Daemon calls are chained so they arrive in the order the changes happened.
    private static var pending: Task<Void, Never>?

    init(
        schedule: @escaping ScheduleAfter,
        resolver: @escaping @MainActor () -> String?,
        sender: @escaping @MainActor (String?) -> Void
    ) {
        self.schedule = schedule
        self.resolver = resolver
        self.sender = sender
    }

    private static func sendToDaemon(_ id: String?) {
        let previous = pending
        pending = Task {
            await previous?.value
            await HookDaemon.shared.setViewedPane(id)
        }
    }

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
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        refresh()
    }

    /// (Re)arm the settle timer; only the state still standing when it fires is sent.
    func scheduleRefresh() {
        cancelPending?()
        cancelPending = schedule(Self.settleDelay) { [weak self] in
            self?.cancelPending = nil
            self?.refresh()
        }
    }

    func refresh() {
        let id = resolver()
        if let lastSent, lastSent == id { return }
        lastSent = .some(id)
        sender(id)
    }
}

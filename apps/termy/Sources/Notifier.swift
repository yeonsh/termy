// Notifier.swift
//
// Native macOS attention signals on WAITING transitions. Closes the loop on
// the project pitch: "you stop losing track of which agent needs you" means
// the user finds out *without* having to check the dashboard.
//
// Layered so at least one signal always lands, even when banners are denied
// (common on ad-hoc-signed dev builds):
//   1. Dock badge — shows the count of WAITING panes. TCC-free, persists
//      until the badge count drops to zero.
//   2. Sound — `NSSound(named: "Glass")` on every fresh WAIT transition.
//      TCC-free; the user can mute system alerts if they want it silent.
//   3. Dock bounce — `requestUserAttention` pings the dock icon when termy
//      is not the frontmost app. No-op when active.
//   4. Banner — `UNUserNotification` with default sound. Requires the user
//      to have granted notification permission. Fails gracefully if not.
//
// Driven by MissionControlModel.onSnapshotUpdate (single subscriber — see
// the note there about AsyncStream's single-consumer invariant). Previously
// Notifier had its own `for await` on HookDaemon.updates and silently lost
// most events because MissionControlModel was draining the same stream.

import AppKit
import Foundation
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Wired by AppDelegate so notification taps can focus the right pane.
    var onFocusPane: ((String) -> Void)?

    private var previousStates: [String: PaneState] = [:]
    /// Pane ids currently in WAITING. Used to drive the dock badge count so
    /// the badge only shows when there is real work pending.
    private var waitingPaneIds: Set<String> = []

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                TrayLog.log("Notifier: auth error \(error)")
            } else {
                TrayLog.log("Notifier: auth granted=\(granted)")
            }
        }
    }

    /// Called by MissionControlModel for every pane-state update. This is the
    /// single funnel for WAIT detection since AsyncStream<DaemonUpdate> only
    /// supports one consumer.
    func handle(_ snap: PaneSnapshot) {
        let prev = previousStates[snap.paneId]
        previousStates[snap.paneId] = snap.state

        let wasWaiting = waitingPaneIds.contains(snap.paneId)
        let isWaiting = snap.state == .waiting
        if isWaiting {
            waitingPaneIds.insert(snap.paneId)
        } else {
            waitingPaneIds.remove(snap.paneId)
        }
        if wasWaiting != isWaiting {
            updateDockBadge()
        }

        // Only *entering* WAITING is a notification event. Staying waiting
        // or leaving it isn't.
        guard isWaiting, prev != .waiting else { return }

        // Sound fires unconditionally — a short audible cue works even when
        // termy is active (user may be in another window/pane) and doesn't
        // need TCC approval. `.criticalSoundRequest`-style Glass is a
        // familiar "look here" chime on macOS.
        NSSound(named: "Glass")?.play()

        // Dock bounce: documented no-op when the app is active. Fires the
        // icon bounce when the user is in another app, which is exactly the
        // scenario the project is optimized for (agent runs in background).
        NSApp.requestUserAttention(.informationalRequest)

        // Banner: may be denied on dev builds; harmless failure.
        post(for: snap)
    }

    /// Unified set of currently-waiting panes reflected in the dock badge.
    /// Prunes paneIds that no longer exist (closed panes).
    func pruneWaitingPanes(livePaneIds: Set<String>) {
        let stale = waitingPaneIds.subtracting(livePaneIds)
        if !stale.isEmpty {
            waitingPaneIds.subtract(stale)
            for id in stale { previousStates.removeValue(forKey: id) }
            updateDockBadge()
        }
    }

    private func updateDockBadge() {
        let n = waitingPaneIds.count
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    /// Jump to System Settings > Notifications for this app so the user can
    /// flip the banner switch on. Called from the menu item.
    static func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Post

    private func post(for snap: PaneSnapshot) {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: snap)
        content.body = notificationBody(for: snap)
        content.sound = .default
        content.userInfo = ["paneId": snap.paneId]

        // Stable per-pane id: replacing an older banner for the same pane
        // prevents a stack of stale "needs you" banners if the user has been
        // away for a while.
        let request = UNNotificationRequest(
            identifier: "app.termy.waiting.\(snap.paneId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                TrayLog.log("Notifier: add failed \(error)")
            }
        }
    }

    private func notificationTitle(for snap: PaneSnapshot) -> String {
        let project = snap.projectId?.isEmpty == false ? snap.projectId! : "Claude"
        return "\(project) needs you"
    }

    private func notificationBody(for snap: PaneSnapshot) -> String {
        // Codex panes carry waitSource; map it to user-facing copy first.
        if let source = snap.waitSource {
            switch source {
            case .permission:           return "Waiting for your approval."
            case .askUserQuestion:      return "Codex is asking a question."
            case .turnEnd:
                if let msg = snap.lastAssistantMessage, !msg.isEmpty {
                    return String(msg.prefix(140))
                }
                return "Codex finished — your turn."
            case .promotedFromPossible: return "Codex has been quiet for a while — check on it."
            }
        }
        if let reason = snap.notificationReason {
            switch reason {
            case "permission":         return "Waiting for your approval."
            case "idle":               return "Still idle — check what's pending."
            case "mcp_elicit":         return "An MCP tool is asking for input."
            case "ask_user_question":  return "Claude is asking a question."
            default:                   break
            }
        }
        if let msg = snap.lastAssistantMessage, !msg.isEmpty {
            return String(msg.prefix(140))
        }
        return "Claude is waiting for your response."
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Present even when termy is active — handle() already suppresses the
        // add() in that case, so reaching this method means the banner should
        // appear.
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let paneId = response.notification.request.content.userInfo["paneId"] as? String
        // Ack the system immediately; the pane focus work can land on its own.
        completionHandler()
        Task { @MainActor [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            if let paneId {
                self?.onFocusPane?(paneId)
            }
        }
    }
}

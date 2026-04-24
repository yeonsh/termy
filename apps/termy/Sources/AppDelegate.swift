// AppDelegate.swift
//
// Weekend 1 scope: app entry point. Creates MainWindowController on launch.
// No hooks, no daemon, no project switcher yet. Just terminal + tabs + splits.

import AppKit
import Foundation

/// File-backed logger — macOS 14+ routes NSLog to the unified log only, so
/// stderr-based tracing fails silently. TrayLog appends to /tmp/termy-debug.log.
enum TrayLog {
    static let path = "/tmp/termy-debug.log"

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

@main
enum TermyApp {
    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppAppearancePreference.applyStoredPreference()
        installMenuBar()

        // Start the hook daemon BEFORE creating any panes. Panes need it to
        // be listening so PtyExit events have somewhere to go.
        Task.detached {
            await HookDaemon.shared.start()
        }

        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)

        // WAITING notifications — route banner taps back through the window
        // controller so the clicked pane becomes focused.
        Notifier.shared.onFocusPane = { [weak controller] paneId in
            controller?.focusPane(byId: paneId)
        }
        Notifier.shared.start()

        // First-run: nudge the user to grant Full Disk Access so they don't
        // eat 5+ TCC prompts from child processes. Deferred a tick so the
        // main window is on screen behind the alert instead of after it.
        // Hook installer runs after FDA so the user isn't stacked with two
        // modal dialogs at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            FullDiskAccess.promptIfNeeded()
            HookInstaller.promptIfNeeded()
        }

        // Instantiating SPUStandardUpdaterController on first access starts
        // background update checks against SUFeedURL (see Info.plist).
        _ = Updater.shared
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush pending workspace autosave, then stop the hook daemon. Both
        // are async; block briefly so the process doesn't exit mid-write.
        // 2s total cap — atomic temp-rename means a lost flush at worst
        // regresses the layout by one debounce interval, not a corrupt file.
        let sem = DispatchSemaphore(value: 0)
        let autosaver = mainWindowController?.autosaver
        Task { @MainActor in
            if let autosaver {
                await autosaver.flushSync()
            }
            await HookDaemon.shared.stop()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu action forwarding

    private var activeController: MainWindowController? {
        if let winCtrl = NSApp.keyWindow?.windowController as? MainWindowController {
            return winCtrl
        }
        return mainWindowController
    }

    @IBAction func newPane(_ sender: Any?) {
        activeController?.newPane(sender)
    }

    @IBAction func splitColumn(_ sender: Any?) {
        activeController?.splitColumn(sender)
    }

    @IBAction func splitRow(_ sender: Any?) {
        activeController?.splitRow(sender)
    }

    @IBAction func closePane(_ sender: Any?) {
        activeController?.closePane(sender)
    }

    @IBAction func toggleMaximizePane(_ sender: Any?) {
        activeController?.toggleMaximizePane(sender)
    }

    @IBAction func focusPrevPane(_ sender: Any?) {
        activeController?.focusPrevPane(sender)
    }

    @IBAction func focusNextPane(_ sender: Any?) {
        activeController?.focusNextPane(sender)
    }

    @IBAction func focusPaneLeft(_ sender: Any?) {
        activeController?.focusPane(direction: .left)
    }

    @IBAction func focusPaneRight(_ sender: Any?) {
        activeController?.focusPane(direction: .right)
    }

    @IBAction func focusPaneUp(_ sender: Any?) {
        activeController?.focusPane(direction: .up)
    }

    @IBAction func focusPaneDown(_ sender: Any?) {
        activeController?.focusPane(direction: .down)
    }

    @IBAction func cycleFilterPrev(_ sender: Any?) {
        activeController?.cycleFilterPrev(sender)
    }

    @IBAction func cycleFilterNext(_ sender: Any?) {
        activeController?.cycleFilterNext(sender)
    }

    @IBAction func showProjectSwitcher(_ sender: Any?) {
        activeController?.showProjectSwitcher(sender)
    }

    @IBAction func showKeyboardShortcuts(_ sender: Any?) {
        activeController?.showKeyboardShortcuts(sender)
    }

    @IBAction func showFontSettings(_ sender: Any?) {
        activeController?.showFontSettings(sender)
    }

    @IBAction func selectFilter0(_ sender: Any?) { activeController?.selectAllFilter() }
    @IBAction func selectFilter1(_ sender: Any?) { activeController?.selectProjectFilter(at: 0) }
    @IBAction func selectFilter2(_ sender: Any?) { activeController?.selectProjectFilter(at: 1) }
    @IBAction func selectFilter3(_ sender: Any?) { activeController?.selectProjectFilter(at: 2) }
    @IBAction func selectFilter4(_ sender: Any?) { activeController?.selectProjectFilter(at: 3) }
    @IBAction func selectFilter5(_ sender: Any?) { activeController?.selectProjectFilter(at: 4) }
    @IBAction func selectFilter6(_ sender: Any?) { activeController?.selectProjectFilter(at: 5) }
    @IBAction func selectFilter7(_ sender: Any?) { activeController?.selectProjectFilter(at: 6) }
    @IBAction func selectFilter8(_ sender: Any?) { activeController?.selectProjectFilter(at: 7) }
    @IBAction func selectFilter9(_ sender: Any?) { activeController?.selectProjectFilter(at: 8) }

    @IBAction func cycleDashboardPrev(_ sender: Any?) {
        activeController?.cycleDashboardItem(delta: -1)
    }

    @IBAction func cycleDashboardNext(_ sender: Any?) {
        activeController?.cycleDashboardItem(delta: 1)
    }

    @IBAction func cycleWaitingPane(_ sender: Any?) {
        activeController?.cycleWaitingPane()
    }

    @IBAction func selectDashboard1(_ sender: Any?) { activeController?.selectDashboardItem(at: 0) }
    @IBAction func selectDashboard2(_ sender: Any?) { activeController?.selectDashboardItem(at: 1) }
    @IBAction func selectDashboard3(_ sender: Any?) { activeController?.selectDashboardItem(at: 2) }
    @IBAction func selectDashboard4(_ sender: Any?) { activeController?.selectDashboardItem(at: 3) }
    @IBAction func selectDashboard5(_ sender: Any?) { activeController?.selectDashboardItem(at: 4) }
    @IBAction func selectDashboard6(_ sender: Any?) { activeController?.selectDashboardItem(at: 5) }
    @IBAction func selectDashboard7(_ sender: Any?) { activeController?.selectDashboardItem(at: 6) }
    @IBAction func selectDashboard8(_ sender: Any?) { activeController?.selectDashboardItem(at: 7) }
    @IBAction func selectDashboard9(_ sender: Any?) { activeController?.selectDashboardItem(at: 8) }

    @IBAction func openFullDiskAccessPrompt(_ sender: Any?) {
        FullDiskAccess.showPromptFromMenu()
    }

    @IBAction func openNotificationSettings(_ sender: Any?) {
        Notifier.openNotificationSettings()
    }

    @IBAction func openHookInstallerPrompt(_ sender: Any?) {
        HookInstaller.showPromptFromMenu()
    }

    @IBAction func useLightAppearance(_ sender: Any?) {
        AppAppearancePreference.light.apply()
    }

    @IBAction func useDarkAppearance(_ sender: Any?) {
        AppAppearancePreference.dark.apply()
    }

    @IBAction func useSystemAppearance(_ sender: Any?) {
        AppAppearancePreference.system.apply()
    }

    @IBAction func cycleAppearance(_ sender: Any?) {
        let next = selectedAppearancePreference.next
        next.apply()
        AppearanceBanner.shared.show(next, over: NSApp.keyWindow ?? mainWindowController?.window)
    }

    private var selectedAppearancePreference: AppAppearancePreference {
        AppAppearancePreference.stored() ?? .system
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(useSystemAppearance(_:)):
            menuItem.state = selectedAppearancePreference == .system ? .on : .off
        case #selector(useLightAppearance(_:)):
            menuItem.state = selectedAppearancePreference == .light ? .on : .off
        case #selector(useDarkAppearance(_:)):
            menuItem.state = selectedAppearancePreference == .dark ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: - Menu bar

    private func installMenuBar() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        mainMenu.addItem(makeAppMenu())
        mainMenu.addItem(makeFileMenu())
        mainMenu.addItem(makeEditMenu())
        mainMenu.addItem(makeViewMenu())
        mainMenu.addItem(makeWindowMenu())
        mainMenu.addItem(makeHelpMenu())
    }

    private func makeAppMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "termy")
        menu.addItem(
            withTitle: "About termy",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        let update = menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(Updater.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        update.target = Updater.shared
        menu.addItem(.separator())
        let settings = menu.addItem(
            withTitle: "Settings…",
            action: #selector(AppDelegate.showFontSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        let fda = menu.addItem(
            withTitle: "Grant Full Disk Access…",
            action: #selector(AppDelegate.openFullDiskAccessPrompt(_:)),
            keyEquivalent: ""
        )
        fda.target = self
        let notif = menu.addItem(
            withTitle: "Notification Settings…",
            action: #selector(AppDelegate.openNotificationSettings(_:)),
            keyEquivalent: ""
        )
        notif.target = self
        let hookInstaller = menu.addItem(
            withTitle: "Claude Code Hooks…",
            action: #selector(AppDelegate.openHookInstallerPrompt(_:)),
            keyEquivalent: ""
        )
        hookInstaller.target = self
        menu.addItem(.separator())
        let servicesItem = menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide termy",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit termy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    private func makeFileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        let newPane = menu.addItem(
            withTitle: "New Pane",
            action: #selector(AppDelegate.newPane(_:)),
            keyEquivalent: "n"
        )
        newPane.target = self
        newPane.keyEquivalentModifierMask = [.command]

        let splitRow = menu.addItem(
            withTitle: "Split Row",
            action: #selector(AppDelegate.splitRow(_:)),
            keyEquivalent: "d"
        )
        splitRow.target = self
        splitRow.keyEquivalentModifierMask = [.command]

        let splitCol = menu.addItem(
            withTitle: "Split Column",
            action: #selector(AppDelegate.splitColumn(_:)),
            keyEquivalent: "D"
        )
        splitCol.target = self
        splitCol.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        let closePane = menu.addItem(
            withTitle: "Close Pane",
            action: #selector(AppDelegate.closePane(_:)),
            keyEquivalent: "w"
        )
        closePane.target = self
        closePane.keyEquivalentModifierMask = [.command]

        let closeWindow = menu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "W"
        )
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        item.submenu = menu
        return item
    }

    private func makeEditMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        item.submenu = menu
        return item
    }

    private func makeViewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        let appearance = menu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "")
        appearance.submenu = makeAppearanceMenu()

        menu.addItem(.separator())

        let toggle = menu.addItem(
            withTitle: "Maximize Pane",
            action: #selector(AppDelegate.toggleMaximizePane(_:)),
            keyEquivalent: "\r"
        )
        toggle.target = self
        toggle.keyEquivalentModifierMask = [.command]

        menu.addItem(.separator())

        let prevPane = menu.addItem(
            withTitle: "Previous Pane",
            action: #selector(AppDelegate.focusPrevPane(_:)),
            keyEquivalent: "["
        )
        prevPane.target = self
        prevPane.keyEquivalentModifierMask = [.command]

        let nextPane = menu.addItem(
            withTitle: "Next Pane",
            action: #selector(AppDelegate.focusNextPane(_:)),
            keyEquivalent: "]"
        )
        nextPane.target = self
        nextPane.keyEquivalentModifierMask = [.command]

        menu.addItem(.separator())

        let paneLeft = menu.addItem(
            withTitle: "Focus Pane Left",
            action: #selector(AppDelegate.focusPaneLeft(_:)),
            keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        )
        paneLeft.target = self
        paneLeft.keyEquivalentModifierMask = [.command, .option]

        let paneRight = menu.addItem(
            withTitle: "Focus Pane Right",
            action: #selector(AppDelegate.focusPaneRight(_:)),
            keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        )
        paneRight.target = self
        paneRight.keyEquivalentModifierMask = [.command, .option]

        let paneUp = menu.addItem(
            withTitle: "Focus Pane Up",
            action: #selector(AppDelegate.focusPaneUp(_:)),
            keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        )
        paneUp.target = self
        paneUp.keyEquivalentModifierMask = [.command, .option]

        let paneDown = menu.addItem(
            withTitle: "Focus Pane Down",
            action: #selector(AppDelegate.focusPaneDown(_:)),
            keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        )
        paneDown.target = self
        paneDown.keyEquivalentModifierMask = [.command, .option]

        item.submenu = menu
        return item
    }

    private func makeAppearanceMenu() -> NSMenu {
        let menu = NSMenu(title: "Appearance")

        // ⌘T is the macOS-standard "Show Tab Bar / Show Fonts" chord, so
        // theme cycling lives on ⌘⇧T to avoid the collision.
        let cycle = menu.addItem(
            withTitle: "Cycle Appearance",
            action: #selector(AppDelegate.cycleAppearance(_:)),
            keyEquivalent: "T"
        )
        cycle.target = self
        cycle.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        let system = menu.addItem(
            withTitle: "Match System",
            action: #selector(AppDelegate.useSystemAppearance(_:)),
            keyEquivalent: ""
        )
        system.target = self

        menu.addItem(.separator())

        let light = menu.addItem(
            withTitle: "Light",
            action: #selector(AppDelegate.useLightAppearance(_:)),
            keyEquivalent: ""
        )
        light.target = self

        let dark = menu.addItem(
            withTitle: "Dark",
            action: #selector(AppDelegate.useDarkAppearance(_:)),
            keyEquivalent: ""
        )
        dark.target = self

        return menu
    }

    private func makeWindowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )

        menu.addItem(.separator())

        // ⌘K — headline project-restore chord. Top of the Window menu's
        // non-system section so the shortcut is discoverable without hunting
        // through help docs.
        let switchProject = menu.addItem(
            withTitle: "Switch Project…",
            action: #selector(AppDelegate.showProjectSwitcher(_:)),
            keyEquivalent: "k"
        )
        switchProject.target = self
        switchProject.keyEquivalentModifierMask = [.command]

        menu.addItem(.separator())

        // Project filter — inherits the old tab-cycling shortcut.
        let prevFilter = menu.addItem(
            withTitle: "Previous Filter",
            action: #selector(AppDelegate.cycleFilterPrev(_:)),
            keyEquivalent: "["
        )
        prevFilter.target = self
        prevFilter.keyEquivalentModifierMask = [.command, .shift]

        let nextFilter = menu.addItem(
            withTitle: "Next Filter",
            action: #selector(AppDelegate.cycleFilterNext(_:)),
            keyEquivalent: "]"
        )
        nextFilter.target = self
        nextFilter.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        // Direct filter jumps: ⌘0 is ALL when available; ⌘1..⌘9 start at
        // the first project segment.
        let showAll = menu.addItem(
            withTitle: "Show All Panes",
            action: #selector(AppDelegate.selectFilter0(_:)),
            keyEquivalent: "0"
        )
        showAll.target = self
        showAll.keyEquivalentModifierMask = [.command]

        let selectors: [Selector] = [
            #selector(AppDelegate.selectFilter1(_:)),
            #selector(AppDelegate.selectFilter2(_:)),
            #selector(AppDelegate.selectFilter3(_:)),
            #selector(AppDelegate.selectFilter4(_:)),
            #selector(AppDelegate.selectFilter5(_:)),
            #selector(AppDelegate.selectFilter6(_:)),
            #selector(AppDelegate.selectFilter7(_:)),
            #selector(AppDelegate.selectFilter8(_:)),
            #selector(AppDelegate.selectFilter9(_:))
        ]
        for (i, sel) in selectors.enumerated() {
            let title = "Project Filter \(i + 1)"
            let entry = menu.addItem(withTitle: title, action: sel, keyEquivalent: "\(i + 1)")
            entry.target = self
            entry.keyEquivalentModifierMask = [.command]
        }

        menu.addItem(.separator())

        // Dashboard navigation — one modifier layer above the filter shortcuts
        // (⌘[ pane, ⌘⇧[ filter, ⌘⌥[ dashboard). Independent of layout order;
        // follows the priority sort (WAITING first, ERRORED, …).
        let prevDash = menu.addItem(
            withTitle: "Previous Dashboard Item",
            action: #selector(AppDelegate.cycleDashboardPrev(_:)),
            keyEquivalent: "["
        )
        prevDash.target = self
        prevDash.keyEquivalentModifierMask = [.command, .option]

        let nextDash = menu.addItem(
            withTitle: "Next Dashboard Item",
            action: #selector(AppDelegate.cycleDashboardNext(_:)),
            keyEquivalent: "]"
        )
        nextDash.target = self
        nextDash.keyEquivalentModifierMask = [.command, .option]

        // ⌘G — jump to the next WAITING pane. The attention-routing shortcut:
        // when multiple agents are blocked waiting for input, one tap cycles
        // through them without the user having to eyeball the bar.
        let nextWait = menu.addItem(
            withTitle: "Next Waiting Pane",
            action: #selector(AppDelegate.cycleWaitingPane(_:)),
            keyEquivalent: "g"
        )
        nextWait.target = self
        nextWait.keyEquivalentModifierMask = [.command]

        // Direct dashboard jumps ⌘⌥1..⌘⌥9 — index into the priority-sorted
        // dashboard items, so ⌘⌥1 is always the highest-priority pane.
        let dashSelectors: [Selector] = [
            #selector(AppDelegate.selectDashboard1(_:)),
            #selector(AppDelegate.selectDashboard2(_:)),
            #selector(AppDelegate.selectDashboard3(_:)),
            #selector(AppDelegate.selectDashboard4(_:)),
            #selector(AppDelegate.selectDashboard5(_:)),
            #selector(AppDelegate.selectDashboard6(_:)),
            #selector(AppDelegate.selectDashboard7(_:)),
            #selector(AppDelegate.selectDashboard8(_:)),
            #selector(AppDelegate.selectDashboard9(_:))
        ]
        for (i, sel) in dashSelectors.enumerated() {
            let title = "Dashboard Item \(i + 1)"
            let entry = menu.addItem(withTitle: title, action: sel, keyEquivalent: "\(i + 1)")
            entry.target = self
            entry.keyEquivalentModifierMask = [.command, .option]
        }

        NSApp.windowsMenu = menu
        item.submenu = menu
        return item
    }

    private func makeHelpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        let shortcuts = menu.addItem(
            withTitle: "Keyboard Shortcuts",
            action: #selector(AppDelegate.showKeyboardShortcuts(_:)),
            keyEquivalent: "/"
        )
        shortcuts.target = self
        shortcuts.keyEquivalentModifierMask = [.command]
        NSApp.helpMenu = menu
        item.submenu = menu
        return item
    }
}

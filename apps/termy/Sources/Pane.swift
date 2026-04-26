// Pane.swift
//
// Weekend 3+ layout: one pane is a header strip (project / branch) stacked
// on top of the SwiftTerm terminal view. Same project → same accent color
// across every pane in the window, so at a glance the user can tell which
// panes belong together.
//
//   ┌─────────────────────────────────────┐
//   │  api  /  main                       │  ← PaneHeaderView, 26pt, tinted
//   ├─────────────────────────────────────┤
//   │                                     │
//   │  $ claude                           │
//   │  > Hello!                           │  ← LocalProcessTerminalView
//   │                                     │
//   └─────────────────────────────────────┘
//
// The header auto-updates when SwiftTerm reports a cwd change via OSC 7
// (the shell's PROMPT_COMMAND emits `printf '\e]7;file://…\a'` on each
// prompt), so `cd ~/code/api` in the shell re-runs git-branch detection
// and refreshes the label.

import AppKit
import Foundation
import SwiftTerm

final class Pane: NSView, LocalProcessTerminalViewDelegate {
    let paneId: String
    /// Live project identifier — mutable so `cd` into another project folder
    /// reassigns this pane to the new project. Workspace listens via
    /// `onProjectChanged` to rebuild the toolbar filter segments.
    ///
    /// Note: the pane's `$TERMY_PROJECT_ID` env var stays at its original
    /// value (we can't retroactively rewrite the child shell's environment).
    /// The workspace's filter uses this live projectId; the dashboard
    /// snapshots still carry the original env value. v1.1 could reconcile
    /// them via Workspace-sourced project lookup.
    private(set) var projectId: String
    let initialCwd: String
    let terminal: TermyTerminalView

    /// Fires (on the main actor) when `cd` causes the pane to belong to a
    /// different project than it did a moment ago.
    var onProjectChanged: (() -> Void)?

    /// Fires (on the main actor) every time the derived header label (project
    /// folder + git branch) is recomputed — i.e. on pane init and on every
    /// OSC 7 `cd`. Mission control uses this to render chip labels that match
    /// the pane header instead of a meaningless UUID.
    var onHeaderChanged: ((_ project: String, _ branch: String?) -> Void)?

    /// Fires (on the main actor) when the pane's shell process exits — typed
    /// `exit`, hit Ctrl-D, or crashed. Workspace uses this to auto-close the
    /// pane so a dead pty doesn't sit around as a blank rectangle.
    var onShellExited: ((_ exitCode: Int32) -> Void)?

    /// Fires on any left-mouse-down inside the terminal (or header). Workspace
    /// wires this to `focus(pane:)` so clicking a pane makes it the focused
    /// one. Previously this used an `NSClickGestureRecognizer` on Pane, but
    /// the recognizer intercepted the mouseDown after it reached our
    /// NSEvent monitor, starving SwiftTerm's own `mouseDown` of the event —
    /// which broke double-click word selection and triple-click row
    /// selection because SwiftTerm's multi-click code lives in the method
    /// that never ran.
    var onPaneClicked: (() -> Void)?

    private let headerView: PaneHeaderView
    private let headerHeight: CGFloat = 26
    private var isShowingActiveAppearance = false

    /// Tracks the shell's live cwd so splits and header updates stay accurate.
    private(set) var currentCwd: String

    /// Watches `.git/HEAD` so `git checkout` / `git switch` (which don't
    /// change the cwd and therefore don't fire OSC 7) refresh the pane
    /// header label. nil when cwd isn't inside a git repo.
    private var headWatcher: GitHeadWatcher?

    /// `nonisolated(unsafe)` because the deinit is nonisolated and Swift 6
    /// strict concurrency would otherwise refuse to read this MainActor-bound
    /// property when releasing the observer. Pane only mutates this from
    /// MainActor (init), so the unsafety is contained.
    nonisolated(unsafe) private var fontPreferenceObserver: NSObjectProtocol?

    init(
        projectId: String,
        cwd: String? = nil
    ) {
        self.paneId = UUID().uuidString
        self.projectId = projectId
        self.initialCwd = Pane.resolveCwd(cwd)
        self.currentCwd = self.initialCwd
        self.terminal = TermyTerminalView(frame: .zero)
        self.headerView = PaneHeaderView()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        terminal.font = TerminalFontPreference.shared.resolvedFont()

        // Drive the hover-underline UX for URLs. `.implicit` picks up
        // plain-text URLs in addition to OSC 8 hyperlinks;
        // `.hoverWithModifier` underlines them only when CMD is held.
        // CMD+click activation itself is handled in `TermyTerminalView`.
        terminal.linkReporting = .implicit
        terminal.linkHighlightMode = .hoverWithModifier

        setupHeader()
        setupTerminal()
        terminal.processDelegate = self
        terminal.onClickInBounds = { [weak self] in
            self?.onPaneClicked?()
        }
        applyTheme()
        applyActiveAppearance(false)

        refreshHeader()   // initial project / branch
        installHeadWatcher(for: self.currentCwd)
        observeFontPreference()
        startShell()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit {
        if let token = fontPreferenceObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func observeFontPreference() {
        fontPreferenceObserver = NotificationCenter.default.addObserver(
            forName: TerminalFontPreference.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.terminal.font = TerminalFontPreference.shared.resolvedFont()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
        refreshHeaderAppearance()
        applyActiveAppearance(isShowingActiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
        refreshHeaderAppearance()
        applyActiveAppearance(isShowingActiveAppearance)
    }

    private static func resolveCwd(_ requested: String?) -> String {
        if let r = requested, !r.isEmpty, r != "/" { return r }
        let appCwd = FileManager.default.currentDirectoryPath
        if !appCwd.isEmpty, appCwd != "/" { return appCwd }
        return NSHomeDirectory()
    }

    // MARK: - Layout

    private func setupHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: headerHeight)
        ])
    }

    private func setupTerminal() {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        // Breathing room between the terminal glyphs and the pane's rounded
        // border. SwiftTerm draws at bounds origin with no built-in inset, so
        // we inset the terminal view itself — Pane's background matches the
        // terminal's `nativeBackgroundColor`, so the gap reads as padding.
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 4),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
        hideTerminalScroller()
    }

    /// SwiftTerm adds a private `NSScroller` subview anchored to the terminal's
    /// trailing edge. Even in `.overlay` style it can draw a faint track that
    /// reads as a vertical line on the right side of the pane — we're not
    /// using keyboard-driven scrolling, so hide it outright.
    private func hideTerminalScroller() {
        for sub in terminal.subviews {
            if sub is NSScroller {
                sub.isHidden = true
            }
        }
    }

    // MARK: - Shell

    private func startShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env: [String: String] = ProcessInfo.processInfo.environment
        env["TERMY_PANE_ID"] = paneId
        env["TERMY_PROJECT_ID"] = projectId
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"

        FileManager.default.changeCurrentDirectoryPath(initialCwd)
        let envArray = env.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: shell,
            args: ["-l"],
            environment: envArray,
            execName: nil
        )

        // Register with the foreground-process watcher so synthetic
        // SessionStart / SessionEnd events fire when the user runs
        // `claude` / `codex` and exits back to the shell. SwiftTerm
        // populates `process.shellPid` / `process.childfd` synchronously
        // inside startProcess, so reading them right after is safe.
        let masterFd = terminal.process.childfd
        let shellPid = terminal.process.shellPid
        let paneId = self.paneId
        let projectId = self.projectId
        if masterFd >= 0, shellPid > 0 {
            Task.detached {
                await ForegroundProcessWatcher.shared.register(
                    paneId: paneId,
                    masterFd: masterFd,
                    shellPid: shellPid,
                    projectId: projectId
                )
            }
        }
    }

    func focusTerminal() {
        window?.makeFirstResponder(terminal)
    }

    func applyActiveAppearance(_ active: Bool) {
        isShowingActiveAppearance = active
        let theme = PaneStyling.theme(for: effectiveAppearance)
        let accent = PaneStyling.accentColor(for: projectId, appearance: effectiveAppearance)
        let focusAppearance = PaneStyling.focusAppearance(active: active, accent: accent, theme: theme)
        // Route the focus-state caret color through TermyTerminalView's pin
        // instead of mutating `caretColor` directly: Termy needs to swap the
        // caret to `.clear` while a Korean/CJK IME composition is in flight
        // (otherwise the cursor block bleeds through behind the marked-text
        // overlay as a faint gray box), and the pin lets it remember what
        // color to restore once composition ends.
        terminal.pinnedCaretColor = focusAppearance.caretColor
        // Initial cursor-style preference. TUIs (claude code, vim, etc.)
        // legitimately drive cursor style via DECSCUSR (`\e[N q`); we set
        // ours on focus changes and let the running app override mid-session
        // — that's the contract terminals honor.
        terminal.terminal.setCursorStyle(active ? .blinkBar : .steadyBar)
        layer?.opacity = focusAppearance.paneOpacity
        layer?.borderWidth = focusAppearance.borderWidth
        layer?.borderColor = focusAppearance.borderColor.cgColor
    }

    // MARK: - Header updates

    private func installHeadWatcher(for cwd: String) {
        if headWatcher == nil {
            headWatcher = GitHeadWatcher { [weak self] in
                self?.refreshHeader()
            }
        }
        headWatcher?.watch(cwd: cwd)
    }

    private func refreshHeader() {
        let cwd = currentCwd
        Task.detached(priority: .userInitiated) { [weak self] in
            let root = GitBranch.workTreeRoot(for: cwd) ?? cwd
            let projectLabel = (root as NSString).lastPathComponent
            let branch = GitBranch.branch(for: cwd)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.headerView.configure(
                    project: projectLabel,
                    branch: branch,
                    appearance: self.effectiveAppearance
                )
                // Detect project drift — user cd'd into a different
                // project. Let Workspace rebuild the filter segments.
                if self.projectId != projectLabel {
                    self.projectId = projectLabel
                    self.onProjectChanged?()
                }
                self.onHeaderChanged?(projectLabel, branch)
            }
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // v1.1: propagate to tab label when informative.
    }

    /// OSC 7 is how modern shells (zsh's default, bash with termsupport,
    /// fish, etc.) tell the terminal about the current working directory
    /// on every prompt. Any `cd` inside the pane fires this → we refresh
    /// the header to reflect the new folder + branch.
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let newCwd = directory, !newCwd.isEmpty else { return }
        // OSC 7 sends a file:// URL (e.g. "file:///Users/ysh/proj");
        // convert it to a plain filesystem path before use.
        let resolved: String
        if let url = URL(string: newCwd), url.scheme == "file" {
            resolved = url.path
        } else {
            resolved = (newCwd as NSString).expandingTildeInPath
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard resolved != self.currentCwd else { return }
            self.currentCwd = resolved
            self.refreshHeader()
            // `cd` may have crossed repo boundaries — re-arm on the new
            // HEAD so branch updates keep flowing.
            self.installHeadWatcher(for: resolved)
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let code = exitCode ?? -1
        let paneId = self.paneId
        Task { @MainActor [weak self] in
            guard let self else { return }
            let projectId = self.projectId
            Task.detached {
                await HookDaemon.shared.postPtyExit(
                    paneId: paneId,
                    projectId: projectId,
                    exitCode: code
                )
                await ForegroundProcessWatcher.shared.unregister(paneId: paneId)
            }
            self.headWatcher?.stop()
            self.onShellExited?(code)
        }
    }

    private func applyTheme() {
        let theme = PaneStyling.theme(for: effectiveAppearance)
        layer?.backgroundColor = theme.paneBackgroundColor.cgColor
        terminal.nativeBackgroundColor = theme.paneBackgroundColor
        terminal.nativeForegroundColor = theme.terminalForegroundColor
        terminal.selectedTextBackgroundColor = theme.terminalSelectionBackgroundColor
        terminal.installColors(theme.terminalANSIColors.map { $0.termyTerminalColor() })
    }

    private func refreshHeaderAppearance() {
        headerView.reapplyTheme(appearance: effectiveAppearance)
    }
}

// MARK: - PaneHeaderView

final class PaneHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    private var project: String = ""
    private var branch: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        // Subtle bottom border = accent at higher opacity so the header
        // reads as a proper header strip, not a floating patch of color.
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1)
        ])

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = TermyTypography.medium()
        label.textColor = .labelColor
        label.allowsDefaultTighteningForTruncation = true
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(project: String, branch: String?, appearance: NSAppearance?) {
        self.project = project
        self.branch = branch
        applyTheme(appearance: appearance)
        rebuildLabel()
    }

    func reapplyTheme(appearance: NSAppearance?) {
        applyTheme(appearance: appearance)
    }

    private func applyTheme(appearance: NSAppearance?) {
        let theme = PaneStyling.theme(for: appearance)
        let accent = PaneStyling.accentColor(for: project, appearance: appearance)
        layer?.backgroundColor = accent.withAlphaComponent(theme.headerTintAlpha).cgColor
    }

    private func rebuildLabel() {
        let attr = NSMutableAttributedString()
        let projectAttrs: [NSAttributedString.Key: Any] = [
            .font: TermyTypography.semibold(),
            .foregroundColor: NSColor.labelColor
        ]
        attr.append(NSAttributedString(string: project, attributes: projectAttrs))

        if let branch, !branch.isEmpty {
            let slashAttrs: [NSAttributedString.Key: Any] = [
                .font: TermyTypography.regular(),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let branchAttrs: [NSAttributedString.Key: Any] = [
                .font: TermyTypography.regular(),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            attr.append(NSAttributedString(string: "  /  ", attributes: slashAttrs))
            attr.append(NSAttributedString(string: branch, attributes: branchAttrs))
        }
        label.attributedStringValue = attr
    }
}

private extension NSColor {
    func termyTerminalColor() -> Color {
        let color = usingColorSpace(.deviceRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Color(
            red: UInt16(red * 65535.0),
            green: UInt16(green * 65535.0),
            blue: UInt16(blue * 65535.0)
        )
    }
}

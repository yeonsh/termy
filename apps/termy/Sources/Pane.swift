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
//
// hc pane(`launch: .hc`): 셸은 herdr-core 안에서 돌아 termy가 꺼져도 살아 있고, 이 pane은 local PTY 대신
// `HcPaneBackend`로 그 terminal에 붙은 viewer다. foreground·cwd는 hc 이벤트로 받고, 셸 종료는 local과 같은
// 경로(PtyExit → pane 닫기)를 탄다. 원격 pane(machine 있음)은 만들 때 받은 project로 고정이고 git을 보지 않는다.

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

    /// local PTY 셸인지, herdr-core terminal인지(원격이면 machine). pane이 닫힐 때까지 바뀌지 않는다.
    let launch: PaneLaunch
    /// 만들 때의 project 키(local은 worktree root의 canonical path, 원격은 `<machine>:<folder>`).
    /// hc terminal의 `termy.project` label이 된다.
    let projectKey: String
    /// hc pane의 backend. local pane은 nil.
    private(set) var hcBackend: HcPaneBackend?

    /// 원격 머신의 hc pane. project는 만들 때 받은 값으로 고정이고 git·drift를 보지 않는다.
    var isRemote: Bool {
        if case .hc(machine: .some) = launch { return true }
        return false
    }

    /// 이 pane이 속한 ⌘K 기록의 키(`WorkspaceRecord.canonicalPath`). local은 지금 cwd의 worktree root라 `cd`를
    /// 따라가고, 원격은 만들 때 정한 project 키(`<machine>:<folder>`)다.
    var workspaceRecordKey: String {
        isRemote ? projectKey : ProjectIdentity.canonicalPath(for: currentCwd)
    }

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

    /// Pending agent-resume command for a pane restored after an update
    /// relaunch. nil once typed (or when there is none).
    private var startupInputScheduler: StartupInputScheduler?
    /// hc pane이 처음 붙으면 입력할 agent resume 명령.
    private var pendingHcStartupInput: String?

    /// hc 연결 상태(연결 중·셸 재시작 중·unavailable)를 terminal 위에 보여 준다. hc pane에만 있다.
    private var hcStatusOverlay: PaneStatusOverlay?
    /// 마지막으로 hc에 알린 pane 포커스. relayout마다 같은 값을 다시 보내지 않는다.
    private var hcFocusSent: Bool?
    /// 마지막으로 display facts를 맞춘 테마. 다크/라이트가 실제로 바뀔 때만 FACTS를 보낸다.
    private var factsThemeVariant: TermyThemeVariant?
    /// ForegroundProcessWatcher·HookDaemon 호출의 꼬리. 보낸 순서대로 처리하게 이어 붙인다.
    private var watcherCalls: Task<Void, Never>?
    /// 복원한 hc pane의 hook 세부 정보. HookDaemon에 되살리고, 그 snapshot이 MissionControlModel에 닿기 전에
    /// 저장이 돌아도 잃지 않게 들고 있는다.
    private(set) var restoredHookDetails: PaneHookDetails?

    init(
        projectId: String,
        cwd: String? = nil,
        startupInput: String? = nil,
        paneId: String = UUID().uuidString,
        launch: PaneLaunch = .local,
        projectKey: String? = nil
    ) {
        self.paneId = paneId
        self.projectId = projectId
        self.launch = launch
        if case .hc(machine: let machine?) = launch {
            // 원격 폴더는 이 Mac에 없으므로 resolveCwd(로컬 존재 확인)를 거치지 않는다.
            // 원격 project를 여는 쪽은 늘 폴더를 준다.
            self.initialCwd = cwd ?? "~"
            self.projectKey = projectKey ?? "\(machine):\(self.initialCwd)"
        } else {
            self.initialCwd = Pane.resolveCwd(cwd)
            self.projectKey = projectKey ?? ProjectIdentity.canonicalPath(for: self.initialCwd)
        }
        self.currentCwd = self.initialCwd
        self.terminal = TermyTerminalView(frame: .zero)
        self.terminal.paneId = self.paneId
        self.headerView = PaneHeaderView()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        terminal.setTerminalFont(TerminalFontPreference.shared.resolvedFont())

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
        terminal.previewBaseDirectories = { [weak self] in
            self?.previewBaseDirectories() ?? []
        }
        terminal.onOpenPreviewFile = { url in
            _ = PreviewManager.shared.open(url)
        }
        applyTheme()
        applyActiveAppearance(false)

        refreshHeader()   // initial project / branch
        if !isRemote {
            installHeadWatcher(for: self.currentCwd)
        }
        observeFontPreference()
        switch launch {
        case .local:
            startShell()
            // 업데이트 재시작 뒤 agent resume.
            if let startupInput {
                scheduleStartupInput(startupInput)
            }
        case .hc(let machine):
            // hc pane은 업데이트로 죽지 않으므로 hc 기록에는 resume이 없다. local 기록을 지금 설정에 따라 hc로 연
            // pane에만 온다: 새 terminal에 붙은 뒤 입력한다(붙기 전의 입력은 보낼 곳이 없어 버려진다).
            pendingHcStartupInput = startupInput
            startHc(machine: machine)
        }
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
                self?.terminal.setTerminalFont(TerminalFontPreference.shared.resolvedFont())
                self?.hcBackend?.sendDisplayFacts()   // 셀 크기가 바뀌었다
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

    /// A requested directory that no longer exists falls back to `$HOME`,
    /// not the app's cwd: `startShell` changes the process-wide cwd, so
    /// that would be whatever directory the previous pane started in.
    private static func resolveCwd(_ requested: String?) -> String {
        if let r = requested, !r.isEmpty, r != "/" {
            return FileManager.default.directoryExists(atPath: r) ? r : NSHomeDirectory()
        }
        let appCwd = FileManager.default.currentDirectoryPath
        if !appCwd.isEmpty, appCwd != "/" { return appCwd }
        return NSHomeDirectory()
    }

    // MARK: - Layout

    /// 헤더 오른쪽 끝 herdr 표시의 tooltip. local pane이면 nil(표시하지 않는다).
    nonisolated static func herdrMarkToolTip(for launch: PaneLaunch) -> String? {
        switch launch {
        case .local: return nil
        case .hc(let machine?): return "Running in herdr-core on \(machine)"
        case .hc(nil): return "Running in herdr-core"
        }
    }

    private func setupHeader() {
        headerView.setHerdrMark(toolTip: Self.herdrMarkToolTip(for: launch))
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

    /// Variables that describe the *launching* agent session (termy started
    /// from inside Claude Code / Codex / opencode), not the user's
    /// configuration. Left in place, a `claude` started in a pane runs as a
    /// child session and writes no transcript, so `--resume` fails. A blanket
    /// `CLAUDE_CODE_*` strip would also drop settings users set on purpose
    /// (e.g. `CLAUDE_CODE_NO_FLICKER`). opencode sets its markers on shell
    /// tool children (`packages/core/src/shell.ts`); keep values the user
    /// configured themselves, such as `OPENCODE_CONFIG_DIR`.
    static let agentSessionMarkerEnvKeys: [String] = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_EXECPATH", "CLAUDE_PID",
        "CLAUDE_EFFORT", "CLAUDE_PLUGIN_DATA", "AI_AGENT",
        "CODEX_COMPANION_SESSION_ID", "CODEX_SANDBOX",
        "CODEX_SANDBOX_NETWORK_DISABLED",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CODEX_THREAD_ID",
        "ANTIGRAVITY_AGENT", "ANTIGRAVITY_TRAJECTORY_ID",
        "ANTIGRAVITY_CONVERSATION_ID", "ANTIGRAVITY_AGENTAPI_EXE",
        "ANTIGRAVITY_LS_VERSION", "ANTIGRAVITY_PROJECT_ID",
        "ANTIGRAVITY_APP_DATA_DIR", "ANTIGRAVITY_SOURCE_METADATA",
        "ANTIGRAVITY_LS_ADDRESS", "ANTIGRAVITY_CSRF_TOKEN",
        "OPENCODE_TERMINAL", "OPENCODE_SESSION_ID",
    ]

    /// Environment handed to a pane's login shell.
    static func shellEnvironment(
        base: [String: String], paneId: String, projectId: String
    ) -> [String: String] {
        var env = base
        for key in agentSessionMarkerEnvKeys { env.removeValue(forKey: key) }
        // Claude Code sets GIT_EDITOR=true for its children; leaked, it makes
        // `git commit` without -m abort. A user's own value survives.
        if env["GIT_EDITOR"] == "true" { env.removeValue(forKey: "GIT_EDITOR") }
        env["TERMY_PANE_ID"] = paneId
        env["TERMY_PROJECT_ID"] = projectId
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        return env
    }

    private func startShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = Pane.shellEnvironment(
            base: ProcessInfo.processInfo.environment,
            paneId: paneId, projectId: projectId)

        FileManager.default.changeCurrentDirectoryPath(initialCwd)
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // Claude는 OSC 7501 질의에 답하는 터미널에만 상태를 보고한다. Esc 취소는 Stop hook이 없어서 이 보고로만 안다.
        // hc pane(startHc)은 core가 답하고 events로 받으므로 local 경로에서만 켠다.
        let statusPaneId = paneId
        let statusProjectId = projectId
        terminal.enableProgramStatusReports { [weak self] status in
            self?.enqueueWatcherCall {
                await HookDaemon.shared.applyProgramStatus(paneId: statusPaneId, projectId: statusProjectId, status: status)
            }
        }

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

    /// hc pane: 셸은 herdr-core 안에서 돌고, backend가 자기 terminal을 label로 찾아 붙거나 새로 띄워 붙는다.
    /// foreground는 PTY 대신 hc 이벤트로 받아 ForegroundProcessWatcher에 넣는다(synthetic Session 이벤트와
    /// Codex reconcile은 local과 같은 tick이 만든다). 7501 status는 상태 머신 쪽에서 연결한다.
    private func startHc(machine: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let backend = HcPaneBackend(
            paneId: paneId, projectKey: projectKey, projectId: projectId,
            launch: HcLaunch(machine: machine, cwd: initialCwd, shell: shell),
            view: terminal
        )
        hcBackend = backend
        installHcStatusOverlay()
        backend.onExit = { [weak self] code in self?.shellExited(exitCode: code) }
        backend.onForeground = { [weak self] foreground in self?.hcForegroundChanged(foreground) }
        backend.onConnectionState = { [weak self] state in
            guard let self else { return }
            self.showHcConnectionState(state)
            if case .attached = state, let input = self.pendingHcStartupInput {
                self.pendingHcStartupInput = nil
                self.scheduleStartupInput(input)
            }
        }
        // 7501 status는 watcher 호출과 같은 순서 큐로 보낸다(working → idle이 뒤집히면 안 된다).
        backend.onStatus = { [weak self] status in
            guard let self else { return }
            let paneId = self.paneId
            let projectId = self.projectId
            self.enqueueWatcherCall {
                await HookDaemon.shared.applyProgramStatus(paneId: paneId, projectId: projectId, status: status)
            }
        }
        let paneId = self.paneId
        let projectId = self.projectId
        enqueueWatcherCall {
            await ForegroundProcessWatcher.shared.registerPushed(paneId: paneId, projectId: projectId)
        }
        backend.start()
        // 붙어 있지 않을 때(연결 중·셸 재시작 중·unavailable) 친 키는 버린다. 상태 라벨이 이유를 보여 준다.
        let forward = terminal.remoteInput
        terminal.remoteInput = { [weak backend] bytes in
            guard backend?.connectionState == .attached else { return }
            forward?(bytes)
        }
    }

    /// session.json에 남긴 hook 세부 정보를 HookDaemon에 되살린다. watcher 큐에 넣어 attach 뒤에 오는
    /// status·foreground보다 먼저 닿게 한다. local pane은 아무것도 하지 않는다.
    func restoreHookDetails(_ details: PaneHookDetails) {
        guard hcBackend != nil else { return }
        restoredHookDetails = details
        let paneId = self.paneId
        let projectId = self.projectId
        enqueueWatcherCall {
            await HookDaemon.shared.restoreDetails(paneId: paneId, projectId: projectId, details: details)
        }
    }

    /// 사용자가 이 hc pane이나 그 창을 닫았다: terminal을 끝낸다. kill은 onExit을 부르지 않아 셸 종료
    /// 경로(shellExited)를 타지 않으므로 foreground 감시 항목도 여기서 뺀다. local pane은 아무것도 하지 않는다.
    func killHcTerminal() {
        guard let hcBackend else { return }
        hcBackend.kill()
        unregisterForegroundWatch()
    }

    /// 앱 종료 중에 정리된다: terminal은 남기고(다음 실행 때 다시 붙는다) viewer만 떠난다.
    func detachHcTerminal() {
        guard let hcBackend else { return }
        hcBackend.detach()
        unregisterForegroundWatch()
    }

    private func unregisterForegroundWatch() {
        let paneId = self.paneId
        enqueueWatcherCall {
            await ForegroundProcessWatcher.shared.unregister(paneId: paneId)
        }
    }

    /// hc `foreground` 이벤트(이름·argv·cwd). cwd는 OSC 7과 같은 갱신 경로를 탄다: 다시 attach한 first paint에는
    /// OSC 7이 없을 수 있다.
    private func hcForegroundChanged(_ foreground: HcForeground?) {
        let agent = foreground.flatMap {
            ForegroundProcessWatcher.classifyAgent(processName: $0.name ?? "", arguments: $0.argv ?? [])
        }
        let paneId = self.paneId
        enqueueWatcherCall {
            await ForegroundProcessWatcher.shared.updatePushed(paneId: paneId, agent: agent)
        }
        if let cwd = foreground?.cwd, !cwd.isEmpty {
            applyReportedCwd(cwd)
        }
    }

    /// ForegroundProcessWatcher·HookDaemon 호출을 보낸 순서대로 처리한다. 하나씩 Task.detached로 보내면 순서가
    /// 보장되지 않아 hc pane의 등록보다 값이나 해제가 먼저 닿을 수 있다.
    private func enqueueWatcherCall(_ call: @escaping @Sendable () async -> Void) {
        let previous = watcherCalls
        watcherCalls = Task.detached {
            await previous?.value
            await call()
        }
    }

    // MARK: - hc 상태 라벨

    private func installHcStatusOverlay() {
        let overlay = PaneStatusOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        addSubview(overlay, positioned: .above, relativeTo: terminal)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: terminal.topAnchor, constant: 12),
            overlay.centerXAnchor.constraint(equalTo: terminal.centerXAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: terminal.widthAnchor, constant: -24)
        ])
        hcStatusOverlay = overlay
    }

    private func showHcConnectionState(_ state: HcPaneConnectionState) {
        guard let overlay = hcStatusOverlay else { return }
        if let text = Self.hcStatusText(state) {
            overlay.text = text
            overlay.isHidden = false
        } else {
            overlay.isHidden = true
        }
    }

    /// 상태 라벨 문구. 붙어 있으면 nil(라벨을 숨긴다).
    nonisolated static func hcStatusText(_ state: HcPaneConnectionState) -> String? {
        switch state {
        case .attached: return nil
        case .connecting: return "Connecting to herdr-core…"
        case .restartingShell: return "Restarting shell…"
        case .unavailable(let reason): return "herdr-core unavailable: \(reason)"
        }
    }

    /// Type `input` into the fresh shell once it looks ready (see
    /// `StartupInputScheduler`). Used to resume an agent after an update
    /// relaunch.
    private func scheduleStartupInput(_ input: String) {
        let scheduler = StartupInputScheduler(schedule: MainQueueTimer.schedule) { [weak self] in
            guard let self else { return }
            self.terminal.onOutput = nil
            self.startupInputScheduler = nil
            self.terminal.send(txt: input + "\r")
        }
        startupInputScheduler = scheduler
        terminal.onOutput = { [weak scheduler] in scheduler?.outputReceived() }
        scheduler.start()
    }

    /// Live agent session in this pane for the update-relaunch save. nil
    /// when no agent owns the PTY foreground or termy has no session id for
    /// it (see `AgentResumeCapture`).
    func agentResumeRecord(snapshot: PaneSnapshot?) -> AgentResumeRecord? {
        // hc pane은 업데이트 재시작에 죽지 않고 다시 붙으므로 resume할 것이 없다.
        guard launch == .local else { return nil }
        let masterFd = terminal.process.childfd
        let shellPid = terminal.process.shellPid
        guard masterFd >= 0, shellPid > 0,
              let pid = ForegroundProcessWatcher.foregroundProcessGroupLeader(
                  masterFd: masterFd,
                  shellPid: shellPid
              ),
              let name = ForegroundProcessWatcher.processName(pid: pid)
        else { return nil }
        let argv = ForegroundProcessWatcher.processArguments(pid: pid)
        return AgentResumeCapture.record(
            foregroundAgent: ForegroundProcessWatcher.classifyAgent(
                processName: name,
                arguments: argv ?? []
            ),
            argv: argv,
            processCwd: ForegroundProcessWatcher.processCwd(pid: pid),
            snapshot: snapshot
        )
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
        if let hcBackend, hcFocusSent != active {
            hcFocusSent = active
            hcBackend.setFocused(active)
        }
    }

    // MARK: - Header updates

    /// Mirror the agent's state onto the header (THINK activity bar).
    func applyAgentState(_ state: PaneState) {
        headerView.setThinking(state.displaysAsThinking)
    }

    private func installHeadWatcher(for cwd: String) {
        if headWatcher == nil {
            headWatcher = GitHeadWatcher { [weak self] in
                self?.refreshHeader()
            }
        }
        headWatcher?.watch(cwd: cwd)
    }

    private func refreshHeader() {
        if isRemote {
            // 원격 pane의 project는 고정이고 git을 볼 수 없다. 헤더와 mission control 라벨은 projectId
            // (`app@bdpc01`) 그대로. init 중에 불리므로 local 경로처럼 한 박자 늦춰 onHeaderChanged가 연결된 뒤 알린다.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.headerView.configure(project: self.projectId, branch: nil, appearance: self.effectiveAppearance)
                self.onHeaderChanged?(self.projectId, nil)
            }
            return
        }
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

    /// Where a relative markdown or PDF path printed in this pane most likely
    /// points: the shell's cwd, then the agent's (hook-reported), then the
    /// shell's repo root. While an agent runs the shell cwd is where it was
    /// launched, which is what it prints paths relative to. The shell goes
    /// first because the agent cwd outlives the agent: after `exit` and
    /// `cd other-project`, `README.md` must not open the old project's file.
    /// Scrollback from that older session still resolves through the agent
    /// cwd.
    func previewBaseDirectories() -> [String] {
        Self.previewBaseDirectories(
            agentCwd: MissionControlModel.shared.snapshot(paneId: paneId)?.lastCwd,
            shellCwd: currentCwd,
            workTreeRoot: GitBranch.workTreeRoot(for: currentCwd)
        )
    }

    nonisolated static func previewBaseDirectories(
        agentCwd: String?,
        shellCwd: String,
        workTreeRoot: String?
    ) -> [String] {
        var result: [String] = []
        for directory in [shellCwd, agentCwd, workTreeRoot] {
            guard let directory, !directory.isEmpty, !result.contains(directory) else { continue }
            result.append(directory)
        }
        return result
    }

    /// OSC 7 is how modern shells (zsh's default, bash with termsupport,
    /// fish, etc.) tell the terminal about the current working directory
    /// on every prompt. Any `cd` inside the pane fires this → we refresh
    /// the header to reflect the new folder + branch.
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let resolved = Pane.osc7Path(directory) else { return }
        Task { @MainActor [weak self] in
            self?.applyReportedCwd(resolved)
        }
    }

    /// OSC 7 sends a file:// URL (e.g. "file:///Users/ysh/proj"); convert it
    /// to a plain filesystem path. Control characters go first: herdr-core's
    /// re-attach first paint ends OSC 7 with a NUL before ST
    /// (`file://host/path\0`). SwiftTerm's OSC parser drops C0 bytes today,
    /// but one that got through would fail URL parsing and leave the raw
    /// string as the pane's cwd and project path.
    nonisolated static func osc7Path(_ directory: String) -> String? {
        var cleaned = String.UnicodeScalarView()
        cleaned.append(contentsOf: directory.unicodeScalars.filter { $0.properties.generalCategory != .control })
        let value = String(cleaned)
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), url.scheme == "file" {
            return url.path
        }
        return (value as NSString).expandingTildeInPath
    }

    /// 셸이 알려 준 cwd(OSC 7, hc foreground). local이면 header·branch·project drift를 다시 본다.
    /// 원격 pane은 그 머신의 경로라 이 Mac에서 git을 볼 수 없고 project도 고정이므로 currentCwd만 바꾼다.
    private func applyReportedCwd(_ path: String) {
        guard path != currentCwd else { return }
        currentCwd = path
        guard !isRemote else { return }
        refreshHeader()
        // `cd` may have crossed repo boundaries — re-arm on the new
        // HEAD so branch updates keep flowing.
        installHeadWatcher(for: path)
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let code = exitCode ?? -1
        Task { @MainActor [weak self] in
            self?.shellExited(exitCode: code)
        }
    }

    /// The pane's shell ended — the local PTY's process exited, or the hc
    /// terminal closed with `exited`/`killed`. Post PtyExit to the state
    /// machine, then let Workspace close the pane.
    private func shellExited(exitCode code: Int32) {
        let paneId = self.paneId
        let projectId = self.projectId
        enqueueWatcherCall {
            await HookDaemon.shared.postPtyExit(
                paneId: paneId,
                projectId: projectId,
                exitCode: code
            )
            await ForegroundProcessWatcher.shared.unregister(paneId: paneId)
        }
        headWatcher?.stop()
        onShellExited?(code)
    }

    private func applyTheme() {
        let theme = PaneStyling.theme(for: effectiveAppearance)
        layer?.backgroundColor = theme.paneBackgroundColor.cgColor
        terminal.nativeBackgroundColor = theme.paneBackgroundColor
        terminal.nativeForegroundColor = theme.terminalForegroundColor
        terminal.selectedTextBackgroundColor = theme.terminalSelectionBackgroundColor
        // SwiftTerm 1.20 (ed395c7) repaints selected text in this color, black
        // by default, which all but vanishes on the dark selection background.
        terminal.selectedTextForegroundColor = theme.terminalForegroundColor
        terminal.installColors(theme.terminalANSIColors.map { $0.termyTerminalColor() })
        // hc가 색 질의에 답하는 값(display facts)을 맞춘다. viewDidMoveToWindow는 relayout마다 불리므로
        // 다크/라이트가 실제로 바뀔 때만 보낸다(attach 때는 그때의 값이 attach 인자로 간다).
        let variant = PaneStyling.variant(for: effectiveAppearance)
        if variant != factsThemeVariant {
            factsThemeVariant = variant
            hcBackend?.sendDisplayFacts()
        }
    }

    private func refreshHeaderAppearance() {
        headerView.reapplyTheme(appearance: effectiveAppearance)
    }
}

// MARK: - PaneStatusOverlay

/// hc pane이 terminal에 붙어 있지 않은 이유를 terminal 위에 띄우는 작은 라벨. 클릭은 아래 terminal로 넘긴다.
final class PaneStatusOverlay: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = TermyTypography.regular(size: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - PaneHeaderView

final class PaneHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")
    let activityBar = ThinkingActivityBar()
    /// hc pane이면 오른쪽 끝에 보이는 herdr 표시(로고 실루엣, 브랜치와 같은 색). local pane은 숨긴다.
    let herdrMark = NSImageView()
    private var labelTrailingToEdge: NSLayoutConstraint!
    private var labelTrailingToMark: NSLayoutConstraint!

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

        // THINK activity bar rides on top of the bottom border.
        activityBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityBar)
        NSLayoutConstraint.activate([
            activityBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            activityBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            activityBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            activityBar.heightAnchor.constraint(equalToConstant: 3)
        ])

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = TermyTypography.medium()
        label.textColor = .labelColor
        label.allowsDefaultTighteningForTruncation = true
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        addSubview(label)

        let markImage = NSImage(named: "HerdrMark")
        markImage?.isTemplate = true
        herdrMark.image = markImage
        herdrMark.imageScaling = .scaleProportionallyUpOrDown
        herdrMark.contentTintColor = .secondaryLabelColor
        herdrMark.isHidden = true
        herdrMark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(herdrMark)
        let markHeight: CGFloat = 13
        let markAspect = markImage.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 } ?? 1

        labelTrailingToEdge = label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        labelTrailingToMark = label.trailingAnchor.constraint(lessThanOrEqualTo: herdrMark.leadingAnchor, constant: -6)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labelTrailingToEdge,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            herdrMark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            herdrMark.centerYAnchor.constraint(equalTo: centerYAnchor),
            herdrMark.heightAnchor.constraint(equalToConstant: markHeight),
            herdrMark.widthAnchor.constraint(equalToConstant: (markHeight * markAspect).rounded())
        ])
    }

    /// hc pane이면 `toolTip`과 함께 herdr 표시를 보이고, nil이면 숨긴다. 제목은 표시 앞에서 줄인다.
    func setHerdrMark(toolTip: String?) {
        herdrMark.toolTip = toolTip
        herdrMark.isHidden = toolTip == nil
        labelTrailingToEdge.isActive = toolTip == nil
        labelTrailingToMark.isActive = toolTip != nil
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

    func setThinking(_ thinking: Bool) {
        activityBar.setActive(thinking)
    }

    private func applyTheme(appearance: NSAppearance?) {
        let theme = PaneStyling.theme(for: appearance)
        let accent = PaneStyling.accentColor(for: project, appearance: appearance)
        layer?.backgroundColor = accent.withAlphaComponent(theme.headerTintAlpha).cgColor
        // Same hue as the tint, fully opaque, so the bar reads over it.
        activityBar.color = accent.withAlphaComponent(1)
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

extension FileManager {
    /// True only for an existing directory (a file at `path` doesn't count).
    func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

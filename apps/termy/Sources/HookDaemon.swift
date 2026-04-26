// HookDaemon.swift
//
// The backbone of termy's mission-control story. Owns a Unix-domain socket
// at /tmp/termy-$UID.sock, reads line-delimited JSON written by the
// `termy-hook` helper (and by Pane's synthetic PtyExit), runs each event
// through PaneStateMachine, journals it, and publishes snapshots so a UI
// layer (Weekend 3) can subscribe.
//
//                       termy-hook CLI ─┐
//                                       ├─ UDS socket ──▶ [listener task]
//                              Pane.swift ┘                      │
//                                                               ▼
//                                                    HookDaemon actor
//                                                       │    │    │
//                                           decode → apply → journal
//                                                       │
//                                                       ▼
//                                               AsyncStream<Update>
//                                                       │
//                                                    (Weekend 3 UI)
//
// Design notes:
//   * actor-isolated state so snapshots are safe to read from the main actor
//     via `await snapshots`.
//   * 30-second IDLE timer is implemented as a single periodic task (ticks
//     every 5s) rather than per-pane scheduled callbacks — cheaper, and
//     survives sleep/wake gracefully because we re-evaluate based on wall-
//     clock timestamps. After a long wake (>2 min since last activity) we
//     refuse to bulk-flip WAITING panes to IDLE.
//   * journal is append-only at ~/Library/Application Support/termy/events.jsonl;
//     rotation/truncation is v1.1.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Observed-to-the-outside status: the state of each pane plus a monotonic
/// sequence number so UI consumers can drop stale updates.
struct DaemonUpdate: Sendable {
    let seq: UInt64
    let snapshot: PaneSnapshot
}

enum CodexForegroundReconciler {
    /// Returns a `.possiblyWaiting` snapshot if a foreground Codex pane has
    /// been silent on hooks for at least `silenceThreshold` seconds while in
    /// THINKING. Returns nil if it should be left alone (recent activity,
    /// already attention-seeking, non-Codex, or wrong base state).
    static func possiblyWaitingSnapshotIfQuiet(
        _ snapshot: PaneSnapshot,
        now: Date,
        silenceThreshold: TimeInterval
    ) -> PaneSnapshot? {
        guard snapshot.agentKind == .codex,
              snapshot.state == .thinking,
              !snapshot.needsAttention
        else { return nil }

        let quietFor = now.timeIntervalSince(snapshot.updatedAt)
        guard quietFor >= silenceThreshold else { return nil }

        var updated = snapshot
        updated.state = .possiblyWaiting
        updated.waitSource = nil
        updated.updatedAt = now
        updated.enteredStateAt = now
        return updated
    }
}

actor HookDaemon {
    static let shared = HookDaemon()

    /// /tmp/termy-$UID.sock — production path. Overridable for tests.
    let socketPath: String
    /// ~/Library/Application Support/termy/events.jsonl — journal.
    let journalURL: URL

    private var panes: [String: PaneSnapshot] = [:]
    private var seq: UInt64 = 0
    private var idleTimerTask: Task<Void, Never>?
    /// accept() and read() are blocking syscalls. We pin them to a dedicated
    /// DispatchQueue so they can't stall the Swift Concurrency worker pool.
    private nonisolated let ioQueue = DispatchQueue(
        label: "app.termy.daemon.io",
        qos: .utility,
        attributes: .concurrent
    )
    /// Mutated only from ioQueue. Shared with the actor via bridging tasks.
    private nonisolated(unsafe) var serverFD: Int32 = -1
    private nonisolated(unsafe) var listening: Bool = false

    private let updateStream: AsyncStream<DaemonUpdate>
    private let updateContinuation: AsyncStream<DaemonUpdate>.Continuation
    /// Subscribers consume pane-state changes through this stream.
    nonisolated let updates: AsyncStream<DaemonUpdate>

    /// WAITING → IDLE threshold. Per design doc §Premise 5, 30s is a knob.
    private let idleThreshold: TimeInterval = 30
    /// Codex currently has no reliable "turn completed, prompt is ready"
    /// hook. If Codex stays in the PTY foreground after its last hook event
    /// and no more activity arrives for this long, treat it as input-ready.
    private let codexThinkingSilenceThreshold: TimeInterval = 8
    /// POSSIBLY_WAITING → WAITING(.promotedFromPossible) after this many
    /// seconds elapsed since entering possibly with no recovery. Total
    /// silence-to-sound is `codexThinkingSilenceThreshold` + this value
    /// (default 8 + 12 = ~20s).
    private let codexPromotionThreshold: TimeInterval = 12

    // MARK: - Init

    init() {
        let uid = getuid()
        self.socketPath = "/tmp/termy-\(uid).sock"

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("termy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.journalURL = dir.appendingPathComponent("events.jsonl")

        var continuation: AsyncStream<DaemonUpdate>.Continuation!
        self.updateStream = AsyncStream<DaemonUpdate> { continuation = $0 }
        self.updateContinuation = continuation
        self.updates = updateStream
    }

    /// Test seam — spins up a daemon without binding the socket. The
    /// production path goes through `start()`; tests skip that and drive
    /// the actor directly.
    static func testInstance() -> HookDaemon {
        HookDaemon()
    }

    /// Test seam — set or replace a pane's snapshot and return it. Used by
    /// tests to bootstrap state before exercising actor methods.
    @discardableResult
    func injectSnapshot(_ build: @Sendable () -> PaneSnapshot) -> PaneSnapshot {
        let snap = build()
        panes[snap.paneId] = snap
        return snap
    }

    // MARK: - Lifecycle

    /// Start listening. Safe to call once per process; subsequent calls no-op.
    func start() async {
        guard !listening else { return }
        listening = true
        openSocket()
        spawnAcceptLoop()
        idleTimerTask = Task.detached { [weak self] in
            await self?.idleLoop()
        }
        // Foreground-process watcher synthesizes SessionStart/SessionEnd
        // for agent CLIs that leave or enter the shell's fg PG. Closes
        // Codex's missing SessionEnd gap and covers hook-less agents.
        await ForegroundProcessWatcher.shared.start(daemon: self)
    }

    /// Tear down socket and cancel background tasks. Call on app quit.
    func stop() {
        listening = false
        idleTimerTask?.cancel()
        idleTimerTask = nil
        Task { await ForegroundProcessWatcher.shared.stop() }
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }

    /// Called by Pane when its pty exits. Posts a synthetic PtyExit event.
    /// Goes through the same state machine as hook events so the UI only
    /// cares about one source of truth.
    func postPtyExit(paneId: String, projectId: String?, exitCode: Int32) async {
        let event = HookEvent(
            event: .ptyExit,
            paneId: paneId,
            projectId: projectId,
            ts: Date().timeIntervalSince1970,
            agent: "termy",
            meta: HookEvent.Meta(exitCode: exitCode)
        )
        await ingest(event)
    }

    /// Called by ForegroundProcessWatcher when a known agent CLI enters
    /// the foreground process group of a pane's PTY. We tag the synthetic
    /// event with the detected agent (not "termy") so PaneStateMachine
    /// stamps the correct agentKind on the snapshot.
    func postSyntheticSessionStart(
        paneId: String,
        projectId: String?,
        agent: AgentKind
    ) async {
        let event = HookEvent(
            event: .sessionStart,
            paneId: paneId,
            projectId: projectId,
            ts: Date().timeIntervalSince1970,
            agent: agent == .codex ? "codex" : "claude-code",
            meta: HookEvent.Meta()
        )
        await ingest(event)
    }

    /// Called by ForegroundProcessWatcher when the foreground binary
    /// returns to the shell (or transitions to a non-agent process).
    /// `agent` stays "termy" because the source isn't an agent itself —
    /// the snapshot's existing agentKind is preserved by PaneStateMachine.
    func postSyntheticSessionEnd(paneId: String, projectId: String?) async {
        let event = HookEvent(
            event: .sessionEnd,
            paneId: paneId,
            projectId: projectId,
            ts: Date().timeIntervalSince1970,
            agent: "termy",
            meta: HookEvent.Meta()
        )
        await ingest(event)
    }

    /// Called by ForegroundProcessWatcher while Codex remains the pane's
    /// foreground process. Codex does not emit a Claude-style Stop hook when
    /// a normal turn returns to the prompt, so a quiet foreground Codex pane
    /// can otherwise stick on THINK forever.
    func reconcileCodexForeground(paneId: String, now: Date = Date()) {
        guard let current = panes[paneId],
              let snapshot = CodexForegroundReconciler.possiblyWaitingSnapshotIfQuiet(
                current,
                now: now,
                silenceThreshold: codexThinkingSilenceThreshold
              )
        else { return }

        panes[paneId] = snapshot
        seq &+= 1
        updateContinuation.yield(DaemonUpdate(seq: seq, snapshot: snapshot))
    }

    /// Called by TermyTerminalView every time the PTY produces output.
    /// PTY bytes are proof the model is working (reasoning summaries print
    /// to the PTY even between hook events). Reverts a Codex pane to
    /// `.thinking` from either:
    ///   - `.possiblyWaiting` (silent interim, no badge to clear), or
    ///   - `.waiting(.promotedFromPossible)` (timer-fired false WAIT — clears
    ///     needsAttention and badge so the user isn't paged for a still-live
    ///     turn).
    /// No-op for Claude panes, unknown paneId, or Codex states where the
    /// signal can't act (THINKING, real WAITs, IDLE, ERRORED). The early
    /// return matters: every yield drives MissionControlModel.recomputeItems
    /// + Notifier handling, which would otherwise fire on every PTY chunk
    /// of any pane.
    func recordPtyActivity(paneId: String, at now: Date = Date()) {
        guard var snapshot = panes[paneId],
              snapshot.agentKind == .codex
        else { return }

        let needsRevert: Bool
        switch (snapshot.state, snapshot.waitSource) {
        case (.possiblyWaiting, _):
            needsRevert = true
        case (.waiting, .promotedFromPossible):
            needsRevert = true
        default:
            needsRevert = false
        }
        guard needsRevert else { return }

        snapshot.lastPtyActivityAt = now
        snapshot.state = .thinking
        snapshot.needsAttention = false
        snapshot.waitSource = nil
        snapshot.updatedAt = now
        snapshot.enteredStateAt = now
        panes[paneId] = snapshot
        seq &+= 1
        updateContinuation.yield(DaemonUpdate(seq: seq, snapshot: snapshot))
    }

    /// Read-only accessor for the UI layer.
    func snapshot(paneId: String) -> PaneSnapshot? {
        panes[paneId]
    }

    func allSnapshots() -> [PaneSnapshot] {
        Array(panes.values)
    }

    // MARK: - Socket plumbing

    private nonisolated func openSocket() {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            TrayLog.log("HookDaemon: socket() failed errno=\(errno)")
            return
        }

        // Without FD_CLOEXEC, every shell SwiftTerm forks for a pane (and
        // every claude/codex/MCP-helper exec'd from those shells) inherits
        // this listening fd. The kernel then can't free the listen-socket
        // inode when termy restarts, and child references keep the listen
        // queue alive beyond our process's lifetime. Set close-on-exec so
        // forks see the bind but exec() drops it.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path),
                     "socket path too long")
        withUnsafeMutablePointer(to: &addr.sun_path) { dest in
            dest.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                bind(fd, s, addrLen)
            }
        }
        guard bindResult == 0 else {
            TrayLog.log("HookDaemon: bind() failed errno=\(errno)")
            close(fd)
            return
        }

        // 0600 permissions — only the user can talk to us.
        chmod(socketPath, 0o600)

        guard listen(fd, 32) == 0 else {
            TrayLog.log("HookDaemon: listen() failed errno=\(errno)")
            close(fd)
            return
        }

        serverFD = fd
        TrayLog.log("HookDaemon: listening on \(socketPath)")
    }

    private nonisolated func spawnAcceptLoop() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            while self.listening && self.serverFD >= 0 {
                var client = sockaddr_un()
                var len = socklen_t(MemoryLayout<sockaddr_un>.size)
                let cfd = withUnsafeMutablePointer(to: &client) { p -> Int32 in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                        accept(self.serverFD, s, &len)
                    }
                }
                guard cfd >= 0 else {
                    let err = errno
                    if err == EINTR { continue }
                    // The previous behavior was to `return` on every
                    // non-EINTR error, which silently killed the daemon:
                    // the bound fd stayed open but no thread serviced it,
                    // so further connect()s landed ECONNREFUSED until the
                    // user noticed the dashboard had gone deaf. Recover
                    // instead — a single accept() failure is almost never
                    // permanent (EMFILE/ENFILE/ECONNABORTED all clear once
                    // load drops). Only fatal-fd errors warrant exiting.
                    TrayLog.log("HookDaemon: accept() failed errno=\(err)")
                    if err == EBADF || err == EINVAL || err == ENOTSOCK {
                        TrayLog.log("HookDaemon: accept() fatal — exiting loop")
                        return
                    }
                    // Transient: brief backoff so we don't spin if the
                    // condition repeats (e.g. EMFILE under fd exhaustion).
                    usleep(50_000)
                    continue
                }
                // Same close-on-exec story as the listen socket: SwiftTerm
                // forks a shell when the user creates a new pane, and any
                // accepted-but-not-yet-closed client fd would otherwise be
                // inherited into that shell.
                _ = fcntl(cfd, F_SETFD, FD_CLOEXEC)
                self.ioQueue.async { [weak self] in
                    self?.readClient(fd: cfd)
                }
            }
        }
    }

    private nonisolated func readClient(fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        buffer.reserveCapacity(4096)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while listening {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)

            // Process complete lines.
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<newline)
                buffer.removeSubrange(0...newline)
                if line.isEmpty { continue }
                let frozen = line
                Task { [weak self] in
                    await self?.decodeAndIngest(frozen)
                }
            }
        }
        // Handle any trailing line without a newline.
        if !buffer.isEmpty {
            let frozen = buffer
            Task { [weak self] in
                await self?.decodeAndIngest(frozen)
            }
        }
    }

    // MARK: - Event ingestion

    private func decodeAndIngest(_ data: Data) async {
        let decoder = JSONDecoder()
        do {
            let event = try decoder.decode(HookEvent.self, from: data)
            await ingest(event)
        } catch {
            TrayLog.log("HookDaemon: decode failed: \(error); raw=\(String(data: data, encoding: .utf8) ?? "<binary>")")
        }
    }

    private func ingest(_ event: HookEvent) async {
        // Events without a pane_id come from `claude` invocations outside
        // termy (user ran it in iTerm/plain shell). Journal for debug, drop
        // from the state map.
        guard let paneId = event.paneId, !paneId.isEmpty else {
            await appendJournal(event)
            return
        }

        let previous = panes[paneId] ?? PaneSnapshot.empty(
            paneId: paneId,
            projectId: event.projectId
        )
        let next = PaneStateMachine.apply(event, to: previous)
        panes[paneId] = next

        seq &+= 1
        updateContinuation.yield(DaemonUpdate(seq: seq, snapshot: next))

        await appendJournal(event)
    }

    // MARK: - Journal

    private nonisolated func appendJournal(_ event: HookEvent) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)

        let path = journalURL.path
        // Tight loop-safe: use low-level open/write rather than FileHandle to
        // avoid Foundation caching surprises.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress, line.count)
        }
    }

    // MARK: - Idle timer

    private func idleLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000) // 5s tick
            await tickPromotePossiblyWaiting()
            await tickIdle()
        }
    }

    /// Walk POSSIBLY_WAITING Codex panes; promote any that have been in
    /// the state for `codexPromotionThreshold` seconds with no hook or
    /// PTY recovery. Promotion sets `waitSource = .promotedFromPossible`
    /// and `needsAttention = true`, which Notifier turns into a sound +
    /// dock badge. Called from `idleLoop`.
    func tickPromotePossiblyWaiting(now: Date = Date()) {
        for (id, snapshot) in panes where snapshot.state == .possiblyWaiting {
            let elapsed = now.timeIntervalSince(snapshot.enteredStateAt)
            guard elapsed >= codexPromotionThreshold else { continue }
            var updated = snapshot
            updated.state = .waiting
            updated.waitSource = .promotedFromPossible
            updated.needsAttention = true
            updated.updatedAt = now
            updated.enteredStateAt = now
            panes[id] = updated
            seq &+= 1
            updateContinuation.yield(DaemonUpdate(seq: seq, snapshot: updated))
        }
    }

    private func tickIdle() async {
        let now = Date()
        for (id, snapshot) in panes where snapshot.state == .waiting {
            // A WAITING pane with an outstanding attention signal (permission,
            // mcp_elicit, ask_user_question, post-idle reminder) is NOT idle —
            // Claude is blocked on the user. Flipping it to IDLE while the
            // signal persists paints the chip accent-blue via backgroundTint's
            // needsAttention branch, making the dashboard read "IDLE label on
            // blue THINK-ish background". Leave the pane WAITING until an
            // event (UserPromptSubmit / PostToolUse / SessionEnd) clears
            // needsAttention.
            if snapshot.needsAttention { continue }
            let since = now.timeIntervalSince(snapshot.enteredStateAt)
            // Sleep/wake guard: if the system was asleep > 2 min and we woke
            // up, don't bulk-flip all WAITING panes to IDLE. The user is
            // coming back to check state, not being told everything's idle.
            if since > idleThreshold, since < 120 {
                var updated = snapshot
                updated.state = .idle
                updated.updatedAt = now
                updated.enteredStateAt = now
                panes[id] = updated
                seq &+= 1
                updateContinuation.yield(DaemonUpdate(seq: seq, snapshot: updated))
            }
        }
    }
}

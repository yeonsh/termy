// ForegroundProcessWatcher.swift
//
// Per-pane poller that watches which binary owns the foreground process
// group of each pane's PTY, and synthesizes SessionStart / SessionEnd
// events when known agent CLIs (`claude`, `codex`) enter or leave that
// foreground PG.
//
// Why we need this:
//   - Codex CLI has no native `SessionEnd` hook event. When the user types
//     `/exit` and lands back at a bare shell prompt, no hook fires — the
//     pane's chip would freeze on its last state (THINK/WAIT/IDLE).
//   - It also covers the bookend transitions for any agent that ships
//     without hooks at all (Aider, Gemini CLI, future `claude` versions).
//
// Approach (kernel signal, not screen scraping):
//   - `tcgetpgrp(masterFd)` returns the foreground process group of the
//     PTY. The pgrp ID equals the PID of the pgrp leader, so we can
//     `proc_name(pid)` to discover the binary.
//   - When the leader's name flips between a known agent and the shell
//     (or any other non-agent binary), we synthesize the right hook event.
//
// Limitations (acceptable for v1):
//   - Polling cadence is 1 Hz; if a user runs `claude` for <1s it may go
//     unobserved. State machine + real hooks correct the steady state.
//   - Pipelines (`claude | tee`) put `tee` in the foreground; we won't
//     see claude. If users hit this we add path-based detection later.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

actor ForegroundProcessWatcher {
    static let shared = ForegroundProcessWatcher()

    /// 1-second tick is responsive enough for chip-state UX and cheap
    /// even with 32 panes (a `tcgetpgrp` + `proc_name` pair is two
    /// syscalls; 64 syscalls/sec is rounding error).
    private static let tickInterval: TimeInterval = 1.0

    private weak var daemon: HookDaemon?
    private var entries: [String: Entry] = [:]
    private var tickTask: Task<Void, Never>?

    private struct Entry {
        let masterFd: Int32
        let shellPid: pid_t
        let projectId: String?
        /// Last classification we observed — `nil` means "shell or other
        /// non-agent process is in the foreground". Transitions in or out
        /// of `nil` drive synthetic events.
        var lastDetected: AgentKind?
    }

    init() {}

    // MARK: - Lifecycle

    func start(daemon: HookDaemon) {
        self.daemon = daemon
        guard tickTask == nil else { return }
        tickTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
                await self?.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Pane registration

    func register(paneId: String, masterFd: Int32, shellPid: pid_t, projectId: String?) {
        entries[paneId] = Entry(
            masterFd: masterFd,
            shellPid: shellPid,
            projectId: projectId,
            lastDetected: nil
        )
    }

    func unregister(paneId: String) {
        entries.removeValue(forKey: paneId)
    }

    // MARK: - Polling

    private func tick() async {
        for (paneId, entry) in entries {
            let detected = currentForegroundAgent(masterFd: entry.masterFd, shellPid: entry.shellPid)
            guard detected != entry.lastDetected else { continue }

            // Edge: we left the previous agent (or first transition).
            if let prior = entry.lastDetected, prior != detected {
                await daemon?.postSyntheticSessionEnd(
                    paneId: paneId,
                    projectId: entry.projectId
                )
            }
            // Edge: we entered a new agent.
            if let next = detected {
                await daemon?.postSyntheticSessionStart(
                    paneId: paneId,
                    projectId: entry.projectId,
                    agent: next
                )
            }

            var updated = entry
            updated.lastDetected = detected
            entries[paneId] = updated
        }

        for (paneId, entry) in entries where entry.lastDetected == .codex {
            await daemon?.reconcileCodexForeground(paneId: paneId)
        }
    }

    /// Read the foreground PG of `masterFd`, look up the PG leader, and
    /// classify it. Returns `nil` for the shell prompt, for unknown binaries
    /// (vim, less, etc.), and on syscall failure.
    private func currentForegroundAgent(masterFd: Int32, shellPid: pid_t) -> AgentKind? {
        let fgPgrp = tcgetpgrp(masterFd)
        guard fgPgrp > 0 else { return nil }
        // If the foreground PG is the shell's own PG, no agent is running.
        // (Shell-builtins still run in the shell's PG, hence comparing PG
        // and not "exact PID == shell".)
        let shellPgrp = getpgid(shellPid)
        if shellPgrp > 0 && shellPgrp == fgPgrp { return nil }
        guard let name = Self.processName(pid: fgPgrp) else { return nil }
        return Self.classifyAgent(
            processName: name,
            arguments: Self.processArguments(pid: fgPgrp) ?? []
        )
    }

    // MARK: - Pure helpers (testable)

    /// Classify a foreground process using both its executable name and argv.
    ///
    /// Homebrew / npm installs often launch Codex through a Node shebang, so
    /// Darwin reports the foreground PG leader as `node` instead of `codex`.
    /// The hook stream corrects state once the user submits a prompt, but the
    /// dashboard should show the pane as soon as Codex is launched. For known
    /// JS runtimes, inspect argv for a real Codex/Claude CLI entrypoint.
    static func classifyAgent(processName: String, arguments: [String]) -> AgentKind? {
        if let direct = classifyAgent(by: processName) {
            return direct
        }
        guard isJavaScriptRuntime(processName) else {
            return nil
        }
        return classifyAgent(fromArguments: arguments)
    }

    /// Map a process basename / executable name to a known agent.
    /// Lowercase comparison so `Codex`, `codex-cli`, etc. all match.
    static func classifyAgent(by name: String) -> AgentKind? {
        let normalized = name.lowercased()
        // Check codex first because some users alias `claude → codex` for
        // experimentation; we trust the actual binary name, not the alias.
        if normalized == "codex" || normalized.hasPrefix("codex-") {
            return .codex
        }
        if normalized == "claude" || normalized.hasPrefix("claude-") {
            return .claude
        }
        return nil
    }

    private static func isJavaScriptRuntime(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized == "node"
            || normalized == "nodejs"
            || normalized == "bun"
            || normalized == "deno"
    }

    private static func classifyAgent(fromArguments arguments: [String]) -> AgentKind? {
        for argument in arguments {
            let normalized = argument.lowercased()
            let basename = (normalized as NSString).lastPathComponent
            if basename == "codex"
                || basename.hasPrefix("codex-")
                || normalized.contains("@openai/codex") {
                return .codex
            }
            if basename == "claude"
                || basename.hasPrefix("claude-")
                || normalized.contains("@anthropic-ai/claude-code") {
                return .claude
            }
        }
        return nil
    }

    /// libproc's `proc_name` returns the basename (not full path) of the
    /// executable for a PID, truncated to ~16 chars. Returns nil if the
    /// PID has gone away or the syscall fails.
    static func processName(pid: pid_t) -> String? {
        #if canImport(Darwin)
        var buf = [CChar](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            proc_name(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        guard n > 0 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    /// Read argv for a process using macOS's KERN_PROCARGS2 sysctl. Returns
    /// nil if the process has exited, access is denied, or the buffer format
    /// is not the expected argc + exec-path + argv layout.
    static func processArguments(pid: pid_t) -> [String]? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }

        let argc = buffer.withUnsafeBytes { raw -> Int32 in
            raw.load(as: Int32.self)
        }
        guard argc > 0 else { return [] }

        var offset = MemoryLayout<Int32>.size
        // Skip exec path.
        while offset < size, buffer[offset] != 0 {
            offset += 1
        }
        // Skip separator NULs before argv[0].
        while offset < size, buffer[offset] == 0 {
            offset += 1
        }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard offset < size else { break }
            let start = offset
            while offset < size, buffer[offset] != 0 {
                offset += 1
            }
            if offset > start,
               let arg = String(bytes: buffer[start..<offset], encoding: .utf8) {
                arguments.append(arg)
            }
            while offset < size, buffer[offset] == 0 {
                offset += 1
            }
        }
        return arguments
        #else
        return nil
        #endif
    }
}

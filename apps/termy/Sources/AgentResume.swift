// AgentResume.swift
//
// What termy records about a running agent right before a Sparkle update
// relaunch, and the shell command that reopens the same conversation in
// the restored pane. The relaunch kills every PTY child (termy.app owns
// the PTY master fds), so the process can't survive — the conversation
// can, through `claude --resume` / `codex resume`.
// See docs/superpowers/specs/2026-10-10-agent-resume-after-update-design.md.

import Foundation

/// One pane's agent session, captured at update-relaunch time only.
struct AgentResumeRecord: Codable, Equatable {
    var kind: AgentKind
    var sessionId: String
    /// The agent process's own cwd as the kernel reports it. nil when it
    /// couldn't be read — restore then uses the pane's saved cwd.
    var cwd: String?
    /// argv pieces that passed `AgentResumeFlags`, in original order.
    var flags: [String]
}

/// Builds the command typed into a restored pane's shell.
enum AgentResumeCommand {
    static func make(_ record: AgentResumeRecord) -> String {
        let id = shellQuote(record.sessionId)
        let flags = record.flags.map(shellQuote)
        let words: [String]
        switch record.kind {
        case .claude:
            words = ["claude", "--resume", id] + flags
        case .codex:
            // `codex resume [OPTIONS] [SESSION_ID] [PROMPT]` — options go
            // first so nothing after the id can read as a prompt.
            words = ["codex", "resume"] + flags + [id]
        }
        return words.joined(separator: " ")
    }

    private static let safeCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:=@%+,-"
    )

    /// Leave shell-safe words bare so the visible command stays readable;
    /// single-quote everything else. A leading `=` is quoted too because
    /// zsh's EQUALS option expands it.
    static func shellQuote(_ word: String) -> String {
        if !word.isEmpty,
           !word.hasPrefix("="),
           word.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return word
        }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Decides whether a pane gets an `AgentResumeRecord`. Pure — `Pane`
/// reads the live process info and passes it in.
enum AgentResumeCapture {
    /// A record only when an agent owns the PTY foreground right now and
    /// termy's hook snapshot has a session id for that same agent.
    static func record(
        foregroundAgent: AgentKind?,
        argv: [String]?,
        processCwd: String?,
        snapshot: PaneSnapshot?
    ) -> AgentResumeRecord? {
        guard let kind = foregroundAgent,
              let snapshot,
              snapshot.agentKind == kind,
              snapshot.state != .initializing,
              let sessionId = snapshot.lastSessionId,
              !sessionId.isEmpty
        else { return nil }
        return AgentResumeRecord(
            kind: kind,
            sessionId: sessionId,
            cwd: processCwd,
            flags: AgentResumeFlags.extract(kind: kind, argv: argv ?? [])
        )
    }
}

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
    /// The resume command is typed into the shell as keystrokes, where a
    /// control character would act as an editing key (^U, ^C, ESC) rather
    /// than text: an id outside `[A-Za-z0-9._-]` gives no record, and a
    /// control character in any carried flag drops every flag.
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
              !sessionId.isEmpty,
              sessionId.unicodeScalars.allSatisfy(sessionIdCharacters.contains)
        else { return nil }
        var flags = AgentResumeFlags.extract(kind: kind, argv: argv ?? [])
        if flags.contains(where: containsControlCharacter) {
            flags = []
        }
        return AgentResumeRecord(
            kind: kind,
            sessionId: sessionId,
            cwd: processCwd,
            flags: flags
        )
    }

    private static let sessionIdCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )

    /// C0 controls (U+0000–U+001F) and DEL (U+007F).
    private static func containsControlCharacter(_ word: String) -> Bool {
        word.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Restore-time decision for one saved pane: where its shell starts and
    /// which resume command to type. The agent's cwd, else the pane's; when
    /// neither exists any more the shell lands in `$HOME`
    /// (`Pane.resolveCwd`) and the agent is not resumed — a resume there
    /// would run in an unrelated directory.
    static func restorePlan(
        paneCwd: String,
        resume: AgentResumeRecord?,
        directoryExists: (String) -> Bool
    ) -> (cwd: String, startupInput: String?) {
        guard let resume else { return (paneCwd, nil) }
        if let agentCwd = resume.cwd, directoryExists(agentCwd) {
            return (agentCwd, AgentResumeCommand.make(resume))
        }
        if directoryExists(paneCwd) {
            return (paneCwd, AgentResumeCommand.make(resume))
        }
        return (paneCwd, nil)
    }
}

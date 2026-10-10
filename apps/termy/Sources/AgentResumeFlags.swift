// AgentResumeFlags.swift
//
// Picks the argv pieces worth carrying into `claude --resume` /
// `codex resume`: permission and model flags only. Everything else —
// positional prompts above all — is dropped, so a resume never replays
// the prompt the agent was launched with.
//
// The argv comes from the running agent process, so every flag in it was
// accepted by the CLI version that is running. A stale entry in these
// tables just never matches, and a new CLI flag just isn't carried; only
// a change to the resume command itself needs a termy update.

import Foundation

enum AgentResumeFlags {
    private enum Arity {
        /// Boolean switch.
        case none
        /// Exactly one value. May repeat (`-c a=1 -c b=2`); every
        /// occurrence is kept in order.
        case one
        /// Variadic (commander `<values...>`): every following argument up
        /// to the next one starting with `-`.
        case many
    }

    private static let claude: [String: Arity] = [
        "--dangerously-skip-permissions": .none,
        "--model": .one,
        "--permission-mode": .one,
        "--allowedTools": .many,
        "--allowed-tools": .many,
        "--disallowedTools": .many,
        "--disallowed-tools": .many,
        "--add-dir": .many,
    ]

    /// Checked against `codex resume --help` (codex-cli 0.160.1). `-p` is
    /// `--profile` here, unlike claude's `-p` / `--print`.
    private static let codex: [String: Arity] = [
        "--approve-for-me": .none,
        "--dangerously-bypass-approvals-and-sandbox": .none,
        "-m": .one, "--model": .one,
        "-s": .one, "--sandbox": .one,
        "-a": .one, "--ask-for-approval": .one,
        "-p": .one, "--profile": .one,
        "-c": .one, "--config": .one,
        "--add-dir": .one,
    ]

    static func extract(kind: AgentKind, argv: [String]) -> [String] {
        guard let entry = ForegroundProcessWatcher.agentEntrypoint(in: argv) else { return [] }
        let args = Array(argv.dropFirst(entry.index + 1))
        let table = (kind == .claude) ? claude : codex
        var kept: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                // `--flag=value` carries its value inline.
                if let arity = table[String(arg[..<eq])], arity != .none {
                    kept.append(arg)
                }
                i += 1
                continue
            }
            guard let arity = table[arg] else {
                i += 1
                continue
            }
            switch arity {
            case .none:
                kept.append(arg)
                i += 1
            case .one:
                if i + 1 < args.count {
                    kept.append(contentsOf: [arg, args[i + 1]])
                }
                i += 2
            case .many:
                var j = i + 1
                while j < args.count, !args[j].hasPrefix("-") { j += 1 }
                if j > i + 1 {
                    kept.append(contentsOf: args[i..<j])
                }
                i = j
            }
        }
        return kept
    }
}

// HookCLI.swift
//
// Argument parsing for `termy-hook`. Lives in its own file so the unit
// tests can compile it without dragging in the rest of main.swift's
// top-level statements (sockets, stdin reads, exit codes).
//
// Both the termy-hook tool target and the termy-tests bundle compile this
// file (see project.yml). Keep it dependency-free — no Foundation types
// beyond Swift stdlib so it stays cheap to share.

/// Parsed command-line invocation for `termy-hook`.
struct ParsedHookArgs: Equatable {
    var agent: String   // wire-level value: "claude-code" | "codex" | …
    var event: String   // hook event name, e.g. "SessionStart"
}

enum HookCLI {
    /// Parse `argv` into a typed invocation, or `nil` if the form is
    /// unrecognized (caller bails silently — never fail the calling agent).
    ///
    /// Supported forms:
    ///   termy-hook SessionStart                        → agent="claude-code"
    ///   termy-hook --agent codex PermissionRequest     → agent="codex"
    ///   termy-hook --agent claude SessionEnd           → agent="claude-code"
    static func parse(_ argv: [String]) -> ParsedHookArgs? {
        var agent = "claude-code"
        var positional: [String] = []
        var idx = 1 // skip executable path
        while idx < argv.count {
            let arg = argv[idx]
            switch arg {
            case "--agent":
                guard idx + 1 < argv.count else { return nil }
                let raw = argv[idx + 1]
                // Map our typed names ("claude" / "codex") to the wire
                // names the daemon expects. Unknown values pass through
                // verbatim — daemon treats them as unresolved kind and
                // inherits the pane's prior agentKind.
                switch raw {
                case "claude": agent = "claude-code"
                default:       agent = raw
                }
                idx += 2
            default:
                positional.append(arg)
                idx += 1
            }
        }
        guard let event = positional.first else { return nil }
        return ParsedHookArgs(agent: agent, event: event)
    }
}

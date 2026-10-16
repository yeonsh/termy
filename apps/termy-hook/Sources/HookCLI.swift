// HookCLI.swift
//
// Argument parsing for `termy-hook`. Lives in its own file so the unit
// tests can compile it without dragging in the rest of main.swift's
// top-level statements (sockets, stdin reads, exit codes).
//
// Both the termy-hook tool target and the termy-tests bundle compile this
// file (see project.yml). Keep it dependency-free — no Foundation types
// beyond Swift stdlib so it stays cheap to share.

import Foundation

/// Parsed command-line invocation for `termy-hook`.
struct ParsedHookArgs: Equatable {
    var agent: String   // wire-level value: "claude-code" | "codex" | "antigravity" | …
    var event: String   // hook event name, e.g. "SessionStart"
}

enum HookCLI {
    /// Fields we forward to the daemon. Dropping the rest keeps events.jsonl
    /// small — raw SessionStart with an active plugin can be >150KB.
    /// Keys match HookEvent.Meta in the host app.
    static let forwardedKeys: Set<String> = [
        "session_id", "cwd", "source", "reason", "notification_type",
        "prompt", "last_assistant_message", "stop_hook_active",
        "tool_name", "tool_use_id", "tool_input",
        "exit_code", "error", "transcript_path"
    ]

    /// Hard cap per string field — CC payloads sometimes include prompts or
    /// assistant messages in the 10-100KB range. Truncate for the wire.
    static let defaultMaxStringBytes = 4096

    /// Parse `argv` into a typed invocation, or `nil` if the form is
    /// unrecognized (caller bails silently — never fail the calling agent).
    ///
    /// Supported forms:
    ///   termy-hook SessionStart                        → agent="claude-code"
    ///   termy-hook --agent codex PermissionRequest     → agent="codex"
    ///   termy-hook --agent claude SessionEnd           → agent="claude-code"
    ///   termy-hook --agent antigravity PreInvocation   → agent="antigravity"
    ///   termy-hook --agent agy PreInvocation           → agent="antigravity"
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
                // Map our typed names ("claude" / "codex" / "agy") to the wire
                // names the daemon expects. Unknown values pass through
                // verbatim — daemon treats them as unresolved kind and
                // inherits the pane's prior agentKind.
                switch raw {
                case "claude":             agent = "claude-code"
                case "agy", "antigravity": agent = "antigravity"
                default:                   agent = raw
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

    /// Slim a payload dict down to our forwarded keys, normalizing Antigravity
    /// camelCase/nested fields (`conversationId`, `workspacePaths`, `toolCall`,
    /// `terminationReason`, `transcriptPath`) into the canonical snake_case
    /// keys expected by `HookEvent.Meta`.
    static func slimMeta(
        _ raw: [String: Any],
        maxStringBytes: Int = defaultMaxStringBytes
    ) -> [String: String] {
        var out: [String: String] = [:]
        for key in forwardedKeys {
            guard let value = raw[key], !(value is NSNull) else { continue }
            out[key] = coerceToString(value, maxBytes: maxStringBytes)
        }

        // Antigravity CLI (agy) camelCase / nested protojson fields:
        if out["session_id"] == nil,
           let convId = raw["conversationId"] as? String,
           !convId.isEmpty {
            out["session_id"] = coerceToString(convId, maxBytes: maxStringBytes)
        }
        if out["cwd"] == nil,
           let workspaces = raw["workspacePaths"] as? [Any],
           let first = workspaces.lazy.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
            out["cwd"] = coerceToString(first, maxBytes: maxStringBytes)
        }
        if out["transcript_path"] == nil,
           let transcript = raw["transcriptPath"] as? String,
           !transcript.isEmpty {
            out["transcript_path"] = coerceToString(transcript, maxBytes: maxStringBytes)
        }
        if out["reason"] == nil,
           let termReason = raw["terminationReason"] as? String,
           !termReason.isEmpty {
            out["reason"] = coerceToString(termReason, maxBytes: maxStringBytes)
        }
        if let toolCall = raw["toolCall"] as? [String: Any] {
            if out["tool_name"] == nil,
               let name = toolCall["name"] as? String,
               !name.isEmpty {
                out["tool_name"] = coerceToString(name, maxBytes: maxStringBytes)
            }
            if out["tool_use_id"] == nil,
               let id = toolCall["id"] as? String,
               !id.isEmpty {
                out["tool_use_id"] = coerceToString(id, maxBytes: maxStringBytes)
            }
            if out["tool_input"] == nil,
               let args = toolCall["args"],
               !(args is NSNull) {
                out["tool_input"] = coerceToString(args, maxBytes: maxStringBytes)
            }
        }

        return out
    }

    /// Coerce any Foundation-JSON-decoded value to a String for the wire.
    static func coerceToString(_ value: Any, maxBytes: Int = defaultMaxStringBytes) -> String {
        if let s = value as? String {
            return String(s.prefix(maxBytes))
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let json = String(data: data, encoding: .utf8) {
            return String(json.prefix(maxBytes))
        }
        return String(describing: value).prefix(maxBytes).description
    }
}

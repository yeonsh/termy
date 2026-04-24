// HookEvent.swift
//
// Wire format for messages traveling over /tmp/termy-$UID.sock.
// Producer side is the `termy-hook` CLI; consumer is HookDaemon.
//
// Schema is *slimmed* vs. what Claude Code actually passes to hooks — raw CC
// payloads include large fields (e.g. SessionStart carries a full plugin
// prompt blob, 150KB+). The helper binary drops noise before writing, so the
// daemon only parses a small, stable subset.

import Foundation

/// Canonical CC hook event names, plus `PtyExit` emitted synthetically by
/// PtyController when the child process exits (no real hook fires for hard
/// crashes — this is the only reliable ERRORED signal).
enum HookEventKind: String, Codable {
    case sessionStart         = "SessionStart"
    case sessionEnd           = "SessionEnd"
    case userPromptSubmit     = "UserPromptSubmit"
    case preToolUse           = "PreToolUse"
    case postToolUse          = "PostToolUse"
    case postToolUseFailure   = "PostToolUseFailure"
    case stop                 = "Stop"
    case stopFailure          = "StopFailure"
    case subagentStop         = "SubagentStop"
    case notification         = "Notification"
    case ptyExit              = "PtyExit" // synthetic from PtyController on pty EOF
}

/// One event as it appears on the socket, line-delimited JSON.
struct HookEvent: Codable {
    let event: HookEventKind
    let paneId: String?          // from $TERMY_PANE_ID
    let projectId: String?       // from $TERMY_PROJECT_ID
    let ts: Double               // unix seconds (sub-second resolution on synthetic events)
    let agent: String            // "claude-code" for hook-originated; "termy" for synthetic
    let meta: Meta

    enum CodingKeys: String, CodingKey {
        case event
        case paneId = "pane_id"
        case projectId = "project_id"
        case ts
        case agent
        case meta
    }

    /// Event-specific payload (kept small by `termy-hook`).
    struct Meta: Codable {
        var sessionId: String?
        var cwd: String?
        var source: String?                  // SessionStart: "startup" | "resume" | "compact"
        var reason: String?                  // SessionEnd: "clear" | "exit" | ...; Notification: "permission" | "idle" | "mcp_elicit"
        var prompt: String?                  // UserPromptSubmit, truncated
        var lastAssistantMessage: String?    // Stop, truncated
        /// CC actually sends this as a numeric string ("0"/"1") despite the
        /// field name, so we accept it as String? and let the daemon ignore
        /// the exact value. Typing it as Bool? crashed every Stop decode.
        var stopHookActive: String?          // Stop
        var toolName: String?                // Pre/PostToolUse
        var toolUseId: String?               // Pre/PostToolUse
        var toolInput: String?               // Pre/PostToolUse, truncated
        var exitCode: Int32?                 // PtyExit

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd
            case source
            case reason
            case prompt
            case lastAssistantMessage = "last_assistant_message"
            case stopHookActive = "stop_hook_active"
            case toolName = "tool_name"
            case toolUseId = "tool_use_id"
            case toolInput = "tool_input"
            case exitCode = "exit_code"
        }
    }
}

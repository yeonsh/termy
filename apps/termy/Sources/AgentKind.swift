// AgentKind.swift
//
// Which CLI agent is running inside a pane. Threaded through PaneSnapshot
// so the dashboard, Notifier, and PaneStateMachine can branch on agent
// semantics without sprinkling string compares everywhere.
//
// Wire format: HookEvent's existing `agent: String` field carries the raw
// label written by termy-hook ("claude-code", "codex", "termy" for synthetic
// events). `AgentKind.from(rawAgent:)` is the central place that maps those
// strings to a typed enum — anything unrecognized falls back to `.claude`
// since that's the dominant install today.

import Foundation

enum AgentKind: String, Sendable, Codable, Hashable {
    case claude
    case codex

    /// Map the wire-level `agent` string emitted by termy-hook to a kind.
    /// Synthetic events (`agent == "termy"`) are inherited from the snapshot
    /// they target, so callers should fall back to the pane's existing kind
    /// rather than coercing termy → .claude.
    static func from(rawAgent: String) -> AgentKind? {
        switch rawAgent {
        case "claude-code": return .claude
        case "codex":       return .codex
        default:            return nil
        }
    }
}

// PaneState.swift
//
// Per-pane state machine driven by HookEvents. ERRORED is driven by
// PtyExit (exit_code != 0) or StopFailure — NOT by PostToolUseFailure, which
// fires on routine tool errors that Claude recovers from within the same turn.
//
//   INIT             ──(UserPromptSubmit)─────────▶ THINKING
//   INIT             ──(SessionStart)──────────────▶ INIT          (informational)
//   THINKING         ──(Stop)───────────────────────▶ WAITING(.turnEnd)
//   THINKING         ──(SessionEnd)─────────────────▶ INIT
//   THINKING         ──(PtyExit, exit != 0)─────────▶ ERRORED
//   THINKING         ──(reconciler 8s silence)──────▶ POSSIBLY_WAITING (silent)
//   POSSIBLY_WAITING ──(Pre/PostToolUse)─────────────▶ THINKING       (silent recovery)
//   POSSIBLY_WAITING ──(PTY byte)────────────────────▶ THINKING       (PTY proof of life)
//   POSSIBLY_WAITING ──(Stop)────────────────────────▶ WAITING(.turnEnd)         ♪
//   POSSIBLY_WAITING ──(PermissionRequest)───────────▶ WAITING(.permission)      ♪
//   POSSIBLY_WAITING ──(AskUserQuestion)─────────────▶ WAITING(.askUserQuestion) ♪
//   POSSIBLY_WAITING ──(promote timer 12s elapsed)───▶ WAITING(.promotedFromPossible) ♪
//   WAITING          ──(UserPromptSubmit)───────────▶ THINKING
//   WAITING          ──(30s wall-clock timer)───────▶ IDLE
//   WAITING          ──(SessionEnd | PtyExit)───────▶ INIT
//   WAITING(.permission)         ──(PostToolUse)──▶ THINKING (Codex resumed)
//   WAITING(.askUserQuestion)    ──(PostToolUse AskUserQuestion)──▶ THINKING
//   WAITING(.promotedFromPossible) ──(Pre/PostToolUse)──▶ THINKING (recovery, c80d2c4 lineage)
//   IDLE      ──(UserPromptSubmit)──────▶ THINKING
//   IDLE      ──(SessionEnd | PtyExit)──▶ INIT
//   ERRORED   ──(UserPromptSubmit)──────▶ THINKING
//   ERRORED   ──(Stop)───────────────────▶ WAITING(.turnEnd)
//   ERRORED   ──(SessionStart)───────────▶ INIT
//   *(codex)  ──(SessionStart)───────────▶ IDLE          (hard reset)
//
// ♪ = Notifier plays a sound and raises needsAttention.
//
// POSSIBLY_WAITING is rendered as THINK in the dashboard chip — invisible to
// the user. The two-stage WAIT is documented in
// docs/superpowers/plans/2026-04-26-codex-possibly-waiting-state.md.

import Foundation

enum PaneState: String, Sendable, Codable {
    case initializing    = "INIT"
    case thinking        = "THINKING"
    case possiblyWaiting = "POSSIBLY_WAITING"
    case waiting         = "WAITING"
    case idle            = "IDLE"
    case errored         = "ERRORED"
}

/// Why a pane is in `.waiting`. Codex paths set this; Claude paths leave nil
/// and rely on `notificationReason` for the legacy reason strings.
enum WaitSource: String, Sendable, Codable {
    /// Codex emitted PermissionRequest — user must approve a tool call.
    case permission           = "permission"
    /// Codex called AskUserQuestion — user must pick an option.
    case askUserQuestion      = "ask_user_question"
    /// Codex's Stop hook fired — turn naturally ended.
    case turnEnd              = "turn_end"
    /// Reconciler-induced POSSIBLY_WAITING aged out without recovery —
    /// promoted to real WAITING by the daemon's tick. Eligible for
    /// hook-based recovery on next Pre/PostToolUse.
    case promotedFromPossible = "promoted_from_possible"
}

/// Immutable snapshot of everything HookDaemon tracks for one pane.
struct PaneSnapshot: Sendable, Codable {
    let paneId: String
    let projectId: String?
    var state: PaneState
    var needsAttention: Bool
    var notificationReason: String?     // Claude legacy: "permission" | "idle" | "mcp_elicit" or nil
    /// Codex-only typed reason for `.waiting`. nil for Claude and for non-waiting states.
    var waitSource: WaitSource?
    var lastSessionId: String?
    var lastCwd: String?
    var lastPrompt: String?              // UserPromptSubmit.prompt (truncated)
    var lastAssistantMessage: String?    // Stop.last_assistant_message (truncated)
    var updatedAt: Date
    /// Timestamp of the most recent event; used by HookDaemon to arm the
    /// WAITING → IDLE 30-second wall-clock timer.
    var enteredStateAt: Date
    /// Which CLI agent is running in this pane. Set on the first hook event
    /// (or by foreground-process detection) and sticky thereafter until a
    /// new SessionStart from a different agent arrives.
    var agentKind: AgentKind = .claude
    /// Last time PTY produced output for this pane. Updated by
    /// TermyTerminalView.dataReceived → HookDaemon.recordPtyActivity.
    /// Used as a liveness signal during POSSIBLY_WAITING.
    var lastPtyActivityAt: Date?

    private enum CodingKeys: String, CodingKey {
        case paneId, projectId, state, needsAttention, notificationReason, waitSource
        case lastSessionId, lastCwd, lastPrompt, lastAssistantMessage
        case updatedAt, enteredStateAt, agentKind, lastPtyActivityAt
    }
}

extension PaneSnapshot {
    static func empty(
        paneId: String,
        projectId: String?,
        agentKind: AgentKind = .claude
    ) -> PaneSnapshot {
        let now = Date()
        return PaneSnapshot(
            paneId: paneId,
            projectId: projectId,
            state: .initializing,
            needsAttention: false,
            notificationReason: nil,
            waitSource: nil,
            lastSessionId: nil,
            lastCwd: nil,
            lastPrompt: nil,
            lastAssistantMessage: nil,
            updatedAt: now,
            enteredStateAt: now,
            agentKind: agentKind,
            lastPtyActivityAt: nil
        )
    }
}

/// Pure state-transition function. Given the current snapshot and an
/// incoming event, returns the new snapshot. Deterministic — no I/O, no
/// timers. HookDaemon owns the idle timer separately.
enum PaneStateMachine {
    static func apply(_ event: HookEvent, to previous: PaneSnapshot) -> PaneSnapshot {
        var next = previous
        next.updatedAt = Date()

        // Stamp the pane with whichever agent originated this event.
        // Synthetic events (agent="termy") return nil here and leave the
        // pane's existing kind untouched. A user switching from `claude`
        // to `codex` in the same pane will flip kind on the first event
        // from the new agent.
        if let kind = event.agentKind {
            next.agentKind = kind
        }

        // If the session id changed for this pane, it's a different CC
        // invocation (user typed /clear or started a new claude). Reset.
        if let incoming = event.meta.sessionId,
           let prior = previous.lastSessionId,
           incoming != prior {
            next.state = .initializing
            next.needsAttention = false
            next.notificationReason = nil
            next.enteredStateAt = next.updatedAt
        }
        if let incoming = event.meta.sessionId {
            next.lastSessionId = incoming
        }
        if let cwd = event.meta.cwd {
            next.lastCwd = cwd
        }

        switch event.event {
        case .sessionStart:
            // A fresh agent invocation has just started.
            //
            // Codex panes: hard-reset to IDLE regardless of prior state.
            // Codex has no SessionEnd hook event — Phase 4's foreground-
            // process detector synthesizes one but can miss edges
            // (rapid-fire `/exit` + relaunch, daemon restart). Treating
            // every Codex SessionStart as a clean reset stops stale
            // THINK/WAIT chips from surviving across sessions.
            //
            // Claude panes: only promote from .initializing. Mid-work
            // sessions (resume after compact, etc.) keep their state so
            // the dashboard doesn't flicker on every plugin handshake.
            let resolvedKind = event.agentKind ?? previous.agentKind
            if resolvedKind == .codex {
                next.state = .idle
                next.needsAttention = false
                next.notificationReason = nil
                next.enteredStateAt = next.updatedAt
            } else if previous.state == .initializing {
                next.state = .idle
                next.enteredStateAt = next.updatedAt
            }

        case .userPromptSubmit:
            next.lastPrompt = event.meta.prompt
            next.state = .thinking
            next.needsAttention = false
            next.notificationReason = nil
            next.enteredStateAt = next.updatedAt

        case .stop:
            next.lastAssistantMessage = event.meta.lastAssistantMessage
            next.state = .waiting
            // waitSource is the Codex-only typed reason (see PaneState.swift).
            // Claude paths leave it nil and continue using notificationReason
            // for legacy reason strings; Notifier reads waitSource as Codex,
            // so tagging Claude WAITs with .turnEnd would mis-attribute the
            // notification copy.
            if (event.agentKind ?? previous.agentKind) == .codex {
                next.waitSource = .turnEnd
            }
            next.enteredStateAt = next.updatedAt

        case .stopFailure:
            // Abnormal turn termination (rate-limit, mid-turn crash). Unlike
            // PostToolUseFailure, this really does end the turn.
            next.state = .errored
            next.enteredStateAt = next.updatedAt

        case .postToolUseFailure:
            // Per-tool failure is NOT a pane-level error. Claude routinely
            // recovers from Read-missing-file, Glob-no-matches, Bash-exit-1
            // and continues the turn. Flipping to ERRORED on every such tool
            // failure makes the dashboard lie ("ERR" on a pane that's still
            // THINKING). Keep the state unchanged.
            break

        case .sessionEnd, .ptyExit:
            // PtyExit with non-zero exit → ERRORED; everything else → INIT.
            if event.event == .ptyExit, let code = event.meta.exitCode, code != 0 {
                next.state = .errored
            } else {
                next.state = .initializing
                next.needsAttention = false
                next.notificationReason = nil
            }
            next.enteredStateAt = next.updatedAt

        case .notification:
            next.needsAttention = true
            next.notificationReason = event.meta.reason
            // Reasons where Claude is actively paused waiting for the user
            // (permission prompt, MCP elicitation, post-idle reminder) should
            // flip the visible state to WAITING — "THINKING while waiting on
            // me" is a lie, and so is "IDLE while waiting on me" (IDLE lands
            // any time the 30s WAITING→IDLE timer fires while a notification
            // is still outstanding). `auth_success` and unknown reasons
            // preserve state since Claude continues on its own.
            switch event.meta.reason {
            case "permission", "idle", "mcp_elicit":
                if previous.state == .thinking || previous.state == .idle {
                    next.state = .waiting
                    next.enteredStateAt = next.updatedAt
                }
            default:
                break
            }

        case .permissionRequest:
            // Codex's "blocked on user" signal — same semantic as Claude
            // Code's Notification(reason: permission). Always flip to WAIT
            // and raise needsAttention; the dock badge + dashboard chip
            // need to reflect that the agent is stalled, regardless of
            // what state we thought we were in (idle drift, missed Stop).
            next.state = .waiting
            next.needsAttention = true
            next.notificationReason = "permission"
            next.waitSource = .permission
            next.enteredStateAt = next.updatedAt

        case .preToolUse:
            if event.meta.toolName == "AskUserQuestion" {
                next.state = .waiting
                next.needsAttention = true
                next.notificationReason = "ask_user_question"
                // Codex-only — Notifier reads waitSource as Codex copy.
                if (event.agentKind ?? previous.agentKind) == .codex {
                    next.waitSource = .askUserQuestion
                }
                next.enteredStateAt = next.updatedAt
            } else if (event.agentKind ?? previous.agentKind) == .codex,
                      previous.state == .possiblyWaiting {
                // Possible-WAIT recovery: hook activity proves the model is working.
                // Silent — no needsAttention was raised on possibly entry.
                next.state = .thinking
                next.enteredStateAt = next.updatedAt
            } else if (event.agentKind ?? previous.agentKind) == .codex,
                      previous.state == .waiting,
                      previous.waitSource == .promotedFromPossible {
                // Real-WAIT recovery (preserved c80d2c4 logic, re-keyed on waitSource).
                // The promotion timer fired but a real Pre/PostToolUse arrived after,
                // so the model was working all along — flip back to THINKING.
                next.state = .thinking
                next.needsAttention = false
                next.waitSource = nil
                next.enteredStateAt = next.updatedAt
            }

        case .postToolUse:
            if event.meta.toolName == "AskUserQuestion",
               previous.state == .waiting,
               previous.waitSource == .askUserQuestion
                || previous.notificationReason == "ask_user_question" {
                // Match either typed source (Codex) or legacy reason string
                // (Claude) — entry sites diverge by agent but recovery is
                // symmetric.
                next.state = .thinking
                next.needsAttention = false
                next.notificationReason = nil
                next.waitSource = nil
                next.enteredStateAt = next.updatedAt
            } else if (event.agentKind ?? previous.agentKind) == .codex,
                      previous.state == .waiting,
                      previous.waitSource == .permission {
                next.state = .thinking
                next.needsAttention = false
                next.notificationReason = nil
                next.waitSource = nil
                next.enteredStateAt = next.updatedAt
            } else if (event.agentKind ?? previous.agentKind) == .codex,
                      previous.state == .possiblyWaiting {
                next.state = .thinking
                next.enteredStateAt = next.updatedAt
            } else if (event.agentKind ?? previous.agentKind) == .codex,
                      previous.state == .waiting,
                      previous.waitSource == .promotedFromPossible {
                next.state = .thinking
                next.needsAttention = false
                next.waitSource = nil
                next.enteredStateAt = next.updatedAt
            }

        case .subagentStop:
            // Informational; a Task subagent finished. v1.1 could surface
            // nested agent progress in the dashboard tooltip.
            break
        }

        return next
    }
}

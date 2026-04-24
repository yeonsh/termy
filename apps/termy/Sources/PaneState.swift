// PaneState.swift
//
// Per-pane state machine driven by HookEvents. ERRORED is driven by
// PtyExit (exit_code != 0) or StopFailure — NOT by PostToolUseFailure, which
// fires on routine tool errors (missing file, empty glob, Bash exit 1) that
// Claude recovers from within the same turn.
//
//   INIT      ──(UserPromptSubmit)─────▶ THINKING
//   INIT      ──(SessionStart)──────────▶ INIT         (informational; arm pane)
//   THINKING  ──(Stop)───────────────────▶ WAITING
//   THINKING  ──(SessionEnd)─────────────▶ INIT         (claude exited cleanly mid-turn)
//   THINKING  ──(PtyExit, exit_code != 0)▶ ERRORED      (crash / SIGKILL / Ctrl+C)
//   THINKING  ──(PtyExit, exit_code == 0)▶ INIT         (clean exit — rare mid-turn)
//   WAITING   ──(UserPromptSubmit)──────▶ THINKING
//   WAITING   ──(30s wall-clock timer)──▶ IDLE          (HookDaemon re-checks on wake)
//   WAITING   ──(SessionEnd | PtyExit)──▶ INIT
//   IDLE      ──(UserPromptSubmit)──────▶ THINKING
//   IDLE      ──(SessionEnd | PtyExit)──▶ INIT
//   ERRORED   ──(UserPromptSubmit)──────▶ THINKING      (user retried in same pane)
//   ERRORED   ──(Stop)───────────────────▶ WAITING       (recover-on-next-turn)
//   ERRORED   ──(SessionStart)───────────▶ INIT          (fresh claude session)
//
// Notification events do NOT change the `state` field — they toggle the
// `needsAttention` overlay on the snapshot. The dock badge shows the union
// of (state == .waiting) and (needsAttention == true).

import Foundation

enum PaneState: String, Sendable, Codable {
    case initializing = "INIT"
    case thinking     = "THINKING"
    case waiting      = "WAITING"
    case idle         = "IDLE"
    case errored      = "ERRORED"
}

/// Immutable snapshot of everything HookDaemon tracks for one pane.
struct PaneSnapshot: Sendable, Codable {
    let paneId: String
    let projectId: String?
    var state: PaneState
    var needsAttention: Bool
    var notificationReason: String?     // "permission" | "idle" | "mcp_elicit" or nil
    var lastSessionId: String?
    var lastCwd: String?
    var lastPrompt: String?              // UserPromptSubmit.prompt (truncated)
    var lastAssistantMessage: String?    // Stop.last_assistant_message (truncated)
    var updatedAt: Date
    /// Timestamp of the most recent event; used by HookDaemon to arm the
    /// WAITING → IDLE 30-second wall-clock timer.
    var enteredStateAt: Date
}

extension PaneSnapshot {
    static func empty(paneId: String, projectId: String?) -> PaneSnapshot {
        let now = Date()
        return PaneSnapshot(
            paneId: paneId,
            projectId: projectId,
            state: .initializing,
            needsAttention: false,
            notificationReason: nil,
            lastSessionId: nil,
            lastCwd: nil,
            lastPrompt: nil,
            lastAssistantMessage: nil,
            updatedAt: now,
            enteredStateAt: now
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
            // A fresh claude invocation has just started. For a pane that
            // hasn't seen a turn yet (state == .initializing), promote it to
            // IDLE so the mission-control bar shows a chip immediately —
            // users expect to SEE claude is live, not discover it only after
            // they submit a prompt. For a pane mid-work (resumed session),
            // preserve whatever state it's in.
            if previous.state == .initializing {
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
            switch previous.state {
            case .thinking, .errored:
                next.state = .waiting
            default:
                // Defensive — Stop outside THINKING means our state drifted.
                // Snap back to waiting rather than stay wrong.
                next.state = .waiting
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

        case .preToolUse:
            // Most tool uses are Claude actively doing work — stay THINKING.
            // Exception: AskUserQuestion pauses Claude until the user picks an
            // option. The user sees a blocking menu; the chip must say WAIT,
            // not THINK. (No Notification fires for AskUserQuestion in
            // practice — only PreToolUse + a delayed idle Notification ~6s
            // later, which is too slow and often doesn't come.)
            if event.meta.toolName == "AskUserQuestion" {
                next.state = .waiting
                next.needsAttention = true
                next.notificationReason = "ask_user_question"
                next.enteredStateAt = next.updatedAt
            }

        case .postToolUse:
            // When AskUserQuestion resolves (user answered), Claude resumes —
            // flip back to THINKING. Other PostToolUse events don't change
            // state; Claude continues in THINKING from whatever it was doing.
            if event.meta.toolName == "AskUserQuestion",
               previous.state == .waiting,
               previous.notificationReason == "ask_user_question" {
                next.state = .thinking
                next.needsAttention = false
                next.notificationReason = nil
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

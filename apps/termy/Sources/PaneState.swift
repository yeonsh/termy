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
//   THINKING         ──(Esc/Ctrl-C key, no 7501)────▶ IDLE (silent)
//   IDLE(key)        ──(PreToolUse)──────────────────▶ THINKING (silent; key was not an interrupt)
//   IDLE(key)        ──(PostToolUse[Failure] | Stop)─▶ IDLE (late result of the interrupted turn)
//   THINKING         ──(PtyExit, exit != 0)─────────▶ ERRORED
//   THINKING         ──(reconciler 8s silence)──────▶ POSSIBLY_WAITING (silent)
//   POSSIBLY_WAITING ──(Pre/PostToolUse)─────────────▶ THINKING       (silent recovery)
//   POSSIBLY_WAITING ──(PTY byte)────────────────────▶ THINKING       (PTY proof of life)
//   POSSIBLY_WAITING ──(Stop)────────────────────────▶ WAITING(.turnEnd)         ♪
//   POSSIBLY_WAITING ──(PermissionRequest)───────────▶ WAITING(.permission)      ♪
//   POSSIBLY_WAITING ──(AskUserQuestion)─────────────▶ WAITING(.askUserQuestion) ♪
//   POSSIBLY_WAITING ──(promote timer 12s elapsed)───▶ WAITING(.promotedFromPossible) ♪
//   WAITING          ──(UserPromptSubmit)───────────▶ THINKING
//   WAITING          ──(30s after seen)─────────────▶ IDLE
//   WAITING          ──(SessionEnd | PtyExit)───────▶ INIT
//   WAITING(.permission)         ──(PostToolUse)──▶ THINKING (Codex resumed)
//   WAITING(.askUserQuestion)    ──(PostToolUse AskUserQuestion)──▶ THINKING
//   WAITING(.promotedFromPossible) ──(Pre/PostToolUse)──▶ THINKING (recovery, c80d2c4 lineage)
//   THINKING         ──(Notification permission|mcp_elicit|idle, Claude)──▶ WAITING ♪
//   WAITING(permission|mcp_elicit) ──(PostToolUse | PostToolUseFailure)──▶ THINKING (Claude)
//   WAITING(permission|mcp_elicit) ──(Notification idle)──▶ WAITING, attention cleared (no chime)
//   IDLE      ──(UserPromptSubmit)──────▶ THINKING
//   IDLE      ──(SessionEnd | PtyExit)──▶ INIT
//   ERRORED   ──(UserPromptSubmit)──────▶ THINKING
//   ERRORED   ──(Stop)───────────────────▶ WAITING(.turnEnd)
//   ERRORED   ──(SessionStart)───────────▶ INIT
//   *(codex)  ──(SessionStart)───────────▶ IDLE          (hard reset)
//
//   *(opencode) ──(AgentStatus running)─────────────▶ THINKING
//   *(opencode) ──(AgentStatus permission|question)─▶ WAITING ♪
//   *(opencode) ──(AgentStatus succeeded)───────────▶ WAITING ♪ (→ IDLE after 30s)
//   *(opencode) ──(AgentStatus failed)──────────────▶ ERRORED
//   *(opencode) ──(AgentStatus idle)────────────────▶ IDLE (no chime)
//
//   *(7501)     ──(working)───────────────────────▶ THINKING
//   *(7501)     ──(blocked)───────────────────────▶ WAITING ♪
//   *(7501)     ──(done, turn open)───────────────▶ WAITING ♪ (→ IDLE after 30s)
//   *(7501)     ──(idle, turn open)───────────────▶ IDLE (Esc interrupt, no chime)
//   *(7501)     ──(error)─────────────────────────▶ ERRORED
//   *(7501, app=pi) shares the lines above — pi reports idle only on cancel too.
//   7501 comes from herdr-core events (hc panes) or the pane's own OSC
//   handler (local panes). While it is active, hooks fill details only.
//
// ♪ = Notifier plays a sound and raises needsAttention.
//
// POSSIBLY_WAITING is rendered as THINK in the dashboard chip — invisible to
// the user. The two-stage WAIT is documented in
// docs/superpowers/plans/2026-04-26-codex-possibly-waiting-state.md.
//
// Orthogonal to the state: `turnOpen` tracks turn boundaries
// (UserPromptSubmit / tool events open, Stop / StopFailure / SessionEnd /
// PtyExit / resets close) for the update-relaunch gate.

import Foundation

enum PaneState: String, Sendable, Codable {
    case initializing    = "INIT"
    case thinking        = "THINKING"
    case possiblyWaiting = "POSSIBLY_WAITING"
    case waiting         = "WAITING"
    case idle            = "IDLE"
    case errored         = "ERRORED"
}

extension PaneState {
    /// True for every state the UI shows as THINK. POSSIBLY_WAITING is an
    /// internal hedge the user never sees, so it renders as THINK too.
    var displaysAsThinking: Bool {
        self == .thinking || self == .possiblyWaiting
    }
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
    var notificationReason: String?     // "permission" | "idle" | "mcp_elicit" | "ask_user_question", or a raw Claude notification type (e.g. "auth_success"), or nil
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
    /// True between the start of an agent turn and its end. Opened by
    /// UserPromptSubmit and by any tool event (tools only run inside a
    /// turn — this also catches Claude continuing after a blocking Stop
    /// hook), closed by Stop / StopFailure / SessionEnd / PtyExit and by
    /// session resets. Feeds `isMidTurn`, which holds update relaunches.
    var turnOpen: Bool = false
    /// True while the program's OSC 7501 status (herdr-core events for hc panes, the pane's own OSC handler for local panes) drives this pane's state.
    /// Hooks then fill only the detail fields. Runtime-only (not in CodingKeys).
    var programStatusActive: Bool = false
    /// Last moment the user was looking at this pane (set when it becomes or
    /// stops being the viewed pane). Drives the WAIT -> IDLE countdown.
    /// Runtime-only (not in CodingKeys).
    var seenAt: Date?
    /// True while the pane sits in the IDLE that a standalone Esc/Ctrl-C keypress
    /// forced (agents with no hook for interrupts). A later Pre/PostToolUse means
    /// the guess was wrong and silently reopens THINKING; Stop keeps IDLE.
    /// Runtime-only (not in CodingKeys).
    var interruptedByKey: Bool = false

    private enum CodingKeys: String, CodingKey {
        case paneId, projectId, state, needsAttention, notificationReason, waitSource
        case lastSessionId, lastCwd, lastPrompt, lastAssistantMessage
        case updatedAt, enteredStateAt, agentKind, lastPtyActivityAt, turnOpen
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

extension PaneSnapshot {
    /// The agent is inside a turn, so restarting now would kill work that
    /// `claude --resume` / `codex resume` can't bring back. Permission and
    /// question waits count — they happen mid-turn. A Codex pane promoted
    /// to WAIT by the silence heuristic doesn't: termy already treats it as
    /// waiting for input, and a missed Codex Stop would otherwise hold an
    /// update forever. A turn closed by an Esc/Ctrl-C keypress still counts:
    /// the key may have been misdetected (Ctrl-C clearing a draft, Esc closing
    /// a popup) while the agent keeps working. Holding the update is safe — the
    /// 600 s reminder and Restart Now remain.
    var isMidTurn: Bool {
        (turnOpen || interruptedByKey)
            && state != .initializing
            && !(state == .waiting && waitSource == .promotedFromPossible)
    }
}

/// Pure state-transition function. Given the current snapshot and an
/// incoming event, returns the new snapshot. Deterministic — no I/O, no
/// timers. HookDaemon owns the idle timer separately.
enum PaneStateMachine {
    /// Notification reasons meaning Claude is blocked on the user; they gate
    /// informational-notification overwrite and the idle_prompt stale clear.
    private static let blockingReasons: Set<String> = ["permission", "mcp_elicit", "ask_user_question"]

    /// 7501 `idle`이 열린 turn을 닫는 것을 "사용자 취소"로 해석하는 앱.
    /// 둘 다 정상 종료는 `done`으로 보낸다(Claude Code 2.1.319 · pi 1.5.0 실측).
    private static let idleMeansCancelApps: Set<String> = ["claude-code", "pi"]

    /// Matches interactive user-question tools across agents:
    /// Claude Code / Codex (`AskUserQuestion`) and Antigravity (`ask_question`).
    private static func isAskUserQuestionTool(_ toolName: String?) -> Bool {
        toolName == "AskUserQuestion" || toolName == "ask_question"
    }

    /// A Post/PostToolUseFailure on a pane the user closed with Esc/Ctrl-C. Codex keeps an
    /// interrupted command running as a background terminal and reports its result when it
    /// ends (seen live: Ctrl-C during `sleep 30`, PostToolUse 30 s later), so this is the old
    /// tool finishing, not new work. The pane stays IDLE with the flag kept; only a new
    /// PreToolUse proves the key was not an interrupt.
    private static func isLateToolResultAfterInterruptKey(_ previous: PaneSnapshot) -> Bool {
        previous.interruptedByKey && previous.state == .idle
    }

    static func apply(_ event: HookEvent, to previous: PaneSnapshot) -> PaneSnapshot {
        var next = applyHookRules(event, to: previous)
        guard previous.programStatusActive else { return next }
        // 7501 owns the state: hooks keep only the detail fields, except pty/session end.
        if event.event == .ptyExit || event.event == .sessionEnd {
            next.programStatusActive = false
            return next
        }
        next.state = previous.state
        next.needsAttention = previous.needsAttention
        next.notificationReason = previous.notificationReason
        next.waitSource = previous.waitSource
        next.enteredStateAt = previous.enteredStateAt
        next.turnOpen = previous.turnOpen
        return next
    }

    /// Merges the program's 7501 status (nil = the program stopped reporting one).
    /// Re-sent identical statuses (attach/reconnect/missed resync) leave
    /// `state`/`enteredStateAt` untouched so they never re-alert.
    static func applyProgramStatus(_ status: HcStatus?, to previous: PaneSnapshot, now: Date) -> PaneSnapshot {
        var next = previous
        next.updatedAt = now
        guard let status else {
            next.programStatusActive = false
            return next
        }
        next.programStatusActive = true
        next.interruptedByKey = false
        func finish(_ state: PaneState, attention: Bool, reason: String?, source: WaitSource?, turnOpen: Bool) {
            let changed = previous.state != state
                || previous.notificationReason != reason
                || previous.waitSource != source
            next.state = state
            next.needsAttention = changed ? attention : (previous.needsAttention && attention)
            next.notificationReason = reason
            next.waitSource = source
            next.turnOpen = turnOpen
            if changed { next.enteredStateAt = now }
        }
        switch status.state {
        case "working":
            finish(.thinking, attention: false, reason: nil, source: nil, turnOpen: true)
        case "blocked":
            let source: WaitSource = status.kind == "question" ? .askUserQuestion : .permission
            finish(.waiting, attention: true, reason: status.kind ?? "permission", source: source, turnOpen: true)
        case "done", "idle":
            if status.state == "idle", previous.turnOpen, let app = status.app,
               Self.idleMeansCancelApps.contains(app) {
                // (Claude Code와 pi 전용: 둘 다 done으로 끝내고 interrupt에만 idle을 보낸다(pi 1.5.0도 정상 종료는
                // done, 취소에서만 idle). 다른 agent는 working -> idle이 정상 종료다.)
                // 열린 turn을 idle이 닫으면 사용자가 끊은 것이다(Claude는 Esc 뒤 약 70ms에 idle을 보낸다. 권한
                // 프롬프트에서도 같다). 정상 종료는 done이다. 그 pane을 보고 있는 사용자가 한 일이므로 알리지 않는다
                // (opencode interrupted와 같은 규칙). Esc에는 Stop hook이 없어 local pane도 이 경로로만 안다.
                finish(.idle, attention: false, reason: nil, source: nil, turnOpen: false)
            } else if previous.turnOpen {
                // done only ends a turn that is open; a re-sent done (attach/reconnect/resync) follows the idle rule.
                finish(.waiting, attention: false, reason: nil, source: .turnEnd, turnOpen: false)
            } else if previous.state == .waiting {
                break
            } else {
                finish(.idle, attention: false, reason: nil, source: nil, turnOpen: false)
            }
        case "error":
            finish(.errored, attention: false, reason: nil, source: nil, turnOpen: false)
        default:
            break
        }
        return next
    }

    private static func applyHookRules(_ event: HookEvent, to previous: PaneSnapshot) -> PaneSnapshot {
        var next = previous
        next.updatedAt = Date()
        next.interruptedByKey = false

        // Stamp the pane with whichever agent originated this event.
        // Synthetic events (agent="termy") return nil here and leave the
        // pane's existing kind untouched. A user switching from `claude`
        // to `codex` in the same pane will flip kind on the first event
        // from the new agent. The old agent's session id goes with it — a
        // synthetic SessionStart carries no id, and an update relaunch must
        // not resume the new agent with the previous one's id.
        if let kind = event.agentKind {
            if kind != previous.agentKind {
                next.lastSessionId = nil
            }
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
            next.turnOpen = false
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
            // Codex / Antigravity panes: hard-reset to IDLE regardless of
            // prior state. Neither has a native SessionEnd hook event —
            // Phase 4's foreground-process detector synthesizes one but can
            // miss edges (rapid-fire `/exit` + relaunch, daemon restart).
            // Treating every Codex / Antigravity SessionStart as a clean
            // reset stops stale THINK/WAIT chips from surviving across
            // sessions.
            //
            // Claude panes: only promote from .initializing. Mid-work
            // sessions (resume after compact, etc.) keep their state so
            // the dashboard doesn't flicker on every plugin handshake.
            //
            // opencode is deliberately in the Claude group, not the
            // hard-reset one: `opencode -c --prompt …` can start working
            // before the watcher's synthetic SessionStart arrives (up to 1s
            // late), and a hard reset would overwrite the plugin's THINK.
            // The plugin syncs stale chips itself when it starts.
            let resolvedKind = event.agentKind ?? previous.agentKind
            if resolvedKind == .codex || resolvedKind == .antigravity {
                next.state = .idle
                next.needsAttention = false
                next.notificationReason = nil
                next.enteredStateAt = next.updatedAt
                next.turnOpen = false
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
            next.turnOpen = true

        case .preInvocation:
            // Antigravity fires PreInvocation before each model call (both on
            // initial user prompt and when continuing after tool execution).
            next.needsAttention = false
            next.notificationReason = nil
            next.waitSource = nil
            next.turnOpen = true
            if previous.state != .thinking {
                next.state = .thinking
                next.enteredStateAt = next.updatedAt
            }

        case .postInvocation:
            // Antigravity fires PostInvocation when a batch of tool calls
            // finishes. Keep the turn open and promote INIT/IDLE to THINKING.
            next.turnOpen = true
            if previous.state == .initializing || previous.state == .idle {
                next.state = .thinking
                next.enteredStateAt = next.updatedAt
            }

        case .stop:
            let resolvedKind = event.agentKind ?? previous.agentKind
            next.lastAssistantMessage = event.meta.lastAssistantMessage
            next.turnOpen = false
            if previous.interruptedByKey && previous.state == .idle && resolvedKind != .claude {
                // Codex may send Stop for an interrupted turn too: stay IDLE, no chime.
                // Claude never sends Stop after an interrupt, so its Stop means the key
                // misfired and the turn really ended: take the normal path.
            } else if resolvedKind == .antigravity, event.meta.reason == "ERROR" {
                next.state = .errored
                next.waitSource = nil
                next.enteredStateAt = next.updatedAt
            } else if resolvedKind == .antigravity,
                      event.meta.reason == "TERMINAL_STEP_TYPE",
                      previous.state == .waiting,
                      previous.notificationReason == "ask_user_question" {
                // PreToolUse(ask_question) already transitioned this pane to
                // WAITING with needsAttention = true. Preserve the existing
                // WAITING state and enteredStateAt so Notifier doesn't chime
                // a second time when Stop(TERMINAL_STEP_TYPE) follows.
                next.state = .waiting
                next.needsAttention = true
                next.notificationReason = "ask_user_question"
            } else {
                next.state = .waiting
                // waitSource is the Codex-only typed reason (see PaneState.swift).
                // Claude and Antigravity paths leave it nil and continue using
                // notificationReason for legacy reason strings; Notifier reads
                // waitSource as Codex, so tagging non-Codex WAITs with .turnEnd
                // would mis-attribute the notification copy.
                if resolvedKind == .codex {
                    next.waitSource = .turnEnd
                }
                next.enteredStateAt = next.updatedAt
            }

        case .stopFailure:
            // Abnormal turn termination (rate-limit, mid-turn crash). Unlike
            // PostToolUseFailure, this really does end the turn.
            next.state = .errored
            next.enteredStateAt = next.updatedAt
            next.turnOpen = false

        case .postToolUseFailure:
            // Per-tool failure is NOT a pane-level error. Claude routinely
            // recovers from Read-missing-file, Glob-no-matches, Bash-exit-1
            // and continues the turn. Flipping to ERRORED on every such tool
            // failure makes the dashboard lie ("ERR" on a pane that's still
            // THINKING). Keep the state unchanged — except that an approved
            // Claude tool that then fails proves the dialog was answered.
            if Self.isLateToolResultAfterInterruptKey(previous) {
                next.interruptedByKey = true
                next.turnOpen = false
                break
            }
            next.turnOpen = true
            if (event.agentKind ?? previous.agentKind) == .claude,
               previous.state == .waiting,
               previous.notificationReason == "permission"
                || previous.notificationReason == "mcp_elicit" {
                next.state = .thinking
                next.needsAttention = false
                next.notificationReason = nil
                next.enteredStateAt = next.updatedAt
            }

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
            next.turnOpen = false

        case .notification:
            let reason = event.meta.notificationReason
            switch reason {
            case "idle":
                // Claude sends idle_prompt only once the turn is over (no
                // turn, no dialog, no background agents, ~60s after the last
                // query) and only if the user hasn't touched the pane since.
                // It does NOT follow an Esc interrupt — the Esc keypress
                // counts as interaction (verified live, Claude Code 2.1.296),
                // so without 7501 an interrupted turn stays open until the next prompt (7501 idle closes it);
                // UpdateRelaunchGate's menu escape and reminder cover that.
                // A pane still THINKING here missed its Stop some other way,
                // so surface WAIT — the Notifier chimes on entering it. Any
                // other state already reflects an ended turn: leave
                // state/attention alone (no second chime). idle_prompt is
                // only sent with no dialog on screen, so a WAIT still carrying
                // a blocking reason is stale: clear attention, keep state,
                // no chime.
                next.turnOpen = false
                // enteredStateAt restarts: idle_prompt lands >=60s after the
                // dismissal, and tickIdle's sleep/wake guard (since < 120)
                // would otherwise never move the stale WAIT to IDLE.
                if previous.state == .waiting,
                   let r = previous.notificationReason, Self.blockingReasons.contains(r) {
                    next.needsAttention = false
                    next.notificationReason = nil
                    next.enteredStateAt = next.updatedAt
                } else if previous.state == .thinking {
                    next.state = .waiting
                    next.needsAttention = true
                    next.notificationReason = "idle"
                    next.enteredStateAt = next.updatedAt
                }
            case "permission", "mcp_elicit":
                // Claude is paused on the user (permission prompt, MCP
                // elicitation): "THINKING while waiting on me" is a lie, and
                // so is "IDLE while waiting on me" (the 30s WAITING→IDLE timer
                // can fire while a notification is outstanding), so flip to
                // WAITING. The turn is still open.
                next.needsAttention = true
                next.notificationReason = reason
                if previous.state == .thinking || previous.state == .idle {
                    next.state = .waiting
                    next.enteredStateAt = next.updatedAt
                }
            default:
                // `auth_success` and unknown reasons preserve state since
                // Claude continues on its own. Informational ones (e.g.
                // elicitation_response, agent_completed) arriving while a
                // blocking WAIT is outstanding must not overwrite its
                // reason, or PostToolUse recovery would no longer match.
                if previous.state == .waiting,
                   let r = previous.notificationReason, Self.blockingReasons.contains(r) {
                    break
                }
                next.needsAttention = true
                next.notificationReason = reason
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

        case .agentStatus:
            Self.applyAgentStatus(event.meta.reason, to: &next)

        case .preToolUse:
            next.turnOpen = true
            if Self.isAskUserQuestionTool(event.meta.toolName) {
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
            } else if previous.interruptedByKey && previous.state == .idle {
                // The key was not an interrupt after all: the agent is still working.
                next.state = .thinking
                next.enteredStateAt = next.updatedAt
            }

        case .postToolUse:
            if Self.isLateToolResultAfterInterruptKey(previous) {
                next.interruptedByKey = true
                next.turnOpen = false
                break
            }
            next.turnOpen = true
            if Self.isAskUserQuestionTool(event.meta.toolName),
               previous.state == .waiting,
               previous.waitSource == .askUserQuestion
                || previous.notificationReason == "ask_user_question" {
                // Match either typed source (Codex) or legacy reason string
                // (Claude / Antigravity) — entry sites diverge by agent but
                // recovery is symmetric.
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
            } else if (event.agentKind ?? previous.agentKind) == .claude,
                      previous.state == .waiting,
                      previous.notificationReason == "permission"
                        || previous.notificationReason == "mcp_elicit" {
                // Claude has no PermissionRequest-style resolve event; a
                // PostToolUse is the best signal the dialog was answered.
                // PreToolUse is not (a parallel tool's can arrive while it is
                // still up); a parallel tool's PostToolUse can too, which we
                // accept because the WAIT chime already played.
                next.state = .thinking
                next.needsAttention = false
                next.notificationReason = nil
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

    /// Level-triggered opencode status. The plugin sends the current phase,
    /// so every known reason overwrites the table's fields; only
    /// `enteredStateAt` depends on whether this is a fresh entry. Compare
    /// against `next`, not `previous`: a session-id change has already reset
    /// the snapshot to INIT, and that counts as a fresh entry.
    private static func applyAgentStatus(_ reason: String?, to next: inout PaneSnapshot) {
        switch reason {
        case "running":
            let entered = next.state != .thinking
            next.state = .thinking
            next.needsAttention = false
            next.notificationReason = nil
            next.waitSource = nil
            next.turnOpen = true
            if entered { next.enteredStateAt = next.updatedAt }

        case "permission":
            let entered = !(next.state == .waiting && next.notificationReason == "permission")
            next.state = .waiting
            next.needsAttention = true
            next.notificationReason = "permission"
            next.waitSource = nil
            next.turnOpen = true
            if entered { next.enteredStateAt = next.updatedAt }

        case "question":
            let entered = !(next.state == .waiting && next.notificationReason == "ask_user_question")
            next.state = .waiting
            next.needsAttention = true
            next.notificationReason = "ask_user_question"
            next.waitSource = nil
            next.turnOpen = true
            if entered { next.enteredStateAt = next.updatedAt }

        case "succeeded":
            // Refresh the timestamp unless this is already a silent
            // turn-end WAIT. A permission/question wait that jumps straight
            // to succeeded must restart the 30s IDLE timer: the old
            // timestamp can be >120s old, which HookDaemon.tickIdle treats
            // as a sleep/wake gap and never expires.
            let entered = !(next.state == .waiting && next.notificationReason == nil)
            next.state = .waiting
            next.needsAttention = false
            next.notificationReason = nil
            next.waitSource = nil
            next.turnOpen = false
            if entered { next.enteredStateAt = next.updatedAt }

        case "failed":
            let entered = next.state != .errored
            next.state = .errored
            next.needsAttention = false
            next.notificationReason = nil
            next.waitSource = nil
            next.turnOpen = false
            if entered { next.enteredStateAt = next.updatedAt }

        case "idle":
            let entered = next.state != .idle
            next.state = .idle
            next.needsAttention = false
            next.notificationReason = nil
            next.waitSource = nil
            next.turnOpen = false
            if entered { next.enteredStateAt = next.updatedAt }

        default:
            // Unknown reason: leave the snapshot untouched. Lets a newer
            // plugin vocabulary coexist with an older termy.
            break
        }
    }
}

extension PaneSnapshot {
    /// Start of the 30s WAIT -> IDLE countdown, or nil if the user has not
    /// seen this WAIT yet. Viewed now: counts from the later of entry and
    /// the last sighting. Not viewed: counts only from a sighting made at or
    /// after entry (i.e. the user looked, then left).
    func idleCountdownStart(isViewed: Bool) -> Date? {
        if isViewed { return max(enteredStateAt, seenAt ?? .distantPast) }
        if let seenAt, seenAt >= enteredStateAt { return seenAt }
        return nil
    }
}

// termy-managed opencode plugin. termy rewrites this file; do not edit.
import { spawn } from "node:child_process"

const TERMY_HOOK_PATH = "__TERMY_HOOK_PATH__"

// #region termy-pure
// Phase of the routed root session. Same precedence as opencode's own tab
// badge (packages/tui/src/context/session-tabs.tsx:164-173).
function termyPhase(view) {
  if (!view.sessionID) return "idle"
  if (view.permission) return "permission"
  if (view.question) return "question"
  if (view.busy) return "running"
  return "idle"
}

// Wire reason to send when the phase moves from prev to cur, or null.
// prev/cur: { sessionID: string | null, phase }. outcome: the last
// execution outcome recorded for cur.sessionID, if any.
function termyEmission(prev, cur, outcome) {
  if (prev && prev.sessionID === cur.sessionID && prev.phase === cur.phase) return null
  if (cur.phase !== "idle") return cur.phase
  const wasActive = prev && prev.sessionID === cur.sessionID && prev.phase !== "idle"
  if (wasActive && outcome === "succeeded") return "succeeded"
  if (wasActive && outcome === "failed") return "failed"
  return "idle"
}

// What the routed root session looks like right now. Reads only the plugin
// context, so tests can pass a fake ctx.
// gstack-shortcut(dec-1fde11b6): routed root session only, background tabs ignored; upgrade when users report missed background-tab prompts
function termyView(ctx) {
  const route = ctx.ui.router.current()
  if (route.type !== "session") return { sessionID: null }
  const root = ctx.data.session.root(route.sessionID)
  const ids = [...new Set([root, ...ctx.data.session.family(root)])]
  return {
    sessionID: root,
    permission: ids.some((id) => (ctx.data.session.permission.list(id)?.length ?? 0) > 0),
    question: ids.some((id) => (ctx.data.session.form.list(id)?.length ?? 0) > 0),
    busy: ids.some((id) =>
      ctx.data.session.status(id) === "running" ||
      ctx.data.session.pending.list(id).some((item) => item.type !== "synthetic")),
    cwd: ctx.data.session.get(root)?.location?.directory,
  }
}

// stdin JSON for termy-hook. termy-hook reads stdin with one
// availableData call, so the payload stays below PIPE_BUF (512 bytes):
// cwd is dropped when keeping it would pass 480 bytes.
function termyPayload(reason, view, fallbackCwd) {
  const base = { reason, ...(view.sessionID ? { session_id: view.sessionID } : {}) }
  const full = JSON.stringify({ ...base, cwd: view.cwd ?? fallbackCwd })
  return termyUtf8Length(full) <= 480 ? full : JSON.stringify(base)
}

function termyUtf8Length(text) {
  return unescape(encodeURIComponent(text)).length
}
// #endregion termy-pure

export default {
  id: "termy",
  setup(ctx) {
    if (!process.env.TERMY_PANE_ID) return
    const outcomes = new Map()
    let prev = null
    let scheduled = false
    let queue = Promise.resolve()

    const send = (reason, v) => {
      const payload = termyPayload(reason, v, process.cwd())
      queue = queue.then(() => new Promise((resolve) => {
        try {
          const child = spawn(TERMY_HOOK_PATH, ["--agent", "opencode", "AgentStatus"], {
            stdio: ["pipe", "ignore", "ignore"],
          })
          const timer = setTimeout(resolve, 2000)
          const done = () => { clearTimeout(timer); resolve() }
          child.on("error", done)
          child.on("exit", done)
          child.stdin.on("error", () => {})
          child.stdin.end(payload)
        } catch { resolve() }
      }))
    }

    const derive = () => {
      scheduled = false
      try {
        const v = termyView(ctx)
        const cur = { sessionID: v.sessionID, phase: termyPhase(v) }
        const reason = termyEmission(prev, cur, cur.sessionID ? outcomes.get(cur.sessionID) : undefined)
        prev = cur
        if (reason) send(reason, v)
      } catch {}
    }
    const schedule = () => {
      if (scheduled) return
      scheduled = true
      setTimeout(derive, 0)
    }
    const record = (outcome) => (event) => {
      try {
        const id = event.data.sessionID
        if (ctx.data.session.root(id) === id) outcomes.set(id, outcome)
      } catch {}
    }

    const offs = [
      ctx.data.on("session.execution.started", (event) => { outcomes.delete(event.data.sessionID) }),
      ctx.data.on("session.execution.succeeded", record("succeeded")),
      ctx.data.on("session.execution.failed", record("failed")),
      ctx.data.on("session.execution.interrupted", record("interrupted")),
      ctx.data.listen(schedule),
    ]
    const interval = setInterval(schedule, 1000)
    schedule()
    return () => {
      clearInterval(interval)
      for (const off of offs) off()
    }
  },
}

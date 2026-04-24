// termy-hook — tiny CLI invoked by Claude Code via ~/.claude/settings.json
// hooks. Reads the hook event name from argv[1] and CC's JSON payload from
// stdin, slims the payload, and writes ONE JSON line to the termy daemon's
// Unix-domain socket at /tmp/termy-$UID.sock. Always exits 0 — must never
// hang or fail CC.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Config

/// 100ms write budget is fine for a compiled Swift binary (~5ms cold start).
/// Budget covers: connect + send + close.
let writeDeadline: TimeInterval = 0.1

/// Fields we forward to the daemon. Dropping the rest keeps events.jsonl
/// small — raw SessionStart with an active plugin can be >150KB.
/// Keys match HookEvent.Meta in the host app.
let forwardedKeys: Set<String> = [
    "session_id", "cwd", "source", "reason",
    "prompt", "last_assistant_message", "stop_hook_active",
    "tool_name", "tool_use_id", "tool_input",
    "exit_code"
]
/// Hard cap per string field — CC payloads sometimes include prompts or
/// assistant messages in the 10-100KB range. Truncate for the wire.
let maxStringBytes = 4096

// MARK: - Helpers

func socketPath() -> String {
    "/tmp/termy-\(getuid()).sock"
}

/// Slim a payload dict down to our forwarded keys, truncating big strings.
///
/// Note: the daemon's HookEvent.Meta types every forwarded field as
/// `String?` for simplicity on the Swift side. CC sometimes sends
/// structured objects (e.g. `tool_input` for PreToolUse / PostToolUse is
/// a dict like `{"command": "echo hi", "description": "..."}`). We must
/// coerce non-string values to a JSON-encoded string BEFORE shipping, or
/// the daemon's Codable decoder crashes and the event is dropped.
func slim(_ raw: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for key in forwardedKeys {
        guard let value = raw[key] else { continue }
        out[key] = coerceToString(value)
    }
    return out
}

/// Coerce any Foundation-JSON-decoded value to a String for the wire.
/// The daemon types every forwarded `meta` field as `String?`, so we must
/// flatten here — and we MUST NOT throw or abort, no matter what CC fed us.
///
/// Crash observed in the wild: `JSONSerialization.data(withJSONObject:)`
/// raises an NSException when passed a scalar top-level (bool/number/null).
/// We guard with `isValidJSONObject` first, and fall back to
/// `String(describing:)` for anything else.
func coerceToString(_ value: Any) -> String {
    if let s = value as? String {
        return String(s.prefix(maxStringBytes))
    }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value, options: []),
       let json = String(data: data, encoding: .utf8) {
        return String(json.prefix(maxStringBytes))
    }
    // Booleans, numbers, NSNull, everything else.
    return String(describing: value).prefix(maxStringBytes).description
}

/// Connect + write + close, all under the deadline. Any failure is silent.
func send(_ line: Data, to path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }

    // Non-blocking so we can enforce a write deadline via select().
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
    withUnsafeMutablePointer(to: &addr.sun_path) { dest in
        dest.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
            _ = bytes.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!, src.count)
            }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)

    // connect() may return EINPROGRESS on a non-blocking socket; wait on it
    // with select() bounded by our deadline.
    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
            connect(fd, s, len)
        }
    }
    if connectResult != 0 && errno != EINPROGRESS {
        return
    }
    if connectResult != 0 {
        var writeSet = fd_set()
        fdSetZero(&writeSet)
        fdSet(fd, &writeSet)
        var tv = timeval(
            tv_sec: Int(writeDeadline),
            tv_usec: Int32((writeDeadline - floor(writeDeadline)) * 1_000_000)
        )
        if select(fd + 1, nil, &writeSet, nil, &tv) <= 0 {
            return
        }
        var soErr: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &errLen)
        if soErr != 0 { return }
    }

    // Write. Loop until all bytes sent or deadline hit.
    let start = Date()
    var remaining = line
    while !remaining.isEmpty {
        if Date().timeIntervalSince(start) > writeDeadline { return }
        let n = remaining.withUnsafeBytes { buf -> Int in
            guard let ptr = buf.baseAddress else { return -1 }
            return write(fd, ptr, remaining.count)
        }
        if n > 0 {
            remaining = remaining.subdata(in: n..<remaining.count)
        } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            // Kernel buffer full; wait briefly.
            var ws = fd_set()
            fdSetZero(&ws)
            fdSet(fd, &ws)
            var tv = timeval(tv_sec: 0, tv_usec: 10_000)
            if select(fd + 1, nil, &ws, nil, &tv) <= 0 { return }
        } else {
            return
        }
    }
}

// fd_set helpers — Swift lacks the C macros.
func fdSetZero(_ set: UnsafeMutablePointer<fd_set>) {
    memset(set, 0, MemoryLayout<fd_set>.size)
}
func fdSet(_ fd: Int32, _ set: UnsafeMutablePointer<fd_set>) {
    let intOffset = Int(fd / 32)
    let bitOffset = fd % 32
    let mask: Int32 = 1 << bitOffset
    withUnsafeMutableBytes(of: &set.pointee.fds_bits) { bytes in
        let words = bytes.bindMemory(to: Int32.self)
        words[intOffset] |= mask
    }
}

// MARK: - main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    // No event name; bail silently (CC shouldn't ever call us this way).
    exit(0)
}
let eventName = arguments[1]

// Read stdin with a tight timeout so we never block CC.
let stdinData: Data = {
    let handle = FileHandle.standardInput
    // availableData returns immediately with whatever's buffered; if CC fed us
    // a payload it's already there by the time we run.
    return handle.availableData
}()

let parsedStdin: [String: Any] = {
    guard !stdinData.isEmpty else { return [:] }
    if let obj = try? JSONSerialization.jsonObject(with: stdinData, options: [.allowFragments]) as? [String: Any] {
        return obj
    }
    return [:]
}()

let env = ProcessInfo.processInfo.environment
let paneId = env["TERMY_PANE_ID"]
let projectId = env["TERMY_PROJECT_ID"]

let meta = slim(parsedStdin)

var payload: [String: Any] = [
    "event": eventName,
    "pane_id": paneId as Any? ?? NSNull(),
    "project_id": projectId as Any? ?? NSNull(),
    "ts": Date().timeIntervalSince1970,
    "agent": "claude-code",
    "meta": meta
]

guard let line = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else {
    exit(0)
}
var withNewline = line
withNewline.append(0x0A)

send(withNewline, to: socketPath())
exit(0)

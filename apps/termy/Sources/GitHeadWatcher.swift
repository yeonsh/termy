// GitHeadWatcher.swift
//
// Watches `.git/HEAD` for the pane's current work tree so `git checkout`,
// `git switch`, and detached-HEAD jumps refresh the pane header + dashboard
// chip immediately. OSC 7 can't cover this on its own because branch
// switches don't change the cwd.
//
// Implementation: DispatchSourceFileSystemObject on the resolved HEAD file.
// Git rewrites HEAD atomically (temp file + rename), so on `.rename`/
// `.delete` the fd detaches — we re-resolve and re-arm after every fire.
// Events are debounced ~120ms because a single operation often triggers
// multiple writes (HEAD, ORIG_HEAD, config).
//
// Worktrees and submodules store `.git` as a plain file whose first line is
// `gitdir: <path>`. Resolver follows that to the real HEAD.

import Foundation

@MainActor
final class GitHeadWatcher {
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private var watchedCwd: String?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
        debounceTask?.cancel()
    }

    /// Start (or re-start) watching the HEAD that governs `cwd`. No-op when
    /// cwd isn't inside a git repo — the pane still works, just without
    /// live branch updates (there's nothing to update).
    func watch(cwd: String) {
        watchedCwd = cwd
        rearm()
    }

    func stop() {
        source?.cancel()
        source = nil
        debounceTask?.cancel()
        debounceTask = nil
        watchedCwd = nil
    }

    private func rearm() {
        source?.cancel()
        source = nil
        guard let cwd = watchedCwd,
              let headPath = Self.headPath(for: cwd) else { return }
        let fd = open(headPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.scheduleFire()
        }
        src.setCancelHandler {
            close(fd)
        }
        src.resume()
        source = src
    }

    private func scheduleFire() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            self.onChange()
            // HEAD may have been replaced (atomic rename) — re-open on the
            // new inode so we keep receiving events.
            self.rearm()
        }
    }

    /// Resolves the actual HEAD file for `cwd`. Walks up looking for `.git`;
    /// if `.git` is a directory, HEAD is inside it; if `.git` is a file with
    /// a `gitdir: …` redirect (worktrees / submodules), follows that.
    private static func headPath(for cwd: String) -> String? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: cwd, isDirectory: true).resolvingSymlinksInPath()
        while url.path != "/" {
            let gitPath = url.appendingPathComponent(".git").path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    return (gitPath as NSString).appendingPathComponent("HEAD")
                }
                if let redirected = resolveGitdirFile(at: gitPath) {
                    return (redirected as NSString).appendingPathComponent("HEAD")
                }
                return nil
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Parse `gitdir: <path>` from a `.git` file. Path may be relative to the
    /// file's directory (standard for git worktrees).
    private static func resolveGitdirFile(at path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard firstLine.hasPrefix("gitdir:") else { return nil }
        let rel = firstLine.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if rel.hasPrefix("/") { return rel }
        let base = (path as NSString).deletingLastPathComponent
        return (base as NSString).appendingPathComponent(rel)
    }
}

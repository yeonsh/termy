// GitBranch.swift
//
// Tiny git-branch lookup for pane headers. Runs `git -C <cwd> symbolic-ref
// --short HEAD` with a short timeout; returns nil outside a repo, returns
// the branch name on success, returns a shortened SHA on detached HEAD.
//
// This is called (a) once per pane at spawn time with the initial cwd, and
// (b) again whenever SwiftTerm's OSC 7 delegate reports a cwd change (i.e.
// the user `cd`d somewhere inside the pane).

import Foundation

enum GitBranch {
    /// Synchronous — runs off the main actor via Task.detached at the call
    /// site. Returns nil if cwd isn't a git repo, git isn't installed, or
    /// the process times out.
    static func branch(for cwd: String) -> String? {
        guard FileManager.default.fileExists(atPath: cwd) else { return nil }

        // Fast path: not a git repo → bail without spawning git.
        if findGitDir(startingAt: cwd) == nil { return nil }

        if let name = runGit(["-C", cwd, "symbolic-ref", "--short", "HEAD"]) {
            return name
        }
        // Detached HEAD — show short SHA so the header still carries info.
        if let sha = runGit(["-C", cwd, "rev-parse", "--short", "HEAD"]) {
            return sha
        }
        return nil
    }

    /// Walk parents looking for a `.git` entry (file or dir). Cheaper than
    /// shelling out to `git rev-parse --is-inside-work-tree` for the common
    /// case of non-repo directories.
    private static func findGitDir(startingAt path: String) -> String? {
        var current = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let fm = FileManager.default
        while current.path != "/" {
            let candidate = current.appendingPathComponent(".git").path
            if fm.fileExists(atPath: candidate) { return candidate }
            current.deleteLastPathComponent()
        }
        return nil
    }

    /// Git work-tree root for `cwd`, or nil outside a repo. Used to derive
    /// the pane's project label — we want "api" when cwd is
    /// "~/code/api/src/middleware", not "middleware".
    static func workTreeRoot(for cwd: String) -> String? {
        var current = URL(fileURLWithPath: cwd, isDirectory: true).resolvingSymlinksInPath()
        let fm = FileManager.default
        while current.path != "/" {
            let candidate = current.appendingPathComponent(".git").path
            if fm.fileExists(atPath: candidate) { return current.path }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private static func runGit(_ args: [String]) -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/git"
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }

        // 500ms timeout — branch lookup should be near-instant, but a
        // broken git config could hang and we must not block pane spawn.
        let deadline = Date().addingTimeInterval(0.5)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }

        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.availableData
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }
}

// ProjectIdentityTests.swift
//
// Covers the canonical-path keying story. `derive(for:)` returns a basename
// for display — collisions between unrelated repos are expected there.
// `canonicalPath(for:)` is the new persistence key and MUST NOT collide on
// same-basename inputs.

import XCTest
@testable import termy

final class ProjectIdentityTests: XCTestCase {

    /// Helper: build a throwaway git repo at `path/<name>` with a .git dir.
    private func makeRepo(in root: URL, named name: String) -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        let git = repo.appendingPathComponent(".git", isDirectory: true)
        try? FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        return repo
    }

    /// Helper: write a `.git` FILE at `path/<name>` (that's how git worktrees
    /// announce themselves — the worktree dir contains a regular file named
    /// `.git`, not a directory).
    private func makeWorktree(in root: URL, named name: String) -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = repo.appendingPathComponent(".git")
        try? Data("gitdir: /whatever\n".utf8).write(to: git)
        return repo
    }

    private func tempRoot() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("termy-projid-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - canonicalPath does NOT collide on same basename

    func test_canonicalPath_doesNotCollideOnSameBasename() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let a = makeRepo(in: root.appendingPathComponent("code"), named: "api")
        let b = makeRepo(in: root.appendingPathComponent("other"), named: "api")

        try? FileManager.default.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = makeRepo(in: root.appendingPathComponent("code"), named: "api")
        _ = makeRepo(in: root.appendingPathComponent("other"), named: "api")

        let keyA = ProjectIdentity.canonicalPath(for: a.path)
        let keyB = ProjectIdentity.canonicalPath(for: b.path)
        XCTAssertNotEqual(keyA, keyB, "two `api` repos in different parents must have distinct persistence keys")
        // Display label still collides (intentional).
        XCTAssertEqual(ProjectIdentity.derive(for: a.path), ProjectIdentity.derive(for: b.path))
    }

    // MARK: - canonicalPath resolves symlinks

    func test_canonicalPath_resolvesSymlinks() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let real = makeRepo(in: root, named: "real-api")
        let link = root.appendingPathComponent("link-api")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let keyReal = ProjectIdentity.canonicalPath(for: real.path)
        let keyLink = ProjectIdentity.canonicalPath(for: link.path)
        XCTAssertEqual(keyReal, keyLink, "symlinked path must resolve to the same persistence key")
    }

    // MARK: - canonicalPath picks up a cwd inside a repo

    func test_canonicalPath_cwdInsideRepo_returnsRepoRoot() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = makeRepo(in: root, named: "api")
        let nested = repo.appendingPathComponent("src/billing", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        // Resolving both paths via realpath because tempDir may contain symlinks (/var → /private/var on macOS).
        let expected = URL(fileURLWithPath: repo.path, isDirectory: true).resolvingSymlinksInPath().path
        XCTAssertEqual(ProjectIdentity.canonicalPath(for: nested.path), expected)
    }

    // MARK: - canonicalPath on a worktree (.git FILE, not dir)

    func test_canonicalPath_worktree_hasDistinctKeyFromMainRepo() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let main = makeRepo(in: root, named: "api")
        let wt = makeWorktree(in: root, named: "api-worktree")

        let keyMain = ProjectIdentity.canonicalPath(for: main.path)
        let keyWT = ProjectIdentity.canonicalPath(for: wt.path)
        XCTAssertNotEqual(keyMain, keyWT, "a worktree must have a distinct persistence key from its main repo")
    }
}

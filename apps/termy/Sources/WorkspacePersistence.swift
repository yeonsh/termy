// WorkspacePersistence.swift
//
// Serial writer for per-project workspace files under
// `~/Library/Application Support/termy/workspaces/`. Every save is an atomic
// temp+rename so a mid-write crash can never leave a half-written JSON
// behind. Filenames are hashed from the canonical worktree path, making
// them fixed-size and immune to path-traversal on project names with
// slashes, nulls, or `..` segments.
//
// Schema-version safety:
//   On read, `load(canonicalPath:)` probes the `schemaVersion` field before
//   a full decode. Anything newer than `WorkspaceRecord.currentSchemaVersion`
//   gets moved to `_quarantine/<hash>-v<N>.json` and read returns nil —
//   the caller treats the project as "no saved layout" rather than
//   corrupting state with a partial decode. A corrupt or undecodable file
//   takes the same path (quarantined with `-corrupt` suffix) so users who
//   notice data loss have a recoverable on-disk artifact.
//
// Not yet covered here (explicit follow-ups from the /autoplan Eng review):
//   * Two-instance protection via `flock`/`O_EXLOCK` — deferred; last-writer
//     wins between concurrent termy.app processes today. Documented risk.
//   * Debounce — the actor itself has none; debouncing lives one layer up,
//     in the mutation observer that decides when to call `save(...)`.
//   * Flush on `applicationWillTerminate` — requires the MainActor call
//     site to `await` a synchronous flush before NSApp terminates. Wired
//     in at integration time, not here.

import Foundation
import CryptoKit

enum WorkspacePersistenceError: Error {
    case directoryCreateFailed(Error)
    case writeFailed(Error)
    case renameFailed(POSIXErrorCode)
    case encodeFailed(Error)
}

/// Result of loading a workspace file. `.missing` and `.quarantined` both
/// return nil from the public `load()` API, but are distinguished here for
/// callers that want to surface "your layout was archived" UI.
enum WorkspaceLoadOutcome {
    case loaded(WorkspaceRecord)
    case missing
    case quarantined(reason: String, archivedAt: URL)
}

actor WorkspacePersistence {

    // MARK: - Dirs

    // Immutable after init; `nonisolated` so callers can read without hopping
    // onto the actor's serial executor just to look up a path.
    nonisolated let rootDir: URL
    nonisolated let quarantineDir: URL

    static var defaultRootDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("termy", isDirectory: true)
            .appendingPathComponent("workspaces", isDirectory: true)
    }

    init(rootDir: URL = WorkspacePersistence.defaultRootDir) throws {
        self.rootDir = rootDir
        self.quarantineDir = rootDir.appendingPathComponent("_quarantine", isDirectory: true)

        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: rootDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fm.createDirectory(
                at: quarantineDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw WorkspacePersistenceError.directoryCreateFailed(error)
        }
    }

    // MARK: - Filename hashing

    /// Fixed-length hex filename derived from the SHA-256 of the canonical
    /// path. Path-traversal-proof by construction — the user's project name
    /// never appears on disk as a filename component.
    nonisolated func filename(for canonicalPath: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32)) + ".json"
    }

    nonisolated func fileURL(for canonicalPath: String) -> URL {
        rootDir.appendingPathComponent(filename(for: canonicalPath))
    }

    // MARK: - Save

    /// Atomic write: encode → write to temp → `rename(2)` into place.
    /// Sets `0600` on the final file so attacker-writable semantics match
    /// `HookDaemon`'s socket/journal discipline.
    func save(_ record: WorkspaceRecord) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(record)
        } catch {
            throw WorkspacePersistenceError.encodeFailed(error)
        }

        let finalURL = fileURL(for: record.canonicalPath)
        let tempURL = rootDir.appendingPathComponent(".tmp-\(UUID().uuidString).json")

        do {
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tempURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw WorkspacePersistenceError.writeFailed(error)
        }

        // rename(2) is atomic within a filesystem. If this fails (ENOSPC,
        // permissions flip, etc.) the previous file at `finalURL` is
        // preserved untouched and the temp is cleaned up.
        let ok = rename(tempURL.path, finalURL.path)
        if ok != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: tempURL)
            throw WorkspacePersistenceError.renameFailed(code)
        }
    }

    // MARK: - Load

    /// Read the workspace for `canonicalPath`. Returns `.missing` if no file
    /// exists, `.quarantined` if it existed but was archived (corrupt or
    /// newer-than-known schema), `.loaded(record)` on success.
    func load(canonicalPath: String) -> WorkspaceLoadOutcome {
        let url = fileURL(for: canonicalPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: url) else {
            return quarantine(file: url, reason: "unreadable")
        }

        // Probe the schemaVersion before a full decode so we can recognize
        // files from a future termy version without misinterpreting them.
        struct Probe: Codable { let schemaVersion: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            return quarantine(file: url, reason: "undecodable")
        }
        if probe.schemaVersion > WorkspaceRecord.currentSchemaVersion {
            return quarantine(file: url, reason: "v\(probe.schemaVersion)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(WorkspaceRecord.self, from: data) else {
            return quarantine(file: url, reason: "decode-failed")
        }
        return .loaded(record)
    }

    /// Archive a file to `_quarantine/<basename>-<reason>.json`. Best effort —
    /// if the move fails we still return a `.quarantined` outcome because
    /// from the caller's perspective the file should be treated as unusable.
    @discardableResult
    private func quarantine(file: URL, reason: String) -> WorkspaceLoadOutcome {
        let base = file.deletingPathExtension().lastPathComponent
        let dest = quarantineDir.appendingPathComponent("\(base)-\(reason).json")
        try? FileManager.default.moveItem(at: file, to: dest)
        return .quarantined(reason: reason, archivedAt: dest)
    }

    // MARK: - Enumerate (for ⌘K index)

    /// List every known workspace record. Used by `ProjectSwitcherPanel` to
    /// render the fuzzy-search list. Sorted by `updatedAt` descending so
    /// recently-used projects appear first.
    func all() -> [WorkspaceRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [WorkspaceRecord] = []
        records.reserveCapacity(entries.count)
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(WorkspaceRecord.self, from: data) else {
                continue
            }
            records.append(record)
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Delete (for test cleanup + future "forget project" UX)

    func delete(canonicalPath: String) {
        try? FileManager.default.removeItem(at: fileURL(for: canonicalPath))
    }
}

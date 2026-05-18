// SessionPersistence.swift
//
// Serial reader/writer for the single multi-window session file at
// `~/Library/Application Support/termy/session.json`. Every save is an
// atomic temp+rename so a mid-write crash can't leave half-written JSON.
// On read, a `schemaVersion` newer than known — or an undecodable file —
// is moved to `_quarantine/` and load returns a non-`.loaded` outcome, so
// the caller falls back to a fresh single window rather than corrupting
// state. Mirrors `WorkspacePersistence`'s discipline for a single file.

import Foundation

enum SessionPersistenceError: Error {
    case directoryCreateFailed(Error)
    case writeFailed(Error)
    case renameFailed(POSIXErrorCode)
    case encodeFailed(Error)
}

enum SessionLoadOutcome {
    case loaded(SessionRecord)
    case missing
    case quarantined(reason: String)
}

actor SessionPersistence {
    nonisolated let fileURL: URL
    nonisolated let quarantineDir: URL

    static var defaultRootDir: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("termy", isDirectory: true)
    }

    init(rootDir: URL = SessionPersistence.defaultRootDir) throws {
        self.fileURL = rootDir.appendingPathComponent("session.json")
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
            throw SessionPersistenceError.directoryCreateFailed(error)
        }
    }

    /// Atomic write: encode → temp → `rename(2)`. Final file is `0600`.
    func save(_ record: SessionRecord) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(record)
        } catch {
            throw SessionPersistenceError.encodeFailed(error)
        }

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp-session-\(UUID().uuidString).json")
        do {
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tempURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw SessionPersistenceError.writeFailed(error)
        }

        let ok = rename(tempURL.path, fileURL.path)
        if ok != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: tempURL)
            throw SessionPersistenceError.renameFailed(code)
        }
    }

    /// Read the session file. `.missing` if absent, `.quarantined` if it was
    /// archived (corrupt or newer schema), `.loaded` on success.
    func load() -> SessionLoadOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return quarantine(reason: "unreadable")
        }
        struct Probe: Codable { let schemaVersion: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            return quarantine(reason: "undecodable")
        }
        if probe.schemaVersion > SessionRecord.currentSchemaVersion {
            return quarantine(reason: "v\(probe.schemaVersion)")
        }
        guard let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else {
            return quarantine(reason: "decode-failed")
        }
        return .loaded(record)
    }

    @discardableResult
    private func quarantine(reason: String) -> SessionLoadOutcome {
        let dest = quarantineDir.appendingPathComponent("session-\(reason).json")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: fileURL, to: dest)
        return .quarantined(reason: reason)
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

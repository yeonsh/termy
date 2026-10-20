// PreviewFileWatcher.swift
//
// Tells a preview window when its file changes on disk. Agents write files
// both in place and by atomic save (write a temp file, rename it over the
// original), so we watch the file itself for content changes
// and its parent directory for the file being replaced, removed or
// re-created. Bursts of events — an agent writing in chunks — collapse
// into one check after a short debounce, and the check compares a stat
// fingerprint so events that changed nothing don't re-render.

import Foundation

struct FileFingerprint: Equatable {
    let inode: UInt64
    let size: Int64
    let mtimeNanoseconds: Int64

    /// nil when nothing is at `path` (or it can't be stat'ed).
    static func current(atPath path: String) -> FileFingerprint? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileFingerprint(
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        )
    }
}

/// `.none` would read as `Optional.none` at call sites, hence `.unchanged`.
enum FileChange: Equatable {
    case unchanged
    case modified
    case deleted
    case recreated
}

@MainActor
final class PreviewFileWatcher {
    static let debounceInterval: TimeInterval = 0.15

    private let path: String
    private let directoryPath: String
    private let onChange: (FileChange) -> Void
    private var fingerprint: FileFingerprint?
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingCheck: DispatchWorkItem?

    /// Starts watching immediately. `onChange` runs on the main queue and
    /// never with `.unchanged`. Call `stop()` when done.
    init(fileURL: URL, onChange: @escaping (FileChange) -> Void) {
        path = fileURL.path
        directoryPath = fileURL.deletingLastPathComponent().path
        self.onChange = onChange
        fingerprint = FileFingerprint.current(atPath: path)
        directorySource = makeSource(path: directoryPath, events: .write)
        attachFileSource()
    }

    /// Cancels both sources and any pending check. The owner must call this.
    func stop() {
        pendingCheck?.cancel()
        pendingCheck = nil
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
    }

    nonisolated static func classify(old: FileFingerprint?, new: FileFingerprint?) -> FileChange {
        switch (old, new) {
        case (nil, nil): return .unchanged
        case (nil, .some): return .recreated
        case (.some, nil): return .deleted
        case let (.some(old), .some(new)): return old == new ? .unchanged : .modified
        }
    }

    /// (Re)opens the file source on whatever file is at `path` now. The
    /// old source watched a vnode that an atomic save or delete retired.
    private func attachFileSource() {
        fileSource?.cancel()
        fileSource = makeSource(path: path, events: [.write, .extend, .attrib, .delete, .rename, .revoke])
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func check() {
        let new = FileFingerprint.current(atPath: path)
        let change = Self.classify(old: fingerprint, new: new)
        if new?.inode != fingerprint?.inode {
            attachFileSource()
        }
        fingerprint = new
        if change != .unchanged {
            onChange(change)
        }
    }
}

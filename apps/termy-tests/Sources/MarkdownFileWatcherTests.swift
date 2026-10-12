import XCTest
@testable import termy

@MainActor
final class MarkdownFileWatcherTests: XCTestCase {
    // MARK: classify

    private let a = FileFingerprint(inode: 1, size: 10, mtimeNanoseconds: 100)

    func test_classify() {
        XCTAssertEqual(MarkdownFileWatcher.classify(old: nil, new: nil), .unchanged)
        XCTAssertEqual(MarkdownFileWatcher.classify(old: a, new: a), .unchanged)
        XCTAssertEqual(MarkdownFileWatcher.classify(old: nil, new: a), .recreated)
        XCTAssertEqual(MarkdownFileWatcher.classify(old: a, new: nil), .deleted)
        XCTAssertEqual(
            MarkdownFileWatcher.classify(old: a, new: FileFingerprint(inode: 1, size: 11, mtimeNanoseconds: 100)),
            .modified
        )
        XCTAssertEqual(
            MarkdownFileWatcher.classify(old: a, new: FileFingerprint(inode: 1, size: 10, mtimeNanoseconds: 101)),
            .modified
        )
        // Atomic save: same size and mtime granularity, new inode.
        XCTAssertEqual(
            MarkdownFileWatcher.classify(old: a, new: FileFingerprint(inode: 2, size: 10, mtimeNanoseconds: 100)),
            .modified
        )
    }

    func test_fingerprintIsNilForMissingFile() {
        XCTAssertNil(FileFingerprint.current(atPath: "/nonexistent/\(UUID().uuidString).md"))
    }

    // MARK: live events

    private func makeTempFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try contents.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// Lets the main queue run (dispatch sources and the debounce fire
    /// there) until `condition` holds.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_inPlaceWriteIsReported() async throws {
        let url = try makeTempFile("one")
        var changes: [FileChange] = []
        let watcher = MarkdownFileWatcher(fileURL: url) { changes.append($0) }
        defer { watcher.stop() }

        try "one two".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { !changes.isEmpty }
        XCTAssertEqual(changes.first, .modified)
    }

    func test_atomicReplaceThenInPlaceWriteBothReported() async throws {
        let url = try makeTempFile("one")
        var changes: [FileChange] = []
        let watcher = MarkdownFileWatcher(fileURL: url) { changes.append($0) }
        defer { watcher.stop() }

        try "two two".write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil { changes.count >= 1 }
        // The watcher must have re-attached to the replacement file.
        try "three three three".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { changes.count >= 2 }
        XCTAssertEqual(Array(changes.prefix(2)), [.modified, .modified])
    }

    func test_deleteThenRecreateIsReported() async throws {
        let url = try makeTempFile("one")
        var changes: [FileChange] = []
        let watcher = MarkdownFileWatcher(fileURL: url) { changes.append($0) }
        defer { watcher.stop() }

        try FileManager.default.removeItem(at: url)
        try await waitUntil { changes.count >= 1 }
        try "back".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { changes.count >= 2 }
        XCTAssertEqual(Array(changes.prefix(2)), [.deleted, .recreated])
    }

    func test_stopSilencesWatcher() async throws {
        let url = try makeTempFile("one")
        var changes: [FileChange] = []
        let watcher = MarkdownFileWatcher(fileURL: url) { changes.append($0) }
        watcher.stop()

        try "one two".write(to: url, atomically: false, encoding: .utf8)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(changes, [])
    }
}

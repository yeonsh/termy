import XCTest
@testable import termy

final class SessionPersistenceTests: XCTestCase {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("termy-session-test-\(UUID().uuidString)", isDirectory: true)
    }

    func test_saveThenLoad_roundTrips() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SessionPersistence(rootDir: root)
        let record = SessionRecord(windows: [
            WindowRecord(
                frame: FrameRecord(x: 0, y: 0, width: 100, height: 100),
                rows: [[PaneRecord(cwd: "/x")]]
            )
        ])
        try await persistence.save(record)
        guard case .loaded(let loaded) = await persistence.load() else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(loaded, record)
    }

    func test_load_missingFile_returnsMissing() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SessionPersistence(rootDir: root)
        guard case .missing = await persistence.load() else {
            return XCTFail("expected .missing")
        }
    }

    func test_load_newerSchema_quarantines() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SessionPersistence(rootDir: root)
        let future = #"{"schemaVersion": 999, "windows": []}"#
        try Data(future.utf8).write(to: root.appendingPathComponent("session.json"))
        guard case .quarantined = await persistence.load() else {
            return XCTFail("expected .quarantined")
        }
        // Quarantine moves the file out of the way — a second load is .missing.
        guard case .missing = await persistence.load() else {
            return XCTFail("expected .missing after quarantine")
        }
    }
}

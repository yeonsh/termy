import XCTest
@testable import termy

final class SessionRecordTests: XCTestCase {
    func test_sessionRecord_roundTripsThroughJSON() throws {
        let record = SessionRecord(windows: [
            WindowRecord(
                frame: FrameRecord(x: 10, y: 20, width: 1200, height: 760),
                rows: [
                    [PaneRecord(cwd: "/a"), PaneRecord(cwd: "/b")],
                    [PaneRecord(cwd: "/c")]
                ],
                filterProjectId: "proj",
                focusedPaneIndex: 2
            )
        ])
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func test_sessionRecord_defaultSchemaVersionIsCurrent() {
        let record = SessionRecord(windows: [])
        XCTAssertEqual(record.schemaVersion, SessionRecord.currentSchemaVersion)
    }

    func test_frameRecord_convertsToAndFromCGRect() {
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertEqual(FrameRecord(rect).cgRect, rect)
    }
}

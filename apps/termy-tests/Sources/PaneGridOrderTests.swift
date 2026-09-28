import XCTest
@testable import termy

final class PaneGridOrderTests: XCTestCase {
    /// Fixture panes are named "<project><n>", e.g. "api1".
    private func readingOrder(_ columns: [[String]], projects: [String]) -> [String] {
        PaneGridOrder.readingOrder(columns: columns, projectOrder: projects) {
            String($0.prefix(3))
        }
    }

    func test_singleProject_walksColumnsLeftToRightEachTopToBottom() {
        // api3 was opened before api4, but ⌘D put api4's column in between.
        XCTAssertEqual(
            readingOrder([["api1", "api2"], ["api4"], ["api3"]], projects: ["api"]),
            ["api1", "api2", "api4", "api3"]
        )
    }

    func test_emptyColumns_areSkipped() {
        XCTAssertEqual(
            readingOrder([["api1"], [], ["api2"]], projects: ["api"]),
            ["api1", "api2"]
        )
    }

    func test_allView_walksProjectCellsInChipOrder() {
        // Mirrors the ALL grid: one cell per project, cells in chip order,
        // each cell keeping its own columns left to right.
        XCTAssertEqual(
            readingOrder([["web1"], ["api1", "api2"], ["web2"]], projects: ["api", "web"]),
            ["api1", "api2", "web1", "web2"]
        )
    }

    func test_columnMixingProjects_splitsIntoEachProjectsCell() {
        XCTAssertEqual(
            readingOrder([["api1", "web1", "api2"]], projects: ["api", "web"]),
            ["api1", "api2", "web1"]
        )
    }
}

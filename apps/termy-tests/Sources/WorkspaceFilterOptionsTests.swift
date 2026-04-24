import XCTest
@testable import termy

final class WorkspaceFilterOptionsTests: XCTestCase {
    func test_singlePane_omitsAllFilter() {
        XCTAssertEqual(
            WorkspaceFilterOptions.options(projectIds: ["api"]),
            [.project("api")]
        )
    }

    func test_oneProjectFilter_omitsAllFilterEvenWithMultiplePanes() {
        XCTAssertEqual(
            WorkspaceFilterOptions.options(projectIds: ["api"]),
            [.project("api")]
        )
    }

    func test_twoProjectFilters_includeAllFirst() {
        XCTAssertEqual(
            WorkspaceFilterOptions.options(projectIds: ["api", "web"]),
            [.all, .project("api"), .project("web")]
        )
    }

    func test_noPanes_omitsAllFilter() {
        XCTAssertEqual(
            WorkspaceFilterOptions.options(projectIds: []),
            []
        )
    }

    func test_commandZero_targetsAllOnlyWhenAllFilterExists() {
        XCTAssertNil(
            WorkspaceFilterOptions.allShortcutTarget(projectIds: ["api"])
        )
        XCTAssertEqual(
            WorkspaceFilterOptions.allShortcutTarget(projectIds: ["api", "web"]),
            .all
        )
    }

    func test_commandNumbers_targetProjectFiltersWithoutAllOffset() {
        let ids = ["api", "web"]

        XCTAssertEqual(
            WorkspaceFilterOptions.projectShortcutTarget(projectIds: ids, number: 1),
            .project("api")
        )
        XCTAssertEqual(
            WorkspaceFilterOptions.projectShortcutTarget(projectIds: ids, number: 2),
            .project("web")
        )
        XCTAssertNil(
            WorkspaceFilterOptions.projectShortcutTarget(projectIds: ids, number: 0)
        )
        XCTAssertNil(
            WorkspaceFilterOptions.projectShortcutTarget(projectIds: ids, number: 3)
        )
    }

    func test_shortcutHints_useZeroForAllAndOneBasedProjectNumbers() {
        let ids = ["api", "web"]

        XCTAssertEqual(WorkspaceFilterOptions.shortcutHint(for: .all, projectIds: ids), "0")
        XCTAssertEqual(WorkspaceFilterOptions.shortcutHint(for: .project("api"), projectIds: ids), "1")
        XCTAssertEqual(WorkspaceFilterOptions.shortcutHint(for: .project("web"), projectIds: ids), "2")
        XCTAssertNil(WorkspaceFilterOptions.shortcutHint(for: .project("missing"), projectIds: ids))
    }
}

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

    // MARK: - ⌘-held two-digit project jump

    func test_digitChord_singleDigitJumpsImmediately() {
        var chord = ProjectFilterDigitChord()
        XCTAssertEqual(chord.press(1, projectCount: 12, at: 0), 1)
    }

    func test_digitChord_secondDigitWhileHeldExtendsToTen() {
        var chord = ProjectFilterDigitChord()
        XCTAssertEqual(chord.press(1, projectCount: 12, at: 0), 1)
        XCTAssertEqual(chord.press(0, projectCount: 12, at: 0.3), 10)
    }

    func test_digitChord_zeroAloneIsAll() {
        var chord = ProjectFilterDigitChord()
        XCTAssertEqual(chord.press(0, projectCount: 12, at: 0), 0)
    }

    func test_digitChord_underTenProjectsNeverChains() {
        // With 9 projects, ⌘1 then ⌘0 must still mean project 1 then ALL.
        var chord = ProjectFilterDigitChord()
        XCTAssertEqual(chord.press(1, projectCount: 9, at: 0), 1)
        XCTAssertEqual(chord.press(0, projectCount: 9, at: 0.1), 0)
    }

    func test_digitChord_outOfRangeSecondDigitStartsFresh() {
        var chord = ProjectFilterDigitChord()
        XCTAssertEqual(chord.press(1, projectCount: 12, at: 0), 1)
        XCTAssertEqual(chord.press(5, projectCount: 12, at: 0.1), 5)
    }

    func test_digitChord_nonPrefixDigitDoesNotChain() {
        // 2 cannot start a valid number when there are only 12 projects.
        var chord = ProjectFilterDigitChord()
        XCTAssertEqual(chord.press(2, projectCount: 12, at: 0), 2)
        XCTAssertEqual(chord.press(0, projectCount: 12, at: 0.1), 0)
    }

    func test_digitChord_resetOnCommandReleaseBreaksChain() {
        var chord = ProjectFilterDigitChord()
        XCTAssertEqual(chord.press(1, projectCount: 12, at: 0), 1)
        chord.reset()
        XCTAssertEqual(chord.press(0, projectCount: 12, at: 0.1), 0)
    }

    func test_digitChord_timeoutBreaksChain() {
        var chord = ProjectFilterDigitChord()
        XCTAssertEqual(chord.press(1, projectCount: 12, at: 0), 1)
        XCTAssertEqual(chord.press(1, projectCount: 12, at: 5), 1)
    }

    func test_digitChord_chainEndsAfterTwoDigitNumber() {
        var chord = ProjectFilterDigitChord()
        XCTAssertEqual(chord.press(1, projectCount: 12, at: 0), 1)
        XCTAssertEqual(chord.press(1, projectCount: 12, at: 0.1), 11)
        XCTAssertEqual(chord.press(2, projectCount: 12, at: 0.2), 2)
    }

    func test_shortcutHints_continuePastNine() {
        let ids = (1...12).map { "p\($0)" }
        XCTAssertEqual(WorkspaceFilterOptions.shortcutHint(for: .project("p10"), projectIds: ids), "10")
    }
}

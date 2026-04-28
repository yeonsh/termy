import XCTest
@testable import termy

final class FilterNavigationHistoryTests: XCTestCase {
    func test_markVisited_dedupesPriorOccurrence() {
        var history = FilterNavigationHistory()
        history.markVisited(.project("a"))
        history.markVisited(.project("b"))
        history.markVisited(.project("a"))

        XCTAssertEqual(
            history.popMostRecentValid(in: [.project("a"), .project("b")]),
            .project("a")
        )
    }

    func test_popMostRecentValid_returnsAndRemovesNewestEntry() {
        var history = FilterNavigationHistory()
        history.markVisited(.project("a"))
        history.markVisited(.project("b"))

        XCTAssertEqual(
            history.popMostRecentValid(in: [.project("a"), .project("b")]),
            .project("b")
        )
        XCTAssertEqual(
            history.popMostRecentValid(in: [.project("a"), .project("b")]),
            .project("a")
        )
        XCTAssertNil(
            history.popMostRecentValid(in: [.project("a"), .project("b")])
        )
    }

    func test_popMostRecentValid_skipsAndPrunesEntriesNotInOptions() {
        var history = FilterNavigationHistory()
        history.markVisited(.project("a"))
        history.markVisited(.project("gone"))
        history.markVisited(.project("also-gone"))

        XCTAssertEqual(
            history.popMostRecentValid(in: [.project("a")]),
            .project("a")
        )
        XCTAssertNil(
            history.popMostRecentValid(in: [.project("a")])
        )
    }

    func test_popMostRecentValid_onEmptyHistoryReturnsNil() {
        var history = FilterNavigationHistory()
        XCTAssertNil(history.popMostRecentValid(in: [.all, .project("a")]))
    }

    func test_remove_deletesEveryOccurrence() {
        var history = FilterNavigationHistory()
        history.markVisited(.project("a"))
        history.markVisited(.project("b"))
        history.markVisited(.project("a")) // dedupes — only one "a" remains
        history.remove(.project("a"))

        XCTAssertEqual(
            history.popMostRecentValid(in: [.project("a"), .project("b")]),
            .project("b")
        )
    }

    func test_filterToRestore_fallsBackToFirstOptionWhenHistoryEmpty() {
        var history = FilterNavigationHistory()
        XCTAssertEqual(
            history.filterToRestore(in: [.all, .project("a")]),
            .all
        )
    }

    func test_filterToRestore_prefersHistoryOverFirstOption() {
        var history = FilterNavigationHistory()
        history.markVisited(.project("b"))
        XCTAssertEqual(
            history.filterToRestore(in: [.all, .project("a"), .project("b")]),
            .project("b")
        )
    }
}

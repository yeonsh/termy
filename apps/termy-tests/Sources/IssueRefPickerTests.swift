import AppKit
import XCTest
@testable import termy

final class IssueRefPickerTests: XCTestCase {
    private let bdweb = RepoWebURL(storageKey: "github.com/bdrive/bdweb")!
    private let bdriveCore = RepoWebURL(storageKey: "github.com/bdrive/bdrive-core")!
    private let nd3 = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive3")!

    private func request(candidates: [IssueRefCandidate], limit: Bool = false) -> IssueRefMenuRequest {
        IssueRefMenuRequest(title: "Open #1300 in…", number: 1300, kind: .issue,
                            candidates: candidates, limitToCandidates: limit, saveTarget: .none)
    }

    private func model(candidates: [IssueRefCandidate] = [], all: [RepoWebURL] = [], limit: Bool = false) -> IssueRefPickerModel {
        IssueRefPickerModel(request: request(candidates: candidates, limit: limit), allRepos: all)
    }

    func test_rows_emptyQuery_candidatesThenShowAll() {
        let rows = model(candidates: [.init(repo: bdweb, tag: .thisPane), .init(repo: bdriveCore, tag: .sameLine)],
                         all: [nd3]).rows(query: "", showAll: false)
        XCTAssertEqual(rows.map(\.title), ["bdweb", "bdrive-core", "Show All Projects…"])
        XCTAssertEqual(rows.map(\.tagLabel), ["this pane", "same line", nil])
        XCTAssertEqual(rows.first?.detail, "github.com/bdrive")
    }

    func test_rows_query_searchesAllKnownRepos() {
        let rows = model(candidates: [.init(repo: bdweb, tag: nil)], all: [nd3, bdriveCore])
            .rows(query: "nd3", showAll: false)
        XCTAssertEqual(rows.first?.title, "netdrive3")
        XCTAssertFalse(rows.contains { $0.action == .showAll })
    }

    func test_rows_limitToCandidates_hidesShowAllAndOtherRepos() {
        let m = model(candidates: [.init(repo: bdweb, tag: .recent)], all: [nd3, bdriveCore], limit: true)
        XCTAssertEqual(m.rows(query: "", showAll: false).map(\.title), ["bdweb"])
        XCTAssertEqual(m.rows(query: "nd3", showAll: false).map(\.title), [])
        XCTAssertEqual(m.rows(query: "web", showAll: false).map(\.title), ["bdweb"])
    }

    func test_rows_showAll_sortedByName() {
        let rows = model(candidates: [.init(repo: bdweb, tag: .recent)], all: [nd3, bdriveCore, bdweb])
            .rows(query: "", showAll: true)
        XCTAssertEqual(rows.map(\.title), ["bdrive-core", "bdweb", "netdrive3"])
        XCTAssertEqual(rows.map(\.tagLabel), [nil, "recent", nil])
    }

    func test_rows_searchCappedAtTwelve() {
        let repos = (0..<20).map { RepoWebURL(storageKey: "github.com/o/a\($0)")! }
        XCTAssertEqual(model(all: repos).rows(query: "a", showAll: false).count, 12)
    }

    @MainActor func test_panel_enterPicksFirstCandidate() {
        let panel = IssueRefPickerPanel()
        var picked: [RepoWebURL] = []
        panel.present(request: request(candidates: [.init(repo: bdweb, tag: .thisPane)]), allRepos: [],
                      at: NSPoint(x: 100, y: 500)) { picked.append($0) }
        panel.commitSelection()
        XCTAssertEqual(picked, [bdweb])
        panel.orderOut(nil)
    }

    @MainActor func test_panel_cancelPicksNothing() {
        let panel = IssueRefPickerPanel()
        var picked: [RepoWebURL] = []
        panel.present(request: request(candidates: [.init(repo: bdweb, tag: .thisPane)]), allRepos: [],
                      at: NSPoint(x: 100, y: 500)) { picked.append($0) }
        panel.cancelAndClose()
        panel.commitSelection()
        XCTAssertEqual(picked, [])
        panel.orderOut(nil)
    }

    @MainActor func test_panel_typingNarrowsRows() {
        let panel = IssueRefPickerPanel()
        panel.present(request: request(candidates: [.init(repo: bdweb, tag: .thisPane)]), allRepos: [nd3, bdriveCore],
                      at: NSPoint(x: 100, y: 500)) { _ in }
        panel.setSearchTextForTesting("nd3")
        XCTAssertEqual(panel.visibleRows.map(\.title), ["netdrive3"])
        panel.orderOut(nil)
    }

    @MainActor func test_panel_showAllRowSwitchesListWithoutPicking() {
        let panel = IssueRefPickerPanel()
        var picked: [RepoWebURL] = []
        panel.present(request: request(candidates: []), allRepos: [nd3, bdweb],
                      at: NSPoint(x: 100, y: 500)) { picked.append($0) }
        XCTAssertEqual(panel.visibleRows.map(\.title), ["Show All Projects…"])
        panel.commitSelection()
        XCTAssertEqual(panel.visibleRows.map(\.title), ["bdweb", "netdrive3"])
        XCTAssertEqual(picked, [])
        panel.commitSelection()
        XCTAssertEqual(picked, [bdweb])
        panel.orderOut(nil)
    }
}

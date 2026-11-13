import XCTest
import AppKit
@testable import termy

@MainActor
final class IssueRefControllerTests: XCTestCase {
    private final class Recorder {
        var opened: [URL] = []
        var menus: [(request: IssueRefMenuRequest, allRepos: [RepoWebURL], onPick: (RepoWebURL) -> Void)] = []
        var beeps = 0
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private var tmp: URL!
    private var suite = ""
    private var defaults: UserDefaults!
    private var recorder: Recorder!
    private let nd3 = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive3")!
    private let flutter = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive4_flutter")!

    /// The agent's summary line from the spec: a bare `#1300` clicked, with
    /// `netdrive3 #1300` a few rows up.
    private let exampleLine = "- 답을 기다리는 것: #1300 코디네이터 판단, bdrive-core #26~#28 수정."

    override func setUp() async throws {
        try await super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueRefControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        suite = "IssueRefControllerTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        recorder = Recorder()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        try? FileManager.default.removeItem(at: tmp)
        recorder = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// `<tmp>/work`, holding the given repos as children.
    private func makeWorkspace(_ repos: [String: String]) throws -> String {
        let work = tmp.appendingPathComponent("work")
        for (folder, origin) in repos {
            let git = work.appendingPathComponent(folder).appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            try "[remote \"origin\"]\n\turl = \(origin)\n"
                .write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        return work.path
    }

    private func makeController(index: KnownRepoIndex, memory: IssueRefMemory) -> IssueRefController {
        let recorder = self.recorder!
        return IssueRefController(
            index: index,
            memory: memory,
            openURL: { recorder.opened.append($0) },
            presentMenu: { request, allRepos, _, onPick in
                recorder.menus.append((request, allRepos, onPick))
            },
            beep: { recorder.beeps += 1 }
        )
    }

    private func click(_ text: String, on needle: String, linesAbove: [String] = [],
                       forceMenu: Bool = false) throws -> IssueRefClick {
        let range = try XCTUnwrap(text.range(of: needle))
        let offset = text.distance(from: text.startIndex, to: range.lowerBound) + 1
        let hit = try XCTUnwrap(IssueRefParser.hit(in: text, atOffset: offset))
        return IssueRefClick(
            hit: hit,
            screen: IssueRefScreenContext(text: text, clickOffset: offset, linesAbove: linesAbove),
            forceMenu: forceMenu,
            anchorScreenPoint: .zero
        )
    }

    // MARK: - handle

    func test_handle_exampleLine_opensNetdrive3WithoutMenu() async throws {
        let work = try makeWorkspace([
            "netdrive3": "https://gitlab.bdrive.com/bdrive/netdrive3.git",
            "netdrive4_flutter": "https://gitlab.bdrive.com/bdrive/netdrive4_flutter.git",
        ])
        let memory = IssueRefMemory(defaults: defaults)
        let controller = makeController(index: KnownRepoIndex(workspacePaths: { [work] }), memory: memory)
        let c = try click(exampleLine, on: "#1300",
                          linesAbove: ["2. netdrive3 #1300 코디네이터 판단: 아직 답이 없습니다"])
        XCTAssertNil(c.hit.ref.qualifier)

        await controller.handle(c, paneId: "p1", paneRoots: [])

        XCTAssertEqual(recorder.opened, [URL(string: "https://gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300")!])
        XCTAssertTrue(recorder.menus.isEmpty)
        XCTAssertEqual(recorder.beeps, 0)
        XCTAssertEqual(memory.recents.first, nd3)
    }

    /// A project cloned after the index was built: the first lookup misses
    /// the name, so the index is rebuilt once before any menu shows.
    func test_handle_unknownName_rebuildsIndexOnce() async throws {
        let work = try makeWorkspace(["netdrive3": "https://gitlab.bdrive.com/bdrive/netdrive3.git"])
        let counter = Counter()
        let index = KnownRepoIndex(workspacePaths: { counter.bump() == 1 ? [] : [work] })
        let controller = makeController(index: index, memory: IssueRefMemory(defaults: defaults))

        await controller.handle(try click("netdrive3#1300", on: "#1300"), paneId: "p1", paneRoots: [])

        XCTAssertEqual(recorder.opened, [URL(string: "https://gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300")!])
        XCTAssertTrue(recorder.menus.isEmpty)
        XCTAssertEqual(counter.value, 2)
    }

    /// Words before other numbers (`Task #3`, `see #12`) never name a
    /// project; they must not make the menu wait for a rebuild.
    func test_handle_unrelatedClueNames_doNotRebuild() async throws {
        let work = try makeWorkspace(["netdrive3": "https://gitlab.bdrive.com/bdrive/netdrive3.git"])
        let counter = Counter()
        let index = KnownRepoIndex(workspacePaths: { _ = counter.bump(); return [work] })
        let controller = makeController(index: index, memory: IssueRefMemory(defaults: defaults))

        await controller.handle(try click("#1300", on: "#1300", linesAbove: ["Task #3", "see #12"]),
                                paneId: "p1", paneRoots: [])

        XCTAssertEqual(recorder.menus.count, 1)
        XCTAssertTrue(recorder.opened.isEmpty)
        XCTAssertEqual(counter.value, 1)
    }

    /// An unknown abbreviation shows the menu over every known project;
    /// picking one there saves the abbreviation and opens it.
    func test_handle_unknownAbbreviation_menuPickSavesAlias() async throws {
        let work = try makeWorkspace([
            "netdrive3": "https://gitlab.bdrive.com/bdrive/netdrive3.git",
            "netdrive4_flutter": "https://gitlab.bdrive.com/bdrive/netdrive4_flutter.git",
        ])
        let memory = IssueRefMemory(defaults: defaults)
        let controller = makeController(index: KnownRepoIndex(workspacePaths: { [work] }), memory: memory)

        await controller.handle(try click("fl#45", on: "#45"), paneId: "p1", paneRoots: [])

        XCTAssertTrue(recorder.opened.isEmpty)
        let menu = try XCTUnwrap(recorder.menus.first)
        XCTAssertEqual(recorder.menus.count, 1)
        XCTAssertEqual(menu.request.title, "fl#45 — which project is “fl”?")
        XCTAssertEqual(Set(menu.allRepos), [nd3, flutter])
        XCTAssertEqual(menu.allRepos.count, 2)

        menu.onPick(flutter)

        XCTAssertEqual(memory.alias("fl"), flutter)
        XCTAssertEqual(recorder.opened, [URL(string: "https://gitlab.bdrive.com/bdrive/netdrive4_flutter/-/issues/45")!])
    }

    // MARK: - applyPick

    func test_applyPick_savesAliasAndOpens() {
        let memory = IssueRefMemory(defaults: defaults)
        let controller = makeController(index: KnownRepoIndex(workspacePaths: { [] }), memory: memory)
        let request = IssueRefMenuRequest(title: "fl#45 — which project is “fl”?", number: 45, kind: .issue,
                                          candidates: [], limitToCandidates: false, saveTarget: .alias("fl"))

        controller.applyPick(flutter, request: request)

        XCTAssertEqual(memory.alias("fl"), flutter)
        XCTAssertEqual(memory.recents.first, flutter)
        XCTAssertEqual(recorder.opened, [URL(string: "https://gitlab.bdrive.com/bdrive/netdrive4_flutter/-/issues/45")!])
    }

    // MARK: - context

    func test_context_cluesNearestFirst() throws {
        let c = try click("#1300", on: "#1300", linesAbove: ["netdrive3 #1300", "bdweb #1300"])

        let context = IssueRefController.context(for: c, paneId: "p1", paneRepos: [])

        XCTAssertEqual(context.clues.first?.source, .name(.spaced("bdweb")))
        XCTAssertEqual(context.clues.map(\.source), [.name(.spaced("bdweb")), .name(.spaced("netdrive3"))])
        XCTAssertEqual(context.nearbyNames, ["bdweb", "netdrive3"])
    }
}

import XCTest
@testable import termy

@MainActor
final class IssueRefMemoryTests: XCTestCase {
    private var suite = ""
    private var d: UserDefaults!
    private let flutter = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive4_flutter")!
    private let nd3 = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive3")!

    override func setUp() {
        super.setUp()
        suite = "IssueRefMemoryTests-\(UUID())"
        d = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        d.removePersistentDomain(forName: suite)
        d = nil
        super.tearDown()
    }

    func test_aliasPersistsAcrossInstances_caseInsensitive() {
        IssueRefMemory(defaults: d).setAlias("FL", to: flutter)
        XCTAssertEqual(IssueRefMemory(defaults: d).alias("fl"), flutter)
    }

    func test_aliasStoredAsHostPathOnly() {
        IssueRefMemory(defaults: d).setAlias("fl", to: flutter)
        XCTAssertEqual(d.dictionary(forKey: IssueRefMemory.aliasesKey) as? [String: String],
                       ["fl": "gitlab.bdrive.com/bdrive/netdrive4_flutter"])
    }

    func test_removeAlias() {
        let m = IssueRefMemory(defaults: d)
        m.setAlias("fl", to: flutter)
        m.removeAlias("FL")
        XCTAssertNil(m.alias("fl"))
        XCTAssertEqual(m.aliases, [])
    }

    func test_aliasesSortedByName() {
        let m = IssueRefMemory(defaults: d)
        m.setAlias("nd", to: nd3)
        m.setAlias("fl", to: flutter)
        XCTAssertEqual(m.aliases.map(\.name), ["fl", "nd"])
    }

    func test_invalidStoredEntriesSkipped() {
        d.set(["bad": "nosla", "fl": "gitlab.bdrive.com/bdrive/netdrive4_flutter"], forKey: IssueRefMemory.aliasesKey)
        d.set(["nosla", "gitlab.bdrive.com/bdrive/netdrive3"], forKey: IssueRefMemory.recentsKey)
        let m = IssueRefMemory(defaults: d)
        XCTAssertNil(m.alias("bad"))
        XCTAssertEqual(m.alias("fl"), flutter)
        XCTAssertEqual(m.recents, [nd3])
    }

    func test_picksAreNotPersisted() {
        let key = IssueRefPickKey(paneId: "p1", number: 1300, kind: .issue)
        let m = IssueRefMemory(defaults: d)
        m.setPick(nd3, for: key)
        XCTAssertEqual(m.snapshot.picks[key], nd3)
        XCTAssertNil(IssueRefMemory(defaults: d).snapshot.picks[key])
    }

    func test_recents_moveToFrontAndCapAtFive() {
        let m = IssueRefMemory(defaults: d)
        let repos = (1...6).map { RepoWebURL(storageKey: "gitlab.bdrive.com/g/r\($0)")! }
        repos.forEach { m.noteOpened($0) }
        m.noteOpened(repos[0])
        XCTAssertEqual(m.recents.count, 5)
        XCTAssertEqual(m.recents.first, repos[0])
        XCTAssertEqual(Set(m.recents).count, 5)
        XCTAssertEqual(IssueRefMemory(defaults: d).recents, m.recents)
    }
}

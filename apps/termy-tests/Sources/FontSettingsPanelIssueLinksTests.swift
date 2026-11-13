import XCTest
@testable import termy

@MainActor
final class FontSettingsPanelIssueLinksTests: XCTestCase {
    private var suiteName = ""
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FontSettingsPanelIssueLinksTests-\(UUID())"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        super.tearDown()
    }

    func test_issueLinks_listsAndRemovesAliases() {
        let panel = FontSettingsPanel()
        panel.issueRefMemory = IssueRefMemory(defaults: testDefaults)
        panel.issueRefMemory.setAlias("fl", to: RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive4_flutter")!)
        panel.reloadIssueAliases()
        XCTAssertEqual(panel.issueAliasTitles, ["fl → gitlab.bdrive.com/bdrive/netdrive4_flutter"])
        XCTAssertTrue(panel.isRemoveIssueAliasEnabled)
        panel.removeIssueAlias(nil)
        XCTAssertEqual(panel.issueRefMemory.aliases, [])
        XCTAssertEqual(panel.issueAliasTitles, ["No abbreviations"])
        XCTAssertFalse(panel.isRemoveIssueAliasEnabled)
        panel.orderOut(nil)
    }

    func test_issueLinks_removesOnlySelectedAlias() {
        let panel = FontSettingsPanel()
        panel.issueRefMemory = IssueRefMemory(defaults: testDefaults)
        panel.issueRefMemory.setAlias("fl", to: RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive4_flutter")!)
        panel.issueRefMemory.setAlias("core", to: RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/core")!)
        panel.reloadIssueAliases()
        XCTAssertEqual(panel.issueAliasTitles.count, 2)
        XCTAssertTrue(panel.issueAliasTitles[0].hasPrefix("core → "))
        panel.removeIssueAlias(nil)
        XCTAssertEqual(panel.issueRefMemory.aliases.map(\.name), ["fl"])
        XCTAssertEqual(panel.issueAliasTitles, ["fl → gitlab.bdrive.com/bdrive/netdrive4_flutter"])
        panel.orderOut(nil)
    }
}

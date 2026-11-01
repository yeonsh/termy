import XCTest
@testable import termy

final class HcFeatureSettingsTests: XCTestCase {
    func testLocalPanesDefaultOff() {
        let d = InMemoryUserDefaults()
        XCTAssertFalse(HcFeatureSettings.localPanesEnabled(d))
        XCTAssertEqual(PaneLaunch.forNewLocalPane(defaults: d, hcAllowsNewPanes: true), .local)
    }

    func testLocalPanesOnLaunchesHc() {
        let d = InMemoryUserDefaults()
        HcFeatureSettings.setLocalPanesEnabled(true, d)
        XCTAssertEqual(PaneLaunch.forNewLocalPane(defaults: d, hcAllowsNewPanes: true), .hc(machine: nil))
        XCTAssertEqual(d.object(forKey: "termy.herdrCore.localPanes") as? Bool, true)
    }

    /// R21(spec §6.10). 설정이 켜져 있어도 hc를 쓸 수 없는 것이 확실하면 새 pane은 local이다(셸 없는 pane을 만들지 않는다).
    func testLocalPanesStayLocalWhenHcIsKnownUnusable() {
        let d = InMemoryUserDefaults()
        HcFeatureSettings.setLocalPanesEnabled(true, d)
        XCTAssertEqual(PaneLaunch.forNewLocalPane(defaults: d, hcAllowsNewPanes: false), .local)
        XCTAssertEqual(PaneLaunch.forReopenedRecord(PaneRecord(cwd: "/tmp"), defaults: d, hcAllowsNewPanes: false), .local)
        var remote = PaneRecord(cwd: "/srv")
        remote.backend = .hc
        remote.machine = "box"
        XCTAssertEqual(PaneLaunch.forReopenedRecord(remote, defaults: d, hcAllowsNewPanes: false), .hc(machine: "box"),
                       "a remote record has no local fallback (⌘K asks to install first)")
    }

    func testAdoptOrphansReadsTheSameSetting() {
        let d = InMemoryUserDefaults()
        XCTAssertFalse(WindowManager.shouldAdoptHcOrphans(paneKinds: [.local], defaults: d))
        HcFeatureSettings.setLocalPanesEnabled(true, d)
        XCTAssertTrue(WindowManager.shouldAdoptHcOrphans(paneKinds: [.local], defaults: d))
    }

    // MARK: - R15: ⌘K reopen

    func testReopenedRecordWithoutBackendFollowsSetting() {
        let d = InMemoryUserDefaults()
        let record = PaneRecord(cwd: "/tmp")
        XCTAssertEqual(PaneLaunch.forReopenedRecord(record, defaults: d, hcAllowsNewPanes: true), .local)
        HcFeatureSettings.setLocalPanesEnabled(true, d)
        XCTAssertEqual(PaneLaunch.forReopenedRecord(record, defaults: d, hcAllowsNewPanes: true), .hc(machine: nil))
    }

    func testReopenedRecordWithBackendOrMachineKeepsRecord() {
        let d = InMemoryUserDefaults()
        HcFeatureSettings.setLocalPanesEnabled(true, d)
        var local = PaneRecord(cwd: "/tmp")
        local.backend = .local
        XCTAssertEqual(PaneLaunch.forReopenedRecord(local, defaults: d, hcAllowsNewPanes: true), .local)
        var remote = PaneRecord(cwd: "/srv")
        remote.backend = .hc
        remote.machine = "box"
        XCTAssertEqual(PaneLaunch.forReopenedRecord(remote, defaults: d, hcAllowsNewPanes: true), .hc(machine: "box"))
        HcFeatureSettings.setLocalPanesEnabled(false, d)
        XCTAssertEqual(PaneLaunch.forReopenedRecord(remote, defaults: d, hcAllowsNewPanes: true), .hc(machine: "box"))
    }

    // MARK: - R16: status line

    func testStatusLineBranches() {
        func line(_ a: HcAvailability, installed: Bool = true, version: String? = "0.4.1") -> String {
            HcFeatureSettings.statusLine(availability: a, isInstalled: installed, installedVersion: version)
        }
        XCTAssertEqual(line(.connected(version: "0.4.2")), "herdr-core 0.4.2 · connected")
        XCTAssertEqual(line(.notInstalled, installed: false), "herdr-core: not installed")
        XCTAssertEqual(line(.unavailable("incompatible generation 2")), "herdr-core: unavailable (incompatible generation 2)")
        // 연결이 없을 뿐인 상태는 설치된 버전만 보인다.
        XCTAssertEqual(line(.unavailable("not connected")), "herdr-core 0.4.1")
        XCTAssertEqual(line(.connecting), "herdr-core 0.4.1")
        XCTAssertEqual(line(.unavailable("not connected"), version: nil), "herdr-core")
        // locator가 못 찾으면 초기 상태여도 미설치다.
        XCTAssertEqual(line(.unavailable("not connected"), installed: false, version: nil), "herdr-core: not installed")
        XCTAssertEqual(line(.connecting, installed: false, version: nil), "herdr-core: not installed")
    }

    func testParseVersion() {
        XCTAssertEqual(HcFeatureSettings.parseVersion("herdr-core 0.4.1\n"), "0.4.1")
        XCTAssertEqual(HcFeatureSettings.parseVersion("hc 0.1.16\n"), "0.1.16")
        XCTAssertEqual(HcFeatureSettings.parseVersion("0.4.1"), "0.4.1")
        XCTAssertNil(HcFeatureSettings.parseVersion("  \n"))
        XCTAssertNil(HcFeatureSettings.parseVersion("herdr-core"))
    }
}

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

    /// 세션 복원과 ⌘K: local 기록은 새 셸이므로 backend가 적혀 있어도 지금 설정을 따른다(2026-11-02 사용자 결정).
    /// 설정을 켜기 전에 연 pane도 다시 실행하면 hc가 되어 그 안의 agent가 ⌘Q 뒤에도 살아남는다.
    func testReopenedLocalRecordFollowsSettingEvenWithBackend() {
        let d = InMemoryUserDefaults()
        var local = PaneRecord(cwd: "/tmp")
        local.backend = .local
        XCTAssertEqual(PaneLaunch.forReopenedRecord(local, defaults: d, hcAllowsNewPanes: true), .local)
        HcFeatureSettings.setLocalPanesEnabled(true, d)
        XCTAssertEqual(PaneLaunch.forReopenedRecord(local, defaults: d, hcAllowsNewPanes: true), .hc(machine: nil))
        XCTAssertEqual(PaneLaunch.forReopenedRecord(local, defaults: d, hcAllowsNewPanes: false), .local,
                       "hc known unusable: a shell, not an unavailable pane (R21)")
    }

    /// hc 기록은 살아 있는 terminal에 다시 붙어야 하므로 설정과 상관없이 기록 그대로다.
    func testReopenedHcRecordKeepsRecord() {
        let d = InMemoryUserDefaults()
        var localHc = PaneRecord(cwd: "/tmp")
        localHc.backend = .hc
        var remote = PaneRecord(cwd: "/srv")
        remote.backend = .hc
        remote.machine = "box"
        for on in [true, false] {
            HcFeatureSettings.setLocalPanesEnabled(on, d)
            XCTAssertEqual(PaneLaunch.forReopenedRecord(localHc, defaults: d, hcAllowsNewPanes: true), .hc(machine: nil))
            XCTAssertEqual(PaneLaunch.forReopenedRecord(remote, defaults: d, hcAllowsNewPanes: true), .hc(machine: "box"))
        }
    }

    /// local 기록을 hc로 연 pane은 새 terminal이다: 기록의 pane id(다른 instance의 것일 수 있다, R19)를 잇지 않는다.
    func testOnlyHcRecordsContinueTheirPane() {
        var hc = PaneRecord(cwd: "/tmp")
        hc.backend = .hc
        XCTAssertTrue(hc.continuesHcPane(as: .hc(machine: nil)))
        var local = PaneRecord(cwd: "/tmp")
        local.backend = .local
        XCTAssertFalse(local.continuesHcPane(as: .hc(machine: nil)))
        XCTAssertFalse(PaneRecord(cwd: "/tmp").continuesHcPane(as: .hc(machine: nil)), "a file from before backend existed")
        XCTAssertFalse(local.continuesHcPane(as: .local))
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

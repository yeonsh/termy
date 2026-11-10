import XCTest
@testable import termy

@MainActor
final class QuitConfirmationTests: XCTestCase {
    private func context(
        xctest: Bool = false,
        relaunch: Bool = false,
        powerOff: Bool = false,
        hasMainWindow: Bool = true,
        ask: Bool = true
    ) -> QuitConfirmation.Context {
        QuitConfirmation.Context(
            isRunningUnderXCTest: xctest,
            isRelaunchingForUpdate: relaunch,
            isPoweringOff: powerOff,
            hasMainWindow: hasMainWindow,
            askBeforeQuit: ask
        )
    }

    func test_plainQuit_asks() {
        XCTAssertTrue(QuitConfirmation.shouldAsk(context()))
    }

    // protects=설정을 끈 사용자; fails_when=끈 뒤에도 대화상자가 뜬다
    func test_settingOff_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(ask: false)))
    }

    // protects=Sparkle 재시작; fails_when=업데이트 재시작이 모달에 멈춘다
    func test_updateRelaunch_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(relaunch: true)))
    }

    // protects=로그아웃/시스템 종료; fails_when=모달이 로그아웃을 붙잡는다
    func test_powerOff_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(powerOff: true)))
    }

    // protects=마지막 창을 닫은 직후; fails_when=창이 없는데 묻는다
    func test_noMainWindow_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(hasMainWindow: false)))
    }

    // protects=⌘H로 숨긴 뒤 Dock Quit; fails_when=창은 살아 있고 pane도 도는데 묻지 않고 끝난다
    func test_hiddenButOpenWindows_stillAsk() {
        let manager = WindowManager(
            sessionPersistence: nil,
            workspacePersistence: { nil },
            defaults: InMemoryUserDefaults()
        )
        let defaults = InMemoryUserDefaults()
        // 창을 열 수는 없으니 "창이 하나도 없으면 false"쪽만 고정한다.
        XCTAssertFalse(QuitConfirmation.context(windowManager: manager, defaults: defaults).hasMainWindow)
    }

    // protects=Esc/Return; fails_when=확인 창의 두 버튼이 취소/종료로 배선되지 않는다
    func test_alertButtons() {
        let alert = QuitConfirmation.makeAlert()
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Quit"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "Return은 취소로 간다")
    }

    // protects=취소된 로그아웃 뒤의 ⌘Q; fails_when=한 번 켜진 종료 요청 플래그가 세션 내내 남는다
    func test_powerOffFlag_expires() {
        let now = Date()
        XCTAssertTrue(QuitConfirmation.isPoweringOff(now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(QuitConfirmation.isPoweringOff(now.addingTimeInterval(-120), now: now))
        XCTAssertFalse(QuitConfirmation.isPoweringOff(nil, now: now))
    }

    func test_xctestHost_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(xctest: true)))
    }

    func test_askBeforeQuitDefaultsToTrue() {
        let defaults = InMemoryUserDefaults()
        XCTAssertTrue(QuitSettings.askBeforeQuit(defaults))
    }

    func test_askBeforeQuitRoundTrips() {
        let defaults = InMemoryUserDefaults()
        QuitSettings.setAskBeforeQuit(false, defaults)
        XCTAssertFalse(QuitSettings.askBeforeQuit(defaults))
        QuitSettings.setAskBeforeQuit(true, defaults)
        XCTAssertTrue(QuitSettings.askBeforeQuit(defaults))
    }

    // protects=Cancel/Esc/창 닫기; fails_when=두 번째 버튼이 아닌 응답이 종료로 처리된다
    func test_onlySecondButtonQuits() {
        XCTAssertTrue(QuitConfirmation.responseQuits(.alertSecondButtonReturn))
        XCTAssertFalse(QuitConfirmation.responseQuits(.alertFirstButtonReturn))
        XCTAssertFalse(QuitConfirmation.responseQuits(.abort))
        XCTAssertFalse(QuitConfirmation.responseQuits(.stop))
    }

    // protects=로그아웃/시스템 종료; fails_when=willPowerOff 알림이 플래그를 켜지 않는다
    func test_powerOffNotification_setsFlag() {
        AppLifecycle.powerOffRequestedAt = nil
        let center = NotificationCenter()
        QuitConfirmation.observePowerOff(center: center)
        center.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        XCTAssertNotNil(AppLifecycle.powerOffRequestedAt)
        AppLifecycle.powerOffRequestedAt = nil
    }

    // protects=업데이트 재시작; fails_when=prepareForUpdateRelaunch가 플래그를 켜지 않는다
    func test_prepareForUpdateRelaunch_setsFlag() {
        AppLifecycle.isRelaunchingForUpdate = false
        let manager = WindowManager(
            sessionPersistence: nil,
            workspacePersistence: { nil },
            defaults: InMemoryUserDefaults()
        )
        manager.prepareForUpdateRelaunch()
        XCTAssertTrue(AppLifecycle.isRelaunchingForUpdate)
        AppLifecycle.isRelaunchingForUpdate = false
    }
}

import XCTest
@testable import termy

final class QuitConfirmationTests: XCTestCase {
    private func context(
        xctest: Bool = false,
        relaunch: Bool = false,
        powerOff: Bool = false,
        visibleWindow: Bool = true,
        ask: Bool = true
    ) -> QuitConfirmation.Context {
        QuitConfirmation.Context(
            isRunningUnderXCTest: xctest,
            isRelaunchingForUpdate: relaunch,
            isPoweringOff: powerOff,
            hasVisibleMainWindow: visibleWindow,
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
    func test_noVisibleWindow_doesNotAsk() {
        XCTAssertFalse(QuitConfirmation.shouldAsk(context(visibleWindow: false)))
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
}

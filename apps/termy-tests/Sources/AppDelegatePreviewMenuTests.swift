import XCTest
@testable import termy

@MainActor
final class AppDelegatePreviewMenuTests: XCTestCase {
    private func state(_ action: Selector, previewIsKey: Bool) -> (isEnabled: Bool, title: String?) {
        AppDelegate.previewMenuState(for: action, previewIsKey: previewIsKey)
    }

    func test_closeItemClosesPreviewWhilePreviewIsKey() {
        let close = #selector(AppDelegate.closePane(_:))
        XCTAssertTrue(state(close, previewIsKey: true).isEnabled)
        XCTAssertEqual(state(close, previewIsKey: true).title, "Close Preview")
        XCTAssertTrue(state(close, previewIsKey: false).isEnabled)
        XCTAssertEqual(state(close, previewIsKey: false).title, "Close Pane")
    }

    func test_paneActionsDisabledOnlyWhilePreviewIsKey() {
        let paneActions: [Selector] = [
            #selector(AppDelegate.newPane(_:)),
            #selector(AppDelegate.splitRow(_:)),
            #selector(AppDelegate.splitColumn(_:)),
            #selector(AppDelegate.toggleMaximizePane(_:)),
            #selector(AppDelegate.focusNextPane(_:)),
            #selector(AppDelegate.focusPaneLeft(_:)),
            #selector(AppDelegate.cycleFilterNext(_:)),
            #selector(AppDelegate.selectFilter3(_:)),
            #selector(AppDelegate.showProjectSwitcher(_:)),
            #selector(AppDelegate.increaseFontSize(_:)),
            #selector(AppDelegate.cycleWaitingPane(_:)),
            #selector(AppDelegate.selectDashboard2(_:)),
        ]
        for action in paneActions {
            XCTAssertFalse(state(action, previewIsKey: true).isEnabled, "\(action)")
            XCTAssertTrue(state(action, previewIsKey: false).isEnabled, "\(action)")
            XCTAssertNil(state(action, previewIsKey: true).title, "\(action)")
        }
    }

    func test_appWideActionsStayEnabled() {
        let appActions: [Selector] = [
            #selector(AppDelegate.newWindow(_:)),
            #selector(AppDelegate.useDarkAppearance(_:)),
            #selector(AppDelegate.openNotificationSettings(_:)),
        ]
        for action in appActions {
            XCTAssertTrue(state(action, previewIsKey: true).isEnabled, "\(action)")
        }
    }
}

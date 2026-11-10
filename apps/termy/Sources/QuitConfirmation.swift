// QuitConfirmation.swift
//
// "Quit termy?" 판단. 모든 종료 요청(⌘Q, Dock Quit, AppleScript quit)이
// `applicationShouldTerminate`를 지나므로 거기서 한 번만 묻는다. 다만 그 훅에는
// 사용자의 ⌘Q가 아닌 종료도 함께 지난다 — 업데이트 재시작, 로그아웃/시스템 종료,
// 마지막 창 닫기 — 그리고 그 자리에서 모달이 뜨면 Sparkle 재시작이나 로그아웃이
// 붙잡힌다. 그 경우를 여기서 걸러 낸다.

import AppKit

enum QuitConfirmation {
    /// `applicationShouldTerminate`가 채우는 입력. 테스트가 직접 만든다.
    struct Context {
        var isRunningUnderXCTest = false
        var isRelaunchingForUpdate = false
        var isPoweringOff = false
        var hasVisibleMainWindow = true
        var askBeforeQuit = true
    }

    /// 확인 창을 띄울지. 설정이 켜져 있고, 사용자의 ⌘Q이며, 잃을 pane이 남아 있을 때만 묻는다.
    static func shouldAsk(_ context: Context) -> Bool {
        !context.isRunningUnderXCTest
            && !context.isRelaunchingForUpdate
            && !context.isPoweringOff
            && context.hasVisibleMainWindow
            && context.askBeforeQuit
    }

    /// 모달 응답 중 앱을 끝내는 것은 두 번째 버튼(Quit)뿐. Esc·창 닫기·Cancel은 모두 취소다.
    static func responseQuits(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }

    /// 로그아웃/시스템 종료 요청을 관찰한다. AppKit이 종료 요청보다 먼저 보낸다.
    @MainActor static func observePowerOff(center: NotificationCenter) {
        center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLifecycle.isPoweringOff = true }
        }
    }

    /// 확인 창을 띄운다. Quit이면 true.
    @MainActor static func presentAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit termy?"
        alert.informativeText = "Programs running in panes will be stopped."
        // 첫 버튼이 기본(Return)이다. 확인 창에서 Return이 곧 종료가 되면 안 되므로
        // Cancel을 첫 버튼에 둔다. Esc는 NSAlert가 자동으로 매기지 않아 직접 받아
        // 취소로 돌린다 — 실수로 끝나는 쪽이 아니라 안 끝나는 쪽이 기본이다.
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = "\r"
        alert.addButton(withTitle: "Quit")
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event } // Esc
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        return responseQuits(alert.runModal())
    }

    /// `applicationShouldTerminate`가 채우는 입력.
    @MainActor static func context(
        windowManager: WindowManager,
        defaults: UserDefaults = .standard
    ) -> Context {
        Context(
            isRunningUnderXCTest: TestHostDetector.isRunningUnderXCTest(),
            isRelaunchingForUpdate: AppLifecycle.isRelaunchingForUpdate,
            isPoweringOff: AppLifecycle.isPoweringOff,
            hasVisibleMainWindow: windowManager.controllers.contains { $0.window?.isVisible == true },
            askBeforeQuit: QuitSettings.askBeforeQuit(defaults)
        )
    }
}

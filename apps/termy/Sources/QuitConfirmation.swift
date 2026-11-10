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
        var hasMainWindow = true
        var askBeforeQuit = true
    }

    /// 로그아웃/시스템 종료 요청으로 봐 주는 시간. 그 뒤에 오는 종료 요청은
    /// 시스템이 보낸 것이라 묻지 않는다. 이보다 오래된 요청은 무시한다 —
    /// 로그아웃이 취소된 뒤의 ⌘Q는 다시 물어야 한다.
    static let powerOffWindow: TimeInterval = 30

    /// 확인 창을 띄울지. 설정이 켜져 있고, 사용자의 ⌘Q이며, 잃을 pane이 남아 있을 때만 묻는다.
    static func shouldAsk(_ context: Context) -> Bool {
        !context.isRunningUnderXCTest
            && !context.isRelaunchingForUpdate
            && !context.isPoweringOff
            && context.hasMainWindow
            && context.askBeforeQuit
    }

    /// `requestedAt`이 최근 `powerOffWindow` 안이면 지금 시스템이 앱을 끝내려는 중이다.
    static func isPoweringOff(_ requestedAt: Date?, now: Date = Date()) -> Bool {
        guard let requestedAt else { return false }
        return now.timeIntervalSince(requestedAt) < powerOffWindow
    }

    /// 모달 응답 중 앱을 끝내는 것은 두 번째 버튼(Quit)뿐. Esc·창 닫기·Cancel은 모두 취소다.
    static func responseQuits(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }

    /// 로그아웃/시스템 종료 요청을 관찰한다. AppKit이 종료 요청보다 먼저 보낸다.
    @MainActor static func observePowerOff(center: NotificationCenter) {
        center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLifecycle.powerOffRequestedAt = Date() }
        }
    }

    /// 확인 창. 첫 버튼이 기본(Return)이다 — 확인 창에서 Return이 곧 종료가 되면 안 되므로
    /// Cancel을 첫 버튼에 둔다.
    @MainActor static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quit termy?"
        alert.informativeText = "Programs running in panes will be stopped."
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = "\r"
        alert.addButton(withTitle: "Quit")
        return alert
    }

    /// 확인 창을 띄운다. Quit이면 true. Esc도 취소다 — NSAlert는 Esc를 스스로 매기지 않으므로
    /// 모달이 도는 동안만 키 이벤트를 엿본다.
    @MainActor static func presentAlert() -> Bool {
        // 다른 앱 뒤에서 스크립트나 Dock으로 온 종료 요청이면 창이 가려진 채 모달이 돌아
        // 앱이 멈춘 것처럼 보인다. 확인 창은 반드시 앞으로 가져온다.
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)

        let alert = makeAlert()
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event } // Esc
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        let response = alert.runModal()
        // stopModal로 빠져나온 경우까지 확실히 치운다(이미 닫혔으면 no-op).
        alert.window.orderOut(nil)
        return responseQuits(response)
    }

    /// `applicationShouldTerminate`가 채우는 입력.
    @MainActor static func context(
        windowManager: WindowManager,
        defaults: UserDefaults = .standard
    ) -> Context {
        Context(
            isRunningUnderXCTest: TestHostDetector.isRunningUnderXCTest(),
            isRelaunchingForUpdate: AppLifecycle.isRelaunchingForUpdate,
            isPoweringOff: isPoweringOff(AppLifecycle.powerOffRequestedAt),
            // 창이 숨겨졌는지(⌘H)가 아니라 남아 있는지로 본다. 숨긴 창의 pane은 살아 있다.
            // 마지막 창을 닫는 길은 그 전에 WindowManager.controllers가 비워진다.
            hasMainWindow: !windowManager.controllers.isEmpty,
            askBeforeQuit: QuitSettings.askBeforeQuit(defaults)
        )
    }
}

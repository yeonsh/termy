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
}

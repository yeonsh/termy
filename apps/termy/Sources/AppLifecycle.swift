import Foundation

// 앱이 끝나는 중인지, 그리고 끝나기 직전에 main actor가 필요한 일을 어떻게 기다리는지.
// hc pane은 "사용자가 닫음"(terminal.kill)과 "앱이 끝나며 정리됨"(terminal은 남겨 다음 실행 때 다시 붙음)을 갈라야
// 한다. ⌘Q·업데이트 재시작·로그아웃은 applicationShouldTerminate에서 isTerminating을 켠다. 마지막 창 닫기는 창이 먼저
// 닫히고(그때는 아직 꺼져 있어 kill) 그 결과로 앱이 끝난다.
// 종료 직전의 기다림은 main을 semaphore로 막지 않고 main run loop를 돌린다. HcSessionManager의 kill 응답 처리는
// main actor에서 끝나므로 main을 막으면 timeout까지 끝나지 못한다(kill 쓰기 자체는 main 없이 이미 나가 있다).

enum AppLifecycle {
    @MainActor static var isTerminating = false

    /// Sparkle이 업데이트를 설치하려 앱을 다시 띄우는 중. ⌘Q 확인을 건너뛴다.
    @MainActor static var isRelaunchingForUpdate = false

    /// 사용자가 로그아웃/시스템 종료를 요청했다(`willPowerOffNotification`).
    /// 그 뒤에 오는 종료 요청에 모달을 띄우면 로그아웃이 붙잡힌다.
    @MainActor static var isPoweringOff = false

    /// `work`가 끝나거나 `timeout`이 지날 때까지 main run loop를 돌린다. 끝났으면 true.
    /// main queue의 block 안(GCD callout)에서 부르면 run loop가 main queue를 비우지 않으므로 그때는 timeout까지 기다린다.
    @MainActor @discardableResult
    static func runMainLoop(timeout: TimeInterval, _ work: @escaping @Sendable @MainActor () async -> Void) -> Bool {
        let done = Flag()
        let task = Task { @MainActor in
            await work()
            done.value = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done.value {
            let now = Date()
            guard now < deadline else { break }
            // source 하나를 처리하면 돌아온다. 그 mode에 source가 없으면 곧바로 false라서 잠깐 쉰다.
            if !RunLoop.main.run(mode: .default, before: min(deadline, now.addingTimeInterval(0.01))) {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        if !done.value { task.cancel() }
        return done.value
    }

    /// 보류 중인 terminal.kill이 hc의 응답을 받을 때까지(최대 timeout) 기다린다. 모두 받았으면 true.
    /// applicationWillTerminate가 부른다: 마지막 창을 닫으면 kill을 보낸 직후 앱이 끝나기 때문이다.
    @MainActor @discardableResult
    static func waitForPendingHcKills(_ manager: HcSessionManager, timeout: TimeInterval) -> Bool {
        guard manager.hasPendingKills else { return true }
        runMainLoop(timeout: timeout) {
            await manager.flushPendingKills(timeout: timeout)
        }
        return !manager.hasPendingKills
    }

    @MainActor private final class Flag { var value = false }
}

/// ⌘Q 확인 대화상자를 띄울지. 기본은 켜짐 — pane에서 돌던 작업은 종료와 함께 사라지고
/// 복원되지 않는다. ⌘, 설정 패널과 `QuitConfirmation`이 함께 읽는다.
enum QuitSettings {
    static let askBeforeQuitKey = "termy.quit.askBeforeQuit"

    static func askBeforeQuit(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: askBeforeQuitKey) as? Bool ?? true
    }

    static func setAskBeforeQuit(_ enabled: Bool, _ defaults: UserDefaults) {
        defaults.set(enabled, forKey: askBeforeQuitKey)
    }
}

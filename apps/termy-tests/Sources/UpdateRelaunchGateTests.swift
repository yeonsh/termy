import XCTest
@testable import termy

@MainActor
private final class Harness {
    var busy = 0
    let clock = ManualScheduler()
    var promptCounts: [Int] = []
    var answer: (@MainActor (UpdateRelaunchChoice) -> Void)?
    let installs = Counter()
    let pendingChanges = Counter()
    private(set) lazy var gate: UpdateRelaunchGate = {
        let gate = UpdateRelaunchGate(
            midTurnCount: { [unowned self] in self.busy },
            schedule: clock.schedule,
            presentPrompt: { [unowned self] count, completion in
                self.promptCounts.append(count)
                self.answer = completion
            }
        )
        gate.onPendingChanged = { [pendingChanges] in pendingChanges.value += 1 }
        return gate
    }()

    @discardableResult
    func begin() -> Bool {
        gate.begin { [installs] in installs.value += 1 }
    }
}

@MainActor
final class UpdateRelaunchGateTests: XCTestCase {
    func test_noBusyAgents_relaunchesWithoutPrompt() {
        let h = Harness()
        XCTAssertFalse(h.begin())
        XCTAssertEqual(h.promptCounts, [])
        XCTAssertFalse(h.gate.isPending)
    }

    func test_busyAgents_promptWithCountAndPostpone() {
        let h = Harness()
        h.busy = 2
        XCTAssertTrue(h.begin())
        XCTAssertEqual(h.promptCounts, [2])
        XCTAssertTrue(h.gate.isPending)
        XCTAssertEqual(h.installs.value, 0)
    }

    func test_restartNowChoice_installsImmediately() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.restartNow)
        XCTAssertEqual(h.installs.value, 1)
        XCTAssertFalse(h.gate.isPending)
    }

    func test_wait_releasesAfterSettleDelayOnceIdle() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.waitForAgents)
        h.busy = 0
        h.gate.reevaluate()
        h.clock.advance(by: UpdateRelaunchGate.settleDelay - 0.01)
        XCTAssertEqual(h.installs.value, 0)
        h.clock.advance(by: 0.02)
        XCTAssertEqual(h.installs.value, 1)
    }

    func test_wait_newTurnDuringSettle_keepsWaiting() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.waitForAgents)
        h.busy = 0
        h.gate.reevaluate()
        h.clock.advance(by: 1)
        h.busy = 1
        h.gate.reevaluate()
        h.clock.advance(by: 5)
        XCTAssertEqual(h.installs.value, 0)
        h.busy = 0
        h.gate.reevaluate()
        h.clock.advance(by: UpdateRelaunchGate.settleDelay)
        XCTAssertEqual(h.installs.value, 1)
    }

    func test_wait_settleRecheckSeesNewTurnWithoutReevaluate() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.waitForAgents)
        h.busy = 0
        h.gate.reevaluate()
        h.busy = 1                       // no reevaluate call in between
        h.clock.advance(by: UpdateRelaunchGate.settleDelay)
        XCTAssertEqual(h.installs.value, 0)
        XCTAssertTrue(h.gate.isPending)
    }

    func test_noAutoReleaseWhilePromptIsShowing() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.busy = 0
        h.gate.reevaluate()
        h.clock.advance(by: 10)
        XCTAssertEqual(h.installs.value, 0)
        h.answer?(.waitForAgents)        // already idle → settle starts now
        h.clock.advance(by: UpdateRelaunchGate.settleDelay)
        XCTAssertEqual(h.installs.value, 1)
    }

    func test_menuRestartNow_whileWaiting_installs() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.waitForAgents)
        h.gate.restartNow()
        XCTAssertEqual(h.installs.value, 1)
    }

    func test_handlerRunsOnlyOnce() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.waitForAgents)
        h.gate.restartNow()
        h.gate.restartNow()
        h.busy = 0
        h.gate.reevaluate()
        h.clock.advance(by: 10)
        h.answer?(.restartNow)           // late alert answer
        XCTAssertEqual(h.installs.value, 1)
    }

    func test_onPendingChanged_firesOnEnterAndExitOnly() {
        let h = Harness()
        h.busy = 1
        h.begin()                        // idle → prompting
        h.answer?(.waitForAgents)        // prompting → waiting (still pending)
        h.gate.restartNow()              // waiting → released
        XCTAssertEqual(h.pendingChanges.value, 2)
    }

    func test_choiceForResponse_onlySecondButtonRestarts() {
        XCTAssertEqual(UpdateRelaunchGate.choice(for: .alertFirstButtonReturn), .waitForAgents)
        XCTAssertEqual(UpdateRelaunchGate.choice(for: .alertSecondButtonReturn), .restartNow)
        XCTAssertEqual(UpdateRelaunchGate.choice(for: .abort), .waitForAgents)
        XCTAssertEqual(UpdateRelaunchGate.choice(for: .stop), .waitForAgents)
        XCTAssertEqual(UpdateRelaunchGate.choice(for: .cancel), .waitForAgents)
    }

    func test_beginWhilePending_replacesHandlerWithoutSecondPrompt() {
        let h = Harness()
        h.busy = 1
        let a = Counter()
        let b = Counter()
        XCTAssertTrue(h.gate.begin { a.value += 1 })
        XCTAssertTrue(h.gate.begin { b.value += 1 })
        XCTAssertEqual(h.promptCounts, [1])
        h.answer?(.restartNow)
        XCTAssertEqual(a.value, 0)
        XCTAssertEqual(b.value, 1)
    }

    func test_beginAfterRelease_promptsAgainNextCycle() {
        let h = Harness()
        h.busy = 1
        h.begin()
        h.answer?(.restartNow)
        XCTAssertEqual(h.installs.value, 1)
        XCTAssertTrue(h.begin())
        XCTAssertEqual(h.promptCounts, [1, 1])
    }

    func test_promptTitle_singularAndPlural() {
        XCTAssertEqual(UpdateRelaunchGate.promptTitle(busyCount: 1), "1 agent is still working")
        XCTAssertEqual(UpdateRelaunchGate.promptTitle(busyCount: 3), "3 agents are still working")
    }
}

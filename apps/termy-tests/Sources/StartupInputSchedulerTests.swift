import XCTest
@testable import termy

@MainActor
final class StartupInputSchedulerTests: XCTestCase {
    private func make() -> (StartupInputScheduler, ManualScheduler, Counter) {
        let clock = ManualScheduler()
        let fired = Counter()
        let scheduler = StartupInputScheduler(schedule: clock.schedule) { fired.value += 1 }
        return (scheduler, clock, fired)
    }

    func test_firesAfterOutputGoesQuiet() {
        let (scheduler, clock, fired) = make()
        scheduler.start()
        clock.advance(by: 0.1)
        scheduler.outputReceived()
        clock.advance(by: 0.2)
        scheduler.outputReceived()          // restarts the quiet window
        clock.advance(by: 0.29)
        XCTAssertEqual(fired.value, 0)
        clock.advance(by: 0.02)
        XCTAssertEqual(fired.value, 1)
    }

    func test_firesAtDeadlineWithoutOutput() {
        let (scheduler, clock, fired) = make()
        scheduler.start()
        clock.advance(by: 2.99)
        XCTAssertEqual(fired.value, 0)
        clock.advance(by: 0.02)
        XCTAssertEqual(fired.value, 1)
    }

    // Review Focus 5
    func test_firesAtDeadlineEvenWhileOutputKeepsFlowing() {
        let (scheduler, clock, fired) = make()
        scheduler.start()
        for _ in 0..<50 {
            clock.advance(by: 0.1)
            scheduler.outputReceived()
        }
        XCTAssertEqual(fired.value, 1)
        XCTAssertTrue(scheduler.hasFired)
    }

    func test_firesOnlyOnceAndLeavesNoTimers() {
        let (scheduler, clock, fired) = make()
        scheduler.start()
        scheduler.outputReceived()
        clock.advance(by: 0.3)
        XCTAssertEqual(fired.value, 1)
        scheduler.outputReceived()
        clock.advance(by: 5)
        XCTAssertEqual(fired.value, 1)
        XCTAssertEqual(clock.pendingCount, 0)
    }
}

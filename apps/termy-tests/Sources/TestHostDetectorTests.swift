// TestHostDetectorTests.swift
//
// The unit-test target loads termy.app as its TEST_HOST, so the real
// AppDelegate runs inside every test process. These tests pin down the
// detector that AppDelegate uses to skip launch-time side effects (hook
// installers, first-run prompts) in that mode.

import XCTest
@testable import termy

final class TestHostDetectorTests: XCTestCase {

    func test_isRunningUnderXCTest_withConfigurationPath_isTrue() {
        XCTAssertTrue(
            TestHostDetector.isRunningUnderXCTest(
                environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
            )
        )
    }

    func test_isRunningUnderXCTest_withoutXCTestKeys_isFalse() {
        XCTAssertFalse(
            TestHostDetector.isRunningUnderXCTest(
                environment: ["HOME": "/Users/someone", "PATH": "/usr/bin"]
            )
        )
    }

    func test_currentTestHostProcess_isDetected() {
        // Must hold for the real host environment, otherwise the AppDelegate
        // guard is a no-op and a test run rewrites ~/.claude and ~/.codex.
        XCTAssertTrue(TestHostDetector.isRunningUnderXCTest())
    }
}

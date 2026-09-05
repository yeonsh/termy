// TestHostDetector.swift
//
// The unit-test target loads termy.app as its TEST_HOST, which means the
// real AppDelegate runs inside every test process. Launch-time side effects
// that touch the user's home directory (hook installers, first-run prompts)
// must be skipped in that mode — otherwise a plain `xcodebuild test` silently
// rewrites ~/.claude and ~/.codex to point at the DerivedData build.

import Foundation

enum TestHostDetector {
    /// Environment keys Xcode injects into an XCTest host process.
    static let markerKeys = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCTestSessionIdentifier",
    ]

    static func isRunningUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        markerKeys.contains { environment[$0] != nil }
    }
}

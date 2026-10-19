// OpenCodePluginInstallerTests.swift
//
// State detection and file I/O for the termy-owned opencode TUI plugin.
//
// protects=file-state detection plus safe install/uninstall; fails_when=a
// foreign file is overwritten or another file is deleted, or a read failure is
// classified as a different state; no_claim=that opencode loads a plugin from
// this path (spike S1) — the tests use a temporary directory instead of home.

import XCTest
@testable import termy

final class OpenCodePluginInstallerTests: XCTestCase {
    private var root: URL!
    private var pluginFile: URL { root.appendingPathComponent("plugins/termy/tui.js") }
    private let template = """
    // termy-managed opencode plugin. termy rewrites this file; do not edit.
    const TERMY_HOOK_PATH = "__TERMY_HOOK_PATH__"

    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodePluginInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func expected(_ hook: String = "/Applications/termy.app/Contents/Resources/termy-hook") -> String {
        OpenCodePluginInstaller.pluginSource(template: template, hookPath: hook)
    }

    private func contents() throws -> String { try String(contentsOf: pluginFile, encoding: .utf8) }

    func test_pluginSource_writesHookPathAsJSONStringLiteral() {
        let s = OpenCodePluginInstaller.pluginSource(template: template, hookPath: #"/Volumes/x y/"q"\b/termy-hook"#)
        XCTAssertFalse(s.contains("__TERMY_HOOK_PATH__"))
        XCTAssertTrue(s.contains(#"const TERMY_HOOK_PATH = "/Volumes/x y/\"q\"\\b/termy-hook""#))
    }

    func test_state_missingFile_isNotInstalled() {
        XCTAssertEqual(OpenCodePluginInstaller.currentState(pluginFileURL: pluginFile, expected: expected()), .notInstalled)
    }

    func test_state_sameBytes_isInstalledCurrent() throws {
        try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected())
        XCTAssertEqual(OpenCodePluginInstaller.currentState(pluginFileURL: pluginFile, expected: expected()), .installedCurrent)
    }

    func test_state_termyFileWithOtherContents_isInstalledStale() throws {
        try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected("/old/termy.app/Contents/Resources/termy-hook"))
        XCTAssertEqual(OpenCodePluginInstaller.currentState(pluginFileURL: pluginFile, expected: expected()), .installedStale)
    }

    func test_state_unreadablePath_isConfigError() throws {
        // A directory where tui.js should be: fileExists is true, reading fails.
        try FileManager.default.createDirectory(at: pluginFile, withIntermediateDirectories: true)
        guard case .configError = OpenCodePluginInstaller.currentState(pluginFileURL: pluginFile, expected: expected()) else {
            return XCTFail("expected .configError")
        }
    }

    func test_state_fileWithoutMarker_isForeign() throws {
        try FileManager.default.createDirectory(at: pluginFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default {}\n".write(to: pluginFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(OpenCodePluginInstaller.currentState(pluginFileURL: pluginFile, expected: expected()),
                       .foreign(path: pluginFile.path))
    }

    func test_install_createsDirectoriesAndWritesExactContents() throws {
        try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected())
        XCTAssertEqual(try contents(), expected())
    }

    // protects=never overwrite or delete a file termy didn't write; fails_when=foreign bytes change;
    // no_claim=what opencode does with the folder (Task 1 S1)
    func test_installAndUninstall_refuseForeignFile() throws {
        try FileManager.default.createDirectory(at: pluginFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default {}\n".write(to: pluginFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected()))
        XCTAssertThrowsError(try OpenCodePluginInstaller.uninstall(pluginFileURL: pluginFile))
        XCTAssertEqual(try contents(), "export default {}\n")
    }

    func test_uninstall_removesFileAndEmptyDir_keepsSiblings() throws {
        let fm = FileManager.default
        let sibling = root.appendingPathComponent("plugins/other/tui.js")
        try fm.createDirectory(at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: sibling, atomically: true, encoding: .utf8)
        try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected())
        try OpenCodePluginInstaller.uninstall(pluginFileURL: pluginFile)
        XCTAssertFalse(fm.fileExists(atPath: pluginFile.deletingLastPathComponent().path))
        XCTAssertTrue(fm.fileExists(atPath: sibling.path))

        // A non-empty termy folder keeps everything except tui.js.
        try OpenCodePluginInstaller.install(pluginFileURL: pluginFile, contents: expected())
        let note = pluginFile.deletingLastPathComponent().appendingPathComponent("notes.txt")
        try "keep".write(to: note, atomically: true, encoding: .utf8)
        try OpenCodePluginInstaller.uninstall(pluginFileURL: pluginFile)
        XCTAssertFalse(fm.fileExists(atPath: pluginFile.path))
        XCTAssertTrue(fm.fileExists(atPath: note.path))
    }
}

import XCTest
@testable import termy

final class HcLocatorTests: XCTestCase {
    private func makeExecutable(in dir: URL, mode: Int = 0o755) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("herdr-core")
        FileManager.default.createFile(atPath: exe.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: mode])
        return exe
    }

    func testLocatorPrefersLocalBinThenPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("bin")
        let exe = try makeExecutable(in: bin)
        XCTAssertEqual(HcLocator.find(environment: ["HOME": "/nonexistent", "PATH": bin.path])?.path, exe.path)
        XCTAssertNil(HcLocator.find(environment: ["HOME": "/nonexistent", "PATH": "/nonexistent"]))

        // ~/.local/bin이 PATH보다 먼저다.
        let home = tmp.appendingPathComponent("home")
        let local = try makeExecutable(in: home.appendingPathComponent(".local/bin"))
        XCTAssertEqual(HcLocator.find(environment: ["HOME": home.path, "PATH": bin.path])?.path, local.path)
    }

    func testLocatorSkipsNonExecutableFiles() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let plain = tmp.appendingPathComponent("plain")
        _ = try makeExecutable(in: plain, mode: 0o644)
        let bin = tmp.appendingPathComponent("bin")
        let exe = try makeExecutable(in: bin)
        XCTAssertEqual(HcLocator.find(environment: ["HOME": "/nonexistent", "PATH": "\(plain.path):\(bin.path)"])?.path, exe.path)
    }

    func testMinimalEnvironmentDropsAgentMarkers() {
        let env = HcEndpoint.minimalEnvironment(base: ["HOME": "/h", "CLAUDECODE": "1", "TERM_PROGRAM": "ghostty", "LANG": "ko_KR.UTF-8"])
        XCTAssertEqual(env, ["HOME": "/h", "LANG": "ko_KR.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    func testMinimalEnvironmentKeepsSSHAgentSocket() {
        // core가 원격 머신에 ssh로 붙을 때 agent 키를 쓰려면 SSH_AUTH_SOCK이 넘어가야 한다.
        let env = HcEndpoint.minimalEnvironment(base: ["HOME": "/h", "SSH_AUTH_SOCK": "/tmp/agent.sock", "CLAUDECODE": "1"])
        XCTAssertEqual(env, ["HOME": "/h", "SSH_AUTH_SOCK": "/tmp/agent.sock", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    func testProcessEnvironmentAddsSessionAndExtrasOnly() {
        let endpoint = HcEndpoint(executable: URL(fileURLWithPath: "/x/herdr-core"), session: "s1",
                                  extraEnvironment: ["XDG_STATE_HOME": "/st"])
        let env = endpoint.processEnvironment(base: ["HOME": "/h", "HC_SOCKET": "/user.sock", "HC_SESSION": "default", "CHILD_SESSION": "1"])
        XCTAssertEqual(env, ["HOME": "/h", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HC_SESSION": "s1", "XDG_STATE_HOME": "/st"])
        let noSession = HcEndpoint(executable: URL(fileURLWithPath: "/x/herdr-core"))
        XCTAssertNil(noSession.processEnvironment(base: ["HC_SESSION": "default"])["HC_SESSION"])
    }
}

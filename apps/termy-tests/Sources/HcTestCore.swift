import XCTest
@testable import termy

// 통합 테스트용 scratch herdr-core. 사용자의 core(`default` session)를 절대 건드리지 않도록
// 전용 HC_SESSION과 /tmp 아래 임시 XDG_STATE_HOME/XDG_CONFIG_HOME/XDG_RUNTIME_DIR로만 띄운다.
// Unix socket 경로는 ~104바이트 제한이 있어 깊은 FileManager.temporaryDirectory 대신 짧은
// `/tmp/hct-<8 hex>`를 쓴다. core는 `herdr-core connect`가 처음 붙을 때 스스로 뜬다.

final class HcTestCore: Sendable {
    let endpoint: HcEndpoint
    let root: URL

    private init(endpoint: HcEndpoint, root: URL) {
        self.endpoint = endpoint
        self.root = root
    }

    static func makeOrSkip() throws -> HcTestCore {
        guard let exe = HcLocator.find(environment: ProcessInfo.processInfo.environment) else {
            throw XCTSkip("herdr-core is not installed")
        }
        let tag = String(UUID().uuidString.prefix(8)).lowercased()
        let root = URL(fileURLWithPath: "/tmp/hct-\(tag)", isDirectory: true)
        var extra: [String: String] = [:]
        for (key, sub) in [("XDG_STATE_HOME", "state"), ("XDG_CONFIG_HOME", "config"), ("XDG_RUNTIME_DIR", "run")] {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            extra[key] = dir.path
        }
        let endpoint = HcEndpoint(executable: exe, session: "termy-test-\(tag)", extraEnvironment: extra)
        return HcTestCore(endpoint: endpoint, root: root)
    }

    /// scratch endpoint로 만든 새 연결에서만 server.stop을 보내고, 연결이 끊길 때까지 기다린 뒤 디렉터리를 지운다.
    func stop() async {
        let conn = HcConnection(endpoint: endpoint)
        if (try? await conn.open()) != nil {
            let _: StopResult? = try? await conn.call("server.stop", HcEmptyParams())
            let disconnected = conn.disconnected
            _ = try? await hcWithTimeout(5) {
                for await _ in disconnected { return true }
                return true
            }
        }
        await conn.close()
        try? FileManager.default.removeItem(at: root)
    }

    private struct StopResult: Decodable, Sendable { let stopped: Bool }
}

struct HcTimeoutError: Error {}

/// op가 seconds 안에 끝나지 않으면 HcTimeoutError를 던진다. op는 취소를 따라야 한다(AsyncStream 순회는 따른다).
func hcWithTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw HcTimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw HcTimeoutError() }
        return first
    }
}

import Foundation

// herdr-core 실행 파일을 찾고, `herdr-core connect` 프로세스에 줄 환경을 만든다.
// 앱 환경에는 agent marker(CLAUDECODE 등)나 사용자 core를 가리키는 HC_SOCKET/HC_SESSION이 섞여 있을 수
// 있다. connect가 core를 새로 띄우면 그 환경을 물려받으므로 필요한 키만 골라 넘긴다.

enum HcLocator {
    /// `~/.local/bin`, Homebrew 두 곳, 그다음 PATH 순서로 실행 가능한 `herdr-core`를 찾는다.
    static func find(environment: [String: String], fileManager: FileManager = .default) -> URL? {
        var candidates: [String] = []
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append((home as NSString).appendingPathComponent(".local/bin/herdr-core"))
        }
        candidates += ["/opt/homebrew/bin/herdr-core", "/usr/local/bin/herdr-core"]
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            candidates.append((String(dir) as NSString).appendingPathComponent("herdr-core"))
        }
        for path in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

struct HcEndpoint: Sendable {
    var executable: URL
    var session: String?
    var extraEnvironment: [String: String]

    init(executable: URL, session: String? = nil, extraEnvironment: [String: String] = [:]) {
        self.executable = executable
        self.session = session
        self.extraEnvironment = extraEnvironment
    }

    private static let inheritedKeys = ["HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR"]

    static func minimalEnvironment(base: [String: String]) -> [String: String] {
        var env = base.filter { inheritedKeys.contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    /// connect 프로세스가 실제로 받는 환경: minimal + HC_SESSION(있으면) + extraEnvironment.
    func processEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = Self.minimalEnvironment(base: base)
        if let session { env["HC_SESSION"] = session }
        env.merge(extraEnvironment) { _, extra in extra }
        return env
    }
}

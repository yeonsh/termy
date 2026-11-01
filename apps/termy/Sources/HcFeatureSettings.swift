import Foundation

// "Run local panes in herdr-core" 설정과 그 상태 줄. 기본은 꺼짐이다: local pane은 지금까지처럼 termy가 직접
// 띄운 PTY 셸이고, 켜면 새로 만드는 local pane만 herdr-core terminal이 된다(이미 열린 pane은 그대로다).
// 상태 줄은 패널을 열 때 core에 연결하지 않고(연결하면 core가 뜬다) 이미 있는 availability와 locator 결과만 쓴다.

enum HcFeatureSettings {
    static let localPanesKey = "termy.herdrCore.localPanes"

    static func localPanesEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: localPanesKey) as? Bool ?? false
    }

    static func setLocalPanesEnabled(_ on: Bool, _ defaults: UserDefaults) {
        defaults.set(on, forKey: localPanesKey)
    }

    /// 설정 패널 상태 줄. `installedVersion`은 `herdr-core --version`의 결과(설치돼 있을 때만 의미 있다).
    /// 연결이 없는 상태(첫 상태 `.unavailable("not connected")`와 등록된 pane이 없는 `.connecting` 포함)는
    /// 실패가 아니므로 설치된 버전만 보여 준다.
    static func statusLine(availability: HcAvailability, isInstalled: Bool, installedVersion: String?) -> String {
        switch availability {
        case .connected(let version):
            return "herdr-core \(version) · connected"
        case .notInstalled:
            return "herdr-core: not installed"
        case .unavailable(let reason) where reason != HcSessionManager.notConnectedReason:
            return "herdr-core: unavailable (\(reason))"
        case .unavailable, .connecting:
            guard isInstalled else { return "herdr-core: not installed" }
            if let installedVersion, !installedVersion.isEmpty { return "herdr-core \(installedVersion)" }
            return "herdr-core"
        }
    }

    /// `herdr-core --version` 출력에서 버전만 뽑는다("herdr-core 0.4.1" → "0.4.1", "0.4.1" → "0.4.1").
    static func parseVersion(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        let prefix = "herdr-core"
        if line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return line
    }

    /// `herdr-core --version`만 실행한다(버전만 찍고 core를 건드리지 않는다). 실패하면 nil.
    static func runVersion(executable: URL, environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.environment = HcEndpoint.minimalEnvironment(base: environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parseVersion(String(decoding: data, as: UTF8.self))
    }
}

extension PaneLaunch {
    /// 사용자가 만드는 새 local pane(새 pane·split)의 backend. 설정이 켜져 있으면 hc, 아니면 local이다.
    static func forNewLocalPane(defaults: UserDefaults) -> PaneLaunch {
        HcFeatureSettings.localPanesEnabled(defaults) ? .hc(machine: nil) : .local
    }

    /// ⌘K로 다시 여는 project의 pane. 닫힌 창의 hc terminal은 죽었으므로 backend가 없는 local 기록은 새 셸이고
    /// 지금 설정을 따른다. 원격이나 backend가 적힌 기록은 기록 그대로다.
    static func forReopenedRecord(_ record: PaneRecord, defaults: UserDefaults) -> PaneLaunch {
        if record.backend == nil, record.machine == nil { return forNewLocalPane(defaults: defaults) }
        return record.launch
    }
}

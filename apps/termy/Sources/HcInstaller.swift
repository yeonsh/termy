import Foundation

// herdr-core 공식 설치 스크립트를 실행한다. 앱 환경 그대로 쓰면 agent marker 등이 섞이므로 core를 띄울 때와
// 같은 minimal 환경으로 돌린다. 끝난 뒤 locator가 실행 파일을 찾아야 성공이다. 테스트는 이 함수를 부르지 않는다.

enum HcInstaller {
    static let command = "curl -fsSL https://releases.herdr.dev/core/install.sh | sh"

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    static func run(output: @escaping @MainActor (String) -> Void) async -> Bool {
        let base = ProcessInfo.processInfo.environment
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = HcEndpoint.minimalEnvironment(base: base)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            await output("Couldn't start the installer: \(error.localizedDescription)\n")
            return false
        }
        let box = ProcessBox(process)
        let handle = pipe.fileHandleForReading
        let status: Int32 = await Task.detached {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                let text = String(decoding: data, as: UTF8.self)
                await MainActor.run { output(text) }
            }
            box.process.waitUntilExit()
            return box.process.terminationStatus
        }.value
        return status == 0 && HcLocator.find(environment: base) != nil
    }
}

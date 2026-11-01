import XCTest
@testable import termy

// hc 없이 HcConnection의 읽기 경로를 확인한다. 가짜 core는 stdin의 hello 한 줄을 읽고
// 미리 만든 바이트 파일을 cat으로 내보내는 sh 스크립트다(파일 하나가 read 한 번에 온다).

final class HcConnectionTests: XCTestCase {
    private static let helloID = 1   // HcConnection은 hello부터 id 1을 쓴다

    private func helloLine(generation: Int = 1, methods: [String] = HcConnection.requiredMethods) throws -> Data {
        let result: [String: Any] = ["generation": generation, "version": "fake", "core": [String: Any](),
                                     "framed": true, "methods": methods, "features": [String]()]
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": Self.helloID, "result": result]
        return try JSONSerialization.data(withJSONObject: msg) + Data("\n".utf8)
    }

    /// 단계마다 파일 하나를 cat으로 내보내는 가짜 `herdr-core`. 단계 사이는 `sleep 0.3`, 끝나면 stdin이 닫힐 때까지 머문다.
    private func fakeCore(_ steps: [Data], exitAfter: Bool = false) throws -> HcEndpoint {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hcfake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var script = "#!/bin/sh\nread line\n"
        for (i, bytes) in steps.enumerated() {
            let file = dir.appendingPathComponent("step\(i)")
            try bytes.write(to: file)
            if i > 0 { script += "sleep 0.3\n" }
            script += "cat '\(file.path)'\n"
        }
        script += exitAfter ? "exit 0\n" : "cat >/dev/null\n"
        let exe = dir.appendingPathComponent("herdr-core")
        FileManager.default.createFile(atPath: exe.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        return HcEndpoint(executable: exe)
    }

    private func openFake(_ steps: [Data], exitAfter: Bool = false) async throws -> HcConnection {
        let conn = HcConnection(endpoint: try fakeCore(steps, exitAfter: exitAfter))
        addTeardownBlock { await conn.close() }
        _ = try await conn.open()
        return conn
    }

    func testFramesInHelloChunkAreBufferedUntilStreamIsRequested() async throws {
        // hello 응답 줄과 channel 5의 first paint, CLOSE가 한 read에 같이 온다.
        let closeJSON = Data(#"{"reason":"exited","exit_code":0}"#.utf8)
        var chunk = try helloLine()
        chunk += HcFrame(channel: 5, kind: .data, payload: Data("first".utf8)).encoded()
        chunk += HcFrame(channel: 5, kind: .data, payload: Data("paint".utf8)).encoded()
        chunk += HcFrame(channel: 5, kind: .close, payload: closeJSON).encoded()
        let conn = try await openFake([chunk])
        let stream = await conn.stream(5)
        let events = try await hcWithTimeout(3) { () -> [String] in
            var out: [String] = []
            for await event in stream {
                switch event {
                case .data(let d): out.append(String(decoding: d, as: UTF8.self))
                case .closed(let p): out.append("closed:" + String(decoding: p ?? Data(), as: UTF8.self))
                }
            }
            return out
        }
        XCTAssertEqual(events, ["first", "paint", "closed:" + String(decoding: closeJSON, as: UTF8.self)])
    }

    func testOpenRejectsOtherGeneration() async throws {
        let conn = HcConnection(endpoint: try fakeCore([try helloLine(generation: 2)]))
        addTeardownBlock { await conn.close() }
        do { _ = try await conn.open(); XCTFail("open succeeded") } catch let e as HcError {
            XCTAssertEqual(e, .incompatibleGeneration(2))
        }
    }

    func testOpenReportsMissingMethods() async throws {
        let methods = HcConnection.requiredMethods.filter { $0 != "machine.exec" && $0 != "terminal.kill" }
        let conn = HcConnection(endpoint: try fakeCore([try helloLine(methods: methods)]))
        addTeardownBlock { await conn.close() }
        do { _ = try await conn.open(); XCTFail("open succeeded") } catch let e as HcError {
            XCTAssertEqual(e, .missingMethods(["terminal.kill", "machine.exec"]))
        }
    }

    func testUnparseableReplyFailsItsCall() async throws {
        // error.data가 객체가 아니라 HcRPC.parse가 실패하는 응답. 그 id의 call은 매달리지 않고 끝나야 한다.
        let reply = Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"x","data":"weird"}}"#.utf8)
        let conn = try await openFake([try helloLine(), HcFrame(channel: 0, kind: .data, payload: reply).encoded()])
        do {
            let _: [String: Int] = try await conn.call("terminal.list", HcEmptyParams())
            XCTFail("call succeeded")
        } catch let e as HcError {
            guard case .protocolViolation = e else { return XCTFail("got \(e)") }
        }
    }

    func testRPCErrorCarriesKind() async throws {
        let reply = Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"no terminal t9","data":{"kind":"not_found"}}}"#.utf8)
        let conn = try await openFake([try helloLine(), HcFrame(channel: 0, kind: .data, payload: reply).encoded()])
        do {
            let _: [String: Int] = try await conn.call("terminal.kill", ["terminal": "t9"])
            XCTFail("call succeeded")
        } catch let e as HcError {
            XCTAssertEqual(e, .rpc(kind: "not_found", message: "no terminal t9"))
        }
    }

    func testClosedConnectionsDoNotLeakFileDescriptors() async throws {
        let endpoint = try fakeCore([try helloLine()])
        func openFDs() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        func cycle() async throws {
            let conn = HcConnection(endpoint: endpoint)
            _ = try await conn.open()
            await conn.close()
        }
        try await cycle()   // 처음 한 번에 생기는 lazy 자원은 기준에 넣는다
        try await Task.sleep(for: .milliseconds(300))
        let before = openFDs()
        for _ in 0..<10 { try await cycle() }
        try await Task.sleep(for: .milliseconds(500))   // reader task와 Process가 놓일 시간
        XCTAssertLessThanOrEqual(openFDs(), before + 3, "pipes from closed connections stay open")
    }

    func testProcessExitFailsPendingCallsAndFinishesStreams() async throws {
        let conn = try await openFake([try helloLine(), Data()], exitAfter: true)
        let stream = await conn.stream(7)
        let disconnected = conn.disconnected
        do {
            let _: [String: Int] = try await conn.call("terminal.list", HcEmptyParams())
            XCTFail("call succeeded")
        } catch let e as HcError {
            XCTAssertEqual(e, .disconnected)
        }
        let finished = try await hcWithTimeout(3) { () -> Bool in
            for await _ in stream {}
            return true
        }
        XCTAssertTrue(finished)
        let reason = try await hcWithTimeout(3) { () -> HcError?? in
            for await r in disconnected { return r }
            return nil
        }
        XCTAssertEqual(reason ?? nil, HcError.disconnected)
    }

    // MARK: - R21: 새 hc pane을 만들어도 되는지(HcSessionManager)

    private func subscribeLine() throws -> Data {
        let result: [String: Any] = ["channel": 1, "seq": 0, "terminals": [Any]()]
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": 2, "result": result]   // hello 다음 요청이 id 2다
        // hello 뒤의 응답은 channel 0의 DATA frame으로 온다.
        return HcFrame(channel: 0, kind: .data, payload: try JSONSerialization.data(withJSONObject: msg)).encoded()
    }

    @MainActor
    private func failToConnect(_ manager: HcSessionManager) async {
        do {
            try await manager.ensureConnected()
            XCTFail("connected")
        } catch {}
    }

    @MainActor
    private final class EndpointBox {
        var endpoint: HcEndpoint?
        init(_ endpoint: HcEndpoint?) { self.endpoint = endpoint }
    }

    /// 아직 연결하지 않았거나 일시적으로 실패했으면 새 pane은 hc다(평소 길). herdr-core가 없거나 core가 hello에서
    /// 이 termy와 맞지 않는다고 답했으면(generation 불일치, method 부족) 새 hc pane을 만들지 않는다(spec §6.10).
    @MainActor
    func testNewPanesAreBlockedOnlyByAKnownHardFailure() async throws {
        let missing = HcSessionManager(endpointProvider: { nil })
        addTeardownBlock { await missing.shutdown() }
        XCTAssertFalse(missing.allowsNewPanes(), "not installed")

        let methods = HcConnection.requiredMethods.filter { $0 != "machine.exec" }
        for core in [try fakeCore([try helloLine(generation: 2)]), try fakeCore([try helloLine(methods: methods)])] {
            let manager = HcSessionManager(endpointProvider: { core })
            addTeardownBlock { await manager.shutdown() }
            XCTAssertTrue(manager.allowsNewPanes(), "not connected yet: the normal path")
            await failToConnect(manager)
            XCTAssertFalse(manager.allowsNewPanes(), "the core rejected this termy in hello")
        }

        // hello 전에 끝난 connect(일시적인 실패)는 막지 않는다.
        let flaky = try fakeCore([], exitAfter: true)
        let manager = HcSessionManager(endpointProvider: { flaky })
        addTeardownBlock { await manager.shutdown() }
        await failToConnect(manager)
        XCTAssertTrue(manager.allowsNewPanes())
    }

    /// 거절된 뒤 새 pane을 만들려 하면 그 pane은 local로 두고 뒤에서 다시 연결해 본다. 그사이 `hc update`로 맞는 core가
    /// 됐으면 다음 새 pane부터 hc다(hc pane이 없으면 다시 연결할 일이 없어 거절이 앱을 다시 켤 때까지 남는다).
    @MainActor
    func testRejectedHelloIsProbedAgainOnTheNextNewPane() async throws {
        let box = EndpointBox(try fakeCore([try helloLine(generation: 2)]))
        let manager = HcSessionManager(endpointProvider: { box.endpoint })
        addTeardownBlock { await manager.shutdown() }
        await failToConnect(manager)
        XCTAssertFalse(manager.allowsNewPanes())

        box.endpoint = try fakeCore([try helloLine(), try subscribeLine()])
        XCTAssertFalse(manager.allowsNewPanes(), "this pane still goes local")
        let deadline = Date().addingTimeInterval(5)
        while manager.availability != .connected(version: "fake") {
            guard Date() < deadline else { return XCTFail("the probe did not connect: \(manager.availability)") }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(manager.allowsNewPanes())
    }
}

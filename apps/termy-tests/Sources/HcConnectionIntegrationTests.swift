import XCTest
@testable import termy

// 실제 herdr-core(scratch core, HcTestCore)에 붙는 HcConnection 테스트. hc가 없으면 skip.

final class HcConnectionIntegrationTests: XCTestCase {
    private struct RunParams: Encodable, Sendable { let argv: [String] }
    private struct RunResult: Decodable, Sendable { let address: String }
    private struct AttachParams: Encodable, Sendable { let terminal: String; let cols: Int; let rows: Int }
    private struct AttachResult: Decodable, Sendable { let channel: UInt32 }

    private func openConnection() async throws -> HcConnection {
        let core = try HcTestCore.makeOrSkip()
        addTeardownBlock { await core.stop() }
        let conn = HcConnection(endpoint: core.endpoint)
        addTeardownBlock { await conn.close() }   // teardown은 역순: 연결을 닫은 뒤 core를 멈춘다
        _ = try await conn.open()
        return conn
    }

    private func runAndAttach(_ conn: HcConnection, _ argv: [String]) async throws -> UInt32 {
        let run: RunResult = try await conn.call("terminal.run", RunParams(argv: argv))
        let attach: AttachResult = try await conn.call("terminal.attach", AttachParams(terminal: run.address, cols: 80, rows: 24))
        return attach.channel
    }

    func testHelloReportsGenerationOne() async throws {
        let core = try HcTestCore.makeOrSkip(); addTeardownBlock { await core.stop() }
        let conn = HcConnection(endpoint: core.endpoint)
        addTeardownBlock { await conn.close() }
        let hello = try await conn.open()
        XCTAssertEqual(hello.generation, 1)
        XCTAssertTrue(HcConnection.requiredMethods.allSatisfy(hello.methods.contains))
    }

    func testAttachEchoesInput() async throws {
        let conn = try await openConnection()
        let ch = try await runAndAttach(conn, ["/bin/cat"])
        let stream = await conn.stream(ch)
        await conn.send(HcFrame(channel: ch, kind: .data, payload: Data("abc\n".utf8)))
        let seen = try await hcWithTimeout(3) {
            var buf = Data()
            for await event in stream {
                switch event {
                case .data(let d):
                    buf.append(d)
                    await conn.send(.credit(channel: ch, bytes: UInt32(d.count)))
                    if buf.range(of: Data("abc".utf8)) != nil { return true }
                case .closed:
                    return false
                }
            }
            return false
        }
        XCTAssertTrue(seen)
    }

    func testCreditFlowDeliversLargeOutput() async throws {
        let conn = try await openConnection()
        // 출력이 attach 전에 끝나면 attach가 `finished`로 실패하므로 한 줄을 받은 뒤 쏟아낸다.
        let ch = try await runAndAttach(conn, ["/bin/sh", "-c", "read line; head -c 8388608 /dev/zero | tr '\\0' a; echo; echo END"])
        let stream = await conn.stream(ch)
        await conn.send(HcFrame(channel: ch, kind: .data, payload: Data("\n".utf8)))
        let started = Date()
        let total = try await hcWithTimeout(20) { () -> Int? in
            var total = 0
            var tail = Data()   // 직전 청크의 마지막 2바이트: 청크 경계에 걸린 "END"도 찾는다
            for await event in stream {
                switch event {
                case .data(let d):
                    total += d.count
                    await conn.send(.credit(channel: ch, bytes: UInt32(d.count)))
                    let window = tail + d
                    if window.range(of: Data("END".utf8)) != nil { return total }
                    tail = Data(window.suffix(2))
                case .closed:
                    return nil
                }
            }
            return nil
        }
        print("[hc] credit flow: \(total.map(String.init) ?? "nil") bytes in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        XCTAssertNotNil(total, "stream ended before END")
    }

    func testCloseCarriesExitCode() async throws {
        let conn = try await openConnection()
        // 그냥 `exit 3`이면 attach 전에 끝나 attach가 `finished` 오류로 돌아올 때가 있다(5번 중 1번).
        // 한 줄을 기다리게 해서 attach한 뒤에 끝나게 한다.
        let ch = try await runAndAttach(conn, ["/bin/sh", "-c", "read line; exit 3"])
        let stream = await conn.stream(ch)
        await conn.send(HcFrame(channel: ch, kind: .data, payload: Data("\n".utf8)))
        let payload = try await hcWithTimeout(5) { () -> Data? in
            for await event in stream {
                switch event {
                case .data(let d): await conn.send(.credit(channel: ch, bytes: UInt32(d.count)))
                case .closed(let p): return p
                }
            }
            return nil
        }
        let obj = try JSONSerialization.jsonObject(with: XCTUnwrap(payload)) as? [String: Any]
        XCTAssertEqual(obj?["reason"] as? String, "exited")
        XCTAssertEqual(obj?["exit_code"] as? Int, 3)
    }
}

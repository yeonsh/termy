import XCTest
@testable import termy

final class HcRPCTests: XCTestCase {
    func testParseResponseErrorAndNotification() throws {
        if case .response(let id, _) = try HcRPC.parse(Data(#"{"jsonrpc":"2.0","id":4,"result":{"ok":true}}"#.utf8)) { XCTAssertEqual(id, 4) } else { XCTFail() }
        if case .error(_, let e) = try HcRPC.parse(Data(#"{"jsonrpc":"2.0","id":5,"error":{"code":-32000,"message":"no terminal t9","data":{"kind":"not_found","hint":"h"}}}"#.utf8)) { XCTAssertEqual(e.kind, "not_found"); XCTAssertEqual(e.hint, "h") } else { XCTFail() }
        if case .notification(let m, _) = try HcRPC.parse(Data(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":42}}"#.utf8)) { XCTAssertEqual(m, "heartbeat") } else { XCTFail() }
    }

    func testParseToleratesTrailingNewline() throws {
        if case .response(let id, _) = try HcRPC.parse(Data("{\"id\":1,\"result\":{}}\n".utf8)) { XCTAssertEqual(id, 1) } else { XCTFail() }
    }

    func testRequestAndDecodeHelpers() throws {
        struct P: Codable, Equatable { let a: Int }
        let req = try HcRPC.request(id: 3, method: "m", params: P(a: 9))
        XCTAssertNotEqual(req.last, 0x0A)
        let obj = try JSONSerialization.jsonObject(with: req) as? [String: Any]
        XCTAssertEqual(obj?["method"] as? String, "m")
        XCTAssertEqual(obj?["id"] as? Int, 3)
        XCTAssertEqual(obj?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(try HcRPC.decodeParams(P.self, from: req), P(a: 9))
        let resp = Data(#"{"id":3,"result":{"a":5}}"#.utf8)
        XCTAssertEqual(try HcRPC.decodeResult(P.self, from: resp), P(a: 5))
    }
}

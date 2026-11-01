import XCTest
@testable import termy

final class HcFrameTests: XCTestCase {
    func testResizeFrameBytes() {
        let f = HcFrame.resize(channel: 7, cols: 120, rows: 40).encoded()
        XCTAssertEqual([UInt8](f), [7,0,0,0, 3, 4,0,0,0, 120,0, 40,0])
    }

    func testDecoderHandlesSplitAndBatchedFrames() throws {
        let a = HcFrame(channel: 0, kind: .data, payload: Data("{\"id\":1}".utf8)).encoded()
        let b = HcFrame.credit(channel: 3, bytes: 4096).encoded()
        var d = HcFrameDecoder()
        var all = a + b
        let first = try d.append(all.prefix(5))
        XCTAssertEqual(first, [])
        all.removeFirst(5)
        XCTAssertEqual(try d.append(all).map(\.kind), [.data, .credit])
    }

    func testDecoderRejectsOversizedPayload() {
        var header = Data([0,0,0,0, 0]); var len = UInt32(16_777_217).littleEndian
        header.append(Data(bytes: &len, count: 4))
        var d = HcFrameDecoder()
        XCTAssertThrowsError(try d.append(header)) { XCTAssertEqual($0 as? HcFrameError, .payloadTooLarge(16_777_217)) }
    }

    func testDecoderRejectsUnknownKind() {
        var d = HcFrameDecoder()
        XCTAssertThrowsError(try d.append(Data([0,0,0,0, 9, 0,0,0,0]))) {
            XCTAssertEqual($0 as? HcFrameError, .unknownKind(9))
        }
    }
}

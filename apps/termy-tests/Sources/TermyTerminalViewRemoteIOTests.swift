import XCTest
import AppKit
@testable import termy
import SwiftTerm

@MainActor
final class TermyTerminalViewRemoteIOTests: XCTestCase {
    func testSendRoutesToRemoteInputWhenSet() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var sent: [UInt8] = []
        view.remoteInput = { sent.append(contentsOf: $0) }
        view.send(txt: "a")
        XCTAssertEqual(sent, [0x61])
    }

    func testReceiveRemoteFeedsTerminalAndFiresOnOutput() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var outputs = 0
        view.onOutput = { outputs += 1 }
        view.receiveRemote(ArraySlice(Array("hello".utf8)))
        let line = view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
        XCTAssertEqual(line, "hello")
        XCTAssertEqual(outputs, 1)
    }

    func testGridSizeCallbackFiresOnResizeButNotWhileFrozen() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var sizes: [[Int]] = []
        view.onGridSizeChanged = { sizes.append([$0, $1]) }
        view.freezeSizePropagation()
        view.setFrameSize(NSSize(width: 800, height: 600))
        XCTAssertTrue(sizes.isEmpty)
        view.thawSizePropagation()
        let t = view.getTerminal()
        XCTAssertEqual(sizes.last, [t.cols, t.rows])
    }
}

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

    /// hc first paint는 모드를 되돌리며 `?1049l`을 늘 보낸다. SwiftTerm이 그때 자동 줄바꿈(DECAWM)을
    /// 끄면 core(ghostty-vt)와 화면이 갈라져, nvim이 그린 긴 줄이 다음 행으로 넘어가지 않고 행이 밀렸다.
    func testHcFirstPaintKeepsAutowrapForWrappedLines() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let firstPaintPrefix = "\u{18}\u{1b}[!p\u{1b}[?2026l\u{1b}[?1000l\u{1b}[?2004l\u{1b}[?1l\u{1b}[?2048l"
            + "\u{1b}[=0;1u\u{1b}[?1049l\u{1b}[?1047l\u{1b}[?47l\u{1b}[H\u{1b}[2J\u{1b}[0m\u{1b}[?1049h"
        view.receiveRemote(ArraySlice(Array(firstPaintPrefix.utf8)))

        let terminal = view.getTerminal()
        let full = String(repeating: "A", count: terminal.cols)
        // nvim은 마지막 칸을 쓴 뒤 속성만 바꾸고 이어지는 글자가 다음 행으로 넘어가길 기대한다.
        view.receiveRemote(ArraySlice(Array("\u{1b}[H\(full)\u{1b}(B\u{1b}[mXY".utf8)))

        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), full)
        XCTAssertEqual(terminal.getLine(row: 1)?.translateToString(trimRight: true), "XY")
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
        XCTAssertEqual(sizes, [[t.cols, t.rows]])
    }

    func testFontChangeReportsGrid() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var sizes: [[Int]] = []
        view.onGridSizeChanged = { sizes.append([$0, $1]) }
        view.setTerminalFont(NSFont.monospacedSystemFont(ofSize: 30, weight: .regular))
        let t = view.getTerminal()
        XCTAssertEqual(sizes, [[t.cols, t.rows]])
    }

    func testUnfrozenFrameChangeFiresOnce() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var sizes: [[Int]] = []
        view.onGridSizeChanged = { sizes.append([$0, $1]) }
        view.setFrameSize(NSSize(width: 800, height: 600))
        let t = view.getTerminal()
        XCTAssertEqual(sizes, [[t.cols, t.rows]])
    }

    func testFrameChangeWithSameGridFiresNothing() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var sizes: [[Int]] = []
        view.onGridSizeChanged = { sizes.append([$0, $1]) }
        view.setFrameSize(NSSize(width: 400, height: 300))
        XCTAssertTrue(sizes.isEmpty)
    }
}

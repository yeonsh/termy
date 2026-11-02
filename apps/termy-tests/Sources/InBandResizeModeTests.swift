import XCTest
import AppKit
@testable import termy

/// hc pane에서 mode 2048(in-band resize notifications)을 켠 프로그램에 크기 알림을 보내는지.
/// core가 이 모드를 지원한다고 답하므로 nvim은 SIGWINCH 대신 이 알림만 기다린다.
final class InBandResizeModeTests: XCTestCase {
    private func scan(_ chunks: [String]) -> Bool? {
        var scanner = InBandResizeModeScanner()
        var last: Bool?
        for chunk in chunks {
            if let state = scanner.scan(ArraySlice(Array(chunk.utf8))) { last = state }
        }
        return last
    }

    func test_scanner_readsSetAndReset() {
        XCTAssertEqual(scan(["\u{1b}[?2048h"]), true)
        XCTAssertEqual(scan(["\u{1b}[?2048l"]), false)
        XCTAssertEqual(scan(["\u{1b}[?2048h", "text", "\u{1b}[?2048l"]), false)
    }

    func test_scanner_readsModeInsideAList() {
        XCTAssertEqual(scan(["\u{1b}[?1049;2048;2004h"]), true)
    }

    func test_scanner_readsSequenceSplitAcrossChunks() {
        XCTAssertEqual(scan(["abc\u{1b}", "[?20", "48h"]), true)
    }

    func test_scanner_ignoresOtherModesAndQueries() {
        XCTAssertNil(scan(["\u{1b}[?2004h"]))
        XCTAssertNil(scan(["\u{1b}[?20480h"]))
        XCTAssertNil(scan(["\u{1b}[?2048$p"]), "DECRQM asks, it does not set")
        XCTAssertNil(scan(["\u{1b}[2048h"]), "not a private mode")
    }

    func test_report_format() {
        XCTAssertEqual(
            String(decoding: InBandResizeModeScanner.report(cols: 110, rows: 35, widthPixels: 880, heightPixels: 560), as: UTF8.self),
            "\u{1b}[48;35;110;560;880t"
        )
    }

    @MainActor
    func test_hcView_reportsGridOnlyWhileTheProgramAsks() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var sent = ""
        view.remoteInput = { sent += String(decoding: $0, as: UTF8.self) }
        func grid() -> String { "\(view.getTerminal().rows);\(view.getTerminal().cols);" }

        view.setFrameSize(NSSize(width: 800, height: 500))
        XCTAssertEqual(sent, "", "mode off: nothing is reported")

        view.receiveRemote(ArraySlice(Array("\u{1b}[?2048h".utf8)))
        XCTAssertTrue(sent.hasPrefix("\u{1b}[48;" + grid()), "a report as soon as the mode is on: \(sent.debugDescription)")

        sent = ""
        view.setFrameSize(NSSize(width: 900, height: 560))
        XCTAssertTrue(sent.hasPrefix("\u{1b}[48;" + grid()), "a report with the new grid: \(sent.debugDescription)")

        sent = ""
        view.setTerminalFont(NSFont.monospacedSystemFont(ofSize: 20, weight: .regular))
        XCTAssertTrue(sent.hasPrefix("\u{1b}[48;" + grid()), "a font change reports too: \(sent.debugDescription)")

        sent = ""
        view.receiveRemote(ArraySlice(Array("\u{1b}[?2048l".utf8)))
        view.setFrameSize(NSSize(width: 640, height: 400))
        XCTAssertEqual(sent, "", "mode off again: nothing is reported")
    }
}

// InterruptKeyTests.swift
//
// Pins down which PTY input chunks count as a standalone Esc / Ctrl-C press.

import XCTest
@testable import termy

final class InterruptKeyTests: XCTestCase {

    private func b(_ s: String) -> ArraySlice<UInt8> { ArraySlice(Array(s.utf8)) }

    func testAcceptsLegacyAndKittyPress() {
        XCTAssertTrue(InterruptKey.isStandaloneInterrupt([0x1b]))
        XCTAssertTrue(InterruptKey.isStandaloneInterrupt([0x03]))
        XCTAssertTrue(InterruptKey.isStandaloneInterrupt(b("\u{1b}[27u")))
        XCTAssertTrue(InterruptKey.isStandaloneInterrupt(b("\u{1b}[27;1u")))
        XCTAssertTrue(InterruptKey.isStandaloneInterrupt(b("\u{1b}[27;1:1u")))
        XCTAssertTrue(InterruptKey.isStandaloneInterrupt(b("\u{1b}[99;5u")))
        XCTAssertTrue(InterruptKey.isStandaloneInterrupt(b("\u{1b}[99;69u")))   // ctrl + caps lock
    }

    func testRejectsEverythingElse() {
        for s in ["\u{1b}[A", "\u{1b}b", "\u{1b}[200~", "\u{1b}[<0;10;5M", "\u{1b}[27;2u", "\u{1b}[27;1:3u",
                  "\u{1b}[27;1:2u", "\u{1b}[99;7u", "\u{1b}[99u", "\u{1b}\u{1b}", "c", "\u{03}\u{03}", ""] {
            XCTAssertFalse(InterruptKey.isStandaloneInterrupt(b(s)), s.debugDescription)
        }
    }
}

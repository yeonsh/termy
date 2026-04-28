import XCTest
import AppKit
import Carbon.HIToolbox
@testable import termy
import SwiftTerm

final class TermyTerminalViewTests: XCTestCase {
    /// Korean IME commit: composed Hangul syllable must bypass SwiftTerm's
    /// kitty encoder, which would otherwise emit the triggering key's jamo
    /// (ㄱ, ㅇ, ...) instead of the composed syllable.
    func test_shouldBypassKittyEncoder_forHangulCommit() {
        XCTAssertTrue(
            TermyTerminalView.shouldBypassKittyEncoder(
                text: "한",
                kittyFlags: [.disambiguate, .reportEvents, .reportAlternates]
            )
        )
    }

    /// Codex's exact flag set (disambiguate + event-types + alternates, no
    /// report-all-keys) is the one that triggered the real-world bug.
    func test_shouldBypassKittyEncoder_forCrosstermFlagSet() {
        XCTAssertTrue(
            TermyTerminalView.shouldBypassKittyEncoder(
                text: "글",
                kittyFlags: [.disambiguate, .reportEvents, .reportAlternates]
            )
        )
    }

    func test_shouldBypassKittyEncoder_forMultiScalarCommit() {
        XCTAssertTrue(
            TermyTerminalView.shouldBypassKittyEncoder(
                text: "한글",
                kittyFlags: [.reportAllKeys]
            )
        )
    }

    /// Dead-key composition produces non-ASCII text (á, ñ, ...) that doesn't
    /// match the physical key — same corrupting path as IME commits.
    func test_shouldBypassKittyEncoder_forDeadKeyComposedText() {
        XCTAssertTrue(
            TermyTerminalView.shouldBypassKittyEncoder(
                text: "é",
                kittyFlags: [.disambiguate]
            )
        )
    }

    /// Pure ASCII goes through SwiftTerm's normal path — its encoder emits
    /// plain UTF-8 correctly for ASCII without an alternates+baseLayoutKey
    /// mismatch.
    func test_shouldBypassKittyEncoder_skipsAsciiCommit() {
        XCTAssertFalse(
            TermyTerminalView.shouldBypassKittyEncoder(
                text: "a",
                kittyFlags: [.disambiguate, .reportEvents, .reportAlternates]
            )
        )
    }

    func test_shouldBypassKittyEncoder_skipsWhenNoKittyFlags() {
        XCTAssertFalse(
            TermyTerminalView.shouldBypassKittyEncoder(
                text: "한",
                kittyFlags: []
            )
        )
    }

    func test_shouldBypassKittyEncoder_skipsEmptyText() {
        XCTAssertFalse(
            TermyTerminalView.shouldBypassKittyEncoder(
                text: "",
                kittyFlags: [.reportAllKeys]
            )
        )
    }

    /// Control characters (enter/tab/backspace/etc.) must go through
    /// SwiftTerm's encoder so its functional-key logic can run.
    func test_shouldBypassKittyEncoder_skipsControlCharacters() {
        XCTAssertFalse(
            TermyTerminalView.shouldBypassKittyEncoder(
                text: "\n",
                kittyFlags: [.reportAllKeys]
            )
        )
    }

    // MARK: - Ctrl retargeting under non-ASCII input sources

    /// Hangul 2-beolsik remaps physical 'c' → 'ㅊ'; SwiftTerm's Ctrl handler
    /// then sees a 3-byte UTF-8 string it can't map to a control byte, so
    /// Ctrl+C disappears. Retargeting must kick in.
    func test_needsASCIIRetargeting_forHangulJamo() {
        XCTAssertTrue(
            TermyTerminalView.needsASCIIRetargeting(charactersIgnoringModifiers: "ㅊ")
        )
    }

    func test_needsASCIIRetargeting_forHiragana() {
        XCTAssertTrue(
            TermyTerminalView.needsASCIIRetargeting(charactersIgnoringModifiers: "そ")
        )
    }

    /// US QWERTY with Ctrl+C: charactersIgnoringModifiers == "c" — SwiftTerm's
    /// existing path handles it correctly, don't intervene.
    func test_needsASCIIRetargeting_skipsASCIIChar() {
        XCTAssertFalse(
            TermyTerminalView.needsASCIIRetargeting(charactersIgnoringModifiers: "c")
        )
    }

    /// Punctuation that survives the Korean layout unchanged (',', '.', digits)
    /// stays ASCII; SwiftTerm handles them directly.
    func test_needsASCIIRetargeting_skipsASCIIPunctuation() {
        XCTAssertFalse(
            TermyTerminalView.needsASCIIRetargeting(charactersIgnoringModifiers: ",")
        )
    }

    /// Empty or nil characters (e.g. mid-composition dead-key states) — try
    /// the retargeting path; asciiCharacter(for:) bails out if it can't
    /// resolve a single ASCII scalar.
    func test_needsASCIIRetargeting_forNilCharacters() {
        XCTAssertTrue(
            TermyTerminalView.needsASCIIRetargeting(charactersIgnoringModifiers: nil)
        )
    }

    func test_needsASCIIRetargeting_forEmptyCharacters() {
        XCTAssertTrue(
            TermyTerminalView.needsASCIIRetargeting(charactersIgnoringModifiers: "")
        )
    }

    // MARK: - Shift+Return interception

    private func keyEvent(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        // characters/charactersIgnoringModifiers don't matter for the predicate
        // — it switches on keyCode + modifierFlags only.
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: UInt16(keyCode))!
    }

    func test_isShiftReturn_recognizesShiftReturn() {
        XCTAssertTrue(
            TermyTerminalView.isShiftReturn(
                keyEvent(keyCode: kVK_Return, modifiers: .shift)
            )
        )
    }

    func test_isShiftReturn_recognizesShiftKeypadEnter() {
        XCTAssertTrue(
            TermyTerminalView.isShiftReturn(
                keyEvent(keyCode: kVK_ANSI_KeypadEnter, modifiers: [.shift, .numericPad])
            )
        )
    }

    /// Plain Enter must fall through so SwiftTerm's encoder sends the legacy
    /// CR — submitting a prompt should still work.
    func test_isShiftReturn_skipsPlainReturn() {
        XCTAssertFalse(
            TermyTerminalView.isShiftReturn(
                keyEvent(keyCode: kVK_Return, modifiers: [])
            )
        )
    }

    /// Caps lock is a meaningless modifier for Return — must not block the
    /// Shift-only match.
    func test_isShiftReturn_ignoresCapsLockBit() {
        XCTAssertTrue(
            TermyTerminalView.isShiftReturn(
                keyEvent(keyCode: kVK_Return, modifiers: [.shift, .capsLock])
            )
        )
    }

    /// Cmd+Shift+Return / Ctrl+Shift+Return / Opt+Shift+Return are reserved
    /// for app-level shortcuts (window splits, etc.) and TUI hotkeys — must
    /// not be eaten by the Shift+Return path.
    func test_isShiftReturn_skipsWhenOtherModifiersPresent() {
        let combos: [NSEvent.ModifierFlags] = [
            [.shift, .command],
            [.shift, .control],
            [.shift, .option],
            [.command],
            [.control],
        ]
        for mods in combos {
            XCTAssertFalse(
                TermyTerminalView.isShiftReturn(
                    keyEvent(keyCode: kVK_Return, modifiers: mods)
                ),
                "should skip \(mods.rawValue)"
            )
        }
    }

    /// Shift+letter must not match — only Return/KeypadEnter physical keys.
    func test_isShiftReturn_skipsNonReturnKey() {
        XCTAssertFalse(
            TermyTerminalView.isShiftReturn(
                keyEvent(keyCode: kVK_ANSI_A, modifiers: .shift)
            )
        )
    }
}

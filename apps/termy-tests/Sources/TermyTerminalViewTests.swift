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

    // MARK: - Option+Left/Right word motion

    func test_optionArrowWordMotion_mapsOptionLeftToMetaB() {
        XCTAssertEqual(
            TermyTerminalView.optionArrowWordMotion(
                keyEvent(keyCode: kVK_LeftArrow, modifiers: .option)
            ),
            "\u{1B}b"
        )
    }

    func test_optionArrowWordMotion_mapsOptionRightToMetaF() {
        XCTAssertEqual(
            TermyTerminalView.optionArrowWordMotion(
                keyEvent(keyCode: kVK_RightArrow, modifiers: .option)
            ),
            "\u{1B}f"
        )
    }

    /// AppKit tags every arrow keyDown with `.numericPad` and `.function`;
    /// those bits must not block the match.
    func test_optionArrowWordMotion_ignoresArrowKeyDeviceBits() {
        XCTAssertEqual(
            TermyTerminalView.optionArrowWordMotion(
                keyEvent(keyCode: kVK_LeftArrow, modifiers: [.option, .numericPad, .function])
            ),
            "\u{1B}b"
        )
    }

    /// Plain and Shift/Cmd/Ctrl-combined arrows keep SwiftTerm's xterm
    /// encoding (`CSI D`, `CSI 1;4D`, …); only bare Option is remapped.
    func test_optionArrowWordMotion_skipsOtherModifierCombos() {
        let combos: [NSEvent.ModifierFlags] = [
            [],
            [.shift],
            [.option, .shift],
            [.option, .command],
            [.option, .control],
        ]
        for mods in combos {
            XCTAssertNil(
                TermyTerminalView.optionArrowWordMotion(
                    keyEvent(keyCode: kVK_LeftArrow, modifiers: mods)
                ),
                "should skip \(mods.rawValue)"
            )
        }
    }

    func test_optionArrowWordMotion_skipsVerticalArrows() {
        XCTAssertNil(
            TermyTerminalView.optionArrowWordMotion(
                keyEvent(keyCode: kVK_UpArrow, modifiers: .option)
            )
        )
    }

    // MARK: - CMD+click URL gating
    //
    // SwiftTerm's `.implicit` link detection matches rooted/relative paths
    // (`./src/main.swift`, `/usr/local/bin`, …) in addition to schemed URLs.
    // `URL(string:)` parses those as scheme-less relative URLs, and
    // `NSWorkspace.shared.open` of a scheme-less URL surfaces the
    // LaunchServices "해당 프로그램을 실행할 수 없습니다" alert. Reproducer:
    // any incidental CMD+leftMouseUp over path-shaped text — including the
    // stray trackpad tap that can fire while CMD is held for ⌘+TAB. Gate the
    // opener on a routable scheme so the alert can't trigger.

    func test_openableURL_acceptsHTTPSScheme() {
        XCTAssertNotNil(TermyTerminalView.openableURL(from: "https://example.com"))
    }

    func test_openableURL_acceptsHTTPScheme() {
        XCTAssertNotNil(TermyTerminalView.openableURL(from: "http://example.com/path?q=1"))
    }

    func test_openableURL_acceptsMailtoScheme() {
        XCTAssertNotNil(TermyTerminalView.openableURL(from: "mailto:user@example.com"))
    }

    func test_openableURL_acceptsFileScheme() {
        XCTAssertNotNil(TermyTerminalView.openableURL(from: "file:///Users/ysh/notes.md"))
    }

    func test_openableURL_rejectsRelativePath() {
        XCTAssertNil(TermyTerminalView.openableURL(from: "./src/main.swift"))
    }

    func test_openableURL_rejectsAbsolutePath() {
        XCTAssertNil(TermyTerminalView.openableURL(from: "/usr/local/bin"))
    }

    func test_openableURL_rejectsParentRelativePath() {
        XCTAssertNil(TermyTerminalView.openableURL(from: "../foo/bar"))
    }

    func test_openableURL_rejectsBareFilename() {
        XCTAssertNil(TermyTerminalView.openableURL(from: "main.swift"))
    }

    func test_openableURL_rejectsHomeRelativePath() {
        XCTAssertNil(TermyTerminalView.openableURL(from: "~/Documents/foo"))
    }

    func test_openableURL_rejectsEmpty() {
        XCTAssertNil(TermyTerminalView.openableURL(from: ""))
    }

    // MARK: - Clicks under a mouse-capturing child

    /// Claude Code fullscreen scrolls by redrawing, so only its own selection
    /// survives the wheel. A plain drag has to reach it.
    @MainActor
    func test_plainClick_underMouseCapture_staysWithTheChild() throws {
        let view = Self.mouseCapturingTerminal()
        let click = try XCTUnwrap(Self.leftMouseDown(modifierFlags: []))

        view.handleClickInBounds(click)

        XCTAssertTrue(view.allowMouseReporting)
    }

    /// termy opens links on Cmd+click and swallows that mouseUp, so the
    /// press must not reach the child either.
    @MainActor
    func test_cmdClick_underMouseCapture_staysWithTermy() throws {
        let view = Self.mouseCapturingTerminal()
        let click = try XCTUnwrap(Self.leftMouseDown(modifierFlags: .command))

        view.handleClickInBounds(click)

        XCTAssertFalse(view.allowMouseReporting)
    }

    /// A Shift+drag selection must still clear on a plain click even though
    /// that click goes to the child.
    @MainActor
    func test_plainClick_underMouseCapture_clearsNativeSelection() throws {
        let view = Self.mouseCapturingTerminal()
        view.selectAll()
        XCTAssertTrue(view.selectionActive)
        let click = try XCTUnwrap(Self.leftMouseDown(modifierFlags: []))

        view.handleClickInBounds(click)

        XCTAssertFalse(view.selectionActive)
    }

    /// The link monitor swallows the Cmd+click mouseUp it opened a link on,
    /// so the restore monitor never sees it. Reporting must come back on
    /// anyway, or the next plain click never reaches the child.
    @MainActor
    func test_cmdClickOpeningMarkdownLink_underMouseCapture_restoresReporting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("docs/x.md")
        try "# x\n".write(to: file, atomically: true, encoding: .utf8)

        let view = Self.mouseCapturingTerminal(showing: "docs/x.md")
        var opened: [URL] = []
        view.previewBaseDirectories = { [dir.path] }
        view.onOpenPreviewFile = { opened.append($0) }

        view.handleClickInBounds(try XCTUnwrap(Self.leftMouseDown(modifierFlags: .command)))
        XCTAssertFalse(view.allowMouseReporting)
        // Top-left cell, where the path starts.
        let mouseUp = try XCTUnwrap(Self.mouseEvent(
            .leftMouseUp,
            at: NSPoint(x: 2, y: view.frame.height - 2),
            modifierFlags: .command
        ))

        XCTAssertNil(view.handleLinkClickMouseUp(mouseUp), "the link monitor consumes the click")
        XCTAssertEqual(opened, [file.resolvingSymlinksInPath()])
        XCTAssertTrue(view.allowMouseReporting)
    }

    @MainActor
    private static func mouseCapturingTerminal(showing text: String = "hello") -> TermyTerminalView {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        // Alternate screen + any-event tracking + SGR, as Claude Code
        // fullscreen sets them.
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1003h\u{1b}[?1006h" + text)
        XCTAssertEqual(view.terminal.mouseMode, .anyEvent)
        XCTAssertTrue(view.allowMouseReporting)
        return view
    }

    private static func leftMouseDown(modifierFlags: NSEvent.ModifierFlags) -> NSEvent? {
        mouseEvent(.leftMouseDown, at: NSPoint(x: 10, y: 10), modifierFlags: modifierFlags)
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: location,
            modifierFlags: modifierFlags, timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )
    }

    // MARK: - Cmd+click link actions

    private func clickAction(_ text: String, existing: Set<String> = []) -> LinkClickAction {
        TermyTerminalView.linkClickAction(
            for: text,
            baseDirectories: ["/proj"],
            homeDirectory: "/Users/me",
            isRegularFile: { existing.contains($0) }
        )
    }

    func test_linkClickAction_existingMarkdownOpensPreview() {
        XCTAssertEqual(
            clickAction("docs/a.md", existing: ["/proj/docs/a.md"]),
            .preview(URL(fileURLWithPath: "/proj/docs/a.md").resolvingSymlinksInPath())
        )
        XCTAssertEqual(
            clickAction("file:///proj/docs/a.md", existing: ["/proj/docs/a.md"]),
            .preview(URL(fileURLWithPath: "/proj/docs/a.md").resolvingSymlinksInPath())
        )
    }

    func test_linkClickAction_missingMarkdownBeeps() {
        XCTAssertEqual(clickAction("docs/none.md"), .beep)
    }

    func test_linkClickAction_existingPdfOpensPreview() {
        XCTAssertEqual(
            clickAction("out/r.pdf", existing: ["/proj/out/r.pdf"]),
            .preview(URL(fileURLWithPath: "/proj/out/r.pdf").resolvingSymlinksInPath())
        )
    }

    func test_linkClickAction_missingPdfBeeps() {
        XCTAssertEqual(clickAction("out/none.pdf"), .beep)
    }

    func test_linkClickAction_webURLEndingInPdfOpensBrowser() {
        let link = "https://arxiv.org/pdf/2401.00001.pdf"
        XCTAssertEqual(clickAction(link), .openURL(URL(string: link)!))
    }

    func test_linkClickAction_webURLOpensBrowser() {
        XCTAssertEqual(clickAction("https://example.com"), .openURL(URL(string: "https://example.com")!))
    }

    func test_linkClickAction_webURLEndingInMdOpensBrowser() {
        let link = "https://github.com/o/r/blob/main/README.md"
        XCTAssertEqual(clickAction(link), .openURL(URL(string: link)!))
    }

    func test_linkClickAction_otherPathsAreIgnored() {
        XCTAssertEqual(clickAction("src/main.swift", existing: ["/proj/src/main.swift"]), .ignore)
        XCTAssertEqual(clickAction("   "), .ignore)
    }

    /// Review Focus 1: Ink hard-wraps long lines by moving the cursor, so
    /// the second row is not a soft-wrapped continuation. SwiftTerm's
    /// `heuristicImplicitGroup` is what joins them; pin that it does.
    @MainActor
    func test_linkLookup_joinsInkStyleHardWrappedPath() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let terminal = view.getTerminal()
        terminal.resize(cols: 40, rows: 10)
        // Row 0 fills all 40 columns; Ink then does CR, cursor-down, and
        // indents the continuation by two columns.
        view.feed(text: "  docs/superpowers/specs/2026-10-12-mark\r\u{1b}[1B\u{1b}[2Cdown-preview-design.md")

        let path = "docs/superpowers/specs/2026-10-12-markdown-preview-design.md"
        XCTAssertEqual(terminal.link(at: .screen(Position(col: 10, row: 0)), mode: .explicitAndImplicit), path)
        XCTAssertEqual(terminal.link(at: .screen(Position(col: 5, row: 1)), mode: .explicitAndImplicit), path)
    }

    /// The Korean summary line an agent prints after writing a spec: SwiftTerm
    /// hands over the path with the particle and the rest of the sentence
    /// still attached, and the click must still open the preview.
    @MainActor
    func test_cmdClickOnPathInKoreanSentence_opensPreview() throws {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        let terminal = view.getTerminal()
        terminal.resize(cols: 100, rows: 10)
        view.feed(text: "스펙을 docs/superpowers/specs/x-design.md에 저장했습니다.")

        // "스펙을 " takes 7 columns, so column 12 is inside the path.
        let link = try XCTUnwrap(terminal.link(at: .screen(Position(col: 12, row: 0)), mode: .explicitAndImplicit))
        XCTAssertTrue(link.hasPrefix("docs/superpowers/specs/x-design.md"), link)
        let expected = "/proj/docs/superpowers/specs/x-design.md"
        XCTAssertEqual(
            TermyTerminalView.linkClickAction(
                for: link,
                baseDirectories: ["/proj"],
                homeDirectory: "/Users/me",
                isRegularFile: { $0 == expected }
            ),
            .preview(URL(fileURLWithPath: expected).resolvingSymlinksInPath()),
            "link text: \(link)"
        )
    }

    @MainActor
    func test_cmdClickOnPdfPathInKoreanSentence_opensPreview() throws {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        let terminal = view.getTerminal()
        terminal.resize(cols: 100, rows: 10)
        view.feed(text: "보고서를 out/report.pdf에 저장했습니다.")

        // "보고서를 " takes 9 columns, so column 14 is inside the path.
        let link = try XCTUnwrap(terminal.link(at: .screen(Position(col: 14, row: 0)), mode: .explicitAndImplicit))
        XCTAssertTrue(link.hasPrefix("out/report.pdf"), link)
        let expected = "/proj/out/report.pdf"
        XCTAssertEqual(
            TermyTerminalView.linkClickAction(
                for: link,
                baseDirectories: ["/proj"],
                homeDirectory: "/Users/me",
                isRegularFile: { $0 == expected }
            ),
            .preview(URL(fileURLWithPath: expected).resolvingSymlinksInPath()),
            "link text: \(link)"
        )
    }

    // MARK: - Paths SwiftTerm cuts at "("

    private let parenReport = "/r/NetDrive 시장 탈환 전략 (보강판) 2026-10-20.pdf"
    private let notesReport = "/r/NetDrive 시장 탈환 전략 보강판 개정 노트 2026-10-20.pdf"

    @MainActor
    private func screenClickAction(_ view: TermyTerminalView, row: Int, col: Int) -> LinkClickAction? {
        let files: Set<String> = [parenReport, notesReport]
        return view.linkClickAction(
            atScreen: Position(col: col, row: row),
            baseDirectories: ["/proj"],
            homeDirectory: "/Users/me",
            isRegularFile: { files.contains($0) },
            listDirectory: { $0 == "/r" ? files.map { ($0 as NSString).lastPathComponent } : [] }
        )
    }

    private func preview(_ path: String) -> LinkClickAction {
        .preview(URL(fileURLWithPath: path).resolvingSymlinksInPath())
    }

    /// SwiftTerm's link ends at "전략"; the click still opens the file the
    /// line names, not the sibling that shares the cut-off prefix.
    @MainActor
    func test_cmdClickOnPathWithParentheses_opensTheFileTheLineNames() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 1600, height: 200))
        view.getTerminal().resize(cols: 200, rows: 10)
        view.feed(text: "\(parenReport)\r\n\(notesReport)")

        XCTAssertEqual(screenClickAction(view, row: 0, col: 10), preview(parenReport))
        XCTAssertEqual(screenClickAction(view, row: 1, col: 10), preview(notesReport))
        XCTAssertNil(screenClickAction(view, row: 5, col: 10), "no link there")
    }

    @MainActor
    func test_cmdClickOnSoftWrappedPathWithParentheses_opensTheFile() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.getTerminal().resize(cols: 30, rows: 10)
        view.feed(text: parenReport)

        XCTAssertEqual(screenClickAction(view, row: 0, col: 5), preview(parenReport))
    }

    /// Ink breaks the line at the space before "2026", drops that space, and
    /// indents the continuation.
    @MainActor
    func test_cmdClickOnInkWrappedPathWithParentheses_opensTheFile() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.getTerminal().resize(cols: 40, rows: 10)
        view.feed(text: "  /r/NetDrive 시장 탈환 전략 (보강판)\r\u{1b}[1B\u{1b}[2C2026-10-20.pdf")

        XCTAssertEqual(screenClickAction(view, row: 0, col: 5), preview(parenReport))
    }

    // MARK: - IME marked-text overlay

    /// Claude Code prompt `> 하하 호호` with the cursor moved back to the
    /// start of the text, then a Hangul syllable composed there. SwiftTerm
    /// 1.20's overlay painted the terminal background from the caret to the
    /// right edge, so `하하 호호` vanished until the syllable committed. Only
    /// the cells under the composed text may be covered.
    @MainActor
    func test_markedTextOverlay_coversOnlyTheComposedText() throws {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.nativeBackgroundColor = .red
        view.feed(text: "> 하하 호호\r\u{1b}[2C")
        // SwiftTerm moves the caret to column 2 on its throttled display pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        view.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        let overlay = try XCTUnwrap(view.subviews.lazy.compactMap { $0 as? NSTextView }.first)
        let layoutManager = try XCTUnwrap(overlay.layoutManager)
        let container = try XCTUnwrap(overlay.textContainer)
        let glyphRange = layoutManager.glyphRange(for: container)
        var lineCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in lineCount += 1 }
        XCTAssertEqual(lineCount, 1, "the composed syllable must stay on the caret's row")

        // SwiftTerm excludes the row's text left of the caret from the
        // overlay's first line, so this is the caret's x: column 2.
        let exclusion = try XCTUnwrap(container.exclusionPaths.first).bounds
        let caretX = overlay.frame.minX + exclusion.width
        let cellWidth = caretX / 2
        let row = overlay.frame.midY

        let glyphs = overlay.convert(layoutManager.boundingRect(forGlyphRange: glyphRange, in: container), to: view)
        XCTAssertGreaterThan(Self.overlayAlpha(overlay, at: NSPoint(x: glyphs.midX, y: row), in: view), 0,
                             "the composed syllable is drawn")
        XCTAssertGreaterThan(Self.overlayAlpha(overlay, at: NSPoint(x: caretX + 2 * cellWidth - 1, y: row), in: view), 0,
                             "the whole 2-cell slot of the 하 under the caret is covered")
        XCTAssertEqual(Self.overlayAlpha(overlay, at: NSPoint(x: caretX + 2.5 * cellWidth, y: row), in: view), 0,
                       "the next 하 stays visible")
        XCTAssertEqual(Self.overlayAlpha(overlay, at: NSPoint(x: view.bounds.maxX - 20, y: row), in: view), 0)
    }

    /// Alpha the overlay shows at `point` (in `view` coordinates); 0 when the
    /// point lies outside the overlay or its layer mask. `cacheDisplay`
    /// ignores layer masks, so the mask is applied here.
    @MainActor
    private static func overlayAlpha(_ overlay: NSView, at point: NSPoint, in view: NSView) -> CGFloat {
        let local = overlay.convert(point, from: view)
        guard overlay.bounds.contains(local),
              overlay.layer?.mask.map({ local.x >= $0.frame.minX && local.x < $0.frame.maxX }) ?? true,
              let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { return 0 }
        overlay.cacheDisplay(in: overlay.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / overlay.bounds.width
        let y = overlay.isFlipped ? local.y : overlay.bounds.height - local.y
        return rep.colorAt(x: Int(local.x * scale), y: Int(y * scale))?.alphaComponent ?? 0
    }
}

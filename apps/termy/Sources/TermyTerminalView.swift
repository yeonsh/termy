// TermyTerminalView.swift
//
// Subclass of SwiftTerm's `LocalProcessTerminalView` that owns CMD+click URL
// activation directly. SwiftTerm's built-in handler underlines a hovered URL
// correctly (.hoverWithModifier), but its `mouseUp → linkForClick →
// requestOpenLink` path wasn't firing in practice here. Rather than fight
// SwiftTerm's internal state machine, we install a process-local NSEvent
// monitor and resolve the URL ourselves via the public
// `Terminal.link(at:mode:)` API, then hand it to NSWorkspace. The event is
// consumed only when we actually open a URL; otherwise it propagates
// normally so selection, mouse-reporting, etc. keep working.

import AppKit
import Carbon.HIToolbox
import CoreText
import SwiftTerm

final class TermyTerminalView: LocalProcessTerminalView {
    /// SwiftTerm's `TerminalOptions.default.scrollback` is 500 lines, which
    /// truncates a single `codex` reasoning dump. Bumped to match iTerm2 /
    /// Alacritty's default; applied per-instance via `changeScrollback`
    /// because `LocalProcessTerminalView` doesn't expose an options-injection
    /// initializer.
    private static let scrollbackLines = 10_000

    /// Set by Pane after construction — used to attribute PTY-byte pings
    /// to the right snapshot inside HookDaemon. nil before assignment.
    var paneId: String?

    // `nonisolated(unsafe)` so `deinit` (nonisolated) can read it. The monitor
    // is only written once during init on the main thread; removeMonitor is
    // safe to call from any thread.
    nonisolated(unsafe) private var linkClickMonitor: Any?

    // Counter, not bool, so nested freezes balance correctly if Workspace ever
    // grows another batched relayout site.
    private var sizePropagationFreezeDepth = 0
    private var pendingSizeWhileFrozen: NSSize?

    /// Suppress `setFrameSize` propagation (which SwiftTerm couples to
    /// `processSizeChange` → `terminal.resize` → TIOCSWINSZ) for the duration
    /// of a Workspace relayout transaction. Without this, the intermediate
    /// narrow frames AppKit produces while NSSplitView reparents arranged
    /// subviews would each fire SIGWINCH at the child PTY, and TUI clients
    /// like Claude Code redraw their splash at the smallest size they see.
    /// Pair every call with `thawSizePropagation()`.
    func freezeSizePropagation() {
        sizePropagationFreezeDepth += 1
    }

    func thawSizePropagation() {
        guard sizePropagationFreezeDepth > 0 else { return }
        sizePropagationFreezeDepth -= 1
        guard sizePropagationFreezeDepth == 0 else { return }
        if let pending = pendingSizeWhileFrozen {
            pendingSizeWhileFrozen = nil
            super.setFrameSize(pending)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if sizePropagationFreezeDepth > 0 {
            // Capture the latest desired size; apply it (and let SwiftTerm push
            // it to the PTY) once the transaction thaws. Skipping super here
            // also skips processSizeChange — that's the whole point.
            pendingSizeWhileFrozen = newSize
            return
        }
        super.setFrameSize(newSize)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        terminal.changeScrollback(Self.scrollbackLines)
        installLinkClickMonitor()
        installSelectionClearMonitor()
        installControlKeyRetargetMonitor()
        installShiftReturnMonitor()
        registerForDraggedTypes([.fileURL])
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminal.changeScrollback(Self.scrollbackLines)
        installLinkClickMonitor()
        installSelectionClearMonitor()
        installControlKeyRetargetMonitor()
        installShiftReturnMonitor()
        registerForDraggedTypes([.fileURL])
    }

    deinit {
        if let linkClickMonitor {
            NSEvent.removeMonitor(linkClickMonitor)
        }
        if let selectionClearMonitor {
            NSEvent.removeMonitor(selectionClearMonitor)
        }
        if let selectionReportingRestoreMonitor {
            NSEvent.removeMonitor(selectionReportingRestoreMonitor)
        }
        if let controlKeyRetargetMonitor {
            NSEvent.removeMonitor(controlKeyRetargetMonitor)
        }
        if let shiftReturnMonitor {
            NSEvent.removeMonitor(shiftReturnMonitor)
        }
    }

    // SwiftTerm's built-in `mouseDown` already implements the textbook
    // double-click-word / triple-click-row selection — but only on the
    // non-mouse-reporting branch. Under a TUI agent that enables mouse mode
    // (claude, codex, tmux, vim, …) the click is forwarded to the child and
    // neither selection nor the single-click clear runs, so the local
    // highlight becomes un-selectable and un-clearable. Rather than
    // reimplement word/row heuristics (SwiftTerm's `selection` is internal to
    // the module, so we can't call `selectWordOrExpression` / `select(row:)`
    // directly), we flip `allowMouseReporting` off for the duration of the
    // click — SwiftTerm's `mouseDown` then falls through to the selection
    // path unconditionally — and restore it on the matching mouseUp so real
    // reporting resumes for the next click. Subclassing `mouseDown` isn't an
    // option: SwiftTerm marks it `public` but not `open`, which is why we
    // lean on NSEvent monitors here (same constraint as the link-click and
    // ctrl-key monitors).
    nonisolated(unsafe) private var selectionClearMonitor: Any?
    nonisolated(unsafe) private var selectionReportingRestoreMonitor: Any?
    nonisolated(unsafe) private var reportingWasOverriddenForClick: Bool = false

    /// Fired on every left-mouse-down inside this view's bounds (any click
    /// count). Pane wires this to its own `onPaneClicked` callback so
    /// Workspace can focus the clicked pane — replacing the old
    /// `NSClickGestureRecognizer` that was eating the event before SwiftTerm
    /// could run its multi-click selection code.
    var onClickInBounds: (() -> Void)?

    /// Pane writes the focus-state caret color here instead of mutating
    /// `caretColor` directly. We mirror it onto `caretColor` except while
    /// an IME composition is in flight, where the cursor block would
    /// otherwise show through behind SwiftTerm's marked-text NSTextField
    /// overlay as a faint gray box (the overlay's background is clear; the
    /// caret behind it isn't). During composition we force `caretColor` to
    /// `.clear`; when composition ends we restore the pinned value.
    ///
    /// Stored separately from `caretColor` so we know what to restore — the
    /// terminal still needs `caretView.frame.origin` to position the
    /// overlay, so we can't simply hide the caret view (which is internal
    /// to SwiftTerm anyway).
    var pinnedCaretColor: NSColor? {
        didSet {
            applyEffectiveCaretColor()
        }
    }

    private var imeCompositionActive = false {
        didSet {
            if imeCompositionActive != oldValue {
                applyEffectiveCaretColor()
            }
        }
    }

    private func applyEffectiveCaretColor() {
        if imeCompositionActive {
            caretColor = .clear
        } else if let pinned = pinnedCaretColor {
            caretColor = pinned
        }
    }

    private func installSelectionClearMonitor() {
        selectionClearMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window else { return event }
            guard !event.modifierFlags.contains(.shift) else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }
            self.onClickInBounds?()

            // Bypass mouse reporting for the duration of this press-drag-up
            // cycle — SwiftTerm's selection code (click-clear, double-click
            // word, triple-click row, drag-extend) all sit behind an
            // `if allowMouseReporting { forward to child; return }` guard, so
            // under a TUI with mouseMode ≠ .off the user can't select or clear
            // anything. Toggling off proactively makes selection behave like a
            // native macOS text view regardless of what the child declared.
            // The matching leftMouseUp monitor restores the flag so actual
            // mouse reports resume once the click/drag is over.
            //
            // Tradeoff: pure clicks inside the child's UI (e.g. Claude's
            // internal button hit-testing) no longer reach the child. For
            // termy's target workflow (LLM CLIs, which are keyboard-driven)
            // this is a non-issue; we can add a ⌥-modifier passthrough later
            // if a TUI that genuinely needs mouse input becomes important.
            if self.allowMouseReporting {
                self.allowMouseReporting = false
                self.reportingWasOverriddenForClick = true
            }
            // Single-click clear stays defensive: SwiftTerm's own case-1 path
            // handles this when reporting is off, but if the child ever
            // re-enables reporting mid-click we still want click-to-dismiss.
            if event.clickCount == 1, self.selectionActive {
                self.selectNone()
            }
            return event
        }

        selectionReportingRestoreMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            if self.reportingWasOverriddenForClick {
                self.reportingWasOverriddenForClick = false
                self.allowMouseReporting = true
            }
            return event
        }
    }

    private func installLinkClickMonitor() {
        // Runs in-process before the event reaches any view. We only consume
        // the event (return nil) when the click was over this terminal AND
        // landed on a URL — otherwise the event keeps flowing so selection
        // and mouse reporting are unaffected.
        linkClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            guard event.modifierFlags.contains(.command) else { return event }
            guard event.window === self.window else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }
            if self.openLinkUnderMouse(windowLocation: event.locationInWindow) {
                return nil
            }
            return event
        }
    }

    private func openLinkUnderMouse(windowLocation: NSPoint) -> Bool {
        guard let pos = cellPosition(at: windowLocation) else { return false }
        guard let raw = terminal.link(at: .screen(pos), mode: .explicitAndImplicit) else {
            return false
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let url = URL(string: trimmed)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                .flatMap { URL(string: $0) }
        guard let url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Mirrors SwiftTerm's internal `calculateMouseHit` — cell width from the
    /// "W" glyph advance, height from ascent + descent + leading.
    private func cellPosition(at windowLocation: NSPoint) -> Position? {
        let point = convert(windowLocation, from: nil)
        let f = self.font
        let ascent = CTFontGetAscent(f)
        let descent = CTFontGetDescent(f)
        let leading = CTFontGetLeading(f)
        let cellHeight = ceil(ascent + descent + leading)
        let glyph = f.glyph(withName: "W")
        let cellWidth = f.advancement(forGlyph: glyph).width
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let col = Int(point.x / cellWidth)
        // NSView y-up; terminal rows top-down.
        let row = Int((frame.height - point.y) / cellHeight)
        let clampedCol = max(0, min(col, terminal.cols - 1))
        let clampedRow = max(0, min(row, max(0, terminal.rows - 1)))
        return Position(col: clampedCol, row: clampedRow)
    }

    /// When a non-ASCII input source is active (Hangul 2-beolsik remaps 'c' →
    /// 'ㅊ', 'a' → 'ㅁ', ...; Kana, Pinyin, Cyrillic behave the same way),
    /// `event.charactersIgnoringModifiers` hands SwiftTerm the non-ASCII
    /// scalar. Its non-kitty Ctrl branch feeds that through
    /// `applyControlToEventCharacters`, which only switches on
    /// `[UInt8](ch.utf8).count == 1` and returns `[]` for multi-byte input —
    /// so Ctrl+C, Ctrl+D, Ctrl+Z etc. silently disappear while Korean input is
    /// on. The kitty Ctrl branch has the same bug via
    /// `kittyTextEvent(from:)`, which uses the jamo as the CSI-u key code.
    ///
    /// Fix: install a local keyDown monitor that — when Control is held with
    /// a non-ASCII `charactersIgnoringModifiers` — translates the physical
    /// `keyCode` through the current ASCII-capable keyboard layout and
    /// returns a synthetic NSEvent carrying the ASCII character. SwiftTerm's
    /// `keyDown` then sees `'c'` instead of `'ㅊ'` and its existing Ctrl path
    /// (kitty + non-kitty) runs unchanged. Subclassing `keyDown` isn't
    /// available because SwiftTerm marks it `public` but not `open` — same
    /// constraint that forced the selection-clear monitor above.
    nonisolated(unsafe) private var controlKeyRetargetMonitor: Any?

    private func installControlKeyRetargetMonitor() {
        controlKeyRetargetMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window else { return event }
            guard self.window?.firstResponder === self else { return event }
            guard event.modifierFlags.contains(.control) else { return event }
            guard Self.needsASCIIRetargeting(charactersIgnoringModifiers: event.charactersIgnoringModifiers) else {
                return event
            }
            guard let ascii = Self.asciiCharacter(for: event) else { return event }
            guard let synthetic = NSEvent.keyEvent(
                    with: .keyDown,
                    location: event.locationInWindow,
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: ascii,
                    charactersIgnoringModifiers: ascii,
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode) else {
                return event
            }
            // Interrupt semantics: any in-flight IME composition dies with the
            // control byte. Without this, an orphaned marked-text overlay
            // lingers after the child process has already received Ctrl+C.
            if self.hasMarkedText() {
                self.unmarkText()
            }
            return synthetic
        }
    }

    nonisolated static func needsASCIIRetargeting(charactersIgnoringModifiers: String?) -> Bool {
        guard let characters = charactersIgnoringModifiers,
              let first = characters.unicodeScalars.first else {
            // No characters reported — e.g. dead-key / composing state. Let the
            // retargeting path try; if UCKeyTranslate can't resolve the key we
            // fall through to super.keyDown anyway.
            return true
        }
        // Already ASCII → SwiftTerm's existing Ctrl path handles it correctly.
        return !first.isASCII
    }

    /// Translate the event's physical `keyCode` to its US-layout (or whichever
    /// ASCII-capable layout the user has installed) character. Returns nil if
    /// the key doesn't resolve to a single ASCII scalar — higher layers should
    /// fall back to `super.keyDown` in that case.
    nonisolated static func asciiCharacter(for event: NSEvent) -> String? {
        guard let sourceRef = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        // UCKeyTranslate wants modifier bits in the classic (EventRecord.modifiers >> 8)
        // format. Forward only shift — controlKey here would yield a 0x00–0x1F
        // control byte, defeating the "give me the printable ASCII" translation.
        var modifierState: UInt32 = 0
        if event.modifierFlags.contains(.shift) {
            modifierState |= UInt32(shiftKey >> 8)
        }
        return layoutData.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var actualLength = 0
            let status = UCKeyTranslate(
                layout,
                event.keyCode,
                UInt16(kUCKeyActionDown),
                modifierState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &actualLength,
                &chars)
            guard status == noErr, actualLength == 1 else { return nil }
            let result = String(utf16CodeUnits: chars, count: actualLength)
            guard let scalar = result.unicodeScalars.first, scalar.isASCII else {
                return nil
            }
            return result
        }
    }

    /// Without the kitty keyboard protocol's `disambiguate` flag,
    /// SwiftTerm's encoder emits plain `\r` for both Enter and Shift+Enter
    /// (`KittyKeyboardEncoder.swift:583` legacy path; only Shift+Tab gets
    /// special-cased there). Codex CLI pushes the kitty flags on startup, so
    /// it correctly receives `CSI 13;2u` for Shift+Enter; Claude Code CLI
    /// (Ink/Node) does NOT push kitty flags and instead relies on the host
    /// terminal having a user-level keymap that turns Shift+Enter into a
    /// distinguishable byte sequence — what `claude /terminal-setup` sets up
    /// in iTerm2 / Terminal.app. Termy has no such keymap, so Shift+Enter
    /// inside Claude Code lands as plain Enter and submits the prompt.
    ///
    /// Fix: when kitty `disambiguate` is off, intercept Shift+Return at the
    /// monitor level (SwiftTerm's `keyDown` is `public` but not `open` — same
    /// constraint as the Ctrl/selection monitors) and send `ESC + CR`, the
    /// same bytes macOS emits for Option+Enter and that Claude Code already
    /// documents as its multiline shortcut. In zsh/bash readline, Meta+CR
    /// runs `accept-line` identically to plain CR, so this doesn't regress
    /// shell submission. Gating on "no disambiguate flag" leaves Codex's
    /// `CSI 13;2u` path untouched.
    nonisolated(unsafe) private var shiftReturnMonitor: Any?

    private func installShiftReturnMonitor() {
        shiftReturnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window else { return event }
            guard self.window?.firstResponder === self else { return event }
            // Let IME finish composing — Shift+Enter on most macOS IMEs
            // commits the syllable and shouldn't be eaten before the commit.
            guard !self.hasMarkedText() else { return event }
            guard Self.isShiftReturn(event) else { return event }
            // SwiftTerm's encoder already emits CSI 13;2u when disambiguate
            // is on (Codex's flag set), so don't double-handle.
            guard !self.terminal.keyboardEnhancementFlags.contains(.disambiguate) else {
                return event
            }
            self.send(txt: "\u{1B}\r")
            return nil
        }
    }

    nonisolated static func isShiftReturn(_ event: NSEvent) -> Bool {
        let isReturnKey = Int(event.keyCode) == kVK_Return
            || Int(event.keyCode) == kVK_ANSI_KeypadEnter
        guard isReturnKey else { return false }
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return mods == .shift
    }

    /// When any kitty keyboard flag is active, SwiftTerm's `insertText` path
    /// routes committed text through its kitty encoder, which derives the
    /// outgoing key from the current physical keyDown. For IME commits
    /// (Hangul, Kana, ...) or dead-key composition, the physical key doesn't
    /// describe the inserted scalar. Worse: with `REPORT_ALTERNATE_KEYS` and
    /// a non-nil `baseLayoutKey` (always the case on non-US layouts like
    /// Korean 2-set, where keyCode 15 maps to 'r' but produces 'ㄱ'), the
    /// encoder strips the associated text and emits only the CSI-u key code,
    /// so Codex sees the raw jamo of the triggering key instead of the
    /// composed syllable.
    ///
    /// Fix: when a kitty mode is active and the commit is non-empty, non-
    /// control, non-ASCII text, bypass SwiftTerm's encoder and deliver the
    /// UTF-8 bytes directly. Pure-ASCII commits are left alone — SwiftTerm's
    /// encoder already emits them correctly in every observed kitty flag
    /// configuration. Gating on "any kitty flag" (not just
    /// `REPORT_ALL_KEYS_AS_ESCAPE_CODES`) is load-bearing: crossterm clients
    /// like Codex push only disambiguate + event-types + alternates and
    /// still hit the text-stripping path.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = Self.plainText(from: string),
           Self.shouldBypassKittyEncoder(text: text, kittyFlags: terminal.keyboardEnhancementFlags) {
            send(txt: text)
            // Mirror the cleanup that super.insertText would have done: drop the
            // marked-text overlay and clear SwiftTerm's `kittyIsComposing` flag.
            // Without this, the next kitty-encoded key (e.g. Ctrl+A right after
            // the Korean + space that lands here) sees `composing: true` and is
            // silently dropped by KittyKeyboardEncoder.
            super.unmarkText()
            imeCompositionActive = false
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        imeCompositionActive = hasMarkedText()
    }

    /// SwiftTerm's `setMarkedText` unconditionally sets its private
    /// `kittyIsComposing` to `true`, even when the incoming string is empty —
    /// which is the exact call Korean IME makes right after committing a
    /// syllable on space. That strands `kittyIsComposing` at `true` with no
    /// marked text in flight, and the next kitty-encoded key gets dropped.
    /// Route empty-string updates through `unmarkText` instead, which clears
    /// both the storage and the composing flag.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let text = Self.plainText(from: string), text.isEmpty {
            super.unmarkText()
            imeCompositionActive = false
            return
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        imeCompositionActive = hasMarkedText()
    }

    override func unmarkText() {
        super.unmarkText()
        imeCompositionActive = false
    }

    /// SwiftTerm anchors the IME preview overlay to `caretView.frame.origin`
    /// at the instant `setMarkedText` runs. For TUIs that redraw their input
    /// line asynchronously (Claude, Codex, tmux, …) the caret hasn't advanced
    /// past the just-committed syllable yet, so the next syllable's overlay
    /// lands on top of the previous one — visually erasing it until the next
    /// keystroke. Re-anchor the overlay after each PTY echo.
    ///
    /// `caretView.frame` is updated by `updateDisplay`, which SwiftTerm
    /// throttles to 60 fps via `DispatchQueue.main.asyncAfter(16.67 ms)`, so a
    /// plain `async` would run *before* the caret repositions — we have to
    /// wait past that tick. Coalesce repeated receives onto a single deferred
    /// reposition.
    nonisolated(unsafe) private var markedTextRepositionWork: DispatchWorkItem?

    // Live verification (required per memory `feedback_termy_live_verify.md`):
    //   1. Build & launch termy with `xcodebuild -scheme termy -destination
    //      'platform=macOS' run`.
    //   2. Open a pane, run `codex` with a reasoning-heavy prompt
    //      ("think carefully and explain X in 5 paragraphs").
    //   3. Verify dashboard chip stays on THINK during the long reasoning
    //      period — should NOT flicker to WAIT (silent POSSIBLY_WAITING).
    //   4. Trigger an actual permission prompt (e.g. `codex` asks to run
    //      Bash); verify chip flips to WAIT with sound.
    //   5. After ~20s of model hang (kill -STOP `pidof codex`), confirm
    //      promotion to WAIT(.promotedFromPossible) with sound.

    /// PTY produced bytes — forward to SwiftTerm's renderer (via super) and
    /// publish a liveness ping to HookDaemon. The ping reverts a Codex pane
    /// out of POSSIBLY_WAITING because reasoning-summary text prints to the
    /// PTY even between hook events. Also re-anchors an in-flight IME overlay
    /// to the current caret position after each PTY echo.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        // Liveness ping: revert POSSIBLY_WAITING → THINKING while PTY is
        // producing output (reasoning text keeps flowing even between hooks).
        if let id = paneId {
            Task { await HookDaemon.shared.recordPtyActivity(paneId: id) }
        }

        // IME overlay re-anchor: after a PTY echo SwiftTerm repositions the
        // caret, so we must re-deliver the marked text to sync the overlay.
        guard hasMarkedText() else { return }
        markedTextRepositionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.repositionMarkedTextOverlay()
        }
        markedTextRepositionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.030, execute: work)
    }

    private func repositionMarkedTextOverlay() {
        guard hasMarkedText() else { return }
        let range = markedRange()
        guard let text = attributedSubstring(forProposedRange: range, actualRange: nil) else { return }
        // Re-delivering the same marked text to super triggers SwiftTerm's
        // private `updateMarkedTextOverlay`, which re-reads `caretView.frame`
        // and repositions the NSTextField overlay to the now-current caret.
        super.setMarkedText(text, selectedRange: range, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    nonisolated static func shouldBypassKittyEncoder(text: String, kittyFlags: KittyKeyboardFlags) -> Bool {
        guard !kittyFlags.isEmpty, !text.isEmpty else { return false }
        guard text.unicodeScalars.allSatisfy({ !isControlScalar($0) }) else { return false }
        return text.unicodeScalars.contains { !$0.isASCII }
    }

    nonisolated private static func plainText(from value: Any) -> String? {
        switch value {
        case let attributed as NSAttributedString:
            return attributed.string
        case let text as String:
            return text
        case let text as NSString:
            return text as String
        default:
            return nil
        }
    }

    nonisolated private static func isControlScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F:
            return true
        default:
            return false
        }
    }

    // MARK: - Drag and Drop
    //
    // Accept file drops onto the terminal and inject the dropped paths as
    // typed text — same UX iTerm2 / Terminal.app provide. Neither termy nor
    // SwiftTerm registers for any dragged types out of the box, so without
    // this the view silently rejects drags (no copy cursor, no drop). Paths
    // are backslash-escaped so unquoted shell context (zsh prompt) parses
    // them as a single argument; TUI clients (Claude, Codex) just see the
    // escaped text inserted into their input field, which is the same thing
    // those clients already document handling for drag-from-Finder.

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return Self.canAcceptFileDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return Self.canAcceptFileDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return Self.canAcceptFileDrop(from: sender.draggingPasteboard)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            return false
        }
        let escaped = urls.map { Self.shellEscape($0.path) }.joined(separator: " ")
        send(txt: escaped)
        return true
    }

    nonisolated private static func canAcceptFileDrop(from pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: options)
    }

    /// Backslash-escape characters that the shell would otherwise treat
    /// specially in unquoted context. Matches the set iTerm2/Terminal.app use
    /// for drag-and-drop, which keeps the inserted text legible (no wrapping
    /// quotes) while staying safe under zsh/bash word splitting.
    nonisolated static func shellEscape(_ path: String) -> String {
        var result = ""
        result.reserveCapacity(path.count)
        for ch in path {
            switch ch {
            case " ", "\t", "\n", "\\", "'", "\"", "$", "`", "&", "|", ";",
                 "(", ")", "<", ">", "*", "?", "[", "]", "{", "}", "~", "!", "#":
                result.append("\\")
                result.append(ch)
            default:
                result.append(ch)
            }
        }
        return result
    }
}

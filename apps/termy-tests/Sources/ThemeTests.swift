import AppKit
import XCTest
@testable import termy

final class ThemeTests: XCTestCase {
    func test_appearanceVariant_resolvesAquaAsLight() {
        XCTAssertEqual(PaneStyling.variant(for: NSAppearance(named: .aqua)), .light)
    }

    func test_appearanceVariant_resolvesDarkAquaAsDark() {
        XCTAssertEqual(PaneStyling.variant(for: NSAppearance(named: .darkAqua)), .dark)
    }

    func test_lightTheme_isVisiblyLighterThanDarkTheme() {
        let darkTheme = PaneStyling.theme(for: .dark)
        let lightTheme = PaneStyling.theme(for: .light)

        XCTAssertGreaterThan(brightness(of: lightTheme.windowBackgroundColor), brightness(of: darkTheme.windowBackgroundColor))
        XCTAssertGreaterThan(brightness(of: lightTheme.paneBackgroundColor), brightness(of: darkTheme.paneBackgroundColor))
    }

    func test_selectionBackgroundIsOpaque_forBothThemes() {
        // SwiftTerm f37922e painted selection via `NSRect.fill()` (`.copy`
        // compositing op). Non-opaque colors were written as premultiplied RGB
        // and displayed as an opaque pixel — an rgba overlay showed up
        // darkened, not blended, and text on selected rows was unreadable
        // (light mode, 2026-04-21). 1.20 fills with normal blending, but keep
        // the colors opaque so they don't depend on how SwiftTerm composites.
        for variant: TermyThemeVariant in [.dark, .light] {
            let theme = PaneStyling.theme(for: variant)
            let resolved = theme.terminalSelectionBackgroundColor.usingColorSpace(.deviceRGB)
            XCTAssertEqual(resolved?.alphaComponent, 1.0, "\(variant) selection color must be opaque")
        }
    }

    /// Pane paints selected text in `terminalForegroundColor` (SwiftTerm 1.20
    /// overrides the text color of every selected cell), so that pair must
    /// stay readable: WCAG AA for body text is 4.5:1.
    func test_selectedText_isReadableOnSelectionBackground_forBothThemes() {
        for variant: TermyThemeVariant in [.dark, .light] {
            let theme = PaneStyling.theme(for: variant)
            let ratio = contrastRatio(
                theme.terminalForegroundColor,
                theme.terminalSelectionBackgroundColor
            )
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(variant) selected text contrast")
        }
    }

    func test_builtinThemes_shipExpectedPaletteSurface() {
        let darkTheme = PaneStyling.theme(for: .dark)
        let lightTheme = PaneStyling.theme(for: .light)

        XCTAssertEqual(darkTheme.accentPalette.count, 10)
        XCTAssertEqual(lightTheme.accentPalette.count, 10)
        XCTAssertEqual(darkTheme.terminalANSIColors.count, 16)
        XCTAssertEqual(lightTheme.terminalANSIColors.count, 16)
        XCTAssertLessThan(lightTheme.headerTintAlpha, darkTheme.headerTintAlpha)
    }

    func test_focusAppearance_emphasizesActivePaneAndDimsInactivePane() {
        for variant: TermyThemeVariant in [.dark, .light] {
            let theme = PaneStyling.theme(for: variant)
            let accent = theme.accentPalette[0]
            let active = PaneStyling.focusAppearance(active: true, accent: accent, theme: theme)
            let inactive = PaneStyling.focusAppearance(active: false, accent: accent, theme: theme)

            XCTAssertEqual(active.paneOpacity, 1.0)
            XCTAssertLessThan(inactive.paneOpacity, active.paneOpacity)
            XCTAssertGreaterThan(active.borderWidth, inactive.borderWidth)
            XCTAssertGreaterThan(alpha(of: active.borderColor), alpha(of: inactive.borderColor))
            XCTAssertEqual(alpha(of: inactive.caretColor), 0)
        }
    }

    private func brightness(of color: NSColor) -> CGFloat {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red * 0.299) + (green * 0.587) + (blue * 0.114)
    }

    private func alpha(of color: NSColor) -> CGFloat {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        var alpha: CGFloat = 0
        resolved.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha
    }

    /// WCAG 2 contrast ratio between two opaque colors.
    private func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let lighter = max(relativeLuminance(of: a), relativeLuminance(of: b))
        let darker = min(relativeLuminance(of: a), relativeLuminance(of: b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(of color: NSColor) -> CGFloat {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(resolved.redComponent)
            + 0.7152 * linear(resolved.greenComponent)
            + 0.0722 * linear(resolved.blueComponent)
    }
}

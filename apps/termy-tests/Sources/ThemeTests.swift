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
        // SwiftTerm paints selection via `NSRect.fill()` (`.copy` compositing
        // op). Non-opaque colors are written as premultiplied RGB and displayed
        // as an opaque pixel — an rgba overlay shows up darkened, not blended.
        // Selection colors must carry alpha 1.0 or text on selected rows is
        // unreadable (light mode, 2026-04-21).
        for variant: TermyThemeVariant in [.dark, .light] {
            let theme = PaneStyling.theme(for: variant)
            let resolved = theme.terminalSelectionBackgroundColor.usingColorSpace(.deviceRGB)
            XCTAssertEqual(resolved?.alphaComponent, 1.0, "\(variant) selection color must be opaque")
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
}

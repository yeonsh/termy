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

    private func brightness(of color: NSColor) -> CGFloat {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red * 0.299) + (green * 0.587) + (blue * 0.114)
    }
}

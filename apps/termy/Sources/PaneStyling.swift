// PaneStyling.swift
//
// Turns a project identifier (e.g. "api", "frontend", "infra") into a
// deterministic accent color. Same project → same color across tabs and
// launches. The palette is curated (not raw HSB) so every color lands in
// the same readability + saturation neighborhood and the window reads as
// intentional rather than random.

import AppKit

enum TermyThemeVariant: String {
    case dark
    case light
}

struct TermyTheme {
    let variant: TermyThemeVariant
    let accentPalette: [NSColor]
    let windowBackgroundColor: NSColor
    let contentBackgroundColor: NSColor
    let paneBackgroundColor: NSColor
    let terminalForegroundColor: NSColor
    let terminalSelectionBackgroundColor: NSColor
    let panelBackgroundColor: NSColor
    let panelBorderColor: NSColor
    let headerTintAlpha: CGFloat
    let terminalANSIColors: [NSColor]
}

struct PaneFocusAppearance {
    let paneOpacity: Float
    let borderWidth: CGFloat
    let borderColor: NSColor
    let caretColor: NSColor
}

enum PaneStyling {
    /// Hash-based assignment produced repeat hues for small project counts —
    /// 4 projects could easily land on three shades of red. Sequential
    /// allocation guarantees the first N projects get the first N distinct
    /// palette slots; we only wrap once the palette is exhausted.
    /// Order is "first seen this session" — stable within a launch.
    @MainActor private static var assignments: [String: Int] = [:]
    @MainActor private static var nextIndex: Int = 0

    static func variant(for appearance: NSAppearance?) -> TermyThemeVariant {
        let match = appearance?.bestMatch(from: [.darkAqua, .aqua])
        return match == .aqua ? .light : .dark
    }

    static func theme(for appearance: NSAppearance?) -> TermyTheme {
        theme(for: variant(for: appearance))
    }

    static func theme(for variant: TermyThemeVariant) -> TermyTheme {
        switch variant {
        case .dark:
            return darkTheme
        case .light:
            return lightTheme
        }
    }

    @MainActor static func accentColor(for projectId: String, appearance: NSAppearance? = nil) -> NSColor {
        let key = projectId.isEmpty ? "untitled" : projectId
        if let idx = assignments[key] {
            let palette = theme(for: appearance).accentPalette
            return palette[idx % palette.count]
        }
        let idx = nextIndex
        assignments[key] = idx
        nextIndex += 1
        let palette = theme(for: appearance).accentPalette
        return palette[idx % palette.count]
    }

    static func focusAppearance(active: Bool, accent: NSColor, theme: TermyTheme) -> PaneFocusAppearance {
        if active {
            return PaneFocusAppearance(
                paneOpacity: 1.0,
                borderWidth: 2.5,
                borderColor: accent.withAlphaComponent(theme.variant == .dark ? 0.95 : 0.85),
                caretColor: accent
            )
        }

        return PaneFocusAppearance(
            paneOpacity: theme.variant == .dark ? 0.88 : 0.91,
            borderWidth: 1.0,
            borderColor: theme.terminalForegroundColor.withAlphaComponent(theme.variant == .dark ? 0.14 : 0.16),
            caretColor: .clear
        )
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        rgba(r, g, b, 1)
    }

    private static func rgba(_ r: Int, _ g: Int, _ b: Int, _ alpha: CGFloat) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: alpha
        )
    }

    private static let darkTheme = TermyTheme(
        variant: .dark,
        accentPalette: [
            rgb(134, 239, 172), // mint
            rgb(125, 211, 252), // sky
            rgb(196, 181, 253), // violet
            rgb(249, 168, 212), // pink
            rgb(252, 165, 165), // coral
            rgb(253, 186, 116), // peach
            rgb(253, 224,  71), // butter
            rgb(190, 242, 100), // lime
            rgb(103, 232, 249), // cyan
            rgb(253, 164, 175)  // rose
        ],
        windowBackgroundColor: rgb(10, 12, 15),
        contentBackgroundColor: rgb(10, 12, 15),
        paneBackgroundColor: rgb(18, 20, 26),
        terminalForegroundColor: rgb(232, 235, 241),
        // Must be opaque: SwiftTerm paints the selection via `NSRect.fill()`,
        // which uses the `.copy` compositing op — any alpha <1 is written as
        // premultiplied RGB and then displayed as an opaque pixel, so an
        // rgba(…, 0.34) overlay shows up as its dark premultiplied RGB instead
        // of blending. Use the pre-blended opaque result (pane bg mixed with
        // the intended overlay at 34%).
        terminalSelectionBackgroundColor: rgb(39, 54, 84),
        panelBackgroundColor: rgb(36, 36, 36),
        panelBorderColor: rgba(255, 255, 255, 0.12),
        headerTintAlpha: 0.65,
        terminalANSIColors: [
            rgb(23, 24, 30),
            rgb(220, 95, 93),
            rgb(141, 209, 122),
            rgb(233, 197, 106),
            rgb(111, 164, 255),
            rgb(201, 135, 255),
            rgb(96, 211, 214),
            rgb(205, 212, 224),
            rgb(96, 102, 118),
            rgb(255, 123, 121),
            rgb(169, 228, 150),
            rgb(255, 219, 132),
            rgb(136, 186, 255),
            rgb(221, 163, 255),
            rgb(126, 231, 236),
            rgb(249, 250, 251)
        ]
    )

    private static let lightTheme = TermyTheme(
        variant: .light,
        accentPalette: [
            rgb(74, 222, 128),  // mint
            rgb(56, 189, 248),  // sky
            rgb(129, 140, 248), // indigo
            rgb(244, 114, 182), // pink
            rgb(248, 113, 113), // coral
            rgb(251, 146, 60),  // orange
            rgb(234, 179, 8),   // amber
            rgb(132, 204, 22),  // lime
            rgb(45, 212, 191),  // teal
            rgb(251, 113, 133)  // rose
        ],
        windowBackgroundColor: rgb(240, 243, 247),
        contentBackgroundColor: rgb(240, 243, 247),
        paneBackgroundColor: rgb(250, 251, 253),
        terminalForegroundColor: rgb(35, 40, 49),
        // See note on the dark theme's selection color — opaque is mandatory
        // because SwiftTerm's `.copy` fill turns an alpha overlay into its
        // premultiplied RGB, and `rgba(80, 137, 231, 0.24)` would paint as
        // `rgb(19, 33, 55)` — near-black text on near-black selection.
        terminalSelectionBackgroundColor: rgb(209, 224, 248),
        panelBackgroundColor: rgb(248, 249, 251),
        panelBorderColor: rgba(23, 28, 36, 0.10),
        headerTintAlpha: 0.24,
        terminalANSIColors: [
            rgb(54, 58, 66),
            rgb(207, 69, 79),
            rgb(47, 133, 90),
            rgb(184, 124, 10),
            rgb(37, 99, 235),
            rgb(168, 85, 247),
            rgb(13, 148, 136),
            rgb(214, 219, 227),
            rgb(107, 114, 128),
            rgb(232, 83, 94),
            rgb(59, 150, 102),
            rgb(208, 144, 24),
            rgb(58, 121, 255),
            rgb(190, 106, 255),
            rgb(17, 166, 152),
            rgb(248, 249, 251)
        ]
    )
}

enum TermyTypography {
    static let defaultPointSize: CGFloat = 14

    static func regular(size: CGFloat = defaultPointSize) -> NSFont {
        font(size: size, weight: .regular)
    }

    static func medium(size: CGFloat = defaultPointSize) -> NSFont {
        font(size: size, weight: .medium)
    }

    static func semibold(size: CGFloat = defaultPointSize) -> NSFont {
        font(size: size, weight: .semibold)
    }

    static func font(size: CGFloat = defaultPointSize, weight: NSFont.Weight) -> NSFont {
        for name in candidateNames(for: weight) {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func candidateNames(for weight: NSFont.Weight) -> [String] {
        switch weight {
        case ..<NSFont.Weight.medium:
            return [
                "FiraCode-Regular",
                "Fira Code Regular",
                "FiraCodeRoman-Regular",
                "Fira Code"
            ]
        case ..<NSFont.Weight.semibold:
            return [
                "FiraCode-Medium",
                "Fira Code Medium",
                "Fira Code"
            ]
        default:
            return [
                "FiraCode-SemiBold",
                "Fira Code SemiBold",
                "FiraCode-Bold",
                "Fira Code Bold",
                "Fira Code"
            ]
        }
    }
}

final class AppearanceAwareView: NSView {
    var onAppearanceChange: ((NSAppearance) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportAppearanceChange()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reportAppearanceChange()
    }

    private func reportAppearanceChange() {
        onAppearanceChange?(effectiveAppearance)
    }
}

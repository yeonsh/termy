// TerminalFontPreference.swift
//
// User-controlled font for the terminal pane. Two pieces:
//   1. A primary monospaced font (name + point size).
//   2. A CJK fallback font that Core Text consults when the primary lacks
//      a glyph. The fallback is wired in via `kCTFontCascadeListAttribute`
//      on the resolved NSFont's descriptor — SwiftTerm renders through
//      CTLine/CTRun, so cascade lookup happens automatically per glyph.
//
// Why a separate CJK fallback rather than relying on the system default:
// FiraCode (and most coding fonts) ship no Hangul/CJK, so macOS picks
// Apple SD Gothic Neo at draw time. That font isn't monospaced, which
// makes Korean glyphs sit on subpixel x positions and look smeared next
// to ASCII. Letting the user pick D2Coding / NanumGothicCoding / etc.
// keeps the cell grid aligned.

import AppKit
import CoreText
import Foundation

@MainActor
final class TerminalFontPreference {
    static let shared = TerminalFontPreference()

    /// Posted (on main) whenever any field changes. Listeners re-apply the
    /// resolved font to their terminals.
    static let didChangeNotification = Notification.Name("termy.terminalFontDidChange")

    /// CJK fallback choice that means "let the system pick". Encoded as the
    /// empty string in UserDefaults so we can tell "unset" apart from
    /// "explicitly system" if we ever need to.
    static let systemCJKFallback = ""

    private enum Keys {
        static let primaryName = "termy.terminalFont.primaryName"
        static let pointSize = "termy.terminalFont.pointSize"
        static let cjkFallbackName = "termy.terminalFont.cjkFallbackName"
    }

    static let defaultPointSize: CGFloat = 14
    static let minPointSize: CGFloat = 9
    static let maxPointSize: CGFloat = 36

    /// Names tried in order until one resolves. Mirrors the legacy
    /// TermyTypography fallback chain so existing installs see no change
    /// when no preference is stored.
    static let defaultPrimaryCandidates: [String] = [
        "FiraCode-Regular",
        "Fira Code Regular",
        "FiraCodeRoman-Regular",
        "Fira Code"
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Stored fields

    var primaryFontName: String {
        get { defaults.string(forKey: Keys.primaryName) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Keys.primaryName)
            } else {
                defaults.set(trimmed, forKey: Keys.primaryName)
            }
        }
    }

    var pointSize: CGFloat {
        get {
            let stored = defaults.object(forKey: Keys.pointSize) as? Double
            guard let stored, stored > 0 else { return Self.defaultPointSize }
            return CGFloat(min(max(stored, Double(Self.minPointSize)), Double(Self.maxPointSize)))
        }
        set {
            let clamped = min(max(newValue, Self.minPointSize), Self.maxPointSize)
            defaults.set(Double(clamped), forKey: Keys.pointSize)
        }
    }

    /// Empty string ⇒ no explicit fallback (Core Text falls back to the
    /// system cascade list, same behavior as before this preference existed).
    var cjkFallbackName: String {
        get { defaults.string(forKey: Keys.cjkFallbackName) ?? Self.systemCJKFallback }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Keys.cjkFallbackName)
            } else {
                defaults.set(trimmed, forKey: Keys.cjkFallbackName)
            }
        }
    }

    // MARK: - Resolution

    /// Build the NSFont SwiftTerm should render with. Honors the stored
    /// primary font name + point size, and inserts the CJK fallback at the
    /// front of the descriptor's cascade list when one is configured.
    ///
    /// Falls back to the legacy FiraCode chain → system monospaced if the
    /// stored name doesn't resolve (uninstalled font, typo, etc.).
    func resolvedFont() -> NSFont {
        let size = pointSize
        let primary = resolvedPrimaryFont(size: size)

        guard let cjkDescriptor = cjkFallbackDescriptor() else {
            return primary
        }

        let descriptor = primary.fontDescriptor.addingAttributes([
            .cascadeList: [cjkDescriptor]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? primary
    }

    /// Convenience for callers that want to apply size scaling without
    /// caring about cascade plumbing — same shape as the old
    /// `TermyTypography.regular(size:)` API.
    func resolvedFont(size: CGFloat) -> NSFont {
        let primary = resolvedPrimaryFont(size: size)
        guard let cjkDescriptor = cjkFallbackDescriptor() else {
            return primary
        }
        let descriptor = primary.fontDescriptor.addingAttributes([
            .cascadeList: [cjkDescriptor]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? primary
    }

    private func resolvedPrimaryFont(size: CGFloat) -> NSFont {
        let userName = primaryFontName
        if !userName.isEmpty, let font = NSFont(name: userName, size: size) {
            return font
        }
        for name in Self.defaultPrimaryCandidates {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func cjkFallbackDescriptor() -> NSFontDescriptor? {
        let name = cjkFallbackName
        guard !name.isEmpty else { return nil }
        // Verify the font actually exists before handing it to Core Text —
        // a typo'd name silently produces no fallback rather than warning,
        // and we'd rather skip the cascade entry than confuse the user.
        guard NSFont(name: name, size: 12) != nil else { return nil }
        return NSFontDescriptor(fontAttributes: [.name: name])
    }

    // MARK: - Mutation

    /// Apply a new triple atomically and notify listeners.
    func update(primaryName: String, pointSize: CGFloat, cjkFallbackName: String) {
        self.primaryFontName = primaryName
        self.pointSize = pointSize
        self.cjkFallbackName = cjkFallbackName
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - Font catalogs (for the picker UI)

    /// Names of every fixed-pitch font installed on the system. Used to
    /// populate the primary-font picker. Sorted, deduped on display name.
    static func availableMonospacedFontNames() -> [String] {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        // Family-level dedupe keeps the list short — one entry per family,
        // pointing at the regular/roman face when available.
        var seenFamily = Set<String>()
        var result: [String] = []
        for name in names {
            guard let font = NSFont(name: name, size: 12) else { continue }
            let family = font.familyName ?? name
            if seenFamily.insert(family).inserted {
                result.append(name)
            }
        }
        return result.sorted { lhs, rhs in
            displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
        }
    }

    /// Family-name substrings that flag a font as a useful CJK fallback.
    /// Matched case-insensitively against the family name reported by
    /// macOS — this catches PostScript-name variants we can't enumerate
    /// up front (e.g. "D2Coding" vs "D2Codingligature" vs "D2CodingBold").
    private static let cjkFamilyMatches: [String] = [
        "D2Coding", "Nanum", "Apple SD Gothic", "PingFang", "Hiragino",
        "Sarasa", "Osaka", "Noto Sans CJK", "Noto Serif CJK",
        "Source Han", "BIZ UD", "MS Gothic", "MS Mincho"
    ]

    /// Scan installed fonts and return one PostScript name per CJK-friendly
    /// family. Sorted by display name. Falls back to "no candidates" if
    /// somehow no CJK families are installed (in which case the picker just
    /// shows "System default" — Core Text will pick a fallback at draw time).
    static func availableCJKFallbackNames() -> [String] {
        let manager = NSFontManager.shared
        var seenFamily = Set<String>()
        var result: [String] = []

        for family in (manager.availableFontFamilies) {
            guard cjkFamilyMatches.contains(where: { family.range(of: $0, options: .caseInsensitive) != nil })
            else { continue }
            // Pick the family's regular face (lowest weight, no italic).
            let members = manager.availableMembers(ofFontFamily: family) ?? []
            let regular = members.first(where: { ($0[1] as? String)?.lowercased() == "regular" })
                ?? members.first
            guard
                let regular,
                let postScript = regular[0] as? String,
                NSFont(name: postScript, size: 12) != nil,
                seenFamily.insert(family).inserted
            else { continue }
            result.append(postScript)
        }

        return result.sorted { lhs, rhs in
            displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
        }
    }

    /// Pretty label for a PostScript font name — uses the displayName the
    /// system reports, falling back to the raw PostScript identifier.
    static func displayName(for postScriptName: String) -> String {
        if let font = NSFont(name: postScriptName, size: 12) {
            return font.displayName ?? postScriptName
        }
        return postScriptName
    }
}

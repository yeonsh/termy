import AppKit
import Foundation

enum AppAppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    static let defaultsKey = "termy.appearancePreference"

    var themeVariant: TermyThemeVariant? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var displayName: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// SF Symbol name for the HUD that flashes on cycle.
    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// Cycle order: system → light → dark → system. Mirrors the View →
    /// Appearance submenu so the chord and the menu read the same way.
    var next: Self {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system:
            return nil
        case .light:
            return .aqua
        case .dark:
            return .darkAqua
        }
    }

    var appearance: NSAppearance? {
        guard let appearanceName else { return nil }
        return NSAppearance(named: appearanceName)!
    }

    static func stored(defaults: UserDefaults = .standard) -> Self? {
        guard let rawValue = defaults.string(forKey: defaultsKey) else { return nil }
        return Self(rawValue: rawValue)
    }

    static func activeVariant(
        defaults: UserDefaults = .standard,
        fallbackAppearance: NSAppearance?
    ) -> TermyThemeVariant {
        stored(defaults: defaults)?.themeVariant ?? PaneStyling.variant(for: fallbackAppearance)
    }

    func persist(defaults: UserDefaults = .standard) {
        if self == .system {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(rawValue, forKey: Self.defaultsKey)
        }
    }

    @MainActor
    func apply(
        defaults: UserDefaults = .standard,
        application: NSApplication = .shared
    ) {
        persist(defaults: defaults)
        application.appearance = appearance
    }

    @MainActor
    static func applyStoredPreference(
        defaults: UserDefaults = .standard,
        application: NSApplication = .shared
    ) {
        application.appearance = stored(defaults: defaults)?.appearance
    }
}

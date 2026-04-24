import AppKit
import XCTest
@testable import termy

final class AppAppearancePreferenceTests: XCTestCase {
    func test_storedPreference_readsPersistedValue() {
        let defaults = makeDefaults()
        defaults.set(AppAppearancePreference.dark.rawValue, forKey: AppAppearancePreference.defaultsKey)

        XCTAssertEqual(AppAppearancePreference.stored(defaults: defaults), .dark)
    }

    func test_activeVariant_fallsBackToEffectiveAppearanceWhenUnset() {
        let defaults = makeDefaults()

        XCTAssertEqual(
            AppAppearancePreference.activeVariant(
                defaults: defaults,
                fallbackAppearance: NSAppearance(named: .aqua)
            ),
            .light
        )
        XCTAssertEqual(
            AppAppearancePreference.activeVariant(
                defaults: defaults,
                fallbackAppearance: NSAppearance(named: .darkAqua)
            ),
            .dark
        )
    }

    func test_systemPreference_clearsManualOverride() {
        let defaults = makeDefaults()
        defaults.set(AppAppearancePreference.dark.rawValue, forKey: AppAppearancePreference.defaultsKey)

        AppAppearancePreference.system.persist(defaults: defaults)

        XCTAssertNil(AppAppearancePreference.stored(defaults: defaults))
    }

    func test_preference_exposesExpectedNamedAppearance() {
        XCTAssertNil(AppAppearancePreference.system.appearanceName)
        XCTAssertEqual(AppAppearancePreference.light.appearanceName, .aqua)
        XCTAssertEqual(AppAppearancePreference.dark.appearanceName, .darkAqua)
    }

    private func makeDefaults(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let suiteName = "AppAppearancePreferenceTests.\(file).\(line)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

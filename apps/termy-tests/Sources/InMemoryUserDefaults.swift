import XCTest

/// `UserDefaults` that keeps its values in memory, for tests that only need
/// somewhere to put a value. A `UserDefaults(suiteName:)` domain leaves a
/// plist in ~/Library/Preferences even after `removePersistentDomain` —
/// cfprefsd writes the emptied domain back later, and re-creates the file
/// after it is deleted.
final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    /// Anything not overridden below lands in this fixed domain, never in
    /// the test host's standard one (which is termy's real domain).
    static let fallbackSuiteName = "termy-tests.InMemoryUserDefaults"

    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: Self.fallbackSuiteName)!
    }

    override func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    override func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
    }
}

final class InMemoryUserDefaultsTests: XCTestCase {
    func test_valuesStayInMemory() {
        let defaults = InMemoryUserDefaults()
        defaults.set("{600, 700}", forKey: "k")
        XCTAssertEqual(defaults.string(forKey: "k"), "{600, 700}")
        XCTAssertNil(InMemoryUserDefaults().string(forKey: "k"), "instances don't share values")
        XCTAssertNil(
            UserDefaults(suiteName: InMemoryUserDefaults.fallbackSuiteName)?.object(forKey: "k"),
            "nothing reached the backing domain"
        )
        defaults.removeObject(forKey: "k")
        XCTAssertNil(defaults.string(forKey: "k"))
    }
}

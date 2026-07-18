import XCTest
@testable import Lineform

final class ExportStylePreferenceTests: XCTestCase {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "ExportStylePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    func testAbsentPreferenceResolvesToStandard() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ExportStylePreference.selectedPresetID(defaults: defaults), "standard")
        XCTAssertEqual(ExportStylePreference.selectedPreset(defaults: defaults).id, "standard")
    }

    func testKnownPresetIDRoundTrips() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ExportStylePreference.setSelectedPresetID("compact", defaults: defaults)

        XCTAssertEqual(ExportStylePreference.selectedPresetID(defaults: defaults), "compact")
        XCTAssertEqual(ExportStylePreference.selectedPreset(defaults: defaults).id, "compact")
    }

    func testUnknownPersistedIDFallsBackToStandard() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ExportStylePreference.setSelectedPresetID("nonsense", defaults: defaults)

        XCTAssertEqual(ExportStylePreference.selectedPresetID(defaults: defaults), "nonsense")
        XCTAssertEqual(ExportStylePreference.selectedPreset(defaults: defaults).id, "standard")
    }
}

import XCTest
@testable import Lineform

final class ReadingProfileStoreTests: XCTestCase {
    func testPersistsActiveProfileAcrossStoreInstances() {
        let defaults = UserDefaults(suiteName: "LineformReadingProfileStoreTests")!
        defaults.removePersistentDomain(forName: "LineformReadingProfileStoreTests")

        let store = ReadingProfileStore(defaults: defaults)
        store.apply(ReadingPreset.paper.profile)

        let restored = ReadingProfileStore(defaults: defaults)

        XCTAssertEqual(restored.activeProfile, ReadingPreset.paper.profile)
    }

    func testFallsBackToOriginalWhenNoProfileIsPersisted() {
        let defaults = UserDefaults(suiteName: "LineformReadingProfileStoreEmptyTests")!
        defaults.removePersistentDomain(forName: "LineformReadingProfileStoreEmptyTests")

        let store = ReadingProfileStore(defaults: defaults)

        XCTAssertEqual(store.activeProfile, .original)
    }

    func testMigratesLegacyOriginalProfileToCurrentDefaultWidth() throws {
        let defaults = UserDefaults(suiteName: "LineformReadingProfileStoreLegacyOriginalTests")!
        defaults.removePersistentDomain(forName: "LineformReadingProfileStoreLegacyOriginalTests")
        var legacyOriginal = ReadingProfile.original
        legacyOriginal.columnWidth = 680
        defaults.set(try JSONEncoder().encode(legacyOriginal), forKey: "Lineform.activeReadingProfile")

        let store = ReadingProfileStore(defaults: defaults)

        XCTAssertEqual(store.activeProfile.columnWidth, 820)
    }

    func testResetRestoresDefaultNormalReadingProfile() {
        let defaults = UserDefaults(suiteName: "LineformReadingProfileStoreResetTests")!
        defaults.removePersistentDomain(forName: "LineformReadingProfileStoreResetTests")
        let store = ReadingProfileStore(defaults: defaults)
        store.apply(ReadingPreset.dyslexia.profile)

        store.resetToDefault()

        XCTAssertEqual(store.activeProfile, .original)
    }

    func testApplyingReadingPresetPreservesCurrentTheme() {
        let defaults = UserDefaults(suiteName: "LineformReadingProfileStorePresetThemeTests")!
        defaults.removePersistentDomain(forName: "LineformReadingProfileStorePresetThemeTests")
        let store = ReadingProfileStore(defaults: defaults)
        store.update { $0.applyTheme(.night) }

        store.applyPreset(ReadingPreset.dyslexia)

        XCTAssertEqual(store.activeProfile.themeID, .night)
        XCTAssertEqual(store.activeProfile.fontID, .sfPro)
        XCTAssertTrue(store.activeProfile.readingRulerEnabled)
    }

    func testCustomizedPresetDoesNotContinueToMatchBuiltInPresetSelection() {
        var profile = ReadingPreset.paper.profile
        XCTAssertEqual(ReadingPreset.matchingPresetID(for: profile), ReadingPreset.paper.profile.id)

        profile.fontSize += 1

        XCTAssertNil(ReadingPreset.matchingPresetID(for: profile))
    }
}

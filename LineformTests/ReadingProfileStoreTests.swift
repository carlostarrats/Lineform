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

    func testReadingExperienceInspectorKeepsOnlyDirectVisibleControls() {
        let labels = ReadingExperienceInspector.visibleControlLabels

        XCTAssertTrue(labels.contains("Theme"))
        XCTAssertTrue(labels.contains("Font"))
        XCTAssertTrue(labels.contains("Column Width"))
        XCTAssertTrue(labels.contains("Reduce Markdown Noise"))
        XCTAssertTrue(labels.contains("Reading Ruler"))
        XCTAssertTrue(labels.contains("Typewriter Mode"))
        XCTAssertTrue(labels.contains("Caret Width"))

        XCTAssertFalse(labels.contains("Reading Preset"))
        XCTAssertFalse(labels.contains("Margins"))
        XCTAssertFalse(labels.contains("Reduce Motion"))
    }

    func testReadingExperienceInspectorShowsValuesForEverySliderControl() {
        var profile = ReadingProfile.original
        profile.fontSize = 18
        profile.lineHeightMultiple = 1.45
        profile.paragraphSpacing = 12
        profile.letterSpacing = 0.4
        profile.columnWidth = 760
        profile.insertionPointWidth = 2

        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.fontSize, in: profile), "18 pt")
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.lineHeightMultiple, in: profile), "1.45")
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.paragraphSpacing, in: profile), "12 px")
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.letterSpacing, in: profile), "0.4")
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.columnWidth, in: profile), "760 px")
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.insertionPointWidth, in: profile), "2 px")
    }
}

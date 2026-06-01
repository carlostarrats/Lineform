import XCTest
@testable import Lineform

@MainActor
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

    func testApplyingReadingPresetUsesPresetTheme() {
        let defaults = UserDefaults(suiteName: "LineformReadingProfileStorePresetThemeTests")!
        defaults.removePersistentDomain(forName: "LineformReadingProfileStorePresetThemeTests")
        let store = ReadingProfileStore(defaults: defaults)
        store.update { $0.applyTheme(.night) }

        store.applyPreset(ReadingPreset.calm)

        XCTAssertEqual(store.activeProfile.themeID, .calm)
        XCTAssertEqual(store.activeProfile.fontID, .atkinsonHyperlegible)
        XCTAssertFalse(store.activeProfile.readingRulerEnabled)
    }

    func testCustomizedPresetDoesNotContinueToMatchBuiltInPresetSelection() {
        var profile = ReadingPreset.paper.profile
        XCTAssertEqual(ReadingPreset.matchingPresetID(for: profile), ReadingPreset.paper.profile.id)

        profile.fontSize += 1

        XCTAssertNil(ReadingPreset.matchingPresetID(for: profile))
    }

    func testReadingExperienceInspectorKeepsOnlyDirectVisibleControls() {
        let labels = ReadingExperienceInspector.visibleControlLabels

        XCTAssertTrue(labels.contains("Themes"))
        XCTAssertTrue(labels.contains("Font"))
        XCTAssertTrue(labels.contains("Column Width"))
        XCTAssertTrue(labels.contains("Reduce Markdown Noise"))
        XCTAssertTrue(labels.contains("Reading Ruler"))
        XCTAssertTrue(labels.contains("Typewriter Mode"))

        XCTAssertFalse(labels.contains("Appearance"))
        XCTAssertFalse(labels.contains("Theme"))
        XCTAssertFalse(labels.contains("Focus"))
        XCTAssertFalse(labels.contains("Focus Highlight"))
        XCTAssertFalse(labels.contains("Reading Preset"))
        XCTAssertFalse(labels.contains("Margins"))
        XCTAssertFalse(labels.contains("Caret Width"))
        XCTAssertFalse(labels.contains("Reduce Motion"))
    }

    func testReadingExperiencePresetGridUsesThreeColumns() {
        XCTAssertEqual(ReadingExperienceInspector.presetGridColumnCount, 3)
    }

    func testThemeGridUsesCompactLabelAndDimmedUnselectedCards() {
        XCTAssertEqual(ReadingExperienceInspector.themeTitle, "Themes")
        XCTAssertEqual(ReadingExperienceInspector.themeTitleFontSize, 13)
        XCTAssertEqual(ReadingExperienceInspector.unselectedPresetOpacity, 1)
        XCTAssertEqual(ReadingExperienceInspector.unselectedPresetContentOpacity, 1)
        XCTAssertGreaterThanOrEqual(ReadingExperienceInspector.themeToFontSpacing, 8)
    }

    func testResetButtonIsVisuallySeparatedWithoutDivider() {
        XCTAssertGreaterThanOrEqual(ReadingExperienceInspector.resetTopSpacing, 18)
        XCTAssertFalse(ReadingExperienceInspector.usesResetSeparator)
    }

    func testReadingAidsSectionLabelUsesControlLabelStyling() {
        XCTAssertTrue(ReadingExperienceInspector.usesReadingAidsSectionLabel)
        XCTAssertTrue(ReadingExperienceInspector.visibleControlLabels.contains("Reading Aids"))
        XCTAssertEqual(ReadingExperienceInspector.sectionLabelFontSize, 13)
    }

    func testReadingExperienceInspectorUsesNativeUIFontOutsideThemePreviews() throws {
        XCTAssertTrue(ReadingExperienceInspector.usesNativeUIFontOutsideThemePreviews)
        XCTAssertFalse(ReadingExperienceInspector.usesMonospacedInspectorValueFont)
        XCTAssertEqual(ReadingExperienceInspector.controlLabelFontSize, ReadingExperienceInspector.sectionLabelFontSize)
        XCTAssertEqual(ReadingExperienceInspector.valueFontSize, ReadingExperienceInspector.controlLabelFontSize)
    }

    func testReadingExperienceInspectorKeepsNativeControlHoverOnly() {
        XCTAssertTrue(ReadingExperienceInspector.usesNativeControlHoverOnly)
        XCTAssertGreaterThan(ReadingExperienceInspector.presetCardHoverFillOpacity, 0)
        XCTAssertLessThan(ReadingExperienceInspector.presetCardHoverFillOpacity, 0.2)
    }

    func testResetButtonKeepsVisibleButtonHoverFeedback() {
        XCTAssertTrue(ReadingExperienceInspector.resetButtonShowsHoverFeedback)
        XCTAssertGreaterThan(ReadingExperienceInspector.resetButtonHoverFillOpacity, 0)
        XCTAssertLessThan(ReadingExperienceInspector.resetButtonHoverFillOpacity, 0.2)
    }

    func testReadingExperienceInspectorShowsValuesForEverySliderControl() {
        var profile = ReadingProfile.original
        profile.fontSize = 18
        profile.lineHeightMultiple = 1.45
        profile.paragraphSpacing = 12
        profile.letterSpacing = 0.4
        profile.columnWidth = 760

        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.fontSize, in: profile), "18 pt")
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.lineHeightMultiple, in: profile), "1.45")
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.paragraphSpacing, in: profile), "12 px")
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.letterSpacing, in: profile), "0.4")
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.columnWidth, in: profile), "760 px")
    }

    func testReadingExperienceInspectorAllowsExpandedTypeAndLineHeightRanges() {
        XCTAssertEqual(ReadingExperienceInspector.fontSizeRange.lowerBound, 12)
        XCTAssertEqual(ReadingExperienceInspector.fontSizeRange.upperBound, 48)
        XCTAssertEqual(ReadingExperienceInspector.lineHeightRange.lowerBound, 0.5)
        XCTAssertEqual(ReadingExperienceInspector.lineHeightRange.upperBound, 1.8)
    }

    func testReadingExperienceInspectorUsesExplicitThemeSchemeAndBackground() throws {
        XCTAssertEqual(ReadingExperienceInspector.colorScheme(usesDarkChrome: false), .light)
        XCTAssertEqual(ReadingExperienceInspector.colorScheme(usesDarkChrome: true), .dark)

        let lightBackground = try XCTUnwrap(ReadingExperienceInspector.backgroundColor(usesDarkChrome: false).usingColorSpace(.sRGB))
        let darkBackground = try XCTUnwrap(ReadingExperienceInspector.backgroundColor(usesDarkChrome: true).usingColorSpace(.sRGB))

        let expectedLightBackground = try XCTUnwrap(LineformColors.inspectorLightBackground.usingColorSpace(.sRGB))
        XCTAssertEqual(lightBackground.redComponent, expectedLightBackground.redComponent, accuracy: 0.005)
        XCTAssertEqual(lightBackground.greenComponent, expectedLightBackground.greenComponent, accuracy: 0.005)
        XCTAssertEqual(lightBackground.blueComponent, expectedLightBackground.blueComponent, accuracy: 0.005)
        XCTAssertLessThan(darkBackground.redComponent, 0.3)
    }
}

import XCTest
@testable import Lineform

final class ReadingPresetTests: XCTestCase {
    func testBuiltInPresetsAreCuratedInExpectedOrder() {
        let names = ReadingPreset.builtIn.map(\.profile.name)

        XCTAssertEqual(names, [
            "Original",
            "Paper",
            "Quiet",
            "Focus",
            "Accessible",
            "Dyslexia",
            "Low Light",
            "High Contrast"
        ])
    }

    func testAccessibilityPresetsUseReadableSettings() {
        let accessible = ReadingPreset.accessible.profile
        let dyslexia = ReadingPreset.dyslexia.profile
        let highContrast = ReadingPreset.highContrast.profile

        XCTAssertEqual(accessible.themeID, .system)
        XCTAssertEqual(accessible.fontID, .atkinsonHyperlegible)
        XCTAssertGreaterThanOrEqual(accessible.lineHeightMultiple, 1.5)
        XCTAssertEqual(dyslexia.themeID, .system)
        XCTAssertEqual(dyslexia.fontID, .openDyslexic)
        XCTAssertTrue(dyslexia.readingRulerEnabled)
        XCTAssertEqual(highContrast.themeID, .system)
        XCTAssertTrue(highContrast.highContrastEnabled)
        XCTAssertGreaterThan(highContrast.insertionPointWidth, ReadingProfile.original.insertionPointWidth)
    }

    func testThemeChangesPreserveReadingSettings() {
        var profile = ReadingPreset.dyslexia.profile

        profile.applyTheme(.night)

        XCTAssertEqual(profile.themeID, .night)
        XCTAssertEqual(profile.fontID, .openDyslexic)
        XCTAssertEqual(profile.fontSize, ReadingPreset.dyslexia.profile.fontSize)
        XCTAssertTrue(profile.readingRulerEnabled)
        XCTAssertTrue(profile.reduceMotionEnabled)
    }
}

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

        XCTAssertEqual(accessible.fontID, .atkinsonHyperlegible)
        XCTAssertGreaterThanOrEqual(accessible.lineHeightMultiple, 1.5)
        XCTAssertEqual(dyslexia.fontID, .openDyslexic)
        XCTAssertTrue(dyslexia.readingRulerEnabled)
        XCTAssertTrue(highContrast.highContrastEnabled)
        XCTAssertGreaterThan(highContrast.insertionPointWidth, ReadingProfile.original.insertionPointWidth)
    }
}

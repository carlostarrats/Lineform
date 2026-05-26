import XCTest
@testable import Lineform

final class ReadingPresetTests: XCTestCase {
    func testBuiltInPresetsAreCuratedInExpectedOrder() {
        let names = ReadingPreset.builtIn.map(\.profile.name)

        XCTAssertEqual(names, [
            "Original",
            "Quiet",
            "Paper",
            "Code",
            "Calm",
            "Focus",
        ])
    }

    func testIBooksStylePresetsTuneFontsThemesAndReadingAids() {
        XCTAssertEqual(ReadingPreset.original.profile.fontID, .sfPro)
        XCTAssertEqual(ReadingPreset.original.profile.themeID, .system)
        XCTAssertFalse(ReadingPreset.original.profile.reduceMarkdownNoise)

        XCTAssertEqual(ReadingPreset.quiet.profile.fontID, .newYork)
        XCTAssertEqual(ReadingPreset.quiet.profile.themeID, .quiet)
        XCTAssertTrue(ReadingPreset.quiet.profile.reduceMarkdownNoise)

        XCTAssertEqual(ReadingPreset.paper.profile.fontID, .newYork)
        XCTAssertEqual(ReadingPreset.paper.profile.themeID, .paper)
        XCTAssertGreaterThan(ReadingPreset.paper.profile.lineHeightMultiple, ReadingPreset.quiet.profile.lineHeightMultiple)

        XCTAssertEqual(ReadingPreset.code.profile.fontID, .jetBrainsMono)
        XCTAssertEqual(ReadingPreset.code.profile.themeID, .system)
        XCTAssertLessThan(ReadingPreset.code.profile.lineHeightMultiple, ReadingPreset.calm.profile.lineHeightMultiple)

        XCTAssertEqual(ReadingPreset.calm.profile.fontID, .atkinsonHyperlegible)
        XCTAssertEqual(ReadingPreset.calm.profile.themeID, .calm)
        XCTAssertGreaterThan(ReadingPreset.calm.profile.letterSpacing, ReadingPreset.original.profile.letterSpacing)

        XCTAssertEqual(ReadingPreset.focus.profile.fontID, .atkinsonHyperlegible)
        XCTAssertEqual(ReadingPreset.focus.profile.focusMode, .off)
        XCTAssertTrue(ReadingPreset.focus.profile.readingRulerEnabled)
        XCTAssertTrue(ReadingPreset.focus.profile.reduceMarkdownNoise)
        XCTAssertTrue(ReadingPreset.focus.profile.typewriterModeEnabled)
        XCTAssertGreaterThan(ReadingPreset.focus.profile.insertionPointWidth, ReadingPreset.original.profile.insertionPointWidth)
    }

    func testThemeChangesPreserveReadingSettings() {
        var profile = ReadingPreset.focus.profile

        profile.applyTheme(.night)

        XCTAssertEqual(profile.themeID, .night)
        XCTAssertEqual(profile.fontID, .atkinsonHyperlegible)
        XCTAssertEqual(profile.fontSize, ReadingPreset.focus.profile.fontSize)
        XCTAssertTrue(profile.readingRulerEnabled)
        XCTAssertTrue(profile.typewriterModeEnabled)
    }
}

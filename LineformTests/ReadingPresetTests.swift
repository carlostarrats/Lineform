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
        XCTAssertFalse(ReadingPreset.quiet.profile.reduceMarkdownNoise)

        XCTAssertEqual(ReadingPreset.paper.profile.fontID, .newYork)
        XCTAssertEqual(ReadingPreset.paper.profile.themeID, .paper)
        XCTAssertFalse(ReadingPreset.paper.profile.reduceMarkdownNoise)

        XCTAssertEqual(ReadingPreset.code.profile.fontID, .jetBrainsMono)
        XCTAssertEqual(ReadingPreset.code.profile.themeID, .system)
        XCTAssertEqual(ReadingPreset.code.profile.letterSpacing, 0)

        XCTAssertEqual(ReadingPreset.calm.profile.fontID, .atkinsonHyperlegible)
        XCTAssertEqual(ReadingPreset.calm.profile.themeID, .calm)
        XCTAssertFalse(ReadingPreset.calm.profile.reduceMarkdownNoise)

        XCTAssertEqual(ReadingPreset.focus.profile.fontID, .atkinsonHyperlegible)
        XCTAssertEqual(ReadingPreset.focus.profile.focusMode, .off)
        XCTAssertTrue(ReadingPreset.focus.profile.readingRulerEnabled)
        XCTAssertFalse(ReadingPreset.focus.profile.reduceMarkdownNoise)
        XCTAssertTrue(ReadingPreset.focus.profile.typewriterModeEnabled)
        XCTAssertEqual(ReadingPreset.focus.profile.insertionPointWidth, ReadingPreset.original.profile.insertionPointWidth)
    }

    func testBuiltInPresetReadingValuesMatchCurrentTuning() {
        assertPreset(
            ReadingPreset.original.profile,
            fontSize: 17,
            lineHeight: 1.5,
            paragraphSpacing: 12,
            letterSpacing: 0.5,
            columnWidth: 820,
            caretWidth: 2,
            reduceMarkdownNoise: false,
            readingRuler: false,
            typewriterMode: false
        )
        assertPreset(
            ReadingPreset.quiet.profile,
            fontSize: 18,
            lineHeight: 1.5,
            paragraphSpacing: 12,
            letterSpacing: 0.5,
            columnWidth: 820,
            caretWidth: 2,
            reduceMarkdownNoise: false,
            readingRuler: false,
            typewriterMode: false
        )
        assertPreset(
            ReadingPreset.paper.profile,
            fontSize: 18,
            lineHeight: 1.5,
            paragraphSpacing: 12,
            letterSpacing: 0.5,
            columnWidth: 820,
            caretWidth: 2,
            reduceMarkdownNoise: false,
            readingRuler: false,
            typewriterMode: false
        )
        assertPreset(
            ReadingPreset.code.profile,
            fontSize: 16,
            lineHeight: 1.5,
            paragraphSpacing: 12,
            letterSpacing: 0,
            columnWidth: 820,
            caretWidth: 2,
            reduceMarkdownNoise: false,
            readingRuler: false,
            typewriterMode: false
        )
        assertPreset(
            ReadingPreset.calm.profile,
            fontSize: 18,
            lineHeight: 1.5,
            paragraphSpacing: 12,
            letterSpacing: 0.5,
            columnWidth: 820,
            caretWidth: 2,
            reduceMarkdownNoise: false,
            readingRuler: false,
            typewriterMode: false
        )
        assertPreset(
            ReadingPreset.focus.profile,
            fontSize: 18,
            lineHeight: 1.5,
            paragraphSpacing: 12,
            letterSpacing: 0.5,
            columnWidth: 820,
            caretWidth: 2,
            reduceMarkdownNoise: false,
            readingRuler: true,
            typewriterMode: true
        )
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

    private func assertPreset(
        _ profile: ReadingProfile,
        fontSize: Double,
        lineHeight: Double,
        paragraphSpacing: Double,
        letterSpacing: Double,
        columnWidth: Double,
        caretWidth: Double,
        reduceMarkdownNoise: Bool,
        readingRuler: Bool,
        typewriterMode: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(profile.fontSize, fontSize, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(profile.lineHeightMultiple, lineHeight, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(profile.paragraphSpacing, paragraphSpacing, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(profile.letterSpacing, letterSpacing, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(profile.columnWidth, columnWidth, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(profile.insertionPointWidth, caretWidth, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(profile.reduceMarkdownNoise, reduceMarkdownNoise, file: file, line: line)
        XCTAssertEqual(profile.readingRulerEnabled, readingRuler, file: file, line: line)
        XCTAssertEqual(profile.typewriterModeEnabled, typewriterMode, file: file, line: line)
    }
}

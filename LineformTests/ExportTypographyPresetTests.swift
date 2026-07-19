import XCTest
@testable import Lineform

final class ExportTypographyPresetTests: XCTestCase {
    // MARK: - Declared fields

    func testStandardIsPlainMarkdownSource() {
        let standard = ExportTypographyPreset.standard
        XCTAssertEqual(standard.id, "standard")
        XCTAssertEqual(standard.displayName, "Normal")
        XCTAssertEqual(standard.bodyFace, .system)
        XCTAssertEqual(standard.bodyPointSize, 10)
        XCTAssertEqual(standard.lineHeightMultiple, 1.2)
        XCTAssertEqual(standard.headingScale, 1.0)
        // "Normal" prints the raw markdown source and ignores the user's reading profile.
        XCTAssertFalse(standard.rendersMarkdown)
        XCTAssertFalse(standard.inheritsUserProfile)
    }

    func testStyledRendersWithUserProfile() {
        let styled = ExportTypographyPreset.styled
        XCTAssertEqual(styled.id, "styled")
        XCTAssertEqual(styled.displayName, "Styled")
        XCTAssertNil(styled.bodyFace)          // inherit the user's font face
        XCTAssertEqual(styled.bodyPointSize, 10)
        XCTAssertNil(styled.lineHeightMultiple) // inherit the user's line height
        XCTAssertEqual(styled.headingScale, 1.0)
        // "Styled" renders Read-mode style from the user's SELECTED profile.
        XCTAssertTrue(styled.rendersMarkdown)
        XCTAssertTrue(styled.inheritsUserProfile)
    }

    // MARK: - Export profile resolution

    func testStandardIgnoresUserProfileAndUsesNeutralDefaults() {
        var customized = ReadingProfile.original
        customized.themeID = .night
        customized.highContrastEnabled = true
        customized.fontID = .newYork
        customized.fontSize = 21
        customized.lineHeightMultiple = 1.7

        let profile = ExportTypographyPreset.standard.exportReadingProfile(basedOn: customized)
        // None of the user's customization survives: Normal builds from `.original`, pins the
        // light `.system` page + no high contrast, the system face, the small body size, and the
        // document line height.
        XCTAssertEqual(profile.fontID, .sfPro)
        XCTAssertEqual(profile.fontSize, 10)
        XCTAssertEqual(profile.lineHeightMultiple, 1.2)
        XCTAssertEqual(profile.themeID, .system)
        XCTAssertFalse(profile.highContrastEnabled)
        // A profile field the preset never touches follows `.original`, not the user's value.
        XCTAssertEqual(profile.letterSpacing, ReadingProfile.original.letterSpacing)
    }

    func testStyledInheritsUserFaceAndLineHeight() {
        var customized = ReadingProfile.original
        customized.themeID = .night
        customized.highContrastEnabled = true
        customized.fontID = .newYork
        customized.fontSize = 21
        customized.lineHeightMultiple = 1.7
        customized.letterSpacing = 1.5

        let profile = ExportTypographyPreset.styled.exportReadingProfile(basedOn: customized)
        // The user's face + line height + other rhythm carry through; only the page, contrast, and
        // body size are pinned for a document-style PDF.
        XCTAssertEqual(profile.fontID, .newYork)
        XCTAssertEqual(profile.lineHeightMultiple, 1.7)
        XCTAssertEqual(profile.letterSpacing, 1.5)
        XCTAssertEqual(profile.fontSize, 10)
        XCTAssertEqual(profile.themeID, .system)
        XCTAssertFalse(profile.highContrastEnabled)
    }

    // MARK: - Font faces + list + lookup

    func testExportFontFaceMapsToExistingFontIDs() {
        XCTAssertEqual(ExportFontFace.system.fontID, .sfPro)
        XCTAssertEqual(ExportFontFace.serif.fontID, .newYork)
        XCTAssertEqual(ExportFontFace.atkinson.fontID, .atkinsonHyperlegible)
        XCTAssertEqual(ExportFontFace.openDyslexic.fontID, .openDyslexic)
    }

    func testAllListsTwoPresetsStandardFirst() {
        XCTAssertEqual(ExportTypographyPreset.all.map(\.id), ["standard", "styled"])
    }

    func testPresetWithIDResolvesKnownAndFallsBackToStandard() {
        XCTAssertEqual(ExportTypographyPreset.preset(withID: "styled").id, "styled")
        XCTAssertEqual(ExportTypographyPreset.preset(withID: "bogus").id, "standard")
        XCTAssertEqual(ExportTypographyPreset.preset(withID: nil).id, "standard")
    }
}

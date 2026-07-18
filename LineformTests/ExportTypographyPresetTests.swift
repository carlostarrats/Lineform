import XCTest
@testable import Lineform

final class ExportTypographyPresetTests: XCTestCase {
    func testStandardExportProfileEqualsCurrentFixedExportProfile() {
        let original = ReadingProfile.original
        XCTAssertEqual(
            ExportTypographyPreset.standard.exportReadingProfile(basedOn: original),
            DocumentExportRenderer.exportProfile(from: original)
        )

        var customized = ReadingProfile.original
        customized.themeID = .night
        customized.highContrastEnabled = true
        customized.fontID = .newYork
        customized.fontSize = 21
        customized.lineHeightMultiple = 1.7
        customized.letterSpacing = 1.5
        customized.paragraphSpacing = 13
        XCTAssertEqual(
            ExportTypographyPreset.standard.exportReadingProfile(basedOn: customized),
            DocumentExportRenderer.exportProfile(from: customized)
        )
    }

    func testEachPresetYieldsItsDeclaredFields() {
        let manuscript = ExportTypographyPreset.manuscript
        XCTAssertEqual(manuscript.bodyFace, .serif)
        XCTAssertEqual(manuscript.bodyPointSize, 12)
        XCTAssertEqual(manuscript.lineHeightMultiple, 2.0)
        XCTAssertEqual(manuscript.headingScale, 1.0)
        XCTAssertEqual(manuscript.pageMargins.left, 90)

        let compact = ExportTypographyPreset.compact
        XCTAssertEqual(compact.bodyFace, .system)
        XCTAssertEqual(compact.bodyPointSize, 10)
        XCTAssertEqual(compact.lineHeightMultiple, 1.2)
        XCTAssertEqual(compact.headingScale, 0.85)
        XCTAssertEqual(compact.pageMargins.top, 54)

        let article = ExportTypographyPreset.article
        XCTAssertEqual(article.bodyFace, .serif)
        XCTAssertEqual(article.headingScale, 1.25)
        XCTAssertEqual(article.bodyPointSize, 12)
    }

    func testExportReadingProfileAppliesFaceSizeAndLineHeightFromPreset() {
        let profile = ExportTypographyPreset.manuscript.exportReadingProfile(basedOn: .original)
        XCTAssertEqual(profile.fontID, .newYork)
        XCTAssertEqual(profile.fontSize, 12)
        XCTAssertEqual(profile.lineHeightMultiple, 2.0)
        XCTAssertEqual(profile.themeID, .system)
        XCTAssertEqual(profile.highContrastEnabled, false)
    }

    func testExportFontFaceMapsToExistingFontIDs() {
        XCTAssertEqual(ExportFontFace.system.fontID, .sfPro)
        XCTAssertEqual(ExportFontFace.serif.fontID, .newYork)
        XCTAssertEqual(ExportFontFace.atkinson.fontID, .atkinsonHyperlegible)
        XCTAssertEqual(ExportFontFace.openDyslexic.fontID, .openDyslexic)
    }

    func testAllListsFourPresetsStandardFirst() {
        XCTAssertEqual(ExportTypographyPreset.all.map(\.id), ["standard", "manuscript", "compact", "article"])
    }

    func testPresetWithIDResolvesKnownAndFallsBackToStandard() {
        XCTAssertEqual(ExportTypographyPreset.preset(withID: "compact").id, "compact")
        XCTAssertEqual(ExportTypographyPreset.preset(withID: "bogus").id, "standard")
        XCTAssertEqual(ExportTypographyPreset.preset(withID: nil).id, "standard")
    }
}

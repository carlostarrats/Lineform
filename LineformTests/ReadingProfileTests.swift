import XCTest
@testable import Lineform

final class ReadingProfileTests: XCTestCase {
    func testOriginalPresetUsesReadableDefaults() {
        let profile = ReadingProfile.original

        XCTAssertEqual(profile.name, "Original")
        XCTAssertGreaterThanOrEqual(profile.fontSize, 16)
        XCTAssertGreaterThan(profile.lineHeightMultiple, 1)
        XCTAssertEqual(profile.columnWidth, 820)
    }

    func testReadingProfileCodableRoundTripPreservesValues() throws {
        let profile = ReadingProfile.original
        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ReadingProfile.self, from: encoded)

        XCTAssertEqual(decoded, profile)
    }

    func testLegacyLowLightThemeDecodesAsNight() throws {
        let json = """
        {
          "id": "1C7B19CC-A1ED-4828-8F77-94B6769F7260",
          "name": "Legacy Low Light",
          "fontID": "sfPro",
          "themeID": "lowLight",
          "fontSize": 18,
          "lineHeightMultiple": 1.45,
          "paragraphSpacing": 10,
          "letterSpacing": 0,
          "columnWidth": 680,
          "marginWidth": 52,
          "insertionPointWidth": 2,
          "focusMode": "off",
          "typewriterModeEnabled": false,
          "readingRulerEnabled": false,
          "reduceMarkdownNoise": true,
          "highContrastEnabled": false,
          "reduceMotionEnabled": false,
          "adaptiveReadabilityEnabled": false
        }
        """

        let profile = try JSONDecoder().decode(ReadingProfile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.themeID, .night)
        XCTAssertEqual(profile.name, "Legacy Low Light")
        XCTAssertEqual(profile.fontSize, 18)
    }

    func testLegacyAccessibilityThemeDecodesAsOriginalTheme() throws {
        let json = """
        {
          "id": "3BE5704B-B4DC-468B-A1B1-28031C046946",
          "name": "Legacy Dyslexia",
          "fontID": "openDyslexic",
          "themeID": "dyslexia",
          "fontSize": 19,
          "lineHeightMultiple": 1.6,
          "paragraphSpacing": 14,
          "letterSpacing": 0.25,
          "columnWidth": 740,
          "marginWidth": 64,
          "insertionPointWidth": 2,
          "focusMode": "currentLine",
          "typewriterModeEnabled": false,
          "readingRulerEnabled": true,
          "reduceMarkdownNoise": true,
          "highContrastEnabled": false,
          "reduceMotionEnabled": true,
          "adaptiveReadabilityEnabled": false
        }
        """

        let profile = try JSONDecoder().decode(ReadingProfile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.themeID, .system)
        XCTAssertEqual(profile.fontID, .openDyslexic)
        XCTAssertTrue(profile.readingRulerEnabled)
    }
}

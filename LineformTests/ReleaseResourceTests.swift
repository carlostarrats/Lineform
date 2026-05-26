import XCTest
@testable import Lineform

final class ReleaseResourceTests: XCTestCase {
    func testReleaseMarkdownResourcesAreBundled() throws {
        for resource in ["MarkdownGuide", "Help", "Privacy", "AccessibilityNutritionLabel"] {
            XCTAssertNotNil(Bundle.main.url(forResource: resource, withExtension: "md"), "\(resource).md should be bundled.")
        }

        for resource in ["FontLicenseReview", "AppStoreMetadata", "ReleaseReadiness"] {
            XCTAssertNil(Bundle.main.url(forResource: resource, withExtension: "md"), "\(resource).md is an internal release artifact and should not be bundled.")
        }
    }

    func testMarkdownGuideDocumentsRealMarkdownEditing() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "MarkdownGuide", withExtension: "md"))
        let guide = try String(contentsOf: url)

        XCTAssertTrue(guide.contains("real Markdown files"))
        XCTAssertTrue(guide.contains("# Heading"))
    }

    func testBundledFontLicensesShipWithBundledFonts() {
        for resource in ["OFL-AtkinsonHyperlegible", "OFL-OpenDyslexic"] {
            XCTAssertNotNil(
                Bundle.main.url(forResource: resource, withExtension: "txt", subdirectory: "Fonts"),
                "\(resource).txt should ship with bundled fonts."
            )
        }

        XCTAssertNil(Bundle.main.url(forResource: "OFL-Lexend", withExtension: "txt", subdirectory: "Fonts"))
    }
}

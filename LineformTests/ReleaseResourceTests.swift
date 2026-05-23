import XCTest
@testable import Lineform

final class ReleaseResourceTests: XCTestCase {
    func testReleaseMarkdownResourcesAreBundled() throws {
        for resource in ["MarkdownGuide", "Help", "Privacy", "FontLicenseReview", "AppStoreMetadata", "AccessibilityNutritionLabel", "ReleaseReadiness"] {
            XCTAssertNotNil(Bundle.main.url(forResource: resource, withExtension: "md"), "\(resource).md should be bundled.")
        }
    }

    func testMarkdownGuideDocumentsRealMarkdownEditing() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "MarkdownGuide", withExtension: "md"))
        let guide = try String(contentsOf: url)

        XCTAssertTrue(guide.contains("real Markdown files"))
        XCTAssertTrue(guide.contains("# Heading"))
    }
}

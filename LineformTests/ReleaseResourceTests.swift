import XCTest
import Security
@testable import Lineform

final class ReleaseResourceTests: XCTestCase {
    func testAppEntitlementsStayLocalFirst() throws {
        var staticCode: SecStaticCode?
        XCTAssertEqual(
            SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode),
            errSecSuccess
        )
        let appCode = try XCTUnwrap(staticCode)

        var signingInformation: CFDictionary?
        XCTAssertEqual(
            SecCodeCopySigningInformation(
                appCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInformation
            ),
            errSecSuccess
        )
        let signingInfo = try XCTUnwrap(signingInformation as? [String: Any])
        let entitlements = try XCTUnwrap(
            signingInfo[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        )

        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.files.user-selected.read-write"] as? Bool, true)
        XCTAssertNil(entitlements["com.apple.security.network.client"])
    }

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
        let guide = try String(contentsOf: url, encoding: .utf8)

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

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
        // WKWebView needs this for its helper processes even when rendering bundled intro files.
        XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, true)
    }

    func testReleaseMarkdownResourcesAreBundled() throws {
        for resource in ["MarkdownGuide", "Help", "Privacy", "AccessibilityNutritionLabel"] {
            XCTAssertNotNil(Bundle.main.url(forResource: resource, withExtension: "md"), "\(resource).md should be bundled.")
        }

        for resource in ["FontLicenseReview", "AppStoreMetadata", "ReleaseReadiness"] {
            XCTAssertNil(Bundle.main.url(forResource: resource, withExtension: "md"), "\(resource).md is an internal release artifact and should not be bundled.")
        }
    }

    func testAboutPanelMetadataUsesCarlosCopyrightAndAppIcon() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)

        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(info["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "1.0")
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://raw.githubusercontent.com/carlostarrats/Lineform/main/docs/appcast.xml")
        XCTAssertNotNil(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(
            info["NSHumanReadableCopyright"] as? String,
            AppMenuConfiguration.aboutCopyright
        )
        XCTAssertNotNil(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
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

    @MainActor
    func testFirstPublicReleaseMigrationClearsLegacyTestingState() {
        let suiteName = "LineformFirstPublicReleaseMigrationTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: LineformLaunchDefaults.legacyFirstLaunchIntroCompletedKey)
        defaults.set(Data([0x01]), forKey: "Lineform.outline.workspaceBookmark")
        defaults.set(Data([0x02]), forKey: "Lineform.outline.workspaceSnapshot")
        var recentDocumentsClearCount = 0

        let didMigrate = LineformLaunchDefaults.migrateFirstPublicReleaseDefaultsIfNeeded(defaults: defaults) {
            recentDocumentsClearCount += 1
        }

        XCTAssertTrue(didMigrate)
        XCTAssertNil(defaults.object(forKey: LineformLaunchDefaults.legacyFirstLaunchIntroCompletedKey))
        XCTAssertNil(defaults.object(forKey: "Lineform.outline.workspaceBookmark"))
        XCTAssertNil(defaults.object(forKey: "Lineform.outline.workspaceSnapshot"))
        XCTAssertTrue(defaults.bool(forKey: LineformLaunchDefaults.firstPublicReleaseDefaultsInitializedKey))
        XCTAssertEqual(recentDocumentsClearCount, 1)
    }

    @MainActor
    func testFirstPublicReleaseMigrationIsIdempotentAfterMarkerIsSet() {
        let suiteName = "LineformFirstPublicReleaseMigrationIdempotentTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: LineformLaunchDefaults.firstPublicReleaseDefaultsInitializedKey)
        defaults.set(Data([0x01]), forKey: "Lineform.outline.workspaceBookmark")
        var recentDocumentsClearCount = 0

        let didMigrate = LineformLaunchDefaults.migrateFirstPublicReleaseDefaultsIfNeeded(defaults: defaults) {
            recentDocumentsClearCount += 1
        }

        XCTAssertFalse(didMigrate)
        XCTAssertNotNil(defaults.object(forKey: "Lineform.outline.workspaceBookmark"))
        XCTAssertEqual(recentDocumentsClearCount, 0)
    }

    @MainActor
    func testFirstLaunchIntroCompletionIgnoresLegacyDebugKey() {
        let suiteName = "LineformFirstLaunchIntroCompletionTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: LineformLaunchDefaults.legacyFirstLaunchIntroCompletedKey)

        XCTAssertFalse(LineformLaunchDefaults.hasCompletedFirstLaunchIntro(defaults: defaults))

        LineformLaunchDefaults.markFirstLaunchIntroCompleted(defaults: defaults)

        XCTAssertTrue(LineformLaunchDefaults.hasCompletedFirstLaunchIntro(defaults: defaults))
    }

    func testDebugAndReleaseBuildsUseSeparateDefaultsDomains() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Lineform.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lineform.app.debug;"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lineform.app;"))
    }
}

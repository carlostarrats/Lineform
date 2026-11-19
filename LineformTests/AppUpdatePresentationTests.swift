import XCTest
@testable import Lineform

/// The alert text for each Check for Updates outcome. Runs under the default test plan's
/// `en`/`US`; the per-language test resolves through each `.lproj` so a key that drifted
/// from the catalog (e.g. a positional specifier lost to Swift interpolation) fails here
/// instead of silently shipping English.
final class AppUpdatePresentationTests: XCTestCase {
    private static let languages = ["es", "fr", "de", "ja", "zh-Hans"]
    private static let storeURL = URL(string: "https://apps.apple.com/app/lineform/id6738270430")!

    private func bundle(_ language: String) throws -> Bundle {
        try XCTUnwrap(
            Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
            "\(language).lproj missing from the test host"
        )
    }

    func testUpToDate() {
        let presentation = AppUpdatePresentation(result: .upToDate(current: "1.8.0"))
        XCTAssertEqual(presentation.title, "Lineform is up to date")
        XCTAssertEqual(presentation.message, "Version 1.8.0 is the latest version.")
        XCTAssertEqual(presentation.primaryButton, "OK")
        XCTAssertNil(presentation.secondaryButton)
        XCTAssertNil(presentation.storeURL)
    }

    func testUpdateAvailable() {
        let presentation = AppUpdatePresentation(
            result: .updateAvailable(current: "1.8.0", latest: "1.9.0", storeURL: Self.storeURL))
        XCTAssertEqual(presentation.title, "A new version of Lineform is available")
        XCTAssertEqual(presentation.message, "Version 1.9.0 is on the App Store. You have version 1.8.0.")
        XCTAssertEqual(presentation.primaryButton, "Open App Store")
        XCTAssertEqual(presentation.secondaryButton, "Not Now")
        XCTAssertEqual(presentation.storeURL, Self.storeURL)
    }

    func testFailed() {
        let presentation = AppUpdatePresentation(result: .failed)
        XCTAssertEqual(presentation.title, "Couldn't check for updates")
        XCTAssertEqual(presentation.message, "Check your internet connection and try again.")
        XCTAssertEqual(presentation.primaryButton, "OK")
        XCTAssertNil(presentation.secondaryButton)
        XCTAssertNil(presentation.storeURL)
    }

    /// Every string resolves to a real translation (not the English fallback), keeps both
    /// version numbers, and never leaks a raw format specifier.
    func testEveryLanguageResolvesTheCatalogKeys() throws {
        let english = [
            AppUpdatePresentation(result: .upToDate(current: "1.8.0")),
            AppUpdatePresentation(
                result: .updateAvailable(current: "1.8.0", latest: "1.9.0", storeURL: Self.storeURL)),
            AppUpdatePresentation(result: .failed),
        ]
        for language in Self.languages {
            let bundle = try bundle(language)
            let localized = [
                AppUpdatePresentation(result: .upToDate(current: "1.8.0"), bundle: bundle),
                AppUpdatePresentation(
                    result: .updateAvailable(current: "1.8.0", latest: "1.9.0", storeURL: Self.storeURL),
                    bundle: bundle),
                AppUpdatePresentation(result: .failed, bundle: bundle),
            ]
            for (en, loc) in zip(english, localized) {
                XCTAssertNotEqual(loc.title, en.title, "\(language): title untranslated")
                XCTAssertNotEqual(loc.message, en.message, "\(language): message untranslated")
                XCTAssertFalse(loc.message.contains("%"), "\(language): raw specifier in '\(loc.message)'")
                XCTAssertEqual(loc.storeURL, en.storeURL)
                XCTAssertEqual(loc.secondaryButton == nil, en.secondaryButton == nil)
            }
            XCTAssertTrue(localized[0].message.contains("1.8.0"), "\(language): \(localized[0].message)")
            XCTAssertTrue(localized[1].message.contains("1.9.0"), "\(language): \(localized[1].message)")
            XCTAssertTrue(localized[1].message.contains("1.8.0"), "\(language): \(localized[1].message)")
            XCTAssertTrue(localized[1].message.contains("App Store"), "\(language): \(localized[1].message)")
            XCTAssertTrue(localized[1].primaryButton.contains("App Store"), "\(language): \(localized[1].primaryButton)")
            XCTAssertNotEqual(localized[1].secondaryButton, "Not Now", "\(language): Not Now untranslated")
        }
    }
}

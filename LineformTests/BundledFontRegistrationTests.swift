import XCTest
@testable import LineformCore

/// `FontOption` lives in LineformCore, but the bundled reader fonts ship in the APP bundle and
/// are registered process-wide at launch. These tests run in the app host, where
/// `BundledFontRegistrar.registerFonts()` finds the app's `Fonts` folder, so they prove the
/// package type still sees fonts the app registers.
final class BundledFontRegistrationTests: XCTestCase {
    func testVisibleFontOptionsResolveWithoutSilentSystemFallback() {
        BundledFontRegistrar.registerFonts()
        let visibleOptions = FontOption.availableGroupedOptions.flatMap(\.options)

        XCTAssertFalse(visibleOptions.isEmpty)
        XCTAssertTrue(visibleOptions.contains { $0.id == .sfPro })
        XCTAssertTrue(visibleOptions.contains { $0.id == .newYork })
        XCTAssertTrue(visibleOptions.contains { $0.id == .jetBrainsMono })

        for option in visibleOptions {
            XCTAssertNotNil(option.availableFont(size: 17), "\(option.name) should only be visible when AppKit can resolve it")
        }
    }

    func testBundledReaderFontsResolveAfterRegistration() throws {
        BundledFontRegistrar.registerFonts()

        XCTAssertNotNil(try XCTUnwrap(FontOption.option(for: .atkinsonHyperlegible)).availableFont(size: 17))
        XCTAssertNotNil(try XCTUnwrap(FontOption.option(for: .openDyslexic)).availableFont(size: 17))
    }

    /// Review focus 4: a reader who chose Atkinson Hyperlegible before the upgrade must still get
    /// it, now that `FontOption` resolves fonts from inside the package.
    func testBundledFontsResolveAfterRegistration() {
        BundledFontRegistrar.registerFonts()

        XCTAssertEqual(FontOption.option(for: .atkinsonHyperlegible)?.isAvailable, true)
    }
}

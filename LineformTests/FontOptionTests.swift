import XCTest
@testable import Lineform

final class FontOptionTests: XCTestCase {
    func testFontOptionsAreGroupedForShortIntentionalPicker() {
        let groups = FontOption.groupedOptions.map(\.name)

        XCTAssertEqual(groups, ["System", "Writing", "Reading & Accessibility"])
        XCTAssertEqual(
            FontOption.groupedOptions.flatMap(\.options).map(\.id),
            [.sfPro, .newYork, .jetBrainsMono, .atkinsonHyperlegible, .openDyslexic, .comicSans]
        )
        XCTAssertFalse(FontOption.groupedOptions.flatMap(\.options).contains { $0.id == .lexend })
    }

    func testAppleFontsAreSystemSourcedNotBundled() throws {
        let sfPro = try XCTUnwrap(FontOption.option(for: .sfPro))
        let newYork = try XCTUnwrap(FontOption.option(for: .newYork))

        XCTAssertEqual(sfPro.source, .system)
        XCTAssertEqual(newYork.source, .system)
    }

    func testOpenFontLicenseFontsAreBundled() throws {
        let atkinson = try XCTUnwrap(FontOption.option(for: .atkinsonHyperlegible))
        let openDyslexic = try XCTUnwrap(FontOption.option(for: .openDyslexic))

        XCTAssertEqual(atkinson.source, .bundled)
        XCTAssertEqual(openDyslexic.source, .bundled)
    }

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

    func testNewYorkResolvesThroughSystemSerifDesign() throws {
        let newYork = try XCTUnwrap(FontOption.option(for: .newYork))

        let font = try XCTUnwrap(newYork.availableFont(size: 17))

        XCTAssertTrue(font.fontName.contains("NewYork"))
    }
}

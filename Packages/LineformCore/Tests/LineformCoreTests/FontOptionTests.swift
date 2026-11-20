import XCTest
@testable import LineformCore

final class FontOptionTests: XCTestCase {
    func testFontOptionsAreGroupedForShortIntentionalPicker() {
        let groups = FontOption.groupedOptions.map(\.name)

        XCTAssertEqual(groups, [
            String(localized: "System", bundle: .lineformCore),
            String(localized: "Reading & Accessibility", bundle: .lineformCore),
        ])
        XCTAssertEqual(
            FontOption.groupedOptions.flatMap(\.options).map(\.id),
            [.sfPro, .newYork, .jetBrainsMono, .atkinsonHyperlegible, .openDyslexic, .comicSans]
        )
        XCTAssertFalse(FontOption.groupedOptions.flatMap(\.options).contains { $0.id == .lexend })
    }

    func testMonospacedIsInTheSystemGroupAndThereIsNoWritingGroup() {
        let groups = FontOption.groupedOptions
        XCTAssertEqual(groups.map(\.name), [
            String(localized: "System", bundle: .lineformCore),
            String(localized: "Reading & Accessibility", bundle: .lineformCore),
        ])
        XCTAssertEqual(groups[0].options.map(\.id), [.sfPro, .newYork, .jetBrainsMono])
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

    func testNewYorkResolvesThroughSystemSerifDesign() throws {
        let newYork = try XCTUnwrap(FontOption.option(for: .newYork))

        let font = try XCTUnwrap(newYork.availableFont(size: 17))

        XCTAssertTrue(font.fontName.contains("NewYork"))
    }
}

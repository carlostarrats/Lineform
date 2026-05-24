import XCTest
@testable import Lineform

final class FontOptionTests: XCTestCase {
    func testFontOptionsAreGroupedForShortIntentionalPicker() {
        let groups = FontOption.groupedOptions.map(\.name)

        XCTAssertEqual(groups, ["System", "Writing", "Reading & Accessibility"])
        XCTAssertEqual(FontOption.groupedOptions.flatMap(\.options).map(\.id), FontID.allCases)
    }

    func testAppleFontsAreSystemSourcedNotBundled() throws {
        let sfPro = try XCTUnwrap(FontOption.option(for: .sfPro))
        let newYork = try XCTUnwrap(FontOption.option(for: .newYork))

        XCTAssertEqual(sfPro.source, .system)
        XCTAssertEqual(newYork.source, .system)
    }

    func testFontsAreNotClaimedAsBundledWithoutBundledFiles() {
        XCTAssertFalse(FontOption.groupedOptions.flatMap(\.options).contains { $0.source == .bundled })
    }
}

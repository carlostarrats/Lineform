import AppKit
import XCTest
@testable import Lineform

final class ThemeTests: XCTestCase {
    func testBuiltInThemesHaveDistinctForegroundAndBackgroundColors() {
        for theme in Theme.builtIn {
            XCTAssertNotEqual(theme.textColor, theme.backgroundColor, theme.name)
        }
    }

    func testReaderThemesStaySmallAndAppleBooksStyle() {
        XCTAssertEqual(Theme.readerThemes.map(\.id), [.system, .paper, .quiet, .night])
        XCTAssertEqual(Theme.readerThemes.map(\.name), ["Original", "Paper", "Quiet", "Night"])
    }

    func testThemeIDsOnlyRepresentNormalReaderThemes() {
        XCTAssertEqual(ThemeID.allCases, [.system, .paper, .quiet, .night])
    }

    func testHighContrastProfileResolvesToHighContrastThemeColors() {
        let theme = Theme.theme(for: ReadingPreset.highContrast.profile)

        XCTAssertEqual(theme.textColor, .textColor)
        XCTAssertEqual(theme.backgroundColor, .textBackgroundColor)
        XCTAssertEqual(theme.caretColor, .textColor)
    }
}

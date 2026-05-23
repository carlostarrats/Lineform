import AppKit
import XCTest
@testable import Lineform

final class ThemeTests: XCTestCase {
    func testBuiltInThemesHaveDistinctForegroundAndBackgroundColors() {
        for theme in Theme.builtIn {
            XCTAssertNotEqual(theme.textColor, theme.backgroundColor, theme.name)
        }
    }

    func testHighContrastThemeUsesStrongCaret() {
        let theme = Theme.highContrast

        XCTAssertEqual(theme.id, .highContrast)
        XCTAssertEqual(theme.caretColor, theme.textColor)
    }
}

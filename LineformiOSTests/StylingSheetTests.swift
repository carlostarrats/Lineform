import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The "Aa" button and the Styling sheet's presentation: the Menu button's size, the Mac's label,
/// the detents and corner radius, and a colour scheme taken from the theme, never the system.
@MainActor
final class StylingSheetTests: XCTestCase {
    func testStylingButtonLabelIsReadingExperience() {
        XCTAssertEqual(StylingButton.accessibilityLabel, String(localized: "Reading Experience"))
        XCTAssertEqual(StylingButton.accessibilityLabel, "Reading Experience")
        XCTAssertNotNil(UIImage(systemName: StylingButton.symbolName))
    }

    func testStylingButtonMatchesMenuButtonDiameter() {
        XCTAssertEqual(StylingButton.diameter, 44)
        XCTAssertEqual(StylingButton.diameter, MenuButton.diameter)
    }

    func testStylingButtonSitsInTheBottomRowClearOfTheNoticeAndReadClearance() {
        // The Aa button shares the Menu button's row (same height), so the notice, placed above a
        // Menu-button-high row, and the Read view's bottom clearance stay clear of it too.
        XCTAssertLessThanOrEqual(StylingButton.diameter, MenuButton.diameter)
        XCTAssertGreaterThanOrEqual(
            DocumentScreen.bottomChromeClearance,
            MarkdownEditor.chromeMargin + StylingButton.diameter
        )
    }

    func testSheetDetentsAreMediumAndLarge() {
        XCTAssertEqual(StylingSheet.detents, [.medium, .large])
    }

    func testSheetCornerRadiusIsModal() {
        XCTAssertEqual(StylingSheet.cornerRadius, 20)
        XCTAssertEqual(StylingSheet.cornerRadius, LineformDesign.Radius.modal)
    }

    func testSheetColorSchemeFollowsTheme() {
        // A pure function of the theme: there is no trait collection to consult, so the sheet is
        // dark for Quiet and light for Original whatever the system appearance is.
        XCTAssertEqual(StylingSheet.colorScheme(for: .quiet), .dark)
        XCTAssertEqual(StylingSheet.colorScheme(for: .night), .dark)
        XCTAssertEqual(StylingSheet.colorScheme(for: .system), .light)
        XCTAssertEqual(StylingSheet.colorScheme(for: .paper), .light)
    }

    func testSheetHeaderIsReading() {
        XCTAssertEqual(StylingSheet.headerTitle, "Reading")
        XCTAssertEqual(StylingSheet.headerTitleFontSize, 15)
    }
}

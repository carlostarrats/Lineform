import XCTest
@testable import LineformCore

final class ReadingExperienceControlsTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")

    func testRangesMatchTheDesktopPanel() {
        XCTAssertEqual(ReadingExperienceControls.fontSizeRange, 12...48)
        XCTAssertEqual(ReadingExperienceControls.lineHeightRange, 0.5...1.8)
        XCTAssertEqual(ReadingExperienceControls.blockSpacingRange, 0...24)
        XCTAssertEqual(ReadingExperienceControls.letterSpacingRange, 0...1.2)
        XCTAssertEqual(ReadingExperienceControls.columnWidthRange, 460...1200)
        XCTAssertEqual(
            ReadingExperienceControls.columnWidthRange,
            ReadingProfile.columnWidthMinimum...ReadingProfile.columnWidthMaximum
        )
    }

    func testValueTextWording() {
        var profile = ReadingPreset.paper.profile
        profile.fontSize = 17
        profile.lineHeightMultiple = 1.5
        profile.columnWidth = 820
        profile.paragraphSpacing = 12
        profile.letterSpacing = 0.5

        func text(_ keyPath: KeyPath<ReadingProfile, Double>, _ profile: ReadingProfile) -> String {
            ReadingExperienceControls.valueText(for: keyPath, in: profile, locale: enUS)
        }

        XCTAssertEqual(text(\.fontSize, profile), "17 pt")
        XCTAssertEqual(text(\.lineHeightMultiple, profile), "1.5")
        XCTAssertEqual(text(\.columnWidth, profile), "820 px")
        XCTAssertEqual(text(\.paragraphSpacing, profile), "12 px")
        XCTAssertEqual(text(\.letterSpacing, profile), "0.5")

        profile.columnWidth = 1160
        XCTAssertEqual(text(\.columnWidth, profile), "Full")
    }

    func testDecimalTextDropsTrailingZeros() {
        XCTAssertEqual(ReadingExperienceControls.decimalText(1.0, maximumFractionDigits: 2, locale: enUS), "1")
        XCTAssertEqual(ReadingExperienceControls.decimalText(1.456, maximumFractionDigits: 2, locale: enUS), "1.46")
    }

    func testClampedStaysInsideRange() {
        XCTAssertEqual(ReadingExperienceControls.clamped(60, to: 12...48), 48)
        XCTAssertEqual(ReadingExperienceControls.clamped(4, to: 12...48), 12)
        XCTAssertEqual(ReadingExperienceControls.clamped(20, to: 12...48), 20)
    }

    func testVisibleFontIDFallsBackForRetiredFont() {
        var profile = ReadingPreset.paper.profile
        profile.fontID = .lexend
        XCTAssertEqual(ReadingExperienceControls.visibleFontID(for: profile), FontOption.defaultOption.id)
    }

    func testVisibleFontIDKeepsAvailableFont() {
        var profile = ReadingPreset.paper.profile
        profile.fontID = .newYork
        XCTAssertEqual(ReadingExperienceControls.visibleFontID(for: profile), .newYork)
    }
}

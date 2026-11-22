import XCTest
@testable import LineformCore

/// Moved with `EditorReadingLayout` from the Mac app's `EditorDisplayModeTests`.
final class EditorReadingLayoutTests: XCTestCase {
    func testReadModeUsesSameTextColumnWidthAsWriteMode() {
        var profile = ReadingProfile.original
        profile.columnWidth = 680
        profile.marginWidth = 48

        XCTAssertEqual(EditorReadingLayout.textColumnMaxWidth(for: profile), 680)
    }

    func testReadAndWriteModesUseSameHorizontalInsetForSameWidth() {
        var profile = ReadingProfile.original
        profile.columnWidth = 820
        profile.marginWidth = 40

        XCTAssertEqual(EditorReadingLayout.horizontalInset(forContainerWidth: 1_200, profile: profile), 190)
        XCTAssertEqual(EditorReadingLayout.horizontalInset(forContainerWidth: 700, profile: profile), 40)
    }

    func testFullWidthColumnFillsToMarginsRegardlessOfWindowSize() {
        var profile = ReadingProfile.original
        profile.columnWidth = ReadingProfile.columnWidthMaximum // "Full"
        profile.marginWidth = 40

        XCTAssertTrue(ReadingProfile.isFullWidthColumn(profile.columnWidth))
        // The column is unbounded, so the inset clamps to the margin at any window size.
        XCTAssertEqual(EditorReadingLayout.horizontalInset(forContainerWidth: 900, profile: profile), 40)
        XCTAssertEqual(EditorReadingLayout.horizontalInset(forContainerWidth: 3_000, profile: profile), 40)
        // Text fills the window minus both margins.
        XCTAssertEqual(EditorReadingLayout.textContainerWidth(forContainerWidth: 3_000, profile: profile), 2_920)
    }

    func testFixedColumnWidthStillCentersOnWideWindows() {
        var profile = ReadingProfile.original
        profile.columnWidth = 820 // below the Full threshold
        profile.marginWidth = 40

        XCTAssertFalse(ReadingProfile.isFullWidthColumn(profile.columnWidth))
        // A fixed column centers with growing margins on a wide window (unchanged behavior).
        XCTAssertEqual(EditorReadingLayout.horizontalInset(forContainerWidth: 3_000, profile: profile), 1_090)
    }
}

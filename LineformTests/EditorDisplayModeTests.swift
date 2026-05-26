import XCTest
@testable import Lineform

final class EditorDisplayModeTests: XCTestCase {
    func testDisplayModesStaySmallAndOrdered() {
        XCTAssertEqual(EditorDisplayMode.allCases, [.write, .read, .split])
        XCTAssertEqual(EditorDisplayMode.allCases.map(\.title), ["Write", "Read", "Preview"])
    }

    @MainActor
    func testReadModeHidesStatusBarForCleanReading() {
        XCTAssertTrue(EditorStatusBar.isVisible(in: .write))
        XCTAssertFalse(EditorStatusBar.isVisible(in: .read))
        XCTAssertTrue(EditorStatusBar.isVisible(in: .split))
    }

    func testMarkdownBasicsHelpShowsOnlyInWritingModes() {
        XCTAssertTrue(EditorToolbarVisibility.showsMarkdownBasics(in: .write))
        XCTAssertFalse(EditorToolbarVisibility.showsMarkdownBasics(in: .read))
        XCTAssertTrue(EditorToolbarVisibility.showsMarkdownBasics(in: .split))
    }

    func testMarkdownBasicsExamplesCoverCommonFormatting() {
        XCTAssertEqual(MarkdownBasicsPopover.title, "Markdown Basics")
        XCTAssertEqual(
            MarkdownBasicsPopover.examples.map(\.syntax),
            ["# Title", "## Section", "**bold**", "_italic_", "- bullet", "`code`", "[link](https://example.com)"]
        )
    }

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

    func testStatusBarFormatsCountsWithEmDash() {
        XCTAssertEqual(
            EditorStatusFormatter.statisticsText(wordCount: 304, characterCount: 2345),
            "304 words — 2345 characters"
        )

        XCTAssertEqual(
            EditorStatusFormatter.statusText(
                wordCount: 304,
                characterCount: 2345,
                isPreparingSuggestion: true,
                intelligentEditingStatus: nil
            ),
            "Preparing suggestion — 304 words — 2345 characters"
        )
    }

    func testStatusBarFormatsLastSavedTimeAndDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let now = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 26,
            hour: 10,
            minute: 30
        ).date)
        let today = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 26,
            hour: 9,
            minute: 5
        ).date)
        let earlierDate = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 25,
            hour: 14,
            minute: 6
        ).date)

        XCTAssertEqual(EditorStatusFormatter.lastSavedText(for: nil, now: now, calendar: calendar), "Not saved yet")
        XCTAssertEqual(EditorStatusFormatter.lastSavedText(for: today, now: now, calendar: calendar), "Last save 9:05 AM")
        XCTAssertEqual(EditorStatusFormatter.lastSavedText(for: earlierDate, now: now, calendar: calendar), "Last save May 25, 2026 at 2:06 PM")

        XCTAssertEqual(
            EditorStatusFormatter.lastSavedDisplay(for: today, now: now, calendar: calendar),
            EditorStatusFormatter.LastSavedDisplay(label: "Last save", detail: "9:05 AM")
        )
        XCTAssertEqual(
            EditorStatusFormatter.lastSavedDisplay(for: earlierDate, now: now, calendar: calendar),
            EditorStatusFormatter.LastSavedDisplay(label: "Last save", detail: "May 25, 2026 at 2:06 PM")
        )
    }

    @MainActor
    func testStatusBarDoesNotDrawTopSeparator() {
        XCTAssertFalse(EditorStatusBar.showsTopSeparator)
        XCTAssertTrue(EditorStatusBar.lastSavedDetailUsesPrimaryForeground)
    }

    @MainActor
    func testModeSegmentUsesFixedNeutralSelectionMetrics() {
        XCTAssertEqual(EditorModeSegmentedControl.segmentWidth, 78)
        XCTAssertEqual(EditorModeSegmentedControl.segmentHeight, 30)
        XCTAssertEqual(EditorModeSegmentedControl.selectedFillRedComponent, 0.86, accuracy: 0.01)
        XCTAssertEqual(EditorModeSegmentedControl.backgroundFillRedComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(EditorModeSegmentedControl.shadowRadius, 5)
        XCTAssertEqual(EditorModeSegmentedControl.hitAreaWidth, EditorModeSegmentedControl.segmentWidth)
        XCTAssertEqual(EditorModeSegmentedControl.hitAreaHeight, EditorModeSegmentedControl.segmentHeight)
    }

    @MainActor
    func testModeSegmentLiquidBridgeSpansBetweenStates() {
        let writeOffset = EditorModeSegmentedControl.segmentOffset(for: .write)
        let readOffset = EditorModeSegmentedControl.segmentOffset(for: .read)
        let splitOffset = EditorModeSegmentedControl.segmentOffset(for: .split)

        XCTAssertEqual(EditorModeSegmentedControl.liquidPillOffset(from: .write, to: .split), writeOffset)
        XCTAssertEqual(
            EditorModeSegmentedControl.liquidPillWidth(from: .write, to: .split),
            splitOffset - writeOffset + EditorModeSegmentedControl.segmentWidth
        )

        XCTAssertEqual(EditorModeSegmentedControl.liquidPillOffset(from: .split, to: .read), readOffset)
        XCTAssertEqual(
            EditorModeSegmentedControl.liquidPillWidth(from: .split, to: .read),
            splitOffset - readOffset + EditorModeSegmentedControl.segmentWidth
        )
    }
}

import XCTest
@testable import Lineform

final class AppCommandNotificationTests: XCTestCase {
    func testReadingCommandsLiveInViewMenuWhileIntelligenceStaysTopLevel() {
        XCTAssertEqual(AppMenuConfiguration.readingCommandPlacement, .view)
        XCTAssertTrue(AppMenuConfiguration.keepsTopLevelIntelligenceMenu)
        XCTAssertFalse(AppMenuConfiguration.usesTopLevelReadingMenu)
    }

    func testIntelligenceMenuUsesOnlyLineformOwnedActions() {
        XCTAssertNil(AppMenuConfiguration.intelligencePrimaryCommandTitle)
        XCTAssertEqual(AppMenuConfiguration.lineformIntelligenceCommandTitles, [
            "Proofread",
            "Rewrite",
            "Summarize",
            "Make Shorter",
            "Clean Markdown"
        ])
        XCTAssertFalse(AppMenuConfiguration.addsWritingToolsToEditMenu)
        XCTAssertFalse(AppMenuConfiguration.exposesAppleWritingTools)
    }

    func testFormatMenuContainsEveryMarkdownBasicsAction() {
        XCTAssertEqual(AppMenuConfiguration.formatCommandTitles, [
            "Title",
            "Section",
            "Bold",
            "Italic",
            "Code",
            "Bulleted List",
            "Link"
        ])
    }

    func testReadingExperienceCommandUsesStableNotificationName() {
        XCTAssertEqual(
            LineformAppNotification.showReadingExperience.name.rawValue,
            "Lineform.showReadingExperience"
        )
    }

    func testFindCommandFocusesToolbarSearch() {
        XCTAssertEqual(AppMenuConfiguration.findCommandTitle, "Find")
        XCTAssertEqual(AppMenuConfiguration.findCommandKeyEquivalent, "f")
        XCTAssertEqual(
            LineformAppNotification.focusSearch.name.rawValue,
            "Lineform.focusSearch"
        )
    }

    func testNotificationPayloadCarriesActiveWindowIdentifier() {
        let payload = LineformAppNotification.Payload(windowNumber: 42, value: EditorDisplayMode.read.rawValue)

        XCTAssertTrue(payload.matches(windowNumber: 42))
        XCTAssertFalse(payload.matches(windowNumber: 7))
        XCTAssertEqual(payload.value, "read")
    }
}

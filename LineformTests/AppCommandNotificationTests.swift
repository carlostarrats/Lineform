import XCTest
@testable import Lineform

final class AppCommandNotificationTests: XCTestCase {
    func testReadingCommandsLiveInViewMenuWhileIntelligenceStaysTopLevel() {
        XCTAssertEqual(AppMenuConfiguration.readingCommandPlacement, .view)
        XCTAssertTrue(AppMenuConfiguration.keepsTopLevelIntelligenceMenu)
        XCTAssertFalse(AppMenuConfiguration.usesTopLevelReadingMenu)
    }

    func testIntelligenceMenuPrioritizesNativeWritingToolsBeforeLineformActions() {
        XCTAssertEqual(AppMenuConfiguration.intelligencePrimaryCommandTitle, "Show Writing Tools")
        XCTAssertEqual(AppMenuConfiguration.lineformIntelligenceCommandTitles, [
            "Proofread",
            "Rewrite",
            "Summarize",
            "Improve Readability",
            "Make Clearer",
            "Simplify",
            "Shorten",
            "Make Scannable",
            "Turn into Bullets",
            "Clean Markdown"
        ])
        XCTAssertFalse(AppMenuConfiguration.addsWritingToolsToEditMenu)
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

    func testNotificationPayloadCarriesActiveWindowIdentifier() {
        let payload = LineformAppNotification.Payload(windowNumber: 42, value: EditorDisplayMode.read.rawValue)

        XCTAssertTrue(payload.matches(windowNumber: 42))
        XCTAssertFalse(payload.matches(windowNumber: 7))
        XCTAssertEqual(payload.value, "read")
    }
}

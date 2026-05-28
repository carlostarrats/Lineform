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
        XCTAssertEqual(AppMenuConfiguration.markdownFormattingCommandTitles, [
            "Title",
            "Section",
            "Bold",
            "Italic",
            "Code",
            "Bulleted List",
            "Link"
        ])
        XCTAssertEqual(AppMenuConfiguration.formatCommandTitles(for: .markdown), [
            "Title",
            "Section",
            "Bold",
            "Italic",
            "Code",
            "Bulleted List",
            "Link",
            "Convert to Plain Text"
        ])
        XCTAssertEqual(AppMenuConfiguration.formatCommandTitles(for: .plainText), [
            "Convert to Markdown"
        ])
    }

    func testFileMenuExposesSaveAsBesideSave() {
        XCTAssertEqual(AppMenuConfiguration.saveCommandTitle, "Save")
        XCTAssertEqual(AppMenuConfiguration.saveAsCommandTitle, "Save As...")
        XCTAssertEqual(AppMenuConfiguration.saveAsCommandKeyEquivalent, "S")
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

    func testTextFormatConversionCommandUsesWindowScopedNotification() {
        XCTAssertEqual(
            LineformAppNotification.convertTextFormat.name.rawValue,
            "Lineform.convertTextFormat"
        )
        XCTAssertEqual(LineformTextFormat.markdown.rawValue, "markdown")
        XCTAssertEqual(LineformTextFormat.plainText.rawValue, "plainText")
    }

    func testNotificationPayloadCarriesActiveWindowIdentifier() {
        let payload = LineformAppNotification.Payload(windowNumber: 42, value: EditorDisplayMode.read.rawValue)

        XCTAssertTrue(payload.matches(windowNumber: 42))
        XCTAssertFalse(payload.matches(windowNumber: 7))
        XCTAssertEqual(payload.value, "read")
    }

    @MainActor
    func testDisplayModeMenuStateTracksCurrentMode() {
        let state = LineformDisplayModeMenuState(displayMode: .write)

        state.setDisplayMode(.read)

        XCTAssertEqual(state.displayMode, .read)
    }

    func testAppDeclaresImportedMarkdownType() throws {
        let bundle = try XCTUnwrap(Bundle(identifier: "com.lineform.app"))
        let declarations = try XCTUnwrap(
            bundle.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]]
        )

        let importedTypes = declarations.compactMap { declaration in
            declaration["UTTypeIdentifier"] as? String
        }

        XCTAssertTrue(importedTypes.contains("net.daringfireball.markdown"))
    }
}

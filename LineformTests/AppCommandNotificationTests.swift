import XCTest
@testable import Lineform

final class AppCommandNotificationTests: XCTestCase {
    func testAboutMenuUsesLineformVersionDisplay() {
        XCTAssertEqual(AppMenuConfiguration.aboutCommandTitle, "About Lineform")
        XCTAssertEqual(AppMenuConfiguration.aboutVersionDisplay, "V1.0.5")
        XCTAssertEqual(AppMenuConfiguration.aboutCopyright, "Copyright © 2026 Carlos Tarrats. All rights reserved.")
        XCTAssertEqual(AppMenuConfiguration.checkForUpdatesCommandTitle, "Check for Updates...")
        XCTAssertTrue(AppMenuConfiguration.suppressesDefaultHelpMenu)
        XCTAssertEqual(
            AppMenuConfiguration.aboutPanelOptions()[.applicationVersion] as? String,
            "V1.0.5"
        )
    }

    func testReadingCommandsLiveInViewMenuWhileIntelligenceDoesNotExposeShortcutMenu() {
        XCTAssertEqual(AppMenuConfiguration.readingCommandPlacement, .view)
        XCTAssertFalse(AppMenuConfiguration.keepsTopLevelIntelligenceMenu)
        XCTAssertFalse(AppMenuConfiguration.usesTopLevelReadingMenu)
    }

    func testIntelligenceMenuDoesNotExposeFixedShortcutActions() {
        XCTAssertNil(AppMenuConfiguration.intelligencePrimaryCommandTitle)
        XCTAssertTrue(AppMenuConfiguration.lineformIntelligenceCommandTitles.isEmpty)
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
        let bundle = Bundle(for: LineformAppDelegate.self)
        let declarations = try XCTUnwrap(
            bundle.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]]
        )

        let importedTypes = declarations.compactMap { declaration in
            declaration["UTTypeIdentifier"] as? String
        }

        XCTAssertTrue(importedTypes.contains("net.daringfireball.markdown"))
    }
}

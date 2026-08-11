import XCTest
@testable import Lineform

final class AppCommandNotificationTests: XCTestCase {
    func testAboutMenuUsesLineformVersionDisplay() {
        XCTAssertEqual(AppMenuConfiguration.aboutCommandTitle, "About Lineform")
        XCTAssertEqual(AppMenuConfiguration.aboutVersionDisplay, "V1.5.0")
        XCTAssertEqual(AppMenuConfiguration.aboutCopyright, "Copyright © 2026 Carlos Tarrats. All rights reserved.")
        XCTAssertEqual(AppMenuConfiguration.privacyPolicyCommandTitle, "Privacy Policy")
        XCTAssertEqual(AppMenuConfiguration.termsOfUseCommandTitle, "Terms of Use")
        XCTAssertTrue(AppMenuConfiguration.privacyPolicyURL.hasPrefix("https://"))
        XCTAssertTrue(AppMenuConfiguration.termsOfUseURL.hasPrefix("https://"))
        XCTAssertEqual(AppMenuConfiguration.guideCommandTitle, "Lineform Guide")
        XCTAssertEqual(AppMenuConfiguration.guideURL, "https://lineform.app/info/")
        XCTAssertTrue(AppMenuConfiguration.suppressesDefaultHelpMenu)
        XCTAssertEqual(
            AppMenuConfiguration.aboutPanelOptions()[.applicationVersion] as? String,
            "V1.5.0"
        )
    }

    func testReadingCommandsLiveInViewMenu() {
        XCTAssertEqual(AppMenuConfiguration.readingCommandPlacement, .view)
        XCTAssertFalse(AppMenuConfiguration.usesTopLevelReadingMenu)
    }

    func testHiddenFoldersCommandLivesInViewMenuWithStableTitleAndShortcut() {
        XCTAssertEqual(AppMenuConfiguration.showHiddenFoldersCommandTitle, "Show Hidden Folders")
        XCTAssertEqual(AppMenuConfiguration.showHiddenFoldersCommandKeyEquivalent, ".")
        XCTAssertEqual(
            LineformAppNotification.toggleHiddenFolders.name.rawValue,
            "Lineform.toggleHiddenFolders"
        )
    }

    @MainActor
    func testHiddenFoldersMenuStateTracksAndPersistsState() {
        let suiteName = "HiddenFoldersMenuStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { TestDefaults.destroy(defaults, suiteName: suiteName) }

        let key = OutlineFileBrowserStore.showsHiddenFoldersDefaultsKey
        let state = HiddenFoldersMenuState(defaults: defaults, defaultsKey: key)
        XCTAssertFalse(state.isOn)

        state.setShowsHiddenFolders(true)
        XCTAssertTrue(state.isOn)
        XCTAssertTrue(defaults.bool(forKey: key))

        // A fresh state reading the same suite reflects the persisted value —
        // the menu-state and the sidebar store share one source of truth.
        let reloaded = HiddenFoldersMenuState(defaults: defaults, defaultsKey: key)
        XCTAssertTrue(reloaded.isOn)
    }

    func testWritingToolsStayOutOfTheEditMenu() {
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

    func testSettingsCommandUsesStableNotificationNameAndTitle() {
        XCTAssertEqual(AppMenuConfiguration.settingsCommandTitle, "Settings…")
        XCTAssertEqual(
            LineformAppNotification.showSettings.name.rawValue,
            "Lineform.showSettings"
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

    func testFindReplaceCommandUsesWindowScopedNotification() {
        XCTAssertEqual(AppMenuConfiguration.findReplaceCommandTitle, "Find & Replace…")
        XCTAssertEqual(AppMenuConfiguration.findReplaceCommandKeyEquivalent, "f")
        XCTAssertEqual(
            LineformAppNotification.showFindReplace.name.rawValue,
            "Lineform.showFindReplace"
        )
    }

    func testJumpToFileCommandUsesWindowScopedNotification() {
        XCTAssertEqual(AppMenuConfiguration.jumpToFileCommandTitle, "Jump to File…")
        XCTAssertEqual(AppMenuConfiguration.jumpToFileCommandKeyEquivalent, "k")
        XCTAssertEqual(
            LineformAppNotification.showQuickOpen.name.rawValue,
            "Lineform.showQuickOpen"
        )
    }

    func testLinkFormattingShortcutMovedToCommandL() {
        // Cmd+K now belongs to Jump to File; Format > Link (and its context-menu hint)
        // must claim Cmd+L instead.
        XCTAssertEqual(AppMenuConfiguration.linkCommandKeyEquivalent, "l")
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
        // An unknown window on EITHER side matches nothing. `nil == nil` used to be true, so a
        // command posted with no key window fanned out to every window still resolving its own
        // number — including Close Tab, Save As, and Delete.
        XCTAssertFalse(payload.matches(windowNumber: nil))
        XCTAssertFalse(LineformAppNotification.Payload(windowNumber: nil).matches(windowNumber: 42))
        XCTAssertFalse(LineformAppNotification.Payload(windowNumber: nil).matches(windowNumber: nil))
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

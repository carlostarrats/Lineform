import XCTest
@testable import LineformCore

/// Persisted identity: renaming one of these silently resets every user's choice.
final class LineformSettingKeysTests: XCTestCase {
    func testSettingKeysAreTheMacsByteForByte() {
        XCTAssertEqual(LineformSettingKeys.automaticDarkMode, "Lineform.settings.automaticDarkMode")
        XCTAssertEqual(LineformSettingKeys.showICloudInSidebar, "Lineform.settings.showICloudInSidebar")
        XCTAssertEqual(LineformSettingKeys.checksForAnnouncements, "Lineform.settings.checksForAnnouncements")
        XCTAssertEqual(LineformSettingKeys.checksSpellingWhileTyping, "Lineform.settings.checksSpellingWhileTyping")
        XCTAssertEqual(LineformSettingKeys.showSidebarOnLaunch, "Lineform.settings.showSidebarOnLaunch")
        XCTAssertEqual(LineformSettingKeys.allowRootFolderCollapse, "Lineform.settings.allowRootFolderCollapse")
    }

    func testOutlineKeysAreTheMacsByteForByte() {
        XCTAssertEqual(LineformSettingKeys.iCloudSnapshot, "Lineform.outline.iCloudSnapshot")
        XCTAssertEqual(LineformSettingKeys.workspaceBookmark, "Lineform.outline.workspaceBookmark")
        XCTAssertEqual(LineformSettingKeys.workspaceSnapshot, "Lineform.outline.workspaceSnapshot")
        XCTAssertEqual(LineformSettingKeys.showsHiddenFolders, "Lineform.outline.showsHiddenFolders")
        XCTAssertEqual(LineformSettingKeys.iCloudSortOrder, "Lineform.outline.sortOrder.icloud")
        XCTAssertEqual(LineformSettingKeys.workspaceSortOrder, "Lineform.outline.sortOrder.workspace")
        XCTAssertEqual(LineformSettingKeys.lastKnownICloudAvailable, "Lineform.outline.lastKnownICloudAvailable")
    }

    func testEveryBooleanSettingDefaultsOn() {
        XCTAssertTrue(LineformSettingKeys.Defaults.showSidebarOnLaunch)
        XCTAssertTrue(LineformSettingKeys.Defaults.showICloudInSidebar)
        XCTAssertTrue(LineformSettingKeys.Defaults.checksSpellingWhileTyping)
        XCTAssertTrue(LineformSettingKeys.Defaults.checksForAnnouncements)
        XCTAssertTrue(LineformSettingKeys.Defaults.automaticDarkMode)
    }

    func testBoolReadsAnAbsentKeyAsItsDefault() throws {
        let suite = "LineformSettingKeysTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(LineformSettingKeys.bool(LineformSettingKeys.automaticDarkMode, default: true, in: defaults))
        defaults.set(false, forKey: LineformSettingKeys.automaticDarkMode)
        XCTAssertFalse(LineformSettingKeys.bool(LineformSettingKeys.automaticDarkMode, default: true, in: defaults))
        XCTAssertFalse(LineformSettingKeys.bool(LineformSettingKeys.showSidebarOnLaunch, default: false, in: defaults))
    }
}

import XCTest
@testable import Lineform

@MainActor
final class LineformSettingsTests: XCTestCase {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Store

    func testDefaultsAreSidebarOnLockOffICloudOn() {
        let store = LineformSettingsStore(defaults: freshDefaults("LineformSettingsDefaults"))
        XCTAssertTrue(store.showSidebarOnLaunch)
        XCTAssertFalse(store.keepRootFoldersExpanded)
        XCTAssertTrue(store.showICloudInSidebar)
    }

    func testEachSettingPersistsAcrossStoreInstances() {
        let defaults = freshDefaults("LineformSettingsPersist")
        let store = LineformSettingsStore(defaults: defaults)
        store.showSidebarOnLaunch = false
        store.keepRootFoldersExpanded = true
        store.showICloudInSidebar = false

        let restored = LineformSettingsStore(defaults: defaults)
        XCTAssertFalse(restored.showSidebarOnLaunch)
        XCTAssertTrue(restored.keepRootFoldersExpanded)
        XCTAssertFalse(restored.showICloudInSidebar)
    }
}

// MARK: - Emptiness helper

extension LineformSettingsTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformSettingsProbe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDocumentsFolderIsEmptyForEmptyDirectory() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(OutlineFileBrowserStore.documentsFolderIsEmpty(at: dir, fileManager: .default))
    }

    func testDocumentsFolderIsEmptyIgnoresNonMarkdownFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("image.png"))
        XCTAssertTrue(OutlineFileBrowserStore.documentsFolderIsEmpty(at: dir, fileManager: .default))
    }

    func testDocumentsFolderIsNotEmptyWithMarkdown() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Hi".data(using: .utf8)!.write(to: dir.appendingPathComponent("note.md"))
        XCTAssertFalse(OutlineFileBrowserStore.documentsFolderIsEmpty(at: dir, fileManager: .default))
    }
}

// MARK: - Probe

extension LineformSettingsTests {
    func testProbeReportsUnavailableWhenNoContainer() async {
        let probe = ICloudFolderProbe(documentsURLProvider: { nil })
        let status = await probe.status()
        XCTAssertEqual(status, .unavailable)
    }

    func testProbeReportsEmptyForEmptyFolder() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = ICloudFolderProbe(documentsURLProvider: { dir })
        let status = await probe.status()
        XCTAssertEqual(status, .empty)
    }

    func testProbeReportsNotEmptyWithMarkdown() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Hi".data(using: .utf8)!.write(to: dir.appendingPathComponent("note.md"))
        let probe = ICloudFolderProbe(documentsURLProvider: { dir })
        let status = await probe.status()
        XCTAssertEqual(status, .notEmpty)
    }
}

// MARK: - View-model

private struct StubProbe: ICloudFolderProbing {
    let result: ICloudFolderStatus
    func status() async -> ICloudFolderStatus { result }
}

extension LineformSettingsTests {
    func testViewModelStartsChecking() {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .empty))
        XCTAssertNil(vm.status)
        XCTAssertTrue(vm.isChecking)
        XCTAssertFalse(vm.isToggleEnabled)   // disabled while unknown
        XCTAssertTrue(vm.isControlVisible)   // visible (as "Checking…") until proven unavailable
    }

    func testViewModelUnavailableHidesControl() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .unavailable))
        await vm.refresh()
        XCTAssertFalse(vm.isChecking)
        XCTAssertFalse(vm.isControlVisible)
    }

    func testViewModelEmptyEnablesToggle() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .empty))
        await vm.refresh()
        XCTAssertTrue(vm.isControlVisible)
        XCTAssertTrue(vm.isToggleEnabled)
    }

    func testViewModelNotEmptyDisablesToggle() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .notEmpty))
        await vm.refresh()
        XCTAssertTrue(vm.isControlVisible)
        XCTAssertFalse(vm.isToggleEnabled)
    }
}

// MARK: - Sidebar composition helpers

extension LineformSettingsTests {
    func testICloudRootVisibleRequiresBothAvailabilityAndSetting() {
        // Available + setting on → visible
        XCTAssertTrue(OutlineSidebarView.iCloudRootVisible(state: .available, showICloudInSidebar: true))
        // Available + setting off → hidden
        XCTAssertFalse(OutlineSidebarView.iCloudRootVisible(state: .available, showICloudInSidebar: false))
        // Unavailable → hidden regardless of setting
        XCTAssertFalse(OutlineSidebarView.iCloudRootVisible(state: .unavailable, showICloudInSidebar: true))
    }

    func testRootDisclosureHiddenWhenLocked() {
        // Non-empty available root normally shows a chevron...
        XCTAssertTrue(OutlineSidebarView.rootDisclosureVisible(state: .available, isEmpty: false, lockExpanded: false))
        // ...but not when roots are locked expanded.
        XCTAssertFalse(OutlineSidebarView.rootDisclosureVisible(state: .available, isEmpty: false, lockExpanded: true))
    }

    func testRootIsCollapsedForcedFalseWhenLocked() {
        XCTAssertTrue(OutlineSidebarView.rootIsCollapsed(isInCollapsedSet: true, lockExpanded: false))
        XCTAssertFalse(OutlineSidebarView.rootIsCollapsed(isInCollapsedSet: true, lockExpanded: true))
    }
}

// MARK: - Launch seeding

extension LineformSettingsTests {
    func testInitialOutlineVisibleFollowsSetting() {
        let defaults = freshDefaults("LineformSettingsLaunchSeed")
        let store = LineformSettingsStore(defaults: defaults)

        store.showSidebarOnLaunch = true
        XCTAssertTrue(EditorContainerView.initialOutlineVisible(settings: store))

        store.showSidebarOnLaunch = false
        XCTAssertFalse(EditorContainerView.initialOutlineVisible(settings: store))
    }
}

// MARK: - Settings copy

extension LineformSettingsTests {
    func testSettingsCopyIsAccurateAndHonest() {
        XCTAssertEqual(SettingsView.showSidebarOnLaunchTitle, "Show sidebar on launch")
        XCTAssertEqual(SettingsView.keepRootsExpandedTitle, "Keep root folders expanded")
        XCTAssertEqual(SettingsView.showICloudTitle, "Show iCloud in sidebar")
        // The iCloud note must promise no destructive iCloud action.
        XCTAssertTrue(SettingsView.iCloudDisabledNote.contains("empty"))
        XCTAssertTrue(SettingsView.iCloudDisabledNote.lowercased().contains("does not delete"))
        XCTAssertEqual(SettingsView.iCloudCheckingNote, "Checking…")
    }
}

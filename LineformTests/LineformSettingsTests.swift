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

    func testDocumentsFolderWithOnlyHiddenContentCountsAsNotEmpty() throws {
        // The guard is conservative: content inside dot-folders counts regardless of the
        // user's Show Hidden Folders setting, so a root the sidebar COULD render files
        // under can never be hidden.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hidden = dir.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try "# Note".data(using: .utf8)!.write(to: hidden.appendingPathComponent("note.md"))
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
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .empty), seededStatus: nil)
        XCTAssertNil(vm.status)
        XCTAssertTrue(vm.isChecking)
        XCTAssertFalse(vm.canHideICloud)     // hiding blocked while unknown
        XCTAssertTrue(vm.isControlVisible)   // visible (as "Checking…") until proven unavailable
    }

    func testViewModelUnavailableHidesControl() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .unavailable), seededStatus: nil)
        await vm.refresh()
        XCTAssertFalse(vm.isChecking)
        XCTAssertFalse(vm.isControlVisible)
    }

    func testViewModelEmptyAllowsHiding() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .empty), seededStatus: nil)
        await vm.refresh()
        XCTAssertTrue(vm.isControlVisible)
        XCTAssertTrue(vm.canHideICloud)
    }

    func testViewModelNotEmptyBlocksHiding() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .notEmpty), seededStatus: nil)
        await vm.refresh()
        XCTAssertTrue(vm.isControlVisible)
        XCTAssertFalse(vm.canHideICloud)
    }

    func testViewModelSeededStatusRendersImmediatelyWithoutChecking() {
        // A prior probe's cached result renders instantly on reopen — no Checking flash,
        // no control flicker on machines where iCloud never resolves.
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .unavailable), seededStatus: .unavailable)
        XCTAssertFalse(vm.isChecking)
        XCTAssertFalse(vm.isControlVisible)
    }

    func testViewModelToggleDisableGuardOnlyBlocksTurningOff() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .notEmpty), seededStatus: nil)
        await vm.refresh()
        // Shown + folder not empty → can't turn off (disabled).
        XCTAssertTrue(vm.isToggleDisabled(currentlyShown: true))
        // Hidden + folder not empty → re-showing is always allowed (never stuck).
        XCTAssertFalse(vm.isToggleDisabled(currentlyShown: false))

        let emptyVM = ICloudSettingViewModel(probe: StubProbe(result: .empty), seededStatus: nil)
        await emptyVM.refresh()
        // Shown + folder empty → can turn off (enabled).
        XCTAssertFalse(emptyVM.isToggleDisabled(currentlyShown: true))
        XCTAssertFalse(emptyVM.isToggleDisabled(currentlyShown: false))
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

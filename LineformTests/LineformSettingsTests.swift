import XCTest
@testable import Lineform

@MainActor
final class LineformSettingsTests: XCTestCase {
    /// A suite no earlier run can have written to. See `TestDefaults.makeSuite`: a fixed name is
    /// shared with every previous run of this test, not isolation from it.
    private func freshDefaults(_ label: String) -> UserDefaults {
        TestDefaults.makeSuite(label)
    }

    // MARK: - Store

    func testDefaultsAreSidebarOnNoCollapseChoiceICloudOn() {
        let store = LineformSettingsStore(defaults: freshDefaults("LineformSettingsDefaults"))
        XCTAssertTrue(store.showSidebarOnLaunch)
        // No explicit collapse choice out of the box — the effective behavior adapts
        // to root visibility until the user touches the toggle.
        XCTAssertNil(store.allowRootFolderCollapseChoice)
        XCTAssertTrue(store.showICloudInSidebar)
    }

    func testEachSettingPersistsAcrossStoreInstances() {
        let defaults = freshDefaults("LineformSettingsPersist")
        let store = LineformSettingsStore(defaults: defaults)
        store.showSidebarOnLaunch = false
        store.setAllowRootFolderCollapse(false)
        store.showICloudInSidebar = false

        let restored = LineformSettingsStore(defaults: defaults)
        XCTAssertFalse(restored.showSidebarOnLaunch)
        XCTAssertEqual(restored.allowRootFolderCollapseChoice, false)
        XCTAssertFalse(restored.showICloudInSidebar)
    }

    // MARK: - Announcements

    func testChecksForAnnouncementsDefaultsToTrue() {
        let store = LineformSettingsStore(defaults: freshDefaults("LineformAnnouncementsDefault"))
        XCTAssertTrue(store.checksForAnnouncements, "announcement checks ship on")
    }

    func testChecksForAnnouncementsPersistsAcrossStoreInstances() {
        let defaults = freshDefaults("LineformAnnouncementsPersist")
        let store = LineformSettingsStore(defaults: defaults)
        store.checksForAnnouncements = false

        let restored = LineformSettingsStore(defaults: defaults)
        XCTAssertFalse(restored.checksForAnnouncements)
    }

    // MARK: - Spell checking

    func testChecksSpellingWhileTypingDefaultsToTrue() {
        let store = LineformSettingsStore(defaults: freshDefaults("LineformSpellCheckDefault"))
        XCTAssertTrue(store.checksSpellingWhileTyping, "live spell check ships on")
    }

    func testChecksSpellingWhileTypingPersistsAcrossStoreInstances() {
        let defaults = freshDefaults("LineformSpellCheckPersist")
        let store = LineformSettingsStore(defaults: defaults)
        store.checksSpellingWhileTyping = false

        let restored = LineformSettingsStore(defaults: defaults)
        XCTAssertFalse(restored.checksSpellingWhileTyping, "the user's choice must survive relaunch")
    }

    func testChecksSpellingWhileTypingWritesThroughToDefaults() {
        let defaults = freshDefaults("LineformSpellCheckWriteThrough")
        let store = LineformSettingsStore(defaults: defaults)
        store.checksSpellingWhileTyping = false
        XCTAssertEqual(
            defaults.object(forKey: LineformSettingsStore.checksSpellingWhileTypingKey) as? Bool,
            false
        )
    }

    func testStoreRecordsPersistedICloudAvailability() {
        // Optimistic default: never recorded → assume available (fresh installs are
        // mostly real users with iCloud; avoids a locked-geometry flash).
        let defaults = freshDefaults("LineformICloudAvailability")
        let unavailableStore = OutlineFileBrowserStore(
            defaults: defaults,
            iCloudDocumentsURLProvider: { _ in nil }
        )
        XCTAssertTrue(unavailableStore.lastKnownICloudAvailable)

        // A scan that fails to resolve the container records (and persists) false…
        unavailableStore.refreshICloud()
        XCTAssertFalse(unavailableStore.lastKnownICloudAvailable)
        XCTAssertEqual(defaults.object(forKey: OutlineFileBrowserStore.lastKnownICloudAvailableDefaultsKey) as? Bool, false)

        // …so the NEXT store on the same defaults knows before any scan runs.
        let restored = OutlineFileBrowserStore(
            defaults: defaults,
            iCloudDocumentsURLProvider: { _ in nil }
        )
        XCTAssertFalse(restored.lastKnownICloudAvailable)

        // And a scan that resolves flips it back.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let availableStore = OutlineFileBrowserStore(
            defaults: defaults,
            iCloudDocumentsURLProvider: { _ in dir }
        )
        availableStore.refreshICloud()
        XCTAssertTrue(availableStore.lastKnownICloudAvailable)
        XCTAssertEqual(defaults.object(forKey: OutlineFileBrowserStore.lastKnownICloudAvailableDefaultsKey) as? Bool, true)
    }

    func testViewModelSeedsFromPersistedAvailability() {
        // A Mac whose last scan found no iCloud renders .unavailable on the very
        // first Settings open of a session — no Checking… flash, and the collapse
        // toggle agrees with the sidebar's auto-lock immediately.
        ICloudSettingViewModel.resetProcessCacheForTesting()
        let defaults = freshDefaults("LineformVMPersistedSeed")
        defaults.set(false, forKey: OutlineFileBrowserStore.lastKnownICloudAvailableDefaultsKey)
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .unavailable), defaults: defaults)
        XCTAssertFalse(vm.isChecking)
        XCTAssertTrue(vm.isUnavailable)
    }

    func testEffectiveCollapseAdaptsToICloudVisibilityUntilUserChooses() {
        // No choice: collapsible only while both roots are visible — a lone
        // Workspace root auto-locks open (nothing to collapse against).
        XCTAssertTrue(LineformSettingsStore.effectiveAllowRootFolderCollapse(choice: nil, iCloudRootVisible: true))
        XCTAssertFalse(LineformSettingsStore.effectiveAllowRootFolderCollapse(choice: nil, iCloudRootVisible: false))
        // An explicit choice always wins, in both directions.
        XCTAssertTrue(LineformSettingsStore.effectiveAllowRootFolderCollapse(choice: true, iCloudRootVisible: false))
        XCTAssertFalse(LineformSettingsStore.effectiveAllowRootFolderCollapse(choice: false, iCloudRootVisible: true))
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
    func testViewModelStartsCheckingAndInert() {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .empty), seededStatus: nil)
        XCTAssertNil(vm.status)
        XCTAssertTrue(vm.isChecking)
        XCTAssertFalse(vm.canHideICloud)     // hiding blocked while unknown
        // Toggle is inert in either direction until the probe resolves.
        XCTAssertTrue(vm.isToggleDisabled(currentlyShown: true))
        XCTAssertTrue(vm.isToggleDisabled(currentlyShown: false))
    }

    func testViewModelUnavailableDisablesRow() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .unavailable), seededStatus: nil)
        await vm.refresh()
        XCTAssertFalse(vm.isChecking)
        XCTAssertTrue(vm.isUnavailable)
        // The row stays visible but the toggle is disabled in both directions.
        XCTAssertTrue(vm.isToggleDisabled(currentlyShown: true))
        XCTAssertTrue(vm.isToggleDisabled(currentlyShown: false))
    }

    func testViewModelEmptyAllowsHiding() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .empty), seededStatus: nil)
        await vm.refresh()
        XCTAssertFalse(vm.isUnavailable)
        XCTAssertTrue(vm.canHideICloud)
    }

    func testViewModelNotEmptyStillAllowsHiding() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .notEmpty), seededStatus: nil)
        await vm.refresh()
        XCTAssertFalse(vm.isUnavailable)
        XCTAssertFalse(vm.canHideICloud)
        XCTAssertFalse(vm.isToggleDisabled(currentlyShown: true))
    }

    func testViewModelSeededStatusRendersImmediatelyWithoutChecking() {
        // A prior probe's cached result renders instantly on reopen — no Checking flash.
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .unavailable), seededStatus: .unavailable)
        XCTAssertFalse(vm.isChecking)
        XCTAssertTrue(vm.isUnavailable)
    }

    func testViewModelToggleDisableGuardAllowsBothStatesWhenICloudIsAvailable() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .notEmpty), seededStatus: nil)
        await vm.refresh()
        // Hiding a non-empty folder is non-destructive, so it must not trap the user on.
        XCTAssertFalse(vm.isToggleDisabled(currentlyShown: true))
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
        XCTAssertEqual(SettingsModal.title, "Settings")
        XCTAssertEqual(SettingsModal.showSidebarOnLaunchTitle, "Show sidebar on launch")
        // The collapse setting reads in the affirmative and its note names what it
        // actually affects (the Files sidebar's iCloud and Workspace sections).
        XCTAssertEqual(SettingsModal.allowCollapseTitle, "Allow root folders to expand and collapse")
        XCTAssertTrue(SettingsModal.allowCollapseNote.contains("iCloud and Workspace"))
        XCTAssertTrue(SettingsModal.allowCollapseNote.contains("Files sidebar"))
        XCTAssertEqual(SettingsModal.showICloudTitle, "Show iCloud in sidebar")
        // The iCloud note makes both effects explicit: sidebar visibility and the starting
        // location for a new document's save panel.
        XCTAssertTrue(SettingsModal.iCloudEnabledNote.lowercased().contains("sidebar"))
        XCTAssertTrue(SettingsModal.iCloudEnabledNote.lowercased().contains("new document"))
        XCTAssertTrue(SettingsModal.iCloudEnabledNote.lowercased().contains("choose icloud"))
        XCTAssertEqual(SettingsModal.iCloudCheckingNote, "Checking…")
        XCTAssertEqual(SettingsModal.iCloudUnavailableNote, "iCloud is not available on this Mac.")
    }
}

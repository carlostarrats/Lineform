import XCTest
@testable import Lineform

@MainActor
final class DocumentReloadControllerTests: XCTestCase {
    private struct FakeReader: DocumentDiskReading {
        var text: String?
        var date: Date?
        func readText(at url: URL) -> String? { text }
        func modificationDate(at url: URL) -> Date? { date }
    }

    private func url() -> URL { URL(fileURLWithPath: "/tmp/lineform-test.md") }

    /// Poll until `condition` holds (or fail at `timeout`): async assertions must not be
    /// evaluated once at a fixed deadline — that flakes on loaded machines.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ description: String,
        _ condition: @escaping @MainActor () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let expectation = expectation(description: description)
        func poll() {
            if condition() {
                expectation.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
        }
        poll()
        wait(for: [expectation], timeout: timeout + 0.5)
    }

    func testNoteMovedRepointsWatcherWithoutBlessingUnsavedEditsAsSynced() {
        // An in-app rename retargets the watcher via noteMoved. Unlike register/update,
        // it must preserve the synced baseline: unsaved edits at rename time are still
        // unsaved, and blessing them would let a later external write clobber them.
        let controller = DocumentReloadController(diskReader: FakeReader(text: nil), debounceInterval: 0)
        controller.update(url: url(), syncedText: "saved text")
        controller.currentText = "saved text plus unsaved edits"

        let movedURL = URL(fileURLWithPath: "/tmp/lineform-test-renamed.md")
        controller.noteMoved(to: movedURL)

        XCTAssertEqual(controller.lastSyncedText, "saved text")
        XCTAssertEqual(controller.currentText, "saved text plus unsaved edits")

        // The dirty gate must still hold at the new URL: an external write there may not
        // overwrite the unsaved edits.
        controller.applyDiskSnapshot(url: movedURL, diskText: "external overwrite", modificationDate: Date())
        XCTAssertNil(controller.lastReload)
    }

    func testCleanExternalChangeReloads() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.applyDiskSnapshot(url: url(), diskText: "disk-new", modificationDate: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(controller.lastReload?.text, "disk-new")
        XCTAssertEqual(controller.lastReload?.modificationDate, Date(timeIntervalSince1970: 100))
    }

    // NOTE: this tests the CONTROLLER MECHANISM the background-tab reconcile depends on — that
    // `register(newURL)` followed by `fileDidChange()` picks up newer disk content rather than
    // blessing the passed (stale) syncedText. The actual one-line wiring lives in
    // `EditorContainerView.activateSelectedTab` (`if !isEdited { reloadController.fileDidChange() }`),
    // a SwiftUI View method not reachable from a unit test; the `!isEdited` clean-only guard that
    // protects a DIRTY tab from being clobbered is verified by review, not here. If this mechanism
    // regressed (register's new-URL branch stopped being reconcilable), the fix would silently break.
    func testRegisterToNewURLThenReconcilePicksUpNewerDisk() {
        let controller = DocumentReloadController(
            diskReader: FakeReader(text: "disk-new", date: Date(timeIntervalSince1970: 200)),
            debounceInterval: 0
        )
        controller.update(url: url(), syncedText: "first file")           // active tab = file A
        let other = URL(fileURLWithPath: "/tmp/lineform-test-other.md")
        controller.register(url: other, syncedText: "stale in-memory")    // switch to clean tab B (new URL)
        controller.fileDidChange()                                        // the reconcile the fix triggers
        waitUntil("reconcile after new-URL register picks up disk") { controller.lastReload?.text == "disk-new" }
    }

    func testTabSwitchAfterReloadPublishMovesBaselineOffThePublishedText() {
        // Backs the `applyReload` apply-time guard `result.text == reloadController.lastSyncedText`:
        // a published reload has text == lastSyncedText, and a tab switch (update to a new URL)
        // before that reload is applied moves lastSyncedText away from it — so a stale reload
        // belonging to the previous tab is detectable and can be dropped instead of written into
        // the now-active document.
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.applyDiskSnapshot(url: url(), diskText: "disk-new", modificationDate: nil)
        XCTAssertEqual(controller.lastReload?.text, "disk-new")
        XCTAssertEqual(controller.lastSyncedText, "disk-new") // published reload: text == baseline

        let other = URL(fileURLWithPath: "/tmp/lineform-other.md")
        controller.update(url: other, syncedText: "other tab text")
        XCTAssertNotEqual(controller.lastReload?.text, controller.lastSyncedText) // now detectably stale
    }

    func testUnsavedInMemoryEditsAreNotClobbered() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.currentText = "user typed"   // diverged from the synced baseline
        controller.applyDiskSnapshot(url: url(), diskText: "disk-new", modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testUnchangedDiskIsIgnored() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "same")
        controller.applyDiskSnapshot(url: url(), diskText: "same", modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testNoURLDoesNotReload() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: nil, syncedText: "old")
        controller.applyDiskSnapshot(url: url(), diskText: "disk-new", modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testStaleSnapshotURLIsIgnored() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.applyDiskSnapshot(url: URL(fileURLWithPath: "/tmp/other.md"), diskText: "disk-new", modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testNilDiskTextIsIgnored() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: nil), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.applyDiskSnapshot(url: url(), diskText: nil, modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testReloadAdvancesSyncedBaseline() {
        // After a reload, a subsequent unchanged snapshot must not reload again.
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.applyDiskSnapshot(url: url(), diskText: "v2", modificationDate: nil)
        XCTAssertEqual(controller.lastReload?.text, "v2")
        controller.clearLastReload()
        controller.currentText = "v2"   // the view applied the reload
        controller.applyDiskSnapshot(url: url(), diskText: "v2", modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testRegisterAfterStopReattachesWatcherAndReconciles() {
        // Window-tab deselect calls stop(); reselect must re-arm live reload for the SAME url.
        let controller = DocumentReloadController(diskReader: FakeReader(text: "disk-new"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.stop()
        controller.register(url: url(), syncedText: "old")
        waitUntil("reconciled reload after re-register") { controller.lastReload?.text == "disk-new" }
    }

    func testRegisterWithSameURLPreservesDirtyBaseline() {
        // Re-appearing mid-session must not bless unsaved edits as synced.
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.currentText = "user typed"
        controller.register(url: url(), syncedText: "user typed")
        controller.applyDiskSnapshot(url: url(), diskText: "disk-new", modificationDate: nil)
        XCTAssertNil(controller.lastReload, "dirty document must not be clobbered after re-registration")
    }

    func testNoteSavedBaselinesOnSavedTextNotLiveText() {
        // Keystrokes typed after the save snapshot must keep counting as unsaved edits.
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "saved")
        controller.currentText = "saved + newer keystrokes"
        controller.noteSaved(url: url(), savedText: "saved")
        controller.applyDiskSnapshot(url: url(), diskText: "external", modificationDate: nil)
        XCTAssertNil(controller.lastReload, "post-snapshot keystrokes were treated as synced")
    }

    func testWritingToolsSessionDefersReloadThenReconciles() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "disk-new"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.isWritingToolsSessionActive = true
        controller.applyDiskSnapshot(url: url(), diskText: "disk-new", modificationDate: nil)
        XCTAssertNil(controller.lastReload, "reload must be suspended during a Writing Tools session")
        controller.isWritingToolsSessionActive = false   // triggers a reconcile read
        waitUntil("reload after session end") { controller.lastReload?.text == "disk-new" }
    }

    func testUnchangedModificationDateSkipsFullRead() {
        final class CountingReader: DocumentDiskReading, @unchecked Sendable {
            let date = Date(timeIntervalSince1970: 100)
            private let lock = NSLock()
            private var readCountStorage = 0
            var readCount: Int { lock.lock(); defer { lock.unlock() }; return readCountStorage }
            func readText(at url: URL) -> String? {
                lock.lock(); readCountStorage += 1; lock.unlock()
                return "disk"
            }
            func modificationDate(at url: URL) -> Date? { date }
        }
        let reader = CountingReader()
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        // First pass: full read happens and the modification date is recorded.
        controller.applyDiskSnapshot(url: url(), diskText: "disk", modificationDate: reader.date)
        controller.clearLastReload()
        controller.fileDidChange()
        // Grace period, then assert no full read happened (a regression reads immediately).
        let gracePeriod = expectation(description: "grace period")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { gracePeriod.fulfill() }
        wait(for: [gracePeriod], timeout: 2)
        XCTAssertEqual(reader.readCount, 0, "unchanged modification date must be dismissed stat-only")
    }

    func testDebouncedReloadFromDiskReadsOffMainThenPublishes() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "disk-new"), debounceInterval: 0.05)
        controller.update(url: url(), syncedText: "old")
        controller.fileDidChange()
        waitUntil("debounced reload publishes") { controller.lastReload?.text == "disk-new" }
    }
}

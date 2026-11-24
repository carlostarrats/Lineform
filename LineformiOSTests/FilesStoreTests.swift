import Foundation
import LineformCore
import XCTest
@testable import LineformiOS

/// The Files section's store: when it scans, what it scans, the roots it shows, the Workspace
/// bookmark, and coordinated rename and Trash. Every test works in its own temporary folders and
/// its own defaults suite; the iCloud lookup, the bookmarks and (where it matters) the file
/// operations are injected, so nothing touches a real container or the real Trash.
@MainActor
final class FilesStoreTests: XCTestCase {
    private var folder: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "FilesStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - When to scan

    func testScanRunsOnlyWhenVisible() async throws {
        let device = try makeFolder("Device")
        try write("Hello", to: device.appendingPathComponent("Hello.md"))
        let iCloudLookups = FilesTestCounter()
        let log = FilesScanLog()
        let store = makeStore(device: device, iCloud: { iCloudLookups.increment(); return nil }, log: log)

        XCTAssertEqual(log.scannedURLs, [], "nothing is scanned at construction")
        await store.scanIfVisible()
        XCTAssertEqual(log.scannedURLs, [], "nothing is scanned while Files is not on screen")
        XCTAssertEqual(iCloudLookups.value, 0, "the iCloud container is not even looked up")

        store.setVisible(true)
        await store.scanIfVisible()
        XCTAssertEqual(log.scannedURLs, [device.standardizedFileURL])
        XCTAssertEqual(iCloudLookups.value, 1)
        XCTAssertEqual(store.root(.device)?.items.map(\.name), ["Hello.md"])

        store.setVisible(false)
        await store.scanIfVisible()
        XCTAssertEqual(log.scannedURLs.count, 1, "hiding Files stops scanning")
    }

    func testSortChangeRescans() async throws {
        let device = try makeFolder("Device")
        try write("A", to: device.appendingPathComponent("A.md"))
        let log = FilesScanLog()
        let store = makeStore(device: device, log: log)
        XCTAssertEqual(store.sortOrder, .name)

        await store.setSort(.dateModified)
        XCTAssertEqual(log.scans.count, 0, "a sort change while Files is hidden waits for it to show")
        XCTAssertEqual(defaults.string(forKey: LineformSettingKeys.workspaceSortOrder), "dateModified")
        XCTAssertEqual(defaults.string(forKey: LineformSettingKeys.iCloudSortOrder), "dateModified",
                       "one sort for every root, under both of the Mac's keys")

        store.setVisible(true)
        await store.scanIfVisible()
        XCTAssertEqual(log.scans.last?.sortOrder, .dateModified)
        let before = log.scans.count

        await store.setSort(.dateCreated)
        XCTAssertEqual(log.scans.count, before + 1, "a sort change re-scans rather than re-sorts")
        XCTAssertEqual(log.scans.last?.sortOrder, .dateCreated)

        let reloaded = makeStore(device: device, log: FilesScanLog())
        XCTAssertEqual(reloaded.sortOrder, .dateCreated, "the sort is kept")
    }

    func testHiddenOffRescans() async throws {
        let device = try makeFolder("Device")
        try write("Visible", to: device.appendingPathComponent("Visible.md"))
        try write("Agent", to: device.appendingPathComponent(".agents/Rules.md"))
        let log = FilesScanLog()
        let store = makeStore(device: device, log: log)
        store.setVisible(true)
        await store.scanIfVisible()
        XCTAssertEqual(store.root(.device)?.items.map(\.name), ["Visible.md"])

        await store.setShowsHidden(true)
        XCTAssertEqual(log.scans.last?.showsHidden, true)
        XCTAssertEqual(store.root(.device)?.items.map(\.name), [".agents", "Visible.md"])
        XCTAssertTrue(defaults.bool(forKey: LineformSettingKeys.showsHiddenFolders))

        let before = log.scans.count
        await store.setShowsHidden(false)
        XCTAssertEqual(log.scans.count, before + 1, "turning hidden folders off re-scans")
        XCTAssertEqual(log.scans.last?.showsHidden, false)
        XCTAssertEqual(store.root(.device)?.items.map(\.name), ["Visible.md"])
        XCTAssertFalse(defaults.bool(forKey: LineformSettingKeys.showsHiddenFolders))
    }

    // MARK: - Rename

    func testRenameOpenDocumentFollowsAndStopsAutoRename() async throws {
        let device = try makeFolder("Device")
        let document = OpenDocument(folderProvider: { device }, ubiquitousItems: FakeUbiquitousItems(arrivingText: nil))
        await document.prepare()
        document.edit("Draft one\nBody")
        await document.flush()
        XCTAssertEqual(document.url?.lastPathComponent, "Draft one.md")
        XCTAssertTrue(document.isNamedFromFirstLine)

        let store = makeStore(device: device, log: FilesScanLog())
        store.openDocument = document
        store.setVisible(true)
        await store.scanIfVisible()
        let item = try XCTUnwrap(store.root(.device)?.items.first)

        try await store.rename(item, to: "Chapter")

        XCTAssertEqual(document.url?.lastPathComponent, "Chapter.md", "the editor follows the file")
        XCTAssertFalse(document.isNamedFromFirstLine, "a rename by the writer stops automatic renaming")
        XCTAssertEqual(store.root(.device)?.items.map(\.name), ["Chapter.md"])

        document.edit("A different first line\nBody")
        await document.flush()
        XCTAssertEqual(try names(in: device), ["Chapter.md"], "the next save writes the new name; no duplicate")
        XCTAssertEqual(try String(contentsOf: device.appendingPathComponent("Chapter.md"), encoding: .utf8),
                       "A different first line\nBody")
    }

    func testRenameRejectsSlashAndEmpty() async throws {
        let device = try makeFolder("Device")
        try write("Notes", to: device.appendingPathComponent("Notes.md"))
        let operations = RecordingFileOperations()
        let store = makeStore(device: device, log: FilesScanLog(), operations: operations)
        store.setVisible(true)
        await store.scanIfVisible()
        let item = try XCTUnwrap(store.root(.device)?.items.first)

        for name in ["", "   ", "a/b", "x:y", ".", "..", "Notes"] {
            do {
                try await store.rename(item, to: name)
                XCTFail("“\(name)” was accepted")
            } catch {
                XCTAssertEqual(error as? FilesStoreError, .invalidName, "“\(name)”")
            }
        }
        XCTAssertEqual(operations.moves.count, 0, "an invalid name never reaches the disk")
        XCTAssertEqual(try names(in: device), ["Notes.md"])
        XCTAssertNil(store.notice, "the alert refuses the name itself; nothing failed")
    }

    // MARK: - Trash

    func testTrashOpenDocumentDetaches() async throws {
        let device = try makeFolder("Device")
        let fileURL = device.appendingPathComponent("Doomed.md")
        try write("Doomed\nText", to: fileURL)
        let document = OpenDocument(folderProvider: { device }, ubiquitousItems: FakeUbiquitousItems(arrivingText: nil))
        await document.prepare()
        try await document.open(fileURL)

        let trash = try makeFolder(".Trash")
        let store = makeStore(device: device, log: FilesScanLog(), operations: RecordingFileOperations(trashFolder: trash))
        store.openDocument = document
        store.setVisible(true)
        await store.scanIfVisible()
        let item = try XCTUnwrap(store.root(.device)?.items.first { $0.name == "Doomed.md" })

        try await store.trash(item)

        XCTAssertNil(document.url, "the document lets go of the trashed path")
        XCTAssertEqual(document.text, "Doomed\nText", "the text stays on screen")
        XCTAssertEqual(document.lastSyncedText, document.text, "nothing is waiting to be written back")
        await document.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "the trashed file is not written back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Doomed.md").path))
        XCTAssertEqual(store.root(.device)?.items.map(\.name), [])

        // Let any presenter callback still on its way land: it must not bring the file back either.
        try await Task.sleep(for: .milliseconds(400))
        await document.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testTrashUsesTrashNotRemove() async throws {
        try skipUnlessEnglishInterface()
        let device = try makeFolder("Device")
        let fileURL = device.appendingPathComponent("Old.md")
        try write("Old", to: fileURL)
        let trash = try makeFolder(".Trash")
        let operations = RecordingFileOperations(trashFolder: trash)
        let store = makeStore(device: device, log: FilesScanLog(), operations: operations)
        store.setVisible(true)
        await store.scanIfVisible()
        let item = try XCTUnwrap(store.root(.device)?.items.first)

        try await store.trash(item)
        XCTAssertEqual(operations.trashed.map(\.lastPathComponent), ["Old.md"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Old.md").path),
                      "the file is in the Trash, where it can be recovered")

        // A location whose provider refuses the Trash: an error notice, and the file stays.
        try write("Kept", to: device.appendingPathComponent("Kept.md"))
        let refusing = RecordingFileOperations(refusesTrash: true)
        let refusingStore = makeStore(device: device, log: FilesScanLog(), operations: refusing)
        refusingStore.setVisible(true)
        await refusingStore.scanIfVisible()
        let kept = try XCTUnwrap(refusingStore.root(.device)?.items.first { $0.name == "Kept.md" })
        do {
            try await refusingStore.trash(kept)
            XCTFail("a refused Trash reported success")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: device.appendingPathComponent("Kept.md").path),
                      "a refused Trash never falls back to deleting")
        XCTAssertEqual(refusingStore.notice, "Couldn’t move “Kept.md” to the Trash.")

        // And nothing in the store can delete outright.
        let source = try String(contentsOf: Self.sourceURL("LineformiOS/Menu/FilesStore.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("removeItem("), "FilesStore never calls removeItem")
        XCTAssertTrue(source.contains("trashItem(at:"))
    }

    /// Why the iPhone coordinates (files-sidebar.md): the coordinated move ALONE, with no direct
    /// call into the document, is enough for its presenter to follow a rename and to let go of a
    /// trashed file. The direct calls only make it immediate.
    func testCoordinationAloneReachesTheOpenDocumentsPresenter() async throws {
        let device = try makeFolder("Device")
        let renamed = device.appendingPathComponent("Renamed.md")
        try write("Moved", to: device.appendingPathComponent("Moved.md"))
        let document = OpenDocument(folderProvider: { device }, ubiquitousItems: FakeUbiquitousItems(arrivingText: nil))
        await document.prepare()
        try await document.open(device.appendingPathComponent("Moved.md"))

        try FilesStore.coordinatedMove(from: device.appendingPathComponent("Moved.md"), to: renamed, using: LiveFilesFileOperations())
        try await waitUntil { document.url?.lastPathComponent == "Renamed.md" }
        XCTAssertEqual(document.url?.lastPathComponent, "Renamed.md", "the presenter followed the rename")
        XCTAssertFalse(document.isNamedFromFirstLine)

        let trash = try makeFolder(".Trash")
        try FilesStore.coordinatedTrash(renamed, using: RecordingFileOperations(trashFolder: trash))
        try await waitUntil { document.url == nil }
        XCTAssertNil(document.url, "the presenter let go of the trashed file")
        XCTAssertEqual(document.text, "Moved")
    }

    // MARK: - Workspace

    func testWorkspaceStaleBookmarkShowsUnavailable() async throws {
        let device = try makeFolder("Device")
        let workspace = try makeFolder("Workspace")
        try write("W", to: workspace.appendingPathComponent("W.md"))

        // Stale, and it cannot be refreshed (the provider no longer grants it).
        defaults.set(Data("old".utf8), forKey: LineformSettingKeys.workspaceBookmark)
        let stale = FakeBookmarks(resolvesTo: workspace, isStale: true, refreshFails: true)
        let log = FilesScanLog()
        let store = makeStore(device: device, log: log, bookmarks: stale)
        store.setVisible(true)
        await store.scanIfVisible()
        XCTAssertEqual(store.root(.workspace)?.state, .unavailable)
        XCTAssertFalse(log.scannedURLs.contains(workspace.standardizedFileURL), "never scans without access")

        // A bookmark that no longer resolves at all.
        let broken = FakeBookmarks(resolvesTo: nil)
        let brokenStore = makeStore(device: device, log: log, bookmarks: broken)
        brokenStore.setVisible(true)
        await brokenStore.scanIfVisible()
        XCTAssertEqual(brokenStore.root(.workspace)?.state, .unavailable)

        // Stale but refreshable: re-resolved, refreshed under the same key, and held.
        let refreshable = FakeBookmarks(resolvesTo: workspace, isStale: true)
        let refreshedStore = makeStore(device: device, log: log, bookmarks: refreshable)
        refreshedStore.setVisible(true)
        await refreshedStore.scanIfVisible()
        XCTAssertEqual(refreshedStore.root(.workspace)?.state, .available)
        XCTAssertEqual(refreshedStore.root(.workspace)?.items.map(\.name), ["W.md"])
        XCTAssertEqual(defaults.data(forKey: LineformSettingKeys.workspaceBookmark), FakeBookmarks.freshData)
        XCTAssertEqual(refreshable.started.map(\.standardizedFileURL), [workspace.standardizedFileURL])
        XCTAssertEqual(refreshable.stopped, [], "the scope is held for the store's lifetime")
    }

    func testNoScanBeforeWorkspaceAccepted() async throws {
        let device = try makeFolder("Device")
        let workspace = try makeFolder("Picked")
        try write("Idea", to: workspace.appendingPathComponent("Idea.md"))
        let bookmarks = FakeBookmarks(resolvesTo: workspace)
        let log = FilesScanLog()
        let store = makeStore(device: device, log: log, bookmarks: bookmarks)
        store.setVisible(true)
        await store.scanIfVisible()
        XCTAssertEqual(store.root(.workspace)?.state, .unassigned)
        XCTAssertEqual(log.scannedURLs, [device.standardizedFileURL], "no Workspace scan before a folder is chosen")

        store.chooseWorkspace(workspace)
        await store.scanIfVisible()
        XCTAssertEqual(defaults.data(forKey: LineformSettingKeys.workspaceBookmark), FakeBookmarks.freshData,
                       "a plain bookmark, under the Mac's key name")
        XCTAssertEqual(store.root(.workspace)?.state, .available)
        XCTAssertEqual(store.root(.workspace)?.title, "Picked")
        XCTAssertEqual(store.root(.workspace)?.folderURL?.standardizedFileURL, workspace.standardizedFileURL)
        XCTAssertEqual(store.root(.workspace)?.items.map(\.name), ["Idea.md"])
        XCTAssertEqual(bookmarks.stopped, [])
    }

    // MARK: - Roots

    func testICloudRootHiddenWhenUnresolved() async throws {
        let device = try makeFolder("Device")
        let iCloud = try makeFolder("iCloud/Documents")
        try write("Cloud", to: iCloud.appendingPathComponent("Cloud.md"))

        let unresolved = makeStore(device: device, iCloud: { nil }, log: FilesScanLog())
        unresolved.setVisible(true)
        await unresolved.scanIfVisible()
        XCTAssertEqual(unresolved.roots.map(\.id), [.device, .workspace], "no dead iCloud entry")

        let resolved = makeStore(device: device, iCloud: { iCloud }, log: FilesScanLog())
        resolved.setVisible(true)
        await resolved.scanIfVisible()
        XCTAssertEqual(resolved.roots.map(\.id), [.icloud, .workspace])
        XCTAssertEqual(resolved.root(.icloud)?.items.map(\.name), ["Cloud.md"])

        defaults.set(false, forKey: LineformSettingKeys.showICloudInSidebar)
        let switchedOff = makeStore(device: device, iCloud: { iCloud }, log: FilesScanLog())
        switchedOff.setVisible(true)
        await switchedOff.scanIfVisible()
        XCTAssertEqual(switchedOff.roots.map(\.id), [.workspace], "the setting hides iCloud")
    }

    // MARK: - Watching

    func testSubfolderChangeRefreshes() async throws {
        let device = try makeFolder("Device")
        let sub = device.appendingPathComponent("Sub", isDirectory: true)
        try write("A", to: sub.appendingPathComponent("A.md"))
        let store = makeStore(device: device, log: FilesScanLog())
        store.setVisible(true)
        await store.scanIfVisible()
        XCTAssertEqual(store.children(of: sub)?.map(\.name), ["A.md"])

        // Another app (or iCloud) adds a file two levels down, through a coordinated write.
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: sub.appendingPathComponent("B.md"), options: .forReplacing, error: &error
        ) { url in
            try? Data("B".utf8).write(to: url)
        }
        XCTAssertNil(error)

        let deadline = Date().addingTimeInterval(5)
        while store.children(of: sub)?.map(\.name) != ["A.md", "B.md"], Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(store.children(of: sub)?.map(\.name), ["A.md", "B.md"], "a change in a subfolder refreshes")

        store.setVisible(false)
    }

    // MARK: - Review fixes

    /// The open document was typed into and its first line changed just before the rename: the
    /// pre-rename save renames the file from the first line, so the rename moves the file where it
    /// is now, not where the scan saw it.
    func testRenameRightAfterTypingMovesTheFileWhereItIsNow() async throws {
        let device = try makeFolder("Device")
        let document = OpenDocument(folderProvider: { device }, ubiquitousItems: FakeUbiquitousItems(arrivingText: nil))
        await document.prepare()
        document.edit("Draft\nBody")
        await document.flush()
        XCTAssertEqual(document.url?.lastPathComponent, "Draft.md")

        let store = makeStore(device: device, log: FilesScanLog())
        store.openDocument = document
        store.setVisible(true)
        await store.scanIfVisible()
        let item = try XCTUnwrap(store.root(.device)?.items.first)
        XCTAssertEqual(item.name, "Draft.md")

        // Typed, and not yet autosaved: the save before the move renames Draft.md.
        document.edit("Better title\nBody")
        try await store.rename(item, to: "Chosen")

        XCTAssertEqual(try names(in: device), ["Chosen.md"], "no stray Draft.md or Better title.md")
        XCTAssertEqual(try String(contentsOf: device.appendingPathComponent("Chosen.md"), encoding: .utf8), "Better title\nBody")
        XCTAssertEqual(document.url?.lastPathComponent, "Chosen.md")
        XCTAssertFalse(document.isNamedFromFirstLine)
        XCTAssertNil(store.notice)
    }

    /// Rename and Delete act on downloaded files only: an iCloud placeholder's row offers neither,
    /// and the store refuses both, so nothing ever moves the `.Name.md.icloud` stub.
    func testPlaceholdersCannotBeRenamedOrTrashed() async throws {
        let device = try makeFolder("Device")
        let stub = device.appendingPathComponent(".Evicted.md.icloud")
        try write("stub", to: stub)
        try write("Here", to: device.appendingPathComponent("Here.md"))
        let operations = RecordingFileOperations(trashFolder: try makeFolder(".Trash"))
        let store = makeStore(device: device, log: FilesScanLog(), operations: operations)
        store.setVisible(true)
        await store.scanIfVisible()
        let placeholder = try XCTUnwrap(store.root(.device)?.items.first { $0.name == "Evicted.md" })
        XCTAssertTrue(placeholder.isICloudPlaceholder)

        XCTAssertEqual(FilesRowAction.swipeActions(for: placeholder), [], "no swipe actions on a placeholder")
        XCTAssertEqual(FilesRowAction.menuActions(for: placeholder), [], "no Rename or Delete in its menu")
        let here = try XCTUnwrap(store.root(.device)?.items.first { $0.name == "Here.md" })
        XCTAssertEqual(FilesRowAction.swipeActions(for: here), [.rename, .delete])

        do {
            try await store.rename(placeholder, to: "Renamed")
            XCTFail("a placeholder was renamed")
        } catch {
            XCTAssertEqual(error as? FilesStoreError, .notDownloaded)
        }
        do {
            try await store.trash(placeholder)
            XCTFail("a placeholder was trashed")
        } catch {
            XCTAssertEqual(error as? FilesStoreError, .notDownloaded)
        }
        // Even an item that lost its flag (built by hand) is caught by what is on disk.
        var unflagged = placeholder
        unflagged.isICloudPlaceholder = false
        do {
            try await store.trash(unflagged)
            XCTFail("a placeholder was trashed")
        } catch {
            XCTAssertEqual(error as? FilesStoreError, .notDownloaded)
        }
        XCTAssertEqual(operations.moves.count, 0)
        XCTAssertEqual(operations.trashed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stub.path), "the stub never moves")
    }

    /// Files and Search each make the store visible; one going away never hides it from the other,
    /// whichever order SwiftUI runs the switch in.
    func testVisibilityCountsEachUser() async throws {
        let device = try makeFolder("Device")
        let store = makeStore(device: device, log: FilesScanLog())

        // Search → Files, Files appearing first.
        store.setVisible(true, for: .search)
        store.setVisible(true, for: .files)
        store.setVisible(false, for: .search)
        XCTAssertTrue(store.isVisible, "Search ending never hides Files")
        store.setVisible(false, for: .files)
        XCTAssertFalse(store.isVisible)

        // Search → Files, Search going away first.
        store.setVisible(true, for: .search)
        store.setVisible(false, for: .search)
        store.setVisible(true, for: .files)
        XCTAssertTrue(store.isVisible)
        // Files → Search, Search appearing first, then Files going away.
        store.setVisible(true, for: .search)
        store.setVisible(false, for: .files)
        XCTAssertTrue(store.isVisible, "Files ending never hides Search")
        store.setVisible(false, for: .search)
        XCTAssertFalse(store.isVisible)

        // Through the Search controller itself.
        try write("Note", to: device.appendingPathComponent("Note.md"))
        let controller = SearchController(
            editor: RecordingEditorCommands(text: ""), files: store, currentURL: { nil },
            fileSearch: CrossFileSearchModel(debounceInterval: 0), open: { _ in nil }, announce: { _ in }
        )
        controller.setQuery("note")
        await controller.pendingScan?.value
        store.setVisible(true, for: .files)
        controller.stop()
        XCTAssertTrue(store.isVisible, "Search stopping leaves Files showing")
        store.setVisible(false, for: .files)
        XCTAssertFalse(store.isVisible)
    }

    /// Settings › Show iCloud in Files applies at once, and turning it back on never shows the
    /// iCloud list from before.
    func testShowICloudSettingAppliesLive() async throws {
        let device = try makeFolder("Device")
        let iCloud = try makeFolder("iCloud/Documents")
        try write("Cloud", to: iCloud.appendingPathComponent("Cloud.md"))
        let store = makeStore(device: device, iCloud: { iCloud }, log: FilesScanLog())
        store.setVisible(true)
        await store.scanIfVisible()
        XCTAssertEqual(store.roots.map(\.id), [.icloud, .workspace])

        defaults.set(false, forKey: LineformSettingKeys.showICloudInSidebar)
        try await waitUntil { store.root(.icloud) == nil }
        XCTAssertNil(store.root(.icloud), "the switch hides iCloud without a relaunch")

        // While it is off, the folder changes; the old list must not come back.
        try FileManager.default.removeItem(at: iCloud.appendingPathComponent("Cloud.md"))
        try write("New", to: iCloud.appendingPathComponent("New.md"))
        store.setVisible(false)
        defaults.set(true, forKey: LineformSettingKeys.showICloudInSidebar)
        try await waitUntil { store.root(.icloud) != nil }
        XCTAssertNotEqual(store.root(.icloud)?.items.map(\.name), ["Cloud.md"], "no stale cache")
        store.setVisible(true)
        await store.scanIfVisible()
        XCTAssertEqual(store.root(.icloud)?.items.map(\.name), ["New.md"], "the next appearance scans afresh")
    }

    /// Documents saved on the device before iCloud came on stay listed under On My iPhone.
    func testDeviceRootShowsWhenItHasDocumentsEvenWithICloud() async throws {
        let device = try makeFolder("Device")
        let iCloud = try makeFolder("iCloud/Documents")
        try write("Cloud", to: iCloud.appendingPathComponent("Cloud.md"))

        let empty = makeStore(device: device, iCloud: { iCloud }, log: FilesScanLog())
        empty.setVisible(true)
        await empty.scanIfVisible()
        XCTAssertEqual(empty.roots.map(\.id), [.icloud, .device, .workspace], "On My iPhone shows even when empty, so documents can be kept on the device")

        try write("Old", to: device.appendingPathComponent("Old.md"))
        let store = makeStore(device: device, iCloud: { iCloud }, log: FilesScanLog())
        store.setVisible(true)
        await store.scanIfVisible()
        XCTAssertEqual(store.roots.map(\.id), [.icloud, .device, .workspace])
        XCTAssertEqual(store.root(.device)?.items.map(\.name), ["Old.md"])
        XCTAssertEqual(store.root(.icloud)?.items.map(\.name), ["Cloud.md"])

        // Its documents are searchable too.
        let entries = SearchController.entries(from: store.roots, excluding: nil)
        XCTAssertEqual(Set(entries.map(\.name)), ["Old.md", "Cloud.md"])
    }

    /// `.Trash` (where Files moves deleted documents) is never listed, whatever Show Hidden
    /// Folders says, and a file next to its own placeholder is one row.
    func testTrashIsNeverListedAndAPlaceholderBesideItsFileIsOneRow() async throws {
        let device = try makeFolder("Device")
        try write("Kept", to: device.appendingPathComponent("Kept.md"))
        try write("Gone", to: device.appendingPathComponent(".Trash/Gone.md"))
        try write("Both", to: device.appendingPathComponent("Both.md"))
        try write("stub", to: device.appendingPathComponent(".Both.md.icloud"))
        let store = makeStore(device: device, log: FilesScanLog())
        store.setVisible(true)
        await store.scanIfVisible()
        XCTAssertEqual(store.root(.device)?.items.map(\.name), ["Both.md", "Kept.md"])
        await store.setShowsHidden(true)
        XCTAssertEqual(store.root(.device)?.items.map(\.name), ["Both.md", "Kept.md"], "no .Trash even with hidden folders shown")
        XCTAssertEqual(store.root(.device)?.items.first?.isICloudPlaceholder, false, "the real file wins")
    }

    // MARK: - Helpers

    private func makeStore(
        device: URL,
        iCloud: @escaping @Sendable () -> URL? = { nil },
        log: FilesScanLog,
        operations: any FilesFileOperating = RecordingFileOperations(),
        bookmarks: any WorkspaceBookmarking = FakeBookmarks(resolvesTo: nil)
    ) -> FilesStore {
        FilesStore(
            defaults: defaults,
            iCloudFolder: iCloud,
            deviceFolder: device,
            bookmarks: bookmarks,
            fileOperations: operations,
            scanner: { url, showsHidden, sortOrder in
                log.record(url: url, showsHidden: showsHidden, sortOrder: sortOrder)
                return FilesStore.liveScanner(url, showsHidden, sortOrder)
            }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @discardableResult
    private func makeFolder(_ path: String) throws -> URL {
        let url = folder.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    static func sourceURL(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
    }
}

// MARK: - Test doubles

/// Every scan the store asked for, in order.
final class FilesScanLog: @unchecked Sendable {
    struct Scan: Equatable {
        var url: URL
        var showsHidden: Bool
        var sortOrder: OutlineFileSortOrder
    }

    private let lock = NSLock()
    private var recorded: [Scan] = []

    func record(url: URL, showsHidden: Bool, sortOrder: OutlineFileSortOrder) {
        lock.withLock { recorded.append(Scan(url: url.standardizedFileURL, showsHidden: showsHidden, sortOrder: sortOrder)) }
    }

    var scans: [Scan] { lock.withLock { recorded } }
    var scannedURLs: [URL] { scans.map(\.url) }
}

final class FilesTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// File operations that record what they were asked to do. A move is real; the Trash is a
/// `.Trash` folder of the test's own (or a refusal, as some providers answer).
final class RecordingFileOperations: FilesFileOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var movesRecorded: [(URL, URL)] = []
    private var trashedRecorded: [URL] = []
    private let trashFolder: URL?
    private let refusesTrash: Bool

    init(trashFolder: URL? = nil, refusesTrash: Bool = false) {
        self.trashFolder = trashFolder
        self.refusesTrash = refusesTrash
    }

    var moves: [(URL, URL)] { lock.withLock { movesRecorded } }
    var trashed: [URL] { lock.withLock { trashedRecorded } }

    func moveItem(at source: URL, to destination: URL) throws {
        lock.withLock { movesRecorded.append((source, destination)) }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func trashItem(at url: URL) throws {
        lock.withLock { trashedRecorded.append(url) }
        if refusesTrash { throw CocoaError(.featureUnsupported) }
        guard let trashFolder else { throw CocoaError(.featureUnsupported) }
        try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(url.lastPathComponent))
    }
}

/// Bookmarks without the system: resolves every bookmark to one folder (or fails), optionally
/// stale, and records the security scopes started and stopped.
final class FakeBookmarks: WorkspaceBookmarking, @unchecked Sendable {
    static let freshData = Data("fresh-bookmark".utf8)

    private let lock = NSLock()
    private let target: URL?
    private let isStale: Bool
    private let refreshFails: Bool
    private var startedRecorded: [URL] = []
    private var stoppedRecorded: [URL] = []

    init(resolvesTo target: URL?, isStale: Bool = false, refreshFails: Bool = false) {
        self.target = target
        self.isStale = isStale
        self.refreshFails = refreshFails
    }

    var started: [URL] { lock.withLock { startedRecorded } }
    var stopped: [URL] { lock.withLock { stoppedRecorded } }

    func bookmarkData(for url: URL) throws -> Data {
        if refreshFails { throw CocoaError(.fileReadNoPermission) }
        return Self.freshData
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        guard let target else { throw CocoaError(.fileNoSuchFile) }
        return (target, isStale)
    }

    func startAccess(_ url: URL) -> Bool {
        lock.withLock { startedRecorded.append(url) }
        return true
    }

    func stopAccess(_ url: URL) {
        lock.withLock { stoppedRecorded.append(url) }
    }
}

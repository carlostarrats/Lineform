import XCTest
import AppKit
import SwiftUI
@testable import Lineform

@MainActor
final class EditorTabStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeDocument(_ text: String = "") -> LineformDocument {
        LineformDocument(text: text)
    }

    private func makeStore(text: String = "") -> EditorTabStore {
        EditorTabStore(initialDocument: makeDocument(text))
    }

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    // MARK: - Open / dedupe

    func testInitStartsWithOneSelectedTab() {
        let store = makeStore()
        XCTAssertEqual(store.tabCount, 1)
        XCTAssertEqual(store.selectedTabID, store.tabs.first?.id)
        XCTAssertFalse(store.shouldShowTabBar)
    }

    func testOpenTabAppendsAndSelects() {
        let store = makeStore()
        let id = store.openTab(document: makeDocument("second"), fileURL: url("/tmp/b.md"))
        XCTAssertEqual(store.tabCount, 2)
        XCTAssertEqual(store.selectedTabID, id)
        XCTAssertTrue(store.shouldShowTabBar)
    }

    func testOpenTabForAlreadyOpenFileSwitchesInsteadOfDuplicating() {
        let store = makeStore()
        let fileURL = url("/tmp/notes.md")
        let firstID = store.openTab(document: makeDocument("v1"), fileURL: fileURL)
        // Re-opening the same file (even a different document instance) must switch, not add.
        let secondID = store.openTab(document: makeDocument("v2"), fileURL: fileURL)
        XCTAssertEqual(store.tabCount, 2) // initial + the one file tab
        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(store.selectedTabID, firstID)
    }

    func testTabIndexForURLStandardizesPath() {
        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: url("/tmp/dir/file.md"))
        XCTAssertNotNil(store.tabIndex(for: url("/tmp/dir/../dir/file.md")))
    }

    // MARK: - Close / selection reindex

    func testClosingSelectedMiddleTabSelectsFollowingTab() {
        let store = makeStore()
        let a = store.tabs[0].id
        let b = store.openTab(document: makeDocument(), fileURL: url("/tmp/b.md"))
        let c = store.openTab(document: makeDocument(), fileURL: url("/tmp/c.md"))
        store.selectTab(id: b)
        store.closeTab(id: b)
        XCTAssertEqual(store.tabs.map(\.id), [a, c])
        XCTAssertEqual(store.selectedTabID, c) // the tab that shifted into b's slot
    }

    func testClosingSelectedLastTabSelectsPreviousTab() {
        let store = makeStore()
        let a = store.tabs[0].id
        let c = store.openTab(document: makeDocument(), fileURL: url("/tmp/c.md"))
        store.selectTab(id: c)
        store.closeTab(id: c)
        XCTAssertEqual(store.selectedTabID, a)
    }

    func testClosingNonSelectedTabKeepsSelection() {
        let store = makeStore()
        let a = store.tabs[0].id
        let b = store.openTab(document: makeDocument(), fileURL: url("/tmp/b.md"))
        store.selectTab(id: a)
        store.closeTab(id: b)
        XCTAssertEqual(store.selectedTabID, a)
    }

    func testClosingLastRemainingTabClearsSelection() {
        let store = makeStore()
        store.closeTab(id: store.tabs[0].id)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.selectedTabID)
    }

    // MARK: - Next / previous wrap

    func testSelectNextAndPreviousWrapAround() {
        let store = makeStore()
        let a = store.tabs[0].id
        let b = store.openTab(document: makeDocument(), fileURL: url("/tmp/b.md"))
        store.selectTab(id: b)
        store.selectNextTab() // wraps to first
        XCTAssertEqual(store.selectedTabID, a)
        store.selectPreviousTab() // wraps back to last
        XCTAssertEqual(store.selectedTabID, b)
    }

    // MARK: - Rename retargeting

    func testRetargetFileURLUpdatesExactMatch() {
        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: url("/tmp/old.md"))
        store.retargetFileURL(from: url("/tmp/old.md"), to: url("/tmp/new.md"), isDirectory: false)
        XCTAssertNotNil(store.tabIndex(for: url("/tmp/new.md")))
        XCTAssertNil(store.tabIndex(for: url("/tmp/old.md")))
    }

    func testRetargetFileURLRebasesFolderDescendants() {
        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: url("/tmp/Docs/a.md"))
        store.retargetFileURL(from: url("/tmp/Docs"), to: url("/tmp/Archive"), isDirectory: true)
        XCTAssertNotNil(store.tabIndex(for: url("/tmp/Archive/a.md")))
    }

    func testRetargetFileURLLeavesUnrelatedTabsUntouched() {
        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: url("/tmp/keep.md"))
        store.retargetFileURL(from: url("/tmp/other.md"), to: url("/tmp/moved.md"), isDirectory: false)
        XCTAssertNotNil(store.tabIndex(for: url("/tmp/keep.md")))
    }

    // MARK: - Delete

    func testMarkFileDeletedClearsMatchingURLOnly() {
        let store = makeStore()
        let deletedTab = store.openTab(document: makeDocument("content"), fileURL: url("/tmp/gone.md"))
        store.openTab(document: makeDocument(), fileURL: url("/tmp/stay.md"))
        store.markFileDeleted(url("/tmp/gone.md"))
        let index = store.tabs.firstIndex { $0.id == deletedTab }!
        XCTAssertNil(store.tabs[index].fileURL) // became untitled-with-content
        XCTAssertNotNil(store.tabIndex(for: url("/tmp/stay.md")))
    }

    // MARK: - Save As destination conflicts

    func testSaveAsOntoAnotherOpenTabIsAConflict() {
        let store = makeStore()
        store.openTab(document: makeDocument("victim"), fileURL: url("/tmp/other.md"))
        let active = store.openTab(document: makeDocument("active"), fileURL: url("/tmp/active.md"))

        XCTAssertEqual(
            SaveAsConflict.conflictingTabTitle(
                destination: url("/tmp/other.md"), tabs: store.tabs, activeTabID: active),
            "other.md")
    }

    func testSaveAsOntoTheActiveTabsOwnFileIsNotAConflict() {
        let store = makeStore()
        let active = store.openTab(document: makeDocument("active"), fileURL: url("/tmp/active.md"))
        // Re-saving over yourself is an ordinary Save As; only OTHER tabs can be clobbered.
        XCTAssertNil(SaveAsConflict.conflictingTabTitle(
            destination: url("/tmp/active.md"), tabs: store.tabs, activeTabID: active))
    }

    func testSaveAsToAFreshPathIsNotAConflict() {
        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: url("/tmp/other.md"))
        let active = store.openTab(document: makeDocument(), fileURL: url("/tmp/active.md"))
        XCTAssertNil(SaveAsConflict.conflictingTabTitle(
            destination: url("/tmp/new.md"), tabs: store.tabs, activeTabID: active))
    }

    func testConflictMatchesNonStandardizedPaths() {
        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: url("/tmp/other.md"))
        let active = store.openTab(document: makeDocument(), fileURL: url("/tmp/active.md"))
        XCTAssertEqual(
            SaveAsConflict.conflictingTabTitle(
                destination: url("/tmp/sub/../other.md"), tabs: store.tabs, activeTabID: active),
            "other.md")
    }

    func testConflictMatchesTheSameFileReachedThroughASymlinkedParent() throws {
        // The same file spelled through a symlinked parent directory (the shape of /tmp →
        // /private/tmp). A plain string compare misses it and lets the clobbering save through.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-conflict-\(UUID().uuidString)")
        let realDir = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let linkDir = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let real = realDir.appendingPathComponent("note.md")
        try Data("hi".utf8).write(to: real)

        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: real)
        let active = store.openTab(document: makeDocument(), fileURL: url("/tmp/active.md"))

        XCTAssertEqual(
            SaveAsConflict.conflictingTabTitle(
                destination: linkDir.appendingPathComponent("note.md"),
                tabs: store.tabs, activeTabID: active),
            "note.md")
    }

    func testSavingOntoYourOwnFileIsAllowedEvenWhenItIsOpenInAnotherWindow() throws {
        // Nothing stops the same file being open in two windows. ⌘⇧S → keep the same name is the
        // most routine Save As there is; matching the OTHER window's tab by ID alone would refuse
        // it with no way to proceed. Excluding the active tab's own PATH is what prevents that.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared.md")
        try Data("hi".utf8).write(to: shared)

        let windowA = makeStore()
        let activeInA = windowA.openTab(document: makeDocument(), fileURL: shared)
        let windowB = makeStore()
        windowB.openTab(document: makeDocument(), fileURL: shared)

        XCTAssertNil(
            SaveAsConflict.conflictingTabTitle(
                destination: shared,
                tabs: windowA.tabs + windowB.tabs,
                activeTabID: activeInA),
            "Re-saving a document onto its own file must never be refused.")
    }

    func testConflictMatchesAFileReachedThroughASymlinkedFileName() throws {
        // canonicalPath resolves symlinked DIRECTORIES but hands back the link's own path for the
        // last component, and fileResourceIdentifier reports the link's OWN inode — so this case
        // rests entirely on both sides being put through resolvingSymlinksInPath() first.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("note.md")
        try Data("hi".utf8).write(to: real)
        let alias = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: alias)
        let active = store.openTab(document: makeDocument(), fileURL: url("/tmp/active.md"))

        XCTAssertEqual(
            SaveAsConflict.conflictingTabTitle(
                destination: real, tabs: store.tabs, activeTabID: active),
            "alias.md",
            "Writing note.md overwrites what the open alias.md tab is showing.")
    }

    func testConflictFoldsParentDirectoryCaseWhenTheFileIsNotOnDiskYet() throws {
        // Exercises the parent-canonicalization fallback specifically: neither URL exists, so there
        // is no file identity and no whole-path canonicalPath — only the DIRECTORY resolves.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-conflict-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lowercasedParent = root.appendingPathComponent("sub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: lowercasedParent.path),
            "Volume is case-sensitive; Sub/ and sub/ are distinct directories here.")

        let store = makeStore()
        let absent = sub.appendingPathComponent("ghost.md")
        store.openTab(document: makeDocument(), fileURL: absent)
        let active = store.openTab(document: makeDocument(), fileURL: url("/tmp/active.md"))

        XCTAssertEqual(
            SaveAsConflict.conflictingTabTitle(
                destination: lowercasedParent.appendingPathComponent("ghost.md"),
                tabs: store.tabs, activeTabID: active),
            "ghost.md")
    }

    func testHardLinksToOneInodeAreNotAConflict() throws {
        // Tempting to treat as the same file, but every write here is a safe-save (temp + rename),
        // which replaces the directory entry and BREAKS the link instead of overwriting shared
        // bytes — the other tab's file keeps its contents. Refusing would block a harmless save.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("note.md")
        try Data("original".utf8).write(to: first)
        let second = root.appendingPathComponent("same-inode.md")
        try FileManager.default.linkItem(at: first, to: second)

        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: first)
        let active = store.openTab(document: makeDocument(), fileURL: url("/tmp/active.md"))

        XCTAssertNil(SaveAsConflict.conflictingTabTitle(
            destination: second, tabs: store.tabs, activeTabID: active))

        // The premise, asserted rather than assumed. This covers the Data.write(.atomic) path used
        // by PDF/RTF export; NSDocument's save/autosave (the Markdown branch) was measured to break
        // the link the same way, but isn't reachable from a unit test.
        try Data("rewritten".utf8).write(to: second, options: .atomic)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "original")
    }

    func testConflictMatchesAPrivateTmpSpellingWhenNeitherSideExists() {
        // The exact regression the two-branch normalization warning exists to prevent: /tmp and
        // /private/tmp name one directory, and with NEITHER file on disk there is no file identity
        // to fall back on — only the parent canonicalization can fold them together.
        let name = "ghost-\(UUID().uuidString).md"
        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: url("/tmp/\(name)"))
        let active = store.openTab(document: makeDocument(), fileURL: url("/tmp/active.md"))

        XCTAssertEqual(
            SaveAsConflict.conflictingTabTitle(
                destination: url("/private/tmp/\(name)"), tabs: store.tabs, activeTabID: active),
            name)
    }

    func testConflictMatchesACaseOnlyDifferenceOnCaseInsensitiveVolumes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("Notes.md")
        try Data("hi".utf8).write(to: real)

        let otherCase = dir.appendingPathComponent("notes.md")
        // On a case-SENSITIVE volume these are genuinely two files and refusing would be wrong,
        // so the guarantee under test only exists where the volume folds case.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: otherCase.path),
            "Volume is case-sensitive; Notes.md and notes.md are distinct files here.")

        let store = makeStore()
        store.openTab(document: makeDocument(), fileURL: real)
        let active = store.openTab(document: makeDocument(), fileURL: url("/tmp/active.md"))

        XCTAssertEqual(
            SaveAsConflict.conflictingTabTitle(
                destination: otherCase, tabs: store.tabs, activeTabID: active),
            "Notes.md",
            "Saving over \u{201C}notes.md\u{201D} would overwrite the open \u{201C}Notes.md\u{201D}.")
    }

    func testUntitledTabsAreNeverTheConflictingTab() {
        let store = makeStore() // initial tab has no fileURL
        let active = store.openTab(document: makeDocument(), fileURL: url("/tmp/active.md"))
        // A tab with no file on disk can't be the thing we'd overwrite, whatever the destination.
        XCTAssertNil(SaveAsConflict.conflictingTabTitle(
            destination: url("/tmp/new.md"), tabs: store.tabs, activeTabID: active))
    }

    func testSavingAnUntitledActiveTabOntoAnotherTabsFileIsAConflict() {
        // The likeliest real path into this: an Untitled draft being given a name that happens to
        // be a file already open. The active tab having no URL must not disable the guard.
        let store = makeStore()
        store.openTab(document: makeDocument("existing"), fileURL: url("/tmp/other.md"))
        let untitled = store.tabs.first { $0.fileURL == nil }!.id
        store.selectTab(id: untitled)

        XCTAssertEqual(
            SaveAsConflict.conflictingTabTitle(
                destination: url("/tmp/other.md"), tabs: store.tabs, activeTabID: untitled),
            "other.md")
    }

    func testConflictSeesTabsFromEveryOpenWindow() {
        EditorTabStore.resetRegistryForTesting()
        // Each window owns its own store; a Save As in one window must still see the other's tabs,
        // because that window has no idea its file was rewritten underneath it.
        let windowA = makeStore()
        let windowB = makeStore()
        windowB.openTab(document: makeDocument("B's work"), fileURL: url("/tmp/in-window-b.md"))
        let activeInA = windowA.openTab(document: makeDocument(), fileURL: url("/tmp/in-window-a.md"))

        XCTAssertNil(
            SaveAsConflict.conflictingTabTitle(
                destination: url("/tmp/in-window-b.md"), tabs: windowA.tabs, activeTabID: activeInA),
            "Window A's own tabs alone cannot see the conflict — hence the app-wide registry.")
        XCTAssertEqual(
            SaveAsConflict.conflictingTabTitle(
                destination: url("/tmp/in-window-b.md"),
                tabs: EditorTabStore.allOpenTabs, activeTabID: activeInA),
            "in-window-b.md")
    }

    func testClosedWindowsDropOutOfTheAppWideTabRegistry() {
        EditorTabStore.resetRegistryForTesting()
        let path = "/tmp/registry-\(UUID().uuidString).md"
        autoreleasepool {
            let closing = makeStore()
            closing.openTab(document: makeDocument(), fileURL: url(path))
            XCTAssertTrue(EditorTabStore.allOpenTabs.contains { $0.fileURL?.path == path })
        }
        // The store is weakly held, so a closed window stops causing phantom conflicts.
        XCTAssertFalse(EditorTabStore.allOpenTabs.contains { $0.fileURL?.path == path })
    }
}

@MainActor
final class DocumentTabUnsavedWorkTests: XCTestCase {

    private let saveStatus = DocumentSaveStatus.shared

    // Regression guard for the "!text.isEmpty means dirty" bug: a clean, saved, NON-empty
    // file must NOT count as unsaved work (else it triggers spurious autosaves, a false
    // dirty dot, and a "save changes?" prompt on close).
    func testSavedCleanFileWithContentIsNotUnsavedWork() {
        let id = UUID()
        let doc = LineformDocument(text: "# Real saved file", id: id)
        saveStatus.markSaved(documentID: id, text: doc.text)
        let tab = DocumentTab(document: doc, fileURL: URL(fileURLWithPath: "/tmp/saved.md"))
        XCTAssertFalse(tab.hasUnsavedWork(documentSaveStatus: saveStatus))
    }

    func testEditedSavedFileIsUnsavedWork() {
        let id = UUID()
        let doc = LineformDocument(text: "edited since save", id: id)
        // Baseline saved as different text -> live text differs -> dirty.
        saveStatus.markSaved(documentID: id, text: "original")
        let tab = DocumentTab(document: doc, fileURL: URL(fileURLWithPath: "/tmp/edited.md"))
        XCTAssertTrue(tab.hasUnsavedWork(documentSaveStatus: saveStatus))
    }

    func testUntitledDocumentWithContentIsUnsavedWork() {
        let doc = LineformDocument(text: "typed but never saved", id: UUID())
        let tab = DocumentTab(document: doc, fileURL: nil)
        XCTAssertTrue(tab.hasUnsavedWork(documentSaveStatus: saveStatus))
    }

    func testUntitledEmptyDocumentIsNotUnsavedWork() {
        let doc = LineformDocument(text: "", id: UUID())
        let tab = DocumentTab(document: doc, fileURL: nil)
        XCTAssertFalse(tab.hasUnsavedWork(documentSaveStatus: saveStatus))
    }
}

@MainActor
final class PerTabUndoManagerTests: XCTestCase {

    private func makeCoordinator() -> Coordinator {
        Coordinator(
            text: .constant(""),
            textFormat: .constant(.markdown),
            plainTextConversion: .constant(nil)
        )
    }

    func testEachTabGetsADistinctUndoManager() {
        let coordinator = makeCoordinator()
        let textView = NSTextView()
        let a = UUID(), b = UUID()

        coordinator.currentTabID = a
        let managerA = coordinator.undoManager(for: textView)
        coordinator.currentTabID = b
        let managerB = coordinator.undoManager(for: textView)

        XCTAssertNotNil(managerA)
        XCTAssertNotNil(managerB)
        XCTAssertFalse(managerA === managerB) // isolated -> no cross-tab undo corruption
    }

    func testReturningToATabReusesItsUndoManager() {
        let coordinator = makeCoordinator()
        let textView = NSTextView()
        let a = UUID(), b = UUID()

        coordinator.currentTabID = a
        let firstVisit = coordinator.undoManager(for: textView)
        coordinator.currentTabID = b
        _ = coordinator.undoManager(for: textView)
        coordinator.currentTabID = a
        let secondVisit = coordinator.undoManager(for: textView)

        XCTAssertTrue(firstVisit === secondVisit) // history preserved across a round trip
    }

    func testClosedTabUndoManagerIsReleased() {
        let coordinator = makeCoordinator()
        let textView = NSTextView()
        let a = UUID(), b = UUID()

        coordinator.currentTabID = a
        let original = coordinator.undoManager(for: textView)
        // Tab `a` closes; only `b` remains open.
        coordinator.retainUndoManagers(for: [b])
        coordinator.currentTabID = a
        let afterClose = coordinator.undoManager(for: textView)

        XCTAssertFalse(original === afterClose) // stale manager dropped, a fresh one minted
    }

    func testNilTabFallsBackToResponderChain() {
        let coordinator = makeCoordinator()
        let textView = NSTextView()
        coordinator.currentTabID = nil
        // nil (no active tab) must return nil so AppKit uses the responder-chain manager,
        // never recurse back into the text view's own undoManager.
        XCTAssertNil(coordinator.undoManager(for: textView))
    }
}

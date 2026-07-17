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

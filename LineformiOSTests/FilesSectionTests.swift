import Foundation
import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The Files section's views: which actions a row offers, the sort menu, the date a row shows,
/// the empty and unavailable states' wording, and a hosted render of the roots.
@MainActor
final class FilesSectionTests: XCTestCase {
    private var folder: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var window: UIWindow?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-section-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "FilesSectionTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    func testFolderHasNoDelete() async throws {
        let sub = folder.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("Inside.md"))
        let operations = RecordingFileOperations(trashFolder: folder)
        let store = makeStore(operations: operations)
        store.setVisible(true)
        await store.scanIfVisible()
        let folderItem = try XCTUnwrap(store.root(.device)?.items.first)
        XCTAssertTrue(folderItem.isDirectory)

        do {
            try await store.trash(folderItem)
            XCTFail("a folder was trashed")
        } catch {
            XCTAssertEqual(error as? FilesStoreError, .folderCannotBeDeleted)
        }
        XCTAssertEqual(operations.trashed, [], "a folder never reaches the Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sub.path))

        XCTAssertEqual(FilesRowAction.swipeActions(for: folderItem), [], "no swipe actions on a folder")
        XCTAssertEqual(FilesRowAction.menuActions(for: folderItem), [.rename], "a folder can be renamed, never deleted")
        let fileItem = try XCTUnwrap(store.children(of: sub)?.first)
        XCTAssertEqual(FilesRowAction.swipeActions(for: fileItem), [.rename, .delete])
        XCTAssertEqual(FilesRowAction.menuActions(for: fileItem), [.rename, .delete])
    }

    func testSortMenuUsesThePackageTitles() throws {
        try skipUnlessEnglishInterface()
        // pinned-en
        XCTAssertEqual(FilesSection.sortOptions.map(\.title), ["Name", "Date Created", "Date Modified"])
        XCTAssertEqual(FilesSection.sortMenuTitle, "Sort folders by")
        XCTAssertEqual(FilesSection.hiddenFoldersTitle, "Show Hidden Folders")
    }

    func testRowShowsTheDateOnlyWhenSortedByDate() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let modified = Date(timeIntervalSince1970: 2_000_000)
        let file = OutlineFileTreeItem(
            url: folder.appendingPathComponent("A.md"), name: "A.md", isDirectory: false, children: [],
            createdAt: created, modifiedAt: modified
        )
        let directory = OutlineFileTreeItem(
            url: folder.appendingPathComponent("D"), name: "D", isDirectory: true, children: [],
            createdAt: created, modifiedAt: modified
        )
        XCTAssertNil(FilesRow.shownDate(for: file, sortOrder: .name))
        XCTAssertEqual(FilesRow.shownDate(for: file, sortOrder: .dateModified), modified)
        XCTAssertEqual(FilesRow.shownDate(for: file, sortOrder: .dateCreated), created,
                       "the date the list is in order of")
        XCTAssertNil(FilesRow.shownDate(for: directory, sortOrder: .dateModified), "folders show no date")
        XCTAssertEqual(FilesRow.systemImage(for: file), "doc.text")
        XCTAssertEqual(FilesRow.systemImage(for: directory), "folder")
    }

    func testStatesUseTheMacWording() throws {
        try skipUnlessEnglishInterface()
        // pinned-en
        XCTAssertEqual(FilesSection.deleteTitle(for: "Notes.md"), "Delete “Notes.md”?")
        XCTAssertEqual(FilesSection.deleteMessage, "It will be moved to the Trash.")
        XCTAssertEqual(FilesSection.renameTitle(isDirectory: false), "Rename File")
        XCTAssertEqual(FilesSection.renameTitle(isDirectory: true), "Rename Folder")
        XCTAssertEqual(FilesSection.newDocumentLabel(in: "iCloud"), "New Document in iCloud")
        for text in [FilesSection.deleteMessage, FilesSection.newDocumentLabel(in: "iCloud")] {
            XCTAssertFalse(text.contains("Mac"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("sidebar"), text)
        }
    }

    func testPlaceholderShowsItsRealName() async throws {
        try Data("cloud".utf8).write(to: folder.appendingPathComponent(".Evicted.md.icloud"))
        let store = makeStore()
        store.setVisible(true)
        await store.scanIfVisible()
        let item = try XCTUnwrap(store.root(.device)?.items.first)
        XCTAssertEqual(item.name, "Evicted.md")
        XCTAssertEqual(item.url.lastPathComponent, "Evicted.md", "opening it downloads the real file")
    }

    func testHostedSectionShowsRootsAndRows() async throws {
        try Data("hello".utf8).write(to: folder.appendingPathComponent("Hello.md"))
        let store = makeStore()
        let document = OpenDocument(folderProvider: { [folder] in folder! }, ubiquitousItems: FakeUbiquitousItems(arrivingText: nil))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        // The word menu holds the store visible while Files is on screen (`WordMenu`).
        window.rootViewController = UIHostingController(
            rootView: WordMenu(
                document: document, editor: RecordingEditorCommands(text: ""), files: store,
                settings: AppSettings(defaults: defaults), profile: .original, exportCommands: nil, mode: .write,
                aiStore: nil, initialPage: .files,
                onClose: {}, onThemes: {}, onReadAloud: {}, onShowHistoryPassage: { _ in }, onAskAI: {}
            )
        )
        window.makeKeyAndVisible()
        self.window = window

        let deadline = Date().addingTimeInterval(5)
        while Self.find("Hello", in: window) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
        }
        XCTAssertTrue(store.isVisible, "showing Files makes it visible")
        XCTAssertNotNil(Self.find("Hello", in: window), "a document card")
        // pinned-en: the roots' and buttons' English names. Only the mockup's rows (2026-11-24):
        // no Workspace, no Open from Files…, no New Document or New Folder rows; each root's "+".
        if interfaceLanguage == "en" {
            XCTAssertNotNil(Self.find("On My iPhone", in: window))
            XCTAssertNil(Self.find("Recent", in: window), "Recent shows documents inside folders; a root document is already a card")
            XCTAssertNotNil(Self.find("New Document in On My iPhone", in: window), "the root's + makes a document there")
            XCTAssertNil(Self.find("Workspace", in: window), "the Workspace never shows on iPhone")
            XCTAssertNil(Self.find("Choose", in: window))
            XCTAssertNil(Self.find("Open from Files…", in: window))
            XCTAssertNil(Self.find("New Folder", in: window))
        }

        window.isHidden = true
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(store.isVisible, "the menu going away stops the scans")
    }

    /// Owner review 4: the iCloud heading lists its own documents (they showed only in Recent),
    /// and an empty root is its heading and "+" alone, with no "No Markdown files".
    func testHostedICloudRootShowsItsDocumentsAndEmptyRootHasNoMessage() async throws {
        let iCloud = folder.appendingPathComponent("Container/Documents", isDirectory: true)
        let device = folder.appendingPathComponent("Device", isDirectory: true)
        try FileManager.default.createDirectory(at: iCloud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        try Data("cloud draft".utf8).write(to: iCloud.appendingPathComponent("Cloud draft.md"))
        let store = FilesStore(
            defaults: defaults, iCloudFolder: { iCloud }, deviceFolder: device,
            bookmarks: FakeBookmarks(resolvesTo: nil), fileOperations: RecordingFileOperations()
        )
        let document = OpenDocument(folderProvider: { device }, ubiquitousItems: FakeUbiquitousItems(arrivingText: nil))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: WordMenu(
                document: document, editor: RecordingEditorCommands(text: ""), files: store,
                settings: AppSettings(defaults: defaults), profile: .original, exportCommands: nil, mode: .write,
                aiStore: nil, initialPage: .files,
                onClose: {}, onThemes: {}, onReadAloud: {}, onShowHistoryPassage: { _ in }, onAskAI: {}
            )
        )
        window.makeKeyAndVisible()
        self.window = window

        let deadline = Date().addingTimeInterval(5)
        while Self.count("Cloud draft", in: window) < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
        }
        XCTAssertNotNil(store.root(.icloud))
        XCTAssertEqual(Self.count("Cloud draft", in: window), 1, "a card under iCloud, never repeated in Recent")
        if interfaceLanguage == "en" {
            XCTAssertNotNil(Self.find("New Document in On My iPhone", in: window), "the empty root keeps its +")
            XCTAssertNil(Self.find("No Markdown files", in: window), "no empty-state text in a root")
        }

        window.isHidden = true
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Helpers

    private func makeStore(operations: any FilesFileOperating = RecordingFileOperations()) -> FilesStore {
        FilesStore(
            defaults: defaults,
            iCloudFolder: { nil },
            deviceFolder: folder,
            bookmarks: FakeBookmarks(resolvesTo: nil),
            fileOperations: operations
        )
    }

    /// How many distinct accessibility elements carry exactly `label` (a card's ⋯, "More actions
    /// for …", does not count).
    private static func count(_ label: String, in root: NSObject) -> Int {
        var seen: Set<ObjectIdentifier> = []
        func walk(_ node: NSObject, depth: Int) -> Int {
            guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return 0 }
            if node.accessibilityLabel == label, !(node is UIWindow) { return 1 }
            var children: [NSObject] = []
            if let view = node as? UIView { children += view.subviews }
            if let elements = node.accessibilityElements as? [NSObject] { children += elements }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = node.accessibilityElement(at: index) as? NSObject { children.append(element) }
                }
            }
            return children.filter { $0 !== node }.reduce(0) { $0 + walk($1, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }

    /// The first accessibility element whose label contains `label`.
    private static func find(_ label: String, in root: NSObject, depth: Int = 0) -> NSObject? {
        guard depth < 60 else { return nil }
        if let own = root.accessibilityLabel, own.contains(label), !(root is UIWindow) { return root }
        var children: [NSObject] = []
        if let view = root as? UIView { children += view.subviews }
        if let elements = root.accessibilityElements as? [NSObject] { children += elements }
        let count = root.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let element = root.accessibilityElement(at: index) as? NSObject { children.append(element) }
            }
        }
        for child in children where child !== root {
            if let found = find(label, in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}

import Foundation
import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The Menu sheet's Search: this document's matches (case- and diacritic-insensitive), file-name
/// and file-content matches across the Files roots, the filter, and Replace / Replace All, which
/// act on this document only. Every file lives in a temporary folder; nothing touches iCloud.
@MainActor
final class SearchTests: XCTestCase {
    private var folder: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var window: UIWindow?
    private var keepers: [ModePositionKeeper] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "SearchTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - In this document

    func testInDocumentMatchesAccentInsensitive() throws {
        // pinned-en
        XCTAssertEqual(SearchFilter.allCases.map(\.title), ["All", "In document", "Files"])
        XCTAssertEqual(SearchFilter.allCases.map(\.rawValue), ["all", "document", "files"], "identity, never localized")
        XCTAssertEqual(SearchRow.inDocumentIndicator, "In document")

        let text = "Café crème\nCAFE noir\nand a cafe"
        let commands = RecordingEditorCommands(text: text)
        var announced: [String] = []
        let controller = makeController(commands, announce: { announced.append($0) })

        XCTAssertEqual(controller.rows, [], "an empty query shows the hint, not results")
        controller.setQuery("cafe")
        let rows = controller.rows
        XCTAssertEqual(rows.count, 3, "case- and diacritic-insensitive: Café, CAFE and cafe")
        XCTAssertEqual(rows.map(\.indicator), ["In document", "In document", "In document"])
        XCTAssertEqual(rows.compactMap(\.snippet?.lineText), ["Café crème", "CAFE noir", "and a cafe"])
        let ranges = EditorSearchResolver.matches(in: text, query: "cafe")
        XCTAssertEqual(rows.map(\.kind), ranges.map { SearchRow.Kind.inDocument($0) })
        XCTAssertEqual(controller.activeIndex, 0)
        XCTAssertEqual(controller.statusText, "3 matches")

        // The status is announced once, and again only when it changes.
        XCTAssertEqual(announced, ["Search for cafe. 3 matches. Result 1 of 3."])
        controller.textChanged()
        XCTAssertEqual(announced.count, 1, "an unchanged status is not re-announced")

        // No regex: a pattern is literal text.
        controller.setQuery("c.fe")
        XCTAssertEqual(controller.rows, [])
        XCTAssertEqual(controller.statusText, "No matches")

        // Tapping an in-document match closes the sheet, then selects it and brings it into view.
        controller.setQuery("cafe")
        var events: [String] = []
        commands.onSelect = { events.append("select \($0.location)") }
        controller.activate(rows[1], dismiss: { events.append("dismiss") })
        XCTAssertEqual(events, ["dismiss", "select \(ranges[1].location)"])
        XCTAssertEqual(commands.selected, [ranges[1]])
        XCTAssertEqual(commands.scrolled, [ranges[1]])
    }

    func testReplaceAllOneUndoKeepsCRLF() throws {
        let (commands, editor) = try liveCommands(text: "café\r\nCafe\r\nCAFÉ au lait")
        let undo = try XCTUnwrap(editor.undoManager)
        undo.removeAllActions()
        let controller = makeController(commands)
        controller.setQuery("cafe")
        XCTAssertEqual(controller.matches.count, 3)
        controller.replacement = "tea"
        XCTAssertTrue(controller.canReplaceAll)

        controller.replaceAll()
        XCTAssertEqual(commands.currentText, "tea\r\ntea\r\ntea au lait")
        XCTAssertEqual(commands.currentText.components(separatedBy: "\r\n").count, 3, "every CRLF survives")
        XCTAssertEqual(controller.matches, [])
        XCTAssertNil(controller.activeIndex)

        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(commands.currentText, "café\r\nCafe\r\nCAFÉ au lait", "one undo restores every replacement")
        XCTAssertFalse(undo.canUndo, "Replace All was one undo step")
    }

    func testReplaceReResolvesLiveText() {
        let commands = RecordingEditorCommands(text: "one cat two cat")
        let controller = makeController(commands)
        controller.setQuery("cat")
        controller.replacement = "dog"
        XCTAssertEqual(controller.activeIndex, 0)
        XCTAssertEqual(controller.matches.first, NSRange(location: 4, length: 3))

        // The text moved under the search (an edit the search has not refreshed for yet).
        commands.text = "a one cat two cat"
        controller.replace()
        XCTAssertTrue(commands.replaced.isEmpty, "a stale range is never replaced")
        XCTAssertEqual(commands.text, "a one cat two cat")
        XCTAssertEqual(controller.matches, [NSRange(location: 6, length: 3), NSRange(location: 14, length: 3)],
                       "it re-resolved against the live text")
        XCTAssertEqual(controller.activeIndex, 0)

        controller.replace()
        XCTAssertEqual(commands.text, "a one dog two cat")
        XCTAssertEqual(controller.activeIndex, 0, "Replace moved on to the next match")
        XCTAssertEqual(controller.matches, [NSRange(location: 14, length: 3)])
    }

    func testPriorInsertionsClearedOnReaim() {
        let commands = RecordingEditorCommands(text: "the log and the log")
        let controller = makeController(commands)
        controller.setQuery("log")
        controller.replacement = "logs"

        controller.replace()
        XCTAssertEqual(commands.text, "the logs and the log")
        XCTAssertEqual(controller.activeIndex, 1)
        controller.replace()
        XCTAssertEqual(commands.text, "the logs and the logs")
        XCTAssertNil(controller.activeIndex, "the only matches left are inside text Replace wrote")
        XCTAssertEqual(controller.replacementInsertions.count, 2)
        XCTAssertFalse(controller.canReplace)

        // The nil is a decision: a refresh never auto-selects a match inside a replacement.
        controller.textChanged()
        XCTAssertNil(controller.activeIndex)
        controller.replace()
        XCTAssertEqual(commands.text, "the logs and the logs", "no logss cascade")

        // Re-aiming (a new query) clears the insertions and selects again.
        controller.setQuery("lo")
        XCTAssertEqual(controller.replacementInsertions, [])
        controller.setQuery("log")
        XCTAssertEqual(controller.replacementInsertions, [])
        XCTAssertEqual(controller.activeIndex, 0)

        // So does a filter change.
        controller.replace()
        XCTAssertFalse(controller.replacementInsertions.isEmpty)
        controller.setFilter(.document)
        XCTAssertEqual(controller.replacementInsertions, [])
    }

    // MARK: - Across files

    func testFileResultsLatestQueryWins() async throws {
        // A 5,000-file tree, injected: nothing on disk, nothing downloaded.
        let tree: [OutlineFileTreeItem] = (0..<50).map { folderIndex in
            let sub = folder.appendingPathComponent("Folder \(folderIndex)", isDirectory: true)
            return OutlineFileTreeItem(
                url: sub, name: sub.lastPathComponent, isDirectory: true,
                children: (0..<100).map { fileIndex in
                    let url = sub.appendingPathComponent("Note \(folderIndex)-\(fileIndex).md")
                    return OutlineFileTreeItem(url: url, name: url.lastPathComponent, isDirectory: false, children: [])
                }
            )
        }
        let reader = CorpusReader { url in
            let name = url.deletingPathExtension().lastPathComponent
            if name.hasSuffix("-7") { return "an alpha line" }
            if name.hasSuffix("-42") { return "a beta line" }
            if name.hasSuffix("-99") { return nil }  // evicted: never read
            return "nothing to see"
        }
        let files = makeStore(scanner: { _, _, _ in tree })
        let controller = makeController(
            RecordingEditorCommands(text: "no match here"), files: files,
            fileSearch: CrossFileSearchModel(reader: reader, debounceInterval: 0.05)
        )

        let started = Date()
        controller.setQuery("alpha")
        controller.setQuery("beta")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "typing never waits for the files")
        await controller.pendingScan?.value
        await controller.pendingFileSearch?.value

        let contentFiles = Set(controller.rows.filter { if case .fileContent = $0.kind { true } else { false } }.map(\.indicator))
        XCTAssertEqual(contentFiles.count, 50, "one beta file per folder")
        XCTAssertTrue(contentFiles.allSatisfy { $0.hasSuffix("-42.md") }, "only the latest query's results")
        XCTAssertFalse(reader.readOnMainThread, "files are read off the main thread")
        XCTAssertTrue(files.isVisible, "search is a reason to scan")

        // Results come in order: this document, then file names, then contents.
        controller.setQuery("Note 3-42")
        await controller.pendingFileSearch?.value
        let kinds = controller.rows.map(\.kind)
        XCTAssertEqual(kinds.first, .fileName, "the file name match")
        XCTAssertEqual(controller.rows.first?.indicator, "Note 3-42.md")
    }

    func testEvictedAndLargeFilesSkipped() async throws {
        try Data("a small needle".utf8).write(to: folder.appendingPathComponent("Small.md"))
        var big = String(repeating: "x", count: 1_048_600)
        big += " needle"
        try Data(big.utf8).write(to: folder.appendingPathComponent("Big.md"))
        // An iCloud placeholder: listed under its real name, with no local contents.
        try Data("placeholder".utf8).write(to: folder.appendingPathComponent(".Gone needle.md.icloud"))
        let reader = ThreadRecordingReader()
        let files = makeStore()
        let controller = makeController(
            RecordingEditorCommands(text: ""), files: files,
            fileSearch: CrossFileSearchModel(reader: reader, debounceInterval: 0)
        )

        controller.setQuery("needle")
        await controller.pendingScan?.value
        await controller.pendingFileSearch?.value

        let content = controller.rows.filter { if case .fileContent = $0.kind { true } else { false } }
        XCTAssertEqual(content.map(\.indicator), ["Small.md"], "the >1 MB file and the evicted file are not read")
        let names = controller.rows.filter { $0.kind == .fileName }.map(\.indicator)
        XCTAssertEqual(names, ["Gone needle.md"], "an evicted file still matches by name")
        XCTAssertFalse(reader.readOnMainThread)
        XCTAssertGreaterThan(reader.reads, 0)
    }

    func testTapFileResultOpensAndSelects() async throws {
        let notes = folder.appendingPathComponent("Notes.md")
        try Data("first needle\nsecond needle\nthird needle".utf8).write(to: notes)
        let saveFolder = folder.appendingPathComponent("Saves", isDirectory: true)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let document = OpenDocument(folderProvider: { saveFolder }, ubiquitousItems: FakeUbiquitousItems(arrivingText: nil))
        await document.prepare()
        let commands = RecordingEditorCommands(text: "")
        commands.liveText = { document.text }
        let files = makeStore()
        let controller = SearchController(
            editor: commands, files: files, currentURL: { document.url },
            fileSearch: CrossFileSearchModel(debounceInterval: 0),
            open: SearchController.opener(for: document),
            announce: { _ in }
        )

        controller.setQuery("needle")
        await controller.pendingScan?.value
        await controller.pendingFileSearch?.value
        let content = controller.rows.filter { if case .fileContent = $0.kind { true } else { false } }
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content.map(\.indicator), ["Notes.md", "Notes.md", "Notes.md"])

        // The file changed since the search ran: a line went in above the hits.
        try Data("zero needle\nfirst needle\nsecond needle\nthird needle".utf8).write(to: notes)
        let tapped = content[1]
        guard case .fileContent(let shownRange) = tapped.kind else { return XCTFail("not a content row") }
        var dismissed = false
        await controller.activate(tapped, dismiss: { dismissed = true })?.value

        XCTAssertTrue(dismissed)
        XCTAssertEqual(document.url?.resolvingSymlinksInPath(), notes.resolvingSymlinksInPath(), "the file opened")
        let opened = EditorSearchResolver.matches(in: document.text, query: "needle")
        let expected = try XCTUnwrap(opened.first { $0.location >= shownRange.location })
        XCTAssertEqual(commands.selected, [expected], "re-resolved against the opened text: the first hit at or after the snippet")
        XCTAssertEqual(commands.scrolled, [expected])

        // A file-name match opens the file and selects nothing.
        let other = folder.appendingPathComponent("needle list.md")
        try Data("nothing".utf8).write(to: other)
        controller.setQuery("needle list")
        await controller.pendingScan?.value
        await files.scanIfVisible()
        controller.rootsChanged()
        await controller.pendingFileSearch?.value
        let nameRow = try XCTUnwrap(controller.rows.first { $0.kind == .fileName })
        commands.selected = []
        await controller.activate(nameRow, dismiss: {})?.value
        XCTAssertEqual(document.url?.lastPathComponent, "needle list.md")
        XCTAssertEqual(commands.selected, [])

        // The open document is not listed among the file results.
        controller.setQuery("nothing")
        await controller.pendingFileSearch?.value
        XCTAssertFalse(controller.rows.contains { $0.url?.lastPathComponent == "needle list.md" && $0.kind != .fileName },
                       "the open document's matches show as In document, not twice")
    }

    func testNoCrossFileReplace() async throws {
        let other = folder.appendingPathComponent("Other.md")
        try Data("cat in another file".utf8).write(to: other)
        let commands = RecordingEditorCommands(text: "a cat here")
        let controller = makeController(commands, files: makeStore(), fileSearch: CrossFileSearchModel(debounceInterval: 0))
        controller.setQuery("cat")
        await controller.pendingScan?.value
        await controller.pendingFileSearch?.value
        XCTAssertTrue(controller.rows.contains { if case .fileContent = $0.kind { true } else { false } })
        controller.replacement = "dog"

        XCTAssertTrue(SearchSection.showsReplaceRow(for: .all))
        XCTAssertTrue(SearchSection.showsReplaceRow(for: .document))
        XCTAssertFalse(SearchSection.showsReplaceRow(for: .files), "Files results offer no replace")

        controller.setFilter(.files)
        XCTAssertFalse(controller.canReplace)
        XCTAssertFalse(controller.canReplaceAll)
        XCTAssertTrue(controller.rows.allSatisfy { $0.url != nil }, "Files shows only file results")
        controller.replaceAll()
        controller.replace()
        XCTAssertTrue(commands.replacedAll.isEmpty)
        XCTAssertTrue(commands.replaced.isEmpty)

        controller.setFilter(.all)
        controller.replaceAll()
        XCTAssertEqual(commands.text, "a dog here", "Replace All changes this document")
        XCTAssertEqual(commands.replacedAll.map(\.ranges), [[NSRange(location: 2, length: 3)]], "only its own ranges")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "cat in another file", "other files are never written")
    }

    // MARK: - Review fixes

    /// What the writer typed reaches the controller as it is typed: a tap on Replace or Replace
    /// All straight after the last keystroke, with no view update between them, uses the new
    /// query and replacement. "cats" must never replace the "cat" in "category".
    func testFieldsReachTheControllerBeforeTheNextViewUpdate() async throws {
        for button in ["Replace All", "Replace"] {
            let commands = RecordingEditorCommands(text: "category cats")
            let folder = self.folder!
            let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: FakeUbiquitousItems(arrivingText: nil))
            let window = try hostSearch(document: document, commands: commands)
            try await settle(window) { !Self.textFields(in: window).isEmpty }

            let query = try XCTUnwrap(Self.textFields(in: window).first, "the search field")
            query.becomeFirstResponder()
            query.insertText("cat")
            try await settle(window) { Self.textFields(in: window).count == 2 && Self.element(button, in: window) != nil }
            let replacement = try XCTUnwrap(Self.textFields(in: window).last, "the replacement field")
            let tap = try XCTUnwrap(Self.element(button, in: window), button)

            // The last keystrokes, then the tap, in one main-thread turn.
            replacement.becomeFirstResponder()
            replacement.insertText("dogs")
            query.becomeFirstResponder()
            query.insertText("s")
            XCTAssertTrue(tap.accessibilityActivate(), "\(button) was tapped")

            XCTAssertEqual(commands.text, "category dogs", "\(button) used the typed query and replacement")
            window.isHidden = true
        }
    }

    /// A tap on a file result outlives the sheet: the match is selected once the file opens, even
    /// though the section and its controller are gone by then.
    func testFileResultSelectsAfterTheControllerIsReleased() async throws {
        let commands = RecordingEditorCommands(text: "")
        let opened = "zero\nthe needle here"
        let gate = OpenGate()
        var controller: SearchController? = SearchController(
            editor: commands, files: nil, currentURL: { nil },
            fileSearch: CrossFileSearchModel(debounceInterval: 0),
            open: { _ in
                await gate.wait()
                commands.text = opened
                return opened
            },
            announce: { _ in }
        )
        weak var released = controller
        controller?.setQuery("needle")
        let row = SearchRow(
            id: "content", kind: .fileContent(NSRange(location: 9, length: 6)),
            url: folder.appendingPathComponent("Other.md"), snippet: nil, indicator: "Other.md"
        )
        var dismissed = false
        let task = controller?.activate(row, dismiss: { dismissed = true })
        controller = nil
        XCTAssertNil(released, "the sheet and its controller are gone before the file opens")
        XCTAssertTrue(dismissed)

        gate.open()
        await task?.value
        let expected = NSRange(location: 9, length: 6)
        XCTAssertEqual(commands.selected, [expected], "the match is still selected")
        XCTAssertEqual(commands.scrolled, [expected])
    }

    // MARK: - Helpers

    private func makeController(
        _ commands: any EditorCommands,
        files: FilesStore? = nil,
        fileSearch: CrossFileSearchModel = CrossFileSearchModel(debounceInterval: 0),
        announce: @escaping @MainActor (String) -> Void = { _ in }
    ) -> SearchController {
        SearchController(
            editor: commands, files: files, currentURL: { nil }, fileSearch: fileSearch,
            open: { _ in nil }, announce: announce
        )
    }

    private func makeStore(scanner: FilesStore.Scanner? = nil) -> FilesStore {
        FilesStore(
            defaults: defaults,
            iCloudFolder: { nil },
            deviceFolder: folder,
            bookmarks: FakeBookmarks(resolvesTo: nil),
            fileOperations: RecordingFileOperations(),
            scanner: scanner ?? FilesStore.liveScanner
        )
    }

    private func hostSearch(document: OpenDocument, commands: RecordingEditorCommands) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: SearchSection(document: document, editor: commands, files: makeStore(), onDismiss: {})
        )
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func settle(_ window: UIWindow, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try await Task.sleep(for: .milliseconds(30))
            window.layoutIfNeeded()
        } while !condition() && Date() < deadline
    }

    /// The text fields on screen, top to bottom.
    private static func textFields(in view: UIView) -> [UITextField] {
        var found: [UITextField] = []
        func walk(_ view: UIView) {
            if let field = view as? UITextField { found.append(field) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }

    /// The button labelled exactly `label`.
    private static func element(_ label: String, in root: NSObject, depth: Int = 0) -> NSObject? {
        guard depth < 60 else { return nil }
        if root.accessibilityLabel == label, root.accessibilityTraits.contains(.button), !(root is UIWindow) { return root }
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
            if let found = element(label, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func liveCommands(text: String) throws -> (LiveEditorCommands, LineformTextView) {
        let editor = LineformTextView.make(profile: .original)
        editor.setDocumentText(text)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        editor.frame = CGRect(x: 0, y: 0, width: 393, height: 800)
        host.view.addSubview(editor)
        window.isHidden = false
        self.window = window
        let keeper = ModePositionKeeper()
        keeper.editor = editor
        keepers.append(keeper)
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: FakeUbiquitousItems(arrivingText: nil))
        return (LiveEditorCommands(positionKeeper: keeper, document: document, mode: .write), editor)
    }
}

/// Holds an open until the test lets it finish.
@MainActor
final class OpenGate {
    private var isOpen = false
    private var waiting: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        isOpen = true
        waiting?.resume()
        waiting = nil
    }
}

/// An in-memory corpus, read off the main thread.
final class CorpusReader: CrossFileSearchFileReading, @unchecked Sendable {
    private let lock = NSLock()
    private let text: @Sendable (URL) -> String?
    private var sawMainThread = false

    init(text: @escaping @Sendable (URL) -> String?) { self.text = text }

    var readOnMainThread: Bool { lock.withLock { sawMainThread } }

    func readSearchableText(at url: URL) -> String? {
        if Thread.isMainThread { lock.withLock { sawMainThread = true } }
        return text(url)
    }
}

/// The production reader, recording where it ran.
final class ThreadRecordingReader: CrossFileSearchFileReading, @unchecked Sendable {
    private let lock = NSLock()
    private let inner = CrossFileSearchFileReader()
    private var sawMainThread = false
    private var count = 0

    var readOnMainThread: Bool { lock.withLock { sawMainThread } }
    var reads: Int { lock.withLock { count } }

    func readSearchableText(at url: URL) -> String? {
        lock.withLock {
            count += 1
            if Thread.isMainThread { sawMainThread = true }
        }
        return inner.readSearchableText(at: url)
    }
}

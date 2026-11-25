import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The word menu: its words in order and how each leaves or opens, the status line, the ⋯
/// button, its back-one-page navigation, the card grid rule, the palette's contrast, and the
/// editor commands the pages use (each one undo step). Every document saves into its own
/// temporary folder.
@MainActor
final class WordMenuTests: XCTestCase {
    private var folder: URL!
    private var window: UIWindow?
    private var defaultsSuite: String?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("word-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        if let defaultsSuite { UserDefaults().removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: folder)
    }

    func testWordsInSpecOrder() throws {
        XCTAssertEqual(WordMenuItem.allCases, [
            .files, .outline, .basics, .themes, .settings, .exportPrint, .readAloud, .history, .connectAI, .about,
        ])
        XCTAssertEqual(WordMenuItem.allCases.map(\.style), [
            .large, .large, .large, .largeGrey, .largeGrey, .small, .small, .small, .small, .small,
        ])
        // pinned-en: the Mac's strings where they match, under the test plan's English.
        if interfaceLanguage == "en" {
            XCTAssertEqual(WordMenuItem.allCases.map(\.title), [
                "Files", "Outline", "Markdown Basics", "Themes", "Settings",
                "Export & Print", "Read Aloud", "History", "Connect Your AI", "About Lineform",
            ])
        }
        // History is listed only while the document has history.
        XCTAssertFalse(WordMenuItem.visible(hasHistory: false).contains(.history))
        XCTAssertTrue(WordMenuItem.visible(hasHistory: true).contains(.history))
        // Themes and Read Aloud leave the menu; every other word opens a page.
        XCTAssertEqual(WordMenuItem.themes.destination, .themesSheet)
        XCTAssertEqual(WordMenuItem.readAloud.destination, .readAloud)
        XCTAssertNotNil(WordMenuItem.themes.accessibilityHint)
        XCTAssertNil(WordMenuItem.files.accessibilityHint)
        XCTAssertEqual(WordMenuItem.history.destination, .page(.history))
        // No iPhone word names a Mac or a sidebar.
        for item in WordMenuItem.allCases {
            XCTAssertFalse(item.title.contains("Mac"), item.title)
            XCTAssertFalse(item.title.localizedCaseInsensitiveContains("sidebar"), item.title)
        }
    }

    /// ✕ on the word list closes; ← goes back one page at a time (folder → Files → words).
    func testNavigationGoesBackOnePageAtATime() {
        var navigation = WordMenuNavigation()
        XCTAssertTrue(navigation.isOnWordList)
        navigation.push(.files)
        navigation.push(.folder(FilesFolderRoute(url: folder, title: "Journal")))
        XCTAssertEqual(navigation.top?.title, "Journal")
        XCTAssertTrue(navigation.top?.showsFiles == true, "a folder keeps the Files store on screen")
        XCTAssertTrue(navigation.back())
        XCTAssertEqual(navigation.top, .files)
        XCTAssertTrue(navigation.back())
        XCTAssertTrue(navigation.isOnWordList)
        XCTAssertFalse(navigation.back(), "on the word list the corner button closes the menu")
        XCTAssertFalse(WordMenuPage.outline.showsFiles)
    }

    /// The way back (2026-11-24 review): the session keeps the page, Files' search and the scroll
    /// offsets; a card or search result marks it, and reopening clears the mark. VoiceOver reads
    /// "Back to Files" (or the folder's name).
    func testSessionKeepsWhereTheWriterWas() throws {
        try skipUnlessEnglishInterface()
        let session = WordMenuSession()
        session.navigation.push(.files)
        session.filesQuery = "export"
        session.filesScope = .openDocument
        session.scrollOffsets[1] = 420
        XCTAssertFalse(session.openedDocument)
        session.noteOpenedDocument()
        XCTAssertTrue(session.openedDocument, "a card or search result opened a document")
        XCTAssertEqual(session.resumeAccessibilityLabel, "Back to Files")
        session.navigation.push(.folder(FilesFolderRoute(url: folder, title: "Journal")))
        XCTAssertEqual(session.resumeAccessibilityLabel, "Back to Journal")
        session.resumed()
        XCTAssertFalse(session.openedDocument)
        XCTAssertEqual(session.filesQuery, "export")
        XCTAssertEqual(session.filesScope, .openDocument)
        XCTAssertEqual(session.scrollOffsets[1], 420)
        XCTAssertEqual(DocumentScreen.resumeButtonDuration, .seconds(4))
    }

    /// A lone card spans the width; two or more are always half width.
    func testCardGridRule() {
        XCTAssertEqual(WordMenuCardGrid<SearchResultCard, EmptyView>.columnCount(for: 1), 1)
        XCTAssertEqual(WordMenuCardGrid<SearchResultCard, EmptyView>.columnCount(for: 2), 2)
        XCTAssertEqual(WordMenuCardGrid<SearchResultCard, EmptyView>.columnCount(for: 3), 2)
        XCTAssertEqual(WordMenuMetrics.cardHeight, 150)
    }

    /// Every ink of the menu clears its ratio on every surface it is drawn on, light and dark.
    func testPaletteContrast() {
        for isDark in [false, true] {
            let palette = WordMenuPalette(isDark: isDark)
            for entry in palette.entries {
                let ratio = Theme.contrastRatio(entry.color, entry.surface)
                XCTAssertGreaterThanOrEqual(ratio, entry.minimumRatio, "\(isDark ? "dark" : "light") \(entry.name): \(ratio)")
            }
        }
        // The cards stand apart from the darker search field.
        let light = WordMenuPalette(isDark: false), dark = WordMenuPalette(isDark: true)
        XCTAssertGreaterThan(Theme.relativeLuminance(light.card), Theme.relativeLuminance(light.field))
        XCTAssertGreaterThan(Theme.relativeLuminance(dark.card), Theme.relativeLuminance(dark.field))
        XCTAssertTrue(light.cardHasShadow)
        XCTAssertFalse(dark.cardHasShadow)
    }

    /// Search results group into one card per document: this document's matches first.
    func testSearchResultsGroupByDocument() {
        let other = folder.appendingPathComponent("Notes/Letter.md")
        let rows = [
            SearchRow(id: "d1", kind: .inDocument(NSRange(location: 0, length: 3)), indicator: "In document"),
            SearchRow(id: "d2", kind: .inDocument(NSRange(location: 9, length: 3)), indicator: "In document"),
            SearchRow(id: "n1", kind: .fileName, url: other, detail: "/Notes", indicator: "Letter.md"),
            SearchRow(id: "c1", kind: .fileContent(NSRange(location: 4, length: 3)), url: other, indicator: "Letter.md"),
        ]
        let cards = SearchResultCard.cards(from: rows, currentTitle: "Draft")
        XCTAssertEqual(cards.map(\.title), ["Draft", "Letter"])
        XCTAssertEqual(cards[0].row.id, "d1", "a tap goes to the first match")
        XCTAssertEqual(cards[1].detail, "Notes")
    }

    func testStatusLineShowsSavedAndCounts() async throws {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: WordMenuTestUbiquitousItems())
        await document.prepare()
        // The states in the interface language; English pins them below.
        let notSavedYet = WordMenu.notSavedYetText
        let saved = DocumentStatusText.saveState(isSaved: true, isAutosaved: false)
        let unsaved = DocumentStatusText.saveState(isSaved: false, isAutosaved: false)
        XCTAssertEqual(Set([notSavedYet, saved, unsaved]).count, 3)

        XCTAssertEqual(WordMenu.saveStateText(for: document), notSavedYet, "a blank new document has no file")
        document.edit("one two three")
        XCTAssertEqual(WordMenu.saveStateText(for: document), notSavedYet, "a new document's text is not on disk")
        XCTAssertFalse(WordMenu.isSaved(document))
        await document.flush()
        XCTAssertNotNil(document.url)
        XCTAssertEqual(WordMenu.saveStateText(for: document), saved)
        XCTAssertTrue(WordMenu.isSaved(document), "Saved shows in the Mac's green")
        document.edit("one two three four")
        XCTAssertEqual(WordMenu.saveStateText(for: document), unsaved, "between a keystroke and its autosave")
        await document.flush()
        XCTAssertEqual(WordMenu.saveStateText(for: document), saved)
        // pinned-en: the Mac's own keys and counts.
        if interfaceLanguage == "en" {
            XCTAssertEqual([notSavedYet, saved, unsaved], ["Not saved yet", "Saved", "Unsaved changes"])
            XCTAssertEqual(WordMenu.countText(DocumentStatistics(text: "one two three")), "3 words")
            XCTAssertEqual(WordMenu.countText(DocumentStatistics(text: "one")), "1 word")
            XCTAssertEqual(WordMenu.countText(DocumentStatistics(text: "吾輩は猫である。")), "8 characters", "CJK shows characters only, as on the Mac")
            XCTAssertEqual(WordMenu.documentTitle(for: nil), "Untitled")
            XCTAssertEqual(WordMenu.documentTitle(for: folder.appendingPathComponent("Export update.md")), "Export update")
        }
    }

    /// The open file was deleted elsewhere: its text stays on screen but is on disk nowhere, so the
    /// header never says Saved. The next change saves it again, while typing or on the way to the
    /// background.
    func testHeaderAfterADetachSaysNotSavedYetAndTheNextChangeSaves() async throws {
        try skipUnlessEnglishInterface()
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: WordMenuTestUbiquitousItems())
        await document.prepare()
        document.edit("Doomed draft")
        await document.flush()
        let url = try XCTUnwrap(document.url)
        XCTAssertEqual(WordMenu.saveStateText(for: document), "Saved")

        try FileManager.default.removeItem(at: url)
        document.fileWasTrashed(at: url)
        XCTAssertNil(document.url)
        XCTAssertEqual(document.text, "Doomed draft")
        XCTAssertEqual(WordMenu.saveStateText(for: document), "Not saved yet", "detached text is on disk nowhere")

        // The app goes to the background after a change: the text saves as a new document.
        document.edit("Doomed draft, rescued")
        document.flushForBackground(using: WordMenuBackgroundTasks())
        let rescued = folder.appendingPathComponent("Doomed draft, rescued.md")
        XCTAssertEqual(try String(contentsOf: rescued, encoding: .utf8), "Doomed draft, rescued")
        XCTAssertEqual(document.url?.standardizedFileURL, rescued.standardizedFileURL)
        XCTAssertEqual(WordMenu.saveStateText(for: document), "Saved")

        // Detached again; this time plain typing (the autosave) saves it.
        try FileManager.default.removeItem(at: rescued)
        document.fileWasTrashed(at: rescued)
        XCTAssertEqual(WordMenu.saveStateText(for: document), "Not saved yet")
        document.edit("Typed back")
        let typed = folder.appendingPathComponent("Typed back.md")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: typed.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try String(contentsOf: typed, encoding: .utf8), "Typed back")
        XCTAssertEqual(WordMenu.saveStateText(for: document), "Saved")
    }

    func testMoreButtonLabelIsMenu() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(MoreButton.accessibilityTitle, "Menu")
        let window = try hostScreen(document: OpenDocument(folderProvider: { [folder] in folder! }, ubiquitousItems: WordMenuTestUbiquitousItems()))
        settle(ticks: 5)
        XCTAssertNotNil(Self.accessibilityFrame(label: "Menu", in: window), "the ⋯ button reads as Menu")
        XCTAssertNil(Self.accessibilityFrame(label: "Reading Experience", in: window), "the Aa button is gone")
    }

    func testBottomClearanceUsesMoreButtonSize() {
        XCTAssertEqual(MoreButton.diameter, 48)
        XCTAssertGreaterThanOrEqual(MoreButton.diameter, WordMenuMetrics.minimumTarget)
        XCTAssertGreaterThan(MoreButton.diameter, PreviewLinkButton.diameter, "the ⋯ button is the taller one")
        XCTAssertEqual(DocumentScreen.bottomChromeClearance, MarkdownEditor.chromeMargin + MoreButton.diameter + 8)
    }

    // MARK: - Editor commands

    func testReplaceAllIsOneUndoStepAndKeepsCRLF() throws {
        let (commands, editor) = try liveCommands(text: "café\r\nCafe\r\ncafé")
        let undo = try XCTUnwrap(editor.undoManager)
        undo.removeAllActions()

        XCTAssertTrue(commands.replaceAll(ranges: [NSRange(location: 0, length: 4), NSRange(location: 12, length: 4)], with: "tea"))
        XCTAssertEqual(commands.currentText, "tea\r\nCafe\r\ntea")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(commands.currentText, "café\r\nCafe\r\ncafé", "one undo restores every replacement")
        XCTAssertFalse(undo.canUndo, "it was a single undo step")
    }

    func testReplaceAllRefusesOverlappingAndOutOfBoundsRanges() throws {
        let (commands, _) = try liveCommands(text: "abcdef")
        XCTAssertFalse(commands.replaceAll(ranges: [NSRange(location: 0, length: 3), NSRange(location: 2, length: 2)], with: "x"))
        XCTAssertFalse(commands.replaceAll(ranges: [NSRange(location: 4, length: 5)], with: "x"))
        XCTAssertFalse(commands.replaceAll(ranges: [], with: "x"))
        XCTAssertEqual(commands.currentText, "abcdef")
    }

    func testReplaceSelectAndTablesGoThroughTheEditor() throws {
        let (commands, editor) = try liveCommands(text: "hello world")
        XCTAssertTrue(commands.replace(range: NSRange(location: 6, length: 5), with: "there"))
        XCTAssertEqual(commands.currentText, "hello there")
        commands.selectRange(NSRange(location: 0, length: 500))
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 11), "clamped to the text")
        commands.selectRange(NSRange(location: 11, length: 0))
        commands.insertTable()
        XCTAssertTrue(commands.currentText.contains("|"), "the starter table went in")
        commands.scrollToCharacterRange(NSRange(location: 0, length: 0))
    }

    // MARK: - Helpers

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
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: WordMenuTestUbiquitousItems())
        return (LiveEditorCommands(positionKeeper: keeper, document: document, mode: .write), editor)
    }

    private var keepers: [ModePositionKeeper] = []

    private func hostScreen(document: OpenDocument) throws -> UIWindow {
        let suite = "WordMenuTests-\(UUID().uuidString)"
        defaultsSuite = suite
        let store = ReadingProfileStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: DocumentScreen(document: document, profileStore: store))
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func settle(ticks: Int) {
        for _ in 0..<ticks {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window?.layoutIfNeeded()
        }
    }

    private static func accessibilityFrame(label: String, in root: NSObject, depth: Int = 0) -> CGRect? {
        guard depth < 40 else { return nil }
        if root.accessibilityLabel == label, !(root is UIWindow) { return root.accessibilityFrame }
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
            if let frame = accessibilityFrame(label: label, in: child, depth: depth + 1) { return frame }
        }
        return nil
    }
}

/// Every file is local: nothing downloads, and real iCloud is never asked.
private struct WordMenuTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}

/// Background-task assertions that do nothing, for `flushForBackground`.
@MainActor
private final class WordMenuBackgroundTasks: BackgroundTaskAsserting {
    func beginAssertion(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIBackgroundTaskIdentifier(rawValue: 1)
    }

    func endAssertion(_ identifier: UIBackgroundTaskIdentifier) {}
}

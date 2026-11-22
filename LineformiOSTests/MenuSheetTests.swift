import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The Menu sheet shell: its sections in order, the save-state and count header, the Menu button,
/// the bottom clearance it needs, the section kept with the scene, and the editor commands the
/// sections will use (each one undo step). Every document saves into its own temporary folder.
@MainActor
final class MenuSheetTests: XCTestCase {
    private var folder: URL!
    private var window: UIWindow?
    private var defaultsSuite: String?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-sheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        if let defaultsSuite { UserDefaults().removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: folder)
    }

    func testSectionsInSpecOrder() {
        XCTAssertEqual(MenuSection.allCases, [.files, .outline, .basics, .search, .document, .settings])
        // Raw values are scene-storage identity, never localized.
        XCTAssertEqual(MenuSection.allCases.map(\.rawValue), ["files", "outline", "basics", "search", "document", "settings"])
        // pinned-en: the Mac's strings, under the test plan's English.
        XCTAssertEqual(MenuSection.allCases.map(\.title), ["Files", "Outline", "Markdown Basics", "Search", "Document", "Settings"])
        XCTAssertEqual(Set(MenuSection.allCases.map(\.systemImage)).count, MenuSection.allCases.count)
    }

    func testHeaderShowsSavedAndCounts() async {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: MenuSheetTestUbiquitousItems())
        await document.prepare()

        XCTAssertEqual(MenuSheet.saveStateText(for: document), "Not saved yet", "a blank new document has no file")
        document.edit("one two three")
        XCTAssertEqual(MenuSheet.saveStateText(for: document), "Not saved yet", "a new document's text is not on disk")
        await document.flush()
        XCTAssertNotNil(document.url)
        XCTAssertEqual(MenuSheet.saveStateText(for: document), "Saved")
        document.edit("one two three four")
        XCTAssertEqual(MenuSheet.saveStateText(for: document), "Unsaved changes", "between a keystroke and its autosave")
        await document.flush()
        XCTAssertEqual(MenuSheet.saveStateText(for: document), "Saved")
        XCTAssertEqual(MenuSheet.countsText(for: "one two three"), "3 words — 13 characters")
        XCTAssertEqual(MenuSheet.countsText(for: "吾輩は猫である。"), "8 characters", "CJK shows characters only, as on the Mac")
        // pinned-en: the Mac's own key.
        XCTAssertEqual(MenuSheet.notSavedYetText, "Not saved yet")
    }

    /// The open file was deleted elsewhere: its text stays on screen but is on disk nowhere, so the
    /// header never says Saved. The next change saves it again, while typing or on the way to the
    /// background.
    func testHeaderAfterADetachSaysNotSavedYetAndTheNextChangeSaves() async throws {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: MenuSheetTestUbiquitousItems())
        await document.prepare()
        document.edit("Doomed draft")
        await document.flush()
        let url = try XCTUnwrap(document.url)
        XCTAssertEqual(MenuSheet.saveStateText(for: document), "Saved")

        try FileManager.default.removeItem(at: url)
        document.fileWasTrashed(at: url)
        XCTAssertNil(document.url)
        XCTAssertEqual(document.text, "Doomed draft")
        XCTAssertEqual(MenuSheet.saveStateText(for: document), "Not saved yet", "detached text is on disk nowhere")

        // The app goes to the background after a change: the text saves as a new document.
        document.edit("Doomed draft, rescued")
        document.flushForBackground(using: MenuSheetBackgroundTasks())
        let rescued = folder.appendingPathComponent("Doomed draft, rescued.md")
        XCTAssertEqual(try String(contentsOf: rescued, encoding: .utf8), "Doomed draft, rescued")
        XCTAssertEqual(document.url?.standardizedFileURL, rescued.standardizedFileURL)
        XCTAssertEqual(MenuSheet.saveStateText(for: document), "Saved")

        // Detached again; this time plain typing (the autosave) saves it.
        try FileManager.default.removeItem(at: rescued)
        document.fileWasTrashed(at: rescued)
        XCTAssertEqual(MenuSheet.saveStateText(for: document), "Not saved yet")
        document.edit("Typed back")
        let typed = folder.appendingPathComponent("Typed back.md")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: typed.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try String(contentsOf: typed, encoding: .utf8), "Typed back")
        XCTAssertEqual(MenuSheet.saveStateText(for: document), "Saved")
    }

    func testMenuButtonLabelIsMenu() throws {
        XCTAssertEqual(MenuButton.accessibilityTitle, "Menu")
        let window = try hostScreen(document: OpenDocument(folderProvider: { [folder] in folder! }, ubiquitousItems: MenuSheetTestUbiquitousItems()))
        settle(ticks: 5)
        XCTAssertNotNil(Self.accessibilityFrame(label: "Menu", in: window), "the floating button reads as Menu")
        XCTAssertNil(Self.accessibilityFrame(label: "Files", in: window), "the old stand-in label is gone")
    }

    func testBottomClearanceUsesMenuButtonSize() {
        XCTAssertEqual(MenuButton.diameter, 44)
        XCTAssertGreaterThan(MenuButton.diameter, PreviewLinkButton.diameter, "the Menu button is the taller one")
        XCTAssertEqual(DocumentScreen.bottomChromeClearance, MarkdownEditor.chromeMargin + MenuButton.diameter + 8)
    }

    func testSectionPersists() {
        XCTAssertEqual(MenuSheet.sectionStorageKey, "menuSection")
        XCTAssertEqual(MenuSection.defaultSection, .files)
        for section in MenuSection.allCases {
            XCTAssertEqual(MenuSection(rawValue: section.rawValue), section, "\(section) survives a relaunch")
        }
        XCTAssertNil(MenuSection(rawValue: "Files"), "raw values are not display names")
    }

    func testSheetLook() {
        XCTAssertEqual(MenuSheet.cornerRadius, LineformDesign.Radius.modal)
        XCTAssertEqual(MenuSheet.cornerRadius, 20)
        XCTAssertEqual(MenuSheet.detents, [.medium, .large])
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
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: MenuSheetTestUbiquitousItems())
        return (LiveEditorCommands(positionKeeper: keeper, document: document, mode: .write), editor)
    }

    private var keepers: [ModePositionKeeper] = []

    private func hostScreen(document: OpenDocument) throws -> UIWindow {
        let suite = "MenuSheetTests-\(UUID().uuidString)"
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
private struct MenuSheetTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}

/// Background-task assertions that do nothing, for `flushForBackground`.
@MainActor
private final class MenuSheetBackgroundTasks: BackgroundTaskAsserting {
    func beginAssertion(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIBackgroundTaskIdentifier(rawValue: 1)
    }

    func endAssertion(_ identifier: UIBackgroundTaskIdentifier) {}
}

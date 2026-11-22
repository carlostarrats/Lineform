import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The Menu sheet's Document section: Convert to Plain Text / Convert to Markdown (the Mac's
/// state machine on `OpenDocument`), Check Document Now (one whole-document spelling pass), and
/// the section's rows and links. Every document saves into its own temporary folder.
@MainActor
final class DocumentCommandsTests: XCTestCase {
    private var folder: URL!
    private var window: UIWindow?
    private var boundText = ""
    private var coordinator: MarkdownEditor.Coordinator?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("document-commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        coordinator = nil
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Convert

    func testConvertToPlainTextAndBackRoundTrips() async throws {
        let document = await preparedDocument()
        let markdown = "# Title\n\nSome **bold** and _italic_ text with a [link](https://example.com).\n\n- one\n- two\n"
        document.edit(markdown)
        XCTAssertEqual(document.textFormat, .markdown)
        XCTAssertTrue(document.canConvertTextFormat)
        // pinned-en: the Mac's menu titles.
        XCTAssertEqual(DocumentSection.conversionTitle(for: document.textFormat), "Convert to Plain Text")

        let converted = try XCTUnwrap(document.convertToPlainText())
        XCTAssertEqual(document.text, MarkdownPlainTextConverter.plainText(from: markdown))
        XCTAssertEqual(converted, NSRange(location: 0, length: (document.text as NSString).length))
        XCTAssertEqual(document.textFormat, .plainText)
        XCTAssertNotNil(document.plainTextConversion)
        XCTAssertEqual(DocumentSection.conversionTitle(for: document.textFormat), "Convert to Markdown")
        XCTAssertFalse(DocumentSection.showsTableCommands(for: document.textFormat), "tables are Markdown only, as on the Mac")
        XCTAssertTrue(document.canConvertTextFormat, "the conversion it holds can be restored")

        // Converting again does nothing: the Mac returns the conversion's range.
        XCTAssertEqual(document.convertToPlainText(), converted)

        document.restoreMarkdown()
        XCTAssertEqual(document.text, markdown, "back to the Markdown byte for byte")
        XCTAssertEqual(document.textFormat, .markdown)
        XCTAssertNil(document.plainTextConversion)
        XCTAssertTrue(DocumentSection.showsTableCommands(for: document.textFormat))

        // The converted text saves as is (no stripping at write time).
        document.convertToPlainText()
        await document.flush()
        let url = try XCTUnwrap(document.url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), MarkdownPlainTextConverter.plainText(from: markdown))

        // An edit inside the converted text means the Markdown can no longer be put back: the
        // document stays plain text and forgets the conversion, as on the Mac.
        document.edit("Edited " + document.text)
        XCTAssertNil(document.restoreMarkdown())
        XCTAssertEqual(document.textFormat, .plainText)
        XCTAssertNil(document.plainTextConversion)
        XCTAssertFalse(document.canConvertTextFormat, "nothing to restore: the row is off")

        // A new document is Markdown again.
        await document.newDocument()
        XCTAssertEqual(document.textFormat, .markdown)
        XCTAssertNil(document.plainTextConversion)
    }

    func testOpenedTextFileIsPlainTextWithNothingToRestore() async throws {
        let txt = folder.appendingPathComponent("Notes.txt")
        try Data("# not a heading here\n".utf8).write(to: txt)
        let md = folder.appendingPathComponent("Notes.md")
        try Data("# Heading\n".utf8).write(to: md)
        let document = await preparedDocument()

        try await document.open(txt)
        XCTAssertEqual(document.textFormat, .plainText)
        XCTAssertFalse(document.canConvertTextFormat, "a .txt from disk holds no conversion to undo")
        XCTAssertNil(document.restoreMarkdown())
        XCTAssertEqual(document.text, "# not a heading here\n", "the file's text is never touched")
        XCTAssertEqual(document.textFormat, .plainText, "and it never flips to Markdown")

        try await document.open(md)
        XCTAssertEqual(document.textFormat, .markdown)
    }

    func testConvertKeepsCodeVerbatim() async throws {
        let document = await preparedDocument()
        let markdown = "# Code\r\n\r\nRun **this**:\r\n\r\n```python\r\nr\"\\\\d+\\\\.\\\\d\"\r\nprintf(\"a\\\\tb\")\r\n```\r\n\r\n$$\r\na*b*c \\[x\\]\r\n$$\r\n"
        document.edit(markdown)

        document.convertToPlainText()
        let plain = document.text
        XCTAssertTrue(plain.contains("r\"\\\\d+\\\\.\\\\d\"\r\n"), "the regex keeps every backslash")
        XCTAssertTrue(plain.contains("printf(\"a\\\\tb\")\r\n"), "an escape in code is never turned into a tab")
        XCTAssertTrue(plain.contains("a*b*c \\[x\\]"), "display math stays LaTeX")
        XCTAssertFalse(plain.contains("**this**"), "prose is stripped")
        XCTAssertFalse(plain.contains("\r\n\r\n\r\n"), "lines split on \\n only: no blank line per CRLF")
        XCTAssertEqual(plain.components(separatedBy: "\r\n").count - 1, plain.components(separatedBy: "\n").count - 1,
                       "every line still ends in CRLF")

        document.restoreMarkdown()
        XCTAssertEqual(document.text, markdown)
    }

    func testConvertThroughTheEditorIsOneUndoStep() async throws {
        let document = await preparedDocument()
        let markdown = "# Title\n\n**bold** text\n"
        let editor = hostEditor(for: document, text: markdown)
        XCTAssertEqual(document.text, markdown)

        document.convertToPlainText()
        XCTAssertEqual(editor.textStorage.string, MarkdownPlainTextConverter.plainText(from: markdown), "the editor shows it")
        XCTAssertEqual(document.text, editor.textStorage.string)
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.textStorage.string, markdown, "one undo puts the Markdown back")
    }

    // MARK: - Check Document Now

    func testCheckDocumentNowFindsOffscreenMisspelling() throws {
        _ = try XCTUnwrap(SpellCheckPass.language(primary: "en-US"), "the simulator has an English dictionary")
        let clean = String(repeating: "A clean line of plain prose sits here.\n", count: 600)
        let text = clean + "The last line has teh word.\n"
        let editor = hostEditor(text: text, height: 400)
        let misspelling = (text as NSString).range(of: "teh")

        XCTAssertTrue(editor.runSpellCheckPass())
        XCTAssertFalse(editor.spellCheck.misspelledRanges.contains(misspelling), "the typing pass stays in its window")

        XCTAssertTrue(editor.checkDocumentNow())
        XCTAssertTrue(editor.spellCheck.misspelledRanges.contains(misspelling), "the whole document was checked once")
        XCTAssertEqual(editor.selectedRange, misspelling, "the first misspelling is selected, as the Mac's command does")

        // A clean document finds nothing and selects nothing new.
        let cleanEditor = hostEditor(text: clean, height: 400)
        cleanEditor.selectedRange = NSRange(location: 4, length: 0)
        XCTAssertFalse(cleanEditor.checkDocumentNow())
        XCTAssertEqual(cleanEditor.spellCheck.misspelledRanges, [])
        XCTAssertEqual(cleanEditor.selectedRange, NSRange(location: 4, length: 0))

        // Through the Menu's commands.
        let keeper = ModePositionKeeper()
        keeper.editor = editor
        editor.selectedRange = NSRange(location: 0, length: 0)
        editor.spellCheck.misspelledRanges = []
        let commands = LiveEditorCommands(positionKeeper: keeper, document: OpenDocument(folderProvider: { [folder] in folder! }), mode: .write)
        XCTAssertTrue(commands.checkDocumentNow())
        XCTAssertEqual(editor.selectedRange, misspelling)
    }

    // MARK: - Rows and links

    func testDocumentRowsAndLinks() {
        // pinned-en: the Mac's command titles, in the section's order.
        XCTAssertEqual(DocumentSection.rowTitles(for: .markdown), [
            "New Document", "Open from Files…", "Insert Table", "Reformat Table",
            "Convert to Plain Text", "Check Document Now",
            "Export As", "Print…", "Share…", "Start Speaking", "Show Hidden Folders",
            "Lineform Guide", "Privacy Policy", "Terms of Use",
        ])
        XCTAssertEqual(DocumentSection.rowTitles(for: .plainText), [
            "New Document", "Open from Files…",
            "Convert to Markdown", "Check Document Now",
            "Export As", "Print…", "Share…", "Start Speaking", "Show Hidden Folders",
            "Lineform Guide", "Privacy Policy", "Terms of Use",
        ])
        XCTAssertEqual(DocumentSection.guideURL.absoluteString, LineformLinks.guideURL)
        XCTAssertEqual(DocumentSection.privacyPolicyURL.absoluteString, LineformLinks.privacyPolicyURL)
        XCTAssertEqual(DocumentSection.termsOfUseURL.absoluteString, LineformLinks.termsOfUseURL)
    }

    // MARK: - Helpers

    private func preparedDocument() async -> OpenDocument {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: DocumentCommandsTestUbiquitousItems())
        await document.prepare()
        return document
    }

    /// An editor wired to `document` the way `MarkdownEditor` wires it: its changes reach the
    /// document, and the document's Read edits go through it.
    private func hostEditor(for document: OpenDocument, text: String) -> LineformTextView {
        document.edit(text)
        let binding = Binding<String>(get: { document.text }, set: { document.edit($0) })
        let representable = MarkdownEditor(text: binding, profile: .original, readEditDocument: document)
        let coordinator = representable.makeCoordinator()
        self.coordinator = coordinator
        let editor = LineformTextView.make(profile: .original)
        editor.setDocumentText(text)
        editor.delegate = coordinator
        representable.configure(editor)
        place(editor, height: 800)
        return editor
    }

    private func hostEditor(text: String, height: CGFloat) -> LineformTextView {
        boundText = text
        let binding = Binding<String>(get: { [unowned self] in boundText }, set: { [unowned self] in boundText = $0 })
        let coordinator = MarkdownEditor(text: binding, profile: .original).makeCoordinator()
        self.coordinator = coordinator
        let editor = LineformTextView.make(profile: .original)
        editor.setDocumentText(text)
        editor.delegate = coordinator
        place(editor, height: height)
        return editor
    }

    private func place(_ editor: LineformTextView, height: CGFloat) {
        editor.frame = CGRect(x: 0, y: 0, width: 393, height: height)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window?.isHidden = true
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            window.rootViewController = host
            host.view.addSubview(editor)
            window.isHidden = false
            self.window = window
        }
        editor.layoutIfNeeded()
    }
}

/// Every file is local: nothing downloads, and real iCloud is never asked.
private struct DocumentCommandsTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}

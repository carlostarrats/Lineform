import AppIntents
import LineformCore
import XCTest
@testable import LineformiOS

/// App Intents on iPhone: New Lineform Note and Open in Lineform, the Mac's two actions, routed
/// through `OpenDocument` (the current document is saved first), and registered with the system
/// (`Metadata.appintents` in the built app, which only exists while AppIntents is linked).
@MainActor
final class PhoneAppIntentsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("intents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// `AppIntents.framework` must stay LINKED in the iPhone target too: without it no
    /// `Metadata.appintents` is emitted and the actions silently never register (the Mac shipped
    /// that way once).
    func testAppIntentsMetadataIsEmittedIntoTheApp() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Metadata.appintents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Metadata.appintents is missing — AppIntents.framework is no longer linked.")
    }

    /// The phrases are the Mac's, from the Mac's `AppShortcuts.xcstrings` (shared by reference).
    func testTheShortcutsAreTheMacs() throws {
        XCTAssertEqual(LineformAppShortcuts.appShortcuts.count, 2)
        XCTAssertTrue(NewLineformNoteIntent.openAppWhenRun)
        XCTAssertTrue(OpenInLineformIntent.openAppWhenRun)
        let catalog = Bundle.main.url(forResource: "AppShortcuts", withExtension: "strings", subdirectory: nil, localization: "de")
            ?? Bundle.main.url(forResource: "AppShortcuts", withExtension: "strings", subdirectory: "de.lproj")
        XCTAssertNotNil(catalog, "AppShortcuts.xcstrings is compiled into the iPhone app")
    }

    /// The intents' own words are the Mac's catalog entries, in every language.
    func testTheIntentStringsAreLocalized() throws {
        let keys = ["New Lineform Note", "Open in Lineform", "Text", "File", "The note's starting text.",
                    "The Markdown or text file to open.", "Opens a Markdown or text file in Lineform.",
                    "Opens a new note in Lineform, pre-filled with the given text. Save it wherever you like.",
                    "New Note", "That file couldn't be opened in Lineform."]
        for language in ["de", "es", "fr", "ja", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "\u{1}missing", table: nil)
                XCTAssertNotEqual(value, "\u{1}missing", "\(language): \(key)")
            }
        }
    }

    // MARK: Routing

    /// New Lineform Note saves the current document, then opens a fresh one holding the text,
    /// which autosaves like typing (named from its first line).
    func testNewNoteSavesTheCurrentDocumentThenOpensTheText() async throws {
        let document = try await preparedDocument()
        document.edit("Old draft\nstill here")
        let router = PhoneIntentRouter()
        await router.attach(document)

        await router.handle(.newNote("# Shopping\nmilk"))
        XCTAssertNil(document.url, "a fresh document")
        XCTAssertEqual(document.text, "# Shopping\nmilk")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Old draft.md"), encoding: .utf8),
                       "Old draft\nstill here", "the current document was saved first")
        await document.flush()
        XCTAssertEqual(document.url?.lastPathComponent, "Shopping.md")
    }

    func testANewNoteWithNoTextIsABlankDocument() async throws {
        let document = try await preparedDocument()
        document.edit("Something")
        let router = PhoneIntentRouter()
        await router.attach(document)
        await router.handle(.newNote(""))
        XCTAssertEqual(document.text, "")
        XCTAssertNil(document.url)
    }

    func testOpenInLineformOpensTheFileThroughTheDocument() async throws {
        let file = folder.appendingPathComponent("Notes.md")
        try Data("Hello\r\nworld".utf8).write(to: file)
        let document = try await preparedDocument()
        document.edit("Draft")
        let router = PhoneIntentRouter()
        await router.attach(document)
        await router.handle(.open(file))
        XCTAssertEqual(document.url?.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(document.text, "Hello\r\nworld", "CRLF kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Draft.md").path),
                      "the current document was saved first")
    }

    func testAnUnreadableFileShowsTheOpenFailure() async throws {
        let file = folder.appendingPathComponent("Binary.md")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: file)
        let document = try await preparedDocument()
        let router = PhoneIntentRouter()
        await router.attach(document)
        await router.handle(.open(file))
        XCTAssertNil(document.url)
        XCTAssertEqual(document.failedOpenURL, file, "the screen's \"couldn't be opened\" alert")
    }

    /// An intent that arrives before the screen has its document (a cold launch) waits for it, and
    /// runs after the launch restore (the screen attaches once `prepare` is done).
    func testARequestBeforeTheDocumentIsReadyWaits() async throws {
        let router = PhoneIntentRouter()
        await router.handle(.newNote("Early"))
        let document = try await preparedDocument()
        XCTAssertEqual(document.text, "")
        await router.attach(document)
        XCTAssertEqual(document.text, "Early")
        // Drained once: attaching again replays nothing.
        document.edit("Typed")
        await router.attach(document)
        XCTAssertEqual(document.text, "Typed")
    }

    private func preparedDocument() async throws -> OpenDocument {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: IntentTestUbiquitousItems())
        await document.prepare()
        return document
    }
}

private struct IntentTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}

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
                    "New Note", "That file couldn't be opened in Lineform.", "Lineform couldn't save the new note."]
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

        try await router.handle(.newNote("# Shopping\nmilk"))
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
        try await router.handle(.newNote(""))
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
        try await router.handle(.open(file))
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
        do {
            try await router.handle(.open(file))
            XCTFail("a file that couldn't be opened fails the shortcut too")
        } catch {
            XCTAssertEqual(error as? LineformShortcutError, .couldNotOpen)
        }
        XCTAssertNil(document.url)
        XCTAssertEqual(document.failedOpenURL, file, "the screen's \"couldn't be opened\" alert")
    }

    /// An intent that arrives before the screen has its document (a cold launch) waits for it, and
    /// runs after the launch restore (the screen attaches once `prepare` is done).
    func testARequestBeforeTheDocumentIsReadyWaits() async throws {
        let router = PhoneIntentRouter()
        let early = Task { @MainActor in try await router.handle(.newNote("Early")) }
        let document = try await preparedDocument()
        XCTAssertEqual(document.text, "")
        await router.attach(document)
        try await early.value
        XCTAssertEqual(document.text, "Early")
        // Drained once: attaching again replays nothing.
        document.edit("Typed")
        await router.attach(document)
        XCTAssertEqual(document.text, "Typed")
    }

    // MARK: Waiting for the outcome

    /// Open in Lineform returns only once the file is open — on a cold launch too, where the
    /// request waits for the screen's document — so Shortcuts never reports success early.
    func testAColdLaunchOpenReturnsOnlyAfterTheOpenCompletes() async throws {
        let file = folder.appendingPathComponent("Cold.md")
        try Data("Cold start".utf8).write(to: file)
        let router = PhoneIntentRouter()
        var finished = false
        let request = Task { @MainActor in
            try await router.handle(.open(file))
            finished = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(finished, "still waiting for the screen's document")
        let document = try await preparedDocument()
        await router.attach(document)
        try await request.value
        XCTAssertTrue(finished)
        XCTAssertEqual(document.url?.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(document.text, "Cold start")
    }

    /// A queued open that fails throws to the shortcut once the document is attached.
    func testAColdLaunchOpenThatFailsThrows() async throws {
        let file = folder.appendingPathComponent("Binary.md")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: file)
        let router = PhoneIntentRouter()
        let request = Task { @MainActor in try await router.handle(.open(file)) }
        for _ in 0..<5 { await Task.yield() }
        await router.attach(try await preparedDocument())
        do {
            try await request.value
            XCTFail("the shortcut is told it failed")
        } catch {
            XCTAssertEqual(error as? LineformShortcutError, .couldNotOpen)
        }
    }

    // MARK: Files Shortcuts hands over as a copy

    /// A file in a temporary or system-managed place (Shortcuts' own copy, the app's Inbox) is
    /// never opened in place: its text opens as a new note, and the original is never written.
    func testATemporaryCopyOpensAsANewNoteAndTheOriginalIsUntouched() async throws {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let copy = elsewhere.appendingPathComponent("Shared.md")
        let original = Data("# Shared\nfrom Shortcuts".utf8)
        try original.write(to: copy)

        XCTAssertFalse(PhoneIntentFile.opensInPlace(copy, saveFolders: [folder], hasSecurityScopedGrant: { _ in true }),
                       "a temporary location never opens in place, grant or not")
        let request = try PhoneIntentFile.request(fileURL: copy, saveFolders: [folder], hasSecurityScopedGrant: { _ in true },
                                                  readData: { try Data(contentsOf: copy) })
        XCTAssertEqual(request, .newNote("# Shared\nfrom Shortcuts"))

        let document = try await preparedDocument()
        let router = PhoneIntentRouter()
        await router.attach(document)
        try await router.handle(request)
        XCTAssertNil(document.url, "an untitled document")
        XCTAssertEqual(document.text, "# Shared\nfrom Shortcuts")
        document.edit(document.text + "\nedited")
        await document.flush()
        XCTAssertEqual(document.url?.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL,
                       "it saves into the save folder")
        XCTAssertEqual(try Data(contentsOf: copy), original, "the original is never written")
    }

    /// No file URL at all: the data is read while the intent runs and opens as a new note.
    func testAFileWithNoURLOpensItsTextAsANewNote() throws {
        let request = try PhoneIntentFile.request(fileURL: nil, saveFolders: [folder], hasSecurityScopedGrant: { _ in true },
                                                  readData: { Data("Loose text".utf8) })
        XCTAssertEqual(request, .newNote("Loose text"))
        XCTAssertThrowsError(try PhoneIntentFile.request(fileURL: nil, saveFolders: [folder], hasSecurityScopedGrant: { _ in true },
                                                         readData: { Data([0xFF, 0xFE, 0x00, 0xD8]) }))
    }

    /// Where a file opens in place: in a save folder, or under a security-scoped grant (a file
    /// the writer picked in Files). The app's Inbox and temporary folder never; anywhere else
    /// without a grant never.
    func testWhereAFileOpensInPlace() {
        let inSaveFolder = folder.appendingPathComponent("Mine.md")
        XCTAssertTrue(PhoneIntentFile.opensInPlace(inSaveFolder, saveFolders: [folder], temporaryDirectory: URL(fileURLWithPath: "/nowhere"),
                                                   hasSecurityScopedGrant: { _ in false }))
        let picked = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Picked.md")
        XCTAssertTrue(PhoneIntentFile.opensInPlace(picked, saveFolders: [folder], hasSecurityScopedGrant: { _ in true }))
        XCTAssertFalse(PhoneIntentFile.opensInPlace(picked, saveFolders: [folder], hasSecurityScopedGrant: { _ in false }))
        let inbox = PhoneIntentFile.inboxFolder.appendingPathComponent("Sent.md")
        XCTAssertFalse(PhoneIntentFile.opensInPlace(inbox, saveFolders: [PhoneIntentFile.inboxFolder.deletingLastPathComponent()],
                                                    hasSecurityScopedGrant: { _ in true }),
                       "the Inbox is inside Documents, a save folder, and still never opens in place")
    }

    // MARK: New Lineform Note never drops its text

    /// When the current document can't be saved, New Note can't replace it — so the note is
    /// written straight into the save folder instead, and the current document stays.
    func testANewNoteWhoseCurrentDocumentCantBeSavedIsWrittenToTheSaveFolder() async throws {
        let document = try await preparedDocument(writer: FailingWriter(failures: 1))
        document.edit("Old draft")
        let router = PhoneIntentRouter()
        await router.attach(document)
        try await router.handle(.newNote("# Shopping\nmilk"))
        XCTAssertEqual(document.text, "Old draft", "the unsaved document stays on screen")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Shopping.md"), encoding: .utf8),
                       "# Shopping\nmilk", "the note's text is on disk")
    }

    /// The same on a cold launch: the queued note is kept, and the shortcut waits for it.
    func testAQueuedNewNoteWhoseCurrentDocumentCantBeSavedIsWrittenToTheSaveFolder() async throws {
        let router = PhoneIntentRouter()
        let request = Task { @MainActor in try await router.handle(.newNote("Queued\nnote")) }
        let document = try await preparedDocument(writer: FailingWriter(failures: 1))
        document.edit("Unsaved")
        await router.attach(document)
        try await request.value
        XCTAssertEqual(document.text, "Unsaved")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Queued.md"), encoding: .utf8), "Queued\nnote")
    }

    /// When nothing can be written at all, the shortcut fails (Shortcuts keeps its input) rather
    /// than reporting a note that does not exist — queued or not.
    func testANewNoteThatCantBeKeptAnywhereThrows() async throws {
        let document = try await preparedDocument(writer: FailingWriter())
        document.edit("Unsaved")
        let router = PhoneIntentRouter()
        let queued = Task { @MainActor in try await router.handle(.newNote("Queued")) }
        for _ in 0..<5 { await Task.yield() }
        await router.attach(document)
        for request in [queued] {
            do {
                try await request.value
                XCTFail("a note that could not be kept is a failure")
            } catch {
                XCTAssertEqual(error as? LineformShortcutError, .newNoteNotSaved)
            }
        }
        do {
            try await router.handle(.newNote("Direct"))
            XCTFail("a note that could not be kept is a failure")
        } catch {
            XCTAssertEqual(error as? LineformShortcutError, .newNoteNotSaved)
        }
        XCTAssertEqual(document.text, "Unsaved")
    }

    private func preparedDocument(writer: any DocumentFileWriting = FileSystemDocumentWriter()) async throws -> OpenDocument {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, writer: writer, ubiquitousItems: IntentTestUbiquitousItems())
        await document.prepare()
        return document
    }
}

private struct IntentTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}

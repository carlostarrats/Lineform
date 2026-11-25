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
        // The Mac's two, then the iPhone's note shortcuts: Add, Get Text, Find, Open.
        XCTAssertEqual(LineformAppShortcuts.appShortcuts.count, 6)
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
                    "New Note", "That file couldn't be opened in Lineform.", "Lineform couldn't save the new note.",
                    // The note intents.
                    "Add to Lineform Note", "Adds text to the end of a Lineform note.", "Note",
                    "The text to add to the end of the note.", "Add ${text} to ${note}", "Get Note Text",
                    "Gets the text of a Lineform note.", "Get the text of ${note}", "Find Notes",
                    "Finds Lineform notes by name, and optionally by what they contain.", "Search Contents",
                    "Find notes matching ${name}", "Open Lineform Note", "Opens a note in Lineform.", "Lineform Note",
                    "Add to Note", "Open Note", "Lineform couldn't add the text to the note.", "That note couldn't be read.",
                    "iCloud", "On My iPhone", "Name"]
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

    // MARK: Add to Lineform Note: the append rule

    func testAppendingPutsTheTextOnALineOfItsOwn() {
        XCTAssertEqual(PhoneNoteText.appending("eggs", to: ""), "eggs")
        XCTAssertEqual(PhoneNoteText.appending("eggs", to: "- milk"), "- milk\neggs")
        XCTAssertEqual(PhoneNoteText.appending("eggs", to: "- milk\n"), "- milk\neggs\n", "a final line break stays final")
        XCTAssertEqual(PhoneNoteText.appending("eggs\n", to: "- milk\n"), "- milk\neggs\n", "never doubled")
        XCTAssertEqual(PhoneNoteText.appending("", to: "- milk"), "- milk", "nothing to add changes nothing")
    }

    /// The addition takes the file's own line endings: a Windows file stays CRLF throughout.
    func testAppendingKeepsCRLFAndABOM() {
        XCTAssertEqual(PhoneNoteText.appending("a\nb", to: "one\r\ntwo\r\n"), "one\r\ntwo\r\na\r\nb\r\n")
        XCTAssertEqual(PhoneNoteText.appending("x", to: "one\r\ntwo"), "one\r\ntwo\r\nx")
        XCTAssertEqual(PhoneNoteText.appending("x", to: "\u{FEFF}head"), "\u{FEFF}head\nx")
    }

    /// A note that is not on screen: one coordinated read-and-write, bytes kept (BOM, CRLF).
    func testAppendingToAFileKeepsItsBytes() throws {
        let file = folder.appendingPathComponent("Windows.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\n".utf8)).write(to: file)
        XCTAssertTrue(PhoneNoteText.append("three", toFileAt: file))
        XCTAssertEqual(try Data(contentsOf: file), Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\nthree\r\n".utf8)))

        let binary = folder.appendingPathComponent("Binary.md")
        let bytes = Data([0xFF, 0xFE, 0x00, 0xD8])
        try bytes.write(to: binary)
        XCTAssertFalse(PhoneNoteText.append("x", toFileAt: binary), "a file that is not text is refused")
        XCTAssertEqual(try Data(contentsOf: binary), bytes, "and never written")
    }

    /// The note on screen takes the text through the document — never behind its back — keeping
    /// its unsaved edits, and the file has it when the shortcut returns.
    func testAppendingToTheOpenNoteGoesThroughTheDocument() async throws {
        let file = folder.appendingPathComponent("List.md")
        try Data("- milk".utf8).write(to: file)
        let document = try await preparedDocument()
        try await document.open(file)
        document.edit("- milk\n- bread")
        let router = PhoneIntentRouter(sceneIsConnecting: { false })
        await router.attach(document)

        try await router.append("- eggs", toNoteAt: file)
        XCTAssertEqual(document.text, "- milk\n- bread\n- eggs", "the unsaved edit is kept")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "- milk\n- bread\n- eggs", "flushed")
        let read = try await router.text(ofNoteAt: file)
        XCTAssertEqual(read, "- milk\n- bread\n- eggs")
    }

    /// Another note: its file changes, the document on screen does not.
    func testAppendingToAnotherNoteWritesItsFileOnly() async throws {
        let other = folder.appendingPathComponent("Other.md")
        try Data("Other".utf8).write(to: other)
        let document = try await preparedDocument()
        document.edit("On screen")
        let router = PhoneIntentRouter(sceneIsConnecting: { false })
        await router.attach(document)

        try await router.append("more", toNoteAt: other)
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "Other\nmore")
        XCTAssertEqual(document.text, "On screen")
        let otherText = try await router.text(ofNoteAt: other)
        XCTAssertEqual(otherText, "Other\nmore")

        do {
            _ = try await router.text(ofNoteAt: folder.appendingPathComponent("Gone.md"))
            XCTFail("a missing note fails the shortcut")
        } catch {
            XCTAssertEqual(error as? LineformShortcutError, .couldNotReadNote)
        }
    }

    /// With no screen coming (a background launch), Add and Get go straight to the file; with a
    /// screen coming, they wait for its document.
    func testAddWaitsForAComingScreenOnly() async throws {
        let file = folder.appendingPathComponent("Wait.md")
        try Data("Start".utf8).write(to: file)
        let router = PhoneIntentRouter(sceneIsConnecting: { true })
        var finished = false
        let request = Task { @MainActor in
            try await router.append("added", toNoteAt: file)
            finished = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(finished, "waiting for the screen's document")
        let document = try await preparedDocument()
        try await document.open(file)
        await router.attach(document)
        try await request.value
        XCTAssertEqual(document.text, "Start\nadded", "through the document once it attached")
    }

    // MARK: The note entity and its query

    private func library() throws -> (PhoneNoteLibrary, cloud: URL, device: URL) {
        let cloud = folder.appendingPathComponent("cloud", isDirectory: true)
        let device = folder.appendingPathComponent("device", isDirectory: true)
        for path in ["cloud/Ideas", "device/Inbox"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("Lists of things".utf8).write(to: cloud.appendingPathComponent("Groceries.md"))
        try Data("Résumé draft".utf8).write(to: cloud.appendingPathComponent("Ideas/Café plans.markdown"))
        try Data("A secret word: zebra".utf8).write(to: device.appendingPathComponent("Journal.txt"))
        try Data("not a note".utf8).write(to: device.appendingPathComponent("photo.png"))
        try Data("sent by another app".utf8).write(to: device.appendingPathComponent("Inbox/Sent.md"))
        let library = PhoneNoteLibrary(
            roots: [.init(id: .icloud, folder: cloud), .init(id: .device, folder: device)],
            excludedFolders: [device.appendingPathComponent("Inbox", isDirectory: true)]
        )
        return (library, cloud, device)
    }

    /// Every note in both roots: title without extension, the location as subtitle, an id of root
    /// plus path inside it. Never the Inbox, never a file that is not a note.
    func testTheLibraryListsNotesInBothRoots() throws {
        let (library, _, _) = try library()
        let byID = Dictionary(uniqueKeysWithValues: library.notes().map { ($0.entity.id, $0.entity) })
        XCTAssertEqual(Set(byID.keys), ["icloud:Groceries.md", "icloud:Ideas/Café plans.markdown", "device:Journal.txt"])
        XCTAssertEqual(byID["icloud:Ideas/Café plans.markdown"]?.title, "Café plans")
        XCTAssertEqual(byID["icloud:Groceries.md"]?.location, .icloud)
        XCTAssertEqual(byID["device:Journal.txt"]?.location, .device)
        XCTAssertEqual(LineformNoteEntity.locationTitle(.icloud), "iCloud")
        XCTAssertEqual(LineformNoteEntity.locationTitle(.device), "On My iPhone")
    }

    /// An id resolves back to its file while the file is there; an id that leaves its root, names
    /// no root, or names the Inbox resolves to nothing.
    func testAnIDResolvesOnlyToANoteInsideItsRoot() throws {
        let (library, cloud, _) = try library()
        XCTAssertEqual(library.url(forID: "icloud:Ideas/Café plans.markdown")?.standardizedFileURL,
                       cloud.appendingPathComponent("Ideas/Café plans.markdown").standardizedFileURL)
        XCTAssertEqual(library.entity(forID: "device:Journal.txt")?.title, "Journal")
        for bad in ["icloud:../device/Journal.txt", "icloud:Ideas/../Groceries.md", "workspace:Groceries.md",
                    "Groceries.md", "icloud:", "icloud:Missing.md", "device:photo.png", "device:Inbox/Sent.md",
                    "icloud:/Groceries.md"] {
            XCTAssertNil(library.url(forID: bad), bad)
        }
    }

    /// An iCloud file not downloaded yet is still a note (Spotlight and Shortcuts keep it).
    func testAnICloudPlaceholderIsStillANote() throws {
        let (library, cloud, _) = try library()
        try Data().write(to: cloud.appendingPathComponent(".Later.md.icloud"))
        XCTAssertTrue(library.notes().contains { $0.entity.id == "icloud:Later.md" })
        XCTAssertNotNil(library.url(forID: "icloud:Later.md"))
    }

    /// Find Notes: names match as Search does (case- and diacritic-insensitive); contents only when
    /// asked, after the name matches; the document on screen is searched as it is now.
    func testFindingNotesByNameAndContents() throws {
        let (library, _, device) = try library()
        XCTAssertEqual(library.find("cafe", searchingContents: false).map(\.entity.title), ["Café plans"])
        XCTAssertEqual(library.find("GROC", searchingContents: false).map(\.entity.title), ["Groceries"])
        XCTAssertEqual(library.find("zebra", searchingContents: false), [], "names only by default")
        XCTAssertEqual(library.find("zebra", searchingContents: true).map(\.entity.title), ["Journal"])
        XCTAssertEqual(library.find("  ", searchingContents: false).count, 3, "an empty query is every note")
        let overrides = [FilesStore.key(device.appendingPathComponent("Journal.txt")): "typed just now: walrus"]
        XCTAssertEqual(library.find("walrus", searchingContents: true, overrides: overrides).map(\.entity.title), ["Journal"])
        XCTAssertEqual(library.find("zebra", searchingContents: true, overrides: overrides), [])
    }

    // MARK: Spotlight

    /// The first refresh replaces everything; later ones send only what changed. The entity carries
    /// a title and a location, nothing of the text.
    func testSpotlightSendsOnlyTheChange() {
        let a = LineformNoteEntity(id: "device:A.md", title: "A", location: .device)
        let b = LineformNoteEntity(id: "device:B.md", title: "B", location: .device)
        let first = PhoneSpotlightIndex.change(from: nil, to: [a, b])
        XCTAssertTrue(first.replacesAll)
        XCTAssertEqual(first.indexed, [a, b])

        let old = ["device:A.md": a, "device:B.md": b]
        XCTAssertTrue(PhoneSpotlightIndex.change(from: old, to: [a, b]).isEmpty)
        let renamed = LineformNoteEntity(id: "device:C.md", title: "C", location: .device)
        let change = PhoneSpotlightIndex.change(from: old, to: [a, renamed])
        XCTAssertFalse(change.replacesAll)
        XCTAssertEqual(change.removedIDs, ["device:B.md"])
        XCTAssertEqual(change.indexed, [renamed])
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

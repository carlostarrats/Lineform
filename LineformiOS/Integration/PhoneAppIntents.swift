import AppIntents
import CoreSpotlight
import Foundation
import LineformCore
import UIKit
import os

// Shortcuts, Spotlight and Siri on iPhone: the Mac's two local-first actions (`Lineform/App/
// LineformAppIntents.swift`), with the same type names, titles, parameters and phrases, so a
// shortcut reads the same on both. No network, no new entitlement.
//
//   • New Lineform Note — a fresh document holding the given text.
//   • Open in Lineform — opens a Markdown or text file.
//
// Both are foreground intents and run in the app's process. They go through `OpenDocument`, like
// New Document and an open from Files: the current document is saved first, and a document whose
// save fails stays (its notice shows). Unlike the Mac, nothing is staged: a new iPhone document
// already autosaves into the save folder, named from its first line.
//
// `perform()` returns only once the request has actually run — on a cold launch it waits for the
// screen's document — and throws when it failed, so Shortcuts never reports a success that did
// not happen. Open in Lineform never edits a file Shortcuts handed over as a copy
// (`PhoneIntentFile`), and New Lineform Note never drops its text (`PhoneIntentRouter.perform`).
//
// `AppIntents.framework` must stay LINKED in the iPhone target's Frameworks phase, or no
// `Metadata.appintents` is emitted and the actions silently never register
// (`PhoneAppIntentsTests.testAppIntentsMetadataIsEmittedIntoTheApp`). The phrases come from the
// Mac's `AppShortcuts.xcstrings`, in the iPhone's Resources by reference.

struct NewLineformNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Lineform Note"
    static let description = IntentDescription("Opens a new note in Lineform, pre-filled with the given text. Save it wherever you like.")
    static let openAppWhenRun = true

    @Parameter(title: "Text", description: "The note's starting text.", default: "")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PhoneIntentRouter.shared.handle(.newNote(text))
        return .result()
    }
}

struct OpenInLineformIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in Lineform"
    static let description = IntentDescription("Opens a Markdown or text file in Lineform.")
    static let openAppWhenRun = true

    @Parameter(title: "File", description: "The Markdown or text file to open.")
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        // Decided — and a copy's bytes read — now, while the intent runs and Shortcuts' copy
        // still exists.
        let file = self.file
        let saveFolders = await PhoneIntentRouter.shared.saveFolders()
        let request = try PhoneIntentFile.request(fileURL: file.fileURL, saveFolders: saveFolders, readData: { file.data })
        try await PhoneIntentRouter.shared.handle(request)
        return .result()
    }
}

/// Registers the intents so they appear in Shortcuts, Spotlight and Siri with no setup.
struct LineformAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewLineformNoteIntent(),
            phrases: [
                "New note in \(.applicationName)",
                "Create a note in \(.applicationName)"
            ],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenInLineformIntent(),
            phrases: [
                "Open a file in \(.applicationName)"
            ],
            shortTitle: "Open in Lineform",
            systemImageName: "doc.text"
        )
        // iPhone only (the Mac has no note entity yet); their phrases are in the same
        // `AppShortcuts.xcstrings`.
        AppShortcut(
            intent: AddToLineformNoteIntent(),
            phrases: [
                "Add to a note in \(.applicationName)",
                "Add text to a note in \(.applicationName)"
            ],
            shortTitle: "Add to Note",
            systemImageName: "text.append"
        )
        AppShortcut(
            intent: GetLineformNoteTextIntent(),
            phrases: [
                "Get note text from \(.applicationName)"
            ],
            shortTitle: "Get Note Text",
            systemImageName: "doc.plaintext"
        )
        AppShortcut(
            intent: FindLineformNotesIntent(),
            phrases: [
                "Find notes in \(.applicationName)",
                "Search notes in \(.applicationName)"
            ],
            shortTitle: "Find Notes",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenLineformNoteIntent(),
            phrases: [
                "Open a note in \(.applicationName)"
            ],
            shortTitle: "Open Note",
            systemImageName: "doc.text.magnifyingglass"
        )
    }
}

enum LineformShortcutError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    /// The Mac's case, kept for its string; the iPhone reads a URL-less file's data instead.
    case noFileURL
    /// The file could not be read, or its open failed or was overtaken.
    case couldNotOpen
    /// New Lineform Note could neither open the note nor write it into the save folder.
    case newNoteNotSaved
    /// Add to Lineform Note: the note could not be read as text or written, or the editor refused
    /// the edit (an AI review is up, or an input method is composing).
    case couldNotAddText
    /// Get Note Text (and Add): the note is gone, or could not be read as text.
    case couldNotReadNote

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noFileURL, .couldNotOpen: return "That file couldn't be opened in Lineform."
        case .newNoteNotSaved: return "Lineform couldn't save the new note."
        case .couldNotAddText: return "Lineform couldn't add the text to the note."
        case .couldNotReadNote: return "That note couldn't be read."
        }
    }
}

/// Where Open in Lineform may open a file IN PLACE. A file Shortcuts hands over is often a copy in
/// a temporary or system-managed place: editing that copy would look like saving while the
/// writer's real file never changed, and the copy can vanish. So a file opens in place only from
/// a save folder (iCloud Drive's Lineform folder, On My iPhone ▸ Lineform) or under a
/// security-scoped grant (a file the writer picked in Files) — and never from the app's
/// temporary folder or its `Inbox`, grant or not. Anything else, and a file with no URL, opens as
/// a new untitled note holding its text; the original is never written.
enum PhoneIntentFile {
    /// The app's temporary folder.
    static var temporaryFolder: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    /// `Documents/Inbox`, where the system drops files other apps send.
    static var inboxFolder: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? temporaryFolder)
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Whether the URL carries a security-scoped grant: accessing it succeeds. Released at once;
    /// `OpenDocument.open` takes its own.
    static func liveSecurityScopedGrant(_ url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else { return false }
        url.stopAccessingSecurityScopedResource()
        return true
    }

    static func opensInPlace(
        _ url: URL,
        saveFolders: [URL],
        temporaryDirectory: URL = temporaryFolder,
        inbox: URL = inboxFolder,
        hasSecurityScopedGrant: (URL) -> Bool = liveSecurityScopedGrant
    ) -> Bool {
        guard url.isFileURL else { return false }
        if isInside(url, inbox) || isInside(url, temporaryDirectory) { return false }
        if saveFolders.contains(where: { isInside(url, $0) }) { return true }
        return hasSecurityScopedGrant(url)
    }

    /// The request for an intent's file: `.open` in place, or `.newNote` with the text read now
    /// through `readData`. Throws `couldNotOpen` when the data can't be read or isn't text.
    static func request(
        fileURL: URL?,
        saveFolders: [URL],
        temporaryDirectory: URL = temporaryFolder,
        inbox: URL = inboxFolder,
        hasSecurityScopedGrant: (URL) -> Bool = liveSecurityScopedGrant,
        readData: () throws -> Data
    ) throws -> PhoneIntentRouter.Request {
        if let fileURL, opensInPlace(fileURL, saveFolders: saveFolders, temporaryDirectory: temporaryDirectory,
                                     inbox: inbox, hasSecurityScopedGrant: hasSecurityScopedGrant) {
            return .open(fileURL)
        }
        let didAccess = fileURL?.startAccessingSecurityScopedResource() ?? false
        defer { if didAccess { fileURL?.stopAccessingSecurityScopedResource() } }
        guard let data = try? readData(), let text = MarkdownFileCodec.decode(data) else {
            throw LineformShortcutError.couldNotOpen
        }
        return .newNote(text)
    }

    /// Whether `url` is `folder` itself or inside it, comparing resolved paths (`/var` and
    /// `/private/var` are one place).
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if !folderPath.hasSuffix("/") { folderPath += "/" }
        return path.hasPrefix(folderPath)
    }
}

/// Hands an intent to the open document. The screen attaches its document once `prepare` (and the
/// launch restore) is done; an intent that arrives earlier, as on a cold launch, waits for it, so a
/// restore never lands over the note or file the writer asked for. Either way `handle` returns
/// only once the request has run, and throws its failure.
@MainActor
final class PhoneIntentRouter {
    static let shared = PhoneIntentRouter()

    enum Request: Equatable {
        case newNote(String)
        case open(URL)
    }

    private weak var document: OpenDocument?
    private var pending: [(request: Request, continuation: CheckedContinuation<Void, Error>)] = []
    /// Add to Lineform Note and Get Note Text waiting for a screen that is coming up.
    private var attachWaiters: [CheckedContinuation<Void, Never>] = []
    /// Whether a screen is on its way (a scene is connected), so its document will attach soon.
    private let sceneIsConnecting: @MainActor () -> Bool

    /// - Parameter sceneIsConnecting: whether a scene is connected while no document is attached
    ///   yet. Tests pass `{ false }`; the live one asks UIKit.
    init(sceneIsConnecting: @escaping @MainActor () -> Bool = { !UIApplication.shared.connectedScenes.isEmpty }) {
        self.sceneIsConnecting = sceneIsConnecting
    }

    /// The screen's document, ready. Runs whatever arrived before it, in order, and resumes each
    /// waiting intent with its outcome.
    func attach(_ document: OpenDocument) async {
        self.document = document
        let waiters = attachWaiters
        attachWaiters = []
        for waiter in waiters { waiter.resume() }
        while !pending.isEmpty {
            let next = pending.removeFirst()
            do {
                try await Self.perform(next.request, on: document)
                next.continuation.resume()
            } catch {
                next.continuation.resume(throwing: error)
            }
        }
    }

    /// The screen's document, once attached.
    var attachedDocument: OpenDocument? { document }

    /// When no document is attached yet but a screen is coming up (a scene is connected), waits
    /// until it attaches, or `attachWait` at most. With no scene (the app launched in the
    /// background for a shortcut) it returns at once: there is no document to go through.
    func waitForAComingScreen() async {
        guard document == nil, sceneIsConnecting() else { return }
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.attachWait)
            guard !Task.isCancelled, let self else { return }
            let waiters = self.attachWaiters
            self.attachWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        await withCheckedContinuation { continuation in
            attachWaiters.append(continuation)
        }
        timeout.cancel()
    }

    /// Runs `request` — after the document is attached, on a cold launch — and returns once it has.
    func handle(_ request: Request) async throws {
        guard let document else {
            try await withCheckedThrowingContinuation { continuation in
                pending.append((request, continuation))
            }
            return
        }
        try await Self.perform(request, on: document)
    }

    /// The folders a file opens in place from: the document's save folder once known, and the
    /// two the app saves into (iCloud Drive's Lineform folder when available, and On My iPhone).
    func saveFolders() async -> [URL] {
        var folders = await Task.detached {
            let resolver = DocumentFolderResolver.live()
            return [resolver.iCloudFolder(), resolver.deviceFolder].compactMap { $0 }
        }.value
        if let saveFolder = document?.saveFolder { folders.append(saveFolder) }
        return folders
    }

    /// New Note: save the current document, start a blank one, and put the text in it (it then
    /// autosaves like typing). When the current document can't be put away — its save failed, or
    /// a later open took over — the note is written straight into the save folder instead, so
    /// its text is never dropped; if even that fails, the intent throws and Shortcuts shows the
    /// failure (its input still holds the text). Open: a file that cannot be opened shows the
    /// screen's "couldn't be opened" alert and throws.
    private static func perform(_ request: Request, on document: OpenDocument) async throws {
        switch request {
        case .newNote(let text):
            if await document.newDocument() {
                if !text.isEmpty { document.edit(text) }
                return
            }
            guard !text.isEmpty, await document.saveNewNoteBeside(text) != nil else {
                throw LineformShortcutError.newNoteNotSaved
            }
        case .open(let url):
            do {
                try await document.open(url)
            } catch OpenDocument.OpenError.currentDocumentNotSaved, OpenDocument.OpenError.superseded,
                    OpenDocument.OpenError.downloadFailed {
                // The save failure and a failed download have their own notices; an overtaken open
                // is the later one's business.
                throw LineformShortcutError.couldNotOpen
            } catch {
                document.failedOpenURL = url
                throw LineformShortcutError.couldNotOpen
            }
        }
    }
}

// MARK: - Notes as entities: Add to Lineform Note, Get Note Text, Find Notes, Open Lineform Note
//
// A Lineform note is a Markdown or text file in one of the two roots Files shows on iPhone:
// iCloud Drive's Lineform folder and On My iPhone ▸ Lineform (`FilesSection.phoneRoots`). Never the
// Workspace, never `Documents/Inbox` (copies other apps sent). Its id is the root plus the path
// inside it ("device:Folder/Note.md"), so it survives the app container moving.
//
// Add to Lineform Note never writes behind the open document's back: when the note is the one on
// screen, the text goes in through the editor (one undo step, then autosave) and is flushed before
// the intent returns; otherwise it is one coordinated read-and-write of the file, so another
// presenter (Files, another app) hears it like any other change. While a screen is coming up but
// has not attached its document yet, both wait for it (a little while at most).
//
// Spotlight (`PhoneSpotlightIndex`) indexes each note's TITLE and LOCATION only — never its text —
// and a tap runs Open Lineform Note, which is Open in Lineform's path (`PhoneIntentRouter.handle`).
// Find Notes' "Search Contents" reads files on the device only, the way Files' search does
// (`CrossFileSearchFileReader`: never downloads an iCloud file, skips anything over 1 MB).
// Nothing here sends anything anywhere.

/// A Lineform note for Shortcuts, Siri and Spotlight.
struct LineformNoteEntity: AppEntity, IndexedEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lineform Note")
    static let defaultQuery = LineformNoteQuery()

    /// The root and the path inside it: "icloud:Folder/Note.md" or "device:Note.md".
    var id: String
    /// The file name without its extension.
    var title: String
    var location: FilesRootID

    var displayRepresentation: DisplayRepresentation {
        // Interpolated, so a note's name is shown as it is and never looked up in the catalog.
        DisplayRepresentation(title: "\(title)", subtitle: Self.locationTitle(location))
    }

    static func locationTitle(_ location: FilesRootID) -> LocalizedStringResource {
        switch location {
        case .icloud: return "iCloud"
        case .device, .workspace: return "On My iPhone"
        }
    }
}

/// The notes Shortcuts and Siri can pick from, and find by name.
struct LineformNoteQuery: EntityStringQuery {
    func entities(for identifiers: [LineformNoteEntity.ID]) async throws -> [LineformNoteEntity] {
        let library = await PhoneNoteLibrary.live()
        return identifiers.compactMap { library.entity(forID: $0) }
    }

    func entities(matching string: String) async throws -> [LineformNoteEntity] {
        let library = await PhoneNoteLibrary.live()
        return library.find(string, searchingContents: false).map(\.entity)
    }

    func suggestedEntities() async throws -> [LineformNoteEntity] {
        let library = await PhoneNoteLibrary.live()
        return library.notes().map(\.entity)
    }
}

/// One note as the library found it.
struct PhoneNote: Equatable, Sendable {
    var entity: LineformNoteEntity
    var url: URL
    var modifiedAt: Date?
}

/// The two roots notes live in, and the scan, lookup and search over them. Plain file reads: call
/// it off the main thread.
struct PhoneNoteLibrary: Sendable {
    struct Root: Equatable, Sendable {
        var id: FilesRootID
        var folder: URL
    }

    var roots: [Root]
    /// Folders inside a root that never hold notes (`Documents/Inbox`).
    var excludedFolders: [URL] = []
    var scanner: FilesStore.Scanner = FilesStore.liveScanner

    /// The app's roots, looked up off the main thread: iCloud Drive's Lineform folder when the
    /// container resolves (the Debug preview folder under `-LineformPreviewICloud`, as Files),
    /// and On My iPhone.
    static func live() async -> PhoneNoteLibrary {
        await Task.detached {
            let resolver = DocumentFolderResolver.live()
            var roots: [Root] = []
            if let iCloud = FilesStore.previewICloudFolder() ?? resolver.iCloudFolder() {
                roots.append(Root(id: .icloud, folder: iCloud))
            }
            let device = resolver.deviceFolder
            if !roots.contains(where: { FilesStore.key($0.folder) == FilesStore.key(device) }) {
                roots.append(Root(id: .device, folder: device))
            }
            return PhoneNoteLibrary(roots: roots, excludedFolders: [PhoneIntentFile.inboxFolder])
        }.value
    }

    /// Every note, most recently changed first (then by name).
    func notes() -> [PhoneNote] {
        var found: [PhoneNote] = []
        for root in roots {
            func walk(_ items: [OutlineFileTreeItem]) {
                for item in items {
                    if item.isDirectory {
                        walk(item.children)
                    } else if !isExcluded(item.url), let entity = entity(for: item.url, in: root) {
                        found.append(PhoneNote(entity: entity, url: item.url, modifiedAt: item.modifiedAt))
                    }
                }
            }
            walk(scanner(root.folder, false, .dateModified))
        }
        return found.sorted { lhs, rhs in
            switch (lhs.modifiedAt, rhs.modifiedAt) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.entity.title.localizedStandardCompare(rhs.entity.title) == .orderedAscending
            }
        }
    }

    /// The entity for a file inside `root`, or nil for a file that is not a note.
    func entity(for url: URL, in root: Root) -> LineformNoteEntity? {
        let rootPath = FilesStore.key(root.folder)
        let path = FilesStore.key(url)
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        guard OutlineFileScanner.supportedFileExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return LineformNoteEntity(
            id: "\(root.id.rawValue):\(relative)",
            title: url.deletingPathExtension().lastPathComponent,
            location: root.id
        )
    }

    /// The file an id names, when it is still there (or iCloud still has it as a placeholder). An
    /// id that leaves its root (`..`), names no root, or is not a note resolves to nothing.
    func url(forID id: String) -> URL? {
        guard let colon = id.firstIndex(of: ":"),
              let rootID = FilesRootID(rawValue: String(id[..<colon])),
              let root = roots.first(where: { $0.id == rootID })
        else { return nil }
        let relative = String(id[id.index(after: colon)...])
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return nil }
        let url = components.reduce(root.folder) { $0.appendingPathComponent(String($1)) }
        guard entity(for: url, in: root) != nil, !isExcluded(url) else { return nil }
        let manager = FileManager.default
        let stub = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard manager.fileExists(atPath: url.path) || manager.fileExists(atPath: stub.path) else { return nil }
        return url
    }

    func entity(forID id: String) -> LineformNoteEntity? {
        guard let url = url(forID: id), let root = root(containing: url) else { return nil }
        return entity(for: url, in: root)
    }

    /// The notes whose name matches `query` (literal, case- and diacritic-insensitive, as Search),
    /// then — with `searchingContents` — the ones whose text does. An empty query is every note.
    /// `contents` reads a note's text; `overrides` (keyed by `FilesStore.key`) stands in for it,
    /// for the document on screen.
    func find(
        _ query: String,
        searchingContents: Bool,
        overrides: [String: String] = [:],
        contents: (URL) -> String? = { CrossFileSearchFileReader().readSearchableText(at: $0) }
    ) -> [PhoneNote] {
        let all = notes()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        func matches(_ text: String) -> Bool { !EditorSearchResolver.matches(in: text, query: trimmed).isEmpty }
        let byName = all.filter { matches($0.entity.title) }
            .sorted { $0.entity.title.localizedStandardCompare($1.entity.title) == .orderedAscending }
        guard searchingContents else { return byName }
        let named = Set(byName.map(\.entity.id))
        let byContents = all.filter { note in
            guard !named.contains(note.entity.id) else { return false }
            guard let text = overrides[FilesStore.key(note.url)] ?? contents(note.url) else { return false }
            return matches(text)
        }
        return byName + byContents
    }

    private func root(containing url: URL) -> Root? {
        let path = FilesStore.key(url)
        return roots.first { path.hasPrefix(FilesStore.key($0.folder) + "/") }
    }

    private func isExcluded(_ url: URL) -> Bool {
        let path = FilesStore.key(url)
        return excludedFolders.contains { path.hasPrefix(FilesStore.key($0) + "/") }
    }
}

/// Appending to a note's text, keeping the file's own line endings.
enum PhoneNoteText {
    /// `text` with `addition` at the end, on a line of its own. The addition takes the text's line
    /// ending (CRLF when the text has one, else LF); a text that ended with a line break still
    /// does. Nothing to add leaves the text as it is.
    static func appending(_ addition: String, to text: String) -> String {
        guard !addition.isEmpty else { return text }
        let ending = text.contains("\r\n") ? "\r\n" : "\n"
        var added = addition.replacingOccurrences(of: "\r\n", with: "\n")
        if ending == "\r\n" { added = added.replacingOccurrences(of: "\n", with: "\r\n") }
        guard !text.isEmpty else { return added }
        // `Character.isNewline` sees "\r\n" as one line break.
        if text.last?.isNewline == true {
            return text + added + (added.last?.isNewline == true ? "" : ending)
        }
        return text + ending + added
    }

    /// One coordinated read-and-write of the file at `url` (read first, so iCloud brings the latest
    /// version in), through `MarkdownFileCodec` both ways: a BOM and CRLF endings are kept. False
    /// when it could not be read as text or written.
    static func append(_ addition: String, toFileAt url: URL, writer: any DocumentFileWriting = FileSystemDocumentWriter()) -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var succeeded = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], writingItemAt: url, options: .forMerging, error: &coordinationError
        ) { readURL, writeURL in
            guard let data = try? Data(contentsOf: readURL), let text = MarkdownFileCodec.decode(data) else { return }
            do {
                try writer.write(MarkdownFileCodec.encode(appending(addition, to: text)), to: writeURL, replaceExisting: true)
                succeeded = true
            } catch {}
        }
        return coordinationError == nil && succeeded
    }
}

extension OpenDocument {
    /// The whole new text from an intent, as a Read edit is applied: through the editor (one
    /// ranged edit, one undo step) or, with no editor mounted, through `edit`. False when the
    /// editor refused it (an AI review is up, or an input method is composing).
    func applyIntentEdit(_ newText: String) -> Bool {
        guard newText != text else { return true }
        if let readEditor { return readEditor.applyReadEdit(newText) }
        edit(newText)
        return true
    }
}

extension PhoneIntentRouter {
    /// How long Add and Get wait for a screen that is coming up before going to the file itself.
    static let attachWait: Duration = .seconds(10)

    /// The attached document when `url` is its file.
    func document(showing url: URL) -> OpenDocument? {
        guard let document = attachedDocument, let open = document.url,
              FilesStore.key(open) == FilesStore.key(OpenDocument.realURL(for: url))
        else { return nil }
        return document
    }

    /// Add to Lineform Note: through the document on screen when it is that note (then flushed,
    /// so the file has it when the shortcut goes on), otherwise one coordinated write of the file.
    func append(_ addition: String, toNoteAt url: URL) async throws {
        guard !addition.isEmpty else { return }
        await waitForAComingScreen()
        if let document = document(showing: url) {
            guard document.applyIntentEdit(PhoneNoteText.appending(addition, to: document.text)),
                  await document.flush()
            else { throw LineformShortcutError.couldNotAddText }
            return
        }
        let file = OpenDocument.realURL(for: url)
        let appended = await Task.detached { PhoneNoteText.append(addition, toFileAt: file) }.value
        guard appended else { throw LineformShortcutError.couldNotAddText }
    }

    /// Get Note Text: the document on screen's text when it is that note (what the writer sees,
    /// unsaved edits included), otherwise the file's, read with coordination.
    func text(ofNoteAt url: URL) async throws -> String {
        await waitForAComingScreen()
        if let document = document(showing: url) { return document.text }
        let file = OpenDocument.realURL(for: url)
        guard let text = await Task.detached(operation: { FileSystemDiskReader().readText(at: file) }).value else {
            throw LineformShortcutError.couldNotReadNote
        }
        return text
    }

    /// The on-screen document's text, keyed by `FilesStore.key`, for Find Notes.
    func openDocumentOverrides() -> [String: String] {
        guard let document = attachedDocument, let url = document.url else { return [:] }
        return [FilesStore.key(url): document.text]
    }
}

/// Add to Lineform Note: puts text at the end of a note, on a line of its own.
struct AddToLineformNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Lineform Note"
    static let description = IntentDescription("Adds text to the end of a Lineform note.")

    @Parameter(title: "Note")
    var note: LineformNoteEntity

    @Parameter(title: "Text", description: "The text to add to the end of the note.")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$note)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let id = note.id
        guard let url = await PhoneNoteLibrary.live().url(forID: id) else { throw LineformShortcutError.couldNotReadNote }
        try await PhoneIntentRouter.shared.append(text, toNoteAt: url)
        return .result()
    }
}

/// Get Note Text: a note's text, for the next action.
struct GetLineformNoteTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Note Text"
    static let description = IntentDescription("Gets the text of a Lineform note.")

    @Parameter(title: "Note")
    var note: LineformNoteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the text of \(\.$note)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = note.id
        guard let url = await PhoneNoteLibrary.live().url(forID: id) else { throw LineformShortcutError.couldNotReadNote }
        return .result(value: try await PhoneIntentRouter.shared.text(ofNoteAt: url))
    }
}

/// Find Notes: notes by name, and optionally by what they contain.
struct FindLineformNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Notes"
    static let description = IntentDescription("Finds Lineform notes by name, and optionally by what they contain.")

    @Parameter(title: "Name", default: "")
    var name: String

    @Parameter(title: "Search Contents", default: false)
    var searchesContents: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Find notes matching \(\.$name)") {
            \.$searchesContents
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[LineformNoteEntity]> {
        let query = name
        let searchesContents = searchesContents
        let overrides = PhoneIntentRouter.shared.openDocumentOverrides()
        let library = await PhoneNoteLibrary.live()
        let found = await Task.detached {
            library.find(query, searchingContents: searchesContents, overrides: overrides).map(\.entity)
        }.value
        return .result(value: found)
    }
}

/// Open Lineform Note: opens a note picked in Shortcuts or Siri, or tapped in Spotlight, through
/// Open in Lineform's path (the current document is saved first).
struct OpenLineformNoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Lineform Note"
    static let description = IntentDescription("Opens a note in Lineform.")

    @Parameter(title: "Note")
    var target: LineformNoteEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let id = target.id
        guard let url = await PhoneNoteLibrary.live().url(forID: id) else { throw LineformShortcutError.couldNotOpen }
        try await PhoneIntentRouter.shared.handle(.open(url))
        return .result()
    }
}

// MARK: - Spotlight

/// Keeps Spotlight's list of notes current: each note's title and location as a
/// `LineformNoteEntity`, never its text. Refreshed (debounced) when the app becomes active, when
/// the open document gets, changes or loses its file, and when Files rescans a root. The first
/// refresh in a process replaces everything Lineform indexed; later ones send only the change.
/// Inert under XCTest (`shared`), so the test host never talks to Spotlight.
@MainActor
final class PhoneSpotlightIndex {
    static let shared = PhoneSpotlightIndex(isEnabled: !LineformiOSApp.isRunningUnderTests)

    struct Change: Equatable {
        /// Drop everything indexed before (the first refresh in a process).
        var replacesAll: Bool
        var removedIDs: [String]
        var indexed: [LineformNoteEntity]

        var isEmpty: Bool { !replacesAll && removedIDs.isEmpty && indexed.isEmpty }
    }

    static let debounce: Duration = .seconds(2)

    private let isEnabled: Bool
    /// What Spotlight has from this process, by id; nil before the first refresh.
    private var indexed: [String: LineformNoteEntity]?
    private var refreshTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.lineform.app", category: "spotlight")

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// What to send Spotlight to go from `old` (nil: unknown, replace all) to `notes`.
    nonisolated static func change(from old: [String: LineformNoteEntity]?, to notes: [LineformNoteEntity]) -> Change {
        guard let old else { return Change(replacesAll: true, removedIDs: [], indexed: notes) }
        let new = Set(notes.map(\.id))
        let removed = old.keys.filter { !new.contains($0) }.sorted()
        let changed = notes.filter { old[$0.id] != $0 }
        return Change(replacesAll: false, removedIDs: removed, indexed: changed)
    }

    /// Refreshes `debounce` after the last call.
    func scheduleRefresh() {
        guard isEnabled else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        let library = await PhoneNoteLibrary.live()
        let notes = await Task.detached { library.notes().map(\.entity) }.value
        let change = Self.change(from: indexed, to: notes)
        guard !change.isEmpty else { return }
        do {
            try await Self.send(change)
            indexed = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            log.error("Spotlight could not be updated: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func send(_ change: Change) async throws {
        let index = CSSearchableIndex.default()
        if change.replacesAll {
            try await index.deleteAppEntities(ofType: LineformNoteEntity.self)
        } else if !change.removedIDs.isEmpty {
            try await index.deleteAppEntities(identifiedBy: change.removedIDs, ofType: LineformNoteEntity.self)
        }
        if !change.indexed.isEmpty {
            try await index.indexAppEntities(change.indexed)
        }
    }
}

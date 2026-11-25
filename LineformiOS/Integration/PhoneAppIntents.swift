import AppIntents
import Foundation
import LineformCore

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
    }
}

enum LineformShortcutError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    /// The Mac's case, kept for its string; the iPhone reads a URL-less file's data instead.
    case noFileURL
    /// The file could not be read, or its open failed or was overtaken.
    case couldNotOpen
    /// New Lineform Note could neither open the note nor write it into the save folder.
    case newNoteNotSaved

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noFileURL, .couldNotOpen: return "That file couldn't be opened in Lineform."
        case .newNoteNotSaved: return "Lineform couldn't save the new note."
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

    /// The screen's document, ready. Runs whatever arrived before it, in order, and resumes each
    /// waiting intent with its outcome.
    func attach(_ document: OpenDocument) async {
        self.document = document
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

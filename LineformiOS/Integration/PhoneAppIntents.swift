import AppIntents
import Foundation

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
        await PhoneIntentRouter.shared.handle(.newNote(text))
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
        guard let url = file.fileURL else {
            throw LineformShortcutError.noFileURL
        }
        await PhoneIntentRouter.shared.handle(.open(url))
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

enum LineformShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case noFileURL

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noFileURL: return "That file couldn't be opened in Lineform."
        }
    }
}

/// Hands an intent to the open document. The screen attaches its document once `prepare` (and the
/// launch restore) is done; an intent that arrives earlier, as on a cold launch, waits for it, so a
/// restore never lands over the note or file the writer asked for.
@MainActor
final class PhoneIntentRouter {
    static let shared = PhoneIntentRouter()

    enum Request: Equatable {
        case newNote(String)
        case open(URL)
    }

    private weak var document: OpenDocument?
    private var pending: [Request] = []

    /// The screen's document, ready. Runs whatever arrived before it, in order.
    func attach(_ document: OpenDocument) async {
        self.document = document
        let queued = pending
        pending = []
        for request in queued {
            await Self.perform(request, on: document)
        }
    }

    func handle(_ request: Request) async {
        guard let document else {
            pending.append(request)
            return
        }
        await Self.perform(request, on: document)
    }

    /// New Note: save the current document, start a blank one, and put the text in it (it then
    /// autosaves like typing). Open: `openReportingFailure`, so an unreadable file shows the
    /// screen's "couldn't be opened" alert.
    private static func perform(_ request: Request, on document: OpenDocument) async {
        switch request {
        case .newNote(let text):
            guard await document.newDocument() else { return }
            if !text.isEmpty { document.edit(text) }
        case .open(let url):
            await document.openReportingFailure(url)
        }
    }
}

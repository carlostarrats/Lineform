import AppIntents
import AppKit

// Apple Shortcuts / Spotlight / Siri integration (and Raycast, which runs any Shortcut). Two
// deliberately minimal, local-first actions — no network, no new entitlement:
//
//   • New Lineform Note — opens Lineform with a note pre-filled from the given text.
//   • Open in Lineform — opens a Markdown/text file in Lineform.
//
// Both are foreground intents (they present a window). Opening always routes through Launch
// Services targeting THIS app bundle, so it lands in Lineform (never TextEdit for a .txt) and the
// sandbox grants access to a user-picked file the same way a Finder double-click does. A new note
// is staged into the app's OWN container (always writable under the sandbox) and opened through the
// document system, so it becomes a real, autosaving document the user can then Save As anywhere —
// mirroring the `lineform -` piped-stdin CLI path.

struct NewLineformNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Lineform Note"
    static let description = IntentDescription("Opens a new note in Lineform, pre-filled with the given text. Save it wherever you like.")
    static let openAppWhenRun = true

    @Parameter(title: "Text", description: "The note's starting text.", default: "")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let url = try LineformShortcutSupport.stageNote(text: text)
        LineformShortcutSupport.openInLineform(url)
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
        LineformShortcutSupport.openInLineform(url)
        return .result()
    }
}

/// Registers the intents with the system so they appear in Shortcuts, Spotlight, and Siri (and can
/// be run from Raycast's Shortcuts support) with no user setup.
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

enum LineformShortcutSupport {
    /// Open `url` in THIS app via Launch Services, targeting the app bundle explicitly so a `.txt`
    /// can't open in TextEdit and so a user-picked file gets a Powerbox grant (as with a double
    /// click). Works whether Lineform is already running or being launched to service the intent.
    @MainActor
    static func openInLineform(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
    }

    /// Write the note text to a uniquely named `.md` in the app's container and return its URL. The
    /// document system opens it as a real (autosaving) document; the user can Save As elsewhere.
    /// Staged notes older than 7 days are pruned so the folder doesn't accumulate.
    static func stageNote(text: String) throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Lineform/ShortcutNotes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneOldNotes(in: directory)

        let name = uniqueFileName(for: text, in: directory)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private static func uniqueFileName(for text: String, in directory: URL) -> String {
        let title = noteTitle(from: text)
        var candidate = "\(title).md"
        var counter = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            counter += 1
            candidate = "\(title) \(counter).md"
        }
        return candidate
    }

    /// A tidy filename derived from the first non-empty line (heading markers stripped), or
    /// "New Note". Affects only the file's NAME — the note's content is written verbatim.
    private static func noteTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let withoutMarkers = firstLine
            .trimmingCharacters(in: .whitespaces)
            .drop { $0 == "#" }
            .trimmingCharacters(in: .whitespaces)
        // Reject the characters a FILENAME cannot carry, rather than allow-listing ASCII. The old
        // allow-list dropped every non-ASCII letter, so an accented title lost its accents and a
        // CJK, Cyrillic, or Arabic note produced an empty string and was filed as "New Note" —
        // every such note colliding on one name. APFS and HFS+ accept any Unicode except `/` and
        // NUL; `:` is excluded because Finder still presents it as a path separator.
        let forbidden = Set("/:\0")
        let cleaned = String(withoutMarkers.filter { character in
            !character.unicodeScalars.contains { forbidden.contains(Character($0)) || $0.properties.isDefaultIgnorableCodePoint }
                && !character.isNewline
        })
        .trimmingCharacters(in: .whitespaces)
        let limited = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
        // A leading dot would make the note a hidden file the user cannot find in Finder, and
        // "." / ".." are not usable names at all.
        guard !limited.isEmpty, !limited.hasPrefix(".") else { return "New Note" }
        return limited
    }

    private static func pruneOldNotes(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .contentAccessDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for item in items {
            let values = try? item.resourceValues(forKeys: keys)
            // Prune only when the file has been untouched — neither modified NOR accessed — since the
            // cutoff, so a staged note still open in a window (its file was read when opened, which
            // refreshes the access date) is never deleted out from under the document.
            let lastTouched = [values?.contentModificationDate, values?.contentAccessDate]
                .compactMap { $0 }
                .max()
            if let lastTouched, lastTouched < cutoff {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}

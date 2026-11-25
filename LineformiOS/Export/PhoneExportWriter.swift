import Foundation
import LineformCore

/// Writes an export to a file the share sheet can hand on. Each export goes into its own fresh
/// folder (a UUID) under `folder`, so two quick exports never share a path and one never replaces
/// a file another share sheet still holds. The file is named from the document's base name,
/// sanitized so it can never leave that folder. `removeAll()` clears `folder`: at launch, and
/// after the share sheet closes.
@MainActor
struct PhoneExportWriter {
    enum WriteError: Error {
        /// The export produced no bytes.
        case empty
    }

    let folder: URL

    init(folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)) {
        self.folder = folder
    }

    func write(
        _ format: PhoneExportFormat,
        text: String,
        baseName: String,
        profile: ReadingProfile,
        paper: ExportPaperSize,
        documentDirectory: URL?
    ) throws -> URL {
        let name = Self.sanitizedBaseName(baseName)
        let data: Data
        switch format {
        case .html:
            data = ExportContent.htmlData(text: text, title: name)
        case .pdf:
            data = PhonePDFRenderer.pdfData(
                text: text, profile: profile, paper: paper, preset: .standard, documentDirectory: documentDirectory
            )
        case .markdown:
            // The document's text exactly as it is, UTF-8: nothing rendered, nothing rewritten.
            data = Data(text.utf8)
        }
        // An empty render is a failure; an empty document's Markdown is just an empty file.
        guard !data.isEmpty || format == .markdown else { throw WriteError.empty }

        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A file name from a document's base name: no `/` or `:`, no control characters, no leading
    /// dots (no hidden file, no `..`), trimmed; "Untitled" when nothing is left.
    static func sanitizedBaseName(_ baseName: String) -> String {
        let kept = String(String.UnicodeScalarView(baseName.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != ":" && !CharacterSet.controlCharacters.contains(scalar)
        }))
        var name = Substring(kept.trimmingCharacters(in: .whitespacesAndNewlines))
        while name.first == "." { name = name.dropFirst() }
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? String(localized: "Untitled") : result
    }

    /// Deletes every export in `folder`.
    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}

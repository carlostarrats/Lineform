import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown")
}

struct LineformDocument: FileDocument, Equatable {
    static var readableContentTypes: [UTType] {
        [.markdownText, .plainText]
    }

    static var writableContentTypes: [UTType] {
        [.markdownText, .plainText]
    }

    let id: UUID
    var text: String
    var textFormat: LineformTextFormat
    var plainTextConversion: MarkdownPlainTextConversion?

    init(
        text: String = "",
        id: UUID = UUID(),
        textFormat: LineformTextFormat = .markdown,
        plainTextConversion: MarkdownPlainTextConversion? = nil
    ) {
        self.id = id
        self.text = text
        self.textFormat = textFormat
        self.plainTextConversion = plainTextConversion
    }

    init(markdownData: Data, id: UUID = UUID(), textFormat: LineformTextFormat = .markdown) throws {
        // Validate with `String(data:encoding:)` — it returns nil on invalid UTF-8, which is how
        // a corrupt file is rejected rather than repaired. Decode with `String(decoding:as:)`,
        // because the validating initializer ALSO strips a leading U+FEFF on Darwin: the BOM then
        // never reaches `text`, `markdownData()` cannot re-emit it, and the first write silently
        // drops three bytes from the head of every Notepad-authored file. This is the same rule
        // as the CRLF one — Lineform never normalises a file's byte-level conventions for the
        // writer — and it is what makes the BOM handling in the parsing layer reachable at all.
        guard String(data: markdownData, encoding: .utf8) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }

        self.id = id
        text = String(decoding: markdownData, as: UTF8.self)
        self.textFormat = textFormat
        plainTextConversion = nil
    }

    init(contentsOf url: URL, id: UUID = UUID()) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let contentType = Self.contentType(for: url)
        try self.init(
            markdownData: Data(contentsOf: url),
            id: id,
            textFormat: contentType == .plainText ? .plainText : .markdown
        )
    }

    init(fileWrapper: FileWrapper, contentType: UTType, id: UUID = UUID()) throws {
        guard fileWrapper.isRegularFile, let data = fileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let textFormat: LineformTextFormat = contentType == .plainText ? .plainText : .markdown
        try self.init(markdownData: data, id: id, textFormat: textFormat)
    }

    init(configuration: ReadConfiguration) throws {
        let documentID = UUID()
        try self.init(fileWrapper: configuration.file, contentType: configuration.contentType, id: documentID)

        if let modificationDate = Self.modificationDate(from: configuration.file) {
            let loadedText = text
            Task { @MainActor in
                DocumentSaveStatus.shared.markSaved(documentID: documentID, at: modificationDate, text: loadedText)
            }
        }
    }

    func markdownData() -> Data {
        Data(text.utf8)
    }

    func plainTextData() -> Data {
        Data(MarkdownPlainTextConverter.plainText(from: text).utf8)
    }

    @discardableResult
    mutating func convertMarkdownToPlainText(selectedRange: NSRange? = nil) -> NSRange? {
        guard textFormat == .markdown else {
            return plainTextConversion?.range
        }

        let nsText = text as NSString
        let conversionRange: NSRange
        if let selectedRange, selectedRange.length > 0 {
            conversionRange = selectedRange
        } else {
            conversionRange = NSRange(location: 0, length: nsText.length)
        }

        guard conversionRange.length > 0, NSMaxRange(conversionRange) <= nsText.length else {
            return nil
        }

        let originalMarkdown = nsText.substring(with: conversionRange)
        let plainText = MarkdownPlainTextConverter.plainText(from: originalMarkdown)
        let replacementRange = NSRange(location: conversionRange.location, length: (plainText as NSString).length)

        guard let swiftRange = Range(conversionRange, in: text) else {
            return nil
        }

        text.replaceSubrange(swiftRange, with: plainText)
        plainTextConversion = MarkdownPlainTextConversion(
            originalMarkdown: originalMarkdown,
            plainText: plainText,
            range: replacementRange
        )
        textFormat = .plainText
        return replacementRange
    }

    @discardableResult
    mutating func restoreConvertedMarkdown() -> NSRange? {
        if
            let conversion = plainTextConversion,
            let edit = conversion.restoredMarkdown(in: text)
        {
            text = edit.text
            plainTextConversion = nil
            textFormat = .markdown
            return edit.selectedRange
        }

        // Only a document that actually holds a conversion goes back to `.markdown`. A `.txt`
        // file opened from disk has `textFormat == .plainText` and no conversion, and flipping it
        // here made the next write take the lossy `plainTextData()` branch — running the Markdown
        // stripper over the user's plain-text file and deleting its fenced-code lines, link URLs,
        // and every leading marker.
        plainTextConversion = nil
        return nil
    }

    /// True when a write for `contentType` emits the in-memory `text` byte-for-byte.
    ///
    /// `data(for:)` and `recordsSourceSave(for:)` are two halves of one question and MUST be
    /// derived from this single predicate. When they were written separately they disagreed for
    /// `.markdownText` + `.plainText` — the state Convert to Plain Text leaves a `.md` document in
    /// — so that write emitted the source verbatim while recording nothing: no "Saved" flash, a
    /// permanently amber status bar, a frozen dirty hash, and a `lastSyncedText` baseline that
    /// stopped updating (which disables live reload and the background-tab disk reconcile).
    func writesSourceVerbatim(for contentType: UTType) -> Bool {
        contentType != .plainText || textFormat == .plainText
    }

    func data(for contentType: UTType) throws -> Data {
        writesSourceVerbatim(for: contentType) ? markdownData() : plainTextData()
    }

    func recordsSourceSave(for contentType: UTType) -> Bool {
        writesSourceVerbatim(for: contentType)
    }

    static func modificationDate(from fileWrapper: FileWrapper) -> Date? {
        fileWrapper.fileAttributes[FileAttributeKey.modificationDate.rawValue] as? Date
    }

    static func contentType(for url: URL) -> UTType {
        if url.pathExtension.localizedCaseInsensitiveCompare("txt") == .orderedSame {
            return .plainText
        }

        return .markdownText
    }

    /// Stat through `FileManager`, never `url.resourceValues(forKeys:)`.
    ///
    /// `URL` caches resource values on the instance, and `DocumentReloadController` re-uses one
    /// stored `URL` for the life of the watch. With the caching read, the modification date froze
    /// at whatever the first stat saw, so `reloadFromDisk`'s `modificationDate == lastSeen`
    /// pre-check short-circuited forever: live reload fired at most once per file, and every
    /// later external rewrite produced no reload and no "Updated" flash while the editor kept
    /// showing — and kept autosaving — the stale snapshot.
    static func modificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try data(for: configuration.contentType)
        if recordsSourceSave(for: configuration.contentType) {
            let documentID = id
            let savedText = text
            Task { @MainActor in
                DocumentSaveStatus.shared.recordWrite(documentID: documentID, text: savedText)
            }
        }

        return FileWrapper(regularFileWithContents: data)
    }

    static func == (lhs: LineformDocument, rhs: LineformDocument) -> Bool {
        lhs.text == rhs.text && lhs.textFormat == rhs.textFormat
    }
}

@MainActor
final class DocumentSaveStatus: ObservableObject {
    static let shared = DocumentSaveStatus()

    enum SaveKind: Equatable { case manual, autosave }

    struct SaveEvent: Equatable {
        let documentID: UUID
        let kind: SaveKind
        let sequence: Int
    }

    @Published private var savedAtByDocumentID: [UUID: Date] = [:]
    private var savedTextByDocumentID: [UUID: String] = [:]
    /// Hash of the last text written per document, used for dirty detection. Kept
    /// separately from `savedTextByDocumentID` (which is capped for memory and only
    /// feeds the reload baseline) because dirty detection has no live fallback: if it
    /// were pruned, an open document would silently stop showing "Unsaved changes".
    /// This map is tiny (one Int per doc) and shares `savedAt`'s never-pruned lifetime.
    private var savedTextHashByDocumentID: [UUID: Int] = [:]

    /// A transient signal published for each real write so the status bar can flash
    /// a green "Saved"/"Autosaved" confirmation. Distinct `sequence` per event so
    /// `.onChange` fires even for repeated kinds.
    @Published private(set) var lastSaveEvent: SaveEvent?
    /// Set when the user invokes Save / Save As, cleared when consumed by a write or
    /// invalidated by an edit (see `noteUserEdit`). A one-shot flag rather than a timed
    /// window so it survives a slow `NSSavePanel` interaction (Save As, first save of an
    /// untitled doc) without misclassifying the resulting write as an autosave.
    private var pendingManualSave = false
    private var writeSequence = 0

    private init() {}

    func savedAt(for documentID: UUID) -> Date? {
        savedAtByDocumentID[documentID]
    }

    /// True when the live text differs from the last text written to disk. Untitled
    /// documents (no recorded save) are never "dirty" — their state is shown as
    /// "Not saved yet" instead.
    func isDirty(documentID: UUID, currentText: String) -> Bool {
        guard savedAtByDocumentID[documentID] != nil else { return false }
        guard let savedHash = savedTextHashByDocumentID[documentID] else { return false }
        return savedHash != currentText.hashValue
    }

    /// Records that the user just invoked Save / Save As, so the next real write is
    /// attributed to the user ("Saved") rather than an autosave ("Autosaved").
    func noteManualSaveIntent() {
        pendingManualSave = true
    }

    /// Called when the user edits the document. A pending manual-save intent that has
    /// not yet produced a write is cleared, because the next write will be an autosave
    /// of this new edit — not the earlier ⌘S/Save As. (During a modal save panel the
    /// document can't be edited, so a legitimate panel save keeps its intent.)
    func noteUserEdit() {
        pendingManualSave = false
    }

    private func consumeManualSaveIntent() -> Bool {
        let manual = pendingManualSave
        pendingManualSave = false
        return manual
    }

    /// Called from the document write path for a real save. Updates the saved
    /// date/text baseline and publishes a classified event for the status flash.
    func recordWrite(documentID: UUID, text: String) {
        let manual = consumeManualSaveIntent()
        markSaved(documentID: documentID, at: Date(), text: text)
        writeSequence += 1
        lastSaveEvent = SaveEvent(documentID: documentID, kind: manual ? .manual : .autosave, sequence: writeSequence)
    }

    /// The exact text that was written by the save this `savedAt` describes. The live reload
    /// baseline uses this instead of the live document text, which may already contain
    /// keystrokes typed after the save snapshot was taken.
    func savedText(for documentID: UUID) -> String? {
        savedTextByDocumentID[documentID]
    }

    func markSaved(documentID: UUID, at date: Date = Date(), text: String? = nil) {
        if let text {
            savedTextByDocumentID[documentID] = text
            savedTextHashByDocumentID[documentID] = text.hashValue
        }
        savedAtByDocumentID[documentID] = date
        pruneSavedTexts(keeping: documentID)
    }

    /// Saved texts are full document contents; don't retain them for every document ever
    /// touched in the session. Keep the most recently saved few — enough for every open
    /// window in normal use — and let a fallback (the live text) cover the rest.
    private func pruneSavedTexts(keeping documentID: UUID) {
        let cap = 8
        guard savedTextByDocumentID.count > cap else { return }
        let byAge = savedTextByDocumentID.keys.sorted {
            (savedAtByDocumentID[$0] ?? .distantPast) < (savedAtByDocumentID[$1] ?? .distantPast)
        }
        for staleID in byAge where staleID != documentID {
            guard savedTextByDocumentID.count > cap else { break }
            savedTextByDocumentID.removeValue(forKey: staleID)
        }
    }
}

#if DEBUG
extension DocumentSaveStatus {
    /// Isolated instance for tests so they don't mutate the shared singleton.
    static func testInstance() -> DocumentSaveStatus { DocumentSaveStatus() }
}
#endif

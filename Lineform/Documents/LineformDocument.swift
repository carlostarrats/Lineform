import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import LineformCore

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
        // `MarkdownFileCodec` rejects invalid UTF-8 rather than repairing it, and keeps a leading
        // U+FEFF and CRLF line endings exactly as they are on disk (the reasons are on the codec).
        guard let decoded = MarkdownFileCodec.decode(markdownData) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        self.id = id
        text = decoded
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
        MarkdownFileCodec.encode(text)
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

    /// Stat through `FileManager`, never `url.resourceValues(forKeys:)`: the reasons are on
    /// `FileSystemDiskReader.modificationDate(at:)`, which this forwards to.
    static func modificationDate(at url: URL) -> Date? {
        FileSystemDiskReader().modificationDate(at: url)
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

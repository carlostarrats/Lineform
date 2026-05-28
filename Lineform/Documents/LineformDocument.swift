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
        [.markdownText, .plainText, .pdf]
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
        guard let decodedText = String(data: markdownData, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        self.id = id
        text = decodedText
        self.textFormat = textFormat
        plainTextConversion = nil
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
            Task { @MainActor in
                DocumentSaveStatus.shared.markSaved(documentID: documentID, at: modificationDate)
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

        plainTextConversion = nil
        textFormat = .markdown
        return nil
    }

    func data(for contentType: UTType) throws -> Data {
        switch contentType {
        case .pdf:
            return pdfData()
        case .plainText:
            return textFormat == .plainText ? markdownData() : plainTextData()
        default:
            return markdownData()
        }
    }

    func recordsSourceSave(for contentType: UTType) -> Bool {
        switch textFormat {
        case .markdown:
            return contentType == .markdownText
        case .plainText:
            return contentType == .plainText
        }
    }

    func pdfData() -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 72
        let textRect = pageRect.insetBy(dx: margin, dy: margin)
        let renderedText = MarkdownPlainTextConverter.plainText(from: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4

        let attributedText = NSAttributedString(
            string: renderedText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph
            ]
        )

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            return Data()
        }

        var mediaBox = pageRect
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        repeat {
            let textContainer = NSTextContainer(size: textRect.size)
            textContainer.lineFragmentPadding = 0
            layoutManager.addTextContainer(textContainer)

            let glyphRange = layoutManager.glyphRange(for: textContainer)
            guard glyphRange.length > 0 else {
                break
            }

            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: textRect.origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: textRect.origin)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        } while layoutManager.textContainers.count < layoutManager.numberOfGlyphs

        context.closePDF()

        return data as Data
    }

    static func modificationDate(from fileWrapper: FileWrapper) -> Date? {
        fileWrapper.fileAttributes[FileAttributeKey.modificationDate.rawValue] as? Date
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try data(for: configuration.contentType)
        if recordsSourceSave(for: configuration.contentType) {
            let documentID = id
            Task { @MainActor in
                DocumentSaveStatus.shared.markSaved(documentID: documentID)
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

    @Published private var savedAtByDocumentID: [UUID: Date] = [:]

    private init() {}

    func savedAt(for documentID: UUID) -> Date? {
        savedAtByDocumentID[documentID]
    }

    func markSaved(documentID: UUID, at date: Date = Date()) {
        savedAtByDocumentID[documentID] = date
    }
}

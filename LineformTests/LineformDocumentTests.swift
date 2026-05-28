import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Lineform

final class LineformDocumentTests: XCTestCase {
    func testNewDocumentStartsWithEmptyMarkdownText() {
        let document = LineformDocument()

        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.textFormat, .markdown)
    }

    func testDocumentReadsUTF8MarkdownData() throws {
        let source = Data("# Title\n\nPortable Markdown.\n".utf8)

        let document = try LineformDocument(markdownData: source)

        XCTAssertEqual(document.text, "# Title\n\nPortable Markdown.\n")
    }

    func testExtractsFileWrapperModificationDateForOpenedDocuments() throws {
        let savedDate = try XCTUnwrap(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            year: 2026,
            month: 5,
            day: 26,
            hour: 10,
            minute: 32
        ).date)
        let fileWrapper = FileWrapper(regularFileWithContents: Data("Saved markdown".utf8))
        fileWrapper.fileAttributes = [
            FileAttributeKey.type.rawValue: FileAttributeType.typeRegular.rawValue,
            FileAttributeKey.posixPermissions.rawValue: 0o644,
            FileAttributeKey.modificationDate.rawValue: savedDate
        ]

        XCTAssertEqual(LineformDocument.modificationDate(from: fileWrapper), savedDate)
    }

    func testDocumentWritesPlainUTF8MarkdownData() throws {
        let document = LineformDocument(text: "Lineform keeps files plain.\n")

        XCTAssertEqual(document.markdownData(), Data("Lineform keeps files plain.\n".utf8))
    }

    func testDocumentAdvertisesMarkdownAndPlainTextTypes() {
        XCTAssertTrue(LineformDocument.readableContentTypes.contains(.markdownText))
        XCTAssertTrue(LineformDocument.readableContentTypes.contains(.plainText))
        XCTAssertTrue(LineformDocument.writableContentTypes.contains(.markdownText))
        XCTAssertTrue(LineformDocument.writableContentTypes.contains(.plainText))
        XCTAssertTrue(LineformDocument.writableContentTypes.contains(.pdf))
    }

    func testDocumentCanRenderPDFDataForSavePanel() {
        let document = LineformDocument(text: "# Title\n\nPortable **Markdown**.\n")

        let pdfData = document.pdfData()

        XCTAssertTrue(pdfData.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(pdfData.count, 100)
    }

    func testPDFExportPaginatesLongDocuments() throws {
        let longText = (1...220)
            .map { "Line \($0): Lineform keeps Markdown files portable across normal file tools." }
            .joined(separator: "\n")
        let document = LineformDocument(text: longText)

        let pdfData = document.pdfData()
        let provider = try XCTUnwrap(CGDataProvider(data: pdfData as CFData))
        let pdfDocument = try XCTUnwrap(CGPDFDocument(provider))

        XCTAssertGreaterThan(pdfDocument.numberOfPages, 1)
    }

    func testPlainTextSaveWritesPlainTextWithoutMarkdownMarkers() throws {
        let document = LineformDocument(text: "# Title\n\nPortable **Markdown**.\n")

        XCTAssertEqual(document.plainTextData(), Data("Title\n\nPortable Markdown.\n".utf8))
    }

    func testPlainTextDocumentSavePreservesLiteralMarkdownLookingText() throws {
        let source = "# Not a heading\n- Not a list marker\n**Literal stars** and `literal ticks`\n"
        let document = LineformDocument(text: source, textFormat: .plainText)

        let data = try document.data(for: .plainText)

        XCTAssertEqual(data, Data(source.utf8))
    }

    func testReadConfigurationRejectsNonRegularFileWrappers() throws {
        let directoryWrapper = FileWrapper(directoryWithFileWrappers: [:])

        XCTAssertThrowsError(
            try LineformDocument(fileWrapper: directoryWrapper, contentType: .plainText)
        )
    }

    func testOnlyNativeDocumentSavesUpdateLastSavedStatus() {
        let markdownDocument = LineformDocument(text: "# Title", textFormat: .markdown)
        let plainTextDocument = LineformDocument(text: "# Literal", textFormat: .plainText)

        XCTAssertTrue(markdownDocument.recordsSourceSave(for: .markdownText))
        XCTAssertFalse(markdownDocument.recordsSourceSave(for: .plainText))
        XCTAssertFalse(markdownDocument.recordsSourceSave(for: .pdf))
        XCTAssertTrue(plainTextDocument.recordsSourceSave(for: .plainText))
        XCTAssertFalse(plainTextDocument.recordsSourceSave(for: .markdownText))
        XCTAssertFalse(plainTextDocument.recordsSourceSave(for: .pdf))
    }

    func testDocumentTextFormatConversionRoundTripsMarkdownFromMenuCommandState() {
        var document = LineformDocument(text: "# Title\n\nPortable **Markdown**.\n")

        document.convertMarkdownToPlainText()

        XCTAssertEqual(document.text, "Title\n\nPortable Markdown.\n")
        XCTAssertEqual(document.textFormat, .plainText)
        XCTAssertEqual(document.plainTextConversion?.originalMarkdown, "# Title\n\nPortable **Markdown**.\n")

        document.restoreConvertedMarkdown()

        XCTAssertEqual(document.text, "# Title\n\nPortable **Markdown**.\n")
        XCTAssertEqual(document.textFormat, .markdown)
        XCTAssertNil(document.plainTextConversion)
    }

    func testRepeatedDocumentPlainTextConversionDoesNotOverwriteStoredMarkdownRestore() {
        var document = LineformDocument(text: "# Title\n\nPortable **Markdown**.\n")

        document.convertMarkdownToPlainText()
        document.convertMarkdownToPlainText()
        document.restoreConvertedMarkdown()

        XCTAssertEqual(document.text, "# Title\n\nPortable **Markdown**.\n")
        XCTAssertEqual(document.textFormat, .markdown)
    }

    func testDocumentRejectsInvalidUTF8InsteadOfRepairingBytes() {
        XCTAssertThrowsError(try LineformDocument(markdownData: Data([0xFF, 0xFE, 0x00])))
    }
}

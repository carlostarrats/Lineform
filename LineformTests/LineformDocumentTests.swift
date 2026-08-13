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

    func testHiddenICloudPrefersWorkspaceForAnUntitledSave() {
        let workspace = URL(fileURLWithPath: "/tmp/Lineform Workspace", isDirectory: true)
        let documents = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)

        XCTAssertEqual(
            NewDocumentSaveLocation.preferredDirectory(
                showICloudInSidebar: false,
                workspaceURL: workspace,
                documentsDirectory: documents
            ),
            workspace
        )
    }

    func testHiddenICloudFallsBackToDocumentsForAnUntitledSave() {
        let documents = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)

        XCTAssertEqual(
            NewDocumentSaveLocation.preferredDirectory(
                showICloudInSidebar: false,
                workspaceURL: nil,
                documentsDirectory: documents
            ),
            documents
        )
        XCTAssertNil(
            NewDocumentSaveLocation.preferredDirectory(
                showICloudInSidebar: true,
                workspaceURL: nil,
                documentsDirectory: documents
            )
        )
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
        // PDF is no longer an implicit Save As format — rich PDF export/print is a dedicated
        // command (see DocumentExportRendererTests).
        XCTAssertFalse(LineformDocument.writableContentTypes.contains(.pdf))
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
        XCTAssertTrue(plainTextDocument.recordsSourceSave(for: .plainText))
        // A `.md` document left in `.plainText` by Convert to Plain Text still writes its source
        // verbatim, so that write DOES record. The previous expectation here was `false`, which
        // enshrined the disagreement between `data(for:)` and `recordsSourceSave(for:)`.
        XCTAssertTrue(plainTextDocument.recordsSourceSave(for: .markdownText))
    }

    /// `data(for:)` emits `text` verbatim exactly when `recordsSourceSave(for:)` is true. They are
    /// two halves of one predicate; asserting the agreement directly is what keeps them from
    /// drifting apart again.
    func testVerbatimWritesAreExactlyTheWritesThatRecordASave() throws {
        let source = "# Title\n\nPortable **Markdown**.\n"
        for textFormat in [LineformTextFormat.markdown, .plainText] {
            for contentType in [UTType.markdownText, .plainText] {
                let document = LineformDocument(text: source, textFormat: textFormat)
                let data = try document.data(for: contentType)
                XCTAssertEqual(
                    data == Data(source.utf8),
                    document.recordsSourceSave(for: contentType),
                    "textFormat: \(textFormat), contentType: \(contentType)"
                )
            }
        }
    }

    /// Convert to Markdown on a `.txt` document that was never converted must not flip it into the
    /// state whose next write runs the Markdown stripper over the user's plain-text file.
    func testRestoringMarkdownOnANeverConvertedPlainTextDocumentKeepsTheFileVerbatim() throws {
        let source = "TODO\n# shopping\n- milk\n```\nliteral fence\n```\nSee [the doc](https://example.com/x)\n"
        var document = LineformDocument(text: source, textFormat: .plainText)

        XCTAssertNil(document.restoreConvertedMarkdown())

        XCTAssertEqual(document.textFormat, .plainText)
        XCTAssertEqual(try document.data(for: .plainText), Data(source.utf8))
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

    /// A UTF-8 BOM is part of the user's file, not decoration. `String(data:encoding:)` strips it
    /// on Darwin, so decoding through it silently rewrote the head of every Notepad-authored file
    /// on the first save. Byte-for-byte round-trip is the assertion that matters.
    func testDocumentPreservesALeadingByteOrderMarkThroughAReadWriteRoundTrip() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let source = bom + Data("# Title\r\n\r\nBody.\r\n".utf8)

        let document = try LineformDocument(markdownData: source)

        XCTAssertEqual(document.text.unicodeScalars.first, "\u{FEFF}")
        XCTAssertEqual(document.markdownData(), source)
        XCTAssertEqual(try document.data(for: .markdownText), source)
    }

    /// The reload reader and the document loader must decode identically, or a BOM'd file compares
    /// unequal to its own in-memory text and reloads on every save.
    func testDiskReaderDecodesAByteOrderMarkTheSameWayTheDocumentLoaderDoes() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let source = bom + Data("# Title\n".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bom-\(UUID().uuidString).md")
        try source.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try LineformDocument(markdownData: source)

        XCTAssertEqual(FileSystemDiskReader().readText(at: url), document.text)
    }

    /// `URL` caches resource values per instance, so statting through a stored `URL` froze the
    /// modification date and live reload fired at most once per file. The reader must see a
    /// second external write through the SAME url value it was given the first time.
    func testDiskReaderSeesASecondExternalWriteThroughTheSameURLValue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stat-\(UUID().uuidString).md")
        try Data("one".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = FileSystemDiskReader()
        let first = reader.modificationDate(at: url)

        try Data("two".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
        let second = reader.modificationDate(at: url)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }
}

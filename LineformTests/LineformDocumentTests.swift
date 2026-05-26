import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Lineform

final class LineformDocumentTests: XCTestCase {
    func testNewDocumentStartsWithEmptyMarkdownText() {
        let document = LineformDocument()

        XCTAssertEqual(document.text, "")
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
    }

    func testDocumentRejectsInvalidUTF8InsteadOfRepairingBytes() {
        XCTAssertThrowsError(try LineformDocument(markdownData: Data([0xFF, 0xFE, 0x00])))
    }
}

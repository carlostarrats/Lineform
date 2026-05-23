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

    func testDocumentWritesPlainUTF8MarkdownData() throws {
        let document = LineformDocument(text: "Lineform keeps files plain.\n")

        XCTAssertEqual(document.markdownData(), Data("Lineform keeps files plain.\n".utf8))
    }

    func testDocumentAdvertisesMarkdownAndPlainTextTypes() {
        XCTAssertTrue(LineformDocument.readableContentTypes.contains(.lineformMarkdown))
        XCTAssertTrue(LineformDocument.readableContentTypes.contains(.plainText))
    }
}

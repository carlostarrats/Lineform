import LineformCore
import PDFKit
import UIKit
import XCTest
@testable import LineformiOS

/// The iPhone's export files: HTML titled with the document's name, Normal and Styled PDF, RTF,
/// each in its own fresh folder under the export folder, named from a sanitized base name, and
/// all cleared by `removeAll`. Every test writes into its own temporary folder.
@MainActor
final class PhoneExportWriterTests: XCTestCase {
    private var folder: URL!
    private var writer: PhoneExportWriter!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-writer-\(UUID().uuidString)", isDirectory: true)
        writer = PhoneExportWriter(folder: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ format: PhoneExportFormat, _ text: String, baseName: String = "Notes") throws -> URL {
        try writer.write(format, text: text, baseName: baseName, profile: .original, paper: .usLetter, documentDirectory: nil)
    }

    func testFormatsMatchTheMac() {
        XCTAssertEqual(PhoneExportFormat.allCases, [.html, .pdf, .styledPDF, .rtf])
        XCTAssertEqual(PhoneExportFormat.allCases.map(\.fileExtension), ["html", "pdf", "pdf", "rtf"])
        XCTAssertEqual(PhoneExportFormat.allCases.map(\.usesPaper), [false, true, true, false])
        XCTAssertEqual(PhoneExportFormat.html.title, "HTML")
        XCTAssertEqual(PhoneExportFormat.rtf.title, "Rich Text (.rtf)")
    }

    func testHTMLFileHasDocumentTitle() throws {
        let url = try write(.html, "# Heading\n\nBody.", baseName: "Trip Notes")
        XCTAssertEqual(url.lastPathComponent, "Trip Notes.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>Trip Notes</title>"), html)
        XCTAssertTrue(html.contains("Heading"))
    }

    func testPDFAndStyledPDFDiffer() throws {
        let text = "# Heading\n\nSome **bold** words."
        let normal = try XCTUnwrap(PDFDocument(url: try write(.pdf, text))?.string)
        let styled = try XCTUnwrap(PDFDocument(url: try write(.styledPDF, text))?.string)
        XCTAssertTrue(normal.contains("**"), "Normal prints the source: \(normal)")
        XCTAssertFalse(styled.contains("**"), "Styled renders the Markdown: \(styled)")
        XCTAssertTrue(styled.contains("bold"))
    }

    func testRTFOpensAsRTF() throws {
        let url = try write(.rtf, "# Heading\n\nSome **bold** words.")
        XCTAssertEqual(url.pathExtension, "rtf")
        let attributed = try NSAttributedString(
            url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
        )
        XCTAssertTrue(attributed.string.contains("Heading"), attributed.string)
        XCTAssertTrue(attributed.string.contains("bold words"), attributed.string)
        XCTAssertFalse(attributed.string.contains("**"), attributed.string)
    }

    func testExportFileNameIsSanitizedAndUnique() throws {
        let first = try write(.pdf, "Words.", baseName: "../a/b:c")
        let second = try write(.pdf, "Words.", baseName: "../a/b:c")
        for url in [first, second] {
            let name = url.deletingPathExtension().lastPathComponent
            XCTAssertFalse(name.contains("/"), name)
            XCTAssertFalse(name.contains(":"), name)
            XCTAssertFalse(name.hasPrefix("."), name)
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"),
                          "\(url.path) escaped \(folder.path)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertNotEqual(first, second, "two exports share a path")
        XCTAssertEqual(PhoneExportWriter.sanitizedBaseName("  ..hidden\u{0007}name  "), "hiddenname")
    }

    func testExportNamesUntitled() throws {
        XCTAssertEqual(try write(.pdf, "", baseName: "").lastPathComponent, "Untitled.pdf")
        XCTAssertEqual(PhoneExportWriter.sanitizedBaseName("/:.."), "Untitled")
        XCTAssertEqual(PhoneExportWriter.sanitizedBaseName(" \n "), "Untitled")
    }

    func testRemoveAllClearsFolder() throws {
        let url = try write(.html, "Words.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        writer.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "left behind: \(leftovers)")
        // The writer still works after clearing.
        XCTAssertTrue(FileManager.default.fileExists(atPath: try write(.rtf, "Again.").path))
    }
}

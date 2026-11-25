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

    func testFormatsMatchTheApprovedMockup() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(PhoneExportFormat.allCases, [.pdf, .html, .markdown])
        XCTAssertEqual(PhoneExportFormat.allCases.map(\.fileExtension), ["pdf", "html", "md"])
        XCTAssertEqual(PhoneExportFormat.allCases.map(\.usesPaper), [true, false, false])
        // pinned-en: the mockup's rows.
        XCTAssertEqual(PhoneExportFormat.allCases.map(\.title), ["Export PDF…", "Export HTML…", "Export Markdown…"])
    }

    func testMarkdownExportIsTheTextAsIs() throws {
        let text = "# Heading\r\n\nSome **bold** words, `code`, and é.\n"
        let url = try write(.markdown, text, baseName: "Trip Notes")
        XCTAssertEqual(url.lastPathComponent, "Trip Notes.md")
        XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8), "byte for byte")
        // An empty document exports an empty file, not a failure.
        XCTAssertEqual(try Data(contentsOf: try write(.markdown, "")), Data())
    }

    func testHTMLFileHasDocumentTitle() throws {
        let url = try write(.html, "# Heading\n\nBody.", baseName: "Trip Notes")
        XCTAssertEqual(url.lastPathComponent, "Trip Notes.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>Trip Notes</title>"), html)
        XCTAssertTrue(html.contains("Heading"))
    }

    func testPDFIsTheMacsNormalPDF() throws {
        let text = "# Heading\n\nSome **bold** words."
        let normal = try XCTUnwrap(PDFDocument(url: try write(.pdf, text))?.string)
        XCTAssertTrue(normal.contains("**"), "Normal prints the source: \(normal)")
        XCTAssertTrue(normal.contains("bold"))
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
        try skipUnlessEnglishInterface()
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: try write(.markdown, "Again.").path))
    }
}

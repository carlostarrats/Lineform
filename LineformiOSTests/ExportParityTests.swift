import LineformCore
import PDFKit
import UIKit
import XCTest
@testable import LineformiOS

/// The iPhone's exports of the shared parity corpus against what the Mac produced for the same
/// file (`Fixtures/export-parity/mac-expected.json`, recorded by the Mac's hosted
/// `ExportParityRecordHostedTests`): the same words in the Normal PDF, Styled PDF and RTF, page
/// counts within one of the Mac's on US Letter and A4, the same HTML apart from the bytes of the
/// pictures each platform rasterizes, and math and diagrams that come out upright on the page.
///
/// Words are compared as multisets: a table's cells come out of PDFKit's text extraction in a
/// different order on the two platforms, and line wrapping never matters.
@MainActor
final class ExportParityTests: XCTestCase {
    struct Pages: Codable, Equatable {
        var normalPages: Int
        var styledPages: Int
    }

    struct Parity: Codable {
        var macOS: String
        var letter: Pages
        var a4: Pages
        var normalWords: [String]
        var styledWords: [String]
        var rtfWords: [String]
        var htmlWithoutImages: String
    }

    /// The HTML export's title, the same on both sides.
    private static let title = "Parity corpus"

    private static var fixtureDirectory: URL {
        Bundle(for: ExportParityTests.self).resourceURL!.appendingPathComponent("export-parity", isDirectory: true)
    }

    private func corpus() throws -> String {
        try String(contentsOf: Self.fixtureDirectory.appendingPathComponent("corpus.md"), encoding: .utf8)
    }

    private func mac() throws -> Parity {
        let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("mac-expected.json"))
        return try JSONDecoder().decode(Parity.self, from: data)
    }

    private func pdf(_ paper: ExportPaperSize, _ preset: ExportTypographyPreset) throws -> PDFDocument {
        let data = PhonePDFRenderer.pdfData(
            text: try corpus(), profile: .original, paper: paper, preset: preset, documentDirectory: nil
        )
        return try XCTUnwrap(PDFDocument(data: data), "the \(paper) export is not a PDF")
    }

    /// Words split on whitespace, the Mac recorder's rule.
    private static func words(_ string: String?) -> [String] {
        (string ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    /// The Mac recorder's rule: each embedded PNG's base64 becomes `IMG`.
    private static func htmlWithoutImages(_ html: String) -> String {
        html.replacingOccurrences(of: "data:image/png;base64,[A-Za-z0-9+/=]+", with: "IMG", options: .regularExpression)
    }

    /// Fails with the words only one side has, and how many times.
    private func assertSameWords(_ phone: [String], _ mac: [String], _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        var counts: [String: Int] = [:]
        for word in phone { counts[word, default: 0] += 1 }
        for word in mac { counts[word, default: 0] -= 1 }
        let differences = counts.filter { $0.value != 0 }.sorted { $0.key < $1.key }
        XCTAssertTrue(differences.isEmpty, "\(what): words the iPhone has more (+) or fewer (−) of than the Mac: "
                      + differences.map { "\($0.key) \($0.value > 0 ? "+" : "−")\(abs($0.value))" }.joined(separator: ", "),
                      file: file, line: line)
    }

    // MARK: - Text

    func testPDFTextMatchesMac() throws {
        let mac = try mac()
        assertSameWords(Self.words(try pdf(.usLetter, .standard).string), mac.normalWords, "Normal PDF")
        assertSameWords(Self.extractionNormalized(Self.words(try pdf(.usLetter, .styled).string)),
                        Self.extractionNormalized(mac.styledWords), "Styled PDF")
    }

    /// Two artifacts of reading text BACK out of the Mac's Styled PDF with PDFKit, applied to both
    /// sides alike. Neither is on the page (checked by rendering the Mac PDF: "bullet" is spelled
    /// in full and the table is drawn once), so neither is a difference a reader would see:
    ///
    /// - A table that `NSTextTable` splits across a page break carries ALL its cells in the
    ///   content of both pages (clipped on each), so the table's words come out twice in a row.
    ///   A run of six or more words immediately followed by the same run is kept once. Prose
    ///   never repeats itself that way, so this cannot hide a real duplicate.
    /// - In the tracked list text, PDFKit reads the "ll" of "bullet" as one "l" ("bulet"). A
    ///   doubled "l" is read as one on both sides.
    static func extractionNormalized(_ words: [String]) -> [String] {
        var kept: [String] = []
        var index = 0
        while index < words.count {
            let longest = min(64, (words.count - index) / 2)
            if longest >= 6, let run = (6...longest).reversed().first(where: { length in
                words[index..<(index + length)].elementsEqual(words[(index + length)..<(index + 2 * length)])
            }) {
                index += run // drop the first copy; the second is read on
                continue
            }
            kept.append(words[index])
            index += 1
        }
        return kept.map { $0.replacingOccurrences(of: "ll", with: "l") }
    }

    func testExtractionNormalizationKeepsOneCopyAndOneL() {
        let table = ["Boat", "Harbor", "Length", "Gull", "North", "12", "m"]
        XCTAssertEqual(Self.extractionNormalized(["A"] + table + table + ["Code"]), ["A"] + table.map {
            $0.replacingOccurrences(of: "ll", with: "l")
        } + ["Code"])
        XCTAssertEqual(Self.extractionNormalized(["the", "the", "bullet"]), ["the", "the", "bulet"],
                       "short repeats are real text")
    }

    func testRTFTextMatchesMac() throws {
        let data = try ExportContent.rtfData(
            text: try corpus(), profile: .original, paper: .usLetter, preset: .standard, appVersion: ExportContent.appVersion
        )
        let string = try NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
        ).string
        assertSameWords(Self.words(string), try mac().rtfWords, "RTF")
    }

    func testHTMLMatchesMacExceptImageBytes() throws {
        let html = String(decoding: ExportContent.htmlData(text: try corpus(), title: Self.title), as: UTF8.self)
        let phone = Self.htmlWithoutImages(html)
        let expected = try mac().htmlWithoutImages
        if phone != expected {
            let a = phone.components(separatedBy: "\n"), b = expected.components(separatedBy: "\n")
            let index = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
            XCTFail("HTML differs at line \(index + 1):\n  iPhone: \(index < a.count ? a[index] : "<end>")\n"
                    + "  Mac:    \(index < b.count ? b[index] : "<end>")")
        }
    }

    // MARK: - Pages

    func testPageCountWithinOneOfMac() throws {
        let mac = try mac()
        for (paper, expected) in [(ExportPaperSize.usLetter, mac.letter), (.a4, mac.a4)] {
            let normal = try pdf(paper, .standard).pageCount
            let styled = try pdf(paper, .styled).pageCount
            XCTAssertLessThanOrEqual(abs(normal - expected.normalPages), 1,
                                     "\(paper.displayName) Normal: iPhone \(normal) pages, Mac \(expected.normalPages)")
            XCTAssertLessThanOrEqual(abs(styled - expected.styledPages), 1,
                                     "\(paper.displayName) Styled: iPhone \(styled) pages, Mac \(expected.styledPages)")
        }
    }

    // MARK: - Orientation

    /// The page area between two lines of prose that sit just above and just below a picture,
    /// rasterized: the picture's ink alone.
    private func region(between before: String, and after: String, in document: PDFDocument,
                        scale: CGFloat = 2) throws -> PhoneRasterInk {
        let above = try XCTUnwrap(document.findString(before, withOptions: []).first, "\(before) not found")
        let below = try XCTUnwrap(document.findString(after, withOptions: []).first, "\(after) not found")
        let abovePage = try XCTUnwrap(above.pages.first)
        let belowPage = try XCTUnwrap(below.pages.first)
        let page: PDFPage
        let topY: CGFloat     // PDF coordinates: origin at the bottom left
        let bottomY: CGFloat
        if abovePage == belowPage {
            page = belowPage
            topY = above.bounds(for: page).minY
            bottomY = below.bounds(for: page).maxY
        } else {
            // The picture did not fit under the line above it and opens the next page.
            page = belowPage
            topY = page.bounds(for: .mediaBox).height - ExportTypographyPreset.styled.pageMargins.top + 1
            bottomY = below.bounds(for: page).maxY
        }
        let size = page.bounds(for: .mediaBox).size
        let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixelScale = CGFloat(cgImage.height) / size.height
        let crop = CGRect(x: 0, y: (size.height - topY) * pixelScale + 1,
                          width: CGFloat(cgImage.width), height: (topY - bottomY) * pixelScale - 2)
        let cropped = try XCTUnwrap(cgImage.cropping(to: crop.integral), "nothing between \(before) and \(after)")
        return try PhoneRasterInk(UIImage(cgImage: cropped))
    }

    func testParityMathAndMermaidUpright() throws {
        let styled = try pdf(.usLetter, .styled)

        // A narrow numerator over a wide denominator: mirrored, the wide row would be on top.
        let fraction = try region(between: "Before the wide fraction.", and: "After the wide fraction.", in: styled)
        let top = try XCTUnwrap(fraction.firstInkRow, "the fraction has no ink")
        let bottom = try XCTUnwrap(fraction.lastInkRow)
        let topSpan = try XCTUnwrap(fraction.inkSpan(row: top))
        let bottomSpan = try XCTUnwrap(fraction.inkSpan(row: bottom))
        XCTAssertLessThan(topSpan, bottomSpan,
                          "top ink row spans \(topSpan) px, bottom \(bottomSpan) px: the numerator is not on top")

        // A top-down flowchart ends in two side-by-side nodes: its widest row is in the lower half.
        let diagram = try region(between: "Before the diagram.", and: "After the diagram.", in: styled)
        let widest = try XCTUnwrap(diagram.widestInkRow, "the diagram has no ink")
        let diagramTop = try XCTUnwrap(diagram.firstInkRow)
        let diagramBottom = try XCTUnwrap(diagram.lastInkRow)
        XCTAssertGreaterThan(diagramBottom - diagramTop, 40, "the diagram did not render as an image")
        XCTAssertGreaterThan(widest, (diagramTop + diagramBottom) / 2,
                             "widest ink row \(widest) between \(diagramTop) and \(diagramBottom): the diagram is upside down")
    }
}

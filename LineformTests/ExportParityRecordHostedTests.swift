import AppKit
import LineformCore
import PDFKit
import XCTest
@testable import Lineform

/// Records the Mac's exports of the shared parity corpus (`LineformiOSTests/Fixtures/export-parity/
/// corpus.md`) as `mac-expected.json`, the reference the iPhone's `ExportParityTests` compares its
/// own exports against: the words of the Normal PDF, Styled PDF and RTF, the page counts on US
/// Letter and A4, and the HTML with each embedded picture's bytes replaced by `IMG`.
///
/// HOSTED plan only, like `DocumentExportPDFHostedTests`: the PDFs come from `NSPrintOperation`,
/// whose cold start is environment-sensitive.
///
/// - Without the env var it asserts the live Mac output still equals the JSON, and skips when the
///   JSON was recorded on another macOS version (fonts and line breaking move between releases).
/// - Record with `TEST_RUNNER_RECORD_EXPORT_PARITY=1 xcodebuild test … -testPlan LineformHosted
///   -only-testing:LineformTests/ExportParityRecordHostedTests` (xcodebuild strips the prefix).
///   The Debug test host is sandboxed, so it cannot write the source tree: it writes the app
///   container's `tmp/mac-expected.json` (`~/Library/Containers/com.lineform.app.debug/Data/tmp/`)
///   and fails with that path; copy it to `LineformiOSTests/Fixtures/export-parity/`.
@MainActor
final class ExportParityRecordHostedTests: XCTestCase {
    struct Pages: Codable, Equatable {
        var normalPages: Int
        var styledPages: Int
    }

    struct Parity: Codable, Equatable {
        var macOS: String
        var letter: Pages
        var a4: Pages
        var normalWords: [String]
        var styledWords: [String]
        var rtfWords: [String]
        var htmlWithoutImages: String
    }

    func testMacExportMatchesRecordedParity() throws {
        let actual = try Self.measure()
        if ProcessInfo.processInfo.environment["RECORD_EXPORT_PARITY"] == "1" {
            try record(actual)
            return
        }
        let url = Self.fixtureDirectory.appendingPathComponent("mac-expected.json")
        let expected = try JSONDecoder().decode(Parity.self, from: Data(contentsOf: url))
        if expected.macOS != actual.macOS {
            throw XCTSkip("mac-expected.json was recorded on \(expected.macOS); re-record on this OS (\(actual.macOS))")
        }
        XCTAssertEqual(actual.letter, expected.letter, "Letter page counts moved")
        XCTAssertEqual(actual.a4, expected.a4, "A4 page counts moved")
        XCTAssertEqual(actual.normalWords, expected.normalWords, "Normal PDF words moved")
        XCTAssertEqual(actual.styledWords, expected.styledWords, "Styled PDF words moved")
        XCTAssertEqual(actual.rtfWords, expected.rtfWords, "RTF words moved")
        XCTAssertEqual(actual.htmlWithoutImages, expected.htmlWithoutImages, "HTML moved")
    }

    // MARK: - Measuring

    static let title = "Parity corpus"

    static func measure() throws -> Parity {
        let text = try corpus()
        func pdf(_ paper: ExportPaperSize, _ preset: ExportTypographyPreset) throws -> PDFDocument {
            let data = DocumentExportRenderer.pdfData(text: text, profile: .original, paper: paper, preset: preset)
            return try XCTUnwrap(PDFDocument(data: data), "the \(paper) \(preset) export is not a PDF")
        }
        let letterNormal = try pdf(.usLetter, .standard)
        let letterStyled = try pdf(.usLetter, .styled)
        let a4Normal = try pdf(.a4, .standard)
        let a4Styled = try pdf(.a4, .styled)
        let rtf = try ExportContent.rtfData(
            text: text, profile: .original, paper: .usLetter, preset: .standard, appVersion: ExportContent.appVersion
        )
        let rtfString = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil)).string
        let html = String(decoding: DocumentExportRenderer.htmlData(text: text, title: title), as: UTF8.self)
        return Parity(
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            letter: Pages(normalPages: letterNormal.pageCount, styledPages: letterStyled.pageCount),
            a4: Pages(normalPages: a4Normal.pageCount, styledPages: a4Styled.pageCount),
            normalWords: words(letterNormal.string),
            styledWords: words(letterStyled.string),
            rtfWords: words(rtfString),
            htmlWithoutImages: htmlWithoutImages(html)
        )
    }

    /// Words split on whitespace, so line wrapping never matters.
    static func words(_ string: String?) -> [String] {
        (string ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    /// The HTML with every embedded PNG's base64 replaced by `IMG`: the math and diagram pictures
    /// are rasterized by each platform, so their bytes differ; everything around them must not.
    static func htmlWithoutImages(_ html: String) -> String {
        html.replacingOccurrences(of: "data:image/png;base64,[A-Za-z0-9+/=]+", with: "IMG", options: .regularExpression)
    }

    // MARK: - Fixtures

    private static var fixtureDirectory: URL {
        Bundle(for: ExportParityRecordHostedTests.self).resourceURL!
            .appendingPathComponent("export-parity", isDirectory: true)
    }

    private static var sourceExpectedURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LineformiOSTests/Fixtures/export-parity/mac-expected.json")
    }

    private static func corpus() throws -> String {
        try String(contentsOf: fixtureDirectory.appendingPathComponent("corpus.md"), encoding: .utf8)
    }

    private func record(_ parity: Parity) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(parity) + Data("\n".utf8)
        do {
            try data.write(to: Self.sourceExpectedURL, options: .atomic)
            print("[export-parity] recorded \(Self.sourceExpectedURL.path)")
        } catch {
            // The sandboxed test host cannot write the source tree: leave it in the container.
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("mac-expected.json")
            try data.write(to: fallback, options: .atomic)
            XCTFail("[export-parity] could not write the source fixture (\(error.localizedDescription)); wrote \(fallback.path)")
        }
    }
}

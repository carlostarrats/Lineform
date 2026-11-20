import CoreGraphics
import XCTest
@testable import LineformCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Markdown renderer on both platforms: every block kind renders, the Mac/iPhone seam
/// (display metrics, table emitter, horizontal rule) behaves, and the moved captions keep their
/// translations.
@MainActor
final class RendererPlatformTests: XCTestCase {

    private func corpus() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "corpus", withExtension: "md", subdirectory: "render-corpus"),
            "render-corpus/corpus.md missing from the test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func render(
        _ text: String,
        columnWidth: CGFloat = 680,
        mathProvider: MathImageProviding = DisabledMathImageProvider(),
        displayMetrics: RenderDisplayMetrics = .current
    ) -> NSAttributedString {
        MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: columnWidth,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: mathProvider,
            diagramLog: NullDiagramFailureLog(),
            appVersion: "0",
            displayMetrics: displayMetrics
        )
    }

    private func hasAttribute(_ key: NSAttributedString.Key, in text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    // MARK: - Every block kind

    func testRenderProducesEveryBlockKind() throws {
        let output = render(try corpus())
        XCTAssertGreaterThan(output.length, 0)
        var hasRule = false
        output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, _, stop in
            if value is HorizontalRuleAttachment { hasRule = true; stop.pointee = true }
        }
        XCTAssertTrue(hasRule, "no HorizontalRuleAttachment for the corpus's ---")
        XCTAssertTrue(hasAttribute(.checkboxSourceRange, in: output), "no task checkbox")
        XCTAssertTrue(hasAttribute(.headingSourceRange, in: output), "no heading")
        XCTAssertTrue(hasAttribute(.codeBlockSourceRange, in: output), "no fenced code block")
        XCTAssertTrue(hasAttribute(.imageSourceRange, in: output), "no image placeholder")
    }

    // MARK: - iPhone table

    #if os(iOS)
    func testTableRowsCarryRowIndexOnIPhone() throws {
        let table = "| H1 | H2 |\n|:---|---:|\n| a | b |\n| c | d |"
        let output = render(table)
        var rows: [Int: NSRange] = [:]
        output.enumerateAttribute(.markdownTableRow, in: NSRange(location: 0, length: output.length)) { value, range, _ in
            guard let number = value as? NSNumber else { return }
            let row = number.intValue
            rows[row] = rows[row].map { NSUnionRange($0, range) } ?? range
        }
        XCTAssertEqual(rows.keys.sorted(), [0, 1, 2])
        let headerRange = try XCTUnwrap(rows[0])
        let headerFont = try XCTUnwrap(output.attribute(.font, at: headerRange.location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(headerFont.fontDescriptor.symbolicTraits.contains(.traitBold), "header row is not bold")
        let bodyFont = try XCTUnwrap(output.attribute(.font, at: try XCTUnwrap(rows[1]).location, effectiveRange: nil) as? UIFont)
        XCTAssertFalse(bodyFont.fontDescriptor.symbolicTraits.contains(.traitBold), "body row is bold")
        XCTAssertEqual(bodyFont.pointSize, CGFloat(ReadingProfile.original.fontSize) * MarkdownPreviewRenderer.tableTextScale, accuracy: 0.01)
        // One paragraph per row, cells joined by tabs.
        let headerText = (output.string as NSString).substring(with: headerRange)
        XCTAssertTrue(headerText.hasPrefix("H1\tH2"), "header row text: \(headerText.debugDescription)")
    }

    func testLongTableCellDoesNotCrashAtNarrowWidth() {
        let header = "| a | b | c | d | e | f |"
        let delimiter = "|---|:---:|---:|---|---|---|"
        let long = String(repeating: "word ", count: 80)
        let row = "| \(long) | x | y | z | w | v |"
        let table = [header, delimiter, row].joined(separator: "\n")
        for width: CGFloat in [1, 320] {
            let output = render(table, columnWidth: width)
            XCTAssertGreaterThan(output.length, 400, "width \(width)")
        }
    }

    func testHorizontalRuleFillsLineWidth() {
        let rule = HorizontalRuleAttachment(color: .black, height: 17)
        let wide = rule.attachmentBounds(
            for: nil, proposedLineFragment: CGRect(x: 0, y: 0, width: 300, height: 20),
            glyphPosition: .zero, characterIndex: 0
        )
        XCTAssertEqual(wide.width, 300)
        XCTAssertEqual(wide.height, 17)
        let empty = rule.attachmentBounds(
            for: nil, proposedLineFragment: CGRect(x: 0, y: 0, width: 0, height: 20),
            glyphPosition: .zero, characterIndex: 0
        )
        XCTAssertEqual(empty.width, 1)
    }
    #endif

    // MARK: - Display metrics

    private func pixelWidth(_ image: PlatformImage) throws -> Int {
        #if os(macOS)
        var proposed = CGRect(origin: .zero, size: image.size)
        return try XCTUnwrap(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)).width
        #else
        return try XCTUnwrap(image.cgImage).width
        #endif
    }

    /// Records the scale each math render asks for. The real `MathImageProvider` uses `scale`
    /// only in its cache key (SwiftMath rasterizes at the context's own scale), so math cannot
    /// show the metrics in its pixels; this proves the metrics reach it.
    private final class ScaleRecordingMathProvider: MathImageProviding {
        var scales: [CGFloat] = []
        func outcome(latex: String, style: MathStyle, foreground: PlatformColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome {
            scales.append(scale)
            return .skipped
        }
    }

    private func mermaidPixelWidth(scale: CGFloat) throws -> Int {
        let output = MarkdownPreviewRenderer().render(
            "```mermaid\nflowchart TD\n    A[Start] --> B[Done]\n```",
            profile: .original,
            columnWidth: 680,
            mermaidProvider: MermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            appVersion: "0",
            displayMetrics: RenderDisplayMetrics(scale: scale, visibleViewportHeight: 900)
        )
        var image: PlatformImage?
        output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, _, stop in
            if let attachment = value as? BlockRenderedAttachment { image = attachment.image; stop.pointee = true }
        }
        return try pixelWidth(try XCTUnwrap(image, "the diagram did not render to an attachment"))
    }

    func testExplicitMetricsChangeAttachmentPixels() throws {
        let one = try mermaidPixelWidth(scale: 1)
        let two = try mermaidPixelWidth(scale: 2)
        XCTAssertGreaterThan(one, 0)
        XCTAssertEqual(Double(two), Double(one) * 2, accuracy: 2, "scale 1 = \(one) px, scale 2 = \(two) px")

        // Block and inline math receive the explicit scale.
        let math = ScaleRecordingMathProvider()
        for scale: CGFloat in [1, 2] {
            _ = render("$$\nx^2\n$$\n\nInline $y^2$.", mathProvider: math,
                       displayMetrics: RenderDisplayMetrics(scale: scale, visibleViewportHeight: 900))
        }
        XCTAssertEqual(math.scales, [1, 1, 2, 2])
    }

    #if os(macOS)
    func testCurrentMetricsAreReadPerCall() {
        XCTAssertEqual(RenderDisplayMetrics.current.scale, NSScreen.main?.backingScaleFactor ?? 2)
        XCTAssertEqual(RenderDisplayMetrics.current.visibleViewportHeight, NSScreen.main?.visibleFrame.height ?? 900)
    }
    #endif

    // MARK: - Caption translations

    private static let languages = ["es", "fr", "de", "ja", "zh-Hans"]

    /// Per-language `.lproj` lookup (ruling R3): the package catalog compiles into
    /// `Bundle.lineformCore`, and each language must read the translation the app catalog
    /// carried before the move.
    private func assertTranslated(_ key: String, expected: [String: String]) throws {
        for language in Self.languages {
            let bundle = try XCTUnwrap(
                Bundle.lineformCore.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
                "\(language).lproj missing from LineformCore's bundle"
            )
            let localized = bundle.localizedString(forKey: key, value: "\u{1}missing", table: nil)
            XCTAssertNotEqual(localized, key, "\(key) is English in \(language)")
            XCTAssertEqual(localized, expected[language], "\(key) in \(language)")
        }
    }

    func testMermaidCaptionIsTranslated() throws {
        try assertTranslated("Mermaid diagram (source)", expected: [
            "es": "Diagrama de Mermaid (código fuente)", "fr": "Diagramme Mermaid (source)",
            "de": "Mermaid-Diagramm (Quelltext)", "ja": "Mermaid図（ソース）", "zh-Hans": "Mermaid 图表（源代码）",
        ])
    }

    func testMathCaptionIsTranslated() throws {
        try assertTranslated("Math (source)", expected: [
            "es": "Fórmula (código fuente)", "fr": "Formule (source)",
            "de": "Formel (Quelltext)", "ja": "数式（ソース）", "zh-Hans": "数学公式（源代码）",
        ])
    }
}

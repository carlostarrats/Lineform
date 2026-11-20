import XCTest
import AppKit
@testable import Lineform
@testable import LineformCore

/// The renderer side of Mermaid: captioned fallback, accessibility and export. The provider
/// seam's own tests moved to LineformCoreTests with the provider.
final class MermaidRenderingTests: XCTestCase {
    // A fake provider + log to exercise the renderer's fallback path without the library.
    private final class FakeProvider: MermaidImageProviding {
        let result: MermaidRenderOutcome
        init(_ result: MermaidRenderOutcome) { self.result = result }
        func outcome(source: String, background: NSColor, foreground: NSColor, scale: CGFloat) -> MermaidRenderOutcome { result }
    }
    private final class FakeLog: DiagramFailureLogging {
        var records: [(source: String, error: String)] = []
        func record(source: String, error: String, appVersion: String) { records.append((source, error)) }
    }

    @MainActor
    func testFailedMermaidFallsBackToCaptionedSourceAndLogs() {
        let log = FakeLog()
        let text = "before\n```mermaid\ngraph TD; A-->B\n```\nafter"
        let output = MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 600,
            mermaidProvider: FakeProvider(.failed("boom")),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: log,
            appVersion: "1.0"
        ).string
        XCTAssertTrue(output.contains("Mermaid diagram (source)"))
        XCTAssertTrue(output.contains("graph TD; A-->B"))
        XCTAssertFalse(output.contains("```"))   // the fence lines are not emitted
        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.records.first?.error, "boom")
    }

    @MainActor
    func testRenderedMermaidImageCarriesAccessibilityDescription() throws {
        let source = "graph TD; A-->B"
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let rendered = MarkdownPreviewRenderer().render(
            "```mermaid\n\(source)\n```",
            profile: .original,
            columnWidth: 600,
            mermaidProvider: FakeProvider(.image(image)),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: FakeLog(),
            appVersion: "1.0"
        )

        var attachmentImage: NSImage?
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, stop in
            if let attachment = value as? NSTextAttachment, let image = attachment.image {
                attachmentImage = image
                stop.pointee = true
            }
        }

        let diagram = try XCTUnwrap(attachmentImage, "successful render should embed the diagram image as an attachment")
        XCTAssertEqual(diagram.accessibilityDescription, "Mermaid diagram. \(source)")
    }

    /// A failed diagram renders the captioned source and NOTHING that offers to send it. Diagram
    /// reporting was removed 2026-07-29 so that no part of Lineform transmits document content —
    /// this guards the removal, on screen and in exported output alike.
    @MainActor
    func testFailedDiagramOffersNoWayToSendTheSource() {
        let text = "```mermaid\ngraph TD; A-->B\n```"

        // On screen: a genuinely failed diagram must fall back to the captioned source, with no
        // link and no "Report this" affordance in the attributed output.
        let onScreen = MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 600,
            mermaidProvider: FakeProvider(.failed("boom")),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: FakeLog(),
            appVersion: "1.0"
        )
        assertNoReportAffordance(in: onScreen, label: "on screen")

        // Exported (RTF/PDF text path): this is the REAL export renderer, not the on-screen call
        // again — it routes mermaid through DisabledMermaidImageProvider and imagesAsText, which is
        // the path a shared PDF/RTF takes. No link may survive into an exported document.
        let exported = DocumentExportRenderer.makeRTFAttributedString(
            text: text, profile: .original, paper: .usLetter
        )
        assertNoReportAffordance(in: exported, label: "exported (RTF/PDF)")

        // Exported HTML: a distinct emitter (MarkdownHTMLRenderer). Assert no report scheme or copy
        // leaks into the produced markup.
        let html = String(decoding: DocumentExportRenderer.htmlData(text: text, title: "t"), as: UTF8.self)
        XCTAssertFalse(html.contains("lineform-report"), "exported HTML: no report scheme")
        XCTAssertFalse(html.contains("Report this"), "exported HTML: no report affordance")
    }

    @MainActor
    private func assertNoReportAffordance(in rendered: NSAttributedString, label: String) {
        XCTAssertTrue(rendered.string.contains("Mermaid diagram (source)"), "\(label): fallback still renders")
        XCTAssertFalse(rendered.string.contains("Report this"), "\(label): no report affordance")
        var foundLink = false
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if value != nil { foundLink = true }
        }
        XCTAssertFalse(foundLink, "\(label): no link may reach a failed-diagram fallback")
    }

    @MainActor
    func testSkippedMermaidFallsBackWithoutLogging() {
        let log = FakeLog()
        let text = "```mermaid\ngraph TD; A-->B\n```"
        let output = MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 600,
            mermaidProvider: FakeProvider(.skipped),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: log,
            appVersion: "1.0"
        ).string
        XCTAssertTrue(output.contains("Mermaid diagram (source)"))
        XCTAssertTrue(output.contains("graph TD; A-->B"))
        XCTAssertEqual(log.records.count, 0)
    }

    @MainActor
    func testUnsupportedMermaidFallsBackWithoutLogging() {
        let log = FakeLog()
        let text = "before\n```mermaid\ngantt\n title Project\n```\nafter"
        let output = MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 600,
            mermaidProvider: FakeProvider(.unsupported("gantt")),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: log,
            appVersion: "1.0"
        ).string
        XCTAssertTrue(output.contains("Mermaid diagram (source)"))
        XCTAssertTrue(output.contains("gantt"))
        XCTAssertEqual(log.records.count, 0)             // not logged
    }

}

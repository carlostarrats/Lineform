import XCTest
import AppKit
@testable import Lineform

final class MermaidRenderingTests: XCTestCase {
    func testSizeGuardBoundary() {
        XCTAssertTrue(MermaidBlockPolicy.shouldAttemptRender(source: String(repeating: "a", count: 20_000)))
        XCTAssertFalse(MermaidBlockPolicy.shouldAttemptRender(source: String(repeating: "a", count: 20_001)))
    }

    func testHexColorConversion() {
        XCTAssertEqual(MermaidHexColor.string(from: .black), "#000000")
        XCTAssertEqual(MermaidHexColor.string(from: .white), "#ffffff")
        XCTAssertEqual(MermaidHexColor.string(from: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)), "#ff0000")
    }

    func testCacheKeyStableAndDistinct() {
        let a = MermaidCacheKey.key(source: "graph TD; A-->B", backgroundHex: "#000000", foregroundHex: "#ffffff", scale: 2)
        let sameInputs = MermaidCacheKey.key(source: "graph TD; A-->B", backgroundHex: "#000000", foregroundHex: "#ffffff", scale: 2)
        let differentSource = MermaidCacheKey.key(source: "graph TD; A-->C", backgroundHex: "#000000", foregroundHex: "#ffffff", scale: 2)
        let differentTheme = MermaidCacheKey.key(source: "graph TD; A-->B", backgroundHex: "#111111", foregroundHex: "#ffffff", scale: 2)
        let differentScale = MermaidCacheKey.key(source: "graph TD; A-->B", backgroundHex: "#000000", foregroundHex: "#ffffff", scale: 1)
        XCTAssertEqual(a, sameInputs)
        XCTAssertNotEqual(a, differentSource)
        XCTAssertNotEqual(a, differentTheme)
        XCTAssertNotEqual(a, differentScale)
    }

    func testUprightCorrectionVerticallyFlipsRaster() throws {
        // Synthetic 2x4 image with two distinct solid bands. BeautifulMermaid's macOS
        // path renders diagrams into a bottom-left-origin context while its drawing code
        // assumes top-left, so every diagram comes back vertically mirrored. The upright
        // correction must flip the raster so the top and bottom bands swap.
        let width = 2, height = 4
        guard let source = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return XCTFail("could not create source context") }
        // Core Graphics origin is bottom-left, so "upper" rows are the high-y rows.
        source.setFillColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor)   // band A on the visual top
        source.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        source.setFillColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).cgColor)   // band B on the visual bottom
        source.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        let cgSource = try XCTUnwrap(source.makeImage())
        let input = NSImage(cgImage: cgSource, size: NSSize(width: width, height: height))

        let upright = try XCTUnwrap(MermaidImageOrientation.uprightForMacOS(input))

        // Read the raw bytes of a single pixel (CGImage row 0 is the visual top row).
        // Compare pixels rather than assuming a channel order, so the assertion is
        // independent of the pixel format macOS hands back through NSImage.
        func pixel(_ image: NSImage, atRow row: Int) throws -> [UInt8] {
            var rect = CGRect(origin: .zero, size: image.size)
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            XCTAssertEqual(cg.width, width)
            XCTAssertEqual(cg.height, height)
            let data = try XCTUnwrap(cg.dataProvider?.data)
            let ptr = try XCTUnwrap(CFDataGetBytePtr(data))
            let bytesPerPixel = cg.bitsPerPixel / 8
            let offset = row * cg.bytesPerRow
            return (0..<bytesPerPixel).map { ptr[offset + $0] }
        }

        let inputTop = try pixel(input, atRow: 0)
        let inputBottom = try pixel(input, atRow: height - 1)
        let uprightTop = try pixel(upright, atRow: 0)
        let uprightBottom = try pixel(upright, atRow: height - 1)

        XCTAssertNotEqual(inputTop, inputBottom, "the two bands must be distinguishable")
        XCTAssertEqual(uprightTop, inputBottom, "upright correction must move the original bottom band to the top")
        XCTAssertEqual(uprightBottom, inputTop, "upright correction must move the original top band to the bottom")
    }

    func testMermaidFenceDetection() {
        XCTAssertTrue(MermaidFence.isMermaidOpening("```mermaid"))
        XCTAssertTrue(MermaidFence.isMermaidOpening("``` mermaid"))
        XCTAssertTrue(MermaidFence.isMermaidOpening("~~~mermaid"))
        XCTAssertFalse(MermaidFence.isMermaidOpening("```swift"))
        XCTAssertFalse(MermaidFence.isMermaidOpening("```"))
        XCTAssertFalse(MermaidFence.isMermaidOpening("plain text"))
    }

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
        for label in ["on screen", "exported"] {
            let rendered = MarkdownPreviewRenderer().render(
                text,
                profile: .original,
                columnWidth: 600,
                mermaidProvider: FakeProvider(.failed("boom")),
                mathProvider: DisabledMathImageProvider(),
                diagramLog: FakeLog(),
                appVersion: "1.0"
            )
            XCTAssertTrue(rendered.string.contains("Mermaid diagram (source)"), "\(label): fallback still renders")
            XCTAssertFalse(rendered.string.contains("Report this"), "\(label): no report affordance")
            var foundLink = false
            rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                if value != nil { foundLink = true }
            }
            XCTAssertFalse(foundLink, "\(label): no link may reach a failed-diagram fallback")
        }
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

    // MARK: - Part 1: unsupported types fall back cleanly (no library call, no log/report)

    func testProviderReturnsUnsupportedForGanttWithoutCallingLibrary() {
        let provider = MermaidImageProvider()
        let outcome = provider.outcome(source: "gantt\n title Project\n section A\n Task :a1, 2024-01-01, 30d",
                                       background: .white, foreground: .black, scale: 2)
        guard case .unsupported = outcome else { return XCTFail("expected .unsupported, got \(outcome)") }
    }

    func testProviderStillAttemptsSupportedType() {
        let provider = MermaidImageProvider()
        let outcome = provider.outcome(source: "flowchart TD\n A-->B",
                                       background: .white, foreground: .black, scale: 2)
        // Supported types route to BeautifulMermaid: image or a genuine failure, never .unsupported.
        if case .unsupported = outcome { XCTFail("supported type must not be .unsupported") }
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

    // MARK: - Part 2: native pie rendering

    func testProviderRendersPieNatively() {
        let provider = MermaidImageProvider()
        let outcome = provider.outcome(source: "pie title Fruit\n \"Apples\" : 30\n \"Pears\" : 10",
                                       background: .clear, foreground: .black, scale: 2)
        guard case .image(let img) = outcome else { return XCTFail("expected .image, got \(outcome)") }
        XCTAssertGreaterThan(img.size.width, 0)
    }

    func testProviderFallsBackForMalformedPie() {
        let provider = MermaidImageProvider()
        let outcome = provider.outcome(source: "pie title Empty",
                                       background: .clear, foreground: .black, scale: 2)
        guard case .unsupported = outcome else { return XCTFail("expected .unsupported, got \(outcome)") }
    }

    /// `Int(v)` traps on a value above `Double(Int.max)` and on inf/NaN, so the parser must reject
    /// them. Rendering such a block crashed the process — in Read, Split, Export, and Print.
    func testPieChartRejectsValuesTheLegendCouldNotConvert() {
        for value in ["99999999999999999999", "inf", "1e400"] {
            XCTAssertNil(
                MermaidPieChart.parse("pie title Q\n\"a\" : \(value)\n\"b\" : 5\n"),
                "value: \(value)"
            )
        }
        XCTAssertNotNil(MermaidPieChart.parse("pie title Q\n\"a\" : 3\n\"b\" : 5\n"))
    }

    /// A front-matter diagram is valid Mermaid. It must not reach the `.failed` path, which logs
    /// the user's document text — the path reserved for genuine library bugs.
    func testFrontMatterIsStrippedBeforeTheDiagramSourceIsHandedToTheLibrary() {
        let source = "---\ntitle: My flow\n---\nflowchart TD\n  A --> B\n"

        XCTAssertEqual(MermaidTypeClassifier.classify(source), .supported)
        XCTAssertEqual(MermaidSource.withoutFrontMatter(source), "flowchart TD\n  A --> B\n")
        // No front matter: untouched.
        XCTAssertEqual(MermaidSource.withoutFrontMatter("flowchart TD\n  A --> B\n"), "flowchart TD\n  A --> B\n")
    }

    /// The character cap admitted sources whose rasters exceed the whole diagram-cache budget, so
    /// they re-rendered on the main thread on every preview pass. Bound the structure too.
    func testSizeGuardBoundsNodeCountNotOnlyCharacterCount() {
        let wide = "flowchart TD\n" + (0..<200).map { "  ROOT --> L\($0)" }.joined(separator: "\n")

        XCTAssertLessThan(wide.count, MermaidBlockPolicy.maxSourceLength)
        XCTAssertFalse(MermaidBlockPolicy.shouldAttemptRender(source: wide))
        XCTAssertTrue(MermaidBlockPolicy.shouldAttemptRender(source: "flowchart TD\n  A --> B"))
    }

}

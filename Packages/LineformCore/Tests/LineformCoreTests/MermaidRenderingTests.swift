import XCTest
@testable import LineformCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Mermaid image provider seam. The renderer-side tests (captioned fallback, accessibility,
/// export) stay in LineformTests with the renderer.
final class MermaidRenderingTests: XCTestCase {
    func testSizeGuardBoundary() {
        XCTAssertTrue(MermaidBlockPolicy.shouldAttemptRender(source: String(repeating: "a", count: 20_000)))
        XCTAssertFalse(MermaidBlockPolicy.shouldAttemptRender(source: String(repeating: "a", count: 20_001)))
    }

    func testHexColorConversion() {
        XCTAssertEqual(MermaidHexColor.string(from: .black), "#000000")
        XCTAssertEqual(MermaidHexColor.string(from: .white), "#ffffff")
        XCTAssertEqual(MermaidHexColor.string(from: PlatformColor.lineformSRGB(red: 1, green: 0, blue: 0, alpha: 1)), "#ff0000")
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

    #if os(macOS)
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
    #endif

    func testMermaidFenceDetection() {
        XCTAssertTrue(MermaidFence.isMermaidOpening("```mermaid"))
        XCTAssertTrue(MermaidFence.isMermaidOpening("``` mermaid"))
        XCTAssertTrue(MermaidFence.isMermaidOpening("~~~mermaid"))
        XCTAssertFalse(MermaidFence.isMermaidOpening("```swift"))
        XCTAssertFalse(MermaidFence.isMermaidOpening("```"))
        XCTAssertFalse(MermaidFence.isMermaidOpening("plain text"))
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

    // MARK: - Orientation on this platform (spec §11: re-checked on iPhone)

    /// BeautifulMermaid draws for a top-left origin. macOS flips its raster upright at the seam;
    /// iOS uses the library's UIKit output as is. Either way the two side-by-side nodes at the
    /// END of a top-down flowchart must be at the bottom: the widest row of ink is in the lower half.
    func testFlowchartRendersTopDownOnThisPlatform() throws {
        let source = "graph TD\n  A[Start] --> B[Middle]\n  B --> C[Left]\n  B --> D[Right]"
        let outcome = MermaidImageProvider().outcome(source: source, background: .white, foreground: .black, scale: 2)
        guard case .image(let image) = outcome else { return XCTFail("expected .image, got \(outcome)") }

        let scan = try RasterInkScan(image)
        let widest = try XCTUnwrap(scan.widestInkRow, "the diagram has no ink")
        XCTAssertGreaterThan(widest, scan.height / 2,
                             "widest ink row \(widest) of \(scan.height): the diagram is upside down")
    }

    /// The pie draws its own raster (flipped NSImage on macOS, UIGraphicsImageRenderer on iOS):
    /// its title is at the top. The pie's centre column (padding 16 + radius 100 = 116 pt) is past
    /// the short title, so its topmost ink is the circle's top, below the 16 pt padding + 24 pt
    /// title band (40 pt). A mirrored pie puts the circle's top 16 pt from the top instead.
    func testPieRendersTitleAtTop() throws {
        let source = "pie title Fruit\n \"Apples\" : 30\n \"Pears\" : 10"
        let outcome = MermaidImageProvider().outcome(source: source, background: .white, foreground: .black, scale: 2)
        guard case .image(let image) = outcome else { return XCTFail("expected .image, got \(outcome)") }

        let scan = try RasterInkScan(image)
        let pixelsPerPoint = CGFloat(scan.width) / image.size.width
        let centreColumn = Int((116 * pixelsPerPoint).rounded())
        let top = try XCTUnwrap(scan.topmostInk(inColumn: centreColumn), "the pie's centre column has no ink")
        XCTAssertGreaterThanOrEqual(CGFloat(top), 36 * pixelsPerPoint,
                                    "pie centre column's top ink \(top) px: the circle is above the title band, the pie is upside down")
    }
}

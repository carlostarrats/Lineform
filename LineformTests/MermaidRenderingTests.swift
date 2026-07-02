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
    func testSkippedMermaidFallsBackWithoutLogging() {
        let log = FakeLog()
        let text = "```mermaid\ngraph TD; A-->B\n```"
        let output = MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 600,
            mermaidProvider: FakeProvider(.skipped),
            diagramLog: log,
            appVersion: "1.0"
        ).string
        XCTAssertTrue(output.contains("Mermaid diagram (source)"))
        XCTAssertTrue(output.contains("graph TD; A-->B"))
        XCTAssertEqual(log.records.count, 0)
    }
}

import XCTest
@testable import Lineform

/// Coverage for the `headingScale` parameter threaded into `MarkdownPreviewRenderer.render(...)`
/// (Task 2 of the PDF Export Typographic Themes plan). `headingScale` is not a `ReadingProfile`
/// field, so it is a defaulted render parameter; the default `1.0` must leave on-screen
/// Read/Preview rendering byte-identical (proven by the existing renderer/export test suites
/// staying green, since no call site outside these new tests passes a non-default value).
@MainActor
final class MarkdownPreviewRendererHeadingScaleTests: XCTestCase {

    private func firstHeadingFontSize(scale: CGFloat) -> CGFloat {
        let attributed = MarkdownPreviewRenderer().render(
            "# Title\n\nBody",
            profile: .original,
            columnWidth: 600,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            appVersion: "0",
            headingScale: scale
        )
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        return font?.pointSize ?? 0
    }

    func testDefaultHeadingScaleMatchesUnscaledBoost() {
        XCTAssertEqual(firstHeadingFontSize(scale: 1.0), ReadingProfile.original.fontSize + 11)
        XCTAssertEqual(firstHeadingFontSize(scale: 1.0), 28)
    }

    func testHeadingScaleAmplifiesTheBoostOverBody() {
        XCTAssertEqual(firstHeadingFontSize(scale: 1.5), 17 + 11 * 1.5)
        XCTAssertEqual(firstHeadingFontSize(scale: 0.0), 17)
    }

    func testHeadingScaleDoesNotChangeBodyRun() {
        let attributed = MarkdownPreviewRenderer().render(
            "# Title\n\nBody",
            profile: .original,
            columnWidth: 600,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            appVersion: "0",
            headingScale: 1.5
        )
        let ns = attributed.string as NSString
        let bodyRange = ns.range(of: "Body")
        XCTAssertNotEqual(bodyRange.location, NSNotFound)
        let font = attributed.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 17)
    }
}

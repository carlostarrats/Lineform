import AppKit
import CoreText
import XCTest
@testable import Lineform

final class MarkdownFontCascadeTests: XCTestCase {

    private func cascadeCount(_ font: NSFont) -> Int? {
        (CTFontCopyAttribute(font as CTFont, kCTFontCascadeListAttribute) as? [Any])?.count
    }

    func testFallbackFamiliesAllResolveOnThisSystem() {
        for family in MarkdownFontCascade.fallbackFamilies {
            XCTAssertNotNil(NSFont(name: family, size: 17), "\(family) does not ship with this macOS")
        }
    }

    func testApplyingAttachesTheCascadeWithoutChangingTheFamily() {
        let base = NSFont.systemFont(ofSize: 17)
        let cascaded = MarkdownFontCascade.applying(to: base)

        XCTAssertEqual(cascaded.familyName, base.familyName)
        XCTAssertEqual(cascaded.pointSize, base.pointSize)
        XCTAssertEqual(cascadeCount(cascaded), MarkdownFontCascade.fallbackFamilies.count)
    }

    func testMonospacedKeepsFixedPitch() {
        let mono = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        XCTAssertTrue(MarkdownFontCascade.applying(to: mono).isFixedPitch)
    }

    /// The regression the whole helper exists for. NSFontManager.convert drops the cascade on
    /// every system font — measured, not assumed — so a naive convert loses the fallback for
    /// headings, table headers, callout titles, and every bold/italic span.
    func testConvertPreservesTheCascadeOnSystemFonts() {
        let bases: [(String, NSFont)] = [
            ("systemFont", .systemFont(ofSize: 17)),
            ("monospacedSystemFont", .monospacedSystemFont(ofSize: 17, weight: .regular))
        ]

        for (label, base) in bases {
            let cascaded = MarkdownFontCascade.applying(to: base)
            for trait in [NSFontTraitMask.boldFontMask, .italicFontMask] {
                let converted = MarkdownFontCascade.convert(cascaded, toHaveTrait: trait)
                XCTAssertEqual(
                    cascadeCount(converted), MarkdownFontCascade.fallbackFamilies.count,
                    "\(label) lost its cascade under \(trait)"
                )
            }
        }
    }

    func testBareNSFontManagerStillDropsIt() {
        // Pins the platform behaviour the helper works around. If this ever starts passing,
        // the helper can be simplified — but do not assume it; measure.
        let cascaded = MarkdownFontCascade.applying(to: .systemFont(ofSize: 17))
        let naive = NSFontManager.shared.convert(cascaded, toHaveTrait: .boldFontMask)
        XCTAssertNil(cascadeCount(naive), "AppKit now preserves the cascade — revisit MarkdownFontCascade")
    }

    func testConvertActuallyAppliesTheTrait() {
        let bold = MarkdownFontCascade.convert(MarkdownFontCascade.applying(to: .systemFont(ofSize: 17)),
                                               toHaveTrait: .boldFontMask)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    }

    // MARK: - Wiring

    func testEveryFontOptionCarriesTheCascade() {
        var checked = 0
        for option in FontOption.groupedOptions.flatMap(\.options) where option.isAvailable {
            let font = option.resolvedFont(size: 17)
            checked += 1
            XCTAssertEqual(
                cascadeCount(font),
                MarkdownFontCascade.fallbackFamilies.count,
                "\(option.name) resolved without the CJK fallback"
            )
        }
        // A floor, because `where option.isAvailable` can silently shrink the loop to nothing on a
        // machine missing the optional families — in the limit this test would assert nothing at
        // all and still pass. SF Pro, New York, and Monospaced are always resolvable.
        XCTAssertGreaterThanOrEqual(
            checked, 3,
            "fewer options than the always-available set — this test has stopped covering anything"
        )
    }

    /// The nil-signal `isAvailable` depends on must survive the cascade: a bogus family still has
    /// to resolve to nil, or every unavailable font silently becomes "available".
    func testUnavailableFamilyStillResolvesToNil() {
        let bogus = FontOption(id: .comicSans, name: "Nope", familyName: "NoSuchFamilyXYZ", source: .system)
        XCTAssertNil(bogus.availableFont(size: 17))
        XCTAssertFalse(bogus.isAvailable)
    }

    /// Goes through `availableFont`, NOT `resolvedFont`: `resolvedFont`'s own fallback is cascaded
    /// too (Step 3a), so if `.newYork` ever started resolving to nil this test would pass through
    /// that fallback while the serif branch was silently broken.
    func testNewYorkFallsThroughToTheSerifDesignWithCascadeIntact() throws {
        let newYork = try XCTUnwrap(FontOption.option(for: .newYork))
        let font = try XCTUnwrap(newYork.availableFont(size: 17), "New York resolved to nil")

        XCTAssertEqual(cascadeCount(font), MarkdownFontCascade.fallbackFamilies.count)
        // Whichever branch produced it, it must actually be the serif face — not the sans-serif
        // system font arriving via some other path.
        let family = font.familyName ?? ""
        XCTAssertTrue(
            family.contains("New York") || family.contains("Serif"),
            "expected the New York / serif design, got \(family)"
        )
    }

    /// `resolvedFont`'s own `?? .systemFont` fallback is the case MOST likely to be rendering
    /// someone else's script, and `testEveryFontOptionCarriesTheCascade` cannot see it because it
    /// filters on `isAvailable`.
    func testTheUnavailableFontFallbackIsAlsoCascaded() {
        let bogus = FontOption(id: .comicSans, name: "Nope", familyName: "NoSuchFamilyXYZ", source: .system)
        let font = bogus.resolvedFont(size: 17)
        XCTAssertEqual(cascadeCount(font), MarkdownFontCascade.fallbackFamilies.count)
    }

    /// The cascade must not move the PRIMARY face's metrics — everything from heading size boosts
    /// to the image margin math is computed off them.
    func testCascadeDoesNotChangeThePrimaryFaceMetrics() {
        let bases: [NSFont] = [
            .systemFont(ofSize: 17),
            .monospacedSystemFont(ofSize: 17, weight: .regular)
        ]
        for base in bases {
            let cascaded = MarkdownFontCascade.applying(to: base)
            XCTAssertEqual(cascaded.ascender, base.ascender, accuracy: 0.001)
            XCTAssertEqual(cascaded.descender, base.descender, accuracy: 0.001)
            XCTAssertEqual(cascaded.leading, base.leading, accuracy: 0.001)
            XCTAssertEqual(cascaded.pointSize, base.pointSize, accuracy: 0.001)
        }
    }

    // MARK: - Directly constructed code faces

    /// The monospaced faces for inline code and fenced blocks are built directly, bypassing
    /// `FontOption`, so neither the renderer's body-font path nor `resolvedFont` covers them.
    /// CJK in comments, string literals, and prose-in-code is common.
    @MainActor
    func testRenderedCodeSpansAndBlocksCarryTheCascade() {
        let rendered = MarkdownPreviewRenderer().render(
            "Body `内联` text\n\n```\nコード\n```\n",
            profile: .original
        )

        var sawMonospaced = false
        rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            guard let font = value as? NSFont, font.isFixedPitch else {
                return
            }
            sawMonospaced = true
            XCTAssertEqual(
                self.cascadeCount(font),
                MarkdownFontCascade.fallbackFamilies.count,
                "a monospaced run rendered without the CJK fallback"
            )
        }
        XCTAssertTrue(sawMonospaced, "the fixture produced no monospaced runs — it no longer covers the code faces")
    }

    @MainActor
    func testEditorCodeHighlightingCarriesTheCascade() {
        // No window: the default test plan forbids constructing one. A bare NSTextView is enough
        // for the highlighter, which only touches its text storage.
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = "Body `内联` text\n"
        MarkdownSyntaxHighlighter().highlight(textView: textView, profile: .original)
        let storage = textView.textStorage!

        var sawMonospaced = false
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let font = value as? NSFont, font.isFixedPitch else {
                return
            }
            sawMonospaced = true
            XCTAssertEqual(
                self.cascadeCount(font),
                MarkdownFontCascade.fallbackFamilies.count,
                "an editor code-span run lost the CJK fallback"
            )
        }
        XCTAssertTrue(sawMonospaced, "the fixture produced no code-span runs")
    }

    // MARK: - Descriptor re-derivations

    /// Headings and table cells are rebuilt with `NSFont(descriptor:size:)` after the trait
    /// conversion (`MarkdownPreviewRenderer` heading size boost, table cell scale). That
    /// `NSFontDescriptor` carries `.cascadeList` through was asserted from reasoning alone;
    /// this repo has a track record of two implementations of one concept disagreeing, so pin it.
    @MainActor
    func testRenderedCJKHeadingAndTableCellsCarryTheCascade() throws {
        let rendered = MarkdownPreviewRenderer().render(
            "# 見出し\n\n| 標題 | 第二 |\n| --- | --- |\n| 单元格 | 内容 |\n",
            profile: .original
        )

        // The heading is the first run.
        let headingFont = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(
            cascadeCount(headingFont), MarkdownFontCascade.fallbackFamilies.count,
            "the heading lost the cascade through its descriptor re-derivation"
        )

        // Every table cell: locate them by the text they contain rather than by index, so the
        // assertion survives a change in how the table is stitched into the output.
        let ns = rendered.string as NSString
        for cell in ["標題", "第二", "单元格", "内容"] {
            let range = ns.range(of: cell)
            XCTAssertNotEqual(range.location, NSNotFound, "\(cell) is missing from the rendered table")
            guard range.location != NSNotFound else { continue }
            let font = try XCTUnwrap(
                rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            )
            XCTAssertEqual(
                cascadeCount(font), MarkdownFontCascade.fallbackFamilies.count,
                "table cell \"\(cell)\" lost the cascade"
            )
        }
    }

    // MARK: - Sites outside the original sweep

    /// `ExportTypographyPreset.standard` is the DEFAULT for PDF export and Print, and its
    /// `rendersMarkdown == false` branch lays out the entire raw document in one monospaced face —
    /// the highest-CJK-density surface in the app.
    @MainActor
    func testDefaultExportPresetLaysOutRawSourceWithTheCascade() throws {
        XCTAssertFalse(ExportTypographyPreset.standard.rendersMarkdown,
                       "the default preset now renders markdown — this test covers the raw-source branch")

        let textView = DocumentExportRenderer.makeExportTextView(
            text: "# 見出し\n\n中文段落。\n",
            profile: .original,
            paper: .usLetter,
            preset: .standard
        )
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertGreaterThan(storage.length, 0)

        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(cascadeCount(font), MarkdownFontCascade.fallbackFamilies.count,
                       "the default PDF/Print face resolves CJK per-glyph while Write mode does not")
    }

    /// The mermaid and math source captions OVERWRITE an already-cascaded base font with a fresh
    /// system face — the same drop-the-cascade shape as the `NSFontManager` bug. They draw
    /// localized strings, which are CJK in two shipped languages.
    @MainActor
    func testDiagramAndMathFallbackCaptionsCarryTheCascade() throws {
        // A deliberately invalid diagram and an empty math block both take the captioned-source
        // fallback path.
        let rendered = MarkdownPreviewRenderer().render(
            "```mermaid\nnot a real diagram\n```\n\n$$\n$$\n",
            profile: .original
        )

        var sawCaption = false
        for caption in ["Mermaid diagram (source)", "Math (source)"] {
            let range = (rendered.string as NSString).range(of: caption)
            guard range.location != NSNotFound else { continue }
            sawCaption = true
            let font = try XCTUnwrap(
                rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            )
            XCTAssertEqual(cascadeCount(font), MarkdownFontCascade.fallbackFamilies.count,
                           "the \"\(caption)\" caption lost the cascade")
        }
        XCTAssertTrue(sawCaption, "neither fallback caption rendered — the fixture no longer covers them")
    }

    /// The pie renderer draws DOCUMENT-DERIVED text (a `pie title 销售额` title and its slice
    /// labels) into a raster that goes into PDF.
    func testMermaidPieChartFontsCarryTheCascade() {
        XCTAssertEqual(cascadeCount(MermaidPieRenderer.titleFont),
                       MarkdownFontCascade.fallbackFamilies.count)
        XCTAssertEqual(cascadeCount(MermaidPieRenderer.legendFont),
                       MarkdownFontCascade.fallbackFamilies.count)
    }

    func testMermaidPieChartRendersCJKTitleAndLabels() throws {
        let model = try XCTUnwrap(MermaidPieChart.parse("pie title 销售额\n \"苹果\" : 30\n \"梨\" : 10"))
        let image = MermaidPieRenderer.image(
            model: model, background: .white, foreground: .black, scale: 2
        )
        XCTAssertNotNil(image)
    }

    // MARK: - Memoization

    /// `applying(to:)` realizes a font, and the editor runs the code-span/fence face once per
    /// token inside the debounced per-keystroke highlight loop. The face depends on nothing but
    /// the point size, so it must be cached rather than rebuilt.
    func testMonospacedIsMemoizedPerPointSize() {
        let first = MarkdownFontCascade.monospaced(ofSize: 17)
        let second = MarkdownFontCascade.monospaced(ofSize: 17)
        XCTAssertTrue(first === second, "the cascaded monospaced face is rebuilt on every call")

        let other = MarkdownFontCascade.monospaced(ofSize: 13)
        XCTAssertEqual(other.pointSize, 13, accuracy: 0.001)
        XCTAssertFalse(first === other, "different point sizes must not share a cache entry")
    }

    func testMonospacedIsCascadedAndFixedPitch() {
        let font = MarkdownFontCascade.monospaced(ofSize: 17)
        XCTAssertTrue(font.isFixedPitch)
        XCTAssertEqual(cascadeCount(font), MarkdownFontCascade.fallbackFamilies.count)
        XCTAssertEqual(font.pointSize, 17, accuracy: 0.001)
    }
}

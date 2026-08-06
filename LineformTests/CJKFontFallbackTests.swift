import AppKit
import CoreText
import XCTest
@testable import Lineform

/// Lineform declares NO `.cascadeList` anywhere. CJK reaches a face through CoreText's implicit
/// substitution, which is locale-informed AND metric-compatible with the primary face.
///
/// This file exists because the opposite was built and shipped on this branch — an explicit
/// `["Hiragino Sans", "PingFang SC"]` attached to every resolved font — on the premise that the
/// implicit substitution was "unchosen". Measured on macOS 26, the premise is false in every
/// particular, and the cascade made typography WORSE: the system picks optically-sized UI variants
/// (`.PingFang UI Text SC`) whose metrics match the Latin primary, while the public families a
/// hardcoded list can name are taller, so one mixed document went from uniform line heights to
/// two distinct heights on one page, and exports re-paginated.
///
/// So these tests pin the PLATFORM behaviour we now depend on, plus the absence of a cascade.
/// If one of them fails, re-measure with `CTFontCreateForString` before concluding anything —
/// do not "fix" it by declaring a fallback list.
final class CJKFontFallbackTests: XCTestCase {

    /// All-Han except the last two, which mix Han with kana. Han is shared between the scripts and
    /// is the whole question; kana is script-exclusive and resolves on its own.
    private static let samples = ["今天雪很大", "这是中文", "日本語", "見出し", "单元格", "吾輩は猫である"]

    private func cascadeCount(_ font: NSFont) -> Int? {
        (CTFontCopyAttribute(font as CTFont, kCTFontCascadeListAttribute) as? [Any])?.count
    }

    /// The face CoreText actually picks for the character at `index` of `text` in `font`.
    private func substituteFont(_ text: String, _ index: Int, in font: NSFont) -> CTFont {
        CTFontCreateForString(font as CTFont, text as CFString, CFRange(location: index, length: 1))
    }

    private func hasGlyph(for character: String, in font: CTFont) -> Bool {
        var characters = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        let mapped = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        return mapped && glyphs.allSatisfy { $0 != 0 }
    }

    /// Asserts every character of every sample reaches a real glyph in a real family — never
    /// `.notdef`, never the LastResort face.
    private func assertResolvesCJK(_ font: NSFont, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for sample in Self.samples {
            let ns = sample as NSString
            for index in 0..<ns.length {
                let character = ns.substring(with: NSRange(location: index, length: 1))
                let resolved = substituteFont(sample, index, in: font)
                let family = CTFontCopyFamilyName(resolved) as String
                XCTAssertFalse(family.contains("LastResort"),
                               "\(label): \(character) fell through to LastResort", file: file, line: line)
                XCTAssertTrue(hasGlyph(for: character, in: resolved),
                              "\(label): \(character) resolved to \(family) with no glyph", file: file, line: line)
            }
        }
    }

    // MARK: - The platform resolves CJK on its own

    /// Every font the app can hand to the text system resolves CJK bare — no fallback list of ours
    /// involved. This is the claim the whole cascade was supposed to guarantee; the platform
    /// already did.
    func testEveryFontOptionResolvesCJKWithoutADeclaredCascade() {
        var checked = 0
        for option in FontOption.groupedOptions.flatMap(\.options) where option.isAvailable {
            checked += 1
            assertResolvesCJK(option.resolvedFont(size: 17), option.name)
        }
        // A floor: `where option.isAvailable` can shrink to nothing on a machine missing the
        // optional families, and this test would then assert nothing and still pass.
        XCTAssertGreaterThanOrEqual(checked, 3, "fewer options than the always-available set")
    }

    /// The specific measurement that misled this branch. "`NSFontManager.convert` drops the
    /// cascade" was true, and irrelevant: the converted font resolves CJK to a BOLD CJK face on
    /// its own. Headings, table headers, callout titles, and every bold span go through here.
    func testBoldConversionStillResolvesCJKToABoldFace() throws {
        let serifDescriptor = try XCTUnwrap(NSFont.systemFont(ofSize: 17).fontDescriptor.withDesign(.serif))
        let bases: [(String, NSFont)] = [
            ("systemFont", .systemFont(ofSize: 17)),
            ("monospacedSystemFont", .monospacedSystemFont(ofSize: 17, weight: .regular)),
            ("serif design", try XCTUnwrap(NSFont(descriptor: serifDescriptor, size: 17)))
        ]

        for (label, base) in bases {
            let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask), label)
            assertResolvesCJK(bold, "\(label) bold")

            for sample in Self.samples {
                let resolved = substituteFont(sample, 0, in: bold)
                XCTAssertTrue(
                    CTFontGetSymbolicTraits(resolved).contains(.traitBold),
                    "\(label) bold: \(sample.prefix(1)) resolved to a NON-bold CJK face "
                        + "(\(CTFontCopyPostScriptName(resolved) as String)) — re-measure before "
                        + "reaching for a cascade list, which would make this worse, not better"
                )
            }
        }
    }

    /// Evidence 4 from the removal review: a declared sans cascade dragged the serif reading font's
    /// CJK out of Songti SC and into PingFang/Hiragino. Bare, the serif design keeps a serif Han
    /// face — one of the things the cascade silently cost.
    func testTheSerifReadingFontKeepsASerifCJKFace() throws {
        let newYork = try XCTUnwrap(FontOption.option(for: .newYork))
        // Through `availableFont`, NOT `resolvedFont`: if `.newYork` ever resolved to nil,
        // `resolvedFont`'s system fallback would conceal it.
        let font = try XCTUnwrap(newYork.availableFont(size: 17), "New York resolved to nil")
        let family = font.familyName ?? ""
        XCTAssertTrue(family.contains("New York") || family.contains("Serif"),
                      "expected the New York / serif design, got \(family)")

        let resolved = CTFontCopyFamilyName(substituteFont("中文", 0, in: font)) as String
        XCTAssertFalse(resolved.contains("PingFang"),
                       "the serif reading font now resolves CJK to a SANS face (\(resolved))")
    }

    // MARK: - Metric compatibility, the regression a cascade caused

    private func lineFragmentHeights(_ font: NSFont, _ text: String) -> [CGFloat] {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 2000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        var heights: [CGFloat] = []
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var range = NSRange(location: 0, length: 0)
            heights.append(layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &range).height)
            glyphIndex = NSMaxRange(range)
        }
        return heights
    }

    private static let mixedScriptDocument = """
        The quick brown fox
        中文段落示例文字
        日本語の段落見本
        Another latin line
        漢字とかなの行
        """

    /// THE regression, and the test that would have caught it. The system faces the app reads by
    /// default substitute an optically-sized UI variant whose metrics match the Latin primary, so a
    /// mixed EN/zh/ja page has ONE line height. Measured at 16pt: 18/18/18/18/18 bare, versus
    /// 18/24/24/18/24 with `["Hiragino Sans", "PingFang SC"]` declared.
    func testMixedScriptLinesShareOneLineHeight() throws {
        let faces: [(String, NSFont)] = [
            ("SF Pro", try XCTUnwrap(FontOption.option(for: .sfPro)?.resolvedFont(size: 16))),
            ("Monospaced", try XCTUnwrap(FontOption.option(for: .jetBrainsMono)?.resolvedFont(size: 16)))
        ]

        for (label, font) in faces {
            let heights = lineFragmentHeights(font, Self.mixedScriptDocument)
            XCTAssertEqual(heights.count, 5, "\(label): the fixture stopped laying out as five lines")
            let distinct = Set(heights.map { ($0 * 100).rounded() })
            XCTAssertEqual(distinct.count, 1,
                           "\(label): Latin, Chinese and Japanese lines no longer share a line height "
                               + "(\(heights)) — something reintroduced a font fallback that is not "
                               + "metric-compatible with the primary face")
        }
    }

    /// The counterfactual, kept so the rule above has its reason attached rather than remembered:
    /// declaring the public CJK families we would have had to name DOES break that uniformity.
    /// If this ever fails, those families became metric-compatible — re-measure before
    /// concluding a cascade is now harmless; it still costs the serif face (above) and a
    /// per-conversion re-attachment on a per-keystroke path.
    func testADeclaredCascadeWouldBreakThatUniformity() throws {
        let base = try XCTUnwrap(FontOption.option(for: .sfPro)?.resolvedFont(size: 16))
        let descriptors = ["Hiragino Sans", "PingFang SC"].map {
            NSFontDescriptor(fontAttributes: [.family: $0])
        }
        let cascaded = try XCTUnwrap(
            NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: descriptors]),
                   size: base.pointSize)
        )
        let heights = lineFragmentHeights(cascaded, Self.mixedScriptDocument)
        XCTAssertGreaterThan(Set(heights.map { ($0 * 100).rounded() }).count, 1,
                             "a hardcoded CJK cascade no longer changes line heights (\(heights))")
    }

    // MARK: - No cascade is declared anywhere

    /// The guard against rebuilding the feature by halves: no font the app resolves, and no font
    /// it renders with, carries a fallback list.
    ///
    /// This originally covered only `FontOption.resolvedFont` and `MarkdownPreviewRenderer`'s
    /// output — two of the SEVEN sites the removed `MarkdownFontCascade` used to attach to (see
    /// `git show 33206ad`). Widened to also cover the export path (`DocumentExportRenderer`, the
    /// default PDF/Print preset and the highest-CJK-density surface in the app) and the live
    /// editor's applied typography and syntax highlighting (`LineformTextView`,
    /// `MarkdownSyntaxHighlighter`).
    ///
    /// Three former sites are NOT reached here, and can't be without adding test-only surface to
    /// production code: `MermaidPieChart.MermaidPieRenderer.image` builds its title/legend fonts as
    /// LOCAL variables and returns only a rasterized `NSImage` — there is no attributed string or
    /// font attribute left to inspect once it's pixels. `SaveAsExport.ExportPanelController`'s font
    /// lives on an `NSSavePanel` accessory view, and constructing an `NSSavePanel` (an `NSWindow`
    /// subclass) is forbidden in the default test plan. `FirstLaunchIntroOverlay`'s font lives on a
    /// `private let label` with no accessor.
    @MainActor
    func testNoResolvedOrRenderedFontDeclaresACascadeList() throws {
        for option in FontOption.groupedOptions.flatMap(\.options) where option.isAvailable {
            XCTAssertNil(cascadeCount(option.resolvedFont(size: 17)),
                         "\(option.name) declares a cascade list")
        }

        let rendered = MarkdownPreviewRenderer().render(
            "# 見出し\n\nBody **粗体** and `内联` text\n\n```\nコード\n```\n\n| 標題 | 第二 |\n| --- | --- |\n| 单元格 | 内容 |\n",
            profile: .original
        )
        var runs = 0
        rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            runs += 1
            XCTAssertNil(self.cascadeCount(font),
                         "a rendered run declares a cascade list at \(range)")
        }
        XCTAssertGreaterThan(runs, 3, "the fixture stopped producing distinct font runs")

        // The export path: DocumentExportRenderer.rawSourceAttributedString, reached through the
        // "Normal" preset (`.standard`, `rendersMarkdown == false`) that lays out the raw markdown
        // source — the exact site the removed cascade's comment called out by name.
        let exportTextView = DocumentExportRenderer.makeExportTextView(
            text: "中文段落 日本語の文章 **粗体**",
            profile: .original,
            paper: .usLetter,
            preset: .standard
        )
        var exportRuns = 0
        if let exportStorage = exportTextView.textStorage {
            exportStorage.enumerateAttribute(
                .font, in: NSRange(location: 0, length: exportStorage.length)
            ) { value, range, _ in
                guard let font = value as? NSFont else { return }
                exportRuns += 1
                XCTAssertNil(self.cascadeCount(font),
                             "an exported run declares a cascade list at \(range)")
            }
        }
        XCTAssertGreaterThan(exportRuns, 0, "the export fixture stopped producing font runs")

        // The live editor's applied typography (LineformTextView.applyTypography) and its syntax
        // highlighting overlay (MarkdownSyntaxHighlighter, including the code-span/code-fence font).
        let editorTextView = LineformTextView()
        editorTextView.applyTypography(.original)
        XCTAssertNil(cascadeCount(try XCTUnwrap(editorTextView.font)),
                     "LineformTextView's applied typography declares a cascade list")

        editorTextView.string = "中文段落 `内联代码` 日本語\n\n```\nコード块\n```\n"
        MarkdownSyntaxHighlighter().highlight(textView: editorTextView, profile: .original)
        var highlightRuns = 0
        if let highlightStorage = editorTextView.textStorage {
            highlightStorage.enumerateAttribute(
                .font, in: NSRange(location: 0, length: highlightStorage.length)
            ) { value, range, _ in
                guard let font = value as? NSFont else { return }
                highlightRuns += 1
                XCTAssertNil(self.cascadeCount(font),
                             "a syntax-highlighted run declares a cascade list at \(range)")
            }
        }
        XCTAssertGreaterThan(highlightRuns, 0, "the highlighting fixture stopped producing font runs")
    }

    // MARK: - Retired FontIDs (kept: unrelated to the cascade, and a real fix)

    /// A `FontID` can be RETIRED: still declared in the enum so persisted `ReadingProfile`s keep
    /// decoding, but dropped from `groupedOptions` so it is no longer offered. `.lexend` is one
    /// today, and `ReadingProfile` is `Codable` with NO fontID sanitization on decode — so a
    /// profile persisted from a build where it was selectable still arrives carrying it.
    ///
    /// This pins the CLASS, not today's instance: EVERY declared id must reach a usable font
    /// through ALL THREE render consumers, so the next retirement is safe by construction.
    @MainActor
    func testEveryDeclaredFontIDYieldsAUsableFontThroughAllThreeConsumers() throws {
        let retired = FontID.allCases.filter { FontOption.option(for: $0) == nil }
        XCTAssertFalse(
            retired.isEmpty,
            "no FontID is retired any more — if one was un-retired, keep this test covering the class"
        )

        for id in FontID.allCases {
            var profile = ReadingProfile.original
            profile.fontID = id
            let label = "\(id)\(retired.contains(id) ? " (retired)" : "")"

            // 1. The preview renderer's body font.
            let rendered = MarkdownPreviewRenderer().render("中文段落。", profile: profile)
            let bodyFont = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            assertResolvesCJK(bodyFont, "preview body font for \(label)")

            // 2. The editor's base attributes.
            let base = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
            let baseFont = try XCTUnwrap(base[.font] as? NSFont)
            assertResolvesCJK(baseFont, "highlighter base font for \(label)")

            // 3. The text view's applied typography.
            let textView = LineformTextView()
            textView.applyTypography(profile)
            let viewFont = try XCTUnwrap(textView.font)
            assertResolvesCJK(viewFont, "text view font for \(label)")
        }
    }

    /// A retired id substitutes the whole default OPTION, not just a face — so its other
    /// properties are corrected too, which a bare system font would not have done.
    func testRetiredFontIDResolvesToTheDefaultOption() {
        XCTAssertNil(FontOption.option(for: .lexend), "Lexend is no longer retired — pick another id")
        XCTAssertEqual(FontOption.resolved(for: .lexend), FontOption.defaultOption)
        XCTAssertEqual(FontOption.defaultOption.id, .sfPro)
        // A live id must still resolve to itself, not to the default.
        XCTAssertEqual(FontOption.resolved(for: .newYork).id, .newYork)
    }

    /// The nil signal `isAvailable` depends on: a bogus family must resolve to nil, or every
    /// unavailable font silently becomes "available".
    func testUnavailableFamilyStillResolvesToNil() {
        let bogus = FontOption(id: .comicSans, name: "Nope", familyName: "NoSuchFamilyXYZ", source: .system)
        XCTAssertNil(bogus.availableFont(size: 17))
        XCTAssertFalse(bogus.isAvailable)
        // …and `resolvedFont` still hands back something usable.
        assertResolvesCJK(bogus.resolvedFont(size: 17), "unavailable-font fallback")
    }

    /// The pie renderer draws DOCUMENT-DERIVED text (a `pie title 销售额` title and its slice
    /// labels) into a raster bound for PDF and Print — it must still render CJK.
    func testMermaidPieChartRendersCJKTitleAndLabels() throws {
        let model = try XCTUnwrap(MermaidPieChart.parse("pie title 销售额\n \"苹果\" : 30\n \"梨\" : 10"))
        let image = MermaidPieRenderer.image(
            model: model, background: .white, foreground: .black, scale: 2
        )
        XCTAssertNotNil(image)
    }
}

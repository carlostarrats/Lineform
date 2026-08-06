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

    // MARK: - What the cascade actually RESOLVES

    /// Sample text spanning the interesting cases. All-Han except the last, which mixes Han with
    /// kana — kana is script-exclusive, Han is not, and the Han is the whole question.
    private static let chineseSamples = ["今天雪很大", "直骨雪今漢字", "这是中文"]
    private static let japaneseSamples = ["日本語", "吾輩は猫である"]
    private static let allSamples = chineseSamples + japaneseSamples

    private func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    /// The family CoreText actually picks for the character at `index` of `text` in `font`.
    private func resolvedFamily(_ text: String, _ index: Int, in font: NSFont) -> String {
        let resolved = CTFontCreateForString(
            font as CTFont, text as CFString, CFRange(location: index, length: 1)
        )
        return CTFontCopyFamilyName(resolved) as String
    }

    /// `(character, family)` for every HAN character in `text` — the shared characters whose face
    /// the ordering decides. Kana and script-exclusive punctuation are excluded on purpose.
    private func hanFamilies(_ text: String, in font: NSFont) -> [(String, String)] {
        let ns = text as NSString
        return (0..<ns.length).compactMap { index in
            let character = ns.substring(with: NSRange(location: index, length: 1))
            guard let scalar = character.unicodeScalars.first, isHan(scalar) else { return nil }
            return (character, resolvedFamily(text, index, in: font))
        }
    }

    private func cascaded(_ families: [String]) -> NSFont {
        let descriptors = families.map { NSFontDescriptor(fontAttributes: [.family: $0]) }
        let base = NSFont.systemFont(ofSize: 17)
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: descriptors]),
                      size: 17) ?? base
    }

    /// THE REGRESSION, asserted on the RESOLVED face rather than on the cascade list's length.
    /// Every other cascade test in this file checks only that a list is ATTACHED, which is why a
    /// hardcoded Japanese-first order shipped green while rendering pure Chinese in a Japanese face
    /// for every character the two scripts share. `这` is the only character in these samples that
    /// is simplified-only, so it is the only one that escapes — which is why `这是中文` looked fine
    /// and hid the bug.
    func testJapaneseFirstOrderDragsChineseHanIntoTheJapaneseFace() {
        let font = cascaded(MarkdownFontCascade.japaneseFirst)
        var draggedIn = 0
        for sample in Self.chineseSamples {
            for (character, family) in hanFamilies(sample, in: font) where family == "Hiragino Sans" {
                draggedIn += 1
                XCTAssertNotEqual(character, "这", "简体-only 这 should never reach the Japanese face")
            }
        }
        XCTAssertGreaterThan(
            draggedIn, 8,
            "Japanese-first no longer pulls shared Han out of the Chinese face — re-measure before "
                + "concluding the ordering rule is unnecessary"
        )
    }

    /// The shipped default, and the reason it is the default: every shared Han character lands in
    /// PingFang SC for Chinese AND Japanese text. Kana still resolves to Hiragino Sans, because
    /// kana is script-exclusive and CoreText walks past PingFang for it — the cascade costs
    /// Japanese readers their kana face nothing.
    func testSimplifiedChineseFirstPutsEveryHanCharacterInPingFang() {
        let font = cascaded(MarkdownFontCascade.simplifiedChineseFirst)
        var checked = 0
        for sample in Self.allSamples {
            for (character, family) in hanFamilies(sample, in: font) {
                checked += 1
                XCTAssertEqual(family, "PingFang SC", "\(character) in \"\(sample)\"")
            }
        }
        XCTAssertGreaterThan(checked, 15, "the samples stopped containing Han")

        // Kana, the script-exclusive control.
        XCTAssertEqual(resolvedFamily("吾輩は猫である", 2, in: font), "Hiragino Sans",
                       "は left the Japanese kana face")
    }

    /// The default must REPRODUCE the platform, not override it. Measured on macOS 26: an `en`
    /// machine's bare `.systemFont` already resolves every Han character below through a PingFang
    /// face — CoreText's implicit substitution is locale-informed, not unchosen. A default that
    /// moved these characters would be the regression, not the fix. If this ever fails, re-derive
    /// the default order from a fresh measurement rather than editing the assertion.
    func testTheNonJapaneseDefaultReproducesThePlatformsHanFace() {
        let bare = NSFont.systemFont(ofSize: 17)
        let cascadedFont = cascaded(MarkdownFontCascade.simplifiedChineseFirst)

        for sample in Self.allSamples {
            for (character, family) in hanFamilies(sample, in: bare) {
                XCTAssertTrue(family.contains("PingFang"),
                              "the platform now resolves \(character) to \(family)")
            }
            for (character, family) in hanFamilies(sample, in: cascadedFont) {
                XCTAssertTrue(family.contains("PingFang"),
                              "the default cascade moved \(character) to \(family)")
            }
        }
    }

    /// Pure, so the language branch is testable without relaunching the app under another UI
    /// language. `Bundle.main.preferredLocalizations` is the source — NOT `Locale.language.languageCode`,
    /// which collapses `zh-Hans` to `zh`.
    func testOrderIsDerivedFromThePreferredLocalization() {
        for japanese in [["ja"], ["ja-JP"], ["JA"], ["ja", "en"]] {
            XCTAssertEqual(MarkdownFontCascade.resolvedFallbackFamilies(preferring: japanese),
                           MarkdownFontCascade.japaneseFirst, "\(japanese)")
        }
        for other in [["zh-Hans"], ["zh-Hant"], ["en"], ["de"], ["es"], ["fr"], [], ["en", "ja"]] {
            XCTAssertEqual(MarkdownFontCascade.resolvedFallbackFamilies(preferring: other),
                           MarkdownFontCascade.simplifiedChineseFirst, "\(other)")
        }
    }

    /// Whichever branch this machine takes, the shipped list must be one of the two declared orders
    /// and must always be the same two families — the COUNT is what every other test in this file
    /// asserts against, so only the order may vary.
    func testShippedOrderIsOneOfTheTwoDeclaredOrders() {
        XCTAssertTrue(
            MarkdownFontCascade.fallbackFamilies == MarkdownFontCascade.japaneseFirst
                || MarkdownFontCascade.fallbackFamilies == MarkdownFontCascade.simplifiedChineseFirst,
            "\(MarkdownFontCascade.fallbackFamilies)"
        )
        XCTAssertEqual(Set(MarkdownFontCascade.japaneseFirst),
                       Set(MarkdownFontCascade.simplifiedChineseFirst))
        XCTAssertEqual(MarkdownFontCascade.fallbackFamilies,
                       MarkdownFontCascade.resolvedFallbackFamilies(
                           preferring: Bundle.main.preferredLocalizations))
    }

    /// End to end: a font that went through the app's OWN `applying(to:)` — not a hand-built
    /// descriptor — resolves shared Han into the family the derived order puts first.
    func testAppliedCascadeResolvesHanIntoTheLeadingFamily() {
        let font = MarkdownFontCascade.applying(to: .systemFont(ofSize: 17))
        let leading = MarkdownFontCascade.fallbackFamilies[0]
        var checked = 0
        for sample in Self.allSamples {
            for (_, family) in hanFamilies(sample, in: font) where family == leading {
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 10, "no Han character reached \(leading)")
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

    // MARK: - Retired FontIDs

    /// A `FontID` can be RETIRED: still declared in the enum so persisted `ReadingProfile`s keep
    /// decoding, but dropped from `groupedOptions` so it is no longer offered. `.lexend` is one
    /// today, and `ReadingProfile` is `Codable` with NO fontID sanitization on decode — so a
    /// profile persisted from a build where it was selectable still arrives carrying it.
    ///
    /// This pins the CLASS, not today's instance: EVERY declared id must reach a cascaded font
    /// through ALL THREE render consumers, so the next retirement is safe by construction.
    @MainActor
    func testEveryDeclaredFontIDYieldsACascadedFontThroughAllThreeConsumers() throws {
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
            XCTAssertEqual(cascadeCount(bodyFont), MarkdownFontCascade.fallbackFamilies.count,
                           "preview body font uncascaded for \(label)")

            // 2. The editor's base attributes.
            let base = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
            let baseFont = try XCTUnwrap(base[.font] as? NSFont)
            XCTAssertEqual(cascadeCount(baseFont), MarkdownFontCascade.fallbackFamilies.count,
                           "highlighter base font uncascaded for \(label)")

            // 3. The text view's applied typography.
            let textView = LineformTextView()
            textView.applyTypography(profile)
            let viewFont = try XCTUnwrap(textView.font)
            XCTAssertEqual(cascadeCount(viewFont), MarkdownFontCascade.fallbackFamilies.count,
                           "text view font uncascaded for \(label)")
        }
    }

    /// A retired id substitutes the whole default OPTION, not just a face — so its other
    /// properties are corrected too, which a cascaded bare font would not have done.
    func testRetiredFontIDResolvesToTheDefaultOption() {
        XCTAssertNil(FontOption.option(for: .lexend), "Lexend is no longer retired — pick another id")
        XCTAssertEqual(FontOption.resolved(for: .lexend), FontOption.defaultOption)
        XCTAssertEqual(FontOption.defaultOption.id, .sfPro)
        // A live id must still resolve to itself, not to the default.
        XCTAssertEqual(FontOption.resolved(for: .newYork).id, .newYork)
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

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
        for option in FontOption.groupedOptions.flatMap(\.options) where option.isAvailable {
            let font = option.resolvedFont(size: 17)
            XCTAssertEqual(
                cascadeCount(font),
                MarkdownFontCascade.fallbackFamilies.count,
                "\(option.name) resolved without the CJK fallback"
            )
        }
    }

    /// The nil-signal `isAvailable` depends on must survive the cascade: a bogus family still has
    /// to resolve to nil, or every unavailable font silently becomes "available".
    func testUnavailableFamilyStillResolvesToNil() {
        let bogus = FontOption(id: .comicSans, name: "Nope", familyName: "NoSuchFamilyXYZ", source: .system)
        XCTAssertNil(bogus.availableFont(size: 17))
        XCTAssertFalse(bogus.isAvailable)
    }

    func testNewYorkFallsThroughToTheSerifDesignWithCascadeIntact() throws {
        let newYork = try XCTUnwrap(FontOption.option(for: .newYork))
        let font = newYork.resolvedFont(size: 17)
        XCTAssertNotNil(CTFontCopyAttribute(font as CTFont, kCTFontCascadeListAttribute))
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
}

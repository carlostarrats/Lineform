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
}

import XCTest
@testable import LineformCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// `MarkdownTokenStyler`: whole-document base attributes, token inks only inside the scope.
final class MarkdownTokenStylerTests: XCTestCase {
    private func color(_ storage: NSTextStorage, at location: Int) -> PlatformColor? {
        storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? PlatformColor
    }

    func testApplyColorsTokensOnlyInsideTheScope() {
        let doc = "# Top heading\n" + String(repeating: "plain body line\n", count: 200) + "# Bottom heading"
        let storage = NSTextStorage(string: doc)
        MarkdownTokenStyler.apply(to: storage, profile: .original, tokenScope: NSRange(location: 0, length: 13))

        XCTAssertEqual(color(storage, at: 0), MarkdownTextStyle.markdownMarkerColor(for: .original))
        let bottom = (doc as NSString).range(of: "# Bottom heading").location
        XCTAssertEqual(color(storage, at: bottom), Theme.theme(for: .original).textColor)
        // Base attributes are whole-document: the font is the base font past the scope too.
        XCTAssertEqual(storage.attribute(.font, at: bottom, effectiveRange: nil) as? PlatformFont,
                       MarkdownTextStyle.baseAttributes(for: .original)[.font] as? PlatformFont)
    }

    func testApplyBaseThenApplyTokensRefreshesOnlyTheirScope() {
        let storage = NSTextStorage(string: "# A\n# B\n# C")
        MarkdownTokenStyler.applyBase(to: storage, profile: .original)
        let base = Theme.theme(for: .original).textColor
        XCTAssertEqual(color(storage, at: 0), base)

        MarkdownTokenStyler.applyTokens(to: storage, profile: .original, scope: NSRange(location: 4, length: 3))
        XCTAssertEqual(color(storage, at: 4), MarkdownTextStyle.markdownMarkerColor(for: .original))
        XCTAssertEqual(color(storage, at: 0), base)
        XCTAssertEqual(color(storage, at: 8), base)
    }

    func testApplyTokensResetsStaleTokenAttributesInItsScope() {
        let storage = NSTextStorage(string: "`code` here")
        MarkdownTokenStyler.apply(to: storage, profile: .original, tokenScope: nil)
        XCTAssertEqual(color(storage, at: 1), MarkdownTextStyle.inlineCodeColor(for: .original))

        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "x") // no longer code
        MarkdownTokenStyler.applyTokens(to: storage, profile: .original, scope: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(color(storage, at: 1), Theme.theme(for: .original).textColor)
    }

    func testTokenAttributesPerKind() {
        var profile = ReadingProfile.original
        profile.fontSize = 21
        let marker = MarkdownTextStyle.markdownMarkerColor(for: profile)
        let link = Theme.theme(for: profile).readableInk(PlatformColor.lineformLink)
        for kind in [MarkdownTokenKind.headingMarker, .listMarker, .checkbox, .blockquoteMarker, .linkDestination] {
            XCTAssertEqual(MarkdownTokenStyler.attributes(for: kind, profile: profile)[.foregroundColor] as? PlatformColor, marker, "\(kind)")
        }
        for kind in [MarkdownTokenKind.linkText, .imageText, .imageDestination] {
            XCTAssertEqual(MarkdownTokenStyler.attributes(for: kind, profile: profile)[.foregroundColor] as? PlatformColor, link, "\(kind)")
        }
        for kind in [MarkdownTokenKind.codeSpan, .codeFence] {
            let attributes = MarkdownTokenStyler.attributes(for: kind, profile: profile)
            XCTAssertEqual(attributes[.foregroundColor] as? PlatformColor, MarkdownTextStyle.inlineCodeColor(for: profile))
            XCTAssertEqual(attributes[.font] as? PlatformFont, PlatformFont.monospacedSystemFont(ofSize: 21, weight: .regular))
        }
    }
}

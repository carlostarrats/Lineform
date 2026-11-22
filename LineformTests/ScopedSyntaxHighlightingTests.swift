import AppKit
import XCTest
@testable import Lineform
@testable import LineformCore

final class ScopedSyntaxHighlightingTests: XCTestCase {

    // MARK: - Forwarders (the pure cases moved to LineformCore's MarkdownTokenScopeTests)

    /// The Mac names forward to `MarkdownTokenScope` unchanged.
    func testMacNamesForwardToTheSharedTokenScope() {
        let text = "aaaa\nbbbb\ncccc\ndddd\neeee" as NSString
        let visible = NSRange(location: 10, length: 4)
        XCTAssertEqual(
            MarkdownSyntaxHighlighter.scopedTokenRange(visibleRange: visible, margin: 1, in: text),
            MarkdownTokenScope.scopedTokenRange(in: text, around: visible, margin: 1)
        )
        let doc = "# H\n- item `code`\n[l](d)" as NSString
        let scope = NSRange(location: 0, length: doc.length)
        XCTAssertEqual(MarkdownSyntaxHighlighter().tokens(in: doc, scope: scope),
                       MarkdownTokenScope.tokens(in: doc, scope: scope))
        XCTAssertTrue(MarkdownSyntaxHighlighter.range(NSRange(location: 0, length: 10), covers: NSRange(location: 2, length: 3)))
        XCTAssertFalse(MarkdownSyntaxHighlighter.range(NSRange(location: 0, length: 10), covers: NSRange(location: 8, length: 5)))
    }

    // MARK: - Task 3: base pass + scoped token pass

    @MainActor
    func testHighlightWithTokenScopeColorsOnlyInsideScope() {
        // Heading at top (loc 0) and a heading far below; scope only the top.
        let doc = "# Top heading\n" + String(repeating: "plain body line\n", count: 200) + "# Bottom heading"
        let textView = LineformTextView()
        textView.string = doc
        let highlighter = MarkdownSyntaxHighlighter()

        let topScope = NSRange(location: 0, length: 13) // "# Top heading"
        highlighter.highlight(textView: textView, profile: .original, tokenScope: topScope)

        let storage = textView.textStorage!
        let markerColor = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        let topMarker = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        assertSameRGB(topMarker!, markerColor) // '#' colored in scope

        let bottomHashLocation = (doc as NSString).range(of: "# Bottom heading").location
        let bottomMarker = storage.attribute(.foregroundColor, at: bottomHashLocation, effectiveRange: nil) as? NSColor
        // Off-scope '#' stays base text color, NOT marker color.
        assertSameRGB(bottomMarker!, Theme.theme(for: .original).textColor)
    }

    @MainActor
    func testRefreshTokensColorsOnlyItsScopeAndLeavesRestUntouched() {
        let doc = "# A\n# B\n# C"
        let textView = LineformTextView()
        textView.string = doc
        let highlighter = MarkdownSyntaxHighlighter()
        // Start from all-base (no tokens applied anywhere).
        highlighter.highlight(textView: textView, profile: .original, tokenScope: NSRange(location: 0, length: 0))

        let storage = textView.textStorage!
        let base = Theme.theme(for: .original).textColor
        assertSameRGB(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor, base)

        // Refresh only the second heading's line ("# B" starts at loc 4).
        highlighter.refreshTokens(textView: textView, profile: .original, scope: NSRange(location: 4, length: 3))
        let marker = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        assertSameRGB(storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as! NSColor, marker) // '#' of B
        assertSameRGB(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor, base)   // A still base
    }

    // MARK: - Parity with the pre-move highlighter

    /// The token styling moved into LineformCore's `MarkdownTokenStyler` (2026-11). The Mac's
    /// `highlight` / `refreshTokens` must still write byte-identical attributes, so this compares
    /// them with a frozen copy of the pre-move implementation, for every theme, high contrast on and
    /// off, and every token kind, on a whole pass, a scoped pass and a refresh.
    @MainActor
    func testHighlightAndRefreshWriteTheSameAttributesAsThePreMoveHighlighter() {
        let doc = """
        # Heading
        - item with `code` and [link](https://example.com)
        1. [ ] task
        > quote ![alt](images/a.png) and ![](b.png)
        ```
        fenced
        ```
        tail line
        """
        let length = (doc as NSString).length
        var profiles: [ReadingProfile] = []
        for theme in ThemeID.allCases {
            for highContrast in [false, true] {
                var profile = ReadingProfile.original
                profile.themeID = theme
                profile.highContrastEnabled = highContrast
                profile.fontSize = 19
                profiles.append(profile)
            }
        }
        let scopes: [NSRange?] = [nil, NSRange(location: 0, length: 10), NSRange(location: 12, length: 40)]
        for profile in profiles {
            for scope in scopes {
                let textView = NSTextView()
                textView.string = doc
                MarkdownSyntaxHighlighter().highlight(textView: textView, profile: profile, tokenScope: scope)
                let expected = NSMutableAttributedString(string: doc)
                Self.preMoveHighlight(expected, profile: profile, scope: scope ?? NSRange(location: 0, length: length))
                XCTAssertTrue(textView.textStorage!.isEqual(to: expected), "highlight differs for \(profile.themeID) scope \(String(describing: scope))")

                let refresh = NSRange(location: 15, length: 30)
                MarkdownSyntaxHighlighter().refreshTokens(textView: textView, profile: profile, scope: refresh)
                Self.preMoveRefresh(expected, profile: profile, scope: refresh)
                XCTAssertTrue(textView.textStorage!.isEqual(to: expected), "refreshTokens differs for \(profile.themeID)")
            }
        }
    }

    // The pre-move `MarkdownSyntaxHighlighter` body, frozen. Do not edit to make a change pass.
    private static func preMoveHighlight(_ storage: NSMutableAttributedString, profile: ReadingProfile, scope: NSRange) {
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(MarkdownSyntaxHighlighter.baseAttributes(for: profile), range: full)
        preMoveTokens(storage, profile: profile, scope: NSIntersectionRange(scope, full))
    }

    private static func preMoveRefresh(_ storage: NSMutableAttributedString, profile: ReadingProfile, scope: NSRange) {
        let clamped = NSIntersectionRange(scope, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return }
        storage.setAttributes(MarkdownSyntaxHighlighter.baseAttributes(for: profile), range: clamped)
        preMoveTokens(storage, profile: profile, scope: clamped)
    }

    private static func preMoveTokens(_ storage: NSMutableAttributedString, profile: ReadingProfile, scope: NSRange) {
        guard scope.length > 0 else { return }
        let text = storage.string as NSString
        let substring = text.substring(with: scope)
        for token in MarkdownRangeAnalyzer().ranges(in: substring) {
            let range = NSRange(location: token.range.location + scope.location, length: token.range.length)
            guard NSMaxRange(range) <= storage.length else { continue }
            storage.addAttributes(preMoveAttributes(for: token.kind, profile: profile), range: range)
        }
    }

    private static func preMoveAttributes(for kind: MarkdownTokenKind, profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        let markerColor = MarkdownSyntaxHighlighter.markdownMarkerColor(for: profile)
        switch kind {
        case .headingMarker, .listMarker, .checkbox, .blockquoteMarker, .linkDestination:
            return [.foregroundColor: markerColor]
        case .codeSpan, .codeFence:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular),
                .foregroundColor: MarkdownSyntaxHighlighter.inlineCodeColor(for: profile)
            ]
        case .linkText, .imageText, .imageDestination:
            return [.foregroundColor: Theme.theme(for: profile).readableInk(NSColor.linkColor)]
        }
    }

    // MARK: - Task 4: text-view wiring

    @MainActor
    func testNoScrollViewFallsBackToFullHighlight() {
        // A bare text view (no scroll view) must colorize a heading anywhere in the doc.
        let doc = String(repeating: "plain line\n", count: 300) + "# Deep heading"
        let textView = LineformTextView()
        textView.string = doc
        textView.refreshMarkdownHighlighting()

        let storage = textView.textStorage!
        let deepHash = (doc as NSString).range(of: "# Deep heading").location
        let marker = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        assertSameRGB(storage.attribute(.foregroundColor, at: deepHash, effectiveRange: nil) as! NSColor, marker)
        XCTAssertNil(textView.currentVisibleTokenScope()) // no scroll view → nil scope
    }

    // MARK: - Helper

    private func assertSameRGB(_ a: NSColor, _ b: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        let ac = a.usingColorSpace(.sRGB)!, bc = b.usingColorSpace(.sRGB)!
        XCTAssertEqual(ac.redComponent, bc.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ac.greenComponent, bc.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ac.blueComponent, bc.blueComponent, accuracy: 0.01, file: file, line: line)
    }
}

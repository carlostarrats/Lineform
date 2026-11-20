import AppKit
import LineformCore

final class MarkdownSyntaxHighlighter {
    // The static half lives in LineformCore's `MarkdownTextStyle`; these forward to it so every
    // existing call site keeps its name.
    static var lightThemeInlineCodeColor: NSColor { MarkdownTextStyle.lightThemeInlineCodeColor }
    static var darkThemeInlineCodeColor: NSColor { MarkdownTextStyle.darkThemeInlineCodeColor }
    static var lightThemeMarkdownMarkerColor: NSColor { MarkdownTextStyle.lightThemeMarkdownMarkerColor }
    static var darkThemeMarkdownMarkerColor: NSColor { MarkdownTextStyle.darkThemeMarkdownMarkerColor }

    static func inlineCodeColor(for profile: ReadingProfile) -> NSColor { MarkdownTextStyle.inlineCodeColor(for: profile) }
    static func inlineCodeColor(for theme: Theme) -> NSColor { MarkdownTextStyle.inlineCodeColor(for: theme) }
    static func markdownMarkerColor(for profile: ReadingProfile) -> NSColor { MarkdownTextStyle.markdownMarkerColor(for: profile) }
    static func markdownMarkerColor(for theme: Theme) -> NSColor { MarkdownTextStyle.markdownMarkerColor(for: theme) }

    static var baseAttributes: [NSAttributedString.Key: Any] { MarkdownTextStyle.baseAttributes }
    static func baseAttributes(for profile: ReadingProfile) -> [NSAttributedString.Key: Any] { MarkdownTextStyle.baseAttributes(for: profile) }

    static func paragraphStyle(for profile: ReadingProfile, font: NSFont, blockSpacing: CGFloat = 0) -> NSMutableParagraphStyle {
        MarkdownTextStyle.paragraphStyle(for: profile, font: font, blockSpacing: blockSpacing)
    }

    static func blockSpacingParagraphStyle(for profile: ReadingProfile, font: NSFont, additionalSpacing: CGFloat = 0) -> NSMutableParagraphStyle {
        MarkdownTextStyle.blockSpacingParagraphStyle(for: profile, font: font, additionalSpacing: additionalSpacing)
    }

    static func markdownBlockSpacingLineRanges(in text: String, includeLineTerminators: Bool = true, includeTrailingBlankBoundary: Bool = true) -> [NSRange] {
        MarkdownTextStyle.markdownBlockSpacingLineRanges(in: text, includeLineTerminators: includeLineTerminators, includeTrailingBlankBoundary: includeTrailingBlankBoundary)
    }

    static func markdownBlockSpacingLineIndexes(in text: String, includeTrailingBlankBoundary: Bool = true) -> [Int] {
        MarkdownTextStyle.markdownBlockSpacingLineIndexes(in: text, includeTrailingBlankBoundary: includeTrailingBlankBoundary)
    }

    static func markdownBlockSpacingLineIndexes(inLines lines: [String], includeTrailingBlankBoundary: Bool = true) -> [Int] {
        MarkdownTextStyle.markdownBlockSpacingLineIndexes(inLines: lines, includeTrailingBlankBoundary: includeTrailingBlankBoundary)
    }

    let analyzer = MarkdownRangeAnalyzer()

    /// `true` when `inner` is fully contained in `outer` — the "already highlighted" guard the
    /// text view uses to skip re-tokenizing on ordinary in-margin scrolls.
    static func range(_ outer: NSRange, covers inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// Full refresh: resets the WHOLE document to base attributes (uniform font / paragraph
    /// style / kern / color → stable layout everywhere) and colorizes tokens only within
    /// `tokenScope`. `tokenScope == nil` colorizes the whole document — the original behavior,
    /// used by tests and by any text view with no enclosing scroll view.
    @MainActor
    func highlight(textView: NSTextView, profile: ReadingProfile = .original, tokenScope: NSRange? = nil) {
        guard let storage = textView.textStorage else {
            return
        }

        let selectedRange = textView.selectedRange()
        let fullRange = NSRange(location: 0, length: storage.length)
        let scope = NSIntersectionRange(tokenScope ?? fullRange, fullRange)

        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes(for: profile), range: fullRange)
        applyTokenAttributes(in: storage, profile: profile, scope: scope)
        storage.endEditing()
        textView.setSelectedRange(selectedRange)
    }

    /// Incremental token pass: resets ONLY `scope` to base (clearing stale token colors there)
    /// and re-applies tokens within it. Does not touch the rest of the document — base is already
    /// whole-document from the last `highlight`, and edits preserve attributes. Used on the
    /// typing pause and on scroll-settle so the per-pass cost is bounded to the visible window.
    @MainActor
    func refreshTokens(textView: NSTextView, profile: ReadingProfile, scope: NSRange) {
        guard let storage = textView.textStorage else {
            return
        }

        let clamped = NSIntersectionRange(scope, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else {
            return
        }

        let selectedRange = textView.selectedRange()

        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes(for: profile), range: clamped)
        applyTokenAttributes(in: storage, profile: profile, scope: clamped)
        storage.endEditing()
        textView.setSelectedRange(selectedRange)
    }

    private func applyTokenAttributes(in storage: NSTextStorage, profile: ReadingProfile, scope: NSRange) {
        guard scope.length > 0 else { return }
        for token in tokens(in: storage.string as NSString, scope: scope) where NSMaxRange(token.range) <= storage.length {
            storage.addAttributes(attributes(for: token.kind, profile: profile), range: token.range)
        }
    }

    private func attributes(for kind: MarkdownTokenKind, profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        let markerColor = Self.markdownMarkerColor(for: profile)
        let mutedColor = markerColor

        switch kind {
        case .headingMarker:
            return [.foregroundColor: markerColor]
        case .listMarker, .checkbox, .blockquoteMarker:
            return [.foregroundColor: mutedColor]
        case .codeSpan, .codeFence:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular),
                .foregroundColor: Self.inlineCodeColor(for: profile)
            ]
        case .linkText:
            // Through the theme's contrast floor: `NSColor.linkColor` is the system blue and was
            // the one reader ink not derived from the theme, so nothing put it under the contrast
            // gate — it reads 3.70:1 on Quiet, below AA.
            return [.foregroundColor: Theme.theme(for: profile).readableInk(NSColor.linkColor)]
        case .linkDestination:
            return [.foregroundColor: markerColor]
        case .imageText, .imageDestination:
            // Image links read in link blue (both alt and path) so they're easy to spot as
            // references — unlike ordinary links, the path is colored too, since image links
            // often have an empty alt (`![](path)`) and the path is the only visible content.
            return [.foregroundColor: Theme.theme(for: profile).readableInk(NSColor.linkColor)]
        }
    }
}

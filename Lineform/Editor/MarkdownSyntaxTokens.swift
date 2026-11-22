import Foundation
import LineformCore

// Token scoping lives in LineformCore's `MarkdownTokenScope` (shared with the iPhone editor).
// These keep the Mac's names as one-line forwarders.
extension MarkdownSyntaxHighlighter {
    /// Forwards to `MarkdownTokenScope.scopedTokenRange(in:around:margin:)`.
    static func scopedTokenRange(visibleRange: NSRange, margin: Int, in text: NSString) -> NSRange {
        MarkdownTokenScope.scopedTokenRange(in: text, around: visibleRange, margin: margin)
    }

    /// Forwards to `MarkdownTokenScope.tokens(in:scope:)`.
    func tokens(in text: NSString, scope: NSRange) -> [MarkdownTokenRange] {
        MarkdownTokenScope.tokens(in: text, scope: scope)
    }
}

// `checkableRanges` lives in LineformCore's `MarkdownSpellCheckRegions`; this keeps the Mac
// text view's call, which passes its highlighter, compiling unchanged.
extension MarkdownSpellCheckRegions {
    static func checkableRanges(in text: NSString, enclosing range: NSRange, highlighter: MarkdownSyntaxHighlighter) -> [NSRange] {
        checkableRanges(in: text, enclosing: range)
    }
}

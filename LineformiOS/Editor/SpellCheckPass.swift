import LineformCore
import UIKit

/// The iPhone's spell check: `UITextChecker` over the prose of the visible window only.
///
/// The system checker is off (`spellCheckingType = .no`), because it cannot be told to skip
/// Markdown: it would flag fenced code, inline code, front matter, math and link destinations.
/// This pass runs instead, on the main actor, over `MarkdownSpellCheckRegions.checkableRanges` of
/// the visible range plus `margin`, snapped to whole lines.
///
/// - **Scoped.** It never looks past the window, and it never calls a whole-document pass
///   (`MarkdownWritingToolsProtection.ignoredRanges`, `MarkdownRangeAnalyzer.ranges(in:)`): the
///   regions are scoped by construction. `SpellCheckTests.testSpellPassIsScopedRatio` guards it.
/// - **Per document.** Each editor owns one pass and one `UITextChecker`, so Ignore Spelling
///   (`ignoreWord`) lasts for this document only; Learn Spelling is the system's, for every one.
/// - The editor schedules it (`LineformiOSTextView+SpellCheck.swift`): `typingDelay` after the
///   last edit, after a scroll, and never while an input method is composing.
@MainActor
final class SpellCheckPass {
    /// The pause after the last edit, or a scroll, before the window is checked again.
    static let typingDelay: TimeInterval = 0.4
    /// Characters checked on each side of the visible range.
    static let margin = 2_000
    /// Suggestions offered in the edit menu.
    static let maximumGuesses = 5

    /// This document's checker: `ignoreWord` is remembered on it.
    let checker = UITextChecker()
    /// The misspellings of the last pass, in text-storage coordinates, kept current across edits
    /// by `textDidChange(editedRange:changeInLength:)`.
    var misspelledRanges: [NSRange] = []

    /// The misspelled words in the prose of `visible` plus `margin` (snapped to whole lines),
    /// in document order.
    static func misspelledRanges(in text: String, visible: NSRange, language: String, checker: UITextChecker) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let clamped = NSIntersectionRange(visible, NSRange(location: 0, length: ns.length))
        let window = MarkdownTokenScope.scopedTokenRange(
            in: ns,
            around: NSRange(location: clamped.location, length: clamped.length),
            margin: margin
        )
        var found: [NSRange] = []
        for region in MarkdownSpellCheckRegions.checkableRanges(in: ns, enclosing: window) {
            var start = region.location
            while start < NSMaxRange(region) {
                let word = checker.rangeOfMisspelledWord(
                    in: text, range: region, startingAt: start, wrap: false, language: language
                )
                guard word.location != NSNotFound, word.length > 0, word.location >= start else { break }
                found.append(word)
                start = NSMaxRange(word)
            }
        }
        return found
    }

    /// The checker language for `primary` (the keyboard's `textInputMode?.primaryLanguage`); when
    /// there is none, or `UITextChecker` has no dictionary for it (the emoji keyboard's "emoji"),
    /// the first preferred language that has one. Nil when none does: then nothing is checked.
    static func language(
        primary: String?,
        preferred: [String] = Locale.preferredLanguages,
        available: [String] = UITextChecker.availableLanguages
    ) -> String? {
        let candidates = (primary.map { [$0] } ?? []) + preferred
        return candidates.lazy.compactMap { dictionary(for: $0, available: available) }.first
    }

    /// The `UITextChecker` dictionary for one language tag: "en_US" for "en-US"; else the bare
    /// language, or its first regional dictionary. Nil when there is none.
    private static func dictionary(for wanted: String, available: [String]) -> String? {
        let normalized = wanted.replacingOccurrences(of: "-", with: "_")
        if available.contains(normalized) { return normalized }
        let parts = normalized.split(separator: "_")
        guard let code = parts.first.map(String.init) else { return nil }
        if parts.count > 1, let region = parts.last, available.contains("\(code)_\(region)") { return "\(code)_\(region)" }
        if available.contains(code) { return code }
        return available.first { $0.hasPrefix(code + "_") }
    }

    /// Keeps the ranges in step with an edit: a range wholly before the edit stays, one wholly
    /// after it shifts by `delta`, and one the edit touches (overlaps or abuts) is dropped until
    /// the next pass re-checks it.
    func textDidChange(editedRange: NSRange, changeInLength delta: Int) {
        guard !misspelledRanges.isEmpty else { return }
        let oldEdited = NSRange(location: editedRange.location, length: max(0, editedRange.length - delta))
        misspelledRanges = misspelledRanges.compactMap { range in
            if NSMaxRange(range) < oldEdited.location { return range }
            if range.location > NSMaxRange(oldEdited) { return NSRange(location: range.location + delta, length: range.length) }
            return nil
        }
    }

    /// The misspelled range at `range` (a caret inside or at either end of a word, or a selection
    /// that overlaps one), if any.
    func misspelledRange(at range: NSRange) -> NSRange? {
        misspelledRanges.first { word in
            if range.length == 0 {
                return range.location >= word.location && range.location <= NSMaxRange(word)
            }
            return NSIntersectionRange(word, range).length > 0
        }
    }

    /// Drops every underline on `word`, after Learn or Ignore.
    func forget(_ word: String, in text: NSString) {
        misspelledRanges.removeAll { NSMaxRange($0) <= text.length && text.substring(with: $0) == word }
    }
}

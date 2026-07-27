import Foundation

/// Decides what a Return keypress should do on a Markdown list-like line: continue the
/// construct, end it, or stay out of the way.
///
/// Pure over `(text, selectedRange)` — no AppKit, no view state — so the entire decision
/// surface is testable without an object graph or a window. `LineformTextView.insertNewline`
/// is the only caller.
///
/// Deliberately NOT handled here: indent/outdent (Tab is untouched) and renumbering the
/// remainder of an ordered list. Ordered items increment only; GFM renders `1. 2. 2.` as
/// 1, 2, 3, so the cost of not renumbering is confined to the source text, whereas a
/// multi-line renumber would have to stay one undo step and hold the caret still.
enum MarkdownListContinuation {
    enum Outcome: Equatable {
        /// Replace the current selection with this string, e.g. `"\n- "` or `"\n4. "`.
        case `continue`(insertion: String)
        /// The writer pressed Return on a marker they never filled in: replace this range
        /// with `""`, leaving a blank line and ending the construct.
        case terminate(clearing: NSRange)
    }

    /// `nil` means "not a continuable line" — the text view should insert an ordinary newline.
    static func outcome(for text: String, selectedRange: NSRange) -> Outcome? {
        let nsText = text as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              NSMaxRange(selectedRange) <= nsText.length else {
            return nil
        }

        let lineRange = lineRangeExcludingTerminator(in: nsText, at: selectedRange.location)
        guard lineRange.length > 0 else {
            return nil
        }

        let line = nsText.substring(with: lineRange)
        guard let prefix = LinePrefix(line: line) else {
            return nil
        }

        // A caret at or before the end of the marker means the writer is pushing the line
        // down, not adding to the list. `‸- milk` + Return is a blank line above the bullet.
        guard selectedRange.location >= lineRange.location + prefix.length else {
            return nil
        }

        // Only now, after a cheap line-local match has already succeeded, pay for the
        // whole-document scan. Returns on ordinary prose never reach this.
        guard !isProtected(text: text, location: lineRange.location) else {
            return nil
        }

        let content = (line as NSString).substring(from: prefix.length)
        if selectedRange.length == 0, content.trimmingCharacters(in: .whitespaces).isEmpty {
            return .terminate(clearing: lineRange)
        }

        // Match the surrounding text's line ending, so continuing a list in a CRLF file does not
        // leave a stray LF line in it.
        let ending = MarkdownLineEnding.inForce(at: lineRange.location, in: nsText)
        return .continue(insertion: ending.text + prefix.continuation)
    }

    /// `NSString.lineRange(for:)` includes the trailing newline; the parser wants the line's
    /// own text so that `prefix.length` and the content test are measured against it.
    private static func lineRangeExcludingTerminator(in nsText: NSString, at location: Int) -> NSRange {
        let paragraph = nsText.lineRange(for: NSRange(location: location, length: 0))
        var end = NSMaxRange(paragraph)
        while end > paragraph.location {
            let character = nsText.substring(with: NSRange(location: end - 1, length: 1))
            guard character == "\n" || character == "\r" else { break }
            end -= 1
        }
        return NSRange(location: paragraph.location, length: end - paragraph.location)
    }

    /// Fenced code and YAML front matter are not prose — `- foo` inside them is code.
    /// `MarkdownRangeAnalyzer` cannot answer this: it is strictly line-local by invariant, so
    /// it cannot see a fence opened on an earlier line. `MarkdownWritingToolsProtection` owns
    /// the fence rules and exposes a per-Return-cheap check for exactly this question.
    private static func isProtected(text: String, location: Int) -> Bool {
        MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: location, in: text)
    }
}

/// The marker layers at the head of a line — indentation, blockquote arrows, and an optional
/// list marker — together with what the *next* line should start with.
///
/// Also used by `MarkdownHeadingEditing` to recognise the lines a heading command must leave
/// alone — one definition of "what markers start a line", rather than two that can drift.
struct LinePrefix {
    /// NSString length of the matched prefix, measured within the line.
    let length: Int
    /// What to emit after the newline, e.g. `"    > - [ ] "`.
    let continuation: String

    init?(line: String) {
        let ns = line as NSString
        var cursor = 0

        let indentEnd = LinePrefix.scanWhitespace(ns, from: 0)
        let indent = ns.substring(with: NSRange(location: 0, length: indentEnd))
        cursor = indentEnd

        var quote = ""
        while cursor < ns.length, ns.character(at: cursor) == UInt16(UnicodeScalar(">").value) {
            cursor += 1
            quote += ">"
            if cursor < ns.length, ns.character(at: cursor) == UInt16(UnicodeScalar(" ").value) {
                cursor += 1
                quote += " "
            }
        }

        var marker = ""
        if let bullet = LinePrefix.scanBullet(ns, from: cursor) {
            cursor = bullet.end
            marker = bullet.continuation
        } else if let ordered = LinePrefix.scanOrdered(ns, from: cursor) {
            cursor = ordered.end
            marker = ordered.continuation
        }

        guard !quote.isEmpty || !marker.isEmpty else {
            return nil
        }

        length = cursor
        continuation = indent + quote + marker
    }

    private static func scanWhitespace(_ ns: NSString, from start: Int) -> Int {
        var cursor = start
        while cursor < ns.length {
            let character = ns.character(at: cursor)
            guard character == UInt16(UnicodeScalar(" ").value) || character == UInt16(UnicodeScalar("\t").value) else {
                break
            }
            cursor += 1
        }
        return cursor
    }

    /// `- item`, `* item`, `+ item`, and their checkbox forms. The bullet character is
    /// preserved so a file written with `*` stays internally consistent.
    ///
    /// The trailing space (or end of line) is required: it is what separates a bullet from
    /// a `---` horizontal rule or a `-word` fragment.
    private static func scanBullet(_ ns: NSString, from start: Int) -> (end: Int, continuation: String)? {
        guard start < ns.length else { return nil }
        let bullet = ns.substring(with: NSRange(location: start, length: 1))
        guard bullet == "-" || bullet == "*" || bullet == "+" else { return nil }

        var cursor = start + 1
        if cursor < ns.length {
            guard ns.character(at: cursor) == UInt16(UnicodeScalar(" ").value) else { return nil }
            cursor += 1
        }

        // A new task item is always unchecked. Inheriting `[x]` would silently mark work done.
        if let checkboxEnd = scanCheckbox(ns, from: cursor) {
            return (checkboxEnd, bullet + " [ ] ")
        }

        return (cursor, bullet + " ")
    }

    private static func scanCheckbox(_ ns: NSString, from start: Int) -> Int? {
        guard start + 3 <= ns.length else { return nil }
        guard ns.substring(with: NSRange(location: start, length: 1)) == "[" else { return nil }
        let mark = ns.substring(with: NSRange(location: start + 1, length: 1))
        guard mark == " " || mark.lowercased() == "x" else { return nil }
        guard ns.substring(with: NSRange(location: start + 2, length: 1)) == "]" else { return nil }

        var cursor = start + 3
        if cursor < ns.length, ns.character(at: cursor) == UInt16(UnicodeScalar(" ").value) {
            cursor += 1
        }
        return cursor
    }

    /// `1. item` and `1) item`. Increments only — see the type comment. The separator the
    /// line already uses is preserved.
    private static func scanOrdered(_ ns: NSString, from start: Int) -> (end: Int, continuation: String)? {
        var cursor = start
        var digits = ""
        while cursor < ns.length {
            let character = ns.substring(with: NSRange(location: cursor, length: 1))
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1,
                  CharacterSet.decimalDigits.contains(scalar) else {
                break
            }
            digits += character
            cursor += 1
        }

        guard !digits.isEmpty, let number = Int(digits), cursor < ns.length else { return nil }

        let separator = ns.substring(with: NSRange(location: cursor, length: 1))
        guard separator == "." || separator == ")" else { return nil }
        cursor += 1

        if cursor < ns.length {
            guard ns.character(at: cursor) == UInt16(UnicodeScalar(" ").value) else { return nil }
            cursor += 1
        }

        return (cursor, "\(number + 1)\(separator) ")
    }
}

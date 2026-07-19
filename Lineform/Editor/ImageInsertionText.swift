import Foundation

/// Pure text transforms for inserting an own-line `![](path)` image link, extracted from
/// `LineformTextView+ImageInsertion` so the placement rules — which the drag/drop geometry chooses
/// between — are unit-testable without a hosted `NSTextView`. Each transform returns a minimal
/// zero-length `Edit` (location + snippet), so the caller can apply it through the
/// `shouldChangeText → replaceCharacters → didChangeText` path (undo + document-binding sync)
/// exactly as before.
enum ImageInsertionText {

    /// A single-point insertion: insert `snippet` at `location` (a zero-length range).
    struct Edit: Equatable {
        let location: Int
        let snippet: String

        /// Caret offset after the insertion (end of the inserted snippet).
        var caret: Int { location + (snippet as NSString).length }

        /// The document text after applying this edit — for tests and callers wanting the result.
        func applied(to text: String) -> String {
            (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: snippet)
        }
    }

    /// Insert the image on its own line at the START of the line containing `index` (a paragraph
    /// boundary), pushing the existing line down. This is the drop-on-a-line / paste behavior — the
    /// image lands BETWEEN whole lines and never splits a word.
    static func insertingOnLine(into text: String, at index: Int, path: String) -> Edit {
        let ns = text as NSString
        let clamped = max(0, min(index, ns.length))
        let lineStart = ns.lineRange(for: NSRange(location: clamped, length: 0)).location
        return Edit(location: lineStart, snippet: "![](\(path))\n")
    }

    /// Append the image on its OWN new line at the END of the document — the "dropped below the last
    /// line" case, which must land AFTER a trailing image/line rather than snapping to its start
    /// (the bug this fixes). A leading newline is added only when the document isn't already
    /// newline-terminated, so the image always starts a fresh line without doubling blank lines.
    static func appendingAtEnd(into text: String, path: String) -> Edit {
        let ns = text as NSString
        let end = ns.length
        let endsWithNewline = end > 0 && ns.substring(with: NSRange(location: end - 1, length: 1)) == "\n"
        let leading = (end > 0 && !endsWithNewline) ? "\n" : ""
        return Edit(location: end, snippet: "\(leading)![](\(path))\n")
    }
}

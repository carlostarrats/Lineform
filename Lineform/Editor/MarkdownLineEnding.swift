import Foundation

/// The line ending an edit should insert, read from the text around the insertion point.
///
/// Lineform never normalises a document's line endings — rewriting them would change lines the
/// writer never touched and produce a whole-file Git diff, which is the opposite of the real-files
/// thesis. But every insertion path used to emit a bare `\n`, so a Windows-authored file gained LF
/// lines wherever it was edited and ended up MIXED. Matching the surrounding text keeps a CRLF file
/// CRLF and an LF file LF, without ever rewriting what is already there.
///
/// **Local, not a whole-document tally.** This runs on every Return, so it may not scan the
/// document: a per-keystroke whole-document pass is the mistake `MarkdownSpellCheckRegions` and
/// `MarkdownListContinuation` were both built to avoid. Reading the terminator of the line the
/// caret is on costs one line's length, and in a file with mixed endings it also gives the better
/// answer — continue the convention of the text you are actually writing in.
enum MarkdownLineEnding: String, Equatable {
    case lf = "\n"
    case crlf = "\r\n"

    var text: String { rawValue }

    /// UTF-16 length of the terminator, for callers positioning a caret past one.
    var length: Int { self == .crlf ? 2 : 1 }

    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let carriageReturn = UInt16(UnicodeScalar("\r").value)

    /// The ending in force at `location`: the terminator of the line the caret sits on, or — when
    /// that is the last line and has none — the terminator of the line before it. An empty or
    /// single-line document has no evidence either way and answers `.lf`, which is what a new
    /// document should use.
    static func inForce(at location: Int, in text: NSString) -> MarkdownLineEnding {
        let clamped = min(max(location, 0), text.length)

        var index = clamped
        while index < text.length {
            if text.character(at: index) == newline {
                return ending(endingAtNewline: index, in: text)
            }
            index += 1
        }

        index = clamped
        while index > 0 {
            index -= 1
            if text.character(at: index) == newline {
                return ending(endingAtNewline: index, in: text)
            }
        }

        return .lf
    }

    /// Convenience for the pure transforms, which hold a `String` already.
    static func inForce(at location: Int, in text: String) -> MarkdownLineEnding {
        inForce(at: location, in: text as NSString)
    }

    private static func ending(endingAtNewline index: Int, in text: NSString) -> MarkdownLineEnding {
        index > 0 && text.character(at: index - 1) == carriageReturn ? .crlf : .lf
    }
}

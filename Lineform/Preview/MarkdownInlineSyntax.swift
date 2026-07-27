import Foundation

/// The one definition of Lineform's inline markdown syntax, shared by every emitter that scans a
/// line for it: `MarkdownPreviewRenderer` (attributed string, for Read/Preview/PDF/RTF) and
/// `MarkdownHTMLRenderer` (HTML export).
///
/// These lived as private constants on the preview renderer until HTML export needed the same six
/// patterns. Copying them would mean a construct added to one emitter silently not existing in the
/// other — the exported file quietly disagreeing with what the app shows on screen. Capture group 1
/// is always the display text; group 2, where present, is the destination.
/// Every opener carries `(?<!\\)` so a backslash-escaped marker does not open a construct, and
/// `unescape(_:)` removes that backslash from the text the reader sees. The two halves are one
/// feature: without the lookbehind, `` \`not code\` `` opened a code span and ATE the backticks;
/// without the unescape, declining to open the construct left a bare `\*` on screen, so the only
/// way to write a literal `*` looked wrong. The Quick Look appex — which cannot import this file
/// — has always done both, so Finder was rendering these lines correctly while the app was not.
enum MarkdownInlineSyntax {
    static let bold = try! NSRegularExpression(pattern: #"(?<!\\)\*\*([^*\n]+)\*\*"#)

    /// Underscore italics, but NEVER inside a word. `_([^_\n]+)_` on its own turned
    /// `make_test_file` into "make" + italic "test" + "file" — the underscores eaten and the word
    /// silently mangled — everywhere the app draws text, plus HTML/PDF/RTF export and read-aloud.
    /// Prose about code is full of `snake_case`, so this fired constantly. CommonMark forbids
    /// intraword `_` emphasis for exactly this reason. `\w` covers the `_` itself, so `__init__`
    /// (a dunder, not bold) is left alone too.
    static let italic = try! NSRegularExpression(pattern: #"(?<![\w\\])_([^_\n]+)_(?![\w])"#)

    /// Asterisk italics. Intraword `*` IS legal — `*` has no snake_case problem — but a `*`
    /// flanked by whitespace is arithmetic or a footnote mark, so the content may not begin or
    /// end with a space. Without that guard `2 * 3 * 4` would italicise the 3.
    /// `**bold**` still wins: it matches one character earlier, and the earliest match takes the line.
    static let italicAsterisk = try! NSRegularExpression(pattern: #"(?<!\\)\*([^*\s\n](?:[^*\n]*[^*\s\n])?)\*"#)
    static let code = try! NSRegularExpression(pattern: #"(?<!\\)`([^`\n]+)`"#)
    static let strikethrough = try! NSRegularExpression(pattern: #"(?<!\\)~~([^~\n]+)~~"#)
    /// Group 1 is the alt text (may be empty), group 2 the path — emitted verbatim by HTML export.
    static let image = try! NSRegularExpression(pattern: #"(?<!\\)!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)
    /// Group 1 is the link text, group 2 the destination.
    static let link = try! NSRegularExpression(pattern: #"(?<!\\)\[([^\]\n]+)\]\(([^\)\n]+)\)"#)

    /// The markers a backslash may escape — exactly the ones the patterns above consume, so an
    /// escape never removes a backslash that meant something else (a Windows path, a regex in
    /// prose). Mirrors the appex's `unescapeInline`.
    private static let escapedMarker = try! NSRegularExpression(pattern: #"\\([*_`~\[\]()!\\])"#)

    /// Drops the backslash from an escaped marker. Applied ONLY to the plain runs between tokens:
    /// a code span's contents are literal by definition (CommonMark does not process escapes
    /// inside one), and a link or image DESTINATION is emitted one-to-one and must never be
    /// rewritten.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        let ns = text as NSString
        return escapedMarker.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "$1"
        )
    }
}

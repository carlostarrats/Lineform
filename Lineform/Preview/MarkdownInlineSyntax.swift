import Foundation

/// The one definition of Lineform's inline markdown syntax, shared by every emitter that scans a
/// line for it: `MarkdownPreviewRenderer` (attributed string, for Read/Preview/PDF/RTF) and
/// `MarkdownHTMLRenderer` (HTML export).
///
/// These lived as private constants on the preview renderer until HTML export needed the same six
/// patterns. Copying them would mean a construct added to one emitter silently not existing in the
/// other — the exported file quietly disagreeing with what the app shows on screen. Capture group 1
/// is always the display text; group 2, where present, is the destination.
enum MarkdownInlineSyntax {
    static let bold = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    static let italic = try! NSRegularExpression(pattern: #"_([^_\n]+)_"#)
    static let code = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    static let strikethrough = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    /// Group 1 is the alt text (may be empty), group 2 the path — emitted verbatim by HTML export.
    static let image = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)
    /// Group 1 is the link text, group 2 the destination.
    static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#)
}

import Foundation

/// Pure helpers for the Reconnect affordance on a broken/unresolved image placeholder: rewriting
/// `![alt](old)` -> `![alt](new)` at a known source range, and choosing whether the new link should
/// be written relative to the document's folder or as an absolute path. No file I/O, no network.
enum ImageLinkRewrite {
    /// Matches a single `![alt](path)` image reference, tolerating leading/trailing whitespace
    /// (mirrors the whitespace the placeholder's source range spans around the syntax itself).
    /// Re-declared here rather than reaching into `MarkdownPreviewRenderer`'s private `imageRegex`
    /// (same character classes: alt excludes `]`/newline, path excludes `)`/newline).
    private static let wholeImageRegex = try! NSRegularExpression(
        pattern: #"^(\s*)!\[([^\]\n]*)\]\(([^\)\n]+)\)(\s*)$"#
    )

    /// Rewrite the image reference spanning `range` in `text` to point at `newPath`, preserving the
    /// original alt text and any surrounding whitespace. Returns the new full text, or nil when
    /// `range` is out of bounds or no longer spans a single `![…](…)` image (a stale range after an
    /// external edit) — same discipline as `CheckboxToggle.toggledText`.
    static func rewritten(in text: String, at range: NSRange, newPath: String) -> String? {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
        let slice = ns.substring(with: range)
        let sliceNS = slice as NSString
        guard let match = wholeImageRegex.firstMatch(
            in: slice,
            range: NSRange(location: 0, length: sliceNS.length)
        ), match.numberOfRanges == 5 else {
            return nil
        }

        let leading = sliceNS.substring(with: match.range(at: 1))
        let alt = sliceNS.substring(with: match.range(at: 2))
        let trailing = sliceNS.substring(with: match.range(at: 4))

        let rebuilt = "\(leading)![\(alt)](\(newPath))\(trailing)"
        return ns.replacingCharacters(in: range, with: rebuilt)
    }

    /// The link path to write: a path RELATIVE to `documentDirectory` when `pickedFile` is within
    /// (under) that directory, otherwise the absolute path. Nil `documentDirectory` -> absolute.
    /// Only a direct under-the-dir relative or an absolute path is produced — never a `../` escape.
    static func linkPath(for pickedFile: URL, documentDirectory: URL?) -> String {
        let pickedPath = pickedFile.standardizedFileURL.path
        guard let documentDirectory else { return markdownDestination(for: pickedPath) }
        let dirPath = documentDirectory.standardizedFileURL.path
        let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
        guard pickedPath.hasPrefix(prefix) else { return markdownDestination(for: pickedPath) }
        return markdownDestination(for: String(pickedPath.dropFirst(prefix.count)))
    }

    /// A filesystem path made safe to write inside `![](…)`.
    ///
    /// Only the characters that END the destination are escaped — a bare `)` closes it, and a
    /// newline ends the line — because `MarkdownInlineSyntax.image` reads the destination as
    /// `[^\)\n]+`. `photo (1).png`, which is what every browser download is named, produced
    /// `![](photo (1).png)`: a link the app had just written and could no longer parse, so
    /// Reconnect left the placeholder permanently broken. Spaces are deliberately NOT escaped —
    /// they parse fine and stay readable in the source. `ImageResolver` decodes these back when
    /// it looks the file up.
    static func markdownDestination(for path: String) -> String {
        var result = ""
        for character in path {
            switch character {
            case "(": result += "%28"
            case ")": result += "%29"
            case "\n": result += "%0A"
            case "\r": result += "%0D"
            default: result.append(character)
            }
        }
        return result
    }
}

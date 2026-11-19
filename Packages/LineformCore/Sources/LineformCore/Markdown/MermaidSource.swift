import Foundation

/// Fence info-string detection for the preview renderer.
public enum MermaidFence {
    /// True when a trimmed fence line opens a mermaid block (```mermaid or ~~~mermaid).
    static func isMermaidOpening(_ trimmedLine: String) -> Bool {
        let marker: String
        if trimmedLine.hasPrefix("```") { marker = "```" }
        else if trimmedLine.hasPrefix("~~~") { marker = "~~~" }
        else { return false }
        let info = trimmedLine.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).lowercased()
        return info == "mermaid"
    }

    /// True when a trimmed line is any closing/opening fence delimiter.
    static func isFenceDelimiter(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
    }

    /// The opening-fence marker (delimiter character + run length) for a trimmed line, or nil if it
    /// isn't a fence opener. A fence run is 3+ of the same `` ` `` or `~`.
    public static func openingMarker(_ trimmedLine: String) -> (character: Character, length: Int)? {
        guard let first = trimmedLine.first, first == "`" || first == "~" else { return nil }
        let length = trimmedLine.prefix { $0 == first }.count
        return length >= 3 ? (first, length) : nil
    }

    /// True when a trimmed line closes a fence opened by `marker`, per CommonMark: the same
    /// delimiter character, a run at least as long as the opener's, and nothing but whitespace after
    /// the run. This is what stops a ```` ``` ```` block from being truncated by an inner `~~~` line
    /// (or vice-versa), and stops a code line like `x = "~~~"` from closing a code block.
    public static func isClosingFence(_ trimmedLine: String, matching marker: (character: Character, length: Int)) -> Bool {
        let run = trimmedLine.prefix { $0 == marker.character }
        guard run.count >= marker.length else { return false }
        return trimmedLine.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

/// The ONE definition of "what part of a mermaid block is the diagram".
///
/// A leading `---`/`---` front-matter block (Mermaid's own `title:`/`config:` header, which most
/// generators emit) and `%%` comments are not diagram source. This was implemented separately in
/// `MermaidTypeClassifier` and in `MermaidPieChart`, and — critically — NOT at the seam where the
/// source is handed to BeautifulMermaid, whose parser reads `"---"` as the first line and throws
/// `invalidHeader("---")`. So a front-matter diagram classified `.supported`, failed, and took the
/// `.failed` path: no diagram, just the captioned source,
/// and 2,000 characters of it written to the on-disk diagram log — the path reserved for genuine
/// library bugs. Every consumer reads this type so the four can't disagree again.
public enum MermaidSource {
    /// Lines with blanks, `%%` comments, and a leading front-matter block removed.
    static func significantLines(_ source: String) -> [String] {
        var out: [String] = []
        forEachBodyLine(source) { line in
            if !line.hasPrefix("%%") { out.append(line) }
        }
        return out
    }

    /// First line that is actual diagram source, or nil.
    static func firstSignificantLine(_ source: String) -> String? {
        significantLines(source).first
    }

    /// `source` with a leading `---`/`---` front-matter block removed and everything else kept
    /// verbatim. This is what BeautifulMermaid is given; the front matter carries only config and
    /// title, which Lineform's strict two-color theme ignores anyway.
    public static func withoutFrontMatter(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let openIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[openIndex].trimmingCharacters(in: .whitespaces) == "---",
              let closeIndex = lines[(openIndex + 1)...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return source }
        return lines[(closeIndex + 1)...].joined(separator: "\n")
    }

    /// Walks the trimmed, non-blank lines that sit outside a leading front-matter block.
    private static func forEachBodyLine(_ source: String, _ body: (String) -> Void) {
        var inFrontMatter = false
        var seenFirstLine = false
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { seenFirstLine = true; continue }
            if !seenFirstLine, line == "---" { inFrontMatter = true; seenFirstLine = true; continue }
            seenFirstLine = true
            if inFrontMatter {
                if line == "---" { inFrontMatter = false }
                continue
            }
            body(line)
        }
    }
}

/// Decides whether a mermaid block is safe to attempt rendering (size guard → fallback).
public enum MermaidBlockPolicy {
    /// Character cap. Cheap, but it bounds only the SOURCE — see `maxSignificantLines`.
    static let maxSourceLength = 20_000

    /// Structural cap, and the one that actually bounds the work. BeautifulMermaid's cost grows
    /// with node count, and its raster area grows roughly quadratically with layout width, so a
    /// 3 KB / 200-node flowchart — one seventh of the character cap — renders for ~1 s on the MAIN
    /// THREAD into a ~392 MB bitmap that instantly exceeds the diagram cache's whole budget and is
    /// evicted, so every keystroke in Split mode pays the full cost again. At 600 nodes it is 22 s
    /// and multi-gigabyte. A real diagram is readable at a fraction of this.
    static let maxSignificantLines = 120

    public static func shouldAttemptRender(source: String) -> Bool {
        guard source.count <= maxSourceLength else { return false }
        return MermaidSource.significantLines(source).count <= maxSignificantLines
    }
}

/// Which renderer, if any, handles a mermaid block.
public enum MermaidDiagramKind: Equatable {
    case supported     // BeautifulMermaid renders it
    case pie           // Lineform renders it natively (MermaidPieChart)
    case unsupported   // recognized-but-unrenderable → clean captioned fallback
}

/// Classifies a mermaid block by its declared type WITHOUT invoking BeautifulMermaid.
///
/// BeautifulMermaid 1.0.4's `Parser.parse` matches a fixed prefix set and DEFAULTS everything
/// else to flowchart, so an unsupported type (pie/gantt/mindmap/…) is silently mis-drawn as a
/// garbage flowchart instead of degrading to our clean fallback. This mirrors that parser's
/// supported prefixes exactly. If the BeautifulMermaid pin is bumped, re-check its parser and
/// update this list (same discipline as the orientation-flip note above).
public enum MermaidTypeClassifier {
    /// Prefixes BeautifulMermaid 1.0.4 actually renders (lowercased, matched on the first line).
    private static let supportedPrefixes = [
        "sequencediagram", "classdiagram", "erdiagram", "xychart", "statediagram",
        "flowchart", "graph"
    ]

    public static func classify(_ source: String) -> MermaidDiagramKind {
        guard let first = MermaidSource.firstSignificantLine(source) else { return .unsupported }
        let lower = first.lowercased()
        if lower.hasPrefix("pie") { return .pie }
        if supportedPrefixes.contains(where: { lower.hasPrefix($0) }) { return .supported }
        return .unsupported
    }
}

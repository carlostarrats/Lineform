import Foundation

enum MarkdownWritingToolsProtection {
    static func ignoredRanges(in text: String, enclosingRange: NSRange) -> [NSRange] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let safeEnclosingRange = NSIntersectionRange(enclosingRange, fullRange)
        guard safeEnclosingRange.length > 0 else {
            return []
        }

        return protectedRanges(in: text)
            .map { NSIntersectionRange($0, safeEnclosingRange) }
            .filter { $0.length > 0 }
    }

    /// Whether `location` sits inside fenced code or YAML front matter — the two regions where
    /// a line that looks like Markdown is not Markdown.
    ///
    /// Deliberately separate from `ignoredRanges`, which computes EVERY protected region in the
    /// whole document — including a per-line regex pass for inline math — and measured 18 ms on
    /// a 730 KB file. That is fine for a Writing Tools session and far too slow for a check that
    /// runs on every Return. This walks lines only as far as `location`, tracks fence state, and
    /// allocates one substring per line instead of splitting the document. Inline math is
    /// irrelevant here: a list marker sits at the head of a line, never inside `$…$`.
    static func isInsideCodeOrFrontMatter(location: Int, in text: String) -> Bool {
        let nsText = text as NSString
        guard location >= 0, location <= nsText.length else {
            return false
        }

        if let frontMatter = frontMatterRange(in: text), NSLocationInRange(location, frontMatter) {
            return true
        }

        var insideFence = false
        var openFenceMarker: String?
        var lineStart = 0

        while lineStart < location {
            var lineEnd = 0
            var contentsEnd = 0
            nsText.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: lineStart, length: 0)
            )

            if let marker = fenceMarker(in: nsText, lineStart: lineStart, contentsEnd: contentsEnd) {
                if insideFence, marker == openFenceMarker {
                    insideFence = false
                    openFenceMarker = nil
                } else if !insideFence {
                    insideFence = true
                    openFenceMarker = marker
                }
            }

            guard lineEnd > lineStart else { break }
            lineStart = lineEnd
        }

        return insideFence
    }

    /// The ``` or ~~~ delimiter a line opens or closes with, or `nil`. Reads UTF-16 units
    /// directly so the overwhelming majority of lines — ordinary prose — are rejected on their
    /// first non-blank character without allocating a substring.
    private static func fenceMarker(in nsText: NSString, lineStart: Int, contentsEnd: Int) -> String? {
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        let backtick = UInt16(UnicodeScalar("`").value)
        let tilde = UInt16(UnicodeScalar("~").value)

        var index = lineStart
        while index < contentsEnd {
            let character = nsText.character(at: index)
            guard character == space || character == tab else { break }
            index += 1
        }

        guard contentsEnd - index >= 3 else { return nil }
        let first = nsText.character(at: index)
        guard first == backtick || first == tilde,
              nsText.character(at: index + 1) == first,
              nsText.character(at: index + 2) == first else {
            return nil
        }

        return first == backtick ? "```" : "~~~"
    }

    private static func protectedRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        ranges.append(contentsOf: frontMatterRange(in: text).map { [$0] } ?? [])
        ranges.append(contentsOf: fencedCodeRanges(in: text))
        ranges.append(contentsOf: mathRanges(in: text))
        return ranges
    }

    /// Block-level protected ranges (front matter, fenced code, math) intersecting `scope`,
    /// clipped to it.
    ///
    /// Load-bearing: this exists so live spell checking never pays for the whole-document
    /// `ignoredRanges` pass (18 ms at 730 KB — see the note on `isInsideCodeOrFrontMatter`).
    /// Fence and `$$`-block state depend on the document prefix, so lines before `scope` are
    /// still walked for state — but the walk stops once past `scope`, allocates no per-line
    /// array, and skips the inline-math regex for lines that end before `scope` begins.
    ///
    /// See `docs/superpowers/specs/2026-07-26-live-spell-check-design.md`.
    static func protectedRanges(in text: NSString, intersecting scope: NSRange) -> [NSRange] {
        let full = NSRange(location: 0, length: text.length)
        let clampedScope = NSIntersectionRange(scope, full)
        guard clampedScope.length > 0 else { return [] }

        let source = text as String
        let limit = NSMaxRange(clampedScope)

        var ranges: [NSRange] = []
        if let frontMatter = frontMatterRange(in: source) {
            ranges.append(frontMatter)
        }
        ranges.append(contentsOf: fencedCodeRanges(in: source, upTo: limit))
        ranges.append(contentsOf: mathRanges(in: source, upTo: limit, collectingFrom: clampedScope.location))

        return ranges
            .map { NSIntersectionRange($0, clampedScope) }
            .filter { $0.length > 0 }
    }

    /// Walks `text`'s lines splitting on `"\n"` ONLY — byte-for-byte what
    /// `components(separatedBy: "\n")` does — without allocating an array of every line up
    /// front. `body` receives the line's content (no terminator), its start offset, and its
    /// stored length (content plus terminator). Returning `false` stops the walk.
    ///
    /// Load-bearing: do NOT switch this to `lineRange(for:)`. That also breaks on `\r`,
    /// `\u{2028}`, and `\u{2029}`, which would silently change protection behavior on CRLF
    /// documents relative to the whole-document passes this shares its predicates with.
    private static func enumerateLines(
        in text: String,
        _ body: (_ line: String, _ offset: Int, _ storedLength: Int) -> Bool
    ) {
        let nsText = text as NSString
        let length = nsText.length
        var offset = 0

        while offset <= length {
            let searchRange = NSRange(location: offset, length: length - offset)
            let newline = nsText.range(of: "\n", options: [], range: searchRange)
            let isLast = newline.location == NSNotFound
            let contentLength = isLast ? length - offset : newline.location - offset
            let storedLength = contentLength + (isLast ? 0 : 1)
            let line = nsText.substring(with: NSRange(location: offset, length: contentLength))

            if !body(line, offset, storedLength) || isLast {
                return
            }
            offset += storedLength
        }
    }

    /// Ranges of LaTeX math regions — inline `$…$` and display `$$…$$` blocks — so Writing Tools
    /// does not rewrite the source, exactly as it leaves fenced code alone. Uses the same `$`
    /// rules as the renderer, so prose dollar signs ("$5") are never protected.
    /// - Parameters:
    ///   - limit: stop walking once a line ends at or past this offset. Anything still open is
    ///     closed by the end-of-text tail below, which — after the caller clips to a scope that
    ///     ends at or before `limit` — is identical to what the unbounded walk produces.
    ///   - collectingFrom: skip the per-line inline-math regex for lines that end before this
    ///     offset. Those ranges cannot intersect the caller's scope, and the regex is the
    ///     expensive part of this function.
    private static func mathRanges(in text: String, upTo limit: Int? = nil, collectingFrom: Int = 0) -> [NSRange] {
        var ranges: [NSRange] = []
        var blockStart: Int?
        var inCodeFence = false

        enumerateLines(in: text) { line, offset, storedLineLength in
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Never interpret `$`/`$$` inside a fenced code block (it is protected separately).
            // Toggle on fence delimiters only when not mid math-block.
            if blockStart == nil, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeFence.toggle()
            } else if inCodeFence {
                // Skipped: inside a fence.
            } else if let start = blockStart {
                if MathBlockFence.blockDelimiterOnly(trimmed) {
                    // Closing `$$`: protect from the opening delimiter through this line.
                    ranges.append(NSRange(location: start, length: offset + storedLineLength - start))
                    blockStart = nil
                }
                // Body lines inside a block are already covered by the enclosing range.
            } else if MathBlockFence.blockDelimiterOnly(trimmed) {
                blockStart = offset
            } else if MathBlockFence.singleLineBlock(trimmed) != nil {
                ranges.append(NSRange(location: offset, length: (line as NSString).length))
            } else if offset + storedLineLength > collectingFrom {
                ranges.append(contentsOf: MathDelimiters.inlineMathRanges(in: line, lineOffset: offset))
            }

            if let limit, offset + storedLineLength >= limit {
                return false
            }
            return true
        }

        // An unclosed `$$` block protects through end of text.
        if let start = blockStart {
            ranges.append(NSRange(location: start, length: max(0, (text as NSString).length - start)))
        }

        return ranges
    }

    private static func frontMatterRange(in text: String) -> NSRange? {
        guard text.hasPrefix("---\n") else {
            return nil
        }

        let nsText = text as NSString
        // The opening delimiter occupies positions 0...3 ("---\n"). Search from the
        // trailing newline (position 3) so a closing "\n---" that immediately follows
        // the opening — i.e. empty front matter ("---\n---") — is still detected.
        let searchRange = NSRange(location: 3, length: max(0, nsText.length - 3))
        let closingRange = nsText.range(of: "\n---", options: [], range: searchRange)
        guard closingRange.location != NSNotFound else {
            return nil
        }

        let end = min(nsText.length, closingRange.location + closingRange.length + 1)
        return NSRange(location: 0, length: end)
    }

    /// - Parameter limit: stop walking once a line ends at or past this offset. See the note on
    ///   `mathRanges(in:upTo:collectingFrom:)`.
    private static func fencedCodeRanges(in text: String, upTo limit: Int? = nil) -> [NSRange] {
        var ranges: [NSRange] = []
        var openFenceStart: Int?
        var openFenceMarker: String?

        enumerateLines(in: text) { line, offset, storedLineLength in
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))

                if let start = openFenceStart, marker == openFenceMarker {
                    ranges.append(NSRange(location: start, length: offset + storedLineLength - start))
                    openFenceStart = nil
                    openFenceMarker = nil
                } else if openFenceStart == nil {
                    openFenceStart = offset
                    openFenceMarker = marker
                }
            }

            if let limit, offset + storedLineLength >= limit {
                return false
            }
            return true
        }

        if let start = openFenceStart {
            ranges.append(NSRange(location: start, length: max(0, (text as NSString).length - start)))
        }

        return ranges
    }
}

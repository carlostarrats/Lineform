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

    /// Ranges of LaTeX math regions — inline `$…$` and display `$$…$$` blocks — so Writing Tools
    /// does not rewrite the source, exactly as it leaves fenced code alone. Uses the same `$`
    /// rules as the renderer, so prose dollar signs ("$5") are never protected.
    private static func mathRanges(in text: String) -> [NSRange] {
        let lines = text.components(separatedBy: "\n")
        var ranges: [NSRange] = []
        var offset = 0
        var blockStart: Int?
        var inCodeFence = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hasNewline = index < lines.count - 1
            let storedLineLength = (line as NSString).length + (hasNewline ? 1 : 0)

            // Never interpret `$`/`$$` inside a fenced code block (it is protected separately).
            // Toggle on fence delimiters only when not mid math-block.
            if blockStart == nil, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeFence.toggle()
                offset += storedLineLength
                continue
            }
            if inCodeFence {
                offset += storedLineLength
                continue
            }

            if let start = blockStart {
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
            } else {
                ranges.append(contentsOf: MathDelimiters.inlineMathRanges(in: line, lineOffset: offset))
            }

            offset += storedLineLength
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

    private static func fencedCodeRanges(in text: String) -> [NSRange] {
        let lines = text.components(separatedBy: "\n")
        var ranges: [NSRange] = []
        var offset = 0
        var openFenceStart: Int?
        var openFenceMarker: String?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineLength = (line as NSString).length
            let hasNewline = index < lines.count - 1
            let storedLineLength = lineLength + (hasNewline ? 1 : 0)

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

            offset += storedLineLength
        }

        if let start = openFenceStart {
            ranges.append(NSRange(location: start, length: max(0, (text as NSString).length - start)))
        }

        return ranges
    }
}

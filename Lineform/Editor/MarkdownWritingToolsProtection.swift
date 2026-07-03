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

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hasNewline = index < lines.count - 1
            let storedLineLength = (line as NSString).length + (hasNewline ? 1 : 0)

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

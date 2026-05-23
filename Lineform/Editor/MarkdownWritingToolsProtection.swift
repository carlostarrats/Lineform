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
        return ranges
    }

    private static func frontMatterRange(in text: String) -> NSRange? {
        guard text.hasPrefix("---\n") else {
            return nil
        }

        let nsText = text as NSString
        let searchRange = NSRange(location: 4, length: max(0, nsText.length - 4))
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

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

        var openMarker: FenceMarker?
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

            if let fence = fenceRun(in: nsText, lineStart: lineStart, contentsEnd: contentsEnd) {
                if let open = openMarker {
                    if fence.closes(open) {
                        openMarker = nil
                    }
                } else {
                    openMarker = fence.marker
                }
            }

            guard lineEnd > lineStart else { break }
            lineStart = lineEnd
        }

        return openMarker != nil
    }

    /// A fence opener's delimiter character and run length, in UTF-16 units — the unit-level twin
    /// of `MermaidFence.openingMarker`.
    struct FenceMarker: Equatable {
        let unit: UInt16
        let length: Int
    }

    /// A classified fence delimiter line: its run, plus whether the run is BARE (nothing but
    /// whitespace follows it). Only a bare run can CLOSE a fence; an opener may carry an info
    /// string.
    struct FenceRun {
        let marker: FenceMarker
        let isBare: Bool

        /// CommonMark's closing rule, and `MermaidFence.isClosingFence`'s: the same delimiter
        /// character, a run at least as long as the opener's, and nothing after it.
        ///
        /// Comparing only the delimiter CHARACTER (or, worse, toggling a flag on any fence line)
        /// is what let an inner ```` ``` ```` close an outer ```` ```` ```` fence — the shape every
        /// note *about* Markdown has. The renderer kept the block whole while these passes ended
        /// it early, so Writing Tools could rewrite embedded code and the spell checker underlined
        /// it.
        func closes(_ open: FenceMarker) -> Bool {
            isBare && marker.unit == open.unit && marker.length >= open.length
        }
    }

    /// The fence delimiter run a line opens or closes with, or `nil`. Reads UTF-16 units
    /// directly so the overwhelming majority of lines — ordinary prose — are rejected on their
    /// first non-blank character without allocating a substring.
    ///
    /// Must agree with `MermaidFence.openingMarker`/`isClosingFence`, which the renderer uses;
    /// `testFenceClassificationMatchesTheRenderer` pins the two together.
    private static func fenceRun(in nsText: NSString, lineStart: Int, contentsEnd: Int) -> FenceRun? {
        var index = lineStart
        while index < contentsEnd, isWhitespace(nsText.character(at: index)) {
            index += 1
        }
        return fenceRun(from: index, to: contentsEnd) { nsText.character(at: $0) }
    }

    /// Shared run classifier over an already-trimmed line start. `unit` reads one UTF-16 unit, so
    /// the hot scoped walk can supply its inline buffer instead of paying an ObjC dispatch each.
    @inline(__always)
    private static func fenceRun(from lower: Int, to contentsEnd: Int, unit: (Int) -> UInt16) -> FenceRun? {
        let backtick = UInt16(UnicodeScalar("`").value)
        let tilde = UInt16(UnicodeScalar("~").value)

        guard lower < contentsEnd else { return nil }
        let first = unit(lower)
        guard first == backtick || first == tilde else { return nil }

        var end = lower
        while end < contentsEnd, unit(end) == first {
            end += 1
        }
        let length = end - lower
        guard length >= 3 else { return nil }

        var isBare = true
        var scan = end
        while scan < contentsEnd {
            if !isWhitespace(unit(scan)) {
                isBare = false
                break
            }
            scan += 1
        }

        return FenceRun(marker: FenceMarker(unit: first, length: length), isBare: isBare)
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
    /// It reproduces exactly what `protectedRanges(in:)` computes, clipped to `scope`, but:
    ///
    /// - **one** walk, not the two `fencedCodeRanges` + `mathRanges` make, so the document
    ///   prefix is traversed once;
    /// - lines before `scope` are classified by reading UTF-16 units directly, with **no
    ///   substring or trimmed-copy allocation** — the prefix only contributes fence and
    ///   `$$`-block *state*, never output;
    /// - the real predicates (`MathBlockFence`, `MathDelimiters`) run only on lines that can
    ///   actually produce a range, and the walk stops once past `scope`.
    ///
    /// A naive version calling the two whole-document passes measured **14.97 ms** per call at
    /// 730 KB — barely better than the pass it was meant to avoid, and it FAILED the gate in
    /// `MarkdownSpellCheckPerformanceTests`. Do not reintroduce that shape.
    ///
    /// Equivalence with `protectedRanges(in:)` is guarded by
    /// `testScopedProtectedRangesMatchesWholeDocumentIntersection`.
    ///
    /// See `docs/superpowers/specs/2026-07-26-live-spell-check-design.md`.
    static func protectedRanges(in text: NSString, intersecting scope: NSRange) -> [NSRange] {
        let full = NSRange(location: 0, length: text.length)
        let clampedScope = NSIntersectionRange(scope, full)
        guard clampedScope.length > 0 else { return [] }

        let limit = NSMaxRange(clampedScope)
        let scopeStart = clampedScope.location
        var ranges: [NSRange] = []

        if let frontMatter = frontMatterRange(in: text) {
            ranges.append(frontMatter)
        }

        // fencedCodeRanges state (marker-matched) and mathRanges state (toggled) are tracked
        // separately because the two whole-document passes track them differently — matching
        // that difference is what keeps this equivalent.
        var openFenceStart: Int?
        var openFenceMarker: FenceMarker?
        var mathBlockStart: Int?
        var mathOpenFenceMarker: FenceMarker?

        let dollar = UInt16(UnicodeScalar("$").value)
        let newlineUnit = UInt16(UnicodeScalar("\n").value)
        let length = text.length
        var offset = 0

        // Reading UTF-16 units through an inline buffer rather than `character(at:)` /
        // `range(of:)`: those are one Objective-C dispatch each, and the prefix walk performs
        // tens of thousands of them on a large document. Measured 2.69 ms → see the note above.
        var buffer = CFStringInlineBuffer()
        CFStringInitInlineBuffer(text as CFString, &buffer, CFRangeMake(0, length))

        @inline(__always)
        func unit(_ index: Int) -> UInt16 {
            CFStringGetCharacterFromInlineBuffer(&buffer, index)
        }

        while offset <= length {
            var scan = offset
            while scan < length, unit(scan) != newlineUnit {
                scan += 1
            }
            let isLast = scan >= length
            let contentsEnd = scan
            let contentLength = contentsEnd - offset
            let storedLength = contentLength + (isLast ? 0 : 1)

            // ONE leading-whitespace scan, shared by both classifications below. Deliberately
            // not `fenceMarker`, which skips only space/tab: this must match
            // `trimmingCharacters(in: lineTrimCharacters)` for the equivalence to hold.
            var lower = offset
            while lower < contentsEnd, isWhitespace(unit(lower)) {
                lower += 1
            }

            let fence = fenceRun(from: lower, to: contentsEnd, unit: unit)

            // Trailing trim is only needed to recognise a `$$`-only line, so pay for it only
            // when the line actually starts with `$`. Ordinary prose exits on one comparison.
            var isBlockDelimiterOnly = false
            if lower < contentsEnd, unit(lower) == dollar {
                var upper = contentsEnd
                while upper > lower, isWhitespace(unit(upper - 1)) {
                    upper -= 1
                }
                isBlockDelimiterOnly = upper - lower == 2 && unit(lower + 1) == dollar
            }

            // --- fencedCodeRanges ---
            if let fence {
                if let open = openFenceMarker, fence.closes(open) {
                    if let start = openFenceStart {
                        ranges.append(NSRange(location: start, length: offset + storedLength - start))
                    }
                    openFenceStart = nil
                    openFenceMarker = nil
                } else if openFenceMarker == nil {
                    openFenceStart = offset
                    openFenceMarker = fence.marker
                }
            }

            // --- mathRanges ---
            if mathBlockStart == nil, let fence {
                if let open = mathOpenFenceMarker {
                    if fence.closes(open) {
                        mathOpenFenceMarker = nil
                    }
                } else {
                    mathOpenFenceMarker = fence.marker
                }
            } else if mathOpenFenceMarker != nil {
                // Inside a fence: `$`/`$$` are not math.
            } else if let start = mathBlockStart {
                if isBlockDelimiterOnly {
                    ranges.append(NSRange(location: start, length: offset + storedLength - start))
                    mathBlockStart = nil
                }
            } else if isBlockDelimiterOnly {
                mathBlockStart = offset
            } else if contentsEnd > scopeStart {
                // The ONLY allocating branch, and only for lines that can produce output.
                let line = text.substring(with: NSRange(location: offset, length: contentLength))
                let trimmed = line.trimmingCharacters(in: lineTrimCharacters)
                if MathBlockFence.singleLineBlock(trimmed) != nil {
                    ranges.append(NSRange(location: offset, length: contentLength))
                } else {
                    ranges.append(contentsOf: MathDelimiters.inlineMathRanges(in: line, lineOffset: offset))
                }
            }

            if isLast || offset + storedLength >= limit {
                break
            }
            offset += storedLength
        }

        // Unterminated constructs protect through end of text, exactly as the whole-document
        // passes do. Clipping to `scope` (which ends at or before `limit`) then makes an
        // early-stopped walk indistinguishable from a complete one.
        if let start = openFenceStart {
            ranges.append(NSRange(location: start, length: max(0, length - start)))
        }
        if let start = mathBlockStart {
            ranges.append(NSRange(location: start, length: max(0, length - start)))
        }

        return ranges
            .map { NSIntersectionRange($0, clampedScope) }
            .filter { $0.length > 0 }
    }

    /// The shared line trim (whitespace plus `\r`). Without `\r`, a Windows-authored file's `$$`
    /// never read as a block delimiter and its front matter never opened, so math and YAML were
    /// left unprotected: Writing Tools could rewrite them, the spell checker flagged them, and ⌘1
    /// inside front matter prepended a heading marker to a YAML key.
    static let lineTrimCharacters = markdownLineTrimCharacters

    /// `lineTrimCharacters` membership for one UTF-16 unit, with an ASCII fast path.
    ///
    /// Must agree with `trimmingCharacters(in: lineTrimCharacters)` exactly — the scoped walk's
    /// equivalence to the whole-document passes depends on classifying lines the same way, so the
    /// two move together or not at all. The fast path is only an optimization: space, tab, and
    /// carriage return are in the set, every other ASCII character is not, and anything non-ASCII
    /// falls through to the real set.
    @inline(__always)
    private static func isWhitespace(_ unit: UInt16) -> Bool {
        if unit == 0x20 || unit == 0x09 || unit == 0x0D {
            return true
        }
        if unit < 0x80 {
            return false
        }
        guard let scalar = UnicodeScalar(unit) else {
            return false
        }
        return lineTrimCharacters.contains(scalar)
    }

    /// Ranges of LaTeX math regions — inline `$…$` and display `$$…$$` blocks — so Writing Tools
    /// does not rewrite the source, exactly as it leaves fenced code alone. Uses the same `$`
    /// rules as the renderer, so prose dollar signs ("$5") are never protected.
    private static func mathRanges(in text: String) -> [NSRange] {
        let lines = text.components(separatedBy: "\n")
        var ranges: [NSRange] = []
        var offset = 0
        var blockStart: Int?
        var openFenceMarker: (character: Character, length: Int)?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: lineTrimCharacters)
            let hasNewline = index < lines.count - 1
            let storedLineLength = (line as NSString).length + (hasNewline ? 1 : 0)

            // Never interpret `$`/`$$` inside a fenced code block (it is protected separately).
            // Fence state is tracked only when not mid math-block, and with `MermaidFence` rather
            // than a toggle — a toggle ended a ```` block at its first inner ``` line and then
            // read the code that followed as math.
            if blockStart == nil, MermaidFence.isFenceDelimiter(trimmed) {
                if let open = openFenceMarker {
                    if MermaidFence.isClosingFence(trimmed, matching: open) {
                        openFenceMarker = nil
                    }
                } else {
                    openFenceMarker = MermaidFence.openingMarker(trimmed)
                }
                offset += storedLineLength
                continue
            }
            if openFenceMarker != nil {
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
        frontMatterRange(in: text as NSString)
    }

    /// Identical to the `String` overload, which delegates here — so the scoped path can avoid
    /// bridging the whole document just to test a four-character prefix.
    private static func frontMatterRange(in nsText: NSString) -> NSRange? {
        // Both delimiters may carry the `\r` of a CRLF ending. Search still keys off the `\n`,
        // which is present either way; only the lengths consumed around it differ.
        let opensWithCRLF = nsText.hasPrefix("---\r\n")
        guard opensWithCRLF || nsText.hasPrefix("---\n") else {
            return nil
        }

        // Search from the opening delimiter's own trailing newline so a closing "\n---" that
        // immediately follows the opening — i.e. empty front matter ("---\n---") — is detected.
        let newlineOffset = opensWithCRLF ? 4 : 3
        let searchRange = NSRange(location: newlineOffset, length: max(0, nsText.length - newlineOffset))
        let closingRange = nsText.range(of: "\n---", options: [], range: searchRange)
        guard closingRange.location != NSNotFound else {
            return nil
        }

        // Consume the closing "---" and its line ending, which is "\r\n", "\n", or absent at EOF.
        var end = NSMaxRange(closingRange)
        if end < nsText.length, nsText.character(at: end) == UInt16(UnicodeScalar("\r").value) {
            end += 1
        }
        if end < nsText.length, nsText.character(at: end) == UInt16(UnicodeScalar("\n").value) {
            end += 1
        }
        return NSRange(location: 0, length: min(nsText.length, end))
    }

    private static func fencedCodeRanges(in text: String) -> [NSRange] {
        let lines = text.components(separatedBy: "\n")
        var ranges: [NSRange] = []
        var offset = 0
        var openFenceStart: Int?
        var openFenceMarker: (character: Character, length: Int)?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: lineTrimCharacters)
            let lineLength = (line as NSString).length
            let hasNewline = index < lines.count - 1
            let storedLineLength = lineLength + (hasNewline ? 1 : 0)

            // `MermaidFence` is the ONE fence definition — the renderer's. Closing is checked
            // before opening, matching `MarkdownOutlineParser`, so a bare delimiter run ends the
            // block it can end rather than opening a new one.
            if let open = openFenceMarker, MermaidFence.isClosingFence(trimmed, matching: open) {
                if let start = openFenceStart {
                    ranges.append(NSRange(location: start, length: offset + storedLineLength - start))
                }
                openFenceStart = nil
                openFenceMarker = nil
            } else if openFenceMarker == nil, let marker = MermaidFence.openingMarker(trimmed) {
                openFenceStart = offset
                openFenceMarker = marker
            }

            offset += storedLineLength
        }

        if let start = openFenceStart {
            ranges.append(NSRange(location: start, length: max(0, (text as NSString).length - start)))
        }

        return ranges
    }
}

import Foundation

/// A run of prose an AI action may revise, in DOCUMENT UTF-16 coordinates. `text` carries no
/// leading or trailing whitespace — edge whitespace stays in the document and is never sent.
struct ProseSegment: Equatable {
    let range: NSRange
    let text: String
}

/// What part of a Markdown document is prose and what is structure, for AI edits.
///
/// The hard rule (spec §4.2, bring-your-own-AI): an AI action never changes Markdown structure.
/// This type is the ONE place that decides what is prose. It defines almost nothing itself — it
/// COMPOSES the owning definition of every construct, so it cannot drift from what the app
/// renders (every concept this repo has implemented twice has disagreed):
///
/// 1. `MarkdownWritingToolsProtection.protectedRanges(in:intersecting:)` — front matter, fenced
///    code (any language, incl. mermaid), display and inline math in all four spellings.
/// 2. `MarkdownSyntaxHighlighter.tokens(in:scope:)` — every kind `protection(of:)` calls
///    `.structure` (markers, code spans, destinations, image text).
/// 3. `MarkdownInlineSyntax` — images whole; link and emphasis delimiters (group 1 is prose);
///    code spans; backslash escapes (`escapedMarker`).
/// 4. Line level, over `markdownSourceLines` (never `CharacterSet.newlines`): line terminators,
///    a line-0 BOM, indentation, trailing whitespace and hard-break `\`, blank lines, rules
///    (`MarkdownHorizontalRule.isRule`), setext underlines.
/// 5. `markdownBlocks(in:lineRanges:)` — `.whole` blocks entirely; markers inside
///    `.markersOnly` blocks via `MarkdownHeadingParser`, `MarkdownList`, `MarkdownCheckbox`,
///    `MarkdownBlockquote`, `MarkdownCallout`, `MarkdownTableParser`.
/// 6. Constructs Lineform does not render but the spec protects, defined ONCE here: raw HTML
///    tags and comments (multi-line too), footnote markers, reference definitions and labels,
///    autolinks, bare URLs and emails, single-tilde strikethrough, every backslash escape.
///
/// Everything is OVER-approximated toward structure: anything claimed by any rule is structure,
/// and only what no rule claims is prose. Structure ranges are widened to composed-character
/// boundaries, so a segment never begins with a combining mark or splits an emoji.
///
/// Cost: whole-document (the block grouping and fence state are cross-line). It runs when the
/// writer chooses an AI action, never per keystroke — it must stay off the spell-check path.
enum MarkdownStructureMap {
    enum TokenProtection: Equatable {
        case structure
        case prose
    }

    enum BlockProtection: Equatable {
        case whole
        case markersOnly
    }

    /// Exhaustive with no `default`: a new token kind stops the build here until it is classified.
    static func protection(of kind: MarkdownTokenKind) -> TokenProtection {
        switch kind {
        case .headingMarker: return .structure
        case .listMarker: return .structure
        case .checkbox: return .structure
        case .blockquoteMarker: return .structure
        case .codeSpan: return .structure
        case .codeFence: return .structure
        case .linkText: return .prose
        case .linkDestination: return .structure
        // Alt text is left alone (spec §4.2, Claude's call): the image is structure whole.
        case .imageText: return .structure
        case .imageDestination: return .structure
        }
    }

    /// Exhaustive with no `default`: a new block case stops the build here until it is classified.
    static func protection(of block: MarkdownBlock) -> BlockProtection {
        switch block {
        case .lines: return .markersOnly
        case .singleLineMath: return .whole
        case .fencedMath: return .whole
        case .mermaid: return .whole
        case .horizontalRule: return .whole
        case .blockquote: return .markersOnly
        case .callout: return .markersOnly
        case .list: return .markersOnly
        case .table: return .markersOnly
        case .fencedCode: return .whole
        case .image: return .whole
        }
    }

    /// Every non-prose unit of the lines touching `scope` — sorted, coalesced, on composed-character
    /// boundaries, clipped to those lines (terminators included). Identical to the whole-document
    /// result intersected with those lines.
    static func structureRanges(in text: NSString, scope: NSRange) -> [NSRange] {
        structureRanges(in: text, scope: scope, referenceLabels: nil)
    }

    /// `referenceLabels` overrides the labels defined in `text` — the guard analyses a block
    /// window but must judge `[label]` by the DOCUMENT's definitions, exactly as `verify` does.
    static func structureRanges(in text: NSString, scope: NSRange, referenceLabels: Set<String>?) -> [NSRange] {
        let model = SourceModel(text)
        guard let span = model.lineSpan(touching: scope), span.length > 0 else { return [] }
        return wholeDocumentStructure(model, labels: referenceLabels ?? definedReferenceLabels(model))
            .map { NSIntersectionRange($0, span) }
            .filter { $0.length > 0 }
    }

    /// The selection minus structure, split at line boundaries, edge-trimmed, empties dropped.
    /// The selection is first widened to composed-character boundaries.
    static func proseSegments(in text: String, selection: NSRange) -> [ProseSegment] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let clamped = NSIntersectionRange(selection, full)
        guard clamped.length > 0, clamped.location >= 0 else { return [] }
        let aligned = ns.rangeOfComposedCharacterSequences(for: clamped)

        let structure = structureRanges(in: ns, scope: aligned)
        var segments: [ProseSegment] = []
        for piece in MarkdownSpellCheckRegions.subtracting(structure, from: aligned) {
            for line in splitAtLineFeeds(piece, in: ns) {
                let trimmed = edgeTrimmed(line, in: ns)
                guard trimmed.length > 0 else { continue }
                segments.append(ProseSegment(range: trimmed, text: ns.substring(with: trimmed)))
            }
        }
        return segments
    }

    /// The structure substrings of the lines touching `scope`, in order. Two texts with the same
    /// signature carry byte-identical structure.
    static func signature(of text: NSString, scope: NSRange) -> [String] {
        signature(of: text, scope: scope, referenceLabels: nil)
    }

    static func signature(of text: NSString, scope: NSRange, referenceLabels: Set<String>?) -> [String] {
        structureRanges(in: text, scope: scope, referenceLabels: referenceLabels).map { text.substring(with: $0) }
            + emphasisPairing(in: text, scope: scope)
    }

    /// Which `*`/`_`/`~` delimiters pair with which, by ordinal among those characters.
    ///
    /// Every such character is structure, so the substrings alone cannot see a prose edit that
    /// re-pairs them — and pairing depends on the prose beside a delimiter (`a_b_c` is not
    /// emphasis, `a+_b_,` is; `_x_,` is, `_x_1` is not). Since the characters themselves can
    /// never move, their ordinals are stable, and a change in who pairs with whom is a change in
    /// structure.
    private static func emphasisPairing(in text: NSString, scope: NSRange) -> [String] {
        let model = SourceModel(text)
        guard let span = model.lineSpan(touching: scope), span.length > 0 else { return [] }
        let first = model.lineIndex(containing: span.location)
        let last = model.lineIndex(containing: max(span.location, NSMaxRange(span) - 1))
        let patterns = [MarkdownInlineSyntax.bold, MarkdownInlineSyntax.italic, MarkdownInlineSyntax.italicAsterisk, MarkdownInlineSyntax.strikethrough, singleTilde]
        var entries: [String] = []
        var ordinal = 0
        for index in first...last {
            let line = model.lines[index]
            let ns = line as NSString
            // Ordinal of each delimiter character on this line, counted from the span's start.
            var ordinals = [Int](repeating: 0, count: ns.length + 1)
            for position in 0..<ns.length {
                ordinals[position] = ordinal
                if delimiterRunCharacters.contains(ns.character(at: position)) { ordinal += 1 }
            }
            ordinals[ns.length] = ordinal
            for (kind, regex) in patterns.enumerated() {
                for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let inner = match.range(at: 1)
                    guard inner.location != NSNotFound else { continue }
                    entries.append("\u{1}\(kind):\(ordinals[match.range.location]):\(ordinals[NSMaxRange(inner)])")
                }
            }
        }
        return entries
    }

    // MARK: - Shared with the guard

    /// Edge whitespace, matched per composed character so a trim never splits a cluster.
    static func edgeTrimmed(_ range: NSRange, in ns: NSString) -> NSRange {
        let string = ns.substring(with: range)
        var leading = 0
        for character in string {
            guard isTrimmable(character) else { break }
            leading += character.utf16.count
        }
        guard leading < range.length else { return NSRange(location: range.location, length: 0) }
        var trailing = 0
        for character in string.reversed() {
            guard isTrimmable(character) else { break }
            trailing += character.utf16.count
        }
        return NSRange(location: range.location + leading, length: range.length - leading - trailing)
    }

    private static let trimSet = CharacterSet.whitespacesAndNewlines.union(markdownLineTrimCharacters)

    private static func isTrimmable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { trimSet.contains($0) }
    }

    private static func splitAtLineFeeds(_ range: NSRange, in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = range.location
        let end = NSMaxRange(range)
        var index = start
        while index < end {
            if ns.character(at: index) == 0x0A {
                if index > start { result.append(NSRange(location: start, length: index - start)) }
                start = index + 1
            }
            index += 1
        }
        if end > start { result.append(NSRange(location: start, length: end - start)) }
        return result
    }

    // MARK: - Source model

    /// The document split the way every renderer splits it (`markdownSourceLines`), with each
    /// line's RAW extent (BOM and terminator included) alongside its stripped content.
    struct SourceModel {
        let text: NSString
        let lines: [String]
        /// Where each line's stripped text sits in the original (past a line-0 BOM, before `\r`).
        let content: [NSRange]
        /// Each line's full extent: from its first unit (a line-0 BOM included) to the start of
        /// the next line (its `\r\n` / `\n` included).
        let raw: [NSRange]

        init(_ text: NSString) {
            self.text = text
            let source = markdownSourceLines(in: text as String)
            lines = source.lines
            var content: [NSRange] = []
            var raw: [NSRange] = []
            for index in source.lines.indices {
                let location = source.ranges[index].location
                content.append(NSRange(location: location, length: (source.lines[index] as NSString).length))
                let start = index == 0 ? 0 : location
                let end = index + 1 < source.ranges.count ? source.ranges[index + 1].location : text.length
                raw.append(NSRange(location: start, length: end - start))
            }
            self.content = content
            self.raw = raw
        }

        func isBlank(_ index: Int) -> Bool {
            lines[index].trimmingCharacters(in: markdownLineTrimCharacters).isEmpty
        }

        /// The index of the line holding `location` (the last line for `location == length`).
        func lineIndex(containing location: Int) -> Int {
            var low = 0
            var high = raw.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if raw[mid].location <= location {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return low
        }

        /// The raw extent of the lines `scope` touches; an empty scope touches the line holding it.
        func lineSpan(touching scope: NSRange) -> NSRange? {
            guard scope.location >= 0, scope.location <= text.length, !raw.isEmpty else { return nil }
            let end = min(NSMaxRange(scope), text.length)
            let first = lineIndex(containing: scope.location)
            let last = end > scope.location ? lineIndex(containing: end - 1) : first
            let start = raw[first].location
            return NSRange(location: start, length: NSMaxRange(raw[last]) - start)
        }
    }

    // MARK: - The composition

    private static func wholeDocumentStructure(_ model: SourceModel, labels: Set<String>) -> [NSRange] {
        let text = model.text
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return [] }
        var ranges: [NSRange] = []

        // 1. Front matter, fenced code, math.
        ranges += MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: full)

        // 2. The editor's tokens, minus the one prose kind.
        ranges += MarkdownSyntaxHighlighter()
            .tokens(in: text, scope: full)
            .filter { protection(of: $0.kind) == .structure }
            .map(\.range)

        // 3, 4, 6. Line-local rules. Reference labels are only structure when defined.
        var codeLike: [NSRange] = []
        for index in model.lines.indices {
            let inline = inlineStructure(line: model.lines[index], offset: model.content[index].location, labels: labels)
            ranges += inline.all
            codeLike += inline.code
            ranges += lineStructure(model, index)
        }
        codeLike += MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: full)

        // 6, cross-line: multi-line HTML comments and tags opened but not closed on their line.
        ranges += multiLineHTML(model, excluding: codeLike)

        // 5. Blocks.
        ranges += blockStructure(model)

        let widened = ranges
            .map { NSIntersectionRange($0, full) }
            .filter { $0.length > 0 }
            .map { text.rangeOfComposedCharacterSequences(for: $0) }
        return coalesced(widened)
    }

    private static func coalesced(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSRange(
                    location: last.location,
                    length: max(NSMaxRange(last), NSMaxRange(range)) - last.location
                )
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: Inline (3, 6)

    /// Raw HTML tags. Not rendered by Lineform; protected by spec §4.2. Defined only here.
    private static let htmlTag = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9-]*(\s[^<>\n]*)?/?>"#)
    /// HTML comments, one line. Defined only here.
    private static let htmlComment = try! NSRegularExpression(pattern: #"<!--[^\n]*?-->"#)
    /// CommonMark autolinks (`<https://example.com>`): a link, so its URL is never prose. Not
    /// rendered as a link by Lineform today. Defined only here.
    private static let autolink = try! NSRegularExpression(pattern: #"<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\s]*>"#)
    /// Footnote references and definitions (`[^1]`, `[^note]:`). Defined only here.
    private static let footnoteMarker = try! NSRegularExpression(pattern: #"\[\^[^\]\s]+\]:?"#)

    /// GFM single-tilde strikethrough (`~x~`). Not rendered by Lineform. Defined only here.
    private static let singleTilde = try! NSRegularExpression(pattern: #"(?<![~\\])~([^~\s\n](?:[^~\n]*[^~\s\n])?)~(?!~)"#)
    /// Every CommonMark backslash escape — a superset of `MarkdownInlineSyntax.escapedMarker`,
    /// which is only the set the app UNESCAPES. All of them are structure.
    private static let anyEscape = try! NSRegularExpression(pattern: #"\\[!-/:-@\[-`{-~]"#)
    /// Email autolinks (`<me@mail.com>`). Defined only here.
    private static let emailAutolink = try! NSRegularExpression(
        pattern: #"<[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*>"#
    )
    /// GFM autolink literals: bare URLs and bare emails. Structure by ruling, so proofreading
    /// never "fixes" an address. Defined only here.
    private static let bareURL = try! NSRegularExpression(pattern: #"(?:https?://|www\.)[^\s<]*[^\s<?!.,:*_~)]"#)
    private static let bareEmail = try! NSRegularExpression(pattern: #"[A-Za-z0-9._+-]+@[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+"#)
    /// A reference-link definition line, `[ref]: https://… "Title"` — whole line. A label starting
    /// with `^` is a footnote definition, whose text stays prose.
    static let referenceDefinition = try! NSRegularExpression(pattern: #"^ {0,3}\[(?!\^)([^\]]+)\]:[ \t]*\S.*$"#)
    /// `[text][label]` (full or collapsed reference). Group 1 is the text, group 2 the label.
    private static let fullReference = try! NSRegularExpression(pattern: #"(?<![\\!])\[([^\]\n]+)\]\[([^\]\n]*)\]"#)
    /// `![alt][label]` — a reference image is structure whole, like an inline one.
    private static let referenceImage = try! NSRegularExpression(pattern: #"(?<!\\)!\[[^\]\n]*\]\[[^\]\n]*\]"#)
    /// `[label]` alone (shortcut reference) — structure only when the label is defined.
    private static let shortcutReference = try! NSRegularExpression(pattern: #"(?<![\\\]])\[([^\]\n]+)\](?![\[(:])"#)

    private static func normalizedLabel(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    static func definedReferenceLabels(_ model: SourceModel) -> Set<String> {
        var labels: Set<String> = []
        for line in model.lines {
            let ns = line as NSString
            if let match = referenceDefinition.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                labels.insert(normalizedLabel(ns.substring(with: match.range(at: 1))))
            }
        }
        return labels
    }

    private static let delimiterRunCharacters: Set<UInt16> = [
        UInt16(UnicodeScalar("*").value), UInt16(UnicodeScalar("_").value), UInt16(UnicodeScalar("~").value),
    ]
    private static let backtickUnit = UInt16(UnicodeScalar("`").value)

    /// A delimiter piece widened over the whole run of delimiter characters touching it, so
    /// `***bold italic***` never leaves a lone prose `*` beside a matched `**` / `*`.
    private static func widenedRun(_ range: NSRange, in ns: NSString, units: Set<UInt16>) -> NSRange {
        var lower = range.location
        var upper = NSMaxRange(range)
        while lower > 0, units.contains(ns.character(at: lower - 1)) { lower -= 1 }
        while upper < ns.length, units.contains(ns.character(at: upper)) { upper += 1 }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func inlineStructure(line: String, offset: Int, labels: Set<String>) -> (all: [NSRange], code: [NSRange]) {
        let ns = line as NSString
        let lineRange = NSRange(location: 0, length: ns.length)
        guard lineRange.length > 0 else { return ([], []) }
        var local: [NSRange] = []
        var code: [NSRange] = []

        func matches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            regex.matches(in: line, range: lineRange)
        }

        if referenceDefinition.firstMatch(in: line, range: lineRange) != nil {
            local.append(lineRange)
        }
        for match in matches(MarkdownInlineSyntax.image) {
            local.append(balancedExtent(of: match, destinationGroup: 2, in: ns))
        }
        for match in matches(MarkdownInlineSyntax.link) {
            local += subtracting(group: 1, from: balancedExtent(of: match, destinationGroup: 2, in: ns), match: match)
        }
        for match in matches(fullReference) {
            let label = ns.substring(with: match.range(at: 2))
            // A collapsed `[text][]` uses its text as the label: the whole thing is structure.
            local += label.isEmpty ? [match.range] : subtracting(group: 1, from: match.range, match: match)
        }
        for match in matches(shortcutReference) where labels.contains(normalizedLabel(ns.substring(with: match.range(at: 1)))) {
            local.append(match.range)
        }
        for regex in [MarkdownInlineSyntax.bold, MarkdownInlineSyntax.italic, MarkdownInlineSyntax.italicAsterisk, MarkdownInlineSyntax.strikethrough, singleTilde] {
            for match in matches(regex) {
                local += subtracting(group: 1, from: match.range, match: match)
                    .map { widenedRun($0, in: ns, units: delimiterRunCharacters) }
            }
        }
        for match in matches(MarkdownInlineSyntax.code) {
            // ``x`` — the outer backticks of a double-backtick span are the same span.
            code.append(widenedRun(match.range, in: ns, units: [backtickUnit]))
        }
        local += code
        for regex in [referenceImage, MarkdownInlineSyntax.escapedMarker, anyEscape, htmlTag, htmlComment, autolink, emailAutolink, bareURL, bareEmail, footnoteMarker] {
            local += matches(regex).map(\.range)
        }

        let shift = { (range: NSRange) in NSRange(location: range.location + offset, length: range.length) }
        return (local.map(shift), code.map(shift))
    }

    /// An HTML comment opened on a line and closed on a later one (or never), and a tag whose
    /// `<name` opens on a line without its `>` — `<img src="a.png"⏎ width="3">`. Comments run to
    /// the closing `-->` or the end of the document; an open tag runs to its `>` if one comes
    /// before a blank line (where CommonMark ends an HTML block), else to the end of its line.
    /// Openers inside code, math, or front matter are ignored.
    private static let openTag = try! NSRegularExpression(pattern: #"<[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?$"#)

    private static func multiLineHTML(_ model: SourceModel, excluding codeLike: [NSRange]) -> [NSRange] {
        let text = model.text
        var ranges: [NSRange] = []
        func isCode(_ location: Int) -> Bool {
            codeLike.contains { NSLocationInRange(location, $0) }
        }

        var search = 0
        while search < text.length {
            let open = text.range(of: "<!--", options: [], range: NSRange(location: search, length: text.length - search))
            guard open.location != NSNotFound else { break }
            if isCode(open.location) {
                search = NSMaxRange(open)
                continue
            }
            let afterOpen = NSMaxRange(open)
            let close = text.range(of: "-->", options: [], range: NSRange(location: afterOpen, length: text.length - afterOpen))
            let end = close.location == NSNotFound ? text.length : NSMaxRange(close)
            ranges.append(NSRange(location: open.location, length: end - open.location))
            search = end
        }

        for index in model.lines.indices {
            let line = model.lines[index]
            let ns = line as NSString
            guard let match = openTag.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let start = model.content[index].location + match.range.location
            guard !isCode(start) else { continue }
            var end = NSMaxRange(model.content[index])
            var next = index + 1
            while next < model.lines.count, !model.isBlank(next) {
                let candidate = (model.lines[next] as NSString).range(of: ">")
                if candidate.location != NSNotFound {
                    end = model.content[next].location + NSMaxRange(candidate)
                    break
                }
                next += 1
            }
            ranges.append(NSRange(location: start, length: end - start))
        }
        return ranges
    }

    private static func subtracting(group: Int, from range: NSRange, match: NSTextCheckingResult) -> [NSRange] {
        let inner = match.range(at: group)
        guard inner.location != NSNotFound, inner.length > 0 else { return [range] }
        return MarkdownSpellCheckRegions.subtracting([inner], from: range)
    }

    /// The match, extended over the `)` that balance any `(` its destination opened.
    ///
    /// `MarkdownInlineSyntax` ends a destination at the first `)`, so `[w](https://e.org/A_(b))`
    /// leaves a trailing `)` outside the match — and `![a](photo (1).png)` leaves `.png)`. Those
    /// characters are part of the URL to every other editor, so they are structure here too. This
    /// only ever ADDS structure; what the app renders is untouched.
    private static func balancedExtent(of match: NSTextCheckingResult, destinationGroup: Int, in ns: NSString) -> NSRange {
        let destination = match.range(at: destinationGroup)
        guard destination.location != NSNotFound else { return match.range }
        let open = UInt16(UnicodeScalar("(").value)
        let close = UInt16(UnicodeScalar(")").value)
        var depth = 0
        for index in destination.location..<NSMaxRange(destination) {
            let unit = ns.character(at: index)
            if unit == open { depth += 1 } else if unit == close { depth -= 1 }
        }
        guard depth > 0 else { return match.range }
        var index = NSMaxRange(match.range)
        while index < ns.length {
            let unit = ns.character(at: index)
            if unit == open {
                depth += 1
            } else if unit == close {
                depth -= 1
                if depth == 0 {
                    return NSRange(location: match.range.location, length: index + 1 - match.range.location)
                }
            }
            index += 1
        }
        return match.range
    }

    // MARK: Line level (4)

    private static func lineStructure(_ model: SourceModel, _ index: Int) -> [NSRange] {
        let text = model.text
        let content = model.content[index]
        let raw = model.raw[index]
        var ranges: [NSRange] = []

        // A line-0 byte-order mark, and the terminator (`\r\n`, `\n`, or a CRLF's `\r` at EOF).
        if content.location > raw.location {
            ranges.append(NSRange(location: raw.location, length: content.location - raw.location))
        }
        if NSMaxRange(raw) > NSMaxRange(content) {
            ranges.append(NSRange(location: NSMaxRange(content), length: NSMaxRange(raw) - NSMaxRange(content)))
        }

        if model.isBlank(index) {
            ranges.append(raw)
            return ranges
        }

        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        let backslash = UInt16(UnicodeScalar("\\").value)
        let start = content.location
        let end = NSMaxRange(content)

        var lead = start
        while lead < end, text.character(at: lead) == space || text.character(at: lead) == tab {
            lead += 1
        }
        if lead > start { ranges.append(NSRange(location: start, length: lead - start)) }

        var trail = end
        while trail > lead, text.character(at: trail - 1) == space || text.character(at: trail - 1) == tab {
            trail -= 1
        }
        if trail < end { ranges.append(NSRange(location: trail, length: end - trail)) }
        // A hard break written as a trailing backslash.
        if trail > lead, text.character(at: trail - 1) == backslash {
            ranges.append(NSRange(location: trail - 1, length: 1))
        }

        // Control characters and in-line separators (a lone `\r`, U+2028 from InDesign, a tab):
        // the guard refuses any revision carrying one, so they must never be inside a segment.
        //
        // And EVERY `*`, `_`, `~`, paired or not (ruling, review round 2). Pairing them here the
        // way the renderer does would be a fifth implementation of emphasis; running each
        // pattern independently mispaired `**a**x*b* c` (the bold's closer read as the italic's
        // opener), leaving the italic's real closer in prose where moving it was admitted.
        // Prose almost never needs these changed; `2 * 3` and `snake_case` stay as written.
        for location in start..<end {
            let unit = text.character(at: location)
            if unit < 0x20 || (unit >= 0x7F && unit <= 0x9F) || unit == 0x2028 || unit == 0x2029
                || delimiterRunCharacters.contains(unit) {
                ranges.append(NSRange(location: location, length: 1))
            }
        }

        let line = model.lines[index]
        if MarkdownHorizontalRule.isRule(lines: model.lines, index: index) {
            ranges.append(content)
        }

        // Setext underline: only `=` or only `-`, under a non-blank line.
        let trimmed = line.trimmingCharacters(in: markdownLineTrimCharacters)
        if index > 0, !model.isBlank(index - 1),
           trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
            ranges.append(content)
        }

        // A table delimiter row, wherever it sits: it is never prose. A row directly above it
        // and the rows below it get the pipe rule even when `markdownBlocks` declines the table
        // (for example a header whose `\|` splits into one cell too many — a known limitation of
        // `MarkdownTableParser.cells`), because GFM still reads them as a table.
        if MarkdownTableParser.isDelimiterRow(line) {
            ranges.append(content)
            if index > 0, MarkdownTableParser.looksLikeRow(model.lines[index - 1]) {
                ranges += pipeStructure(in: text, line: model.content[index - 1])
                var below = index + 1
                while below < model.lines.count, MarkdownTableParser.looksLikeRow(model.lines[below]) {
                    ranges += pipeStructure(in: text, line: model.content[below])
                    below += 1
                }
            }
        }

        return ranges
    }

    /// Every `|` (escaped `\|` included) with the spaces and tabs touching it.
    private static func pipeStructure(in text: NSString, line: NSRange) -> [NSRange] {
        let pipe = UInt16(UnicodeScalar("|").value)
        let backslash = UInt16(UnicodeScalar("\\").value)
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        let start = line.location
        let end = NSMaxRange(line)
        var ranges: [NSRange] = []
        var index = start
        while index < end {
            guard text.character(at: index) == pipe else {
                index += 1
                continue
            }
            var lower = index
            if lower > start, text.character(at: lower - 1) == backslash { lower -= 1 }
            while lower > start, text.character(at: lower - 1) == space || text.character(at: lower - 1) == tab {
                lower -= 1
            }
            var upper = index + 1
            while upper < end, text.character(at: upper) == space || text.character(at: upper) == tab {
                upper += 1
            }
            ranges.append(NSRange(location: lower, length: upper - lower))
            index += 1
        }
        return ranges
    }

    // MARK: Blocks (5)

    private static func blockStructure(_ model: SourceModel) -> [NSRange] {
        let lines = model.lines
        guard !lines.isEmpty else { return [] }
        let blocks = markdownBlocks(in: lines, lineRanges: model.content)
        var ranges: [NSRange] = []
        var cursor = 0

        for block in blocks {
            let last: Int
            switch block {
            case .lines(let range): last = range.upperBound - 1
            case .singleLineMath(_, let lineIndex): last = lineIndex
            case .fencedMath(_, let closingIndex): last = closingIndex ?? lines.count - 1
            case .mermaid(_, let closingIndex): last = closingIndex ?? lines.count - 1
            case .horizontalRule(let lineIndex): last = lineIndex
            case .blockquote(_, let lastLineIndex): last = lastLineIndex
            case .callout(_, _, _, let lastLineIndex): last = lastLineIndex
            case .list(_, let lastLineIndex): last = lastLineIndex
            case .table(_, let lastLineIndex): last = lastLineIndex
            case .fencedCode(_, _, _, let closingIndex): last = closingIndex ?? lines.count - 1
            case .image(_, _, _, let lineIndex): last = lineIndex
            }
            let first = cursor
            let upper = min(max(last, first), lines.count - 1)
            cursor = upper + 1
            guard first <= upper else { continue }

            switch protection(of: block) {
            case .whole:
                let start = model.raw[first].location
                ranges.append(NSRange(location: start, length: NSMaxRange(model.raw[upper]) - start))
            case .markersOnly:
                for index in first...upper {
                    ranges += markers(of: block, model: model, index: index, isFirst: index == first, isDelimiter: index == first + 1)
                }
            }
            if cursor >= lines.count { break }
        }
        return ranges
    }

    private static func markers(of block: MarkdownBlock, model: SourceModel, index: Int, isFirst: Bool, isDelimiter: Bool) -> [NSRange] {
        let line = model.lines[index]
        let content = model.content[index]
        switch block {
        case .lines:
            return headingMarkers(in: line, offset: content.location)
        case .blockquote, .callout:
            guard let quote = MarkdownBlockquote.quoteLine(line) else { return [] }
            let prefix = (line as NSString).length - (quote.text as NSString).length
            var ranges = [NSRange(location: content.location, length: prefix)]
            let innerOffset = content.location + prefix
            if case .callout = block, isFirst, MarkdownCallout.parse(firstQuoteText: quote.text) != nil {
                let close = (quote.text as NSString).range(of: "]")
                if close.location != NSNotFound {
                    ranges.append(NSRange(location: innerOffset, length: NSMaxRange(close)))
                }
            }
            ranges += listMarkers(in: quote.text, offset: innerOffset)
            ranges += headingMarkers(in: quote.text, offset: innerOffset)
            return ranges
        case .list:
            return listMarkers(in: line, offset: content.location)
        case .table:
            if isDelimiter { return [content] }
            return pipeStructure(in: model.text, line: content)
        case .singleLineMath, .fencedMath, .mermaid, .horizontalRule, .fencedCode, .image:
            return []
        }
    }

    /// An ATX heading's marker and closing sequence, as `MarkdownHeadingParser` reads the line.
    private static func headingMarkers(in line: String, offset: Int) -> [NSRange] {
        guard MarkdownHeadingParser.heading(in: line) != nil else { return [] }
        let ns = line as NSString
        let space = UInt16(UnicodeScalar(" ").value)
        let hash = UInt16(UnicodeScalar("#").value)
        var cursor = 0
        while cursor < ns.length, cursor < 3, ns.character(at: cursor) == space {
            cursor += 1
        }
        var markerEnd = cursor
        while markerEnd < ns.length, ns.character(at: markerEnd) == hash {
            markerEnd += 1
        }
        // The parser's title is the rest trimmed of `#` and whitespace on both sides; what it
        // trims is marker, not text.
        let isMarker: (UInt16) -> Bool = { unit in
            guard let scalar = UnicodeScalar(unit) else { return false }
            return unit == hash || CharacterSet.whitespaces.contains(scalar)
        }
        var lead = markerEnd
        while lead < ns.length, isMarker(ns.character(at: lead)) {
            lead += 1
        }
        var trail = ns.length
        while trail > lead, isMarker(ns.character(at: trail - 1)) {
            trail -= 1
        }
        var ranges = [NSRange(location: offset + cursor, length: lead - cursor)]
        if trail < ns.length {
            ranges.append(NSRange(location: offset + trail, length: ns.length - trail))
        }
        return ranges
    }

    /// A list item's indent + marker + separator, and a task checkbox, as `MarkdownList` and
    /// `MarkdownCheckbox` read the line.
    private static func listMarkers(in line: String, offset: Int) -> [NSRange] {
        guard let item = MarkdownList.parse(line) else { return [] }
        var ranges = [NSRange(location: offset, length: item.textColumn)]
        if !item.ordered, MarkdownCheckbox.detect(in: item.text) != nil {
            ranges.append(NSRange(location: offset + item.textColumn, length: 3))
        }
        return ranges
    }
}

/// Decides which AI revisions may enter the document. The AI is never trusted to "be careful":
/// every revision is spliced and its block's structure signature re-derived.
enum MarkdownStructureGuard {
    /// One result per segment, in `segments` order: the (edge-trimmed) revision to splice in, or
    /// nil. A revision is refused when it is empty after trimming; contains a line terminator or
    /// any `Cc` character, or a `Cf` character the original did not; carries a different
    /// sequence of `markdownPunctuation` than the original; exceeds `2 × original + 200` UTF-16 units; or changes the structure
    /// signature of its block (the contiguous non-blank lines around it) when spliced in together
    /// with the revisions already admitted on that block. A segment that no longer matches `text`
    /// is refused. Missing revisions are nil; extra revisions are ignored.
    static func admissibleRevisions(_ revisions: [String], for segments: [ProseSegment], in text: String) -> [String?] {
        let ns = text as NSString
        var result = [String?](repeating: nil, count: segments.count)
        guard ns.length > 0 else { return result }
        let model = MarkdownStructureMap.SourceModel(ns)
        let protected = MarkdownWritingToolsProtection.protectedRanges(in: ns, intersecting: NSRange(location: 0, length: ns.length))
        let labels = MarkdownStructureMap.definedReferenceLabels(model)
        var blocks: [Int: BlockState] = [:]

        let order = segments.indices.sorted { segments[$0].range.location < segments[$1].range.location }
        for index in order where index < revisions.count {
            let segment = segments[index]
            guard isCurrent(segment, in: ns),
                  let revision = normalized(revisions[index], replacing: segment) else { continue }

            let line = model.lineIndex(containing: segment.range.location)
            guard NSMaxRange(segment.range) <= NSMaxRange(model.content[line]) else { continue }
            var first = line
            while first > 0, !model.isBlank(first - 1) { first -= 1 }
            var last = line
            while last + 1 < model.lines.count, !model.isBlank(last + 1) { last += 1 }

            var state = blocks[first] ?? BlockState(model: model, protected: protected, labels: labels, firstLine: first, lastLine: last)
            guard !state.edits.contains(where: { NSIntersectionRange($0.range, segment.range).length > 0 || $0.range.location == segment.range.location }) else {
                continue
            }
            let candidate = state.edits + [(range: segment.range, text: revision)]
            if state.signature(applying: candidate) == state.originalSignature {
                state.edits = candidate
                result[index] = revision
            }
            blocks[first] = state
        }
        return result
    }

    /// Whole-document structure equality: the final gate after composition.
    static func verify(original: String, revised: String) -> Bool {
        let lhs = original as NSString
        let rhs = revised as NSString
        return MarkdownStructureMap.signature(of: lhs, scope: NSRange(location: 0, length: lhs.length))
            == MarkdownStructureMap.signature(of: rhs, scope: NSRange(location: 0, length: rhs.length))
    }

    // MARK: - Private

    private static func isCurrent(_ segment: ProseSegment, in ns: NSString) -> Bool {
        let range = segment.range
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= ns.length else { return false }
        return ns.substring(with: range).utf16.elementsEqual(segment.text.utf16)
    }

    /// The characters that can make or break Markdown. A revision must carry exactly the same
    /// sequence of them as the text it replaces. The signature alone is not enough: it compares
    /// structure CONTENT, not position, so `**very**` revised to `*very*` re-paired as
    /// `***very***` with an identical-looking structure list, and `a` → `a*` beside `*b*`
    /// re-paired the italic.
    static let markdownPunctuation: Set<Unicode.Scalar> = ["*", "_", "~", "`", "|", "[", "]", "<", ">", "#", "$", "\\", "^"]

    private static func punctuationSequence(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { markdownPunctuation.contains($0) }
    }

    private static func formatCharacters(_ text: String) -> Set<Unicode.Scalar> {
        Set(text.unicodeScalars.filter { $0.properties.generalCategory == .format })
    }

    private static func normalized(_ revision: String, replacing segment: ProseSegment) -> String? {
        let forbidden = revision.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
                || scalar.value == 0x2028 || scalar.value == 0x2029
        }
        guard !forbidden else { return nil }
        // Format characters (ZWSP, a U+202E bidi override) are invisible: never introduced.
        guard formatCharacters(revision).isSubset(of: formatCharacters(segment.text)) else { return nil }
        let ns = revision as NSString
        let trimmed = ns.substring(with: MarkdownStructureMap.edgeTrimmed(NSRange(location: 0, length: ns.length), in: ns))
        let length = (trimmed as NSString).length
        guard length > 0, length <= 2 * (segment.text as NSString).length + 200 else { return nil }
        guard punctuationSequence(trimmed) == punctuationSequence(segment.text) else { return nil }
        return trimmed
    }

    /// One block's analysis window and the revisions admitted on it so far.
    ///
    /// The window is the block's lines, started early when a fence, math block, or front matter
    /// is already open at the block's first line, so cross-line state matches the document.
    /// Otherwise the line before the block is blank, which a leading `"\n"` reproduces (a `---`
    /// after a blank line is a rule, never front matter, exactly as in the document).
    private struct BlockState {
        let windowStart: Int
        let prefix: String
        let window: String
        let originalSignature: [String]
        var edits: [(range: NSRange, text: String)] = []

        let labels: Set<String>

        init(model: MarkdownStructureMap.SourceModel, protected: [NSRange], labels: Set<String>, firstLine: Int, lastLine: Int) {
            self.labels = labels
            let blockStart = model.raw[firstLine].location
            var start = blockStart
            var moved = true
            while moved {
                moved = false
                for range in protected where range.location < start && NSMaxRange(range) > start {
                    start = range.location
                    moved = true
                }
            }
            // Snap to the start of that line.
            start = model.raw[model.lineIndex(containing: start)].location
            let end = NSMaxRange(model.raw[lastLine])
            windowStart = start
            prefix = start > 0 ? "\n" : ""
            window = model.text.substring(with: NSRange(location: start, length: end - start))
            originalSignature = Self.signature(of: prefix + window, labels: labels)
        }

        func signature(applying edits: [(range: NSRange, text: String)]) -> [String] {
            let mutable = NSMutableString(string: window)
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                mutable.replaceCharacters(
                    in: NSRange(location: edit.range.location - windowStart, length: edit.range.length),
                    with: edit.text
                )
            }
            return Self.signature(of: prefix + (mutable as String), labels: labels)
        }

        private static func signature(of text: String, labels: Set<String>) -> [String] {
            let ns = text as NSString
            return MarkdownStructureMap.signature(of: ns, scope: NSRange(location: 0, length: ns.length), referenceLabels: labels)
        }
    }
}

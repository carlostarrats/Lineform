import AppKit
import CryptoKit
import SwiftMath

/// Makes a rendered math `NSImage` orientation-stable across graphics contexts.
///
/// SwiftMath's `MathImage.asImage()` returns an `NSImage` that draws correctly (upright) in the
/// flipped `NSTextView` used on screen, but flips vertically in a non-flipped context such as the
/// PDF/print graphics context — leaving block equations upside down in exported PDFs. Rewrapping
/// it as a CGImage-backed `NSImage` (the same technique `MermaidImageOrientation` uses) makes it
/// render identically in both contexts. No flip is applied: SwiftMath is already upright, so its
/// extracted bitmap is used as-is (unlike mermaid, whose raw raster is mirrored).
enum MathImageOrientation {
    static func cgImageBacked(_ image: NSImage) -> NSImage {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return image
        }
        return NSImage(cgImage: cgImage, size: image.size)
    }
}

// MARK: - Delimiter parsing (pure, no rendering)

/// Fence detection for display math blocks: `$$ … $$` and `\[ … \]`.
///
/// The two spellings differ in one way that matters: `$$` opens AND closes, while `\[` opens and
/// only `\]` closes. Every consumer that tracks block state across lines (`markdownBlocks`, the
/// outline, Writing Tools protection, Convert to Plain Text) holds the OPENING `Delimiter` and asks
/// `isClosing(_:of:)`, so a stray `\]` never closes a `$$` block or the reverse.
enum MathBlockFence {
    enum Delimiter: Equatable {
        case dollars    // $$ … $$
        case brackets   // \[ … \]

        var opening: String { self == .dollars ? "$$" : "\\[" }
        var closing: String { self == .dollars ? "$$" : "\\]" }
    }

    /// The delimiter a trimmed line opens a multi-line display block with: a line that is exactly
    /// `$$` or exactly `\[`. A fenced block is ALWAYS math — the explicit-rule heuristic for
    /// backslash delimiters (`MathDelimiters.backslashContentIsMath`) applies only to spans that
    /// open and close on one line, where `\[`/`\(` may just be escaped prose punctuation.
    static func opening(_ trimmedLine: String) -> Delimiter? {
        switch trimmedLine.trimmingCharacters(in: .whitespaces) {
        case "$$": return .dollars
        case "\\[": return .brackets
        default: return nil
        }
    }

    /// True when a trimmed line closes a block opened with `delimiter`.
    static func isClosing(_ trimmedLine: String, of delimiter: Delimiter) -> Bool {
        trimmedLine.trimmingCharacters(in: .whitespaces) == delimiter.closing
    }

    /// For a whole line that is a single display block (`$$…$$` or `\[…\]`), return the inner
    /// LaTeX; else nil. Returns nil when the inner content itself contains `$$` (e.g.
    /// `$$a$$ and $$b$$`), so lines with multiple display spans fall through to the inline path
    /// instead of being swallowed whole.
    ///
    /// The bracket form is decided by `MathDelimiters.inlineSpans` itself — the line is a block
    /// exactly when the inline scanner finds ONE display span covering all of it — so the block
    /// path and the inline path cannot disagree about escapes, closers, or the prose rule.
    static func singleLineBlock(_ trimmedLine: String) -> String? {
        let t = trimmedLine.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\\[") {
            let spans = MathDelimiters.inlineSpans(in: t)
            guard spans.count == 1, let span = spans.first, span.style == .display,
                  span.range == NSRange(location: 0, length: (t as NSString).length) else { return nil }
            return span.latex
        }
        guard t.count >= 5, t.hasPrefix("$$"), t.hasSuffix("$$") else { return nil }
        let inner = String(t.dropFirst(2).dropLast(2))
        guard !inner.isEmpty, !inner.contains("$$") else { return nil }
        return inner
    }
}

/// One inline-math span found in a line: its `NSRange` (UTF-16, including the delimiters), the
/// LaTeX between the delimiters, and whether it is inline (`$…$`, `\(…\)`) or display
/// (`$$…$$`, `\[…\]`) math.
struct MathSpan: Equatable {
    let range: NSRange
    let latex: String
    let style: MathStyle
}

/// Finds inline math spans in a single line using pandoc/GitHub `$` rules so that ordinary
/// prose dollar signs ("$5 to $10") are never treated as math.
///
/// Rules: an opening `$` must be followed by a non-whitespace character; a closing `$` must be
/// preceded by a non-whitespace character and not immediately followed by a digit (this is what
/// keeps "$20 and $30" literal — the opener may precede a digit, but no valid closer exists);
/// `\$` and `\\` are escapes; `$$…$$` is a display span. Spans are ordered and non-overlapping.
///
/// Backslash delimiters (`\(…\)` inline, `\[…\]` display — what ChatGPT and most LaTeX-trained
/// tools emit) are found by the same scan. They collide with CommonMark: `\(` is also an escaped
/// `(`. The explicit rule that resolves it is `backslashContentIsMath`: a backslash span that
/// closes on the same line is math unless its content reads as prose, so `see \(note\)` stays
/// the escaped text "see (note)" while `where \( x \) is` renders an equation.
enum MathDelimiters {
    /// The explicit rule for whether a same-line `\(…\)` / `\[…\]` span is math or escaped
    /// prose punctuation. Math when the trimmed content is non-empty AND either
    ///
    /// - it contains a LaTeX signal — a backslash command, `^`, `_`, `{`, `}`, or `=` — or
    /// - it contains no prose word, i.e. no run of three or more letters.
    ///
    /// So `\(x\)`, `\( f(x) \)`, `\(2n + 1\)` and `\(\alpha\)` are math, while
    /// `\(note\)`, `\(see figure 2\)` and `\[not a link\]` are escaped prose, rendered as
    /// `(note)` etc. A prose-only formula like `\(max(a, b)\)` is the accepted miss: it renders as
    /// its source text, never as a wrong equation. Fenced `\[` / `\]` blocks skip this rule —
    /// a delimiter alone on its own line is unambiguous.
    static func backslashContentIsMath<C: Collection>(_ content: C) -> Bool where C.Element == Character {
        let trimmed = String(content).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: { latexSignals.contains($0) }) { return true }
        var letterRun = 0
        for character in trimmed {
            if character.isLetter {
                letterRun += 1
                if letterRun >= 3 { return false }
            } else {
                letterRun = 0
            }
        }
        return true
    }

    private static let latexSignals: Set<Character> = ["\\", "^", "_", "{", "}", "="]

    static func inlineSpans(in line: String) -> [MathSpan] {
        let chars = Array(line)
        let n = chars.count

        // Precompute the UTF-16 offset of each character index so ranges are correct for
        // multi-unichar characters (emoji, surrogate pairs).
        var utf16At: [Int] = []
        utf16At.reserveCapacity(n + 1)
        var acc = 0
        for c in chars { utf16At.append(acc); acc += String(c).utf16.count }
        utf16At.append(acc)
        func range(_ start: Int, _ endExclusive: Int) -> NSRange {
            NSRange(location: utf16At[start], length: utf16At[endExclusive] - utf16At[start])
        }

        var spans: [MathSpan] = []
        // Once a close-scan has walked to the end of the line without finding a valid closer, no
        // LATER opener can find one either: whether an index closes depends only on its own
        // neighbours, and every close-scan starts at `open + 1` where `chars[open]` is `$` — never
        // mid-backslash-run — so all of them visit the same canonical positions and a later scan
        // covers a strict suffix of an earlier one. Without these flags each unmatched `$` rescans
        // the rest of the line, making a `$`-dense line quadratic; a 20 KB line of dollar signs
        // took seconds on the Writing Tools protection and preview paths.
        var noInlineCloserRemains = false
        var noDisplayCloserRemains = false
        // The same memoization for the backslash forms, one flag per closer. Sound for the same
        // reason: every backslash close-scan starts at `open + 2`, a canonical position.
        var noParenCloserRemains = false
        var noBracketCloserRemains = false
        var i = 0
        while i < n {
            let c = chars[i]
            if c == "\\", i + 1 < n {
                let next = chars[i + 1]
                if next == "(" || next == "[" {
                    let isParen = next == "("
                    let exhausted = isParen ? noParenCloserRemains : noBracketCloserRemains
                    if !exhausted {
                        if let close = backslashClose(chars, from: i + 2, closing: isParen ? ")" : "]") {
                            let inner = chars[(i + 2)..<close]
                            if backslashContentIsMath(inner) {
                                spans.append(MathSpan(range: range(i, close + 2),
                                                      latex: String(inner),
                                                      style: isParen ? .inline : .display))
                                i = close + 2
                                continue
                            }
                            // Prose: fall through and treat `\(` as the escape it also is.
                        } else if isParen {
                            noParenCloserRemains = true
                        } else {
                            noBracketCloserRemains = true
                        }
                    }
                }
                i += 2   // escape: skip the escaped char (handles \$, \\, and declined \( / \[)
                continue
            }
            if c == "$" {
                if i + 1 < n, chars[i + 1] == "$" {
                    // Display `$$…$$`. Whether or not it closes, the `$$` pair is consumed so a
                    // stray second `$` can't start inline math.
                    if !noDisplayCloserRemains, let close = displayClose(chars, from: i + 2) {
                        spans.append(MathSpan(range: range(i, close + 2),
                                              latex: String(chars[(i + 2)..<close]),
                                              style: .display))
                        i = close + 2
                        continue
                    }
                    noDisplayCloserRemains = true
                    i += 2
                    continue
                } else if !noInlineCloserRemains, let close = inlineClose(chars, openAt: i) {
                    spans.append(MathSpan(range: range(i, close + 1),
                                          latex: String(chars[(i + 1)..<close]),
                                          style: .inline))
                    i = close + 1
                    continue
                } else if !noInlineCloserRemains {
                    // Distinguish "this opener was rejected by its own guard" (a whitespace after
                    // the `$`) from "the line has no closer left": only the latter is memoizable,
                    // and `inlineClose` returns nil for both. Re-checking the guard is O(1).
                    let next = i + 1
                    if next < n, !chars[next].isWhitespace {
                        noInlineCloserRemains = true
                    }
                }
            }
            i += 1
        }
        return spans
    }

    /// Given a single opening `$` at `open`, return the index of a valid closing `$`, or nil.
    private static func inlineClose(_ chars: [Character], openAt open: Int) -> Int? {
        let next = open + 1
        guard next < chars.count, !chars[next].isWhitespace else { return nil }

        var j = next
        while j < chars.count {
            if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }   // skip escapes inside math
            if chars[j] == "$" {
                let precededByWhitespace = chars[j - 1].isWhitespace
                let followedByDigit = j + 1 < chars.count && chars[j + 1].isNumber
                if !precededByWhitespace && !followedByDigit { return j }
                // Not a valid closer — keep scanning for a later one (pandoc behavior).
            }
            j += 1
        }
        return nil   // unbalanced → not math
    }

    /// Given a display opener `$$` whose inner text starts at `start`, return the index of the
    /// first `$` of a closing `$$` with non-empty inner content, or nil.
    private static func displayClose(_ chars: [Character], from start: Int) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }
            if chars[j] == "$", chars[j + 1] == "$" {
                return j > start ? j : nil   // require non-empty inner
            }
            j += 1
        }
        return nil
    }

    /// Given a backslash opener whose inner text starts at `start`, return the index of the
    /// backslash of the first `\)` / `\]` (per `closing`), or nil. Escape pairs are skipped in
    /// step, so `\\)` (an escaped backslash, then `)`) is not a closer.
    private static func backslashClose(_ chars: [Character], from start: Int, closing: Character) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "\\" {
                if chars[j + 1] == closing { return j }
                j += 2
                continue
            }
            j += 1
        }
        return nil
    }

    /// Absolute `NSRange`s (including delimiters) of inline math within a line, offset into the
    /// enclosing text. Used to protect math from Writing Tools.
    static func inlineMathRanges(in line: String, lineOffset: Int) -> [NSRange] {
        inlineSpans(in: line).map {
            NSRange(location: $0.range.location + lineOffset, length: $0.range.length)
        }
    }
}

// MARK: - Rendering seam (wraps SwiftMath)

enum MathStyle { case inline, display }

/// Decides whether a math source is safe to attempt rendering (size guard → fallback).
enum MathBlockPolicy {
    static let maxSourceLength = 20_000
    static func shouldAttemptRender(source: String) -> Bool { source.count <= maxSourceLength }
}

/// Stable, compact cache key for a rendered equation, keyed by latex + style + color + scale +
/// point size. `pointSize` must be part of the key: the image is rendered at `fontSize: pointSize`
/// (and its baseline `descent` scales with it), so omitting it collides equations that differ only
/// in reader font size and returns a stale wrong-size raster after a font-size change.
enum MathCacheKey {
    static func key(latex: String, style: MathStyle, foregroundHex: String, scale: CGFloat, pointSize: CGFloat) -> String {
        let styleTag = style == .inline ? "i" : "d"
        let material = "\(styleTag)\n\(scale)\n\(pointSize)\n\(foregroundHex)\n\(latex)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The result of attempting to render a math region. `descent` is the equation's descent
/// below its own baseline (points), used to sit inline math on the surrounding text baseline.
enum MathRenderOutcome {
    case image(NSImage, descent: CGFloat)
    case skipped          // size guard tripped
    case failed(String)   // parse/typeset failure
}

/// Abstracts equation image production so the renderer's fallback path is testable without
/// the library.
protocol MathImageProviding: AnyObject {
    func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome
}

/// A provider that never renders (math falls back to source). Used by the back-compat
/// `render(_:profile:)` convenience and by tests.
final class DisabledMathImageProvider: MathImageProviding {
    func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome {
        .skipped
    }
}

/// The single seam that touches SwiftMath. Every render is defensive: a parse/typeset failure
/// becomes `.failed` → the source fallback, so a broken formula can never break a document.
final class MathImageProvider: MathImageProviding {
    private let cache = NSCache<NSString, CachedMath>()
    private let failureCache = NSCache<NSString, NSString>()

    /// Boxed image + descent so both survive the NSCache round-trip.
    final class CachedMath {
        let image: NSImage
        let descent: CGFloat
        init(image: NSImage, descent: CGFloat) { self.image = image; self.descent = descent }
    }

    init() {
        cache.countLimit = MathCacheBudget.countLimit
        cache.totalCostLimit = MathCacheBudget.totalCostLimitBytes
        failureCache.countLimit = 200
    }

    func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome {
        guard MathBlockPolicy.shouldAttemptRender(source: latex) else { return .skipped }

        let key = MathCacheKey.key(
            latex: latex,
            style: style,
            foregroundHex: MermaidHexColor.string(from: foreground),
            scale: scale,
            pointSize: pointSize
        ) as NSString
        if let cached = cache.object(forKey: key) { return .image(cached.image, descent: cached.descent) }
        if let failure = failureCache.object(forKey: key) { return .failed(failure as String) }

        var mathImage = MathImage(
            latex: latex,
            fontSize: pointSize,
            textColor: foreground,
            labelMode: style == .inline ? .text : .display,
            textAlignment: .left
        )
        let (error, rawImage, layout) = mathImage.asImage()

        if let error {
            let message = error.localizedDescription
            failureCache.setObject(message as NSString, forKey: key)
            return .failed(message)
        }
        guard let rawImage, rawImage.size.width > 0, rawImage.size.height > 0 else {
            // No error but no image: treat as a (non-cached) failure so a later pass can retry.
            return .failed("Math render produced no image")
        }
        // SwiftMath's NSImage draws upright in a flipped view (on-screen Read mode) but flips in a
        // non-flipped context such as the PDF/print graphics context, which left block equations
        // upside down in exported PDFs. Rewrap it as a CGImage-backed image — orientation-stable
        // across contexts (the technique the mermaid path uses), without a flip since SwiftMath is
        // already upright.
        let image = MathImageOrientation.cgImageBacked(rawImage)
        let descent = layout?.descent ?? 0
        cache.setObject(
            CachedMath(image: image, descent: descent),
            forKey: key,
            cost: RasterImageCost.bytes(for: image)
        )
        return .image(image, descent: descent)
    }
}

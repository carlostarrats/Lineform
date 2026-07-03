import AppKit
import CryptoKit
import SwiftMath

// MARK: - Delimiter parsing (pure, no rendering)

/// Fence detection for display (`$$`) math blocks.
enum MathBlockFence {
    /// True when a trimmed line is exactly `$$` (a display-block open/close delimiter).
    static func blockDelimiterOnly(_ trimmedLine: String) -> Bool {
        trimmedLine.trimmingCharacters(in: .whitespaces) == "$$"
    }

    /// For a single-line block `$$…$$`, return the inner LaTeX; else nil.
    static func singleLineBlock(_ trimmedLine: String) -> String? {
        let t = trimmedLine.trimmingCharacters(in: .whitespaces)
        guard t.count >= 5, t.hasPrefix("$$"), t.hasSuffix("$$") else { return nil }
        let inner = t.dropFirst(2).dropLast(2)
        return inner.isEmpty ? nil : String(inner)
    }
}

/// One inline-math span found in a line: its `NSRange` (UTF-16, including the `$`/`$$`
/// delimiters), the LaTeX between the delimiters, and whether it is inline (`$…$`) or
/// display (`$$…$$`) math.
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
enum MathDelimiters {
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
        var i = 0
        while i < n {
            let c = chars[i]
            if c == "\\", i + 1 < n {   // escape: skip the escaped char (handles \$ and \\)
                i += 2
                continue
            }
            if c == "$" {
                if i + 1 < n, chars[i + 1] == "$" {
                    // Display `$$…$$`. Whether or not it closes, the `$$` pair is consumed so a
                    // stray second `$` can't start inline math.
                    if let close = displayClose(chars, from: i + 2) {
                        spans.append(MathSpan(range: range(i, close + 2),
                                              latex: String(chars[(i + 2)..<close]),
                                              style: .display))
                        i = close + 2
                        continue
                    }
                    i += 2
                    continue
                } else if let close = inlineClose(chars, openAt: i) {
                    spans.append(MathSpan(range: range(i, close + 1),
                                          latex: String(chars[(i + 1)..<close]),
                                          style: .inline))
                    i = close + 1
                    continue
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

/// Stable, compact cache key for a rendered equation, keyed by latex + style + color + scale.
enum MathCacheKey {
    static func key(latex: String, style: MathStyle, foregroundHex: String, scale: CGFloat) -> String {
        let styleTag = style == .inline ? "i" : "d"
        let material = "\(styleTag)\n\(scale)\n\(foregroundHex)\n\(latex)"
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
        cache.countLimit = 100
        failureCache.countLimit = 200
    }

    func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome {
        guard MathBlockPolicy.shouldAttemptRender(source: latex) else { return .skipped }

        let key = MathCacheKey.key(
            latex: latex,
            style: style,
            foregroundHex: MermaidHexColor.string(from: foreground),
            scale: scale
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
        let (error, image, layout) = mathImage.asImage()

        if let error {
            let message = error.localizedDescription
            failureCache.setObject(message as NSString, forKey: key)
            return .failed(message)
        }
        guard let image, image.size.width > 0, image.size.height > 0 else {
            // No error but no image: treat as a (non-cached) failure so a later pass can retry.
            return .failed("Math render produced no image")
        }
        let descent = layout?.descent ?? 0
        cache.setObject(CachedMath(image: image, descent: descent), forKey: key)
        return .image(image, descent: descent)
    }
}

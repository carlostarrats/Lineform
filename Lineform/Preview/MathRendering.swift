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

/// One ordered piece of a line: literal text or an inline-math expression.
struct MathInlineSegment: Equatable {
    enum Kind { case text, math }
    let kind: Kind
    let value: String
}

/// Splits a line into text/inline-math segments using GitHub/CommonMark `$` rules so that
/// ordinary prose dollar signs ("$5") are never treated as math.
///
/// Rules: an opening `$` must not be followed by whitespace; a closing `$` must not be
/// preceded by whitespace; a `$` adjacent to a digit does not delimit math; `\$` is a
/// literal dollar; anything that does not cleanly open-and-close stays literal text.
enum MathDelimiters {
    static func segments(in line: String) -> [MathInlineSegment] {
        let chars = Array(line)
        var segments: [MathInlineSegment] = []
        var text = ""
        var i = 0

        func flushText() {
            if !text.isEmpty {
                segments.append(MathInlineSegment(kind: .text, value: text))
                text = ""
            }
        }

        while i < chars.count {
            let c = chars[i]
            // \$ is a literal dollar.
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                text.append("\\")
                text.append("$")
                i += 2
                continue
            }
            if c == "$", let close = closingIndex(chars, openAt: i) {
                flushText()
                let latex = String(chars[(i + 1)..<close])
                segments.append(MathInlineSegment(kind: .math, value: latex))
                i = close + 1
                continue
            }
            text.append(c)
            i += 1
        }
        flushText()
        return segments
    }

    /// Given an opening `$` at `open`, return the index of a valid closing `$`, or nil.
    private static func closingIndex(_ chars: [Character], openAt open: Int) -> Int? {
        // Opening `$` must be followed by a non-whitespace, non-`$` character.
        let next = open + 1
        guard next < chars.count, !chars[next].isWhitespace else { return nil }
        if chars[next] == "$" { return nil }
        // A `$` adjacent to a digit does not open math ("$5", "10$").
        if open > 0, chars[open - 1].isNumber { return nil }
        if chars[next].isNumber { return nil }

        var j = next
        while j < chars.count {
            if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }   // skip escapes inside math
            if chars[j] == "$" {
                // Closing `$` must not be preceded by whitespace, nor followed by a digit.
                if chars[j - 1].isWhitespace { return nil }
                if j + 1 < chars.count, chars[j + 1].isNumber { return nil }
                return j
            }
            j += 1
        }
        return nil   // unbalanced → not math
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

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

// MARK: - Rendering seam (wraps SwiftMath)

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

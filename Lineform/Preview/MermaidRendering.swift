import AppKit
import BeautifulMermaid
import CryptoKit

/// Converts an NSColor to a `#rrggbb` hex string for BeautifulMermaid's two-color mono theme.
enum MermaidHexColor {
    static func string(from color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

/// Fence info-string detection for the preview renderer.
enum MermaidFence {
    /// True when a trimmed fence line opens a mermaid block (```mermaid or ~~~mermaid).
    static func isMermaidOpening(_ trimmedLine: String) -> Bool {
        let marker: String
        if trimmedLine.hasPrefix("```") { marker = "```" }
        else if trimmedLine.hasPrefix("~~~") { marker = "~~~" }
        else { return false }
        let info = trimmedLine.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).lowercased()
        return info == "mermaid"
    }

    /// True when a trimmed line is any closing/opening fence delimiter.
    static func isFenceDelimiter(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
    }
}

/// Decides whether a mermaid block is safe to attempt rendering (size guard → fallback).
enum MermaidBlockPolicy {
    static let maxSourceLength = 20_000

    static func shouldAttemptRender(source: String) -> Bool {
        source.count <= maxSourceLength
    }
}

/// Stable, compact cache key for a rendered diagram, keyed by source + theme + scale.
enum MermaidCacheKey {
    static func key(source: String, backgroundHex: String, foregroundHex: String, scale: CGFloat) -> String {
        let material = "\(scale)\n\(backgroundHex)\n\(foregroundHex)\n\(source)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Corrects the orientation of a diagram raster produced by BeautifulMermaid on macOS.
///
/// BeautifulMermaid 1.0.4's AppKit path (`MermaidImageRenderer._renderPrepared`) draws into a
/// raw `CGContext` bitmap, which has a bottom-left origin (y-up), while the library's drawing
/// code is written for a top-left origin (y-down, the UIKit/`UIGraphicsImageRenderer` convention
/// it also targets). No compensating y-flip is inserted, so on macOS every rendered diagram comes
/// back vertically mirrored — layout upside down and text mirrored. The library is a pinned remote
/// dependency and this is the single seam that touches it, so we flip the finished raster upright
/// here rather than forking the package.
enum MermaidImageOrientation {
    static func uprightForMacOS(_ image: NSImage) -> NSImage {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return image
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let ctx = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return image }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let flipped = ctx.makeImage() else { return image }
        // Preserve the point size so Retina scale (pixels-per-point) is retained.
        return NSImage(cgImage: flipped, size: image.size)
    }
}

/// The result of attempting to render a mermaid block.
enum MermaidRenderOutcome {
    case image(NSImage)
    case skipped          // size guard tripped
    case failed(String)   // render threw or produced no image
}

/// Abstracts diagram image production so the preview renderer's fallback path is testable
/// without the library.
protocol MermaidImageProviding: AnyObject {
    func outcome(source: String, background: NSColor, foreground: NSColor, scale: CGFloat) -> MermaidRenderOutcome
}

/// A provider that never renders (mermaid blocks fall back to captioned source). Used by the
/// back-compat `render(_:profile:)` convenience and by tests.
final class DisabledMermaidImageProvider: MermaidImageProviding {
    func outcome(source: String, background: NSColor, foreground: NSColor, scale: CGFloat) -> MermaidRenderOutcome {
        .skipped
    }
}

/// The single seam that touches BeautifulMermaid. Every render is defensive (do/catch) so any
/// library failure degrades to `.failed` → the captioned-source fallback.
final class MermaidImageProvider: MermaidImageProviding {
    private let cache = NSCache<NSString, NSImage>()
    /// Failed sources are remembered too (key → error), so a broken diagram isn't re-parsed
    /// on every preview pass while the user types elsewhere in the document.
    private let failureCache = NSCache<NSString, NSString>()

    init() {
        cache.countLimit = 50
        failureCache.countLimit = 200
    }

    func outcome(source: String, background: NSColor, foreground: NSColor, scale: CGFloat) -> MermaidRenderOutcome {
        guard MermaidBlockPolicy.shouldAttemptRender(source: source) else { return .skipped }

        let key = MermaidCacheKey.key(
            source: source,
            backgroundHex: MermaidHexColor.string(from: background),
            foregroundHex: MermaidHexColor.string(from: foreground),
            scale: scale
        ) as NSString
        if let cached = cache.object(forKey: key) { return .image(cached) }
        if let failure = failureCache.object(forKey: key) { return .failed(failure as String) }

        do {
            let theme = DiagramTheme(background: background, foreground: foreground)
            if let image = try MermaidRenderer.renderImage(source: source, theme: theme, scale: scale) {
                let upright = MermaidImageOrientation.uprightForMacOS(image)
                cache.setObject(upright, forKey: key)
                return .image(upright)
            }
            // Not negatively cached: producing no image without an error may be transient
            // (resource pressure), so a later pass should retry.
            return .failed("Mermaid render produced no image")
        } catch {
            // Thrown errors are deterministic parse/render failures for this exact source;
            // cache them so a broken diagram isn't re-parsed on every preview pass.
            let message = String(describing: error)
            failureCache.setObject(message as NSString, forKey: key)
            return .failed(message)
        }
    }
}

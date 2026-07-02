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

    func outcome(source: String, background: NSColor, foreground: NSColor, scale: CGFloat) -> MermaidRenderOutcome {
        guard MermaidBlockPolicy.shouldAttemptRender(source: source) else { return .skipped }

        let key = MermaidCacheKey.key(
            source: source,
            backgroundHex: MermaidHexColor.string(from: background),
            foregroundHex: MermaidHexColor.string(from: foreground),
            scale: scale
        ) as NSString
        if let cached = cache.object(forKey: key) { return .image(cached) }

        do {
            let theme = DiagramTheme(background: background, foreground: foreground)
            if let image = try MermaidRenderer.renderImage(source: source, theme: theme, scale: scale) {
                cache.setObject(image, forKey: key)
                return .image(image)
            }
            return .failed("Mermaid render produced no image")
        } catch {
            return .failed(String(describing: error))
        }
    }
}

import BeautifulMermaid
import CryptoKit
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Converts a colour to a `#rrggbb` hex string for BeautifulMermaid's two-color mono theme.
enum MermaidHexColor {
    static func string(from color: PlatformColor) -> String {
        // macOS: `(color.usingColorSpace(.sRGB) ?? color)`'s components, as always.
        let rgb = color.lineformSRGBComponentsOrOwn
        let r = Int((rgb.red * 255).rounded())
        let g = Int((rgb.green * 255).rounded())
        let b = Int((rgb.blue * 255).rounded())
        return String(format: "#%02x%02x%02x", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
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
/// Returns nil rather than the input when the flip cannot be performed. Handing back the
/// un-flipped image would put a MIRRORED diagram on screen — the one outcome this type exists to
/// prevent — and the allocation only fails for rasters big enough that a retry is the right
/// answer. The caller treats nil as a transient failure.
///
/// macOS only: the library's UIKit path draws through `UIGraphicsImageRenderer`, whose origin is
/// top-left, so iOS output is already upright and gets no orientation pass.
#if os(macOS)
enum MermaidImageOrientation {
    static func uprightForMacOS(_ image: NSImage) -> NSImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let ctx = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let flipped = ctx.makeImage() else { return nil }
        // Preserve the point size so Retina scale (pixels-per-point) is retained.
        return NSImage(cgImage: flipped, size: image.size)
    }
}
#endif

/// The result of attempting to render a mermaid block.
public enum MermaidRenderOutcome {
    case image(PlatformImage)
    case skipped               // size guard tripped
    case unsupported(String)   // recognized-but-unrenderable type (e.g. "gantt"); clean fallback, no report/log
    case failed(String)        // render threw or produced no image
}

/// Abstracts diagram image production so the preview renderer's fallback path is testable
/// without the library.
public protocol MermaidImageProviding: AnyObject {
    func outcome(source: String, background: PlatformColor, foreground: PlatformColor, scale: CGFloat) -> MermaidRenderOutcome
}

/// A provider that never renders (mermaid blocks fall back to captioned source). Used by the
/// back-compat `render(_:profile:)` convenience and by tests.
public final class DisabledMermaidImageProvider: MermaidImageProviding {
    public init() {}

    public func outcome(source: String, background: PlatformColor, foreground: PlatformColor, scale: CGFloat) -> MermaidRenderOutcome {
        .skipped
    }
}

/// The single seam that touches BeautifulMermaid. Every render is defensive (do/catch) so any
/// library failure degrades to `.failed` → the captioned-source fallback.
public final class MermaidImageProvider: MermaidImageProviding {
    private let cache = NSCache<NSString, PlatformImage>()
    /// Failed sources are remembered too (key → error), so a broken diagram isn't re-parsed
    /// on every preview pass while the user types elsewhere in the document.
    private let failureCache = NSCache<NSString, NSString>()

    public init() {
        cache.countLimit = DiagramCacheBudget.countLimit
        cache.totalCostLimit = DiagramCacheBudget.totalCostLimitBytes
        failureCache.countLimit = 200
    }

    public func outcome(source: String, background: PlatformColor, foreground: PlatformColor, scale: CGFloat) -> MermaidRenderOutcome {
        guard MermaidBlockPolicy.shouldAttemptRender(source: source) else { return .skipped }

        let kind = MermaidTypeClassifier.classify(source)
        if kind == .unsupported { return .unsupported("unsupported mermaid type") }

        let key = MermaidCacheKey.key(
            source: source,
            backgroundHex: MermaidHexColor.string(from: background),
            foregroundHex: MermaidHexColor.string(from: foreground),
            scale: scale
        ) as NSString
        if let cached = cache.object(forKey: key) { return .image(cached) }
        if let failure = failureCache.object(forKey: key) { return .failed(failure as String) }

        if kind == .pie {
            guard let model = MermaidPieChart.parse(source) else { return .unsupported("malformed pie") }
            guard let image = MermaidPieRenderer.image(model: model, background: background,
                                                       foreground: foreground, scale: scale) else {
                return .failed("Pie render produced no image")   // transient; not neg-cached
            }
            cache.setObject(image, forKey: key, cost: RasterImageCost.bytes(for: image))
            return .image(image)
        }

        // .supported → BeautifulMermaid (existing do/catch, unchanged).
        do {
            let theme = DiagramTheme(background: background, foreground: foreground)
            // Front matter stripped at the seam: BeautifulMermaid throws `invalidHeader("---")`
            // on it, and the classifier that decided this block is `.supported` looked PAST it.
            let renderable = MermaidSource.withoutFrontMatter(source)
            if let image = try MermaidRenderer.renderImage(source: renderable, theme: theme, scale: scale) {
                #if os(macOS)
                guard let upright = MermaidImageOrientation.uprightForMacOS(image) else {
                    // The flip's context allocation failed (a huge raster under memory pressure).
                    // Returning the un-flipped image would draw the diagram MIRRORED; a transient
                    // failure that retries later is the honest outcome.
                    return .failed("Mermaid orientation pass could not allocate")
                }
                #else
                // The library's UIKit output is already upright (top-left origin).
                let upright = image
                #endif
                cache.setObject(upright, forKey: key, cost: RasterImageCost.bytes(for: upright))
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

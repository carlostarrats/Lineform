import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Approximate RGBA byte footprint of an image's backing raster (pixels × 4). Used as the
/// `NSCache` cost so the diagram/equation caches are bounded by MEMORY, not a flat count — a
/// large flowchart weighs far more than a tiny inline equation and should evict accordingly.
enum RasterImageCost {
    static func bytes(for image: PlatformImage) -> Int {
        #if os(macOS)
        var proposed = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            return max(1, cg.width * cg.height * 4)
        }
        // No CGImage available: assume a 2× (Retina) backing store from the point size.
        let w = max(1, Int(image.size.width.rounded()))
        let h = max(1, Int(image.size.height.rounded()))
        return max(1, w * h * 4 * 4)
        #else
        if let cg = image.cgImage {
            return max(1, cg.width * cg.height * 4)
        }
        // No CGImage available: the point size at the image's own scale.
        let w = max(1, Int(image.size.width.rounded()))
        let h = max(1, Int(image.size.height.rounded()))
        return max(1, Int((CGFloat(w * h) * image.scale * image.scale * 4).rounded()))
        #endif
    }
}

/// Memory-sized bounds for the rendered-diagram cache. `NSCache` honors both limits and evicts
/// when either is exceeded; `totalCostLimitBytes` (with a per-image cost of `RasterImageCost`)
/// is the real governor, so a diagram-heavy document keeps its diagrams cached instead of
/// thrashing against the old flat count of 50.
enum DiagramCacheBudget {
    static let countLimit = 512
    static let totalCostLimitBytes = 128 * 1024 * 1024   // 128 MB ceiling
}

/// Memory-sized bounds for the rendered-equation cache (equations are individually small, so the
/// count is generous and the byte ceiling comfortably holds a math-heavy document).
enum MathCacheBudget {
    static let countLimit = 1024
    static let totalCostLimitBytes = 64 * 1024 * 1024    // 64 MB ceiling
}

/// Memory-sized bounds for the block-image attachment cache (downscaled rasters of local files
/// referenced by `![alt](path)`), sibling of `DiagramCacheBudget`/`MathCacheBudget`.
enum ImageCacheBudget {
    static let countLimit = 256
    static let totalCostLimitBytes = 128 * 1024 * 1024   // 128 MB ceiling
}

/// Marks a full-width BLOCK diagram/equation attachment (as opposed to an inline math attachment),
/// so the resize refit rescales only block content and never disturbs inline math's baseline. A
/// bare subclass with no overrides — it behaves identically to `NSTextAttachment` in every other
/// respect (accessibility, copy, layout).
public final class BlockRenderedAttachment: NSTextAttachment {
    /// True only for block-image attachments (`appendImageBlock`). When true, the resize refit
    /// path additionally clamps the attachment's HEIGHT to the real viewport's cap
    /// (`ImageFit.maxHeight`), so a tall image shrinks to fit a short window. Mermaid/math
    /// attachments leave this false and are refit by width only, unchanged.
    public var appliesViewportHeightCap = false
}

/// Pure geometry for the resize refit nit: given a block attachment's natural raster size, its
/// current bounds, and the available fit width, return the bounds it should adopt — or nil when
/// nothing changes. Scales the raster to the fit width preserving aspect ratio, never upscales
/// past the natural size, and preserves the baseline origin (inline math sits on the text
/// baseline via a `-descent` y-offset, which must survive a resize). `maxHeight` (default
/// `.infinity`, i.e. no cap — byte-identical to the pre-existing behavior for callers that don't
/// pass it, namely mermaid/math) additionally downscales the fitted size, aspect preserved, so
/// the resulting height never exceeds it — used only for block images, which must shrink on a
/// short window per the viewport-adaptive height cap.
public enum BlockAttachmentRefit {
    public static func refittedBounds(
        naturalSize: CGSize,
        currentBounds: CGRect,
        fitWidth: CGFloat,
        maxHeight: CGFloat = .infinity
    ) -> CGRect? {
        guard naturalSize.width > 0 else { return nil }
        let target = min(naturalSize.width, max(fitWidth, 1))
        var width = target
        var height = naturalSize.height * (target / naturalSize.width)
        if height > maxHeight, maxHeight.isFinite, maxHeight > 0 {
            let scale = maxHeight / height
            width *= scale
            height = maxHeight
        }
        guard abs(currentBounds.width - width) > 0.5 || abs(currentBounds.height - height) > 0.5 else { return nil }
        return CGRect(x: 0, y: currentBounds.origin.y, width: width, height: height)
    }
}

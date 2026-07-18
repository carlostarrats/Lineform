import AppKit

/// Approximate RGBA byte footprint of an image's backing raster (pixels × 4). Used as the
/// `NSCache` cost so the diagram/equation caches are bounded by MEMORY, not a flat count — a
/// large flowchart weighs far more than a tiny inline equation and should evict accordingly.
enum RasterImageCost {
    static func bytes(for image: NSImage) -> Int {
        var proposed = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            return max(1, cg.width * cg.height * 4)
        }
        // No CGImage available: assume a 2× (Retina) backing store from the point size.
        let w = max(1, Int(image.size.width.rounded()))
        let h = max(1, Int(image.size.height.rounded()))
        return max(1, w * h * 4 * 4)
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

/// Fixed two-variant INK for block MATH, keyed only on light-vs-dark (never the specific theme) so
/// block math — which renders transparent — never re-renders on a theme switch. Block Mermaid
/// diagrams instead use the actual per-theme page color (they must, so Mermaid's node boxes get a
/// solid fill that matches every theme); the memory-sized cache keeps that affordable. Inline math
/// is unaffected (fully theme-aware).
enum DiagramPalette {
    /// Ink for block math: the Original theme's text on light themes, the Quiet theme's on dark
    /// themes — so dark ink only ever lands on a light page and light ink only on a dark page. (All
    /// light themes share the Original text color and both dark themes are near-identical, so this
    /// matches surrounding prose on every theme while staying theme-independent.)
    static func ink(isDark: Bool) -> NSColor {
        (isDark ? Theme.quiet : Theme.system).textColor
    }
}

/// Muted, monochrome-leaning token colors for fenced-code highlighting in Read/Preview. Derived
/// from the theme (light/dark aware), restrained so code reads calm rather than rainbow. `.plain`
/// reuses the theme's own text color (unchanged code foreground). Every colored role is AA-verified
/// against every `Theme.builtIn` background (`CodeSyntaxPaletteContrastTests`). Display-only.
enum CodeSyntaxPalette {
    static func color(for kind: CodeTokenKind, theme: Theme) -> NSColor {
        let dark = theme.usesDarkChrome
        switch kind {
        case .plain:
            return theme.textColor
        case .keyword:
            // A muted plum/violet — the one role allowed a little hue.
            return dark ? NSColor(srgbRed: 0.78, green: 0.62, blue: 0.86, alpha: 1)
                        : NSColor(srgbRed: 0.42, green: 0.24, blue: 0.55, alpha: 1)
        case .string:
            // Muted green.
            return dark ? NSColor(srgbRed: 0.55, green: 0.80, blue: 0.60, alpha: 1)
                        : NSColor(srgbRed: 0.16, green: 0.44, blue: 0.24, alpha: 1)
        case .comment:
            // Low-chroma grey — deliberately the quietest role, still AA.
            return dark ? NSColor(srgbRed: 0.68, green: 0.70, blue: 0.70, alpha: 1)
                        : NSColor(srgbRed: 0.42, green: 0.44, blue: 0.44, alpha: 1)
        case .number:
            // Muted amber/brown.
            return dark ? NSColor(srgbRed: 0.85, green: 0.70, blue: 0.48, alpha: 1)
                        : NSColor(srgbRed: 0.55, green: 0.38, blue: 0.12, alpha: 1)
        case .type:
            // Muted teal/blue.
            return dark ? NSColor(srgbRed: 0.55, green: 0.76, blue: 0.82, alpha: 1)
                        : NSColor(srgbRed: 0.15, green: 0.40, blue: 0.50, alpha: 1)
        }
    }
}

/// Marks a full-width BLOCK diagram/equation attachment (as opposed to an inline math attachment),
/// so the resize refit rescales only block content and never disturbs inline math's baseline. A
/// bare subclass with no overrides — it behaves identically to `NSTextAttachment` in every other
/// respect (accessibility, copy, layout).
final class BlockRenderedAttachment: NSTextAttachment {}

/// Pure geometry for the resize refit nit: given a block attachment's natural raster size, its
/// current bounds, and the available fit width, return the bounds it should adopt — or nil when
/// nothing changes. Scales the raster to the fit width preserving aspect ratio, never upscales
/// past the natural size, and preserves the baseline origin (inline math sits on the text
/// baseline via a `-descent` y-offset, which must survive a resize).
enum BlockAttachmentRefit {
    static func refittedBounds(naturalSize: CGSize, currentBounds: CGRect, fitWidth: CGFloat) -> CGRect? {
        guard naturalSize.width > 0 else { return nil }
        let target = min(naturalSize.width, max(fitWidth, 1))
        guard abs(currentBounds.width - target) > 0.5 else { return nil }
        let height = naturalSize.height * (target / naturalSize.width)
        return CGRect(x: 0, y: currentBounds.origin.y, width: target, height: height)
    }
}

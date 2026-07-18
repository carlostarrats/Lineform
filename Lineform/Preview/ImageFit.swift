import CoreGraphics

/// Pure sizing helpers for block-level inline images: the height cap and the
/// downscale-only fit box. No AppKit image loading here.
enum ImageFit {
    /// Max block-image HEIGHT in points: hard 500pt ceiling, 0.70×viewport shrink on
    /// smaller windows, 240pt floor for very short windows.
    static func maxHeight(visibleViewportHeight: CGFloat) -> CGFloat {
        max(240, min(500, 0.70 * visibleViewportHeight))
    }

    /// Fitted size for `native` scaled DOWN to fit within `maxSize` (both width ≤ and
    /// height ≤), aspect ratio preserved. Returns `native` unchanged when it already
    /// fits — this never upscales.
    static func size(for native: CGSize, in maxSize: CGSize) -> CGSize {
        guard native.width > 0, native.height > 0 else { return native }
        let scale = min(1, maxSize.width / native.width, maxSize.height / native.height)
        return CGSize(width: native.width * scale, height: native.height * scale)
    }
}

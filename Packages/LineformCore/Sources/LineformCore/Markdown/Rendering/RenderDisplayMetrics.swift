import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The display values the renderer rasterizes for: the backing scale of diagram, math and image
/// rasters, and the visible viewport height that caps a block image's height.
public struct RenderDisplayMetrics: Equatable, Sendable {
    public var scale: CGFloat
    public var visibleViewportHeight: CGFloat

    public init(scale: CGFloat, visibleViewportHeight: CGFloat) {
        self.scale = scale
        self.visibleViewportHeight = visibleViewportHeight
    }

    /// The current display. COMPUTED, not stored: on macOS it re-reads `NSScreen.main` on every
    /// access, so a render after the window moves to a screen of another scale rasterizes for
    /// that screen. A cached value would draw blurry diagrams on a Retina screen after launch on
    /// a non-Retina one.
    ///
    /// macOS: `NSScreen.main?.backingScaleFactor ?? 2` and `NSScreen.main?.visibleFrame.height
    /// ?? 900`, the renderer's expressions and fallbacks. iOS: scale 3 and an 844-point viewport
    /// until the iPhone Read view passes its real values.
    @MainActor
    public static var current: RenderDisplayMetrics {
        #if os(macOS)
        RenderDisplayMetrics(
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            visibleViewportHeight: NSScreen.main?.visibleFrame.height ?? 900
        )
        #else
        RenderDisplayMetrics(scale: 3, visibleViewportHeight: 844)
        #endif
    }
}

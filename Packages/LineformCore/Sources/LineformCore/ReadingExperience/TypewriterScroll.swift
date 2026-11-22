import CoreGraphics

/// Typewriter mode's scroll maths: the scroll origin that keeps the caret line at the vertical
/// centre of the visible area. Moved from the Mac app's
/// `LineformTextView.typewriterScrollOrigin(for:visibleBounds:)`, which forwards here with an
/// unbounded content height so its result is unchanged.
public enum TypewriterScroll {
    /// The origin that centres `caretRect` vertically in `visibleBounds`, keeping the horizontal
    /// origin. Never above the top (0), and never past the end of `contentHeight`
    /// (`contentHeight − visibleBounds.height`). Pass `.greatestFiniteMagnitude` for no end limit.
    public static func origin(for caretRect: CGRect, visibleBounds: CGRect, contentHeight: CGFloat) -> CGPoint {
        let centred = caretRect.midY - visibleBounds.height / 2
        let maximum = max(0, contentHeight - visibleBounds.height)
        return CGPoint(x: visibleBounds.origin.x, y: max(0, min(centred, maximum)))
    }
}

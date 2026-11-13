import AppKit

/// The per-change pill at the end of each suggested change (spec §4.1, owner-approved):
/// outline only, ✓ on the left, a thin vertical divider whose ends stop 1pt short of the
/// outline's inner top and bottom, ✕ on the right — all monotone in one ink, no fill.
///
/// Drawn as geometry and activated by hit-testing in `AIReviewTextView`, so assistive tech
/// reaches the same decisions through that view's `accessibilityCustomActions`.
final class AIReviewPillCell: NSTextAttachmentCell {
    enum Part: Equatable { case accept, reject }

    /// The pill's own box. The cell is `leadingGap` wider, so the pill never touches the change.
    nonisolated static let size = NSSize(width: 38, height: 18)
    nonisolated static let leadingGap: CGFloat = 3
    static let outlineWidth: CGFloat = 1
    static let dividerWidth: CGFloat = 0.75
    /// How far the divider's ends stop short of the outline's inner edge.
    static let dividerInset: CGFloat = 1
    static let symbolPointSize: CGFloat = 9

    let changeID: Int
    let isCurrent: Bool
    let ink: NSColor
    /// Vertical offset from the text baseline, so the pill sits centred on the line's capitals.
    /// Set by the overlay from the document font.
    // Read by AppKit's nonisolated layout callbacks; written only on the main thread before layout.
    nonisolated(unsafe) var baselineOffsetY: CGFloat = -4

    init(changeID: Int, isCurrent: Bool, ink: NSColor) {
        self.changeID = changeID
        self.isCurrent = isCurrent
        self.ink = ink
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        changeID = -1
        isCurrent = false
        ink = .textColor
        super.init(coder: coder)
    }

    // MARK: - Geometry

    /// The pill's box inside a cell frame: past the leading gap, `size` big.
    static func outlineRect(in cellFrame: NSRect) -> NSRect {
        NSRect(x: cellFrame.minX + leadingGap, y: cellFrame.midY - size.height / 2,
               width: size.width, height: size.height)
    }

    /// The centre divider: `dividerWidth` wide, its ends `dividerInset` short of the outline's
    /// inner top and bottom (the 1pt stroke sits inside the box).
    static func dividerRect(in cellFrame: NSRect) -> NSRect {
        let inner = outlineRect(in: cellFrame).insetBy(dx: outlineWidth, dy: outlineWidth)
        return NSRect(x: inner.midX - dividerWidth / 2, y: inner.minY + dividerInset,
                      width: dividerWidth, height: inner.height - dividerInset * 2)
    }

    /// Left of the divider (and the leading gap) accepts; right of it rejects.
    func part(at point: NSPoint, in cellFrame: NSRect) -> Part {
        point.x < Self.outlineRect(in: cellFrame).midX ? .accept : .reject
    }

    // MARK: - NSTextAttachmentCell

    override func cellSize() -> NSSize {
        NSSize(width: Self.size.width + Self.leadingGap, height: Self.size.height)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: baselineOffsetY)
    }

    override func wantsToTrackMouse() -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let outline = Self.outlineRect(in: cellFrame)
        let stroke = outline.insetBy(dx: Self.outlineWidth / 2, dy: Self.outlineWidth / 2)
        let path = NSBezierPath(roundedRect: stroke, xRadius: stroke.height / 2, yRadius: stroke.height / 2)
        path.lineWidth = Self.outlineWidth
        ink.setStroke()
        path.stroke()

        ink.setFill()
        Self.dividerRect(in: cellFrame).fill()

        let flipped = controlView?.isFlipped ?? false
        let quarter = outline.width / 4
        drawSymbol("checkmark", centeredAt: NSPoint(x: outline.minX + quarter, y: outline.midY), flipped: flipped)
        drawSymbol("xmark", centeredAt: NSPoint(x: outline.maxX - quarter, y: outline.midY), flipped: flipped)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    private func drawSymbol(_ name: String, centeredAt center: NSPoint, flipped: Bool) {
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        // Monotone: the symbol's shape, filled with the pill's one ink.
        let tinted = NSImage(size: size, flipped: false) { [ink] rect in
            symbol.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let rect = NSRect(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: flipped, hints: nil)
    }
}

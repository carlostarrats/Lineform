import AppKit

/// A quiet, full-width horizontal rule rendered inside the read text view. Uses an attachment
/// cell (not the image-based `BlockRenderedAttachment`) so it spans the current line-fragment
/// width automatically on every relayout — no aspect-ratio refit, which would collapse a hairline.
/// The line is drawn low-contrast and centered in a tall-ish cell so it reads as a calm section
/// break with breathing room, not a heavy bar.
final class HorizontalRuleAttachment: NSTextAttachment {
    /// `@MainActor` because the cell it installs is an `NSCell` subclass, which is main-actor
    /// isolated — building one from a nonisolated context is a Swift 6 error (a warning today)
    /// and would be a genuine data race if rendering ever moved off the main thread. Every
    /// caller is already on the main actor (`MarkdownPreviewRenderer` runs from view code).
    @MainActor
    init(color: NSColor, height: CGFloat) {
        super.init(data: nil, ofType: nil)
        attachmentCell = HorizontalRuleAttachmentCell(color: color, height: height)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

private final class HorizontalRuleAttachmentCell: NSTextAttachmentCell {
    private let color: NSColor
    private let height: CGFloat

    init(color: NSColor, height: CGFloat) {
        self.color = color
        self.height = height
        super.init()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        // Fill the available line-fragment width; a fixed height gives vertical breathing room.
        NSRect(x: 0, y: 0, width: max(1, lineFrag.width), height: height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {
        let y = (cellFrame.minY + cellFrame.maxY) / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cellFrame.minX, y: y))
        path.line(to: NSPoint(x: cellFrame.maxX, y: y))
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }
}

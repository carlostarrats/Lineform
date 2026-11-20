#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A quiet, full-width horizontal rule rendered inside the read text view. Uses an attachment
/// cell (not the image-based `BlockRenderedAttachment`) so it spans the current line-fragment
/// width automatically on every relayout — no aspect-ratio refit, which would collapse a hairline.
/// The line is drawn low-contrast and centered in a tall-ish cell so it reads as a calm section
/// break with breathing room, not a heavy bar.
///
/// iOS has no attachment cells: the attachment itself reports the line-fragment width and draws
/// the same 1-point line across its vertical middle.
public final class HorizontalRuleAttachment: NSTextAttachment {
    #if os(macOS)
    /// `@MainActor` because the cell it installs is an `NSCell` subclass, which is main-actor
    /// isolated — building one from a nonisolated context is a Swift 6 error (a warning today)
    /// and would be a genuine data race if rendering ever moved off the main thread. Every
    /// caller is already on the main actor (`MarkdownPreviewRenderer` runs from view code).
    @MainActor
    init(color: PlatformColor, height: CGFloat) {
        super.init(data: nil, ofType: nil)
        attachmentCell = HorizontalRuleAttachmentCell(color: color, height: height)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    #else
    private let color: PlatformColor
    private let height: CGFloat

    /// `@MainActor` to match the Mac initializer; every caller is on the main actor.
    @MainActor
    init(color: PlatformColor, height: CGFloat) {
        self.color = color
        self.height = height
        super.init(data: nil, ofType: nil)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        // Fill the available line-fragment width; a fixed height gives vertical breathing room.
        CGRect(x: 0, y: 0, width: max(1, lineFrag.width), height: height)
    }

    public override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> UIImage? {
        let size = CGSize(width: max(1, imageBounds.width), height: max(1, imageBounds.height))
        let color = self.color
        return UIGraphicsImageRenderer(size: size).image { _ in
            let y = size.height / 2
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            path.lineWidth = 1
            color.setStroke()
            path.stroke()
        }
    }
    #endif
}

#if os(macOS)
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
#endif

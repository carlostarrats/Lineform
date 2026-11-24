import AppKit
import LineformCore

/// The highlighter selection (`HighlighterSelection`) for the Mac's TextKit 1 text views: the
/// editor (`LineformTextView`) and Read/Preview (`MarkdownPreviewTextView`).
///
/// AppKit's own selection fill is made clear (`selectedTextAttributes`) and the strokes are
/// painted in `drawBackground(in:)`, so they sit BEHIND the glyphs and never touch the text
/// storage — copy, undo, autosave and the file never see them. Selection behaviour itself
/// (dragging, ⇧-arrows, Find, services, the inactive state) is AppKit's, unchanged.
///
/// Cost: only the visible part of the selection is walked (`HighlighterSelectionLayout`), and a
/// selection change invalidates only the lines whose stroke changed, so a drag over a 1 MB
/// document repaints what a native selection would.
@MainActor
enum HighlighterSelectionDrawing {
    /// AppKit's selection fill, made clear: the stroke drawn behind the text replaces it. The
    /// selected text keeps its own ink.
    static let clearSelectedTextAttributes: [NSAttributedString.Key: Any] = [.backgroundColor: NSColor.clear]

    /// Whether macOS asks for more contrast (System Settings ▸ Accessibility ▸ Display).
    static var increasedContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// The visible lines `ranges` covers in `textView`, in its own coordinates.
    static func lines(for ranges: [NSRange], in textView: NSTextView) -> [HighlighterSelection.Line] {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let selected = ranges.filter { $0.length > 0 }
        guard !selected.isEmpty else { return [] }
        let origin = textView.textContainerOrigin
        // A margin past the visible rect, so a stroke whose line is just off screen still paints
        // its overshoot into view.
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -HighlighterSelection.verticalReach * 4)
            .offsetBy(dx: -origin.x, dy: -origin.y)
        return selected.flatMap {
            HighlighterSelectionLayout.lines(selection: $0, layoutManager: layoutManager, textContainer: container,
                                             visibleRect: visible, origin: origin)
        }
    }

    /// Paints the strokes for `lines` that reach `dirtyRect`, one fill per line so the overlap
    /// between two lines darkens like ink laid twice.
    static func draw(_ lines: [HighlighterSelection.Line], theme: Theme, dirtyRect: NSRect) {
        guard !lines.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let increased = increasedContrast
        let fill = HighlighterSelection.fillColor(for: theme, increasedContrast: increased)
        let separate = HighlighterSelection.darkensOverlaps(increasedContrast: increased)
        context.saveGState()
        context.setFillColor(fill.cgColor)
        for line in lines where HighlighterSelection.paintBounds(for: line).intersects(dirtyRect) {
            context.addPath(HighlighterSelection.path(for: line))
            if separate { context.fillPath() }
        }
        // Increase Contrast: one shape (non-zero winding), so overlaps never double the fill.
        if !separate { context.fillPath() }
        context.restoreGState()
    }

    /// Invalidates every line whose stroke changed between `old` and `new` (both what was, or will
    /// be, painted), covering the overshoot AppKit's own selection invalidation does not reach.
    static func invalidate(changedFrom old: [HighlighterSelection.Line], to new: [HighlighterSelection.Line],
                           in view: NSView) {
        guard old != new else { return }
        let oldSet = Set(old), newSet = Set(new)
        for line in oldSet.symmetricDifference(newSet) {
            view.setNeedsDisplay(HighlighterSelection.paintBounds(for: line))
        }
    }
}

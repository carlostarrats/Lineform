import LineformCore
import UIKit

/// The highlighter selection on iPhone (`HighlighterSelection`, the Mac's look): the system's
/// selection fill is replaced by calm marker strokes drawn BEHIND the text in
/// `HighlighterSelectionView`, from TextKit 1 line fragments, like the spelling underlines and
/// History's wash. Nothing is written to the text storage.
///
/// **Hiding the system fill.** UIKit draws the selection through the text view's
/// `UITextSelectionDisplayInteraction`. Its `highlightView` is public and settable (iOS 17+), so the
/// editor gives it `HiddenSelectionHighlightView`: a view that draws nothing and reports each new set
/// of selection rects back here, so the strokes follow the same updates UIKit's own highlight does.
/// The interaction's caret (`cursorView`), the grabber handles (`handleViews`), the loupe and the
/// edit menu are untouched. If a future UIKit stops exposing the interaction, the system fill simply
/// stays (the strokes are then not drawn, never doubled).
///
/// **Cost.** Only the visible lines of the selection are measured (`HighlighterSelectionLayout`),
/// so Select All on a 1 MB document draws one screenful. Typing with a caret costs one comparison.
extension LineformTextView {
    /// The stroke view, made on first use.
    var highlighterSelectionView: HighlighterSelectionView? {
        get { state.highlighterSelectionView }
        set { state.highlighterSelectionView = newValue }
    }

    /// Whether the system's selection fill is replaced (the interaction was found).
    var replacesSystemSelectionHighlight: Bool { state.replacesSystemSelectionHighlight }

    /// Installs the empty highlight view on the system's selection display, once it exists (UIKit
    /// makes it lazily, so this is retried until found).
    func installHighlighterSelectionIfNeeded() {
        guard !state.replacesSystemSelectionHighlight else { return }
        for case let display as UITextSelectionDisplayInteraction in interactions {
            let hidden = HiddenSelectionHighlightView(frame: .zero)
            hidden.onSelectionRectsChange = { [weak self] in self?.highlighterSelectionDidChange() }
            display.highlightView = hidden
            state.replacesSystemSelectionHighlight = true
            setNeedsHighlighterSelectionRedraw()
            return
        }
    }

    /// The selection changed (`textViewDidChangeSelection`). Typing with a caret and no strokes on
    /// screen (the common case) asks for nothing.
    func highlighterSelectionDidChange() {
        guard selectedRange.length > 0 || highlighterSelectionView?.isHidden == false else { return }
        setNeedsHighlighterSelectionRedraw()
    }

    /// The next layout pass re-measures the strokes.
    func setNeedsHighlighterSelectionRedraw() {
        state.needsHighlighterSelectionRedraw = true
        setNeedsLayout()
    }

    /// From `layoutSubviews`, after super: redraws when asked, or when a scroll uncovered new lines
    /// while something is selected.
    func redrawHighlighterSelectionIfNeeded() {
        installHighlighterSelectionIfNeeded()
        let range = shownHighlighterRange
        let visible = bounds.origin
        guard state.needsHighlighterSelectionRedraw
            || (range != nil && visible != state.highlighterSelectionDrawnOrigin) else { return }
        state.needsHighlighterSelectionRedraw = false
        state.highlighterSelectionDrawnOrigin = visible
        redrawHighlighterSelection(range)
    }

    /// The selection the strokes show: only while the system fill is replaced, the editor has the
    /// focus (UIKit hides a resigned text view's selection; so does the highlighter), and something
    /// is selected.
    var shownHighlighterRange: NSRange? {
        guard state.replacesSystemSelectionHighlight, isFirstResponder else { return nil }
        let range = selectedRange
        return range.length > 0 && NSMaxRange(range) <= textStorage.length ? range : nil
    }

    /// The strokes for `range`'s visible lines, in content coordinates.
    func highlighterSelectionLines(for range: NSRange) -> [HighlighterSelection.Line] {
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        // A little past the screen, so a stroke just off it still paints its overshoot in.
        let visible = bounds.insetBy(dx: 0, dy: -HighlighterSelection.verticalReach * 4)
            .offsetBy(dx: -origin.x, dy: -origin.y)
        return HighlighterSelectionLayout.lines(selection: range, layoutManager: layoutManager,
                                                textContainer: textContainer, visibleRect: visible, origin: origin)
    }

    private func redrawHighlighterSelection(_ range: NSRange?) {
        guard let range else {
            highlighterSelectionView?.show([], fill: nil, separate: true)
            return
        }
        let view = highlighterSelectionViewPlacedBehindText()
        let increased = traitCollection.accessibilityContrast == .high || UIAccessibility.isDarkerSystemColorsEnabled
        let fill = HighlighterSelection.fillColor(for: Theme.theme(for: profile), increasedContrast: increased)
        view.show(highlighterSelectionLines(for: range).map { HighlighterSelection.path(for: $0) },
                  fill: fill.cgColor,
                  separate: HighlighterSelection.darkensOverlaps(increasedContrast: increased))
    }

    /// Under the text, above the Reading Ruler and History's wash.
    private func highlighterSelectionViewPlacedBehindText() -> HighlighterSelectionView {
        let view = highlighterSelectionView ?? {
            let made = HighlighterSelectionView(frame: .zero)
            highlighterSelectionView = made
            return made
        }()
        let below = [historyWashView, readingRulerView].compactMap { $0 }.first { $0.superview === self }
        if let below, let index = subviews.firstIndex(of: below) {
            if subviews.firstIndex(of: view) != index + 1 { insertSubview(view, aboveSubview: below) }
        } else if subviews.first !== view {
            insertSubview(view, at: 0)
        }
        return view
    }
}

/// The system highlight's stand-in: draws nothing, and reports each change of the selection's
/// rects (a drag, a handle move, a new selection) so the strokes follow it.
final class HiddenSelectionHighlightView: UIView, UITextSelectionHighlightView {
    var onSelectionRectsChange: (() -> Void)?

    var selectionRects: [UITextSelectionRect] = [] {
        didSet { onSelectionRectsChange?() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

/// The strokes, one shape layer per line so the overlap between two lines darkens like ink laid
/// twice (or one layer for every line under Increase Contrast, so it never doubles).
final class HighlighterSelectionView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// The shape layers drawn now (tests).
    var strokeLayers: [CAShapeLayer] { (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer } }

    func show(_ paths: [CGPath], fill: CGColor?, separate: Bool) {
        isHidden = paths.isEmpty
        let shapes: [CGPath]
        if separate || paths.isEmpty {
            shapes = paths
        } else {
            let union = CGMutablePath()
            paths.forEach { union.addPath($0) }
            shapes = [union]
        }
        var layers = strokeLayers
        while layers.count < shapes.count {
            let shape = CAShapeLayer()
            shape.contentsScale = traitCollection.displayScale
            // No implicit animation: a drag redraws in place.
            shape.actions = ["path": NSNull(), "fillColor": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            layer.addSublayer(shape)
            layers.append(shape)
        }
        for (index, shape) in layers.enumerated() {
            if index < shapes.count {
                shape.isHidden = false
                shape.path = shapes[index]
                shape.fillColor = fill
            } else {
                // Kept for the next drag rather than rebuilt.
                shape.isHidden = true
                shape.path = nil
            }
        }
    }
}

import LineformCore
import UIKit

/// What History mode draws over the text: every located passage as a rounded box, in depth order
/// (the Mac's `HistoryModeDisplay`, without hover or the version counter — the card lists the
/// versions). Pure, so tests read the fills without a view.
struct HistoryWashDisplay: Equatable {
    var passages: [LocatedPassage]
    var selectedID: UUID?

    /// The innermost passage containing `characterIndex`: the shortest range, ties broken by the
    /// finer level. A tap selects it, so a word inside a changed sentence selects the word.
    func innermostPassage(containing characterIndex: Int) -> LocatedPassage? {
        passages
            .filter { NSLocationInRange(characterIndex, $0.range) }
            .min { lhs, rhs in
                if lhs.range.length != rhs.range.length { return lhs.range.length < rhs.range.length }
                return lhs.level > rhs.level
            }
    }

    var selectedPassage: LocatedPassage? {
        guard let selectedID else { return nil }
        return passages.first { $0.id == selectedID }
    }

    /// Each passage's nesting depth (1 = outermost), the Mac's rule: one more than the passages
    /// it sits inside; a passage sharing its parent's exact range is the deeper one.
    var layerDepths: [UUID: Int] {
        func outer(_ a: LocatedPassage, contains b: LocatedPassage) -> Bool {
            guard a.id != b.id, NSIntersectionRange(a.range, b.range) == b.range else { return false }
            if a.range != b.range { return true }
            return a.level != b.level ? a.level < b.level : a.id.uuidString < b.id.uuidString
        }
        var depths: [UUID: Int] = [:]
        for passage in passages {
            depths[passage.id] = 1 + passages.filter { outer($0, contains: passage) }.count
        }
        return depths
    }

    /// The fill each passage draws, outer first (the Mac's `layerFills`, minus hover): nothing
    /// selected, the wash stacked to the passage's depth; a passage selected, it is blue, the
    /// passages inside it add ink layers over the blue, and every other passage takes the stacked
    /// focus-other fill. Every fill is an opaque composite from `HistoryPalette`, whose tests pin
    /// full ink at AA on each of them, in every theme.
    func layerFills(for theme: Theme) -> [(passage: LocatedPassage, fill: UIColor)] {
        let depths = layerDepths
        let selected = selectedPassage
        let selectedDepth = selected.flatMap { depths[$0.id] } ?? 0
        return passages
            .sorted { (depths[$0.id] ?? 1, $1.range.length) < (depths[$1.id] ?? 1, $0.range.length) }
            .map { passage in
                let depth = depths[passage.id] ?? 1
                guard let selected else { return (passage, HistoryPalette.washFill(for: theme, depth: depth)) }
                if passage.id == selected.id { return (passage, HistoryPalette.selectedFill(for: theme)) }
                if depth > selectedDepth, NSIntersectionRange(selected.range, passage.range) == passage.range {
                    return (passage, HistoryPalette.selectedChildFill(for: theme, depth: depth - selectedDepth))
                }
                return (passage, HistoryPalette.focusOtherFill(for: theme, depth: depth))
            }
    }
}

/// The view that holds History mode's washes: one `CAShapeLayer` per passage, in content
/// coordinates, BEHIND the text (it sits under the text container's view, above the Reading
/// Ruler). It never takes touches and is invisible to VoiceOver. It is also the delegate of the
/// editor's History tap, which must recognise alongside UITextView's own gestures.
final class HistoryWashView: UIView, UIGestureRecognizerDelegate {
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

    /// The shape layers drawn now, in drawing order (tests).
    var washLayers: [CAShapeLayer] { (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer } }

    /// Replaces the washes: one path and fill per passage, drawn in the order given.
    func show(_ washes: [(path: CGPath, fill: CGColor)]) {
        var layers = washLayers
        while layers.count < washes.count {
            let shape = CAShapeLayer()
            shape.contentsScale = traitCollection.displayScale
            // No implicit animation: a step redraws in place.
            shape.actions = ["path": NSNull(), "fillColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer.addSublayer(shape)
            layers.append(shape)
        }
        while layers.count > washes.count {
            layers.removeLast().removeFromSuperlayer()
        }
        for (shape, wash) in zip(layers, washes) {
            shape.path = wash.path
            shape.fillColor = wash.fill
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// Drawing History mode's washes. **Phone exception to the Mac (recorded in `iphone-app.md`):**
/// the Mac also recedes the ink of everything outside the selected passage with layout-manager
/// TEMPORARY attributes; iOS TextKit 1 has none, and a storage colour change would churn the
/// highlighting and the undo stack, so the phone draws the wash only. Nothing here ever touches
/// the text storage: the washes are shape layers built from TextKit 1 line fragments, like the
/// spelling underlines.
extension LineformTextView {
    /// The wash view, made on first use.
    var historyWashView: HistoryWashView? {
        get { state.historyWashView }
        set { state.historyWashView = newValue }
    }

    /// The next layout pass redraws the washes.
    func setNeedsHistoryWashRedraw() {
        state.needsHistoryWashRedraw = true
        setNeedsLayout()
    }

    /// Called from `layoutSubviews`, after super.
    func redrawHistoryWashIfNeeded() {
        guard state.needsHistoryWashRedraw else { return }
        redrawHistoryWash()
    }

    /// What History mode shows now, or nil outside it.
    var historyWashDisplay: HistoryWashDisplay? {
        guard let controller = historyController, controller.isHistoryModeActive else { return nil }
        return HistoryWashDisplay(passages: controller.located, selectedID: controller.selectedPassageID)
    }

    /// Draws every located passage's box (or clears them outside History mode).
    func redrawHistoryWash() {
        state.needsHistoryWashRedraw = false
        guard let display = historyWashDisplay, !display.passages.isEmpty else {
            historyWashView?.show([])
            historyWashView?.isHidden = true
            return
        }
        let wash = historyWashViewPlacedBehindText()
        wash.isHidden = false
        // The Original theme's colours are dynamic: resolve them with this view's traits.
        var washes: [(path: CGPath, fill: CGColor)] = []
        traitCollection.performAsCurrent {
            let theme = Theme.theme(for: profile)
            let length = textStorage.length
            for (passage, fill) in display.layerFills(for: theme) where NSMaxRange(passage.range) <= length {
                let path = UIBezierPath()
                for rect in historyRects(for: passage.range) {
                    path.append(UIBezierPath(roundedRect: rect, cornerRadius: HistoryPalette.layerCornerRadius))
                }
                guard !path.isEmpty else { continue }
                washes.append((path.cgPath, fill.cgColor))
            }
        }
        wash.show(washes)
    }

    /// One rect per line fragment `range` covers, in content coordinates.
    func historyRects(for range: NSRange) -> [CGRect] {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return [] }
        var rects: [CGRect] = []
        let inset = textContainerInset
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { [layoutManager] _, _, container, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, glyphs)
            guard part.length > 0 else { return }
            var box = layoutManager.boundingRect(forGlyphRange: part, in: container)
            guard box.width > 0 else { return }
            box = box.offsetBy(dx: inset.left, dy: inset.top).insetBy(dx: -Self.historyWashOutset, dy: 0)
            rects.append(box)
        }
        return rects
    }

    /// The box reaches this far past the ink on each side, so a one-letter word still reads as a box.
    static let historyWashOutset: CGFloat = 2

    /// The wash view, under the text: just above the Reading Ruler when there is one, else the
    /// lowest subview.
    private func historyWashViewPlacedBehindText() -> HistoryWashView {
        let wash = historyWashView ?? {
            let view = HistoryWashView(frame: .zero)
            historyWashView = view
            return view
        }()
        if let ruler = readingRulerView, ruler.superview === self {
            if let rulerIndex = subviews.firstIndex(of: ruler), subviews.firstIndex(of: wash) != rulerIndex + 1 {
                insertSubview(wash, aboveSubview: ruler)
            }
        } else if subviews.first !== wash {
            insertSubview(wash, at: 0)
        }
        return wash
    }
}

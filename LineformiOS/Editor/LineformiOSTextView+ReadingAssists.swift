import LineformCore
import UIKit

/// The reading assists: the Reading Ruler and Typewriter Mode, ported from the Mac's
/// `drawReadingRulerIfNeeded` and `centerSelectionForTypewriterModeIfNeeded`. Both follow the
/// reading profile (`readingRulerEnabled`, `typewriterModeEnabled`) and use the package's
/// `ReadingAssistRangeResolver.focusRange(…, mode: .currentLine)` for the current line.
///
/// - **Ruler.** A band of the tint colour at `readingRulerFillOpacity` (0.12), the Mac's
///   `controlAccentColor` expression, behind the current line's enclosing rects (TextKit 1
///   `enumerateEnclosingRects`), widened to the column and outset 6 × 2 pt as on the Mac. It is a
///   plain view kept as the text view's lowest subview, so it sits behind UIKit's text container
///   view and never covers a glyph. Nothing is written to the text storage.
/// - **Typewriter.** After a selection or text change the caret's line fragment is centred with
///   `setContentOffset(TypewriterScroll.origin(…), animated: false)`, clamped to the content
///   (never above the top, never past the end).
///   Turning it off scrolls back to where the page was when it came on. While the keyboard is
///   animating its frame, centring waits, then runs once the keyboard settles, so it never fights
///   keyboard avoidance.
extension LineformTextView {
    /// The ruler's fill opacity: the Mac's `readingRulerFillOpacity`.
    static let readingRulerFillOpacity: CGFloat = 0.12

    /// Re-places the ruler and, in Typewriter Mode, re-centres the caret line. Called after every
    /// selection change and edit (through the delegate), on a size change, and when the profile
    /// or the whole text changes. Cheap: it lays out only the caret's line.
    func refreshReadingAssists() {
        // During a Styling slider drag each restyle invalidates the whole layout, and placing the
        // assists would lay the prefix out again (about 640 ms on 1 MB): hide the ruler, leave the
        // caret, and catch up once when the drag ends (`stylingDragDidEnd`).
        guard !StylingDrag.isActive else {
            readingRulerView?.isHidden = true
            return
        }
        updateReadingRuler()
        centerSelectionForTypewriterModeIfNeeded()
    }

    // MARK: - Reading Ruler

    private func updateReadingRuler() {
        guard profile.readingRulerEnabled, let band = readingRulerRect() else {
            readingRulerView?.isHidden = true
            return
        }
        let ruler = readingRulerView ?? makeReadingRulerView()
        if subviews.first !== ruler {
            insertSubview(ruler, at: 0)
        }
        ruler.isHidden = false
        if ruler.frame != band {
            ruler.frame = band
        }
    }

    private func makeReadingRulerView() -> UIView {
        let ruler = UIView()
        ruler.isUserInteractionEnabled = false
        ruler.isAccessibilityElement = false
        readingRulerView = ruler
        updateReadingRulerColor()
        insertSubview(ruler, at: 0)
        return ruler
    }

    func updateReadingRulerColor() {
        readingRulerView?.backgroundColor = tintColor.withAlphaComponent(Self.readingRulerFillOpacity)
    }

    /// The current line's enclosing rects (every visual line of a wrapped line), widened to the
    /// column width and outset 6 × 2 pt, in the text view's content coordinates.
    private func readingRulerRect() -> CGRect? {
        guard let line = currentFocusLine() else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        ensureExactLayout(through: NSMaxRange(glyphs) - 1)
        var union = CGRect.null
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            union = union.union(rect)
        }
        if union.isNull {
            union = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        }
        union.origin.x += textContainerInset.left
        union.origin.y += textContainerInset.top
        union.size.width = max(union.width, bounds.width - textContainerInset.left - textContainerInset.right)
        return union.insetBy(dx: -6, dy: -2)
    }

    /// The caret's logical line (`ReadingAssistRangeResolver`, `.currentLine`), or nil for an
    /// empty document.
    private func currentFocusLine() -> NSRange? {
        let text = textStorage.string
        guard let range = ReadingAssistRangeResolver.focusRange(in: text, selectedRange: selectedRange, mode: .currentLine),
              range.length > 0,
              NSMaxRange(range) <= textStorage.length else {
            return nil
        }
        return range
    }

    /// UITextView's TextKit 1 layout is non-contiguous: a line below an unlaid stretch gets an
    /// estimated position that moves once that stretch is laid out. Laying out the prefix up to
    /// `glyph` makes the caret line's rect exact. It costs work only past
    /// `firstUnlaidGlyphIndex()`: once per document, then just the edited stretch after an edit.
    private func ensureExactLayout(through glyph: Int) {
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return }
        let last = min(glyph, glyphCount - 1)
        guard layoutManager.firstUnlaidGlyphIndex() <= last else { return }
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: last + 1))
    }

    // MARK: - Typewriter Mode

    /// Centres the caret's line fragment, unless Typewriter Mode is off or the keyboard is
    /// animating.
    func centerSelectionForTypewriterModeIfNeeded() {
        guard profile.typewriterModeEnabled, !isKeyboardAnimating, let line = currentFocusLine() else { return }
        // The caret's own visual line inside the current line, so a wrapped paragraph keeps the
        // caret (not its first line) at the centre.
        let location = min(max(selectedRange.location, line.location), NSMaxRange(line) - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        ensureExactLayout(through: glyph)
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        lineRect.origin.x += textContainerInset.left
        lineRect.origin.y += textContainerInset.top

        let inset = adjustedContentInset
        let visible = CGRect(
            x: contentOffset.x,
            y: contentOffset.y + inset.top,
            width: bounds.width,
            height: max(0, bounds.height - inset.top - inset.bottom)
        )
        // `contentSize` trails TextKit 1's lazy (non-contiguous) layout on a long document, so the
        // end limit is at least the caret line's own bottom: what is laid out is real content.
        let contentHeight = max(contentSize.height, lineRect.maxY + textContainerInset.bottom)
        let origin = TypewriterScroll.origin(for: lineRect, visibleBounds: visible, contentHeight: contentHeight)
        let offset = CGPoint(x: contentOffset.x, y: origin.y - inset.top)
        scrollForTypewriter(to: offset)
    }

    /// A non-animated scroll that survives UITextView's lazy layout. When the target is past what
    /// was laid out, the first assignment makes UITextView grow `contentSize` and put the old
    /// offset back (measured on iOS 26, for `setContentOffset(_:animated: false)` and the setter
    /// alike); the second, against the grown size, sticks.
    private func scrollForTypewriter(to offset: CGPoint) {
        for _ in 0..<2 where abs(offset.y - contentOffset.y) > 0.5 {
            setContentOffset(offset, animated: false)
        }
    }

    /// Remembers the page position when Typewriter Mode comes on, and returns the position to go
    /// back to when it goes off (the Mac's `updateTypewriterScrollState`). The caller scrolls
    /// there after the profile is applied: the whole-document re-style invalidates layout, and
    /// UITextView pulls the offset in against the shrunken estimate if it went first.
    func updateTypewriterScrollState(from previous: ReadingProfile, to profile: ReadingProfile) -> CGPoint? {
        guard previous.typewriterModeEnabled != profile.typewriterModeEnabled else { return nil }
        if profile.typewriterModeEnabled {
            scrollOffsetBeforeTypewriterMode = contentOffset
            return nil
        }
        defer { scrollOffsetBeforeTypewriterMode = nil }
        return scrollOffsetBeforeTypewriterMode
    }

    /// Scrolls back to the offset saved when Typewriter Mode came on. Only the top is clamped:
    /// the saved offset was a real position when it was taken, and the Mac restores it unclamped.
    func restoreOffsetBeforeTypewriterMode(_ saved: CGPoint) {
        let target = CGPoint(x: saved.x, y: max(saved.y, -adjustedContentInset.top))
        layoutManager.ensureLayout(
            forBoundingRect: CGRect(x: 0, y: max(0, target.y - textContainerInset.top), width: bounds.width, height: bounds.height),
            in: textContainer
        )
        scrollForTypewriter(to: target)
    }

    // MARK: - Keyboard

    func observeKeyboardForTypewriterMode() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrameForTypewriter(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidSettleForTypewriter),
                           name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(stylingDragDidEnd),
                           name: StylingDrag.didEndNotification, object: nil)
    }

    @objc private func keyboardWillChangeFrameForTypewriter(_ notification: Notification) {
        isKeyboardAnimating = true
        // A backstop in case the "did" notification never comes: settle after the animation.
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let selector = #selector(keyboardDidSettleForTypewriter)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
        perform(selector, with: nil, afterDelay: duration + 0.05, inModes: [.common])
    }

    @objc func stylingDragDidEnd() {
        refreshReadingAssists()
    }

    @objc private func keyboardDidSettleForTypewriter() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(keyboardDidSettleForTypewriter), object: nil)
        guard isKeyboardAnimating else { return }
        isKeyboardAnimating = false
        centerSelectionForTypewriterModeIfNeeded()
    }
}

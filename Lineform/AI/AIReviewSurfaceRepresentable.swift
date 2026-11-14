import AppKit
import SwiftUI

/// Hosts the review overlay (`AIReviewTextView`) in a scroll view laid exactly over the editor
/// while a review is up (Write mode only).
///
/// On make it takes the editor's scroll position and the keyboard; on dismantle it hands both
/// back — the editor scrolls to where the reader was in the overlay and becomes first responder
/// again. The position is handed over by CHARACTER, never by pixel y: past the first change the
/// overlay is taller than the document (it also shows the struck originals), so the
/// same y shows different text. The top line's first character is mapped through the
/// composition (`documentIndex` / `overlayIndex`) and that character's line is put at the top. No SwiftUI accessibility modifiers: the overlay text view carries its own label, role
/// and custom actions through AppKit.
struct AIReviewSurfaceRepresentable: NSViewRepresentable {
    let composition: AIReviewComposition
    let currentID: Int?
    /// Pending changes left (Accept All and ← / → are offered for two or more).
    var pendingCount: Int = 1
    /// How much of the overlay's bottom the review card covers (its height + inset + margin): the
    /// current change is revealed above it.
    var bottomObscured: CGFloat = 0
    let profile: ReadingProfile
    /// The editor underneath. Weakly held by the coordinator; nil only in a transient state.
    let editor: NSTextView?
    let onCommand: (AIReviewCommand) -> Void

    final class Coordinator {
        weak var editor: NSTextView?
        var presented: (AIReviewComposition, Int?, ReadingProfile)?
        var onCommand: ((AIReviewCommand) -> Void)?
        /// The card's covered height last revealed against (it is measured after the overlay is made).
        var revealedObscured: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Opaque, in the page colour: below a short composition the editor must not show through.
        scrollView.drawsBackground = true
        if let editorScroll = editor?.enclosingScrollView {
            scrollView.scrollerStyle = editorScroll.scrollerStyle
        }

        let textView = AIReviewTextView.make()
        scrollView.documentView = textView
        context.coordinator.editor = editor
        textView.handOffEditor = editor
        update(textView, in: scrollView, context: context)

        // Start where the reader is: the editor's top character, mapped into the overlay. Applied
        // now and again on the next turn, once SwiftUI has given the scroll view its real size.
        let anchor = editor.flatMap(Self.topAnchor(of:))
        let bottomObscured = bottomObscured
        let showAnchor = { [weak textView, weak scrollView] in
            guard let textView, let scrollView else { return }
            if let anchor,
               let y = Self.originY(in: textView, showing: textView.composition.overlayIndex(forDocumentIndex: anchor.index),
                                    offset: anchor.offset) {
                Self.scroll(scrollView, toY: y)
            }
            // Then, only if the card would cover it, the minimal scroll that shows the change.
            Self.revealCurrentChange(of: textView, in: scrollView, bottomObscured: bottomObscured)
        }
        showAnchor()
        DispatchQueue.main.async { [weak textView] in
            showAnchor()
            // Not in a window at make time: take the keyboard now.
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? AIReviewTextView else { return }
        context.coordinator.editor = editor
        textView.handOffEditor = editor
        let previousCurrent = context.coordinator.presented?.1
        update(textView, in: scrollView, context: context)
        if previousCurrent != currentID || context.coordinator.revealedObscured != bottomObscured {
            // A new current change, or the card's height just measured: reveal it above the card
            // (nothing moves when it already shows).
            context.coordinator.revealedObscured = bottomObscured
            Self.revealCurrentChange(of: textView, in: scrollView, bottomObscured: bottomObscured)
        }
        if let window = textView.window, window.firstResponder !== textView, window.firstResponder === editor {
            // The overlay owns the keyboard during review (the editor is read-only beneath it).
            window.makeFirstResponder(textView)
        }
    }

    private func update(_ textView: AIReviewTextView, in scrollView: NSScrollView, context: Context) {
        scrollView.backgroundColor = Theme.theme(for: profile).backgroundColor
        context.coordinator.onCommand = onCommand
        textView.commandHandler = { [weak coordinator = context.coordinator] command in
            coordinator?.onCommand?(command)
        }
        textView.pendingCount = pendingCount
        if let editor { textView.matchGeometry(of: editor) }
        let key = (composition, currentID, profile)
        if let presented = context.coordinator.presented, presented == key { return }
        context.coordinator.presented = key
        textView.present(composition, currentID: currentID, profile: profile)
        if let editor { textView.matchGeometry(of: editor) }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? AIReviewTextView else { return }
        textView.commandHandler = nil
        textView.handOffEditor = nil
        guard let editor = coordinator.editor, let editorScroll = editor.enclosingScrollView else { return }
        // The overlay's top character, mapped back into the document. When the review ended on an
        // accept, that accept already moved the text after it; a top line before the last change
        // is exact, one after it can be off by that change's length — the same line in practice.
        if let anchor = topAnchor(of: textView),
           let y = originY(in: editor, showing: textView.composition.documentIndex(forOverlayIndex: anchor.index),
                           offset: anchor.offset) {
            scroll(editorScroll, toY: y)
        }
        if let window = editor.window, window.firstResponder === textView || window.firstResponder === window {
            window.makeFirstResponder(editor)
        }
    }

    // MARK: - Scroll hand-over by character

    /// The first character of the line at the top of `textView`'s visible area, and how far the
    /// visible top is below that line's top. NEGATIVE while the visible top is still in the top
    /// inset (above the first line): the editor at rest at the top of a document shows its
    /// `textContainerInset`, and clamping that to 0 put the overlay one inset (~28pt) lower —
    /// the whole document jumped up when a review started and back when it ended (2026-11-13).
    static func topAnchor(of textView: NSTextView) -> (index: Int, offset: CGFloat)? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else { return nil }
        let visibleTop = clip.bounds.minY - textView.textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(0, visibleTop)), in: container)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange()
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let offset = visibleTop < line.minY ? visibleTop - line.minY : max(0, visibleTop - line.minY)
        return (layoutManager.characterIndexForGlyph(at: lineGlyphs.location), offset)
    }

    /// The clip-view origin y that puts `index`'s line at the top of `textView`, `offset` into it
    /// (a negative offset shows that much of the space above the line — the top inset).
    static func originY(in textView: NSTextView, showing index: Int, offset: CGFloat) -> CGFloat? {
        guard let layoutManager = textView.layoutManager, let storage = textView.textStorage,
              storage.length > 0 else { return nil }
        let character = min(max(0, index), storage.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return max(0, line.minY + min(offset, line.height) + textView.textContainerOrigin.y)
    }

    /// Scrolls the least amount that shows the current change ABOVE the review card (2026-11-14:
    /// the card covered a change near the bottom). Nothing moves when it is already visible — the
    /// review must not make the document jump.
    static func revealCurrentChange(of textView: AIReviewTextView, in scrollView: NSScrollView, bottomObscured: CGFloat) {
        guard let id = textView.currentID, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        // EVERY drawn range of the change — struck, replacements, stacked lines — not an anchor.
        let composition = textView.composition
        let ranges = (composition.removedRanges[id] ?? []) + (composition.replacementRanges[id] ?? [])
            + (composition.changeRanges[id].map { [$0] } ?? [])
        guard let end = ranges.map(NSMaxRange).max(), !ranges.isEmpty else { return }
        // Laid out from the top, so the y positions are measured, not estimated (non-contiguous
        // layout guesses the height of text it has not laid out — the change's lower lines read
        // as if they were higher, and the scroll fell short).
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: end))
        var rect = NSRect.null
        for range in ranges where range.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            rect = rect.union(layoutManager.boundingRect(forGlyphRange: glyphs, in: container))
        }
        guard !rect.isNull else { return }
        rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        guard let y = revealOriginY(for: rect, visible: scrollView.contentView.bounds, bottomObscured: bottomObscured) else { return }
        scroll(scrollView, toY: y)
    }

    /// The clip origin y that keeps the change's bottom above the card's top (`bottomObscured`
    /// covers the visible bottom: card + inset + margin), or nil when it already is. The card
    /// covers only the right part of the width, but a change's lines run under it, so the whole
    /// change's BOTTOM must clear it. Below: scrolled up the minimum; a change taller than the
    /// room above the card: its TOP at the visible top (never pushed out of view); above the
    /// visible top: brought `margin` under it.
    static func revealOriginY(for rect: NSRect, visible: NSRect, bottomObscured: CGFloat, margin: CGFloat = 8) -> CGFloat? {
        let top = visible.minY
        let bottom = visible.maxY - bottomObscured
        if rect.minY >= top, rect.maxY <= bottom { return nil }
        if rect.minY < top { return max(0, rect.minY - margin) }
        let lift = rect.maxY - bottom
        return max(0, min(top + lift, rect.minY))
    }

    static func scroll(_ scrollView: NSScrollView, toY y: CGFloat) {
        let origin = NSPoint(x: 0, y: y)
        if let clip = scrollView.contentView as? LineformEditorClipView {
            clip.setBoundsOriginBypassingVerticalLock(origin)
        } else {
            scrollView.contentView.scroll(to: origin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

import AppKit
import SwiftUI

/// Hosts the review overlay (`AIReviewTextView`) in a scroll view laid exactly over the editor
/// while a review is up (Write mode only).
///
/// On make it takes the editor's scroll position and the keyboard; on dismantle it hands both
/// back — the editor scrolls to where the reader was in the overlay and becomes first responder
/// again. The position is handed over by CHARACTER, never by pixel y: past the first change the
/// overlay is taller than the document (it also shows the removed text and the pills), so the
/// same y shows different text. The top line's first character is mapped through the
/// composition (`documentIndex` / `overlayIndex`) and that character's line is put at the top. No SwiftUI accessibility modifiers: the overlay text view carries its own label, role
/// and custom actions through AppKit.
struct AIReviewSurfaceRepresentable: NSViewRepresentable {
    let composition: AIReviewComposition
    let currentID: Int?
    let hasDecided: Bool
    let profile: ReadingProfile
    /// The editor underneath. Weakly held by the coordinator; nil only in a transient state.
    let editor: NSTextView?
    let onCommand: (AIReviewCommand) -> Void

    final class Coordinator {
        weak var editor: NSTextView?
        var presented: (AIReviewComposition, Int?, Bool, ReadingProfile)?
        var onCommand: ((AIReviewCommand) -> Void)?
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
        let showAnchor = { [weak textView, weak scrollView] in
            guard let textView, let scrollView, let anchor,
                  let y = Self.originY(in: textView, showing: textView.composition.overlayIndex(forDocumentIndex: anchor.index),
                                       offset: anchor.offset) else { return }
            Self.scroll(scrollView, toY: y)
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
        if previousCurrent != currentID, let range = textView.currentChangeRange {
            textView.scrollRangeToVisible(range)
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
        if let editor { textView.matchGeometry(of: editor) }
        let key = (composition, currentID, hasDecided, profile)
        if let presented = context.coordinator.presented, presented == key { return }
        context.coordinator.presented = key
        textView.present(composition, currentID: currentID, profile: profile, hasDecided: hasDecided)
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
    /// visible top is below that line's top.
    static func topAnchor(of textView: NSTextView) -> (index: Int, offset: CGFloat)? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else { return nil }
        let y = max(0, clip.bounds.minY - textView.textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange()
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        return (layoutManager.characterIndexForGlyph(at: lineGlyphs.location), max(0, y - line.minY))
    }

    /// The clip-view origin y that puts `index`'s line at the top of `textView`, `offset` into it.
    static func originY(in textView: NSTextView, showing index: Int, offset: CGFloat) -> CGFloat? {
        guard let layoutManager = textView.layoutManager, let storage = textView.textStorage,
              storage.length > 0 else { return nil }
        let character = min(max(0, index), storage.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minY + min(offset, line.height) + textView.textContainerOrigin.y
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

import AppKit
import SwiftUI

/// Hosts the review overlay (`AIReviewTextView`) in a scroll view laid exactly over the editor
/// while a review is up (Write mode only).
///
/// On make it takes the editor's scroll position and the keyboard; on dismantle it hands both
/// back — the editor scrolls to where the reader was in the overlay and becomes first responder
/// again. No SwiftUI accessibility modifiers: the overlay text view carries its own label, role
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
        update(textView, in: scrollView, context: context)

        // Start where the reader is: the text before the first change is the document's, so the
        // same origin shows the same lines.
        if let origin = editor?.enclosingScrollView?.contentView.bounds.origin {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        // Not in a window yet: take the keyboard on the next turn.
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? AIReviewTextView else { return }
        context.coordinator.editor = editor
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
        guard let editor = coordinator.editor, let editorScroll = editor.enclosingScrollView else { return }
        let origin = NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y)
        if let clip = editorScroll.contentView as? LineformEditorClipView {
            clip.setBoundsOriginBypassingVerticalLock(origin)
        } else {
            editorScroll.contentView.scroll(to: origin)
        }
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
        if let window = editor.window, window.firstResponder === textView || window.firstResponder === window {
            window.makeFirstResponder(editor)
        }
    }
}

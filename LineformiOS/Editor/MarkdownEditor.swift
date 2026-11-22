import LineformCore
import SwiftUI
import UIKit

/// The Markdown editor for SwiftUI: wraps `LineformTextView` and binds its text. It replaces the
/// step-3 `PlainTextEditor`.
///
/// The coordinator is the text view's delegate. It writes each change back to the binding (so
/// `OpenDocument` autosaves) and schedules the debounced highlight pass; `scrollViewDidScroll`
/// schedules the visible-window coverage check; `shouldChangeTextIn` routes Return through the
/// editing rules; a selection change or an edit refreshes the reading assists (ruler, typewriter);
/// the edit menu leads with spelling guesses on a misspelling; Writing Tools is told which
/// Markdown regions to leave alone. A pasted or dropped image is saved beside `imageHost`'s
/// document (`LineformiOSTextView+ImagePaste.swift`).
///
/// A text that changes from outside (a live reload, a checkbox or Reconnect made in Read) replaces
/// the editor's text and clears its undo history, so undo never puts older text over the new.
struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    var profile: ReadingProfile
    /// The document a pasted or dropped image is saved beside (`OpenDocument`).
    var imageHost: (any ImageInsertionHost)?
    /// Told which text view is the editor, for the mode switch's position restore.
    var positionKeeper: ModePositionKeeper?
    /// Called on every scroll of the editor (Preview's linked scrolling).
    var onScroll: ((UIScrollView) -> Void)?
    /// Preview's editor pane keeps the caret in view when the keyboard resizes it.
    var keepsCaretVisibleOnResize = false
    /// Extra room above the first line for the floating mode control.
    var topChromeInset: CGFloat = 0

    /// Padding for the chrome that floats over the page (the menu button, the save notice).
    static let chromeMargin: CGFloat = 20

    func makeUIView(context: Context) -> LineformTextView {
        let textView = LineformTextView.make(profile: profile)
        textView.setDocumentText(text)
        textView.delegate = context.coordinator
        textView.imageInsertionHost = imageHost
        textView.keepsCaretVisibleOnResize = keepsCaretVisibleOnResize
        textView.setTopChromeInset(topChromeInset)
        positionKeeper?.editor = textView
        return textView
    }

    func updateUIView(_ textView: LineformTextView, context: Context) {
        context.coordinator.parent = self
        configure(textView)
    }

    /// Hands `textView` this value's inputs. Internal so tests update an editor the same way.
    func configure(_ textView: LineformTextView) {
        textView.profile = profile
        textView.imageInsertionHost = imageHost
        textView.keepsCaretVisibleOnResize = keepsCaretVisibleOnResize
        textView.setTopChromeInset(topChromeInset)
        positionKeeper?.editor = textView
        if textView.text != text {
            // An outside replacement: the editor's undo steps describe the old text.
            textView.setDocumentText(text)
            textView.undoManager?.removeAllActions()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor

        init(parent: MarkdownEditor) { self.parent = parent }

        /// Return's list continuation and CRLF rule (`LineformTextView.handlesChange`).
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard let textView = textView as? LineformTextView else { return true }
            return !textView.handlesChange(in: range, replacementText: text)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            guard let textView = textView as? LineformTextView else { return }
            textView.textDidChangeForHighlighting()
            textView.refreshReadingAssists()
        }

        /// The Reading Ruler follows the caret, and Typewriter Mode re-centres it.
        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? LineformTextView)?.refreshReadingAssists()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? LineformTextView)?.visibleRangeDidChange()
            parent.onScroll?(scrollView)
        }

        /// On a misspelling, the spelling group (guesses, Learn, Ignore) leads the system's menu.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let spelling = (textView as? LineformTextView)?.spellingMenu(for: range) else { return nil }
            return UIMenu(children: [spelling] + suggestedActions)
        }

        /// The Markdown regions Writing Tools must leave alone, should it ever be turned on.
        func textView(_ textView: UITextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
            (textView as? LineformTextView)?.writingToolsIgnoredRanges(in: enclosingRange) ?? []
        }
    }
}

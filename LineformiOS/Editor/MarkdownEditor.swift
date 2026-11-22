import LineformCore
import SwiftUI
import UIKit

/// The Markdown editor for SwiftUI: wraps `LineformTextView` and binds its text. It replaces the
/// step-3 `PlainTextEditor`.
///
/// The coordinator is the text view's delegate. It writes each change back to the binding (so
/// `OpenDocument` autosaves) and schedules the debounced highlight pass; `scrollViewDidScroll`
/// schedules the visible-window coverage check; `shouldChangeTextIn` routes Return through the
/// editing rules; a selection change or an edit refreshes the reading assists (ruler, typewriter).
struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    var profile: ReadingProfile

    /// Padding for the chrome that floats over the page (the menu button, the save notice).
    static let chromeMargin: CGFloat = 20

    func makeUIView(context: Context) -> LineformTextView {
        let textView = LineformTextView.make(profile: profile)
        textView.setDocumentText(text)
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: LineformTextView, context: Context) {
        context.coordinator.parent = self
        textView.profile = profile
        if textView.text != text {
            textView.setDocumentText(text)
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
        }
    }
}

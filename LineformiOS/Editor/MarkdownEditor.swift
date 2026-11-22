import LineformCore
import SwiftUI
import UIKit

/// The Markdown editor for SwiftUI: wraps `LineformTextView` and binds its text. It replaces the
/// step-3 `PlainTextEditor`.
///
/// The coordinator is the text view's delegate. It writes each change back to the binding (so
/// `OpenDocument` autosaves) and schedules the debounced highlight pass; `scrollViewDidScroll`
/// schedules the visible-window coverage check.
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

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? LineformTextView)?.textDidChangeForHighlighting()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? LineformTextView)?.visibleRangeDidChange()
        }
    }
}

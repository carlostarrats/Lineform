import AppKit
import SwiftUI

struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectionContext: SelectionContext
    var profile: ReadingProfile

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectionContext: $selectionContext)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = LineformTextView()
        textView.string = text
        textView.delegate = context.coordinator
        textView.applyTypography(profile)
        textView.refreshMarkdownHighlighting()
        context.coordinator.updateSelection(from: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? LineformTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
            textView.refreshMarkdownHighlighting()
        }

        textView.applyTypography(profile)
    }
}

final class Coordinator: NSObject, NSTextViewDelegate {
    private var text: Binding<String>
    private var selectionContext: Binding<SelectionContext>

    init(text: Binding<String>, selectionContext: Binding<SelectionContext>) {
        self.text = text
        self.selectionContext = selectionContext
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else {
            return
        }

        text.wrappedValue = textView.string
        if let lineformTextView = textView as? LineformTextView {
            lineformTextView.refreshMarkdownHighlighting()
        }
        updateSelection(from: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else {
            return
        }

        updateSelection(from: textView)
    }

    @MainActor
    func updateSelection(from textView: NSTextView) {
        selectionContext.wrappedValue = SelectionContext(text: textView.string, selectedRange: textView.selectedRange())
    }
}

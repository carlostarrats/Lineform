import AppKit
import SwiftUI

struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectionContext: SelectionContext
    @Binding var requestedSelection: NSRange?
    var profile: ReadingProfile
    var intelligentSuggestionRange: NSRange?

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
        textView.setIntelligentSuggestionRange(intelligentSuggestionRange)

        if let range = requestedSelection {
            let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: (textView.string as NSString).length))
            textView.setSelectedRange(safeRange)
            textView.scrollRangeToVisible(safeRange)
            DispatchQueue.main.async {
                requestedSelection = nil
            }
        }
    }
}

final class Coordinator: NSObject, NSTextViewDelegate {
    private var text: Binding<String>
    private var selectionContext: Binding<SelectionContext>
    private var writingToolsSessionActive = false
    private var pendingWritingToolsText: String?
    private var pendingHighlightWorkItem: DispatchWorkItem?

    init(text: Binding<String>, selectionContext: Binding<SelectionContext>) {
        self.text = text
        self.selectionContext = selectionContext
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else {
            return
        }

        if writingToolsSessionActive {
            pendingWritingToolsText = textView.string
        } else {
            text.wrappedValue = textView.string
        }

        if let lineformTextView = textView as? LineformTextView {
            scheduleMarkdownHighlighting(for: lineformTextView)
            lineformTextView.refreshReadingAssists()
        }
        updateSelection(from: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else {
            return
        }

        updateSelection(from: textView)
        if let lineformTextView = textView as? LineformTextView {
            lineformTextView.refreshReadingAssists()
        }
    }

    func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        writingToolsSessionActive = true
        pendingWritingToolsText = nil
        (textView as? LineformTextView)?.writingToolsWillBegin()
    }

    func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        writingToolsSessionActive = false
        text.wrappedValue = pendingWritingToolsText ?? textView.string
        pendingWritingToolsText = nil
        (textView as? LineformTextView)?.writingToolsDidEnd()
    }

    func textView(_ textView: NSTextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
        (textView as? LineformTextView)?.writingToolsIgnoredRanges(in: enclosingRange) ?? []
    }

    @MainActor
    func updateSelection(from textView: NSTextView) {
        selectionContext.wrappedValue = SelectionContext(text: textView.string, selectedRange: textView.selectedRange())
    }

    private func scheduleMarkdownHighlighting(for textView: LineformTextView) {
        pendingHighlightWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak textView] in
            textView?.refreshMarkdownHighlighting()
        }
        pendingHighlightWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }
}

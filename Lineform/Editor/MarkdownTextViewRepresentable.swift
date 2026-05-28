import AppKit
import SwiftUI

struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var textFormat: LineformTextFormat
    @Binding var plainTextConversion: MarkdownPlainTextConversion?
    @Binding var selectionContext: SelectionContext
    @Binding var requestedSelection: NSRange?
    @Binding var selectionAnchorRect: CGRect?
    var profile: ReadingProfile
    var smoothsHorizontalInsetChanges = false
    var intelligentSuggestionRange: NSRange?
    var searchRanges: [NSRange] = []
    var activeSearchRange: NSRange?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            textFormat: $textFormat,
            plainTextConversion: $plainTextConversion,
            selectionContext: $selectionContext,
            selectionAnchorRect: $selectionAnchorRect
        )
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
        textView.smoothsHorizontalInsetChanges = smoothsHorizontalInsetChanges
        context.coordinator.configure(textView)
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

        textView.smoothsHorizontalInsetChanges = smoothsHorizontalInsetChanges
        textView.applyTypography(profile)
        context.coordinator.configure(textView)

        if textView.string != text {
            textView.string = text
            textView.refreshMarkdownHighlighting()
        }

        textView.setIntelligentSuggestionRange(intelligentSuggestionRange)
        textView.setSearchHighlights(searchRanges, activeRange: activeSearchRange)

        if let range = requestedSelection {
            let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: (textView.string as NSString).length))
            textView.setSelectedRange(safeRange)
            context.coordinator.updateSelection(from: textView)
            textView.scrollRangeToVisible(safeRange)
            DispatchQueue.main.async {
                requestedSelection = nil
            }
        }
    }
}

final class Coordinator: NSObject, NSTextViewDelegate {
    private var text: Binding<String>
    private var textFormat: Binding<LineformTextFormat>
    private var plainTextConversion: Binding<MarkdownPlainTextConversion?>
    private var selectionContext: Binding<SelectionContext>
    private var selectionAnchorRect: Binding<CGRect?>
    private var writingToolsSessionActive = false
    private var pendingWritingToolsText: String?
    private var pendingHighlightWorkItem: DispatchWorkItem?

    init(
        text: Binding<String>,
        textFormat: Binding<LineformTextFormat>,
        plainTextConversion: Binding<MarkdownPlainTextConversion?>,
        selectionContext: Binding<SelectionContext>,
        selectionAnchorRect: Binding<CGRect?>
    ) {
        self.text = text
        self.textFormat = textFormat
        self.plainTextConversion = plainTextConversion
        self.selectionContext = selectionContext
        self.selectionAnchorRect = selectionAnchorRect
    }

    @MainActor
    func configure(_ textView: LineformTextView) {
        textView.textFormat = textFormat.wrappedValue
        textView.lastPlainTextConversion = plainTextConversion.wrappedValue
        textView.textFormatChangeHandler = { [weak self] format, conversion in
            self?.textFormat.wrappedValue = format
            self?.plainTextConversion.wrappedValue = conversion
            LineformTextFormatMenuState.shared.setTextFormat(format)
        }
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
        selectionAnchorRect.wrappedValue = (textView as? LineformTextView)?.selectionAnchorRectInEnclosingScrollView()
    }

    private func scheduleMarkdownHighlighting(for textView: LineformTextView) {
        pendingHighlightWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak textView] in
            Task { @MainActor in
                textView?.refreshMarkdownHighlighting()
            }
        }
        pendingHighlightWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }
}

import AppKit
import SwiftUI

struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var textFormat: LineformTextFormat
    @Binding var plainTextConversion: MarkdownPlainTextConversion?
    @Binding var requestedSelection: NSRange?
    var profile: ReadingProfile
    var smoothsHorizontalInsetChanges = false
    var searchRanges: [NSRange] = []
    var activeSearchRange: NSRange?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            textFormat: $textFormat,
            plainTextConversion: $plainTextConversion
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = LineformEditorScrollView()
        scrollView.contentView = LineformEditorClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = LineformTextView()
        textView.string = text
        textView.correctsEmptyInsertionPointToFinalColumn = text.isEmpty
        textView.delegate = context.coordinator
        textView.smoothsHorizontalInsetChanges = smoothsHorizontalInsetChanges
        context.coordinator.configure(textView)
        context.coordinator.performWithoutSelectionUpdates {
            textView.applyTypography(profile)
            textView.refreshMarkdownHighlighting()
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? LineformTextView else {
            return
        }

        textView.smoothsHorizontalInsetChanges = smoothsHorizontalInsetChanges
        textView.correctsEmptyInsertionPointToFinalColumn = text.isEmpty
        textView.applyTypography(profile)
        context.coordinator.configure(textView)

        if textView.string != text {
            // A programmatic full-text replacement. When no explicit selection/scroll target
            // is requested (live reload), preserve the reader's place proportionally; the
            // sidebar swap requests (0,0) instead and is handled below.
            let preservesScroll = requestedSelection == nil
            let scrollRatio = preservesScroll ? textView.captureProportionalScrollOffset() : 0
            textView.string = text
            textView.refreshMarkdownHighlighting()
            if preservesScroll {
                DispatchQueue.main.async {
                    textView.restoreProportionalScrollOffset(scrollRatio)
                }
            }
        }

        textView.setSearchHighlights(searchRanges, activeRange: activeSearchRange)

        if let range = requestedSelection {
            let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: (textView.string as NSString).length))
            context.coordinator.performWithoutSelectionUpdates {
                textView.setSelectedRange(safeRange)
            }
            textView.scrollRangeToVisible(safeRange)
            DispatchQueue.main.async {
                requestedSelection = nil
            }
        }
    }
}

final class LineformEditorScrollView: NSScrollView {
    private var lockedVerticalScrollOriginDuringLayoutTransition: CGFloat?

    func lockVerticalBoundsOriginThroughLayoutTransition(
        duration: TimeInterval = EditorInspectorTextResponse.verticalBoundsOriginLockDuration
    ) {
        (contentView as? LineformEditorClipView)?.lockVerticalBoundsOrigin(duration: duration)
    }

    override func layout() {
        guard let textView = documentView as? LineformTextView else {
            super.layout()
            return
        }

        textView.preserveVisibleLayoutAnchorDuring(
            preservesVisualAnchor: textView.shouldPreserveVisualLayoutAnchorDuringLayoutTransition(),
            restoresAfterDeferredLayout: true,
            verticalScrollOrigin: verticalScrollOriginForLayoutPreservation(textView)
        ) {
            super.layout()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard let textView = documentView as? LineformTextView else {
            super.setFrameSize(newSize)
            return
        }

        if abs(newSize.width - frame.size.width) > 0.5 {
            lockVerticalBoundsOriginThroughLayoutTransition()
        }

        textView.preserveVisibleLayoutAnchorDuring(
            preservesVisualAnchor: textView.shouldPreserveVisualLayoutAnchorDuringLayoutTransition(),
            restoresAfterDeferredLayout: true,
            verticalScrollOrigin: verticalScrollOriginForLayoutPreservation(textView)
        ) {
            super.setFrameSize(newSize)
        }
    }

    private func verticalScrollOriginForLayoutPreservation(_ textView: LineformTextView) -> CGFloat? {
        guard textView.smoothsHorizontalInsetChanges else {
            lockedVerticalScrollOriginDuringLayoutTransition = nil
            return contentView.bounds.origin.y
        }

        if lockedVerticalScrollOriginDuringLayoutTransition == nil {
            lockedVerticalScrollOriginDuringLayoutTransition = contentView.bounds.origin.y
        }

        return lockedVerticalScrollOriginDuringLayoutTransition
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if
            let window,
            EditorFloatingControlHitTestRegistry.contains(
                windowPoint: convert(point, to: nil),
                in: window
            )
        {
            return nil
        }

        return super.hitTest(point)
    }
}

final class LineformEditorClipView: NSClipView {
    private var lockedVerticalBoundsOriginY: CGFloat?
    private var verticalBoundsOriginLockID: UUID?

    func lockVerticalBoundsOrigin(duration: TimeInterval) {
        let lockID = UUID()
        verticalBoundsOriginLockID = lockID
        lockedVerticalBoundsOriginY = bounds.origin.y

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard self?.verticalBoundsOriginLockID == lockID else {
                return
            }

            self?.verticalBoundsOriginLockID = nil
            self?.lockedVerticalBoundsOriginY = nil
        }
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        guard let lockedVerticalBoundsOriginY else {
            super.setBoundsOrigin(newOrigin)
            return
        }

        super.setBoundsOrigin(
            NSPoint(
                x: newOrigin.x,
                y: lockedVerticalBoundsOriginY
            )
        )
    }
}

final class Coordinator: NSObject, NSTextViewDelegate {
    private var text: Binding<String>
    private var textFormat: Binding<LineformTextFormat>
    private var plainTextConversion: Binding<MarkdownPlainTextConversion?>
    private var writingToolsSessionActive = false
    private var pendingWritingToolsText: String?
    private var suppressSelectionUpdates = false

    init(
        text: Binding<String>,
        textFormat: Binding<LineformTextFormat>,
        plainTextConversion: Binding<MarkdownPlainTextConversion?>
    ) {
        self.text = text
        self.textFormat = textFormat
        self.plainTextConversion = plainTextConversion
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

    func performWithoutSelectionUpdates(_ body: () -> Void) {
        suppressSelectionUpdates = true
        body()
        suppressSelectionUpdates = false
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
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !suppressSelectionUpdates else { return }
        guard let textView = notification.object as? NSTextView else {
            return
        }

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

    private func scheduleMarkdownHighlighting(for textView: LineformTextView) {
        let selector = #selector(LineformTextView.refreshMarkdownHighlightingAfterTypingDelay)
        NSObject.cancelPreviousPerformRequests(withTarget: textView, selector: selector, object: nil)
        textView.perform(selector, with: nil, afterDelay: 0.08, inModes: [.common])
    }
}

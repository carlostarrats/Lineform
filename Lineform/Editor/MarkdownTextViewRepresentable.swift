import AppKit
import SwiftUI

struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var textFormat: LineformTextFormat
    @Binding var plainTextConversion: MarkdownPlainTextConversion?
    @Binding var requestedSelection: NSRange?
    @Binding var requestedReplacement: MarkdownEdit?
    @Binding var requestedScrollToTopRange: NSRange?
    var profile: ReadingProfile
    /// The open document's containing folder, so a dragged/pasted image can be written next to the
    /// document (portable relative link). nil for an untitled document.
    var documentDirectory: URL?
    var smoothsHorizontalInsetChanges = false
    var searchRanges: [NSRange] = []
    var activeSearchRange: NSRange?
    /// The tab currently shown in this editor, so the text view uses that tab's undo manager.
    var activeTabID: UUID?
    /// Every open tab's id, so the coordinator can release undo managers for closed tabs.
    var liveTabIDs: Set<UUID> = []
    var onWritingToolsSessionChange: ((Bool) -> Void)?
    var onVisibleTopRangeChanged: ((NSRange) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            textFormat: $textFormat,
            plainTextConversion: $plainTextConversion,
            scrollToTopRange: $requestedScrollToTopRange
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
        // Select the active tab's undo manager before any edit can register one.
        context.coordinator.currentTabID = activeTabID
        context.coordinator.retainUndoManagers(for: liveTabIDs)
        textView.string = text
        context.coordinator.noteSyncedText(text)
        textView.correctsEmptyInsertionPointToFinalColumn = text.isEmpty
        textView.imageInsertionDocumentDirectory = documentDirectory
        textView.delegate = context.coordinator
        textView.smoothsHorizontalInsetChanges = smoothsHorizontalInsetChanges
        textView.onVisibleTopRangeChanged = onVisibleTopRangeChanged
        context.coordinator.writingToolsSessionChangeHandler = onWritingToolsSessionChange
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
        textView.imageInsertionDocumentDirectory = documentDirectory
        textView.applyTypography(profile)
        textView.onVisibleTopRangeChanged = onVisibleTopRangeChanged
        context.coordinator.writingToolsSessionChangeHandler = onWritingToolsSessionChange
        context.coordinator.configure(textView)
        // Point the text view at the active tab's undo manager. Because NSTextView asks the
        // delegate for its undo manager per edit, updating this before the text swap below means
        // a tab switch's incoming edits land in the right tab's history.
        context.coordinator.currentTabID = activeTabID
        context.coordinator.retainUndoManagers(for: liveTabIDs)

        if let replacement = requestedReplacement {
            // A Find & Replace edit. Route through the same undoable whole-text path the
            // formatting commands use (shouldChangeText → setAttributedString → didChangeText),
            // so it is a single ⌘Z step and syncs `text` back through the delegate. This
            // replaces the plain string-sync below for this cycle so the text lands exactly once.
            textView.applyExternalReplacement(replacement)
            DispatchQueue.main.async {
                requestedReplacement = nil
            }
        } else if context.coordinator.lastSyncedText != text && textView.string != text {
            // Cheap-first change detection: the binding almost always holds the exact value the
            // coordinator pushed (identical storage → ~0 ms compare). Only when it differs —
            // a genuine external replacement — pay for the whole-document comparison against
            // the freshly bridged textView.string (~11 ms on a 280K doc; see lastSyncedText).
            // A programmatic full-text replacement. When no explicit selection/scroll target
            // is requested (live reload), preserve the reader's place proportionally; the
            // sidebar swap requests (0,0) instead and is handled below.
            let preservesScroll = requestedSelection == nil
            let scrollRatio = preservesScroll ? textView.captureProportionalScrollOffset() : 0
            textView.string = text
            context.coordinator.noteSyncedText(text)
            textView.refreshMarkdownHighlighting()
            if preservesScroll {
                // Cancel any in-flight anchor restore (it captured the pre-reload layout) and
                // re-assert the proportional offset through the same deferred double-async the
                // anchor machinery uses, so our restore is enqueued last and wins.
                textView.cancelPendingDeferredScrollRestores()
                textView.restoreProportionalScrollOffsetAfterDeferredLayout(scrollRatio)
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

        if let range = requestedScrollToTopRange {
            let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: (textView.string as NSString).length))
            // Jumping from the outline scrolls the heading to the top WITHOUT selecting it —
            // the reader wanted to navigate, not highlight text. Collapse the insertion point
            // to the heading's start (so typing/caret is sensibly placed) but draw no selection.
            context.coordinator.performWithoutSelectionUpdates {
                textView.setSelectedRange(NSRange(location: safeRange.location, length: 0))
            }
            textView.scrollCharacterRangeToTop(safeRange)
            DispatchQueue.main.async {
                requestedScrollToTopRange = nil
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // AppKit doesn't guarantee textViewWritingToolsDidEnd if the view is torn down
        // mid-session (mode switch, document swap); end the session explicitly so observers
        // (the live-reload suspension) aren't left suspended forever.
        coordinator.endWritingToolsSessionIfNeeded()
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

    /// The visual-anchor restore's entry point: unlike ordinary `setBoundsOrigin` calls (which the
    /// transition lock pins so AppKit's own scroll adjustments can't lurch the view), an anchor
    /// restore is the CORRECTION that keeps the top visible character in place while the column
    /// rewraps — it must land, and the lock must then hold the CORRECTED origin. Without this,
    /// a manual window resize (continuous width changes re-engaging the lock) swallowed every
    /// restore and the text visibly jumped as it rewrapped.
    func setBoundsOriginBypassingVerticalLock(_ newOrigin: NSPoint) {
        if lockedVerticalBoundsOriginY != nil {
            lockedVerticalBoundsOriginY = newOrigin.y
        }
        super.setBoundsOrigin(newOrigin)
    }

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
    private var scrollToTopRange: Binding<NSRange?>
    private var writingToolsSessionActive = false
    private var pendingWritingToolsText: String?
    private var suppressSelectionUpdates = false
    /// The exact String value last synced between the text view and the binding (in either
    /// direction). `updateNSView` compares the binding against THIS before falling back to the
    /// expensive whole-document `textView.string != text` walk: the binding hands back the very
    /// value we pushed, so the comparison hits Swift's identical-storage fast path (~0 ms),
    /// whereas comparing against a freshly bridged `textView.string` walks all 280K+ chars —
    /// measured at ~11 ms per call, 4-5 calls per keystroke: the large-doc caret trail
    /// (diagnosed with in-app timing, 2026-07-05). Only a genuine external replacement
    /// (live reload, sidebar swap, Read-mode checkbox toggle) differs from this value.
    private(set) var lastSyncedText: String?

    // MARK: - Per-tab undo
    //
    // The editor reuses ONE text view across all tabs, swapping its text on switch. A single
    // shared undo manager would let ⌘Z in one tab replay another tab's reverse-edits against the
    // wrong text (corruption), which is why tab switches used to wipe undo entirely. Instead we
    // hand the text view a DISTINCT `UndoManager` per tab (via `undoManager(for:)`), so each tab
    // keeps its own history and can never touch another's. Autosave is unaffected — it is driven
    // by the SwiftUI document binding, not this manager (verified: change-count is set explicitly).
    private var undoManagersByTab: [UUID: UndoManager] = [:]
    /// The tab whose undo manager the text view should currently use. Set from `updateNSView`.
    var currentTabID: UUID?

    /// The undo manager for the active tab, created on first use. Returning a per-tab manager
    /// here overrides the responder-chain (document) manager the text view would otherwise use.
    func undoManager(for textView: NSTextView) -> UndoManager? {
        guard let currentTabID else { return nil }
        if let existing = undoManagersByTab[currentTabID] {
            return existing
        }
        let manager = UndoManager()
        undoManagersByTab[currentTabID] = manager
        return manager
    }

    /// Drops undo managers for tabs that are no longer open, so a long-lived window doesn't
    /// accumulate the undo history of every tab ever closed.
    func retainUndoManagers(for liveTabIDs: Set<UUID>) {
        guard !liveTabIDs.isEmpty else { return }
        undoManagersByTab = undoManagersByTab.filter { liveTabIDs.contains($0.key) }
    }

    func noteSyncedText(_ value: String) {
        lastSyncedText = value
    }

    init(
        text: Binding<String>,
        textFormat: Binding<LineformTextFormat>,
        plainTextConversion: Binding<MarkdownPlainTextConversion?>,
        scrollToTopRange: Binding<NSRange?> = .constant(nil)
    ) {
        self.text = text
        self.textFormat = textFormat
        self.plainTextConversion = plainTextConversion
        self.scrollToTopRange = scrollToTopRange
    }

    var writingToolsSessionChangeHandler: ((Bool) -> Void)?

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

    /// Teardown path: if the view is dismantled mid-Writing-Tools-session, release the
    /// deferred text (it was never committed) and notify observers the session is over.
    func endWritingToolsSessionIfNeeded() {
        guard writingToolsSessionActive else { return }
        writingToolsSessionActive = false
        pendingWritingToolsText = nil
        writingToolsSessionChangeHandler?(false)
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else {
            return
        }

        if writingToolsSessionActive {
            pendingWritingToolsText = textView.string
        } else {
            let snapshot = textView.string
            text.wrappedValue = snapshot
            lastSyncedText = snapshot
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
        writingToolsSessionChangeHandler?(true)
    }

    func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        writingToolsSessionActive = false
        let snapshot = pendingWritingToolsText ?? textView.string
        text.wrappedValue = snapshot
        lastSyncedText = snapshot
        pendingWritingToolsText = nil
        (textView as? LineformTextView)?.writingToolsDidEnd()
        writingToolsSessionChangeHandler?(false)
    }

    func textView(_ textView: NSTextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
        (textView as? LineformTextView)?.writingToolsIgnoredRanges(in: enclosingRange) ?? []
    }

    private func scheduleMarkdownHighlighting(for textView: LineformTextView) {
        let selector = #selector(LineformTextView.refreshMarkdownHighlightingAfterTypingDelay)
        NSObject.cancelPreviousPerformRequests(withTarget: textView, selector: selector, object: nil)
        // 0.25s, not 0.08s: fast typing has ~80-120ms inter-key gaps, so an 0.08s delay fires
        // BETWEEN keystrokes mid-burst — each pass re-attributes the visible window and forces
        // a full-viewport repaint, feeding the large-doc caret trail (measured 2026-07-05).
        // A quarter second coalesces the burst and recolors on the actual pause.
        textView.perform(selector, with: nil, afterDelay: 0.25, inModes: [.common])
    }
}

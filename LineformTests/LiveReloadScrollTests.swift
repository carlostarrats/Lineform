import XCTest
import SwiftUI
@testable import Lineform

@MainActor
final class LiveReloadScrollTests: XCTestCase {
    /// Drives the representable's text externally (like a live reload) via an observable model,
    /// so SwiftUI runs `updateNSView` with `requestedSelection == nil` — the scroll-preserving path.
    private final class ReloadTestModel: ObservableObject {
        @Published var text: String
        @Published var requestedSelection: NSRange?
        init(text: String) { self.text = text }
    }

    private struct ReloadTestHost: View {
        @ObservedObject var model: ReloadTestModel
        @State private var format = LineformTextFormat.markdown
        @State private var conversion: MarkdownPlainTextConversion?
        @State private var requestedReplacement: MarkdownEdit?
        @State private var requestedScrollToTopRange: NSRange?

        var body: some View {
            MarkdownTextViewRepresentable(
                text: $model.text,
                textFormat: $format,
                plainTextConversion: $conversion,
                requestedSelection: $model.requestedSelection,
                requestedReplacement: $requestedReplacement,
                requestedScrollToTopRange: $requestedScrollToTopRange,
                profile: .original
            )
        }
    }

    private func pump(_ duration: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: duration)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func firstTextView(in view: NSView) -> LineformTextView? {
        if let match = view as? LineformTextView { return match }
        for subview in view.subviews {
            if let match = firstTextView(in: subview) { return match }
        }
        return nil
    }

    func testSplitJumpUsesOnePhysicalSourceWhenLinkedAndBothPanesWhenUnlinked() {
        let range = NSRange(location: 420, length: 12)

        let linked = SplitScrollJumpPlan(range: range, isLinked: true)
        XCTAssertEqual(linked.editorRange, range)
        XCTAssertNil(linked.previewRange)

        let unlinked = SplitScrollJumpPlan(range: range, isLinked: false)
        XCTAssertEqual(unlinked.editorRange, range)
        XCTAssertEqual(unlinked.previewRange, range)
    }

    func testExternalReloadPreservesProportionalScroll() throws {
        let longText = (0..<400).map { "Line \($0)" }.joined(separator: "\n")
        let model = ReloadTestModel(text: longText)
        let hostingView = NSHostingView(rootView: AnyView(ReloadTestHost(model: model)))
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        // Pump past the mount-time vertical-bounds-origin lock (0.45s) so our scroll sticks.
        pump(0.7)

        let textView = try XCTUnwrap(firstTextView(in: hostingView))
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)

        let midOrigin = (textView.bounds.height - scrollView.contentView.bounds.height) * 0.5
        XCTAssertGreaterThan(midOrigin, 0, "test document must be taller than the viewport")
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: midOrigin))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Capture immediately (no pump) so a stray layout pass cannot reset the origin first.
        let ratioBefore = textView.captureProportionalScrollOffset()
        XCTAssertGreaterThan(ratioBefore, 0.2)

        // Simulate an external reload with a *shorter* document, no requestedSelection. The
        // shorter content changes the document height, so a stale-height restore would land
        // wrong (clamped to the bottom) — this exercises the ensureLayout fix.
        model.text = (0..<150).map { "Reloaded line \($0)" }.joined(separator: "\n")
        pump(0.5)

        let ratioAfter = textView.captureProportionalScrollOffset()
        XCTAssertEqual(ratioAfter, ratioBefore, accuracy: 0.15, "reload should preserve proportional scroll despite the changed document height")
        window.close()
    }

    func testLinkedSplitScrollMovesTheOtherPaneInTheSameEventTurn() throws {
        let longText = (0..<180).map { index in
            "# Section \(index)\n\nParagraph \(index) with **bold text**, `code`, and enough words to wrap across the writing column.\n\n- List item \(index)"
        }.joined(separator: "\n\n")
        let synchronizer = SplitScrollSynchronizer()

        let editorScrollView = LineformEditorScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 600))
        editorScrollView.contentView = LineformEditorClipView()
        editorScrollView.hasVerticalScroller = true
        let editor = LineformTextView()
        editor.string = longText
        editor.applyTypography(.original)
        editor.splitScrollSynchronizer = synchronizer
        editorScrollView.documentView = editor
        editor.updateScrollBoundsObservation()
        synchronizer.connect(editor: editor)

        let previewScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 600))
        previewScrollView.hasVerticalScroller = true
        let preview = MarkdownPreviewTextView()
        preview.splitScrollSynchronizer = synchronizer
        previewScrollView.documentView = preview
        preview.updateScrollBoundsObservation()
        synchronizer.connect(preview: preview)
        preview.apply(text: longText, profile: .original)
        if let layoutManager = preview.layoutManager, let textContainer = preview.textContainer {
            // This test has no window, so AppKit never performs the normal document-view sizing
            // pass. Size the fixture here; linked scrolling itself must not force text layout.
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
                + preview.textContainerInset.height * 2
            preview.setFrameSize(NSSize(width: 450, height: max(600, ceil(usedHeight))))
        }

        editorScrollView.layoutSubtreeIfNeeded()
        previewScrollView.layoutSubtreeIfNeeded()

        let editorMaximumY = editor.frame.height - editorScrollView.contentView.bounds.height
        XCTAssertGreaterThan(editorMaximumY, 0, "test source must be taller than the viewport")
        let requestedEditorY = editorMaximumY * 0.35
        editorScrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: requestedEditorY))
        editorScrollView.reflectScrolledClipView(editorScrollView.contentView)

        // Bounds-change notifications are synchronous. Reading Preview's position without pumping
        // the run loop proves the link does not go through the debounced outline/SwiftUI path.
        let linkedPreviewY = previewScrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(linkedPreviewY, 0)
        let previewMaximumY = preview.frame.height - previewScrollView.contentView.bounds.height
        XCTAssertEqual(linkedPreviewY, min(requestedEditorY, previewMaximumY), accuracy: 0.01)
        XCTAssertEqual(
            editorScrollView.contentView.bounds.origin.y,
            requestedEditorY,
            accuracy: 0.5,
            "the destination notification must not echo back and move the pane being scrolled"
        )

        let editorYBeforeRoutedScroll = editorScrollView.contentView.bounds.origin.y
        let previewYBeforeRoutedScroll = previewScrollView.contentView.bounds.origin.y
        editorScrollView.contentView.setBoundsOrigin(
            NSPoint(x: 0, y: editorYBeforeRoutedScroll + 37)
        )
        editorScrollView.reflectScrolledClipView(editorScrollView.contentView)
        XCTAssertEqual(
            editorScrollView.contentView.bounds.origin.y - editorYBeforeRoutedScroll,
            previewScrollView.contentView.bounds.origin.y - previewYBeforeRoutedScroll,
            accuracy: 0.01,
            "the paired pane should receive the exact pixel delta without a layout reconciliation"
        )
        let routedPreviewY = previewScrollView.contentView.bounds.origin.y

        synchronizer.isLinked = false
        editorScrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: editorMaximumY * 0.55))
        editorScrollView.reflectScrolledClipView(editorScrollView.contentView)
        XCTAssertEqual(previewScrollView.contentView.bounds.origin.y, routedPreviewY, accuracy: 0.5)

        synchronizer.isLinked = true
        synchronizer.alignPreviewToEditor()
        XCTAssertEqual(
            previewScrollView.contentView.bounds.origin.y,
            min(editorScrollView.contentView.bounds.origin.y, previewMaximumY),
            accuracy: 0.01,
            "re-linking should copy the editor's physical Y position once"
        )

        let requestedPreviewY = max(0, previewScrollView.contentView.bounds.origin.y - 29)
        previewScrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: requestedPreviewY))
        previewScrollView.reflectScrolledClipView(previewScrollView.contentView)
        XCTAssertEqual(
            editorScrollView.contentView.bounds.origin.y,
            requestedPreviewY,
            accuracy: 0.01,
            "scrolling Preview should synchronously assign the same physical Y to Write"
        )
    }
}

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

        var body: some View {
            MarkdownTextViewRepresentable(
                text: $model.text,
                textFormat: $format,
                plainTextConversion: $conversion,
                requestedSelection: $model.requestedSelection,
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
}

import AppKit
import XCTest
@testable import Lineform

/// Hosted (scroll-geometry) integration: a large doc in a real NSScrollView colorizes the
/// visible top on a full refresh, leaves deep off-screen text at base color, then colorizes
/// it after a programmatic scroll + settle. Lives in the HOSTED plan because it depends on
/// real layout/scroll geometry (timing/environment-sensitive), like the other quarantined
/// view tests.
final class ScopedHighlightingScrollHostedTests: XCTestCase {
    @MainActor
    func testScrollRevealsColorizedHeading() {
        let doc = "# Top\n" + String(repeating: "plain body line\n", count: 4000) + "# Bottom heading"

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scrollView.hasVerticalScroller = true
        let textView = LineformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        textView.string = doc
        textView.applyTypography(.original)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let storage = textView.textStorage!
        let ns = doc as NSString
        let bottomHash = ns.range(of: "# Bottom heading").location
        let marker = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        let base = Theme.theme(for: .original).textColor

        // Deep bottom heading is off-screen + past the margin → base color after a full refresh.
        textView.refreshMarkdownHighlighting()
        let before = storage.attribute(.foregroundColor, at: bottomHash, effectiveRange: nil) as! NSColor
        assertSameRGB(before, base)

        // Scroll to the bottom and run the (debounced) refresh synchronously.
        let docHeight = textView.frame.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, docHeight - 300)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.refreshVisibleTokensAfterScroll()

        let after = storage.attribute(.foregroundColor, at: bottomHash, effectiveRange: nil) as! NSColor
        assertSameRGB(after, marker)

        window.close()
    }

    private func assertSameRGB(_ a: NSColor, _ b: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        let ac = a.usingColorSpace(.sRGB)!, bc = b.usingColorSpace(.sRGB)!
        XCTAssertEqual(ac.redComponent, bc.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ac.greenComponent, bc.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ac.blueComponent, bc.blueComponent, accuracy: 0.01, file: file, line: line)
    }
}

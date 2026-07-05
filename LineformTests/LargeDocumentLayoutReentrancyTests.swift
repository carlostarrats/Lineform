import AppKit
import XCTest
@testable import Lineform

/// Regression tests for the layout re-entrancy stack-overflow crash (2026-07-05).
///
/// A large, not-yet-laid-out document in a scroll view crashes if `setFrameSize` re-enters
/// whole-container layout: AppKit's typesetter resizes the text view after each line fragment
/// it lays out (`_resizeTextViewForTextContainer` → `setFrameSize`), and the override's
/// `ensureLayout(for:)` calls (anchor capture + `sizePreservingScrollableDocumentHeight`) then
/// recursed once per remaining fragment — thousands deep — until the stack guard killed the
/// process (three crash logs on 2026-07-05, one captured interactively). The fix routes
/// typesetter-driven resizes through a plain `super.setFrameSize`
/// (`isRunningLayoutSensitiveEnsureLayout` in `LineformTextView`).
final class LargeDocumentLayoutReentrancyTests: XCTestCase {
    /// The exact crash repro: scroll view + ~280 KB document + `applyTypography` before any
    /// layout has completed. Before the fix this overflowed the stack (SIGSEGV) every run;
    /// completing at all is the assertion.
    @MainActor
    func testApplyTypographyOnLargeUnlaidOutDocumentDoesNotOverflowTheStack() {
        let doc = (1...2_000).map { i in
            i.isMultiple(of: 25)
                ? "## Section \(i) heading\n- list item with `inline code` and [a link](https://example.com/\(i))\n> a blockquote line here"
                : "Paragraph \(i) with some **bold** and _emphasis_ and `code\(i)` plus text to make lines wrap a bit longer than usual so scrolling has content."
        }.joined(separator: "\n")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let textView = LineformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        scrollView.documentView = textView
        textView.string = doc

        textView.applyTypography(.original)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        // Sanity: the document laid out and kept its content.
        XCTAssertEqual((textView.string as NSString).length, (doc as NSString).length)
        XCTAssertGreaterThan(textView.frame.height, 500)
    }
}

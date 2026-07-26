import XCTest
@testable import Lineform

/// The horizontal-inset animation runs on a REPEATING `Timer(target: self)`, which retains the
/// text view. Anything that leaves that timer scheduled leaks the view, its layout manager, and
/// the document's text storage — and keeps running layout at 120 Hz on a view nobody can see.
final class LineformTextViewInsetAnimationTests: XCTestCase {
    /// Starts a real inset animation and returns the view with the timer scheduled.
    @MainActor
    private func makeAnimatingTextView(in container: NSView) -> LineformTextView {
        let textView = LineformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 1400, height: 400)
        textView.smoothsHorizontalInsetChanges = true
        container.addSubview(textView)

        var profile = ReadingProfile.original
        profile.columnWidth = ReadingProfile.columnWidthMaximum
        // First application establishes the baseline (no animation)…
        textView.applyTypography(profile)
        // …a second one at a very different column width animates toward the new inset.
        profile.columnWidth = ReadingProfile.columnWidthMinimum
        textView.applyTypography(profile)

        return textView
    }

    @MainActor
    func testLeavingTheWindowMidAnimationStopsTheRetainingTimer() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container

        let textView = makeAnimatingTextView(in: container)
        try XCTSkipUnless(
            textView.isAnimatingHorizontalInset,
            "column-width change did not start an animation; nothing to assert"
        )

        // Closing a tab/window or switching Write → Read discards the editor mid-animation.
        textView.removeFromSuperview()

        XCTAssertFalse(
            textView.isAnimatingHorizontalInset,
            "the inset timer must stop when the view leaves its window — it retains the view"
        )
    }

    /// The watchdog that force-ends a non-converging animation is defensive: its trigger (a
    /// missing text container making the target unreachable) cannot be staged from a test
    /// without reaching into AppKit's own invariants. Pin the budget instead, so the grace
    /// period can't be widened into "effectively never".
    func testNonConvergingAnimationWatchdogHasABoundedGracePeriod() {
        XCTAssertGreaterThan(LineformTextView.horizontalInsetAnimationGracePeriod, 0)
        XCTAssertLessThanOrEqual(LineformTextView.horizontalInsetAnimationGracePeriod, 5)
    }
}

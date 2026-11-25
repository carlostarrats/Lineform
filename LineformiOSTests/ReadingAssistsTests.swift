import LineformCore
import UIKit
import XCTest
@testable import LineformiOS

/// The reading assists in the iPhone editor: the Reading Ruler (a tint band behind the current
/// line, never over its glyphs) and Typewriter Mode (the caret line held at the vertical centre).
/// Both follow the reading profile's `readingRulerEnabled` and `typewriterModeEnabled`.
///
/// The editors live in a window: an off-window `UITextView` ignores `setContentOffset`.
@MainActor
final class ReadingAssistsTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - Reading Ruler

    func testRulerRectMatchesCurrentLine() throws {
        let text = "First line\nThe second line is long enough to wrap across more than one line on an iPhone screen.\nThird"
        let textView = makeEditor(text, profile: Self.profile(ruler: true))
        let ns = text as NSString

        textView.selectedRange = NSRange(location: ns.range(of: "second").location, length: 0)
        textView.refreshReadingAssists()

        let ruler = try XCTUnwrap(textView.readingRulerView)
        XCTAssertFalse(ruler.isHidden)
        let expected = Self.expectedBand(textView, line: ns.lineRange(for: NSRange(location: ns.range(of: "second").location, length: 0)))
        XCTAssertEqual(ruler.frame, expected, "the band covers the current line's enclosing rects, full column width")
        XCTAssertGreaterThan(ruler.frame.height, textView.font?.lineHeight ?? 1, "a wrapped line is covered in full")

        // Behind the glyphs: the lowest subview, below UIKit's text container view.
        XCTAssertEqual(textView.subviews.first, ruler, "the ruler is drawn behind the text, never over it")
        XCTAssertFalse(ruler.isUserInteractionEnabled)
        XCTAssertEqual(
            ruler.backgroundColor?.resolvedColor(with: textView.traitCollection),
            Theme.theme(for: textView.profile).caretColor
                .withAlphaComponent(LineformTextView.readingRulerFillOpacity).resolvedColor(with: textView.traitCollection),
            "the theme's ink at alpha 0.12 (the caret itself is the highlighter's blue)"
        )
        XCTAssertEqual(LineformTextView.readingRulerFillOpacity, 0.12)

        // It follows the caret.
        textView.selectedRange = NSRange(location: ns.length, length: 0)
        textView.refreshReadingAssists()
        XCTAssertEqual(ruler.frame, Self.expectedBand(textView, line: ns.lineRange(for: NSRange(location: ns.length - 1, length: 0))))
    }

    func testRulerOffDrawsNothing() {
        let textView = makeEditor("One\nTwo\n", profile: .original)
        textView.refreshReadingAssists()
        XCTAssertTrue(textView.readingRulerView?.isHidden ?? true, "no ruler while the profile has it off")

        textView.profile = Self.profile(ruler: true)
        XCTAssertEqual(textView.readingRulerView?.isHidden, false, "the profile turns it on without another call")

        textView.profile = .original
        XCTAssertTrue(textView.readingRulerView?.isHidden ?? true, "turning it off removes the band")

        let empty = makeEditor("", profile: Self.profile(ruler: true))
        empty.refreshReadingAssists()
        XCTAssertTrue(empty.readingRulerView?.isHidden ?? true, "an empty document has no line to mark")
    }

    // MARK: - Typewriter Mode

    func testTypewriterCentersCaretLine() throws {
        let text = Self.longDocument(lines: 400)
        let textView = makeEditor(text, profile: Self.profile(typewriter: true))
        let ns = text as NSString
        let caret = ns.range(of: "line 200 ").location
        textView.selectedRange = NSRange(location: caret, length: 0)
        textView.refreshReadingAssists()

        let lineRect = Self.lineFragment(textView, at: caret)
        let visibleHeight = textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
        XCTAssertEqual(textView.contentOffset.y + textView.adjustedContentInset.top + visibleHeight / 2, lineRect.midY, accuracy: 0.5,
                       "the caret line sits at the vertical centre")

        // Typing on: an edit keeps it centred.
        textView.selectedRange = NSRange(location: ns.range(of: "line 260 ").location, length: 0)
        textView.insertText("x")
        textView.refreshReadingAssists()
        let moved = Self.lineFragment(textView, at: textView.selectedRange.location)
        XCTAssertEqual(textView.contentOffset.y + textView.adjustedContentInset.top + visibleHeight / 2, moved.midY, accuracy: 0.5)

        // Near the top it never scrolls above the document.
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.refreshReadingAssists()
        XCTAssertEqual(textView.contentOffset.y, -textView.adjustedContentInset.top, accuracy: 0.5)
    }

    func testTypewriterOffRestoresOffset() {
        let text = Self.longDocument(lines: 400)
        let textView = makeEditor(text, profile: .original)
        textView.setContentOffset(CGPoint(x: 0, y: 1_234), animated: false)
        XCTAssertEqual(textView.contentOffset.y, 1_234, accuracy: 0.5, "hosted in a window, the offset sticks")
        textView.selectedRange = NSRange(location: (text as NSString).range(of: "line 300 ").location, length: 0)

        textView.profile = Self.profile(typewriter: true)
        XCTAssertNotEqual(textView.contentOffset.y, 1_234, accuracy: 1, "turning it on centres the caret line")

        textView.profile = .original
        XCTAssertEqual(textView.contentOffset.y, 1_234, accuracy: 0.5, "turning it off restores where the writer was")

        // Off, nothing recentres.
        textView.refreshReadingAssists()
        XCTAssertEqual(textView.contentOffset.y, 1_234, accuracy: 0.5)
    }

    /// A selection (a handle being dragged) holds the page still; collapsing it to a caret centres
    /// again.
    func testTypewriterHoldsStillWhileASelectionIsMade() {
        let text = Self.longDocument(lines: 400)
        let textView = makeEditor(text, profile: Self.profile(typewriter: true))
        let ns = text as NSString
        let caret = ns.range(of: "line 200 ").location
        textView.selectedRange = NSRange(location: caret, length: 0)
        textView.refreshReadingAssists()
        let centred = textView.contentOffset.y

        // The handle drags down over many lines: no re-centring on each change.
        for lines in [3, 12, 30] {
            let end = ns.range(of: "line \(200 + lines) ").location
            textView.selectedRange = NSRange(location: caret, length: end - caret)
            textView.refreshReadingAssists()
            XCTAssertEqual(textView.contentOffset.y, centred, accuracy: 0.5, "still while \(lines) lines are selected")
        }

        // Collapsed to a caret further down (a tap): centred on it again.
        let later = ns.range(of: "line 230 ").location
        textView.selectedRange = NSRange(location: later, length: 0)
        textView.refreshReadingAssists()
        let lineRect = Self.lineFragment(textView, at: later)
        let visibleHeight = textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
        XCTAssertEqual(textView.contentOffset.y + textView.adjustedContentInset.top + visibleHeight / 2, lineRect.midY, accuracy: 0.5)
    }

    func testTypewriterWaitsForTheKeyboardToSettle() {
        let text = Self.longDocument(lines: 400)
        let textView = makeEditor(text, profile: Self.profile(typewriter: true))
        let caret = (text as NSString).range(of: "line 200 ").location
        textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        textView.selectedRange = NSRange(location: caret, length: 0)

        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                        userInfo: [UIResponder.keyboardAnimationDurationUserInfoKey: 10.0])
        textView.refreshReadingAssists()
        XCTAssertEqual(textView.contentOffset.y, 500, accuracy: 0.5, "no centring while the keyboard animates")

        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        let lineRect = Self.lineFragment(textView, at: caret)
        let visibleHeight = textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
        XCTAssertEqual(textView.contentOffset.y + textView.adjustedContentInset.top + visibleHeight / 2, lineRect.midY, accuracy: 0.5,
                       "once the keyboard settles, the caret line is centred")
    }

    // MARK: - Helpers

    private static func profile(ruler: Bool = false, typewriter: Bool = false) -> ReadingProfile {
        var profile = ReadingProfile.original
        profile.readingRulerEnabled = ruler
        profile.typewriterModeEnabled = typewriter
        return profile
    }

    /// The band the Mac draws: the line's enclosing rects, widened to the column, outset 6 × 2.
    private static func expectedBand(_ textView: LineformTextView, line: NSRange) -> CGRect {
        let layoutManager = textView.layoutManager
        let glyphs = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        var union = CGRect.null
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                              withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: textView.textContainer) { rect, _ in
            union = union.union(rect)
        }
        union.origin.x += textView.textContainerInset.left
        union.origin.y += textView.textContainerInset.top
        union.size.width = max(union.width, textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right)
        return union.insetBy(dx: -6, dy: -2)
    }

    private static func lineFragment(_ textView: LineformTextView, at location: Int) -> CGRect {
        let glyph = textView.layoutManager.glyphIndexForCharacter(at: location)
        var rect = textView.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        rect.origin.y += textView.textContainerInset.top
        return rect
    }

    private static func longDocument(lines: Int) -> String {
        (0..<lines).map { "line \($0) of a document long enough to scroll" }.joined(separator: "\n") + "\n"
    }

    private func makeEditor(_ text: String, profile: ReadingProfile) -> LineformTextView {
        let textView = LineformTextView.make(profile: profile)
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window?.isHidden = true
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            window.rootViewController = host
            host.view.addSubview(textView)
            window.isHidden = false
            self.window = window
        }
        textView.setDocumentText(text)
        textView.layoutIfNeeded()
        return textView
    }
}

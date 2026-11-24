import LineformCore
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// The iPhone's highlighter selection: the system fill is replaced through the public
/// `UITextSelectionDisplayInteraction.highlightView`, the strokes are shape layers behind the text,
/// only the visible lines are drawn, and nothing reaches the text storage.
@MainActor
final class PhoneHighlighterSelectionTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func hostedEditor(_ text: String) throws -> LineformTextView {
        let editor = LineformTextView.make(profile: .original)
        editor.setDocumentText(text)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        editor.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        host.view.addSubview(editor)
        window.makeKeyAndVisible()
        self.window = window
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.layoutIfNeeded()
        return editor
    }

    private func select(_ range: NSRange, in editor: LineformTextView) {
        editor.selectedRange = range
        editor.setNeedsHighlighterSelectionRedraw()
        editor.layoutIfNeeded()
    }

    private var visibleStrokes: (LineformTextView) -> [CAShapeLayer] {
        { editor in (editor.highlighterSelectionView?.strokeLayers ?? []).filter { !$0.isHidden && $0.path != nil } }
    }

    func testTheSystemFillIsReplacedAndTheCaretAndHandlesStay() throws {
        let editor = try hostedEditor("In response, the company responsibly disclosed the vulnerability.\n")
        select(NSRange(location: 3, length: 20), in: editor)
        XCTAssertTrue(editor.replacesSystemSelectionHighlight, "the text view's selection display was found")
        let display = try XCTUnwrap(editor.interactions.compactMap { $0 as? UITextSelectionDisplayInteraction }.first)
        XCTAssertTrue(display.highlightView is HiddenSelectionHighlightView)
        XCTAssertTrue(display.highlightView.isHidden, "the system fill draws nothing")
        XCTAssertTrue(display.isActivated, "the caret and handles are still the system's")
    }

    func testStrokesAreDrawnBehindTheTextAndNeverStored() throws {
        let text = "In response, the company responsibly disclosed the identified zero-day vulnerability in the internally-hosted software.\n"
        let editor = try hostedEditor(text)
        let before = try XCTUnwrap(editor.textStorage.copy() as? NSAttributedString)
        select(NSRange(location: 0, length: (text as NSString).length - 1), in: editor)
        let strokes = visibleStrokes(editor)
        XCTAssertGreaterThan(strokes.count, 1, "one stroke per line")
        XCTAssertEqual(strokes.count, editor.highlighterSelectionLines(for: editor.selectedRange).count)
        let view = try XCTUnwrap(editor.highlighterSelectionView)
        XCTAssertTrue(view.superview === editor)
        // Behind the text: a lower subview than anything UIKit draws glyphs in.
        let viewIndex = try XCTUnwrap(editor.subviews.firstIndex(of: view))
        XCTAssertEqual(viewIndex, 0, "the stroke view sits under the text")
        XCTAssertEqual(editor.textStorage, before, "the selection never touches the text storage")

        select(NSRange(location: 4, length: 0), in: editor)
        XCTAssertTrue(visibleStrokes(editor).isEmpty, "a caret draws no stroke")
        XCTAssertTrue(view.isHidden)
    }

    func testOnlyTheVisibleLinesAreDrawnOnALargeDocument() throws {
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20) + "\n\n"
        let text = String(repeating: paragraph, count: 1_200) // just over 1 MB
        XCTAssertGreaterThan((text as NSString).length, 1_000_000)
        let editor = try hostedEditor(text)
        let start = Date()
        select(NSRange(location: 0, length: (text as NSString).length), in: editor)
        let elapsed = Date().timeIntervalSince(start)
        let strokes = visibleStrokes(editor).count
        XCTAssertGreaterThan(strokes, 0)
        XCTAssertLessThan(strokes, 60, "one screenful of lines, never the document")
        XCTAssertLessThan(elapsed, 0.5, "Select All on 1 MB stays quick (Debug, simulator)")
    }

    func testResigningHidesTheStrokes() throws {
        let editor = try hostedEditor("Hello world\n")
        select(NSRange(location: 0, length: 5), in: editor)
        XCTAssertFalse(visibleStrokes(editor).isEmpty)
        _ = editor.resignFirstResponder()
        editor.layoutIfNeeded()
        XCTAssertTrue(visibleStrokes(editor).isEmpty, "as UIKit hides a resigned text view's selection")
    }
}

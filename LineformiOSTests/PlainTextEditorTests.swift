import LineformCore
import UIKit
import XCTest
@testable import LineformiOS

@MainActor
final class PlainTextEditorTests: XCTestCase {
    func testEditorIsTextKit1() {
        let textView = PlainTextEditor.makeTextView(profile: .original)
        XCTAssertNil(textView.textLayoutManager, "the editor must stay on TextKit 1")
        XCTAssertNotNil(textView.layoutManager)
    }

    func testEditorUsesThemePageColour() {
        let textView = PlainTextEditor.makeTextView(profile: .original)
        let theme = Theme.theme(for: ReadingProfile.original)
        XCTAssertEqual(textView.backgroundColor, theme.backgroundColor)
        XCTAssertEqual(textView.tintColor, theme.caretColor)
    }

    func testTypingUsesTheBaseMarkdownStyle() throws {
        let textView = PlainTextEditor.makeTextView(profile: .original)
        let expected = MarkdownTextStyle.baseAttributes(for: .original)
        let font = try XCTUnwrap(textView.typingAttributes[.font] as? UIFont)
        XCTAssertEqual(font, expected[.font] as? UIFont)
        XCTAssertEqual(textView.typingAttributes[.foregroundColor] as? UIColor, expected[.foregroundColor] as? UIColor)
        XCTAssertEqual(textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle, expected[.paragraphStyle] as? NSParagraphStyle)
    }

    func testColumnIsCentredWithAtLeastTwentyPointMargins() {
        let column = CGFloat(ReadingProfile.original.columnWidth)
        // iPhone width: the minimum margin wins.
        XCTAssertEqual(PlainTextEditor.horizontalInset(forWidth: 402, columnWidth: column), 20)
        // Wider than the column: the column is centred.
        XCTAssertEqual(PlainTextEditor.horizontalInset(forWidth: column + 200, columnWidth: column), 100)

        let textView = PlainTextEditor.makeTextView(profile: .original)
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.textContainerInset.left, 20)
        XCTAssertEqual(textView.textContainerInset.right, 20)
        XCTAssertEqual(textView.textContainer.lineFragmentPadding, 0)
    }
}

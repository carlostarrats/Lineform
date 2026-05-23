import AppKit
import XCTest
@testable import Lineform

@MainActor
final class LineformTextViewWritingToolsTests: XCTestCase {
    func testTextViewRemainsNativeNSTextViewWithTextKit2APISurface() {
        let textView = LineformTextView()

        XCTAssertTrue(textView is NSTextView)
        if #available(macOS 12.0, *) {
            _ = textView.textLayoutManager
        }
    }

    func testWritingToolsAreConfiguredForPlainMarkdown() {
        let textView = LineformTextView()

        if #available(macOS 15.0, *) {
            XCTAssertEqual(textView.writingToolsBehavior, .complete)
            XCTAssertTrue(textView.allowedWritingToolsResultOptions.contains(.plainText))
            XCTAssertFalse(textView.allowedWritingToolsResultOptions.contains(.table))
        }
    }
}

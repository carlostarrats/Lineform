import XCTest
@testable import Lineform

final class LineformTextViewEmptyStateTests: XCTestCase {
    func testTextViewExposesCalmEmptyStatePlaceholder() {
        let textView = LineformTextView()

        XCTAssertEqual(textView.emptyStatePlaceholder, "Start writing...")
    }
}

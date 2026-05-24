import XCTest
@testable import Lineform

final class LineformTextViewEmptyStateTests: XCTestCase {
    @MainActor
    func testTextViewExposesCalmEmptyStatePlaceholder() {
        let textView = LineformTextView()

        XCTAssertEqual(textView.emptyStatePlaceholder, "Start writing...")
    }
}

import XCTest
@testable import Lineform

final class AIReviewCompositionTests: XCTestCase {
    private func change(_ id: Int, _ needle: String, in text: String, _ replacement: String) -> AIChange {
        let range = (text as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "missing \(needle)")
        return AIChange(id: id, range: range, original: needle, replacement: replacement)
    }

    private func session(_ text: String, _ changes: [AIChange]) -> AIReviewSession {
        AIReviewSession(action: .rewrite, changes: changes,
                        selectionRange: NSRange(location: 0, length: (text as NSString).length),
                        originalSelection: text)
    }

    private func substring(_ string: String, _ range: NSRange?) -> String? {
        range.map { (string as NSString).substring(with: $0) }
    }

    func testCompositionSplicesInsertionsAndPills() {
        let text = "a big day"
        let composition = AIReviewComposition.build(text: text, session: session(text, [change(0, "big", in: text, "large")]))
        XCTAssertEqual(composition.string, "a biglarge\u{FFFC} day")
        XCTAssertEqual(substring(composition.string, composition.removedRanges[0]), "big")
        XCTAssertEqual(composition.removedRanges[0], NSRange(location: 2, length: 3))
        XCTAssertEqual(composition.pillIndices[0], 10)
        XCTAssertEqual((composition.string as NSString).character(at: 10), 0xFFFC)
        XCTAssertEqual(composition.changeID(atPill: 10), 0)
    }

    func testPureInsertionAndPureDeletion() {
        let text = "one two three"
        let insertion = AIChange(id: 0, range: NSRange(location: 3, length: 0), original: "", replacement: ",")
        let deletion = change(1, " three", in: text, "")
        let composition = AIReviewComposition.build(text: text, session: session(text, [insertion, deletion]))
        XCTAssertEqual(composition.string, "one,\u{FFFC} two three\u{FFFC}")
        XCTAssertNil(composition.removedRanges[0], "an insertion removes nothing")
        XCTAssertEqual(substring(composition.string, composition.removedRanges[1]), " three")
        XCTAssertEqual(composition.pillIndices, [0: 4, 1: 15])
    }

    func testTextBeforeFirstChangeIsIdentical() {
        let text = "# Title\r\n\r\nThe first line stays.\r\nA very big day was had.\r\nEnd."
        let changes = [change(0, "very ", in: text, ""), change(1, "big", in: text, "large")]
        let composition = AIReviewComposition.build(text: text, session: session(text, changes))
        let prefix = (text as NSString).substring(to: changes[0].range.location)
        XCTAssertTrue(composition.string.hasPrefix(prefix))
        XCTAssertTrue(composition.string.hasSuffix(" day was had.\r\nEnd."), "text after the last change is identical too")
    }

    func testKeptOriginalIsNotDimmed() {
        let text = "a big day"
        var review = session(text, [change(0, "big", in: text, "large")])
        review.toggleKeep(0)
        let composition = AIReviewComposition.build(text: text, session: review)
        XCTAssertNil(composition.removedRanges[0])
        XCTAssertEqual(substring(composition.string, composition.keptRanges[0]), "big")
        // What a kept accept writes: the original, the session's separator, the replacement.
        XCTAssertEqual(composition.string, "a big large\u{FFFC} day")
        XCTAssertEqual(composition.changeID(atRemovedOrKept: 3), 0)
    }

    func testDecidedChangesContributeNothing() {
        var text = "a big day and a good night"
        var review = session(text, [change(0, "big", in: text, "large"), change(1, "good", in: text, "fine"),
                                    change(2, "night", in: text, "evening")])
        let edit = try! XCTUnwrap(review.accept(0))
        text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        review.reject(2)
        let composition = AIReviewComposition.build(text: text, session: review)
        XCTAssertEqual(composition.string, "a large day and a goodfine\u{FFFC} night")
        XCTAssertEqual(Array(composition.pillIndices.keys), [1])
        XCTAssertEqual(Array(composition.removedRanges.keys), [1])
        XCTAssertEqual(substring(composition.string, composition.removedRanges[1]), "good")
        XCTAssertEqual(substring(composition.string, composition.changeRanges[1]), "goodfine\u{FFFC}")
    }

    func testStaleRangesAreSkippedNotCrashed() {
        let text = "short"
        let stale = AIChange(id: 0, range: NSRange(location: 40, length: 3), original: "big", replacement: "large")
        let composition = AIReviewComposition.build(text: text, session: session(text, [stale]))
        XCTAssertEqual(composition.string, text)
        XCTAssertTrue(composition.pillIndices.isEmpty)
    }
}

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

    // MARK: - Index mapping (scroll hand-over)

    private func assertRoundTrip(_ text: String, _ review: AIReviewSession, file: StaticString = #filePath, line: UInt = #line) {
        let composition = AIReviewComposition.build(text: text, session: review)
        let doc = text as NSString
        let shown = composition.string as NSString
        for index in 0...doc.length {
            let overlay = composition.overlayIndex(forDocumentIndex: index)
            XCTAssertEqual(composition.documentIndex(forOverlayIndex: overlay), index, "doc \(index)", file: file, line: line)
            if index < doc.length {
                XCTAssertEqual(shown.character(at: overlay), doc.character(at: index),
                               "doc \(index) shows its own character", file: file, line: line)
            }
        }
    }

    func testIndexMappingRoundTripsEveryDocumentCharacter() {
        let text = "a big day and a good night, one two three"
        var review = session(text, [
            change(0, "big", in: text, "considerably larger"),
            change(1, "good", in: text, "fine"),
            AIChange(id: 2, range: NSRange(location: 30, length: 0), original: "", replacement: " (inserted)"),
            change(3, " three", in: text, ""),
        ])
        assertRoundTrip(text, review)
        review.toggleKeep(1)
        assertRoundTrip(text, review)
    }

    func testTextAddedByAChangeMapsToTheChangesEnd() {
        let text = "a big day"
        let composition = AIReviewComposition.build(text: text, session: session(text, [change(0, "big", in: text, "large")]))
        // "a biglarge\u{FFFC} day": the replacement (5…9) and the pill (10) are not in the document.
        for overlay in 5...10 {
            XCTAssertEqual(composition.documentIndex(forOverlayIndex: overlay), 5, "overlay \(overlay)")
        }
        XCTAssertEqual(composition.documentIndex(forOverlayIndex: 3), 3, "inside the original: one to one")
        XCTAssertEqual(composition.documentIndex(forOverlayIndex: 12), 6, "after the change: shifted back")
        XCTAssertEqual(composition.overlayIndex(forDocumentIndex: 6), 12)
    }

    func testCacheRebuildsOnlyWhenSessionOrTextChanges() {
        let text = "a big day and a good night"
        var review = session(text, [change(0, "big", in: text, "large"), change(1, "good", in: text, "fine")])
        let cache = AIReviewCompositionCache()
        let first = cache.composition(text: text, session: review)
        _ = cache.composition(text: text, session: review)
        XCTAssertEqual(cache.buildCount, 1)
        review.move(by: 1)
        XCTAssertNotEqual(cache.composition(text: text, session: review), AIReviewComposition.empty)
        XCTAssertEqual(cache.buildCount, 2, "a new session state rebuilds")
        _ = cache.composition(text: text + " ", session: review)
        XCTAssertEqual(cache.buildCount, 3, "new text rebuilds")
        XCTAssertEqual(first, AIReviewComposition.build(text: text, session: session(text, [change(0, "big", in: text, "large"), change(1, "good", in: text, "fine")])))
    }
}

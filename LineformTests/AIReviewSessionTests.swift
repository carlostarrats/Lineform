import XCTest
@testable import Lineform

final class AIReviewSessionTests: XCTestCase {
    private func change(_ id: Int, _ location: Int, _ original: String, _ replacement: String) -> AIChange {
        AIChange(id: id, range: NSRange(location: location, length: (original as NSString).length),
                 original: original, replacement: replacement)
    }

    /// "The big dog ran far away." with three changes: big→large, ran→sprinted, " away"→"".
    private func threeChanges() -> AIReviewSession {
        let text = "The big dog ran far away."
        let ns = text as NSString
        return AIReviewSession(action: .rephrase, changes: [
            change(0, ns.range(of: "big").location, "big", "large"),
            change(1, ns.range(of: "ran").location, "ran", "sprinted"),
            change(2, ns.range(of: " away").location, " away", ""),
        ], selectionRange: NSRange(location: 0, length: ns.length), originalSelection: text)
    }

    private func apply(_ edits: [AIReviewEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits { result.replaceCharacters(in: edit.range, with: edit.replacement) }
        return result as String
    }

    /// Decisions are recorded, never applied one by one (2026-11-14): every accepted change's
    /// edits come back together, descending, in the coordinates of the document the review was
    /// built from — one apply, one undo step.
    func testAcceptsAreRecordedAndAppliedTogether() throws {
        var session = threeChanges()
        let text = "The big dog ran far away."
        XCTAssertTrue(session.accept(0))
        XCTAssertFalse(session.accept(0), "a decided change cannot be decided again")
        XCTAssertEqual(session.changes.map(\.range), threeChanges().changes.map(\.range), "nothing shifts")
        XCTAssertEqual(session.currentID, 1)
        session.reject(1)
        XCTAssertTrue(session.accept(2))
        XCTAssertTrue(session.isFinished)
        let edits = session.acceptedEdits
        XCTAssertEqual(edits.map(\.range.location), [(text as NSString).range(of: " away").location, 4], "descending")
        let after = apply(edits, to: text)
        XCTAssertEqual(after, "The large dog ran far.")
        session.shiftSelection(by: AIReviewSession.lengthDelta(of: edits))
        XCTAssertEqual(session.selectionRange, NSRange(location: 0, length: (after as NSString).length))
    }

    /// Proofread's navigation: ← / → over the PENDING changes (wrapping), a click selects one,
    /// Accept All accepts what is left; "2 of 3" counts all changes.
    func testMoveSelectAcceptAllAndPosition() {
        var session = threeChanges()
        XCTAssertEqual(session.position?.index, 1)
        XCTAssertEqual(session.position?.count, 3)
        session.move(by: 1)
        XCTAssertEqual(session.currentID, 1)
        session.move(by: -1)
        session.move(by: -1)
        XCTAssertEqual(session.currentID, 2, "wraps")
        session.select(0)
        XCTAssertEqual(session.currentID, 0)
        session.reject(0)
        XCTAssertEqual(session.currentID, 1)
        session.select(0)
        XCTAssertEqual(session.currentID, 1, "a decided change cannot be selected")
        session.acceptAllPending()
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.accepted.map(\.id), [1, 2])
        XCTAssertNil(session.currentID)
    }

    func testRejectDecidesWithoutEditsAndMovesToTheNextPendingChange() {
        var session = threeChanges()
        XCTAssertEqual(session.currentID, 0)
        session.reject(0)
        XCTAssertEqual(session.decisions[0], .rejected)
        XCTAssertFalse(session.acceptedAny)
        XCTAssertEqual(session.currentID, 1, "deciding the current change moves to the next pending one")
        session.reject(1)
        session.reject(2)
        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.currentID)
        XCTAssertFalse(session.acceptedAny)
    }

    /// One change across two list items: accepting it is one decision that returns one edit per
    /// changed segment (descending), never the whole span — the span crosses a line ending.
    func testMultiPartChangeAcceptsAsOneDecisionWithPerSegmentEdits() throws {
        let text = "- alpha one\n- beta two\n"
        let ns = text as NSString
        let segments = MarkdownStructureMap.proseSegments(in: text, selection: NSRange(location: 0, length: ns.length))
        let change = try XCTUnwrap(AIChangeBuilder.change(segments: segments, revisions: ["alpha 1", "beta 2"], in: text))
        var session = AIReviewSession(action: .rephrase, changes: [change],
                                      selectionRange: NSRange(location: 0, length: ns.length), originalSelection: text)
        XCTAssertTrue(session.accept(0))
        let edits = session.acceptedEdits
        XCTAssertEqual(edits.map(\.range), [ns.range(of: "beta two"), ns.range(of: "alpha one")])
        let after = apply(edits, to: text)
        XCTAssertEqual(after, "- alpha 1\n- beta 2\n")
        XCTAssertTrue(session.isFinished)
    }
}

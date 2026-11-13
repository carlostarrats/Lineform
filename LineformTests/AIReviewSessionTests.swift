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
        return AIReviewSession(action: .rewrite, changes: [
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

    func testAcceptShiftsLaterChangesAndSelection() throws {
        var session = threeChanges()
        let text = "The big dog ran far away."
        let edits = session.accept(0)
        XCTAssertEqual(edits.count, 1)
        let edit = try XCTUnwrap(edits.first)
        XCTAssertEqual(edit, AIReviewEdit(range: NSRange(location: 4, length: 3), replacement: "large"))
        let after = apply([edit], to: text)
        XCTAssertEqual(after, "The large dog ran far away.")
        let ran = try XCTUnwrap(session.changes.first { $0.id == 1 })
        XCTAssertEqual((after as NSString).substring(with: ran.range), "ran", "later changes move by the length delta")
        let away = try XCTUnwrap(session.changes.first { $0.id == 2 })
        XCTAssertEqual((after as NSString).substring(with: away.range), " away")
        XCTAssertEqual(session.selectionRange, NSRange(location: 0, length: (after as NSString).length))
        XCTAssertEqual(session.decisions[0], .accepted)
        XCTAssertTrue(session.acceptedAny)

        // A second accept is in the shifted coordinates.
        let second = try XCTUnwrap(session.accept(1).first)
        XCTAssertEqual(apply([second], to: after), "The large dog sprinted far away.")
        XCTAssertEqual(session.accept(1), [], "a decided change cannot be decided again")
    }

    func testKeepingDimmedTextKeepsOriginalAndInsertion() throws {
        var session = threeChanges()
        session.toggleKeep(0)
        XCTAssertEqual(session.keptOriginals, [0])
        let edit = try XCTUnwrap(session.accept(0).first)
        XCTAssertEqual(edit.replacement, "big large")
        XCTAssertEqual(apply([edit], to: "The big dog ran far away."), "The big large dog ran far away.")

        // Keeping a pure deletion keeps everything: no edit at all.
        session.toggleKeep(2)
        XCTAssertEqual(session.accept(2), [])
        XCTAssertEqual(session.decisions[2], .accepted)

        // Untoggling restores the plain replacement.
        var other = threeChanges()
        other.toggleKeep(1)
        other.toggleKeep(1)
        XCTAssertEqual(other.accept(1).first?.replacement, "sprinted")

        // No separator when a touching character is whitespace or a side is empty.
        var spaced = AIReviewSession(action: .rewrite, changes: [change(0, 0, "big ", "large")],
                                     selectionRange: NSRange(location: 0, length: 4), originalSelection: "big ")
        spaced.toggleKeep(0)
        XCTAssertEqual(spaced.accept(0).first?.replacement, "big large")
    }

    func testAcceptRemainingReturnsDescendingEdits() throws {
        var session = threeChanges()
        let text = "The big dog ran far away."
        session.reject(1)
        let edits = session.acceptRemaining()
        XCTAssertEqual(edits.map(\.range.location), edits.map(\.range.location).sorted(by: >))
        XCTAssertEqual(edits.count, 2)
        let after = apply(edits, to: text)
        XCTAssertEqual(after, "The large dog ran far.")
        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.currentID)
        XCTAssertEqual(session.selectionRange, NSRange(location: 0, length: (after as NSString).length))
        XCTAssertEqual((after as NSString).substring(with: try XCTUnwrap(session.changes.first { $0.id == 1 }).range), "ran")
    }

    func testHasDecidedAfterFirstDecision() {
        var session = threeChanges()
        XCTAssertFalse(session.hasDecided)
        XCTAssertEqual(session.position.current, 1)
        XCTAssertEqual(session.position.total, 3)
        session.reject(0)
        XCTAssertTrue(session.hasDecided)
        XCTAssertFalse(session.acceptedAny)
        XCTAssertEqual(session.currentID, 1, "deciding the current change moves to the next pending one")
        XCTAssertEqual(session.position.current, 2)
        session.rejectRemaining()
        XCTAssertTrue(session.isFinished)
        XCTAssertFalse(session.acceptedAny)
    }

    func testMoveWrapsOverPendingOnly() {
        var session = threeChanges()
        session.reject(1)
        XCTAssertEqual(session.currentID, 0)
        session.move(by: 1)
        XCTAssertEqual(session.currentID, 2, "the decided change is skipped")
        session.move(by: 1)
        XCTAssertEqual(session.currentID, 0, "wraps to the first pending change")
        session.move(by: -1)
        XCTAssertEqual(session.currentID, 2, "wraps backwards")
        XCTAssertEqual(session.position.current, 3, "position counts among all changes")
        session.acceptRemaining()
        session.move(by: 1)
        XCTAssertNil(session.currentID)
    }

    /// One change across two list items: accepting it is one decision that returns one edit per
    /// changed segment (descending), never the whole span — the span crosses a line ending.
    func testMultiPartChangeAcceptsAsOneDecisionWithPerSegmentEdits() throws {
        let text = "- alpha one\n- beta two\n"
        let ns = text as NSString
        let segments = MarkdownStructureMap.proseSegments(in: text, selection: NSRange(location: 0, length: ns.length))
        let change = try XCTUnwrap(AIChangeBuilder.change(segments: segments, revisions: ["alpha 1", "beta 2"], in: text))
        var session = AIReviewSession(action: .rewrite, changes: [change],
                                      selectionRange: NSRange(location: 0, length: ns.length), originalSelection: text)
        XCTAssertEqual(session.position.total, 1)
        let edits = session.accept(0)
        XCTAssertEqual(edits.map(\.range), [ns.range(of: "beta two"), ns.range(of: "alpha one")])
        let after = apply(edits, to: text)
        XCTAssertEqual(after, "- alpha 1\n- beta 2\n")
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.selectionRange, NSRange(location: 0, length: (after as NSString).length))
        XCTAssertEqual((after as NSString).substring(with: session.changes[0].range), "alpha 1\n- beta 2",
                       "an accepted change's range covers the text that replaced it")

        var batch = AIReviewSession(action: .rewrite, changes: [change],
                                    selectionRange: NSRange(location: 0, length: ns.length), originalSelection: text)
        XCTAssertEqual(apply(batch.acceptRemaining(), to: text), after, "Accept Remaining applies the same edits")

        var kept = AIReviewSession(action: .rewrite, changes: [change],
                                   selectionRange: NSRange(location: 0, length: ns.length), originalSelection: text)
        kept.toggleKeep(0)
        XCTAssertEqual(apply(kept.accept(0), to: text), "- alpha one alpha 1\n- beta two beta 2\n")
    }
}

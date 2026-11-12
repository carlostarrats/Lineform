import XCTest
@testable import Lineform

final class DocumentHistoryEngineTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEngine() -> DocumentHistoryEngine {
        let date = fixedDate
        return DocumentHistoryEngine(history: DocumentHistory(passages: []), now: { date })
    }

    private func range(of needle: String, in text: String) -> NSRange {
        let found = (text as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "missing \(needle)")
        return found
    }

    private func apply(_ edit: HistoryEdit?, to text: String) -> String {
        guard let edit else { return text }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private func replacing(_ old: String, with new: String, in text: String) -> String {
        (text as NSString).replacingCharacters(in: range(of: old, in: text), with: new)
    }

    private let sentenceText = "Alpha one goes first. Hello there brave new world. Omega two ends it."
    private let sentence = "Hello there brave new world."

    private let nestedText = "Intro paragraph sits here.\n\nFirst sentence is right here. Second sentence goes right here.\n\nOutro paragraph."
    private let paragraph = "First sentence is right here. Second sentence goes right here."
    private let innerSentence = "Second sentence goes right here."

    func testAddCreatesPassageWithFrozenCopyAndLiveVersion() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let passage = try XCTUnwrap(engine.history.passages.first { $0.id == id })
        XCTAssertEqual(passage.level, .sentence)
        XCTAssertEqual(passage.versions.count, 2)
        XCTAssertEqual(passage.currentIndex, 1)
        XCTAssertEqual(passage.versions.map(\.text), [sentence, sentence])
        XCTAssertEqual(passage.lastTouched, fixedDate)
        XCTAssertNil(passage.parentID)
    }

    func testStepReturnsEditReplacingCurrentText() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let edited = replacing("brave new", with: "bold and brave new", in: sentenceText)
        let edit = try XCTUnwrap(engine.step(id, by: -1, in: edited))
        XCTAssertEqual(edit, HistoryEdit(range: range(of: "Hello there bold and brave new world.", in: edited),
                                         replacement: sentence))
        XCTAssertEqual(apply(edit, to: edited), sentenceText)
    }

    func testTypedEditsToCurrentVersionSurviveSwitchingAway() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let typed = "Hello there bold and brave new world."
        let edited = replacing(sentence, with: typed, in: sentenceText)
        let back = apply(try XCTUnwrap(engine.step(id, by: -1, in: edited)), to: edited)
        XCTAssertEqual(back, sentenceText)
        let forward = try XCTUnwrap(engine.step(id, by: 1, in: back))
        XCTAssertEqual(forward.replacement, typed)
        XCTAssertEqual(apply(forward, to: back), edited)
    }

    func testPassageWhoseTextIsGoneIsDropped() throws {
        var engine = makeEngine()
        _ = try XCTUnwrap(engine.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        XCTAssertEqual(engine.locateAll(in: "Something else entirely was written here instead."), [])
        XCTAssertTrue(engine.history.isEmpty)
    }

    func testNestedPassageHiddenWhenParentShowsOtherVersion() throws {
        var engine = makeEngine()
        let parentID = try XCTUnwrap(engine.add(range(of: paragraph, in: nestedText), author: .you, in: nestedText))
        let childID = try XCTUnwrap(engine.add(range(of: innerSentence, in: nestedText), author: .you, in: nestedText))
        XCTAssertEqual(engine.locateAll(in: nestedText).map(\.id), [parentID, childID])
        XCTAssertEqual(engine.history.passages.first { $0.id == childID }?.parentID, parentID)

        // Edit the parent's live version outside the child, then switch the parent away.
        let edited = replacing("First sentence", with: "Opening sentence", in: nestedText)
        let older = apply(try XCTUnwrap(engine.step(parentID, by: -1, in: edited)), to: edited)
        XCTAssertEqual(older, nestedText)
        XCTAssertEqual(engine.locateAll(in: older).map(\.id), [parentID])
        XCTAssertEqual(engine.history.passages.count, 2, "hidden child is kept, not dropped")

        let restored = apply(try XCTUnwrap(engine.step(parentID, by: 1, in: older)), to: older)
        XCTAssertEqual(restored, edited)
        XCTAssertEqual(engine.locateAll(in: restored).map(\.id), [parentID, childID])
    }

    func testCannotAddInsideWordPassage() throws {
        var engine = makeEngine()
        let text = "Alpha one goes first. Hello there braveheart new world. Omega."
        _ = try XCTUnwrap(engine.add(range(of: "braveheart", in: text), author: .you, in: text))
        XCTAssertFalse(engine.canAdd(range(of: "heart", in: text), in: text))
        XCTAssertTrue(engine.canAdd(range(of: "braveheart", in: text), in: text), "same range adds a version")
        XCTAssertTrue(engine.canAdd(range(of: "Omega", in: text), in: text))
    }

    func testDeletingDownToOneVersionRemovesPassageAndChildren() throws {
        var engine = makeEngine()
        let parentID = try XCTUnwrap(engine.add(range(of: paragraph, in: nestedText), author: .you, in: nestedText))
        _ = try XCTUnwrap(engine.add(range(of: innerSentence, in: nestedText), author: .you, in: nestedText))
        XCTAssertNil(engine.deleteVersion(parentID, at: 0, in: nestedText))
        XCTAssertTrue(engine.history.isEmpty)

        // Deleting the current version switches to its neighbour first.
        var other = makeEngine()
        let id = try XCTUnwrap(other.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let edited = replacing("brave new", with: "bold new", in: sentenceText)
        let edit = try XCTUnwrap(other.deleteVersion(id, at: 1, in: edited))
        XCTAssertEqual(edit.replacement, sentence)
        XCTAssertEqual(apply(edit, to: edited), sentenceText)
        XCTAssertTrue(other.history.isEmpty)
    }

    func testGroupListsEveryLevelInNestedGroup() throws {
        let text = "Intro paragraph sits here.\n\nFirst sentence is right here. Second sentence goes brightly here.\n\nOutro."
        let para = "First sentence is right here. Second sentence goes brightly here."
        let inner = "Second sentence goes brightly here."

        var full = makeEngine()
        _ = try XCTUnwrap(full.add(range(of: para, in: text), author: .you, in: text))
        let sentenceID = try XCTUnwrap(full.add(range(of: inner, in: text), author: .you, in: text))
        _ = try XCTUnwrap(full.add(range(of: "brightly", in: text), author: .you, in: text))
        XCTAssertEqual(full.group(containing: sentenceID), [.paragraph, .sentence, .word])

        var noParagraph = makeEngine()
        let loneSentence = try XCTUnwrap(noParagraph.add(range(of: inner, in: text), author: .you, in: text))
        _ = try XCTUnwrap(noParagraph.add(range(of: "brightly", in: text), author: .you, in: text))
        XCTAssertEqual(noParagraph.group(containing: loneSentence), [.sentence, .word])

        var alone = makeEngine()
        let only = try XCTUnwrap(alone.add(range(of: inner, in: text), author: .you, in: text))
        XCTAssertEqual(alone.group(containing: only), [.sentence])
    }

    func testDescendFindsNestedPassageOfLevel() throws {
        let text = "Intro paragraph sits here.\n\nFirst sentence is right here. Second sentence goes brightly here.\n\nOutro."
        var engine = makeEngine()
        let p = try XCTUnwrap(engine.add(range(of: "First sentence is right here. Second sentence goes brightly here.", in: text), author: .you, in: text))
        let s = try XCTUnwrap(engine.add(range(of: "Second sentence goes brightly here.", in: text), author: .you, in: text))
        let w = try XCTUnwrap(engine.add(range(of: "brightly", in: text), author: .you, in: text))
        XCTAssertEqual(engine.descend(from: p, to: .sentence), s)
        XCTAssertEqual(engine.descend(from: p, to: .word), w)
        XCTAssertEqual(engine.descend(from: s, to: .word), w)
        XCTAssertNil(engine.descend(from: w, to: .paragraph))
        XCTAssertEqual(engine.chain(to: w), [p, s, w])
        XCTAssertEqual(engine.locateAll(in: text).map(\.rootID), [p, p, p])
    }

    func testRecordAcceptedStoresOriginalAndAIVersion() throws {
        var engine = makeEngine()
        let original = "Hi world, you are so very brave."
        let id = try XCTUnwrap(engine.recordAccepted(range: range(of: sentence, in: sentenceText),
                                                     original: original, accepted: sentence, in: sentenceText))
        let passage = try XCTUnwrap(engine.history.passages.first { $0.id == id })
        XCTAssertEqual(passage.versions.map(\.author), [.you, .ai])
        XCTAssertEqual(passage.versions.map(\.text), [original, sentence])
        XCTAssertEqual(passage.currentIndex, 1)
        let edit = try XCTUnwrap(engine.step(id, by: 1, in: sentenceText))
        XCTAssertEqual(edit.replacement, original)

        // Accepting over an existing passage's range: the replaced text is the writer's, the
        // accepted text is the AI's.
        var existing = makeEngine()
        let existingID = try XCTUnwrap(existing.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let accepted = "Hello there bold new world."
        let afterAccept = replacing(sentence, with: accepted, in: sentenceText)
        XCTAssertEqual(existing.recordAccepted(range: range(of: accepted, in: afterAccept),
                                               original: sentence, accepted: accepted, in: afterAccept), existingID)
        let extended = try XCTUnwrap(existing.history.passages.first { $0.id == existingID })
        XCTAssertEqual(extended.versions.map(\.text), [sentence, accepted])
        XCTAssertEqual(extended.versions.map(\.author), [.you, .ai])
        XCTAssertEqual(extended.currentIndex, 1)
    }

    func testDeletedPassageWithRecurringContextIsDropped() throws {
        // The after-context recurs at the end of the third paragraph.
        let text = "Intro paragraph kept unchanged here. Old sentence to track. That rule applies to every room in the house."
            + "\n\nSecond paragraph the user never touched at all."
            + "\n\nThird paragraph with its own words. That rule applies to every room in the house."
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "Old sentence to track.", in: text), author: .you, in: text))
        let deleted = replacing("Old sentence to track. That rule applies to every room in the house.", with: "", in: text)
        assertDroppedWithoutEdits(&engine, id: id, in: deleted)

        // Only the before-context recurs: it also opens the first paragraph.
        let lead = "Shared lead-in words go right here. Early sentence follows."
            + "\n\nShared lead-in words go right here. Old sentence to track. Closing words of paragraph two."
        var other = makeEngine()
        let otherID = try XCTUnwrap(other.add(range(of: "Old sentence to track.", in: lead), author: .you, in: lead))
        let trimmed = replacing("Shared lead-in words go right here. Old sentence to track.", with: "", in: lead)
        assertDroppedWithoutEdits(&other, id: otherID, in: trimmed)
    }

    private func assertDroppedWithoutEdits(_ engine: inout DocumentHistoryEngine, id: UUID, in text: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        var probe = engine
        XCTAssertNil(probe.step(id, by: -1, in: text), file: file, line: line)
        probe = engine
        XCTAssertNil(probe.select(id, version: 0, in: text), file: file, line: line)
        probe = engine
        XCTAssertNil(probe.deleteVersion(id, at: 1, in: text), file: file, line: line)
        XCTAssertEqual(engine.locateAll(in: text), [], file: file, line: line)
        XCTAssertTrue(engine.history.isEmpty, file: file, line: line)
    }

    func testTextTypedNextToPassageIsNotSwallowed() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let typed = replacing(sentence, with: sentence + " A new thought.", in: sentenceText)
        XCTAssertEqual(engine.locateAll(in: typed).first { $0.id == id }?.range, range(of: sentence, in: typed))
    }

    func testEditedPassageIsNotConfusedWithUntouchedDuplicate() throws {
        let text = "Start of the story begins here. It works. Middle part of the story is here. It works. The end of it all."
        let second = (text as NSString).range(of: "It works.", options: .backwards)
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(second, author: .you, in: text))
        let edited = (text as NSString).replacingCharacters(in: second, with: "It really works.")
        let edit = try XCTUnwrap(engine.step(id, by: -1, in: edited))
        XCTAssertEqual(edit.range, (edited as NSString).range(of: "It really works."))
        XCTAssertEqual(apply(edit, to: edited), text)
    }

    func testOrphanedChildIsDropped() {
        let ctx = PassageHistoryText.context(around: (sentenceText as NSString).range(of: sentence), in: sentenceText)
        let orphan = HistoryPassage(
            id: UUID(), level: .sentence,
            versions: [HistoryVersion(text: "Old.", author: .you, createdAt: fixedDate),
                       HistoryVersion(text: sentence, author: .you, createdAt: fixedDate)],
            currentIndex: 1, parentID: UUID(), parentVersionIndex: 1,
            contextBefore: ctx.before, contextAfter: ctx.after, lastTouched: fixedDate)
        let date = fixedDate
        var engine = DocumentHistoryEngine(history: DocumentHistory(passages: [orphan]), now: { date })
        XCTAssertEqual(engine.locateAll(in: sentenceText), [])
        XCTAssertTrue(engine.history.isEmpty)
    }
}

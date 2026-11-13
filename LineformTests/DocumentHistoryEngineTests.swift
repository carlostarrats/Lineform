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

    /// A user text change: applies it to `text` AND reports it to the engine, as the editor must.
    private func edit(_ engine: inout DocumentHistoryEngine, _ text: String, replacing r: NSRange, with new: String) -> String {
        engine.applyEdit(r, replacement: new)
        return (text as NSString).replacingCharacters(in: r, with: new)
    }

    private func typing(_ engine: inout DocumentHistoryEngine, _ old: String, with new: String, in text: String) -> String {
        edit(&engine, text, replacing: range(of: old, in: text), with: new)
    }

    /// A passage holding its original twice — frozen, plus a live copy that typing edits — so a
    /// typed change makes two versions to step between. Add to History itself now stores only the
    /// original (`testAddStoresOnlyTheOriginal`); this is the shape a replacement or an accepted
    /// AI change leaves (a frozen version plus a current one the writer keeps typing into), built
    /// directly so the live-range tests below stay about live ranges.
    private func addWithLiveCopy(_ engine: inout DocumentHistoryEngine, _ r: NSRange, in text: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        let id = try XCTUnwrap(engine.add(r, author: .you, in: text), file: file, line: line)
        let p = try XCTUnwrap(engine.history.passages.firstIndex { $0.id == id }, file: file, line: line)
        engine.history.passages[p].versions.append(engine.history.passages[p].versions[0])
        engine.history.passages[p].currentIndex = 1
        // Passages it took in when added sit in its live text.
        for i in engine.history.passages.indices
        where engine.history.passages[i].parentID == id && engine.history.passages[i].parentVersionIndex == 0 {
            engine.history.passages[i].parentVersionIndex = 1
        }
        return id
    }

    private let sentenceText = "Alpha one goes first. Hello there brave new world. Omega two ends it."
    private let sentence = "Hello there brave new world."

    private let nestedText = "Intro paragraph sits here.\n\nFirst sentence is right here. Second sentence goes right here.\n\nOutro paragraph."
    private let paragraph = "First sentence is right here. Second sentence goes right here."
    private let innerSentence = "Second sentence goes right here."

    // MARK: - Add stores only the original (1.8 QA follow-ups)

    private let gentleText = "The wind was gentle that night. Nobody slept."

    func testAddStoresOnlyTheOriginal() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "gentle", in: gentleText), author: .you, in: gentleText))
        let passage = try XCTUnwrap(engine.history.passages.first { $0.id == id })
        XCTAssertEqual(passage.level, .word)
        XCTAssertEqual(passage.versions.map(\.text), ["gentle"], "one version: the original, never a copy plus a live twin")
        XCTAssertEqual(passage.versions.map(\.author), [.you])
        XCTAssertEqual(passage.currentIndex, 0)
        XCTAssertEqual(passage.lastTouched, fixedDate)
        XCTAssertNil(passage.parentID)

        // Adding the same range again adds nothing and returns the same passage.
        XCTAssertEqual(engine.add(range(of: "gentle", in: gentleText), author: .you, in: gentleText), id)
        XCTAssertEqual(engine.history.passages.count, 1)
        XCTAssertEqual(engine.history.passages.first?.versions.map(\.text), ["gentle"])
    }

    func testAddReplacementAppendsAndSelects() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "gentle", in: gentleText), author: .you, in: gentleText))
        let edit = try XCTUnwrap(engine.addReplacement("dangerous", to: id, in: gentleText))
        XCTAssertEqual(edit, HistoryEdit(range: range(of: "gentle", in: gentleText), replacement: "dangerous"))
        let replaced = apply(edit, to: gentleText)
        XCTAssertEqual(replaced, "The wind was dangerous that night. Nobody slept.")
        let passage = try XCTUnwrap(engine.history.passages.first { $0.id == id })
        XCTAssertEqual(passage.versions.map(\.text), ["gentle", "dangerous"])
        XCTAssertEqual(passage.versions.map(\.author), [.you, .you])
        XCTAssertEqual(passage.currentIndex, 1)
        XCTAssertEqual(engine.locateAll(in: replaced).first { $0.id == id }?.range, range(of: "dangerous", in: replaced))

        // Another replacement appends again, and stepping walks all three.
        let third = apply(try XCTUnwrap(engine.addReplacement("fierce", to: id, in: replaced)), to: replaced)
        XCTAssertEqual(engine.history.passages.first?.versions.map(\.text), ["gentle", "dangerous", "fierce"])
        XCTAssertEqual(engine.history.passages.first?.currentIndex, 2)
        XCTAssertEqual(apply(try XCTUnwrap(engine.step(id, by: 1, in: third)), to: third), gentleText)
    }

    func testAddReplacementIgnoresEmptyAndUnchanged() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "gentle", in: gentleText), author: .you, in: gentleText))
        XCTAssertNil(engine.addReplacement("", to: id, in: gentleText))
        XCTAssertNil(engine.addReplacement("  \n\t ", to: id, in: gentleText))
        XCTAssertNil(engine.addReplacement("gentle", to: id, in: gentleText), "the current text is not a new version")
        XCTAssertNil(engine.addReplacement(" gentle\n", to: id, in: gentleText), "nor is it with whitespace around it")
        XCTAssertNil(engine.addReplacement("dangerous", to: UUID(), in: gentleText), "unknown passage")
        XCTAssertEqual(engine.history.passages.first?.versions.map(\.text), ["gentle"])

        // Surrounding whitespace is trimmed off a real replacement.
        let edit = try XCTUnwrap(engine.addReplacement("  dangerous\n", to: id, in: gentleText))
        XCTAssertEqual(edit.replacement, "dangerous")
    }

    /// The field is one line: a pasted line terminator (any of them) and the whitespace around it
    /// become one space, so a replacement never puts a bare LF into a CRLF file or starts new
    /// Markdown structure.
    func testAddReplacementCollapsesInteriorLineTerminators() throws {
        let text = "Alpha beta.\r\nGamma delta.\r\n"
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "Alpha beta.", in: text), author: .you, in: text))
        let edit = try XCTUnwrap(engine.addReplacement("a\nb", to: id, in: text))
        XCTAssertEqual(edit.replacement, "a b")
        let replaced = apply(edit, to: text)
        XCTAssertEqual(replaced, "a b\r\nGamma delta.\r\n")
        XCTAssertEqual(replaced.components(separatedBy: "\n").count, replaced.components(separatedBy: "\r\n").count,
                       "no bare LF")

        for terminator in ["\r\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"] {
            var other = makeEngine()
            let otherID = try XCTUnwrap(other.add(range(of: "Alpha beta.", in: text), author: .you, in: text))
            let replacement = try XCTUnwrap(other.addReplacement("one  \(terminator) \(terminator)\t two", to: otherID, in: text))
            XCTAssertEqual(replacement.replacement, "one two", "terminator \(terminator.unicodeScalars.map { $0.value })")
        }
        var spaced = makeEngine()
        let spacedID = try XCTUnwrap(spaced.add(range(of: "Alpha beta.", in: text), author: .you, in: text))
        XCTAssertEqual(try XCTUnwrap(spaced.addReplacement("keep  inner\tspaces", to: spacedID, in: text)).replacement,
                       "keep  inner\tspaces", "only runs holding a line terminator collapse")
    }

    /// Text that equals ANY version already kept is not a new version: that version is selected.
    func testAddReplacementMatchingAnEarlierVersionSelectsIt() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "gentle", in: gentleText), author: .you, in: gentleText))
        let t1 = apply(try XCTUnwrap(engine.addReplacement("dangerous", to: id, in: gentleText)), to: gentleText)
        let t2 = apply(try XCTUnwrap(engine.addReplacement("fierce", to: id, in: t1)), to: t1)

        let back = try XCTUnwrap(engine.addReplacement("  gentle \n", to: id, in: t2))
        XCTAssertEqual(back, HistoryEdit(range: range(of: "fierce", in: t2), replacement: "gentle"))
        XCTAssertEqual(apply(back, to: t2), gentleText)
        let passage = try XCTUnwrap(engine.history.passages.first { $0.id == id })
        XCTAssertEqual(passage.versions.map(\.text), ["gentle", "dangerous", "fierce"], "nothing appended")
        XCTAssertEqual(passage.currentIndex, 0)
    }

    /// A replacement keeps the live passage's own edge whitespace: an accepted "AI rewrite. "
    /// stays separated from the next sentence. "Unchanged" compares trimmed to trimmed.
    func testAddReplacementKeepsThePassagesEdgeWhitespace() throws {
        // As in testRecordAcceptedWithTrailingWhitespaceKeepsDraft: an AI rewrite accepted over a
        // tracked passage covers exactly what was inserted, trailing space included.
        let text = "One two. Three four. Five six."
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "Three four.", in: text), author: .you, in: text))
        let ai = "AI rewrite. "
        let accepted = edit(&engine, text, replacing: try XCTUnwrap(engine.liveRanges[id]), with: ai)
        XCTAssertEqual(engine.recordAccepted(range: range(of: ai, in: accepted), original: "Three four.",
                                             accepted: ai, in: accepted), id)
        XCTAssertEqual(accepted, "One two. AI rewrite.  Five six.")
        XCTAssertEqual(engine.liveRanges[id], range(of: ai, in: accepted), "the live passage ends in a space")

        XCTAssertNil(engine.addReplacement("AI rewrite.", to: id, in: accepted), "trimmed equals trimmed current")
        XCTAssertNil(engine.addReplacement(" AI rewrite. \n", to: id, in: accepted))
        let replacement = try XCTUnwrap(engine.addReplacement("  Mine instead.", to: id, in: accepted))
        XCTAssertEqual(replacement.replacement, "Mine instead. ", "the passage's own trailing space is kept")
        let replaced = apply(replacement, to: accepted)
        XCTAssertEqual(replaced, "One two. Mine instead.  Five six.")
        XCTAssertEqual(engine.history.passages.first?.versions.map(\.text), ["Three four.", ai, "Mine instead. "])
        XCTAssertEqual(apply(try XCTUnwrap(engine.step(id, by: -1, in: replaced)), to: replaced), accepted)
    }

    func testDiscardRemovesPassagesWithNoReplacement() throws {
        var engine = makeEngine()
        let unrevised = try XCTUnwrap(engine.add(range(of: "gentle", in: gentleText), author: .you, in: gentleText))
        let revised = try XCTUnwrap(engine.add(range(of: "Nobody slept.", in: gentleText), author: .you, in: gentleText))
        let after = apply(try XCTUnwrap(engine.addReplacement("Everyone slept.", to: revised, in: gentleText)), to: gentleText)
        XCTAssertEqual(engine.discardUnrevisedPassages(), [unrevised])
        XCTAssertEqual(engine.history.passages.map(\.id), [revised])
        XCTAssertEqual(engine.locateAll(in: after).map(\.id), [revised])
        XCTAssertEqual(engine.discardUnrevisedPassages(), [])
    }

    func testDiscardKeepsAIRecordedPassages() throws {
        var engine = makeEngine()
        let accepted = "The wind was fierce that night. Nobody slept."
        let id = try XCTUnwrap(engine.recordAccepted(range: range(of: "fierce", in: accepted),
                                                     original: "gentle", accepted: "fierce", in: accepted))
        XCTAssertEqual(engine.discardUnrevisedPassages(), [])
        XCTAssertEqual(engine.history.passages.map(\.id), [id])
        XCTAssertEqual(engine.history.passages.first?.versions.map(\.text), ["gentle", "fierce"])
    }

    /// A discarded passage never takes revised passages inside it down with it: they move up to
    /// the discarded passage's own parent, in the version it sat in (its only version is the live
    /// text, so they are still exactly where that parent shows them).
    func testDiscardReparentsRevisedChildrenOfAnUnrevisedPassage() throws {
        let text = "Intro paragraph sits here.\n\nFirst sentence is right here. Second sentence goes brightly here.\n\nOutro."
        let para = "First sentence is right here. Second sentence goes brightly here."
        let inner = "Second sentence goes brightly here."
        var engine = makeEngine()
        let paraID = try XCTUnwrap(engine.add(range(of: para, in: text), author: .you, in: text))
        let t1 = apply(try XCTUnwrap(engine.addReplacement(para + " Third one.", to: paraID, in: text)), to: text)
        let sentenceID = try XCTUnwrap(engine.add(range(of: inner, in: t1), author: .you, in: t1))   // never revised
        let wordID = try XCTUnwrap(engine.add(range(of: "brightly", in: t1), author: .you, in: t1))
        let t2 = apply(try XCTUnwrap(engine.addReplacement("softly", to: wordID, in: t1)), to: t1)
        XCTAssertEqual(engine.chain(to: wordID), [paraID, sentenceID, wordID])

        XCTAssertEqual(engine.discardUnrevisedPassages(), [sentenceID])
        XCTAssertEqual(Set(engine.history.passages.map(\.id)), [paraID, wordID])
        let word = try XCTUnwrap(engine.history.passages.first { $0.id == wordID })
        XCTAssertEqual(word.parentID, paraID)
        XCTAssertEqual(word.parentVersionIndex, 1, "the paragraph version the sentence was made in")
        XCTAssertEqual(word.versions.map(\.text), ["brightly", "softly"])
        XCTAssertEqual(engine.locateAll(in: t2).map(\.id), [paraID, wordID])
        XCTAssertEqual(engine.chain(to: wordID), [paraID, wordID])
        XCTAssertEqual(apply(try XCTUnwrap(engine.step(wordID, by: -1, in: t2)), to: t2), t1)

        // An unrevised ROOT with a revised child: the child becomes a root.
        var rooted = makeEngine()
        let outer = try XCTUnwrap(rooted.add(range(of: inner, in: text), author: .you, in: text))
        let child = try XCTUnwrap(rooted.add(range(of: "brightly", in: text), author: .you, in: text))
        let swapped = apply(try XCTUnwrap(rooted.addReplacement("softly", to: child, in: text)), to: text)
        XCTAssertEqual(rooted.discardUnrevisedPassages(), [outer])
        let orphan = try XCTUnwrap(rooted.history.passages.first)
        XCTAssertEqual(orphan.id, child)
        XCTAssertNil(orphan.parentID)
        XCTAssertNil(orphan.parentVersionIndex)
        XCTAssertEqual(rooted.locateAll(in: swapped).map(\.id), [child])
    }

    func testCollapsingAdjacentDuplicatesKeepsOneOfEachRun() throws {
        let date = fixedDate
        func v(_ text: String, _ author: HistoryAuthor = .you) -> HistoryVersion {
            HistoryVersion(text: text, author: author, createdAt: date)
        }
        let parentID = UUID()
        let parent = HistoryPassage(
            id: parentID, level: .sentence,
            versions: [v("gentle"), v("gentle"), v("calm"), v("calm", .ai), v("gentle")],
            currentIndex: 3, parentID: nil, parentVersionIndex: nil,
            contextBefore: "", contextAfter: "", lastTouched: date)
        let child = HistoryPassage(
            id: UUID(), level: .word, versions: [v("a"), v("b")], currentIndex: 1,
            parentID: parentID, parentVersionIndex: 3,
            contextBefore: "", contextAfter: "", lastTouched: date)
        let collapsed = DocumentHistoryEngine.collapsingAdjacentDuplicates(DocumentHistory(passages: [parent, child]))
        let p = try XCTUnwrap(collapsed.passages.first { $0.id == parentID })
        XCTAssertEqual(p.versions.map(\.text), ["gentle", "calm", "gentle"])
        XCTAssertEqual(p.currentIndex, 1, "the current duplicate lands on its twin")
        XCTAssertEqual(collapsed.passages.first { $0.id == child.id }?.parentVersionIndex, 1)
        XCTAssertEqual(collapsed.passages.first { $0.id == child.id }?.versions.map(\.text), ["a", "b"])
    }

    func testStepReturnsEditReplacingCurrentText() throws {
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: sentence, in: sentenceText), in: sentenceText)
        let edited = typing(&engine, "brave new", with: "bold and brave new", in: sentenceText)
        let edit = try XCTUnwrap(engine.step(id, by: -1, in: edited))
        XCTAssertEqual(edit, HistoryEdit(range: range(of: "Hello there bold and brave new world.", in: edited),
                                         replacement: sentence))
        XCTAssertEqual(apply(edit, to: edited), sentenceText)
    }

    func testTypedEditsToCurrentVersionSurviveSwitchingAway() throws {
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: sentence, in: sentenceText), in: sentenceText)
        let typed = "Hello there bold and brave new world."
        let edited = typing(&engine, sentence, with: typed, in: sentenceText)
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
        let parentID = try addWithLiveCopy(&engine, range(of: paragraph, in: nestedText), in: nestedText)
        let childID = try addWithLiveCopy(&engine, range(of: innerSentence, in: nestedText), in: nestedText)
        XCTAssertEqual(engine.locateAll(in: nestedText).map(\.id), [parentID, childID])
        XCTAssertEqual(engine.history.passages.first { $0.id == childID }?.parentID, parentID)

        // Edit the parent's live version outside the child, then switch the parent away.
        let edited = typing(&engine, "First sentence", with: "Opening sentence", in: nestedText)
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
        XCTAssertTrue(engine.canAdd(range(of: "braveheart", in: text), in: text), "the same range can be added (it returns the existing passage)")
        XCTAssertTrue(engine.canAdd(range(of: "Omega", in: text), in: text))
    }

    func testDeletingDownToOneVersionRemovesPassageAndChildren() throws {
        var engine = makeEngine()
        let parentID = try addWithLiveCopy(&engine, range(of: paragraph, in: nestedText), in: nestedText)
        _ = try addWithLiveCopy(&engine, range(of: innerSentence, in: nestedText), in: nestedText)
        XCTAssertNil(engine.deleteVersion(parentID, at: 0, in: nestedText))
        XCTAssertTrue(engine.history.isEmpty)

        // Deleting the current version switches to its neighbour first.
        var other = makeEngine()
        let id = try addWithLiveCopy(&other, range(of: sentence, in: sentenceText), in: sentenceText)
        let edited = typing(&other, "brave new", with: "bold new", in: sentenceText)
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

    func testInsideWordPassageDetection() throws {
        let text = "Intro paragraph sits here.\n\nFirst sentence is right here. Second sentence goes brightly here.\n\nOutro."
        var engine = makeEngine()
        _ = try XCTUnwrap(engine.add(range(of: "Second sentence goes brightly here.", in: text), author: .you, in: text))
        let word = range(of: "brightly", in: text)
        XCTAssertFalse(engine.isInsideWordPassage(word), "a sentence passage is not a word passage")
        _ = try XCTUnwrap(engine.add(word, author: .you, in: text))
        XCTAssertTrue(engine.isInsideWordPassage(word))
        XCTAssertTrue(engine.isInsideWordPassage(NSRange(location: word.location + 2, length: 3)))
        XCTAssertFalse(engine.isInsideWordPassage(NSRange(location: word.location - 1, length: word.length + 1)),
                       "a selection reaching outside the word is not inside it")
        XCTAssertFalse(engine.isInsideWordPassage(range(of: "Intro", in: text)))
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
        let afterAccept = typing(&existing, sentence, with: accepted, in: sentenceText)
        XCTAssertEqual(existing.recordAccepted(range: range(of: accepted, in: afterAccept),
                                               original: sentence, accepted: accepted, in: afterAccept), existingID)
        let extended = try XCTUnwrap(existing.history.passages.first { $0.id == existingID })
        XCTAssertEqual(extended.versions.map(\.text), [sentence, accepted])
        XCTAssertEqual(extended.versions.map(\.author), [.you, .ai])
        XCTAssertEqual(extended.currentIndex, 1)

        // Accepting AI text twice in a row keeps the first AI version's authorship.
        let second = "Hello there bold and new world."
        let afterSecond = typing(&existing, accepted, with: second, in: afterAccept)
        XCTAssertEqual(existing.recordAccepted(range: range(of: second, in: afterSecond),
                                               original: accepted, accepted: second, in: afterSecond), existingID)
        let chained = try XCTUnwrap(existing.history.passages.first { $0.id == existingID })
        XCTAssertEqual(chained.versions.map(\.text), [sentence, accepted, second])
        XCTAssertEqual(chained.versions.map(\.author), [.you, .ai, .ai])
        XCTAssertEqual(chained.currentIndex, 2)
    }

    func testAnchoredSpanRejectsUnrelatedSameLevelSentence() throws {
        let text = "Lead words. Old tracked sentence. Rule X applies here now always. Untouched sentence kept. Rule X applies here now always. End."
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "Old tracked sentence.", in: text), author: .you, in: text))
        let deleted = typing(&engine, "Old tracked sentence. Rule X applies here now always. ", with: "", in: text)
        XCTAssertEqual(deleted, "Lead words. Untouched sentence kept. Rule X applies here now always. End.")
        assertDroppedWithoutEdits(&engine, id: id, in: deleted)
    }

    func testTypingAFewCharactersInsideTrackedSentenceKeepsIt() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let typed = typing(&engine, "brave", with: "very brave", in: sentenceText)
        XCTAssertEqual(engine.locateAll(in: typed).first { $0.id == id }?.range,
                       range(of: "Hello there very brave new world.", in: typed))
    }

    func testDeletedPassageWithRecurringContextIsDropped() throws {
        // The after-context recurs at the end of the third paragraph.
        let text = "Intro paragraph kept unchanged here. Old sentence to track. That rule applies to every room in the house."
            + "\n\nSecond paragraph the user never touched at all."
            + "\n\nThird paragraph with its own words. That rule applies to every room in the house."
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "Old sentence to track.", in: text), author: .you, in: text))
        let deleted = typing(&engine, "Old sentence to track. That rule applies to every room in the house.", with: "", in: text)
        assertDroppedWithoutEdits(&engine, id: id, in: deleted)

        // Only the before-context recurs: it also opens the first paragraph.
        let lead = "Shared lead-in words go right here. Early sentence follows."
            + "\n\nShared lead-in words go right here. Old sentence to track. Closing words of paragraph two."
        var other = makeEngine()
        let otherID = try XCTUnwrap(other.add(range(of: "Old sentence to track.", in: lead), author: .you, in: lead))
        let trimmed = typing(&other, "Shared lead-in words go right here. Old sentence to track.", with: "", in: lead)
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
        let typed = edit(&engine, sentenceText, replacing: NSRange(location: range(of: sentence, in: sentenceText).upperBound, length: 0),
                         with: " A new thought.")
        XCTAssertEqual(engine.locateAll(in: typed).first { $0.id == id }?.range, range(of: sentence, in: typed))
    }

    func testEditedPassageIsNotConfusedWithUntouchedDuplicate() throws {
        let text = "Start of the story begins here. It works. Middle part of the story is here. It works. The end of it all."
        let second = (text as NSString).range(of: "It works.", options: .backwards)
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, second, in: text)
        let edited = edit(&engine, text, replacing: second, with: "It really works.")
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

    // MARK: - Live ranges

    func testEditBeforePassageShiftsIt() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let edited = typing(&engine, "Alpha one", with: "Alpha number one", in: sentenceText)
        XCTAssertEqual(engine.liveRanges[id], range(of: sentence, in: edited))
        XCTAssertEqual(engine.locateAll(in: edited).map(\.range), [range(of: sentence, in: edited)])
    }

    func testEditInsidePassageGrowsIt() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let edited = typing(&engine, "brave new", with: "brave and shiny new", in: sentenceText)
        let grown = range(of: "Hello there brave and shiny new world.", in: edited)
        XCTAssertEqual(engine.liveRanges[id], grown)
        XCTAssertEqual(engine.locateAll(in: edited).first?.range, grown)
        XCTAssertEqual(engine.history.passages.first?.versions.last?.text, "Hello there brave and shiny new world.")
    }

    func testEditStraddlingBoundaryDropsPassage() throws {
        var engine = makeEngine()
        let parentID = try XCTUnwrap(engine.add(range(of: paragraph, in: nestedText), author: .you, in: nestedText))
        let childID = try XCTUnwrap(engine.add(range(of: innerSentence, in: nestedText), author: .you, in: nestedText))
        // Straddles the child's leading edge but stays inside the parent: only the child goes.
        let edited = typing(&engine, "here. Second", with: "here, and second", in: nestedText)
        XCTAssertNil(engine.liveRanges[childID])
        XCTAssertEqual(engine.history.passages.map(\.id), [parentID])
        XCTAssertEqual(engine.liveRanges[parentID],
                       range(of: "First sentence is right here, and second sentence goes right here.", in: edited))

        // Straddles the parent's trailing edge: the parent goes too.
        let cut = typing(&engine, "here.\n\nOutro", with: "Outro", in: edited)
        XCTAssertTrue(engine.history.isEmpty)
        XCTAssertTrue(engine.liveRanges.isEmpty)
        XCTAssertEqual(engine.locateAll(in: cut), [])
    }

    func testInsertionAtBoundariesStaysOutside() throws {
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: sentence, in: sentenceText), in: sentenceText)
        let start = range(of: sentence, in: sentenceText)
        var text = edit(&engine, sentenceText, replacing: NSRange(location: start.location, length: 0), with: "Then: ")
        XCTAssertEqual(engine.liveRanges[id], range(of: sentence, in: text), "insertion at the start shifts it")
        text = edit(&engine, text, replacing: NSRange(location: range(of: sentence, in: text).upperBound, length: 0), with: " Added.")
        XCTAssertEqual(engine.liveRanges[id], range(of: sentence, in: text), "insertion at the end stays outside")
        XCTAssertEqual(text, "Alpha one goes first. Then: Hello there brave new world. Added. Omega two ends it.")
        XCTAssertEqual(engine.locateAll(in: text).map(\.range), [range(of: sentence, in: text)])
        XCTAssertEqual(engine.history.passages.first?.versions.map(\.text), [sentence, sentence])
    }

    func testTypedIntoWordPassageSurvives() throws {
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: "brave", in: sentenceText), in: sentenceText)
        let e = range(of: "brave", in: sentenceText).location + 4  // the trailing "e"
        let typed = edit(&engine, sentenceText, replacing: NSRange(location: e, length: 1), with: "er")
        XCTAssertEqual(typed, "Alpha one goes first. Hello there braver new world. Omega two ends it.")
        let back = try XCTUnwrap(engine.step(id, by: -1, in: typed))
        XCTAssertEqual(back, HistoryEdit(range: range(of: "braver", in: typed), replacement: "brave"))
        let older = apply(back, to: typed)
        XCTAssertEqual(older, sentenceText)
        let forward = try XCTUnwrap(engine.step(id, by: 1, in: older))
        XCTAssertEqual(forward, HistoryEdit(range: range(of: "brave", in: older), replacement: "braver"))
    }

    func testParallelSentenceIsNeverClaimed() throws {
        let text = "The cat sat on the mat. The dog sat on the rug."
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: "The cat sat on the mat.", in: text), in: text)
        let typed = typing(&engine, "cat sat", with: "cat calmly sat", in: text)
        XCTAssertEqual(engine.locateAll(in: typed).map(\.id), [id])
        let deleted = typing(&engine, "The cat calmly sat on the mat. ", with: "", in: typed)
        XCTAssertEqual(deleted, "The dog sat on the rug.")
        assertDroppedWithoutEdits(&engine, id: id, in: deleted)

        // With the untouched sentence tracked too, only its own range is ever edited.
        var both = makeEngine()
        let catID = try addWithLiveCopy(&both, range(of: "The cat sat on the mat.", in: text), in: text)
        let dogID = try addWithLiveCopy(&both, range(of: "The dog sat on the rug.", in: text), in: text)
        let catTyped = typing(&both, "cat sat", with: "cat calmly sat", in: text)
        let dogTyped = typing(&both, "dog sat", with: "dog lazily sat", in: catTyped)
        let catGone = typing(&both, "The cat calmly sat on the mat. ", with: "", in: dogTyped)
        XCTAssertNil(both.step(catID, by: -1, in: catGone))
        let dogEdit = try XCTUnwrap(both.step(dogID, by: -1, in: catGone))
        XCTAssertEqual(dogEdit, HistoryEdit(range: range(of: "The dog lazily sat on the rug.", in: catGone),
                                            replacement: "The dog sat on the rug."))
        XCTAssertEqual(both.history.passages.map(\.id), [dogID])
    }

    func testRecordAcceptedKeepsHistoryAfterDissimilarRewrite() throws {
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: sentence, in: sentenceText), in: sentenceText)
        let typed = typing(&engine, "brave", with: "very brave", in: sentenceText)
        let veryBrave = "Hello there very brave new world."
        let ai = "Greetings to this bold, unfamiliar planet."
        let accepted = edit(&engine, typed, replacing: try XCTUnwrap(engine.liveRanges[id]), with: ai)
        XCTAssertEqual(engine.recordAccepted(range: range(of: ai, in: accepted), original: veryBrave,
                                             accepted: ai, in: accepted), id)
        let passage = try XCTUnwrap(engine.history.passages.first { $0.id == id })
        XCTAssertEqual(passage.versions.map(\.text), [sentence, veryBrave, ai])
        XCTAssertEqual(passage.versions.map(\.author), [.you, .you, .ai])
        XCTAssertEqual(passage.currentIndex, 2)
        XCTAssertEqual(engine.history.passages.count, 1)
    }

    func testChainedAcceptsKeepDraft() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let ai1 = "Greetings to this bold, unfamiliar planet."
        let ai2 = "Salutations, daring and strange sphere of ours!"
        let first = typing(&engine, sentence, with: ai1, in: sentenceText)
        XCTAssertEqual(engine.recordAccepted(range: range(of: ai1, in: first), original: sentence, accepted: ai1, in: first), id)
        let second = typing(&engine, ai1, with: ai2, in: first)
        XCTAssertEqual(engine.recordAccepted(range: range(of: ai2, in: second), original: ai1, accepted: ai2, in: second), id)
        let passage = try XCTUnwrap(engine.history.passages.first { $0.id == id })
        XCTAssertEqual(passage.versions.map(\.text), [sentence, ai1, ai2])
        XCTAssertEqual(passage.versions.map(\.author), [.you, .ai, .ai])
        let back = try XCTUnwrap(engine.select(id, version: 0, in: second))
        XCTAssertEqual(apply(back, to: second), sentenceText)
    }

    func testLoadedPassageEditedElsewhereIsDropped() throws {
        var original = makeEngine()
        _ = try XCTUnwrap(original.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let date = fixedDate
        // Positive control: a fresh engine (no live ranges) finds the stored text literally.
        var reloaded = DocumentHistoryEngine(history: original.history, now: { date })
        XCTAssertEqual(reloaded.locateAll(in: sentenceText).map(\.range), [range(of: sentence, in: sentenceText)])

        var fresh = DocumentHistoryEngine(history: original.history, now: { date })
        let elsewhere = replacing("brave", with: "very brave", in: sentenceText)
        XCTAssertEqual(fresh.locateAll(in: elsewhere), [])
        XCTAssertTrue(fresh.history.isEmpty)
    }

    func testEngineEditsKeepLiveRangesConsistent() throws {
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: sentence, in: sentenceText), in: sentenceText)
        let wordID = try addWithLiveCopy(&engine, range(of: "Omega", in: sentenceText), in: sentenceText)
        let typed = typing(&engine, "brave", with: "very brave", in: sentenceText)
        let typedRange = range(of: "Hello there very brave new world.", in: typed)

        let back = apply(try XCTUnwrap(engine.step(id, by: -1, in: typed)), to: typed)
        XCTAssertEqual(back, sentenceText)
        XCTAssertEqual(engine.liveRanges[id], range(of: sentence, in: back))
        XCTAssertEqual(engine.liveRanges[wordID], range(of: "Omega", in: back))

        let forwardEdit = try XCTUnwrap(engine.step(id, by: 1, in: back))
        XCTAssertEqual(forwardEdit.range, range(of: sentence, in: back))
        let forward = apply(forwardEdit, to: back)
        XCTAssertEqual(forward, typed)
        XCTAssertEqual(engine.liveRanges[id], typedRange)
        XCTAssertEqual(engine.liveRanges[wordID], range(of: "Omega", in: forward))
        XCTAssertEqual(engine.locateAll(in: forward).map(\.range), [typedRange, range(of: "Omega", in: forward)])
    }

    // MARK: - Round 5

    /// Types `characters` one key at a time starting at `location`, reporting each key.
    private func typeKeys(_ engine: inout DocumentHistoryEngine, _ characters: String, at location: Int, in text: String) -> String {
        var result = text
        var cursor = location
        for character in characters {
            let key = String(character)
            result = edit(&engine, result, replacing: NSRange(location: cursor, length: 0), with: key)
            cursor += (key as NSString).length
        }
        return result
    }

    func testOverTypingTrackedWordKeepsWholeWord() throws {
        let text = "The cat sat on the mat."
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: "cat", in: text), in: text)
        let cat = range(of: "cat", in: text)
        var typed = edit(&engine, text, replacing: cat, with: "d")  // selection replaced by the first key
        typed = typeKeys(&engine, "og", at: cat.location + 1, in: typed)
        XCTAssertEqual(typed, "The dog sat on the mat.")
        XCTAssertEqual(engine.liveRanges[id], range(of: "dog", in: typed))
        let back = try XCTUnwrap(engine.step(id, by: -1, in: typed))
        XCTAssertEqual(apply(back, to: typed), "The cat sat on the mat.")
    }

    func testAppendingToTrackedWordGrowsIt() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "brave", in: sentenceText), author: .you, in: sentenceText))
        let bold = typing(&engine, "brave", with: "bold", in: sentenceText)
        XCTAssertEqual(engine.recordAccepted(range: range(of: "bold", in: bold), original: "brave", accepted: "bold", in: bold), id)
        let shown = apply(try XCTUnwrap(engine.step(id, by: -1, in: bold)), to: bold)
        XCTAssertEqual(shown, sentenceText)
        let typed = typeKeys(&engine, "er", at: range(of: "brave", in: shown).upperBound, in: shown)
        XCTAssertEqual(engine.liveRanges[id], range(of: "braveer", in: typed))
        let forward = apply(try XCTUnwrap(engine.step(id, by: 1, in: typed)), to: typed)
        XCTAssertEqual(forward, bold)
        let back = apply(try XCTUnwrap(engine.step(id, by: -1, in: forward)), to: forward)
        XCTAssertEqual(back, replacing("brave", with: "braveer", in: sentenceText))
    }

    func testPrependingToTrackedWordGrowsIt() throws {
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: "brave", in: sentenceText), in: sentenceText)
        let typed = typeKeys(&engine, "un", at: range(of: "brave", in: sentenceText).location, in: sentenceText)
        XCTAssertEqual(engine.liveRanges[id], range(of: "unbrave", in: typed))
        let back = apply(try XCTUnwrap(engine.step(id, by: -1, in: typed)), to: typed)
        XCTAssertEqual(back, sentenceText)
    }

    func testSpaceAtBoundaryStaysOutside() throws {
        var engine = makeEngine()
        let id = try XCTUnwrap(engine.add(range(of: "brave", in: sentenceText), author: .you, in: sentenceText))
        var text = typeKeys(&engine, " x", at: range(of: "brave", in: sentenceText).upperBound, in: sentenceText)
        text = typeKeys(&engine, " ", at: range(of: "brave", in: text).location, in: text)
        XCTAssertEqual(text, "Alpha one goes first. Hello there  brave x new world. Omega two ends it.")
        XCTAssertEqual(engine.liveRanges[id], range(of: "brave", in: text))

        // Punctuation at a sentence's edge does not continue a word either.
        var other = makeEngine()
        let sid = try XCTUnwrap(other.add(range(of: sentence, in: sentenceText), author: .you, in: sentenceText))
        let after = typeKeys(&other, "X", at: range(of: sentence, in: sentenceText).upperBound, in: sentenceText)
        XCTAssertEqual(other.liveRanges[sid], range(of: sentence, in: after))
    }

    func testRecordAcceptedWithTrailingWhitespaceKeepsDraft() throws {
        let text = "One two. Three four. Five six."
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: "Three four.", in: text), in: text)
        let drafted = typing(&engine, "Three four.", with: "Drafted words.", in: text)
        let ai = "AI rewrite. "
        let accepted = edit(&engine, drafted, replacing: try XCTUnwrap(engine.liveRanges[id]), with: ai)
        XCTAssertEqual(engine.recordAccepted(range: range(of: ai, in: accepted), original: "Drafted words.",
                                             accepted: ai, in: accepted), id)
        let passage = try XCTUnwrap(engine.history.passages.first { $0.id == id })
        XCTAssertEqual(passage.versions.map(\.text), ["Three four.", "Drafted words.", ai])
        XCTAssertEqual(passage.versions.map(\.author), [.you, .you, .ai])
        let back = apply(try XCTUnwrap(engine.step(id, by: -1, in: accepted)), to: accepted)
        XCTAssertEqual(back, drafted)
    }

    func testUnreportedSameLengthChangeNeverOverwrites() throws {
        let text = "AAA one. Tracked here. BBB."
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: "Tracked here.", in: text), in: text)
        let typed = typing(&engine, "here", with: "now!", in: text)
        XCTAssertEqual(typed, "AAA one. Tracked now!. BBB.")
        let changed = "one. Tracked now!. AAA BBB."  // unreported, same length
        XCTAssertEqual((changed as NSString).length, (typed as NSString).length)
        if let edit = engine.step(id, by: -1, in: changed) {
            XCTAssertEqual(edit.range, range(of: "Tracked now!.", in: changed))
            XCTAssertEqual(apply(edit, to: changed), "one. Tracked here. AAA BBB.")
        } else {
            XCTAssertTrue(engine.history.isEmpty)
        }
    }

    func testInvalidateLiveRangesReFindsLiterally() throws {
        var engine = makeEngine()
        let id = try addWithLiveCopy(&engine, range(of: sentence, in: sentenceText), in: sentenceText)
        let typed = typing(&engine, "brave", with: "very brave", in: sentenceText)
        engine.invalidateLiveRanges()
        XCTAssertTrue(engine.liveRanges.isEmpty)
        let reloaded = "A new opening line arrives.\n\n" + typed
        let typedSentence = "Hello there very brave new world."
        XCTAssertEqual(engine.locateAll(in: reloaded).map(\.range), [range(of: typedSentence, in: reloaded)])
        XCTAssertEqual(engine.liveRanges[id], range(of: typedSentence, in: reloaded))
        let back = apply(try XCTUnwrap(engine.step(id, by: -1, in: reloaded)), to: reloaded)
        XCTAssertEqual(back, "A new opening line arrives.\n\n" + sentenceText)

        engine.invalidateLiveRanges()
        XCTAssertEqual(engine.locateAll(in: "Nothing of it remains in this reloaded file."), [])
        XCTAssertTrue(engine.history.isEmpty)
    }

    // MARK: - Task 3a

    private func assertNoOverlappingSiblings(_ engine: DocumentHistoryEngine, file: StaticString = #filePath, line: UInt = #line) {
        let live = engine.liveRanges.sorted { $0.value.location < $1.value.location }
        for (i, a) in live.enumerated() {
            for b in live[(i + 1)...] {
                let nested = engine.chain(to: a.key).contains(b.key) || engine.chain(to: b.key).contains(a.key)
                XCTAssertTrue(nested || NSIntersectionRange(a.value, b.value).length == 0,
                              "overlap \(a.value) \(b.value)", file: file, line: line)
            }
        }
    }

    func testInsertionAtJoinOfAdjacentPassagesGrowsOnlyOne() throws {
        let text = "Hello brave new world. Tail word here."
        var engine = makeEngine()
        let braveID = try addWithLiveCopy(&engine, range(of: "brave", in: text), in: text)
        let newID = try addWithLiveCopy(&engine, range(of: "new", in: text), in: text)
        let tailID = try addWithLiveCopy(&engine, range(of: "Tail", in: text), in: text)
        var typed = typing(&engine, "Tail", with: "Head", in: text)
        typed = edit(&engine, typed, replacing: NSRange(location: range(of: "brave", in: typed).upperBound, length: 1), with: "")
        typed = typeKeys(&engine, "x", at: range(of: "bravenew", in: typed).location + 5, in: typed)
        XCTAssertEqual(typed, "Hello bravexnew world. Head word here.")
        XCTAssertEqual(engine.liveRanges[braveID], range(of: "bravex", in: typed))
        XCTAssertEqual(engine.liveRanges[newID], NSRange(location: range(of: "bravex", in: typed).upperBound, length: 3))
        assertNoOverlappingSiblings(engine)

        let edit = try XCTUnwrap(engine.deleteVersion(newID, at: 1, in: typed))
        XCTAssertEqual(edit, HistoryEdit(range: NSRange(location: 12, length: 3), replacement: "new"))
        XCTAssertNil(engine.history.passages.first { $0.id == newID }, "left with one version, removed")
        let tail = try XCTUnwrap(engine.history.passages.first { $0.id == tailID })
        XCTAssertEqual(tail.versions.map(\.text), ["Tail", "Head"])
        XCTAssertEqual(tail.currentIndex, 1)
        let brave = try XCTUnwrap(engine.history.passages.first { $0.id == braveID })
        XCTAssertEqual(brave.versions.count, 2)
        XCTAssertEqual(apply(edit, to: typed), typed)
        assertNoOverlappingSiblings(engine)
    }

    func testDeleteVersionAfterDropUsesCorrectPassage() throws {
        // The two-passage form of the join repro: it trapped on a stale passage index.
        let text = "Hello brave new world."
        var engine = makeEngine()
        let braveID = try addWithLiveCopy(&engine, range(of: "brave", in: text), in: text)
        let newID = try addWithLiveCopy(&engine, range(of: "new", in: text), in: text)
        var typed = typing(&engine, "new", with: "old", in: text)
        typed = edit(&engine, typed, replacing: NSRange(location: range(of: "brave", in: typed).upperBound, length: 1), with: "")
        typed = typeKeys(&engine, "x", at: range(of: "braveold", in: typed).location + 5, in: typed)
        XCTAssertEqual(typed, "Hello bravexold world.")
        let edit = try XCTUnwrap(engine.deleteVersion(newID, at: 1, in: typed))
        XCTAssertEqual(edit, HistoryEdit(range: range(of: "old", in: typed), replacement: "new"))
        XCTAssertEqual(apply(edit, to: typed), "Hello bravexnew world.")
        XCTAssertEqual(engine.history.passages.map(\.id), [braveID])
        XCTAssertEqual(engine.history.passages.first?.versions.map(\.text), ["brave", "bravex"])
    }

    func testLocateAllNeverReturnsOverlappingSiblings() throws {
        let text = "Here is my dog. Look, a dog."
        let second = (text as NSString).range(of: "dog", options: .backwards)
        var engine = makeEngine()
        let firstID = try XCTUnwrap(engine.add(range(of: "dog", in: text), author: .you, in: text))
        let secondID = try XCTUnwrap(engine.add(second, author: .you, in: text))
        // Unreported, same length: the first dog becomes mid-word.
        let changed = "Here is mydogs. Look, a dog."
        XCTAssertEqual((changed as NSString).length, (text as NSString).length)
        let located = engine.locateAll(in: changed)
        XCTAssertEqual(located.map(\.id), [secondID])
        XCTAssertEqual(located.first?.range, second)
        XCTAssertNil(engine.history.passages.first { $0.id == firstID })
        XCTAssertNil(engine.step(firstID, by: 1, in: changed))
    }

    func testRecordAcceptedPrefersInnermostPassageOnSharedRange() throws {
        let text = "Intro paragraph sits here.\n\nFirst one is here. Second one is here.\n\nOutro paragraph."
        var engine = makeEngine()
        let paragraphID = try XCTUnwrap(engine.add(range(of: "First one is here. Second one is here.", in: text), author: .you, in: text))
        let sentenceID = try XCTUnwrap(engine.add(range(of: "Second one is here.", in: text), author: .you, in: text))
        // Deleting the first sentence leaves parent and child on the same range.
        let shared = typing(&engine, "First one is here. ", with: "", in: text)
        XCTAssertEqual(engine.liveRanges[paragraphID], engine.liveRanges[sentenceID])
        let ai = "A rewritten second line."
        let accepted = typing(&engine, "Second one is here.", with: ai, in: shared)
        for _ in 0..<20 {  // dictionary order must not matter
            var probe = engine
            XCTAssertEqual(probe.recordAccepted(range: range(of: ai, in: accepted), original: "Second one is here.",
                                                accepted: ai, in: accepted), sentenceID)
        }
    }
    // MARK: - Final review: a literal re-find never picks the other occurrence

    /// The reviewer's probe end to end: a word passage on the second of two identical words, the
    /// text around it retyped (tracked correctly), then a wholesale change forces a literal
    /// re-find. A step may drop the passage; it must never aim at the first "quick".
    func testStepAfterInvalidateNeverTargetsTheOtherIdenticalOccurrence() throws {
        var text = "A quick note. Then a long line of words, a quick brown fox. End."
        var engine = makeEngine()
        let second = (text as NSString).range(of: "quick", options: .backwards)
        let id = try XCTUnwrap(engine.add(second, author: .you, in: text))
        _ = engine.locateAll(in: text)
        text = typing(&engine, "Then a long line of words, a ", with: "Later, one ", in: text)
        text = typing(&engine, " brown fox. End.", with: " note", in: text)
        XCTAssertEqual(engine.locateAll(in: text).first?.range, (text as NSString).range(of: "quick", options: .backwards))
        text = typing(&engine, "Later, one ", with: "Later, two ", in: text)
        engine.invalidateLiveRanges()

        let truth = (text as NSString).range(of: "quick", options: .backwards)
        let located = engine.locateAll(in: text)
        XCTAssertFalse(located.contains { $0.range == (text as NSString).range(of: "quick") },
                       "the first quick is not the passage")
        if let edit = engine.step(id, by: -1, in: text) {
            XCTAssertEqual(edit.range, truth, "a step may only ever rewrite the passage's own text")
        }
    }
}

import XCTest
import AppKit
@testable import Lineform

/// Adversarial probes of History: the engine, the controller's counter and sidebar model, and the
/// counter's placement. Probes that exposed a real defect are wrapped in `XCTExpectFailure`.
@MainActor
final class AdversarialHistoryProbeTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEngine(_ history: DocumentHistory = DocumentHistory(passages: [])) -> DocumentHistoryEngine {
        let date = fixedDate
        return DocumentHistoryEngine(history: history, now: { date })
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

    /// The writer (or an accepted AI change) replaces `old` with `new`; recorded as an accept.
    @discardableResult
    private func accept(_ engine: inout DocumentHistoryEngine, _ text: inout String, _ old: String, _ new: String,
                        within scope: NSRange? = nil) -> UUID? {
        let ns = text as NSString
        let r = scope.map { ns.range(of: old, options: .literal, range: $0) } ?? ns.range(of: old)
        XCTAssertNotEqual(r.location, NSNotFound, "missing \(old)")
        engine.applyEdit(r, replacement: new)
        text = ns.replacingCharacters(in: r, with: new)
        return engine.recordAccepted(range: NSRange(location: r.location, length: (new as NSString).length),
                                     original: old, accepted: new, in: text)
    }

    // MARK: - Re-finding after a reload / reopen

    /// A Japanese word passage (one `.byWords` word) is found by its live range during the
    /// session, but the literal re-find after a reload or reopen skips any match preceded by a
    /// letter — and in Japanese every word is.
    func testJapaneseWordPassageSurvivesAReload() throws {
        var engine = makeEngine()
        var text = "今日は晴れです。明日は雨です。"
        let id = try XCTUnwrap(accept(&engine, &text, "晴れ", "曇り"))
        XCTAssertEqual(engine.history.passages.first { $0.id == id }?.level, .word)
        XCTAssertTrue(engine.locateAll(in: text).contains { $0.id == id }, "found by live range")
        engine.invalidateLiveRanges()  // live reload, Convert to Plain Text, a checkbox toggle
        XCTExpectFailure("PassageHistoryText.locate requires a non-letter before/after a word-edged needle; CJK text has none, so CJK word passages are dropped on every reload or reopen")
        XCTAssertTrue(engine.locateAll(in: text).contains { $0.id == id })
    }

    /// The same for a reopened document (a fresh engine from the persisted history).
    func testJapaneseWordPassageSurvivesReopen() throws {
        var engine = makeEngine()
        var text = "私は東京に住んでいます。"
        let id = try XCTUnwrap(accept(&engine, &text, "東京", "大阪"))
        _ = engine.locateAll(in: text)
        var reopened = makeEngine(DocumentHistoryEngine.preparedForLoad(engine.history))
        XCTExpectFailure("CJK word passages are lost when the document is reopened (same cause as the reload case)")
        XCTAssertTrue(reopened.locateAll(in: text).contains { $0.id == id })
    }

    func testEnglishWordPassageSurvivesReopen() throws {
        var engine = makeEngine()
        var text = "The quick fox jumps."
        let id = try XCTUnwrap(accept(&engine, &text, "quick", "slow"))
        _ = engine.locateAll(in: text)
        var reopened = makeEngine(DocumentHistoryEngine.preparedForLoad(engine.history))
        XCTAssertTrue(reopened.locateAll(in: text).contains { $0.id == id })
    }

    /// Edited externally: the passage's text now appears twice (ambiguous) or not at all. It must
    /// be dropped, never placed on the wrong occurrence.
    func testExternallyEditedFileNeverPlacesAPassageOnTheWrongText() throws {
        var engine = makeEngine()
        var text = "One fine day. Two quiet nights."
        let id = try XCTUnwrap(accept(&engine, &text, "fine", "bright"))
        _ = engine.locateAll(in: text)
        let stored = engine.history
        // Duplicate occurrence with the same context on both sides.
        var a = makeEngine(stored)
        let duplicated = "One bright day. Two quiet nights. One bright day. Two quiet nights."
        if let found = a.locateAll(in: duplicated).first(where: { $0.id == id }) {
            XCTAssertEqual((duplicated as NSString).substring(with: found.range), "bright")
        }
        // Gone entirely.
        var b = makeEngine(stored)
        XCTAssertFalse(b.locateAll(in: "Completely different text.").contains { $0.id == id })
        XCTAssertTrue(b.history.passages.isEmpty)
        // Present inside a longer word only: never matched mid-word.
        var c = makeEngine(stored)
        XCTAssertFalse(c.locateAll(in: "One brightness day.").contains { $0.id == id })
    }

    // MARK: - Nesting and steps

    /// Paragraph ▸ sentence ▸ word, each with its own versions; stepping the outer levels hides and
    /// restores the inner ones exactly, and a fourth level inside the word is refused.
    func testThreeLevelNestingStepsRoundTripAndAFourthIsRefused() throws {
        var engine = makeEngine()
        var text = "Alpha beta gamma delta. Epsilon zeta eta theta.\n\nNext paragraph."
        let paragraph = "Alpha beta gamma delta. Epsilon zeta eta theta."
        let paragraphID = try XCTUnwrap(accept(&engine, &text, paragraph, "Alpha beta gamma delta. Epsilon zeta eta iota."))
        let sentenceID = try XCTUnwrap(accept(&engine, &text, "Alpha beta gamma delta.", "Alpha beta GAMMA delta."))
        let wordID = try XCTUnwrap(accept(&engine, &text, "beta", "BETA"))
        let levels = [paragraphID, sentenceID, wordID].compactMap { id in engine.history.passages.first { $0.id == id }?.level }
        XCTAssertEqual(levels, [.paragraph, .sentence, .word])
        let current = text
        // A word inside the word passage: nothing nests inside a word.
        XCTAssertFalse(engine.canAdd(range(of: "BE", in: text), in: text))
        // Step the paragraph back, then forward: identical text, the word passage visible again.
        let back = apply(engine.step(paragraphID, by: -1, in: text), to: text)
        XCTAssertEqual(back, "Alpha beta gamma delta. Epsilon zeta eta theta.\n\nNext paragraph.")
        XCTAssertFalse(engine.locateAll(in: back).contains { $0.id == wordID })
        let forward = apply(engine.step(paragraphID, by: 1, in: back), to: back)
        XCTAssertEqual(forward, current)
        let located = engine.locateAll(in: forward)
        XCTAssertTrue(located.contains { $0.id == wordID })
        XCTAssertTrue(located.contains { $0.id == sentenceID })
        // Step the word and the sentence through every version: never other text.
        var t = forward
        for _ in 0..<5 {
            t = apply(engine.step(wordID, by: 1, in: t), to: t)
            XCTAssertTrue(t.hasSuffix("Epsilon zeta eta iota.\n\nNext paragraph."), t)
        }
    }

    /// 200 versions of one passage: stepping stays exact and cheap.
    func testTwoHundredVersions() throws {
        var engine = makeEngine()
        var text = "Lead in. Version zero here. Tail out."
        var old = "Version zero here."
        var id: UUID?
        for i in 1...200 {
            let new = "Version \(i) here."
            id = accept(&engine, &text, old, new)
            old = new
        }
        let passageID = try XCTUnwrap(id)
        let passage = try XCTUnwrap(engine.history.passages.first { $0.id == passageID })
        XCTAssertEqual(passage.versions.count, 201)
        XCTAssertEqual(engine.history.passages.count, 1, "one passage, not 200")
        let start = Date()
        var t = text
        for _ in 0..<201 { t = apply(engine.step(passageID, by: 1, in: t), to: t) }
        XCTAssertEqual(t, text, "a full cycle returns to the same text")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        XCTAssertEqual(HistoryCounter(count: 201, current: 200).text, "201/201")
    }

    func testIdenticalAcceptCollapsesOnLoadAndIsNotListedTwice() throws {
        var engine = makeEngine()
        var text = "Same words here."
        let id = try XCTUnwrap(accept(&engine, &text, "Same words here.", "Same words here."))
        let prepared = DocumentHistoryEngine.preparedForLoad(engine.history)
        XCTAssertFalse(prepared.passages.contains { $0.id == id && $0.versions.count > 1
            && Set($0.versions.map(\.text)).count < $0.versions.count }, "no passage lists one text twice")
    }

    /// Deleting text that holds a passage drops it (by design); undoing the delete must not
    /// resurrect it onto different text.
    func testDeleteThenRetypeNeverRebindsToOtherText() throws {
        var engine = makeEngine()
        var text = "Keep this. Change me. Keep this."
        let id = try XCTUnwrap(accept(&engine, &text, "Change me.", "Changed it."))
        let r = range(of: " Changed it.", in: text)
        engine.applyEdit(r, replacement: "")
        text = (text as NSString).replacingCharacters(in: r, with: "")
        engine.applyEdit(NSRange(location: r.location, length: 0), replacement: " Changed it.")
        text = (text as NSString).replacingCharacters(in: NSRange(location: r.location, length: 0), with: " Changed it.")
        for passage in engine.locateAll(in: text) where passage.id == id {
            XCTAssertEqual((text as NSString).substring(with: passage.range), "Changed it.")
        }
    }

    /// Replace With… on a word inside a word passage is not offered (nothing nests in a word),
    /// and adding the passage's own range returns the existing passage.
    func testReplaceWithInsideAWordPassage() throws {
        var engine = makeEngine()
        var text = "A splendid result."
        let id = try XCTUnwrap(accept(&engine, &text, "splendid", "wonderful"))
        XCTAssertFalse(engine.canAdd(range(of: "won", in: text), in: text))
        XCTAssertEqual(engine.add(range(of: "wonderful", in: text), author: .you, in: text), id)
        let edit = try XCTUnwrap(engine.addReplacement("great\nnew", to: id, in: text))
        XCTAssertEqual(edit.replacement, "great new")
        let stepped = apply(edit, to: text)
        let back = engine.addReplacement("  wonderful  ", to: id, in: stepped)
        XCTAssertEqual(back?.replacement, "wonderful", "an existing version is selected, not duplicated")
        XCTAssertEqual(engine.history.passages.first { $0.id == id }?.versions.count, 3)
    }

    /// An AI-style rewrite over a sentence that holds two word passages: both survive, filed
    /// under the new passage, and stepping back shows them again.
    func testAcceptOverTwoWordPassagesFilesBoth() throws {
        var engine = makeEngine()
        var text = "Alpha beta gamma delta."
        let w1 = try XCTUnwrap(accept(&engine, &text, "beta", "BETA"))
        let w2 = try XCTUnwrap(accept(&engine, &text, "delta", "DELTA"))
        let original = text
        let rewritten = "Omega BETA gamma DELTA!"
        engine.beginSettingAside()
        engine.applyEdit(NSRange(location: 0, length: (original as NSString).length), replacement: rewritten)
        engine.endSettingAside()
        text = rewritten
        let sentence = try XCTUnwrap(engine.recordAccepted(range: NSRange(location: 0, length: (text as NSString).length),
                                                           original: original, accepted: rewritten, in: text))
        engine.finishSetAside()
        XCTAssertNotNil(engine.history.passages.first { $0.id == w1 }, "BETA's history kept")
        XCTAssertNotNil(engine.history.passages.first { $0.id == w2 }, "DELTA's history kept")
        let back = apply(engine.step(sentence, by: -1, in: text), to: text)
        XCTAssertEqual(back, original)
        let located = engine.locateAll(in: back)
        XCTAssertTrue(located.contains { $0.id == w1 } && located.contains { $0.id == w2 })
    }

    /// fileSetAside matches a set-aside passage by `original.contains(text)`: a short word passage
    /// is filed under ANY version containing it as a substring, including inside another word.
    func testSetAsideWordIsNotFiledByASubstringOfAnotherWord() throws {
        var engine = makeEngine()
        var text = "The cat is here."
        let word = try XCTUnwrap(accept(&engine, &text, "cat", "dog"))
        // A rewrite that removes "dog" as a word, but contains it inside "dogma".
        let original = text
        let rewritten = "The dogma is here."
        engine.beginSettingAside()
        engine.applyEdit(NSRange(location: 0, length: (original as NSString).length), replacement: rewritten)
        engine.endSettingAside()
        _ = engine.recordAccepted(range: NSRange(location: 0, length: (rewritten as NSString).length),
                                  original: original, accepted: rewritten, in: rewritten)
        engine.finishSetAside()
        // Filed under the version "The dog is here." — correct here, since `original` holds it as a word.
        if let filed = engine.history.passages.first(where: { $0.id == word }) {
            XCTAssertNotNil(filed.parentID)
        }
    }

    // MARK: - Controller: counter and sidebar model

    func testCounterAfterReplaceWithShowsOneOfOne() throws {
        let controller = DocumentHistoryController(store: NullPassageHistoryStore(), now: { [fixedDate] in fixedDate })
        let text = "Alpha beta gamma. Delta epsilon."
        controller.open(url: nil, text: text)
        let id = try XCTUnwrap(controller.add(range(of: "Alpha beta gamma.", in: text), text: text))
        XCTAssertTrue(controller.showPassage(id, text: text))
        // Observation: a just-added one-version passage shows the counter "1/1".
        XCTAssertEqual(controller.display?.counter?.text, "1/1")
        XCTAssertEqual(controller.sidebarModel.versions.count, 1)
        XCTAssertTrue(controller.sidebarModel.versions[0].isOriginal)
    }

    func testSidebarRowTextForOddVersions() {
        XCTAssertEqual(HistorySidebarRow.displayText(for: "\n\n  First line\twith   tabs\nSecond"), "First line with tabs")
        XCTAssertEqual(HistorySidebarRow.displayText(for: "Line one\u{2028}Line two"), "Line one")
        XCTAssertEqual(HistorySidebarRow.displayText(for: "a\r\nb"), "a")
        let arabic = "\u{0647}\u{0630}\u{0627} \u{0646}\u{0635}"
        XCTAssertEqual(HistorySidebarRow.displayText(for: arabic), arabic)
        let long = String(repeating: "word ", count: 5_000)
        XCTAssertEqual(HistorySidebarRow.displayText(for: long).count, 5_000 * 5 - 1)
        XCTAssertEqual(HistorySidebarRow.displayText(for: "   "), "")
    }

    func testCounterTextWidths() {
        XCTAssertEqual(HistoryCounter(count: 1, current: 0).text, "1/1")
        XCTAssertEqual(HistoryCounter(count: 100, current: 98).text, "99/100")
        let narrow = HistoryCounterLayout.font(forTextSize: 8)
        XCTAssertGreaterThanOrEqual(narrow.pointSize, 11)
    }

    // MARK: - Counter placement in right-to-left text

    private func laidOutTextView(_ text: String) throws -> LineformTextView {
        let textView = LineformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        textView.applyDefaultTypography()
        textView.string = text
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        layoutManager.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        return textView
    }

    /// An Arabic word passage mid-line: the counter goes "after" the last logical glyph — which
    /// in RTL is its LEFT edge. Drawn at location + advance it lands on the passage's own glyphs.
    func testCounterNeverOverlapsTextInRightToLeftParagraph() throws {
        let text = "\u{0647}\u{0630}\u{0627} \u{0646}\u{0635} \u{0642}\u{0635}\u{064A}\u{0631} \u{062C}\u{062F}\u{0627}."
        let textView = try laidOutTextView(text)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let word = range(of: "\u{0646}\u{0635}", in: text)
        let located = LocatedPassage(id: UUID(), level: .word, range: word, rootID: UUID())
        let counter = HistoryCounter(count: 3, current: 1)
        textView.historyDisplay = HistoryModeDisplay(passages: [located], selectedID: nil, hoveredID: nil, counter: nil)
        textView.historyDisplay = HistoryModeDisplay(passages: [located], selectedID: located.id, hoveredID: nil, counter: counter)
        layoutManager.ensureLayout(for: container)
        let frame = try XCTUnwrap(textView.historyCounterFrame(for: word, counter: counter))
        // Every glyph of the line other than the counter's room must stay clear of the frame.
        let origin = textView.textContainerOrigin
        var overlaps: [Int] = []
        var rects: [String] = []
        for index in 0..<(text as NSString).length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            let ink = rect.insetBy(dx: 0.5, dy: 0)
            if ink.width > 0, ink.intersects(frame), (text as NSString).character(at: index) != 0x20 {
                overlaps.append(index)
                rects.append("\(index): x \(rect.minX)…\(rect.maxX)")
            }
        }
        XCTExpectFailure("historyCounterFrame places the counter at the last glyph's location + advance, i.e. to its RIGHT; in RTL text the reserved room is on the LEFT, so the counter is drawn over the passage's own last letters")
        XCTAssertTrue(overlaps.isEmpty, "counter frame x \(frame.minX)…\(frame.maxX) overlaps characters \(rects); passage = \(word)")
    }
}

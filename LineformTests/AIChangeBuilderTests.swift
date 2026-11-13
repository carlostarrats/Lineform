import XCTest
@testable import Lineform

final class AIChangeBuilderTests: XCTestCase {
    private func segments(_ text: String) -> [ProseSegment] {
        MarkdownStructureMap.proseSegments(in: text, selection: NSRange(location: 0, length: (text as NSString).length))
    }

    private func change(_ text: String, _ revisions: [String?]) -> AIChange? {
        AIChangeBuilder.change(segments: segments(text), revisions: revisions, in: text)
    }

    /// Applying the change's edits (back to front) to `text`.
    private func applied(_ change: AIChange, to text: String) -> String {
        AIActionController.applying(change.edits(), to: text)
    }

    /// Owner bug (build 38): a one-sentence rewrite came back as three word-level decisions.
    func testOneSentenceRewriteIsOneChange() throws {
        let text = "Though wise men, at their end know dark is right,"
        let revision = "Though wise men, at their end, know that darkness is right,"
        let result = try XCTUnwrap(change(text, [revision]))
        XCTAssertEqual(result.range, NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(result.original, text)
        XCTAssertEqual(result.replacement, revision)
        XCTAssertEqual(applied(result, to: text), revision)
    }

    func testMultiSegmentSelectionIsOneChangeKeepingStructure() throws {
        let text = "- alpha one\n- beta two\n"
        let ns = text as NSString
        XCTAssertEqual(segments(text).map(\.text), ["alpha one", "beta two"])
        let result = try XCTUnwrap(change(text, ["alpha 1", "beta 2"]))
        let start = ns.range(of: "alpha one").location
        XCTAssertEqual(result.range, NSRange(location: start, length: NSMaxRange(ns.range(of: "beta two")) - start))
        XCTAssertEqual(result.original, "alpha one\n- beta two")
        XCTAssertEqual(result.replacement, "alpha 1\n- beta 2")
        XCTAssertEqual(result.parts.count, 2, "one decision, applied as one edit per segment")
        XCTAssertFalse(result.edits().contains { $0.replacement.contains("\n") || ns.substring(with: $0.range).contains("\n") },
                       "no edit touches a line ending: the text view refuses those")
        XCTAssertEqual(applied(result, to: text), "- alpha 1\n- beta 2\n")
    }

    func testUnchangedSegmentsAtEdgesAreExcluded() throws {
        let text = "First one here.\n\nSecond one here.\n\nThird one here."
        let result = try XCTUnwrap(change(text, ["First one here.", "Second one there.", "Third one here."]))
        XCTAssertEqual(result.range, (text as NSString).range(of: "Second one here."))
        XCTAssertEqual(result.original, "Second one here.")
        XCTAssertEqual(result.replacement, "Second one there.")
    }

    func testUnchangedSegmentInTheMiddleIsKeptVerbatim() throws {
        let text = "First one here.\n\nSecond one here.\n\nThird one here."
        let result = try XCTUnwrap(change(text, ["First one there.", nil, "Third one there."]))
        XCTAssertEqual(result.original, text)
        XCTAssertEqual(result.replacement, "First one there.\n\nSecond one here.\n\nThird one there.")
        XCTAssertEqual(result.parts.count, 2)
    }

    func testProofreadIsAlsoOneChange() throws {
        let text = "Teh dog ran far awya from home."
        let result = try XCTUnwrap(change(text, ["The dog ran far away from home."]))
        XCTAssertEqual(result.range, NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(applied(result, to: text), "The dog ran far away from home.")
    }

    func testIdenticalRevisionProducesNoChange() {
        XCTAssertNil(change("The quick brown fox", ["The quick brown fox"]))
    }

    /// An AI that answers in NFC for an NFD document changed nothing the writer can see: the
    /// segment is unchanged and the writer's own bytes are kept.
    func testCanonicallyEquivalentRevisionIsUnchanged() {
        XCTAssertNil(change("The cafe\u{301} was big.", ["The caf\u{E9} was big."]))
    }

    func testDroppedRevisionProducesNoChange() {
        XCTAssertNil(change("The quick brown fox", [nil]))
        XCTAssertNil(change("The quick brown fox", []), "missing revision")
    }

    func testStaleSegmentProducesNoChange() {
        let segment = ProseSegment(range: NSRange(location: 0, length: 5), text: "Hello")
        XCTAssertNil(AIChangeBuilder.change(segments: [segment], revisions: ["Howdy"], in: "Jello world"))
        XCTAssertNil(AIChangeBuilder.change(segments: [segment], revisions: ["Howdy"], in: "Hi"))
    }

    /// The stale check is EXACT: a document region that is only canonically equal (same UTF-16
    /// length, combining marks reordered) is stale, or a change would splice over bytes the AI
    /// never saw.
    func testSegmentDifferingOnlyByNormalizationIsStale() {
        let segmentText = "Ba\u{301}\u{323}d day"
        let document = "Ba\u{323}\u{301}d day"
        XCTAssertEqual(segmentText, document, "canonically equivalent")
        XCTAssertEqual((segmentText as NSString).length, (document as NSString).length)
        let segment = ProseSegment(range: NSRange(location: 0, length: (segmentText as NSString).length), text: segmentText)
        XCTAssertNil(AIChangeBuilder.change(segments: [segment], revisions: ["Good day"], in: document))
        XCTAssertNotNil(AIChangeBuilder.change(segments: [segment], revisions: ["Good day"], in: segmentText))
    }

    func testChangeNeverSplitsComposedCharacters() throws {
        let text = "\u{1F44D}\u{1F3FD} cafe\u{301} ok"
        let result = try XCTUnwrap(change(text, ["\u{1F44D}\u{1F3FF} cafe ok"]))
        let ns = text as NSString
        XCTAssertEqual(result.range, ns.rangeOfComposedCharacterSequences(for: result.range))
        XCTAssertEqual(ns.substring(with: result.range), result.original)
    }

    func testSentenceRangesExcludeListAndQuoteMarkers() {
        let list = "- Item one. Item two."
        XCTAssertEqual(AISentenceSplitter.sentences(in: list, selection: NSRange(location: 0, length: (list as NSString).length)).map(\.range),
                       [(list as NSString).range(of: "Item one."), (list as NSString).range(of: "Item two.")])
        let quote = "> Quote one. Quote two."
        XCTAssertEqual(AISentenceSplitter.sentences(in: quote, selection: NSRange(location: 0, length: (quote as NSString).length)).map(\.range),
                       [(quote as NSString).range(of: "Quote one."), (quote as NSString).range(of: "Quote two.")])
    }

    func testSentencesSpanEmphasis() {
        let text = "This is **very** good. Next one."
        let sentences = AISentenceSplitter.sentences(in: text, selection: NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences.first?.prose, "This is very good.")
        XCTAssertEqual(sentences.first?.range, NSRange(location: 0, length: 22))
        XCTAssertEqual(sentences.last?.prose, "Next one.")
        XCTAssertEqual(sentences.last?.range, NSRange(location: 23, length: 9))
    }

    func testSentencesAreOnlyThoseTheSelectionTouchesAndSkipStructure() {
        let text = "# Title\n\nFirst one. Second one. Third one.\n\n---\n\n```\ncode here.\n```\n"
        let ns = text as NSString
        let all = AISentenceSplitter.sentences(in: text, selection: NSRange(location: 0, length: ns.length))
        XCTAssertEqual(all.map(\.prose), ["Title", "First one.", "Second one.", "Third one."])

        // Inside one sentence: that sentence, whole — never its neighbours on the line.
        let inside = NSRange(location: ns.range(of: "Second").location + 2, length: 3)
        XCTAssertEqual(AISentenceSplitter.sentences(in: text, selection: inside).map(\.prose), ["Second one."])

        // Partly into two sentences: both, whole; the third is never sent.
        let across = NSRange(location: ns.range(of: "one. Second").location, length: 8)
        XCTAssertEqual(AISentenceSplitter.sentences(in: text, selection: across).map(\.prose),
                       ["First one.", "Second one."])

        // Only the space between sentences touches none.
        let gap = NSRange(location: NSMaxRange(ns.range(of: "First one.")), length: 1)
        XCTAssertEqual(AISentenceSplitter.sentences(in: text, selection: gap), [])
    }

    func testGuardedPipelineKeepsStructureAcrossEmphasisAndCRLF() throws {
        let text = "\u{FEFF}# A _good_ title\r\n\r\n- This is **very** good.\r\n"
        let ns = text as NSString
        let segments = self.segments(text)
        XCTAssertFalse(segments.contains { $0.text.contains("*") || $0.text.contains("_") || $0.text.contains("\r") })
        let revisions = segments.map { $0.text.replacingOccurrences(of: "good", with: "fine") }
        let admitted = MarkdownStructureGuard.admissibleRevisions(revisions, for: segments, in: text)
        let result = try XCTUnwrap(AIChangeBuilder.change(segments: segments, revisions: admitted, in: text))
        XCTAssertEqual(result.range, ns.rangeOfComposedCharacterSequences(for: result.range))
        XCTAssertEqual(ns.substring(with: result.range), result.original)
        XCTAssertTrue(result.original.contains("\r\n\r\n- "), "the document's own text between segments")
        XCTAssertTrue(result.replacement.contains("_ title\r\n\r\n- This is **"), "kept byte-for-byte, CRLF and all")
        let composed = applied(result, to: text)
        XCTAssertEqual(composed, "\u{FEFF}# A _fine_ title\r\n\r\n- This is **very** fine.\r\n")
        XCTAssertEqual(AIActionController.applying([AIReviewEdit(range: result.range, replacement: result.replacement)], to: text),
                       composed, "the whole-span replacement and the per-segment edits agree")
        XCTAssertTrue(MarkdownStructureGuard.verify(original: text, revised: composed))
    }
}

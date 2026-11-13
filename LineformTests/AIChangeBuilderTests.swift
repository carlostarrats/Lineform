import XCTest
@testable import Lineform

final class AIChangeBuilderTests: XCTestCase {
    private func changes(_ text: String, _ revisions: [String?]) -> [AIChange] {
        let segments = MarkdownStructureMap.proseSegments(in: text, selection: NSRange(location: 0, length: (text as NSString).length))
        return AIChangeBuilder.changes(segments: segments, revisions: revisions, in: text)
    }

    /// Applying every change (back to front) to `text`.
    private func applied(_ changes: [AIChange], to text: String) -> String {
        let result = NSMutableString(string: text)
        for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: change.range, with: change.replacement)
        }
        return result as String
    }

    private func assertComposed(_ changes: [AIChange], in text: String, file: StaticString = #filePath, line: UInt = #line) {
        let ns = text as NSString
        for change in changes {
            XCTAssertEqual(change.range, ns.rangeOfComposedCharacterSequences(for: change.range), "\(change)", file: file, line: line)
            XCTAssertEqual(ns.substring(with: change.range), change.original, file: file, line: line)
        }
    }

    func testSingleWordReplacement() {
        let result = changes("The quick brown fox", ["The fast brown fox"])
        XCTAssertEqual(result, [AIChange(id: 0, range: NSRange(location: 4, length: 5), original: "quick", replacement: "fast")])
    }

    func testDeletionIsOneChange() {
        let result = changes("really very good", ["good"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.original, "really very ")
        XCTAssertEqual(result.first?.replacement, "")
        XCTAssertEqual(applied(result, to: "really very good"), "good")
    }

    func testChangesSeparatedByWhitespaceMerge() {
        let result = changes("big red car", ["small blue car"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.original, "big red")
        XCTAssertEqual(result.first?.replacement, "small blue")
        XCTAssertEqual(result.first?.range, NSRange(location: 0, length: 7))
    }

    func testApostropheStaysInTheWord() {
        let result = changes("It isn't here", ["It wasn’t here"])
        XCTAssertEqual(result.map(\.original), ["isn't"])
        XCTAssertEqual(result.map(\.replacement), ["wasn’t"])
    }

    func testChangesUseDocumentRangesAcrossSegments() {
        let text = "## Good title\n\nA good day"
        let result = changes(text, ["Fine title", "A fine day"])
        XCTAssertEqual(result.map(\.id), [0, 1])
        XCTAssertEqual(result.map(\.range), [NSRange(location: 3, length: 4), NSRange(location: 17, length: 4)])
        XCTAssertEqual(result.map(\.original), ["Good", "good"])
        XCTAssertEqual(applied(result, to: text), "## Fine title\n\nA fine day")
    }

    func testChangesNeverSplitComposedCharacters() {
        let text = "cafe\u{301} 👍🏽 ok 👨‍👩‍👧 yes"
        let result = changes(text, ["cafe 👍🏽 okay 👨‍👩‍👧 no"])
        XCTAssertEqual(result.map(\.original), ["cafe\u{301}", "ok", "yes"])
        assertComposed(result, in: text)
        XCTAssertEqual(applied(result, to: text), "cafe 👍🏽 okay 👨‍👩‍👧 no")
    }

    func testEmojiItselfChangesAsAWhole() {
        let text = "Nice 👍🏽 work"
        let result = changes(text, ["Nice 👍🏿 work"])
        XCTAssertEqual(result.map(\.original), ["👍🏽"])
        assertComposed(result, in: text)
    }

    func testJapaneseAndChineseDiffPerCharacter() {
        let japanese = "今日は良い天気です。"
        let ja = changes(japanese, ["今日は悪い天気です。"])
        XCTAssertEqual(ja.map(\.original), ["良"])
        XCTAssertEqual(ja.map(\.replacement), ["悪"])
        assertComposed(ja, in: japanese)

        let chinese = "我们今天去公园散步。"
        let zh = changes(chinese, ["我们明天去公园散步。"])
        XCTAssertEqual(zh.map(\.original), ["今"])
        XCTAssertEqual(zh.map(\.range), [NSRange(location: 2, length: 1)])
        XCTAssertEqual(applied(zh, to: chinese), "我们明天去公园散步。")
    }

    func testInsertionHasEmptyRange() {
        let result = changes("a day", ["a good day"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.original, "")
        XCTAssertEqual(applied(result, to: "a day"), "a good day")
    }

    func testIdenticalRevisionProducesNoChanges() {
        XCTAssertEqual(changes("The quick brown fox", ["The quick brown fox"]), [])
    }

    func testDroppedRevisionProducesNoChanges() {
        XCTAssertEqual(changes("The quick brown fox", [nil]), [])
        XCTAssertEqual(changes("The quick brown fox", []), [], "missing revision")
    }

    func testStaleSegmentProducesNoChanges() {
        let segment = ProseSegment(range: NSRange(location: 0, length: 5), text: "Hello")
        XCTAssertEqual(AIChangeBuilder.changes(segments: [segment], revisions: ["Howdy"], in: "Jello world"), [])
        XCTAssertEqual(AIChangeBuilder.changes(segments: [segment], revisions: ["Howdy"], in: "Hi"), [])
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
        XCTAssertEqual(AIChangeBuilder.changes(segments: [segment], revisions: ["Good day"], in: document), [])
        XCTAssertEqual(AIChangeBuilder.changes(segments: [segment], revisions: ["Good day"], in: segmentText).count, 1)
    }

    func testSentenceRangesExcludeListAndQuoteMarkers() {
        let list = "- Item one. Item two."
        XCTAssertEqual(AISentenceSplitter.sentences(in: list, selection: NSRange(location: 0, length: (list as NSString).length)).map(\.range),
                       [(list as NSString).range(of: "Item one."), (list as NSString).range(of: "Item two.")])
        let quote = "> Quote one. Quote two."
        XCTAssertEqual(AISentenceSplitter.sentences(in: quote, selection: NSRange(location: 0, length: (quote as NSString).length)).map(\.range),
                       [(quote as NSString).range(of: "Quote one."), (quote as NSString).range(of: "Quote two.")])
    }

    func testOversizedDiffFallsBackToOneChange() {
        let words = (0..<2_100).map { "w\($0)" }
        let original = words.joined(separator: " ")
        let revision = words.reversed().joined(separator: " ")
        let segment = ProseSegment(range: NSRange(location: 0, length: (original as NSString).length), text: original)
        let result = AIChangeBuilder.changes(segments: [segment], revisions: [revision], in: original)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.range, segment.range)
        XCTAssertEqual(result.first?.replacement, revision)
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

    func testSentencesUseFullLinesAndSkipStructure() {
        let text = "# Title\n\nFirst one. Second one.\n\n---\n\n```\ncode here.\n```\n"
        let start = (text as NSString).range(of: "one. Second").location
        let all = AISentenceSplitter.sentences(in: text, selection: NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(all.map(\.prose), ["Title", "First one.", "Second one."])
        let partial = AISentenceSplitter.sentences(in: text, selection: NSRange(location: start, length: 3))
        XCTAssertEqual(partial.map(\.prose), ["First one.", "Second one."], "the selection widens to full lines")
    }

    func testGuardedPipelineKeepsStructureAcrossEmphasisAndCRLF() {
        let text = "\u{FEFF}# A _good_ title\r\n\r\n- This is **very** good.\r\n"
        let ns = text as NSString
        let segments = MarkdownStructureMap.proseSegments(in: text, selection: NSRange(location: 0, length: ns.length))
        XCTAssertFalse(segments.contains { $0.text.contains("*") || $0.text.contains("_") || $0.text.contains("\r") })
        let revisions = segments.map { $0.text.replacingOccurrences(of: "good", with: "fine") }
        let admitted = MarkdownStructureGuard.admissibleRevisions(revisions, for: segments, in: text)
        let result = AIChangeBuilder.changes(segments: segments, revisions: admitted, in: text)
        XCTAssertEqual(result.map(\.original), ["good", "good"])
        assertComposed(result, in: text)
        let composed = applied(result, to: text)
        XCTAssertEqual(composed, "\u{FEFF}# A _fine_ title\r\n\r\n- This is **very** fine.\r\n")
        XCTAssertTrue(MarkdownStructureGuard.verify(original: text, revised: composed))
    }
}

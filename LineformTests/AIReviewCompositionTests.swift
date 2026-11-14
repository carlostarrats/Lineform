import XCTest
@testable import Lineform

final class AIReviewCompositionTests: XCTestCase {
    private func change(_ id: Int, _ needle: String, in text: String, _ replacement: String) -> AIChange {
        let range = (text as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "missing \(needle)")
        return AIChange(id: id, range: range, original: needle, replacement: replacement)
    }

    private func session(_ text: String, _ changes: [AIChange]) -> AIReviewSession {
        AIReviewSession(action: .rephrase, changes: changes,
                        selectionRange: NSRange(location: 0, length: (text as NSString).length),
                        originalSelection: text)
    }

    private func substrings(_ string: String, _ ranges: [NSRange]?) -> [String] {
        (ranges ?? []).map { (string as NSString).substring(with: $0) }
    }

    // MARK: - Option A presentation

    /// The mockup's sentence: the whole line is rewritten, so the replacement starts on its own
    /// line, under the struck original.
    func testWholeLineChangeStacksReplacementOnItsOwnLine() {
        let original = "Though wise men, at their end know dark is right,"
        let replacement = "Though wise men, at their end, know that darkness is right,"
        let text = "Do not go gentle into that good night,\n\n\(original)\nBecause their words had forked no lightning they"
        let composition = AIReviewComposition.build(text: text, session: session(text, [change(0, original, in: text, replacement)]))
        XCTAssertEqual(composition.string, "Do not go gentle into that good night,\n\n\(original)\n\(replacement)\nBecause their words had forked no lightning they")
        XCTAssertEqual(substrings(composition.string, composition.removedRanges[0]), [original])
        XCTAssertEqual(substrings(composition.string, composition.replacementRanges[0]), [replacement])
    }

    /// The overlay's line break is the document's own ending: a CRLF file gets CRLF.
    func testWholeLineBreakFollowsTheDocumentsLineEnding() {
        let text = "First line.\r\nOld second line.\r\nThird."
        let composition = AIReviewComposition.build(text: text, session: session(text, [change(0, "Old second line.", in: text, "New second line.")]))
        XCTAssertEqual(composition.string, "First line.\r\nOld second line.\r\nNew second line.\r\nThird.")
    }

    /// A rewritten list, task or quote item is a whole-line change: the replacement stacks on its
    /// own line and repeats the item's marker, so it reads as the same item (overlay only).
    func testWholeItemChangeStacksAndRepeatsTheMarker() {
        let original = "Though wise men, at their end know dark is right,"
        let replacement = "Though wise men, at their end, know that darkness is right,"
        for prefix in ["- ", "1. ", "> ", "- [ ] ", "  * ", "> - "] {
            let text = "Intro\n\(prefix)\(original)\r\nAfter"
            let review = session(text, [change(0, original, in: text, replacement)])
            let composition = AIReviewComposition.build(text: text, session: review)
            XCTAssertEqual(composition.string, "Intro\n\(prefix)\(original)\r\n\(prefix)\(replacement)\r\nAfter", prefix)
            XCTAssertEqual(substrings(composition.string, composition.removedRanges[0]), [original], prefix)
            XCTAssertEqual(substrings(composition.string, composition.replacementRanges[0]), [replacement], prefix)
            assertRoundTrip(text, review)
        }
    }

    /// A leading BOM belongs to the file, not to the first line's marker: the first item still
    /// stacks with its marker repeated, and the BOM is never copied into the overlay twice.
    func testFirstLineMarkerSkipsALeadingBOM() {
        let original = "Old first item."
        let replacement = "New first item."
        for prefix in ["- ", "> ", ""] {
            let text = "\u{FEFF}\(prefix)\(original)\nAfter"
            let ns = text as NSString
            let range = ns.range(of: original)
            XCTAssertEqual(AIReviewComposition.wholeLineMarker(range, in: ns), prefix, "\(prefix.debugDescription)")
            let composition = AIReviewComposition.build(text: text, session: session(text, [change(0, original, in: text, replacement)]))
            XCTAssertEqual(composition.string, "\u{FEFF}\(prefix)\(original)\n\(prefix)\(replacement)\nAfter", prefix)
            XCTAssertEqual(composition.string.unicodeScalars.filter { $0 == "\u{FEFF}" }.count, 1)
        }
    }

    /// Prose before the change on the same line is not a marker: inline.
    func testPartOfAnItemStaysInline() {
        let text = "- Keep this. Old part.\nAfter"
        let composition = AIReviewComposition.build(text: text, session: session(text, [change(0, "Old part.", in: text, "New part.")]))
        XCTAssertEqual(composition.string, "- Keep this. Old part. New part.\nAfter")
    }

    func testMidLineChangeIsInline() {
        let text = "Though wise men, at their end know dark is right,"
        let composition = AIReviewComposition.build(text: text, session: session(text, [change(0, "end know dark", in: text, "end, know that darkness")]))
        XCTAssertEqual(composition.string, "Though wise men, at their end know dark end, know that darkness is right,")
        XCTAssertEqual(substrings(composition.string, composition.removedRanges[0]), ["end know dark"])
        XCTAssertEqual(substrings(composition.string, composition.replacementRanges[0]), ["end, know that darkness"])
        XCTAssertEqual(AIReviewSession.separator(between: "end know dark", and: "end, know that darkness"), " ")
        XCTAssertFalse(composition.string.contains("\n"))
    }

    func testCompositionHasNoObjectReplacementCharacter() {
        let text = "a big day\n\nWhole line here.\n"
        let changes = [change(0, "big", in: text, "large"), change(1, "Whole line here.", in: text, "A new line.")]
        let composition = AIReviewComposition.build(text: text, session: session(text, changes))
        XCTAssertFalse(composition.string.contains("\u{FFFC}"))
    }

    /// Only the sentences that differ are struck and highlighted; identical leading and trailing
    /// sentences are drawn once, as document text.
    func testOnlyTheDifferingSentencesAreStruckAndHighlighted() {
        let text = "One stays. Two goes here. Three stays.\nNext."
        let composition = AIReviewComposition.build(text: text, session: session(text, [
            change(0, "One stays. Two goes here. Three stays.", in: text, "One stays. Two is new. Three stays."),
        ]))
        XCTAssertEqual(composition.string, "One stays. Two goes here. Two is new. Three stays.\nNext.")
        XCTAssertEqual(substrings(composition.string, composition.removedRanges[0]), ["Two goes here."])
        XCTAssertEqual(substrings(composition.string, composition.replacementRanges[0]), ["Two is new."])
    }

    /// When every sentence of the line differs, the line rule applies to what differs.
    func testDifferingSentencesCoveringTheWholeLineStack() {
        let text = "Alpha one. Beta two.\nAfter."
        let composition = AIReviewComposition.build(text: text, session: session(text, [
            change(0, "Alpha one. Beta two.", in: text, "Alpha uno. Beta dos."),
        ]))
        XCTAssertEqual(composition.string, "Alpha one. Beta two.\nAlpha uno. Beta dos.\nAfter.")
    }

    /// A change spanning several segments draws each PART; the markers and line endings between
    /// them are document text, drawn once.
    func testMultiPartChangeDrawsMarkersAndLineEndingsOnce() {
        let text = "- First item old\n- Second item old\n"
        let ns = text as NSString
        let first = ns.range(of: "First item old"), second = ns.range(of: "Second item old")
        let span = NSRange(location: first.location, length: NSMaxRange(second) - first.location)
        let replacement = "First item new\n- Second item new"
        let multi = AIChange(id: 0, range: span, original: ns.substring(with: span), replacement: replacement, parts: [
            AIChange.Part(offset: 0, length: first.length, replacement: "First item new"),
            AIChange.Part(offset: second.location - first.location, length: second.length, replacement: "Second item new"),
        ])
        let composition = AIReviewComposition.build(text: text, session: session(text, [multi]))
        // Each item is wholly rewritten, so each stacks under itself with its marker repeated.
        XCTAssertEqual(composition.string, "- First item old\n- First item new\n- Second item old\n- Second item new\n")
        XCTAssertEqual(substrings(composition.string, composition.removedRanges[0]), ["First item old", "Second item old"])
        XCTAssertEqual(substrings(composition.string, composition.replacementRanges[0]), ["First item new", "Second item new"])
        assertRoundTrip(text, session(text, [multi]))
    }

    func testMultiPartWholeLinesEachStack() {
        let text = "Alpha old.\nBeta old.\n"
        let ns = text as NSString
        let first = ns.range(of: "Alpha old."), second = ns.range(of: "Beta old.")
        let span = NSRange(location: 0, length: NSMaxRange(second))
        let multi = AIChange(id: 0, range: span, original: ns.substring(with: span), replacement: "Alpha new.\nBeta new.", parts: [
            AIChange.Part(offset: 0, length: first.length, replacement: "Alpha new."),
            AIChange.Part(offset: second.location, length: second.length, replacement: "Beta new."),
        ])
        let composition = AIReviewComposition.build(text: text, session: session(text, [multi]))
        XCTAssertEqual(composition.string, "Alpha old.\nAlpha new.\nBeta old.\nBeta new.\n")
        assertRoundTrip(text, session(text, [multi]))
    }

    func testPureInsertionAndPureDeletion() {
        let text = "one two three"
        let insertion = AIChange(id: 0, range: NSRange(location: 3, length: 0), original: "", replacement: ",")
        let deletion = change(1, " three", in: text, "")
        let composition = AIReviewComposition.build(text: text, session: session(text, [insertion, deletion]))
        XCTAssertEqual(composition.string, "one, two three")
        XCTAssertNil(composition.removedRanges[0], "an insertion removes nothing")
        XCTAssertEqual(substrings(composition.string, composition.replacementRanges[0]), [","])
        XCTAssertEqual(substrings(composition.string, composition.removedRanges[1]), [" three"])
        XCTAssertNil(composition.replacementRanges[1], "a deletion inserts nothing")
    }

    func testTextBeforeFirstChangeIsIdentical() {
        let text = "# Title\r\n\r\nThe first line stays.\r\nA very big day was had.\r\nEnd."
        let changes = [change(0, "very ", in: text, ""), change(1, "big", in: text, "large")]
        let composition = AIReviewComposition.build(text: text, session: session(text, changes))
        let prefix = (text as NSString).substring(to: changes[0].range.location)
        XCTAssertTrue(composition.string.hasPrefix(prefix))
        XCTAssertTrue(composition.string.hasSuffix(" day was had.\r\nEnd."), "text after the last change is identical too")
    }

    /// A rejected change is simply the document; an accepted one (applied only when the review
    /// ends) stands as its replacement in place of the original, plain — and the index mapping
    /// knows the original is hidden there.
    func testDecidedChangesDrawAsTheirOutcome() {
        let text = "a big day and a good night"
        var review = session(text, [change(0, "big", in: text, "large"), change(1, "good", in: text, "fine"),
                                    change(2, "night", in: text, "evening")])
        review.accept(0)
        review.reject(2)
        let composition = AIReviewComposition.build(text: text, session: review)
        XCTAssertEqual(composition.string, "a large day and a good fine night")
        XCTAssertEqual(substrings(composition.string, composition.acceptedRanges[0]), ["large"])
        XCTAssertNil(composition.changeRanges[0], "an accepted change is not clickable")
        let ns = text as NSString
        XCTAssertEqual(composition.overlayIndex(forDocumentIndex: ns.range(of: "day").location),
                       (composition.string as NSString).range(of: "day").location)
        XCTAssertEqual(composition.documentIndex(forOverlayIndex: (composition.string as NSString).range(of: "day").location),
                       ns.range(of: "day").location)
        XCTAssertEqual(Array(composition.removedRanges.keys), [1])
        XCTAssertEqual(Array(composition.replacementRanges.keys), [1])
        XCTAssertEqual(substrings(composition.string, composition.removedRanges[1]), ["good"])
        XCTAssertEqual(substrings(composition.string, composition.changeRanges[1].map { [$0] }), ["good fine"])
    }

    /// Proofread draws each correction IN PLACE — struck original, the fix right after it on the
    /// same line — even when the correction is a whole line's text.
    func testProofreadCorrectionsAreInline() {
        let text = "- teh\n- A secnd item.\n"
        let changes = [change(0, "teh", in: text, "the"), change(1, "secnd", in: text, "second")]
        let review = AIReviewSession(action: .proofread, changes: changes,
                                     selectionRange: NSRange(location: 0, length: (text as NSString).length), originalSelection: text)
        let composition = AIReviewComposition.build(text: text, session: review)
        XCTAssertEqual(composition.string, "- teh the\n- A secnd second item.\n", "never on a line of its own")
        XCTAssertEqual(substrings(composition.string, composition.removedRanges[0]), ["teh"])
        XCTAssertEqual(substrings(composition.string, composition.replacementRanges[1]), ["second"])
        XCTAssertEqual(composition.changeID(at: (composition.string as NSString).range(of: "second").location), 1)
    }

    /// A Rewrite-family change is shown at the smallest unit that changed: with the same number
    /// of sentences, only the changed ones are struck, each with its replacement right after it.
    func testRewriteShowsOnlyTheChangedSentencesInline() {
        let text = "One stays. Two is old. Three stays. Four is old."
        let replacement = "One stays. Two is new. Three stays. Four is new."
        let composition = AIReviewComposition.build(text: text, session: session(text, [change(0, text, in: text, replacement)]))
        XCTAssertEqual(substrings(composition.string, composition.removedRanges[0]), ["Two is old.", "Four is old."])
        XCTAssertEqual(substrings(composition.string, composition.replacementRanges[0]), ["Two is new.", "Four is new."])
        XCTAssertEqual(composition.string, "One stays. Two is old. Two is new. Three stays. Four is old. Four is new.")
    }

    /// Sentences merged or split (Cut in Half), or every one changed: the whole-span display, a
    /// whole line stacked on a line of its own — never a sentence paired with another's replacement.
    func testMergedSentencesFallBackToTheWholeSpan() {
        XCTAssertNil(AIReviewComposition.changedSentencePairs(original: "A one. B two. C three.", replacement: "A one. B and C."))
        XCTAssertNil(AIReviewComposition.changedSentencePairs(original: "A one. B two.", replacement: "X one. Y two."),
                     "every sentence changed: a whole replacement")
        let pairs = AIReviewComposition.changedSentencePairs(original: "A one. B two. C three.", replacement: "A one. B 2. C three.")
        XCTAssertEqual(pairs?.count, 1)
        let text = "A one. B two. C three.\n"
        let composition = AIReviewComposition.build(text: text, session: session(text, [change(0, "A one. B two. C three.", in: text, "A one. B and C.")]))
        XCTAssertEqual(substrings(composition.string, composition.removedRanges[0]), ["B two. C three."])
        XCTAssertEqual(composition.string, "A one. B two. C three. B and C.\n")
    }

    /// "More Casual" over list items whose prose is split by a link and a code span: a line with
    /// more than one changed segment is shown WHOLE — struck, then its whole new line stacked below
    /// with the marker repeated — never pieces interleaved around the link (2026-11-14).
    func testLineSplitByLinksAndCodeIsShownWhole() throws {
        let text = """
        - Keep a log of overnight lows; the [frost chart](https://example.com/frost) is a good guide.
        - Water at the `drip-line` in the evening, then mulch.

        """
        let ns = text as NSString
        let segments = MarkdownStructureMap.proseSegments(in: text, selection: NSRange(location: 0, length: ns.length))
        let revisions: [String?] = segments.map { segment in
            switch segment.text {
            case "Keep a log of overnight lows; the": return "Track overnight lows; the"
            case "frost chart": return "local frost chart"
            case "is a good guide.": return "is a handy guide."
            case "in the evening, then mulch.": return "each evening, then mulch."
            default: return segment.text
            }
        }
        let change = try XCTUnwrap(AIChangeBuilder.change(segments: segments, revisions: revisions, in: text))
        let review = AIReviewSession(action: .moreCasual, changes: [change], selectionRange: NSRange(location: 0, length: ns.length),
                                     originalSelection: text)
        let composition = AIReviewComposition.build(text: text, session: review)
        XCTAssertEqual(substrings(composition.string, composition.removedRanges[0]),
                       ["Keep a log of overnight lows; the [frost chart](https://example.com/frost) is a good guide.",
                        "in the evening, then mulch."])
        XCTAssertEqual(substrings(composition.string, composition.replacementRanges[0]),
                       ["Track overnight lows; the [local frost chart](https://example.com/frost) is a handy guide.",
                        "each evening, then mulch."])
        XCTAssertTrue(composition.string.hasPrefix(
            "- Keep a log of overnight lows; the [frost chart](https://example.com/frost) is a good guide.\n- Track overnight lows; the [local frost chart](https://example.com/frost) is a handy guide.\n"),
            composition.string)
        XCTAssertTrue(composition.string.contains("- Water at the `drip-line` in the evening, then mulch. each evening, then mulch."),
                      "one changed segment on a line stays inline")
    }

    func testStaleRangesAreSkippedNotCrashed() {
        let text = "short"
        let stale = AIChange(id: 0, range: NSRange(location: 40, length: 3), original: "big", replacement: "large")
        let composition = AIReviewComposition.build(text: text, session: session(text, [stale]))
        XCTAssertEqual(composition.string, text)
        XCTAssertTrue(composition.removedRanges.isEmpty)
        XCTAssertTrue(composition.replacementRanges.isEmpty)
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
        let text = "a big day and a good night, one two three\nA whole line.\nEnd."
        let review = session(text, [
            change(0, "big", in: text, "considerably larger"),
            change(1, "good", in: text, "fine"),
            AIChange(id: 2, range: NSRange(location: 30, length: 0), original: "", replacement: " (inserted)"),
            change(3, " three", in: text, ""),
            change(4, "A whole line.", in: text, "A rewritten line."),
        ])
        assertRoundTrip(text, review)
    }

    func testTextAddedByAChangeMapsToTheChangesEnd() {
        let text = "a big day"
        let composition = AIReviewComposition.build(text: text, session: session(text, [change(0, "big", in: text, "large")]))
        // "a big large day": the separator and replacement (5…10) are not in the document.
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
        review.reject(0)
        XCTAssertNotEqual(cache.composition(text: text, session: review), AIReviewComposition.empty)
        XCTAssertEqual(cache.buildCount, 2, "a new session state rebuilds")
        _ = cache.composition(text: text + " ", session: review)
        XCTAssertEqual(cache.buildCount, 3, "new text rebuilds")
        XCTAssertEqual(first, AIReviewComposition.build(text: text, session: session(text, [change(0, "big", in: text, "large"), change(1, "good", in: text, "fine")])))
    }
}

import XCTest
@testable import Lineform

@MainActor
final class AIActionControllerTests: XCTestCase {
    private var factoryCalls = 0
    private var suiteName = ""

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func makeStore(connected: Bool = true) -> AIConnectionStore {
        suiteName = "AIActionControllerTests.\(UUID().uuidString)"
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, keychain: InMemoryAIKeychain())
        if connected { XCTAssertNil(store.connect(.claude, key: "test-key-not-real")) }
        return store
    }

    private func make(_ text: String, _ behavior: FakeAIClient.Behavior, connected: Bool = true,
                      history: DocumentHistoryController? = nil)
        -> (AIActionController, FakeAIEditorSurface, FakeAIClient) {
        let fake = FakeAIClient(behavior)
        let controller = AIActionController(connectionStore: makeStore(connected: connected)) { [unowned self] _ in
            self.factoryCalls += 1
            return fake
        }
        let surface = FakeAIEditorSurface(text)
        surface.history = history
        controller.editor = surface
        controller.history = history
        return (controller, surface, fake)
    }

    private func whole(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    private func range(of needle: String, in text: String) -> NSRange {
        let found = (text as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "missing \(needle)")
        return found
    }

    private func runToCompletion(_ controller: AIActionController, _ action: AIAction, range: NSRange, text: String) async {
        controller.run(action, range: range, text: text)
        await controller.runTask?.value
    }

    private func session(_ controller: AIActionController, file: StaticString = #filePath, line: UInt = #line) throws -> AIReviewSession {
        guard case .reviewing(let session) = controller.state else {
            XCTFail("expected a review, got \(controller.state)", file: file, line: line)
            throw XCTSkip("no review")
        }
        return session
    }

    private func signature(_ text: String) -> [String] {
        MarkdownStructureMap.signature(of: text as NSString, scope: whole(text))
    }

    private func crlfCount(_ text: String) -> Int {
        (text as NSString).components(separatedBy: "\r\n").count - 1
    }

    private func replace(_ words: [String: String]) -> FakeAIClient.Behavior {
        FakeAIClient.revising { _, segment in
            var result = segment
            for (old, new) in words { result = result.replacingOccurrences(of: old, with: new) }
            return result
        }
    }

    // MARK: - Availability and requests

    func testNoRequestWhenDisconnected() async {
        let text = "The big dog ran far away."
        let (controller, surface, fake) = make(text, .reply("{}"), connected: false)
        XCTAssertFalse(controller.isAvailable(for: whole(text), text: text))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertTrue(fake.prompts.isEmpty)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(surface.editCalls.isEmpty)
    }

    func testAvailabilityNeedsASelectionWithProse() {
        let text = "Prose here.\n\n```\ncode only\n```\n"
        let (controller, _, _) = make(text, .reply("{}"))
        XCTAssertTrue(controller.isAvailable(for: range(of: "Prose", in: text), text: text))
        XCTAssertFalse(controller.isAvailable(for: NSRange(location: 2, length: 0), text: text))
        XCTAssertFalse(controller.isAvailable(for: range(of: "code only", in: text), text: text))
    }

    func testRunProducesReviewWithOneChange() async throws {
        let text = "The big dog ran far away from home."
        let (controller, surface, fake) = make(text, replace(["big": "large", "far": "near", "home": "here"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        let review = try session(controller)
        XCTAssertEqual(review.changes.map(\.original), [text], "the whole selection is one decision")
        XCTAssertEqual(review.changes.map(\.replacement), ["The large dog ran near away from here."])
        XCTAssertEqual(review.originalSelection, text)
        XCTAssertEqual(surface.string, text, "nothing reaches the document before it is accepted")
        XCTAssertTrue(surface.editCalls.isEmpty)
        XCTAssertEqual(fake.prompts.count, 1)
        XCTAssertEqual(FakeAIClient.segments(in: fake.prompts[0]), [text])
        XCTAssertEqual(surface.announcements.last, "1 change suggested")
        XCTAssertFalse(controller.isAvailable(for: whole(text), text: text), "one action at a time")
    }

    /// Proofread too: several word fixes in the selection are ONE change, accepted in one call.
    func testProofreadIsAlsoOneChange() async throws {
        let text = "It works. It works."
        let (controller, surface, _) = make(text, replace(["works": "runs"]))
        await runToCompletion(controller, .proofread, range: whole(text), text: text)
        XCTAssertEqual(try session(controller).changes.count, 1)
        XCTAssertEqual(surface.announcements.last, "1 change suggested")
        controller.handle(.accept(0))
        XCTAssertEqual(surface.string, "It runs. It runs.")
        XCTAssertEqual(surface.editCalls.count, 1)
        XCTAssertEqual(surface.editCalls.first?.actionName, "Accept Suggestion")
        XCTAssertEqual(controller.state, .idle, "the one decision ends the review")
    }

    /// A selection across list items is one change, applied as one call with one edit per item:
    /// the markers and line endings between them are never touched.
    func testMultiSegmentSelectionAcceptsAsOneCall() async throws {
        let text = "- alpha one\r\n- beta two\r\n"
        let (controller, surface, _) = make(text, replace(["one": "1", "two": "2"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        let review = try session(controller)
        XCTAssertEqual(review.changes.map(\.replacement), ["alpha 1\r\n- beta 2"])
        controller.handle(.acceptCurrent)
        XCTAssertEqual(surface.editCalls.count, 1)
        XCTAssertEqual(surface.editCalls.first?.edits.count, 2)
        XCTAssertFalse(surface.editCalls.first?.edits.contains { $0.replacement.contains("\n") } ?? true)
        XCTAssertEqual(surface.editCalls.first?.actionName, "Accept Suggestion")
        XCTAssertEqual(surface.string, "- alpha 1\r\n- beta 2\r\n")
        XCTAssertEqual(crlfCount(surface.string), 2)
        XCTAssertEqual(controller.state, .idle)
    }

    func testAcceptIsOneEditCall() async throws {
        let text = "The big dog ran far away from home."
        let (controller, surface, _) = make(text, replace(["big": "large", "far": "near", "home": "here"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        controller.handle(.acceptCurrent)
        XCTAssertEqual(surface.editCalls.count, 1)
        XCTAssertEqual(surface.editCalls.first?.edits.count, 1)
        XCTAssertEqual(surface.editCalls.first?.actionName, "Accept Suggestion", "named by decisions, not edits")
        XCTAssertEqual(surface.string, "The large dog ran near away from here.")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.announcements.last, "Review ended")
    }

    func testEscapeEndsReviewLeavingTextUnchanged() async throws {
        let text = "The big dog ran far away from home."
        let (controller, surface, _) = make(text, replace(["big": "large"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        _ = try session(controller)
        controller.handle(.end)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.string, text)
        XCTAssertTrue(surface.editCalls.isEmpty)
        XCTAssertEqual(surface.announcements.last, "Review ended")
    }

    /// Esc is an explicit reject-and-end: the pending change is marked rejected (nothing applied),
    /// and History records nothing because nothing was accepted.
    func testEscapeRejectsThePendingChangeAndRecordsNoHistory() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let (controller, surface, _) = make(historyDoc, replace(["big": "large"]), history: history)
        await runToCompletion(controller, .rewrite, range: range(of: "The big dog", in: historyDoc), text: historyDoc)
        let open = try session(controller)
        XCTAssertEqual(open.pending.count, 1)
        let ended = try XCTUnwrap(controller.endReview())
        XCTAssertEqual(ended.decisions, [0: .rejected], "Esc rejects the change explicitly")
        XCTAssertFalse(ended.acceptedAny)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.string, historyDoc)
        XCTAssertTrue(surface.editCalls.isEmpty)
        XCTAssertFalse(history.hasHistory)
    }

    func testTypingEndsReviewThenTypes() async throws {
        let text = "The big dog ran far away from home."
        let (controller, surface, _) = make(text, replace(["big": "large"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        controller.handle(.typed("x"))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.typed, ["x"])
        XCTAssertTrue(surface.editCalls.isEmpty)
    }

    // MARK: - History

    private let historyDoc = "Intro stays put.\n\nThe big dog ran far away from home.\n\nOutro stays too."

    private func versions(_ history: DocumentHistoryController, text: String) throws -> [HistorySidebarRow] {
        XCTAssertTrue(history.enterHistoryMode(text: text))
        let id = try XCTUnwrap(history.display?.passages.first?.id)
        XCTAssertEqual(history.display?.passages.count, 1)
        _ = history.handle(.select(id), text: text)
        let rows = history.sidebarModel.versions
        _ = history.handle(.exit, text: text)
        return rows
    }

    func testOneActionRecordsOneHistoryPassage() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let (controller, surface, _) = make(historyDoc, replace(["big": "large", "far": "near", "home": "here"]), history: history)
        let paragraph = range(of: "The big dog ran far away from home.", in: historyDoc)
        await runToCompletion(controller, .rewrite, range: paragraph, text: historyDoc)
        XCTAssertFalse(history.hasHistory, "History records once, when the review ends")
        controller.handle(.accept(0))
        XCTAssertEqual(controller.state, .idle)
        let accepted = "The large dog ran near away from here."
        XCTAssertEqual(surface.string, "Intro stays put.\n\n\(accepted)\n\nOutro stays too.")
        XCTAssertTrue(history.hasHistory)
        let rows = try versions(history, text: surface.string)
        XCTAssertEqual(rows.map(\.text), ["The big dog ran far away from home.", accepted])
        XCTAssertEqual(rows.map(\.author), [.you, .ai])
    }

    /// The accept that gives a document its FIRST History shows it (the editor opens the sidebar
    /// focused on the passage); later accepts in the same document don't switch the sidebar. A
    /// document with no History yet is shown again — the rule is per document, not once ever.
    func testFirstAcceptInADocumentShowsHistory() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        var requested: [UUID] = []
        var shownText: () -> String = { "" }
        // As the editor does: the request shows History on the passage.
        history.onRequestShowHistory = { id in
            requested.append(id)
            history.showPassage(id, text: shownText())
        }
        let (controller, surface, _) = make(historyDoc, replace(["big": "large", "stays": "remains"]), history: history)
        shownText = { surface.string }
        let sentence = range(of: "The big dog ran far away from home.", in: historyDoc)

        await runToCompletion(controller, .rewrite, range: sentence, text: historyDoc)
        controller.handle(.acceptCurrent)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(requested.count, 1, "the document's first History shows")
        XCTAssertTrue(history.isHistoryModeActive)
        XCTAssertEqual(history.display?.selectedID, requested.first)
        history.exitHistoryMode()
        XCTAssertTrue(history.hasHistory)

        // The same document already has History: a later accept leaves the sidebar alone.
        let later = surface.string
        await runToCompletion(controller, .rewrite, range: range(of: "Intro stays put.", in: later), text: later)
        controller.handle(.acceptCurrent)
        XCTAssertEqual(requested.count, 1)
        XCTAssertFalse(history.isHistoryModeActive)

        // Another document with no History: its first accept shows again.
        let other = "Fresh stays here.\n\nThe big cat sat.\n"
        history.open(url: nil, text: other)
        surface.string = other
        await runToCompletion(controller, .rewrite, range: range(of: "The big cat sat.", in: other), text: other)
        controller.handle(.acceptCurrent)
        XCTAssertEqual(requested.count, 2)
    }

    /// Ruling: an accepted change whose selection spans several paragraphs records one passage
    /// per CHANGED paragraph (original + accepted). An unchanged paragraph records nothing.
    func testMultiParagraphAcceptRecordsOnePassagePerChangedParagraph() async throws {
        let doc = "Intro stays put.\n\nThe big dog ran.\n\nNothing here moves.\n\nA cat sat far away.\n\nOutro stays too."
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: doc)
        let (controller, surface, _) = make(doc, replace(["big": "large", "far": "near"]), history: history)
        let start = range(of: "The big dog", in: doc).location
        let end = NSMaxRange(range(of: "far away.", in: doc))
        await runToCompletion(controller, .rewrite, range: NSRange(location: start, length: end - start), text: doc)
        XCTAssertEqual(try session(controller).changes.count, 1, "one decision across paragraphs")
        controller.handle(.acceptCurrent)
        XCTAssertEqual(controller.state, .idle)
        let text = surface.string
        XCTAssertEqual(text, "Intro stays put.\n\nThe large dog ran.\n\nNothing here moves.\n\nA cat sat near away.\n\nOutro stays too.")
        XCTAssertTrue(history.hasHistory)

        XCTAssertTrue(history.enterHistoryMode(text: text))
        let passages = try XCTUnwrap(history.display?.passages)
        XCTAssertEqual(passages.map(\.range), [range(of: "The large dog ran.", in: text), range(of: "A cat sat near away.", in: text)])
        var rows: [[String]] = []
        for passage in passages {
            _ = history.handle(.select(passage.id), text: text)
            rows.append(history.sidebarModel.versions.map(\.text))
            XCTAssertEqual(history.sidebarModel.versions.map(\.author), [.you, .ai])
        }
        _ = history.handle(.exit, text: text)
        XCTAssertEqual(rows, [["The big dog ran.", "The large dog ran."], ["A cat sat far away.", "A cat sat near away."]])
    }

    /// Plan follow-up: is there an input where EVERY revision is admitted on its own block, yet
    /// the composed document fails `verify`? After the every-`*_~`-is-structure ruling, none is
    /// known: blocks are bounded by blank lines a revision cannot create or remove (an empty
    /// revision is refused), the structure punctuation sequence is fixed per segment, reference
    /// definitions are whole-line structure (so the document's labels cannot change), and the
    /// constructs that cross blank lines (fences, math, front matter, multi-line HTML) are
    /// protected and start the block's analysis window early. This seeded search pins that: any
    /// admitted subset, composed as the controller composes it, verifies. The controller's
    /// composed `verify` stays as the backstop for a hole this search did not find.
    func testAdmittedRevisionsAlwaysComposeToVerifiedStructure() {
        let blocks = [
            "Intro line with words.", "# A heading here", "Title line\n===", "Setext two\n---",
            "- item one\n- item two\n\n  continued para", "1. first\n2. second", "> quoted text\nlazy line",
            "[note]: https://example.com/a", "See [note] and [other] here.", "A | B\n--- | ---\nc | d",
            "Text <!-- open\n\nstill comment -->\nafter it", "```\ncode\n\nmore code\n```\nprose after",
            "$$\nx+y\n\n$$\nprose", "Some `code` and $m$ and **bold** text.", "    indented code",
            "<div title=\"a\"\nb=\"c\">html</div>", "Para one\n\n---\n\nPara two", "Footnote[^1] here.\n\n[^1]: The note text.",
        ]
        let inserts = ["- ", "1. ", "===", "---", ": http://x.y", "www.example.com", " ", "+", "=", "(", ")", ":",
                       "!", "\"", "'", "2)", "a@b.co", "http://z.q", ".", "-", "0", "x"]
        var rng = SplitMix64(seed: 0xA17E57)
        var admittedCount = 0
        for iteration in 0..<400 {
            var parts: [String] = []
            for _ in 0..<Int.random(in: 2...5, using: &rng) { parts.append(blocks.randomElement(using: &rng)!) }
            let doc = (iteration % 3 == 0 ? "---\ntitle: x\n---\n" : "") + parts.joined(separator: "\n\n") + "\n"
            let segments = MarkdownStructureMap.proseSegments(in: doc, selection: NSRange(location: 0, length: (doc as NSString).length))
            guard !segments.isEmpty else { continue }
            let revisions = segments.map { segment -> String in
                let ns = segment.text as NSString
                let at = ns.rangeOfComposedCharacterSequence(at: Int.random(in: 0..<ns.length, using: &rng)).location
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: return inserts.randomElement(using: &rng)! + segment.text
                case 1: return segment.text + inserts.randomElement(using: &rng)!
                case 2: return ns.replacingCharacters(in: NSRange(location: at, length: 0), with: inserts.randomElement(using: &rng)!)
                default: return segment.text.uppercased()
                }
            }
            let admitted = MarkdownStructureGuard.admissibleRevisions(revisions, for: segments, in: doc)
            admittedCount += admitted.compactMap { $0 }.count
            let change = AIChangeBuilder.change(segments: segments, revisions: admitted, in: doc)
            let composed = AIActionController.applying(change?.edits() ?? [], to: doc)
            XCTAssertTrue(MarkdownStructureGuard.verify(original: doc, revised: composed),
                          "iteration \(iteration)\n\(doc)\n→\n\(composed)")
        }
        XCTAssertGreaterThan(admittedCount, 400, "the search must exercise admitted revisions, not only refusals")
    }

    func testNothingAcceptedRecordsNoHistory() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let (controller, surface, _) = make(historyDoc, replace(["big": "large", "far": "near"]), history: history)
        await runToCompletion(controller, .rewrite, range: range(of: "The big dog", in: historyDoc), text: historyDoc)
        controller.handle(.reject(0))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(history.hasHistory)
        XCTAssertEqual(surface.string, historyDoc)
    }

    func testNotAvailableInsideWordPassageOrHistoryMode() {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        _ = history.handle(.add(range(of: "far", in: historyDoc)), text: historyDoc)
        let (controller, _, _) = make(historyDoc, .reply("{}"), history: history)
        XCTAssertFalse(controller.isAvailable(for: range(of: "far", in: historyDoc), text: historyDoc))
        XCTAssertFalse(controller.isAvailable(for: range(of: "a", in: "far").shifted(by: range(of: "far", in: historyDoc).location), text: historyDoc))
        XCTAssertTrue(controller.isAvailable(for: range(of: "Intro stays", in: historyDoc), text: historyDoc))
        XCTAssertTrue(controller.isAvailable(for: range(of: "The big dog ran far away", in: historyDoc), text: historyDoc),
                      "a selection containing the word passage is not inside it")
        XCTAssertTrue(history.enterHistoryMode(text: historyDoc))
        XCTAssertFalse(controller.isAvailable(for: range(of: "Intro stays", in: historyDoc), text: historyDoc))
        controller.run(.rewrite, range: range(of: "Intro stays", in: historyDoc), text: historyDoc)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(factoryCalls, 0)
    }

    // MARK: - Stale replies, cancel, reload

    func testResponseDiscardedWhenTextChangedWhileRunning() async {
        let text = "The big dog ran far away from home."
        let (controller, surface, _) = make(text, replace(["big": "large"]))
        controller.run(.rewrite, range: whole(text), text: text)
        surface.string = text + " More."
        await controller.runTask?.value
        XCTAssertEqual(controller.state, .message("The text changed while Lineform was waiting. Nothing was changed."))
        XCTAssertTrue(surface.editCalls.isEmpty)
        XCTAssertEqual(surface.string, text + " More.")
    }

    func testRenormalizedTextCountsAsChanged() async {
        let text = "The cafe\u{301} was big."
        let (controller, surface, _) = make(text, replace(["big": "large"]))
        controller.run(.rewrite, range: whole(text), text: text)
        surface.string = "The caf\u{E9} was big."  // canonically equal, different UTF-16
        await controller.runTask?.value
        XCTAssertEqual(controller.state, .message("The text changed while Lineform was waiting. Nothing was changed."))
        XCTAssertTrue(surface.editCalls.isEmpty)
    }

    func testCancelStopsTheRequest() async {
        let text = "The big dog ran far away from home."
        let (controller, surface, fake) = make(text, .suspend)
        controller.run(.trim, range: whole(text), text: text)
        guard case .running(.trim, .claude) = controller.state else { return XCTFail("\(controller.state)") }
        let task = controller.runTask
        while fake.prompts.isEmpty { await Task.yield() }
        controller.cancel()
        XCTAssertEqual(controller.state, .idle)
        await task?.value
        XCTAssertTrue(fake.observedCancellation)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(surface.editCalls.isEmpty)
    }

    func testClientErrorBecomesMessage() async {
        let text = "The big dog ran far away from home."
        let (controller, _, _) = make(text, .fail(.rateLimited))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        XCTAssertEqual(controller.state, .message(AIClientError.rateLimited.message))
        controller.dismissMessage()
        XCTAssertEqual(controller.state, .idle)

        let (garbled, garbledSurface, _) = make(text, .reply("not json"))
        await runToCompletion(garbled, .rewrite, range: whole(text), text: text)
        XCTAssertEqual(garbled.state, .message(AIClientError.unusableResponse.message))
        XCTAssertEqual(garbledSurface.announcements.last, AIClientError.unusableResponse.message)

        let (unchanged, unchangedSurface, _) = make(text, replace([:]))
        await runToCompletion(unchanged, .proofread, range: whole(text), text: text)
        XCTAssertEqual(unchanged.state, .message("No changes suggested."))
        XCTAssertEqual(unchangedSurface.string, text)
    }

    /// Rewrite, Trim, Cut in half and Another Word exist to change the text: an identical reply is
    /// the AI failing, never "No changes suggested" (which stays Proofread's legitimate answer).
    func testIdenticalReplyToAChangingActionSaysTheAIReturnedTheSameText() async {
        let text = "The big dog ran far away from home."
        let word = range(of: "big", in: text)
        for (action, selection) in [(AIAction.rewrite, whole(text)), (.trim, whole(text)),
                                    (.cutInHalf, whole(text)), (.anotherWord, word)] {
            // An identical reply, and one that differs only in edge whitespace.
            for behavior in [replace([:]), FakeAIClient.revising { _, segment in " \(segment) " }] {
                let (controller, surface, _) = make(text, behavior)
                await runToCompletion(controller, action, range: selection, text: text)
                XCTAssertEqual(controller.state, .message("Claude returned the same text. Try again."), "\(action)")
                XCTAssertEqual(surface.announcements.last, "Claude returned the same text. Try again.")
                XCTAssertEqual(surface.string, text)
            }
        }
        XCTAssertEqual(AIActionController.unchangedMessage(for: .rewrite, provider: .other,
                                                           segments: [], revisions: []),
                       "Your AI returned the same text. Try again.")
        XCTAssertEqual(AIActionController.unchangedMessage(for: .proofread, provider: .chatGPT,
                                                           segments: [], revisions: []),
                       "No changes suggested.")
    }

    /// Another Word flows through the same one-change review as Rewrite: the word is struck,
    /// its replacement offered, Return accepts it.
    func testAnotherWordIsOneReviewedChange() async throws {
        let text = "The big dog ran far away from home."
        let word = range(of: "big", in: text)
        let (controller, surface, fake) = make(text, replace(["big": "large"]))
        await runToCompletion(controller, .anotherWord, range: word, text: text)
        XCTAssertEqual(FakeAIClient.segments(in: try XCTUnwrap(fake.prompts.first)), ["big"])
        let review = try session(controller)
        XCTAssertEqual(review.action, .anotherWord)
        XCTAssertEqual(review.changes.map(\.replacement), ["large"])
        controller.handle(.acceptCurrent)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.string, "The large dog ran far away from home.")
    }

    func testAbandonOnReloadAppliesNothingAndRecordsNoHistory() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let (controller, surface, _) = make(historyDoc, replace(["big": "large", "far": "near"]), history: history)
        await runToCompletion(controller, .rewrite, range: range(of: "The big dog ran far away from home.", in: historyDoc), text: historyDoc)
        _ = try session(controller)
        controller.abandon()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(surface.editCalls.isEmpty, "abandon applies nothing")
        XCTAssertFalse(history.hasHistory, "reload wins: nothing is recorded")
        controller.handle(.acceptCurrent)
        XCTAssertTrue(surface.editCalls.isEmpty)

        // Abandon while running cancels the request.
        let (running, runningSurface, fake) = make(historyDoc, .suspend)
        running.run(.rewrite, range: whole(historyDoc), text: historyDoc)
        let task = running.runTask
        while fake.prompts.isEmpty { await Task.yield() }
        running.abandon()
        await task?.value
        XCTAssertTrue(fake.observedCancellation)
        XCTAssertEqual(running.state, .idle)
        XCTAssertTrue(runningSurface.editCalls.isEmpty)
    }

    // MARK: - Mark

    func testMarkHighlightsWithoutChangingText() async {
        let text = "- First sentence is short. Second one is a very long sentence indeed.\n\nThird."
        let (controller, surface, fake) = make(text, .reply("{\"sentences\": [1]}"))
        await runToCompletion(controller, .markLong, range: whole(text), text: text)
        XCTAssertEqual(controller.state, .marking([range(of: "First sentence is short.", in: text)]),
                       "a mark covers the sentence's prose, never its list marker")
        XCTAssertEqual(surface.string, text)
        XCTAssertTrue(surface.editCalls.isEmpty)
        let user = fake.prompts.first?.user ?? ""
        XCTAssertTrue(user.contains("\"sentences\":[\"First sentence is short.\""), user)
        controller.dismissMarks()
        XCTAssertEqual(controller.state, .idle)

        let (empty, emptySurface, _) = make(text, .reply("{\"sentences\": []}"))
        await runToCompletion(empty, .markWeakest, range: whole(text), text: text)
        XCTAssertEqual(empty.state, .message("Nothing to mark."))
        XCTAssertEqual(emptySurface.string, text)
    }

    /// Showing History (Add to History, the first-accept intro) ends Mark: History never opens
    /// under Mark's wash. A message (the review-ended intro's) is left up.
    func testYieldingToHistoryDismissesMarksButKeepsAMessage() async {
        let text = "- First sentence is short. Second one is a very long sentence indeed.\n\nThird."
        let (controller, surface, _) = make(text, .reply("{\"sentences\": [1]}"))
        await runToCompletion(controller, .markLong, range: whole(text), text: text)
        guard case .marking = controller.state else { return XCTFail("\(controller.state)") }
        controller.yieldToHistory()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.string, text)

        let (empty, emptySurface, _) = make(text, .reply("{\"sentences\": []}"))
        await runToCompletion(empty, .markWeakest, range: whole(text), text: text)
        XCTAssertEqual(empty.state, .message("Nothing to mark."))
        empty.yieldToHistory()
        XCTAssertEqual(empty.state, .message("Nothing to mark."))
        XCTAssertEqual(emptySurface.string, text)
    }

    // MARK: - Limits

    func testOversizedSelectionIsRefusedWithoutARequest() async {
        let long = String(repeating: "word ", count: 5_000) + "end."
        let (controller, surface, fake) = make(long, .reply("{}"))
        await runToCompletion(controller, .rewrite, range: whole(long), text: long)
        XCTAssertEqual(controller.state, .message("Select less text — about 4,000 words at most."))
        XCTAssertTrue(fake.prompts.isEmpty)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertTrue(surface.editCalls.isEmpty)

        let many = Array(repeating: "Line.", count: AILimits.maxSegments + 1).joined(separator: "\n\n")
        let (manyController, _, manyFake) = make(many, .reply("{}"))
        await runToCompletion(manyController, .markLong, range: whole(many), text: many)
        XCTAssertEqual(manyController.state, .message("Select less text — about 4,000 words at most."))
        XCTAssertTrue(manyFake.prompts.isEmpty)
    }

    // MARK: - Structure

    /// Every construct the structure map protects, in a BOM + CRLF document.
    private static let fixture: String = {
        let lf = """
        ---
        title: Notes
        ---
        # The quick heading

        Some plain prose with a [link text](https://example.com) and ![alt](img.png) and `code span` here.

        - First item is here.
          - Nested item is there.
        - [ ] Task item to do.
        - [x] Done task item.

        | Name | Value |
        | --- | --- |
        | alpha cell | beta cell |

        ```swift
        let x = 1
        ```

        ```mermaid
        graph TD
        A-->B
        ```

        Inline math $a+b$ and \\(c+d\\) sit in prose.

        $$
        x^2
        $$

        \\[
        y^2
        \\]

        > [!NOTE]
        > A callout line of prose.

        Final paragraph of plain prose.
        """
        return "\u{FEFF}" + lf.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
    }()

    nonisolated private static let mangles = ["**", "#", "\n", "|", "`", "\\*", "[x](y)"]

    nonisolated private static func mangle(_ index: Int, _ segment: String) -> String {
        let insert = mangles[index % mangles.count]
        let ns = segment as NSString
        let middle = ns.rangeOfComposedCharacterSequence(at: ns.length / 2).location
        return ns.replacingCharacters(in: NSRange(location: middle, length: 0), with: insert) + " better"
    }

    private func assertStructureSurvives(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let original = Self.fixture
        XCTAssertEqual(signature(text), signature(original), file: file, line: line)
        XCTAssertEqual(crlfCount(text), crlfCount(original), file: file, line: line)
        XCTAssertEqual(text.unicodeScalars.first, "\u{FEFF}", file: file, line: line)
        XCTAssertFalse(text.unicodeScalars.dropFirst().contains("\u{FEFF}"), file: file, line: line)
    }

    func testMangledStructureNeverReachesTheDocument() async throws {
        let text = Self.fixture
        // Every segment mangled: nothing is admitted, nothing can be accepted.
        let (controller, surface, fake) = make(text, FakeAIClient.revising { Self.mangle($0, $1) })
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        XCTAssertGreaterThan(FakeAIClient.segments(in: try XCTUnwrap(fake.prompts.first)).count, 10)
        // Rewrite never says "No changes suggested": every revision was refused, so the reply was
        // unusable (it was not the same text).
        XCTAssertEqual(controller.state, .message(AIClientError.unusableResponse.message))
        controller.handle(.acceptCurrent)
        XCTAssertTrue(surface.editCalls.isEmpty)
        XCTAssertEqual(surface.string, text)
        assertStructureSurvives(surface.string)

        // Half mangled, half honest: only the honest ones reach the document.
        let (mixed, mixedSurface, _) = make(text, FakeAIClient.revising { index, segment in
            index.isMultiple(of: 2) ? Self.mangle(index / 2, segment) : segment + " indeed"
        })
        await runToCompletion(mixed, .rewrite, range: whole(text), text: text)
        let review = try session(mixed)
        XCTAssertEqual(review.changes.count, 1)
        let parts = review.changes.flatMap(\.parts)
        XCTAssertFalse(parts.isEmpty)
        XCTAssertTrue(parts.allSatisfy { part in
            !Self.mangles.contains { part.replacement.contains($0) }
        }, "\(parts)")
        mixed.handle(.acceptCurrent)
        XCTAssertEqual(mixedSurface.editCalls.count, 1)
        XCTAssertNotEqual(mixedSurface.string, text)
        assertStructureSurvives(mixedSurface.string)
    }

    func testHonestEditsApplyAndKeepStructure() async throws {
        let text = Self.fixture
        let (controller, surface, _) = make(text, replace(["prose": "writing", "item": "entry", "cell": "box", "quick": "swift"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        let review = try session(controller)
        XCTAssertEqual(review.changes.count, 1, "the whole selection is one decision")
        XCTAssertGreaterThan(review.changes[0].parts.count, 5)
        controller.handle(.acceptCurrent)
        XCTAssertNotEqual(surface.string, text)
        XCTAssertTrue(surface.string.contains("Final paragraph of plain writing."))
        XCTAssertTrue(surface.string.contains("let x = 1"), "code is never sent")
        assertStructureSurvives(surface.string)
    }

    /// The whole change is verified, never a subset: `$5` → `5$` is a token move that word-level
    /// hunks once split in two (one half alone re-pairing `$` into math). As one change it is
    /// offered and accepted whole, and the structure survives.
    func testAStructureMoveIsOneVerifiedChange() async throws {
        let text = "Price $5 or more today."
        let (controller, surface, _) = make(text, replace(["$5": "5$"]))
        await runToCompletion(controller, .proofread, range: whole(text), text: text)
        XCTAssertEqual(try session(controller).changes.count, 1)
        controller.handle(.accept(0))
        XCTAssertEqual(surface.string, "Price 5$ or more today.")
        XCTAssertEqual(signature(surface.string), signature(text))
        XCTAssertFalse(surface.announcements.contains(AIActionController.structureRefusedMessage))
    }

    /// The accept-time verify still runs against the CURRENT text. A refusal must be SEEN, not
    /// only announced: a refused accept is the only decision, so it becomes the controller's
    /// message. (The review is read-only, so the text cannot really change under it; the fake
    /// surface's text is changed here to reach the guard.)
    func testRefusedDecisionLeavesAVisibleNotice() async throws {
        let text = "Price 55 or more today."
        let shifted = "Price *5 or more today.*"   // the change's range now covers one `*` of a pair

        let (single, singleSurface, _) = make(text, replace(["more": "less"]))
        await runToCompletion(single, .proofread, range: whole(text), text: text)
        singleSurface.string = shifted
        single.handle(.accept(0))
        XCTAssertTrue(singleSurface.editCalls.isEmpty)
        XCTAssertEqual(single.state, .message(AIActionController.structureRefusedMessage))
        XCTAssertNil(single.reviewNotice)
    }

    // MARK: - Final-review fixes

    /// Critical: the reviewed passage stays selected in the editor under the overlay. EVERY way
    /// out of `.reviewing` must collapse that selection to the passage's (shifted) end, or the
    /// next keystroke replaces the whole passage.
    func testEveryWayOutOfAReviewCollapsesTheSelectionToThePassageEnd() async throws {
        let doc = "Intro.\n\nThe big dog ran far away from home.\n\nOutro."
        let passage = range(of: "The big dog ran far away from home.", in: doc)
        let words = ["big": "large", "far": "near", "home": "here"]

        // Esc (End Review): nothing accepted, the end is where it was.
        let (esc, escSurface, _) = make(doc, replace(words))
        await runToCompletion(esc, .rewrite, range: passage, text: doc)
        XCTAssertEqual(escSurface.collapsedSelections, [], "nothing collapses while the review is up")
        esc.handle(.end)
        XCTAssertEqual(escSurface.collapsedSelections, [NSMaxRange(passage)])

        // The one decision: accepting it ends the review at the accepted text's end; rejecting
        // it at the passage's.
        let (pill, pillSurface, _) = make(doc, replace(words))
        await runToCompletion(pill, .rewrite, range: passage, text: doc)
        pill.handle(.accept(0))
        XCTAssertEqual(pillSurface.collapsedSelections,
                       [NSMaxRange(range(of: "The large dog ran near away from here.", in: pillSurface.string))])
        let (rejected, rejectedSurface, _) = make(doc, replace(words))
        await runToCompletion(rejected, .rewrite, range: passage, text: doc)
        rejected.handle(.reject(0))
        XCTAssertEqual(rejectedSurface.collapsedSelections, [NSMaxRange(passage)])

        // A typed key: collapsed BEFORE the key is typed.
        let (typed, typedSurface, _) = make(doc, replace(words))
        await runToCompletion(typed, .rewrite, range: passage, text: doc)
        typed.handle(.typed("x"))
        XCTAssertEqual(typedSurface.collapsedSelections, [NSMaxRange(passage)])
        XCTAssertEqual(typedSurface.typed, ["x"])

        // Abandon (reload) and a document swap's endReview + abandon.
        let (gone, goneSurface, _) = make(doc, replace(words))
        await runToCompletion(gone, .rewrite, range: passage, text: doc)
        gone.abandon()
        XCTAssertEqual(goneSurface.collapsedSelections, [NSMaxRange(passage)])
        let (swap, swapSurface, _) = make(doc, replace(words))
        await runToCompletion(swap, .rewrite, range: passage, text: doc)
        swap.endReview()
        swap.abandon()
        XCTAssertEqual(swapSurface.collapsedSelections, [NSMaxRange(passage)], "once, as the review leaves")
    }

    /// Minor 4: an edit the editor skips ends the review at once, records nothing, and says so —
    /// it never goes on with ranges that no longer describe the text. A multi-segment change is
    /// one call of several edits, so part of it can land: the caret then goes to the passage's
    /// REAL end.
    func testASkippedEditEndsTheReviewRecordingNothing() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let passage = range(of: "The big dog ran far away from home.", in: historyDoc)

        let (single, singleSurface, _) = make(historyDoc, replace(["big": "large", "far": "near"]), history: history)
        await runToCompletion(single, .rewrite, range: passage, text: historyDoc)
        singleSurface.skippedEditIndices = [0]
        single.handle(.accept(0))
        XCTAssertEqual(single.state, .message(AIActionController.editSkippedMessage))
        XCTAssertEqual(singleSurface.announcements.last, AIActionController.editSkippedMessage)
        XCTAssertEqual(singleSurface.collapsedSelections.last, NSMaxRange(passage))
        XCTAssertEqual(singleSurface.string, historyDoc)
        XCTAssertFalse(history.hasHistory)
        single.handle(.accept(0))
        XCTAssertEqual(singleSurface.editCalls.count, 1, "no later decision aims at shifted text")

        // Two paragraphs, one decision, two edits (descending): the second paragraph's lands,
        // the first's is skipped.
        let start = passage.location
        let selection = NSRange(location: start, length: NSMaxRange(range(of: "Outro stays too.", in: historyDoc)) - start)
        for command in [AIReviewCommand.accept(0), .acceptCurrent] {
            let (multi, multiSurface, _) = make(historyDoc, replace(["big": "large", "too": "also"]), history: history)
            await runToCompletion(multi, .rewrite, range: selection, text: historyDoc)
            multiSurface.skippedEditIndices = [1]
            multi.handle(command)
            XCTAssertEqual(multi.state, .message(AIActionController.editSkippedMessage), "\(command)")
            XCTAssertEqual(multiSurface.string, historyDoc.replacingOccurrences(of: "too.", with: "also."))
            XCTAssertEqual(multiSurface.collapsedSelections.last, (multiSurface.string as NSString).length, "\(command)")
            XCTAssertFalse(history.hasHistory)
        }
    }

    /// Minor 5: Disconnect cancels a request in flight and abandons a review it produced.
    func testDisconnectCancelsTheRequestAndAbandonsTheReview() async throws {
        let text = "The big dog ran far away from home."
        suiteName = "AIActionControllerTests.\(UUID().uuidString)"
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, keychain: InMemoryAIKeychain())
        XCTAssertNil(store.connect(.claude, key: "test-key-not-real"))
        let suspended = FakeAIClient(.suspend)
        let running = AIActionController(connectionStore: store) { _ in suspended }
        let runningSurface = FakeAIEditorSurface(text)
        running.editor = runningSurface
        running.run(.rewrite, range: whole(text), text: text)
        let task = running.runTask
        while suspended.prompts.isEmpty { await Task.yield() }
        store.disconnect()
        XCTAssertEqual(running.state, .idle)
        await task?.value
        XCTAssertTrue(suspended.observedCancellation)
        XCTAssertEqual(running.state, .idle, "the cancelled reply is ignored")

        XCTAssertNil(store.connect(.claude, key: "test-key-not-real"))
        let replying = FakeAIClient(replace(["big": "large"]))
        let reviewing = AIActionController(connectionStore: store) { _ in replying }
        let surface = FakeAIEditorSurface(text)
        reviewing.editor = surface
        await runToCompletion(reviewing, .rewrite, range: whole(text), text: text)
        _ = try session(reviewing)
        XCTAssertNil(store.connect(.claude, key: "another-test-key"), "the same provider, a new key")
        _ = try session(reviewing)
        XCTAssertNil(store.connect(.chatGPT, key: "test-key-not-real"))
        XCTAssertEqual(reviewing.state, .idle, "another provider: the review leaves")
        XCTAssertEqual(surface.string, text)
        XCTAssertTrue(surface.editCalls.isEmpty)
    }

    /// Hand-test fix 1: the change is current the moment the review opens, so Return accepts it
    /// without an arrow press.
    func testReturnAcceptsTheChangeWithNoArrowPress() async throws {
        let text = "The big dog ran far away from home."
        let (controller, surface, _) = make(text, replace(["big": "large", "far": "near", "home": "here"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        XCTAssertEqual(try session(controller).currentID, 0)
        controller.handle(.acceptCurrent)
        XCTAssertEqual(surface.string, "The large dog ran near away from here.")
        XCTAssertEqual(controller.state, .idle)
    }

    /// Hand-test fixes 2 and 3: Mark collapses the selection (it drew over the wash), and every
    /// collapse lands at the passage's TEXT end — before the line ending a triple-click includes.
    func testMarkCollapsesTheSelectionBeforeATrailingLineEnding() async {
        for ending in ["\n", "\r\n"] {
            let text = "First is short. Second one is a much longer sentence.\(ending)Next line."
            let line = NSRange(location: 0, length: NSMaxRange(range(of: ending + "Next", in: text)) - 4)
            XCTAssertTrue((text as NSString).substring(with: line).hasSuffix(ending))
            let (controller, surface, _) = make(text, .reply("{\"sentences\": [2]}"))
            await runToCompletion(controller, .markLong, range: line, text: text)
            guard case .marking = controller.state else { return XCTFail("\(controller.state)") }
            XCTAssertEqual(surface.collapsedSelections, [NSMaxRange(range(of: "sentence.", in: text))], ending.debugDescription)
        }
    }

    func testCaretEndExcludesTrailingLineEndings() {
        XCTAssertEqual(AIActionController.caretEnd(of: NSRange(location: 0, length: 4), in: "abc\ndef"), 3)
        XCTAssertEqual(AIActionController.caretEnd(of: NSRange(location: 0, length: 5), in: "abc\r\ndef"), 3)
        XCTAssertEqual(AIActionController.caretEnd(of: NSRange(location: 0, length: 5), in: "abc\n\ndef"), 3)
        XCTAssertEqual(AIActionController.caretEnd(of: NSRange(location: 0, length: 3), in: "abc\ndef"), 3)
        XCTAssertEqual(AIActionController.caretEnd(of: NSRange(location: 3, length: 1), in: "abc\ndef"), 3)
        XCTAssertEqual(AIActionController.caretEnd(of: NSRange(location: 0, length: 99), in: "abc\n"), 3)
    }

    /// Important 2: Mark sends only the sentences the selection touches — never the rest of the
    /// line — and a partly selected sentence goes whole.
    func testMarkSendsOnlyTheSentencesTheSelectionTouches() async {
        let text = "Alpha is first. Beta is second. Gamma is third."
        let selection = NSRange(location: range(of: "is second", in: text).location, length: 4)
        let (controller, surface, fake) = make(text, .reply("{\"sentences\": [1]}"))
        await runToCompletion(controller, .markLong, range: selection, text: text)
        XCTAssertEqual(controller.state, .marking([range(of: "Beta is second.", in: text)]))
        XCTAssertEqual(surface.string, text)
        let user = fake.prompts.first?.user ?? ""
        XCTAssertTrue(user.contains("\"sentences\":[\"Beta is second.\"]"), user)
        XCTAssertFalse(user.contains("Alpha") || user.contains("Gamma"), user)
    }
}

private extension NSRange {
    func shifted(by offset: Int) -> NSRange { NSRange(location: location + offset, length: length) }
}

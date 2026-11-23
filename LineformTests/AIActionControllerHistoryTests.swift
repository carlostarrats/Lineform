import XCTest
@testable import Lineform
@testable import LineformCore

/// The AI controller against the Mac's real History (`DocumentHistoryController`, through
/// `AIHistoryRecording`). The controller's own behaviour is covered in the package
/// (`AIActionControllerTests`, `AIHistoryRecordingTests`).
@MainActor
final class AIActionControllerHistoryTests: XCTestCase {
    private var factoryCalls = 0
    private var suiteName = ""

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func makeStore(connected: Bool = true) -> AIConnectionStore {
        suiteName = "AIActionControllerHistoryTests.\(UUID().uuidString)"
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
        surface.onApplyEdit = { [weak history] edit in history?.noteUserEdit(edit.range, replacement: edit.replacement) }
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

    /// Read tears the Write editor down before the review ends: the accepted decisions go into
    /// the document through the fallback — applied once, recorded in History — never lost.
    func testAcceptedDecisionsSurviveTheEditorGoingAway() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        let text = "Teh cat and teh dog."
        history.open(url: nil, text: text)
        var document = text
        var surface: FakeAIEditorSurface?
        let controller: AIActionController
        do {
            let made = make(text, replace(["teh": "the", "Teh": "The"]), history: history)
            controller = made.0
            surface = made.1
        }
        await runToCompletion(controller, .proofread, range: whole(text), text: text)
        XCTAssertNotNil(surface)
        controller.handle(.acceptCurrent)
        surface = nil   // the editor is gone (weak), as after the switch to Read
        XCTAssertNil(controller.editor)
        var applied = 0
        controller.documentFallback = (text: { document }, apply: { edits in
            applied += 1
            for edit in edits { history.noteUserEdit(edit.range, replacement: edit.replacement) }
            document = AIActionController.applying(edits, to: document)
        })
        controller.endReview()
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(document, "The cat and teh dog.")
        let recorded = try XCTUnwrap(history.rememberedPassageID)
        XCTAssertEqual(history.passage(recorded)?.versions.map(\.text), ["Teh cat and teh dog.", "The cat and teh dog."])
    }

    /// Accept All accepts every remaining correction; all accepted corrections are ONE undo step
    /// and ONE History version of the passage.
    func testProofreadAcceptAllIsOneUndoAndOneHistoryRecord() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        let text = "Intro.\n\nTeh cat and teh dog.\n"
        history.open(url: nil, text: text)
        let (controller, surface, _) = make(text, replace(["teh": "the", "Teh": "The"]), history: history)
        await runToCompletion(controller, .proofread, range: range(of: "Teh cat and teh dog.", in: text), text: text)
        controller.handle(.acceptAll)
        XCTAssertEqual(surface.string, "Intro.\n\nThe cat and the dog.\n")
        XCTAssertEqual(surface.editCalls.count, 1)
        let recorded = try XCTUnwrap(history.rememberedPassageID)
        XCTAssertEqual(history.passage(recorded)?.versions.map(\.text), ["Teh cat and teh dog.", "The cat and the dog."])
        XCTAssertEqual(try versions(history, text: surface.string).count, 2)
    }

    /// Rejecting every correction applies and records nothing.
    func testProofreadRejectingEverythingRecordsNothing() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        let text = "Teh cat and teh dog."
        history.open(url: nil, text: text)
        let (controller, surface, _) = make(text, replace(["teh": "the", "Teh": "The"]), history: history)
        await runToCompletion(controller, .proofread, range: whole(text), text: text)
        controller.handle(.rejectCurrent)
        controller.handle(.rejectCurrent)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(surface.editCalls.isEmpty)
        XCTAssertFalse(history.hasHistory)
    }

    /// Esc is an explicit reject-and-end: the pending change is marked rejected (nothing applied),
    /// and History records nothing because nothing was accepted.
    func testEscapeRejectsThePendingChangeAndRecordsNoHistory() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let (controller, surface, _) = make(historyDoc, replace(["big": "large"]), history: history)
        await runToCompletion(controller, .rephrase, range: range(of: "The big dog", in: historyDoc), text: historyDoc)
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
        await runToCompletion(controller, .rephrase, range: paragraph, text: historyDoc)
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

    // MARK: - History around an AI action (2026-11-13)

    /// A document with History on "The big dog…" (one accepted change), History mode focused on
    /// that passage, then — as when an action starts in History — the context is captured and
    /// History mode ends. Returns the controller and the passage id.
    private func historyInContext(requested: @escaping (UUID) -> Void) throws -> (DocumentHistoryController, UUID, String) {
        let text = "Intro stays put.\n\nThe large dog ran far away from home.\n\nOutro stays too."
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: text)
        let passage = try XCTUnwrap(history.recordAccepted(range: range(of: "The large dog ran far away from home.", in: text),
                                                           original: "The big dog ran far away from home.",
                                                           accepted: "The large dog ran far away from home.", text: text))
        XCTAssertTrue(history.showPassage(passage, text: text))
        history.aiActionWillStart()
        XCTAssertFalse(history.isHistoryModeActive, "History and AI never overlap")
        history.onRequestShowHistory = requested
        return (history, passage, text)
    }

    /// History was on when the action started: every way the action ends brings History back on
    /// the passage selected before it — reject (Esc, ✕), cancel, a same-text message, an error.
    func testHistoryReturnsToTheSelectedPassageWhenTheActionEnds() async throws {
        let ends: [(String, FakeAIClient.Behavior, (AIActionController) -> Void)] = [
            ("reject", replace(["Intro": "Opening"]), { $0.handle(.end) }),
            ("same text", replace([:]), { _ in }),
            ("error", .fail(.rateLimited), { _ in }),
        ]
        for (name, behavior, end) in ends {
            var requested: [UUID] = []
            let (history, passage, text) = try historyInContext { requested.append($0) }
            let (controller, surface, _) = make(text, behavior, history: history)
            await runToCompletion(controller, .rephrase, range: range(of: "Intro stays put.", in: text), text: text)
            end(controller)
            withExtendedLifetime(surface) {}
            XCTAssertEqual(requested, [passage], name)
        }

        var requested: [UUID] = []
        let (history, passage, text) = try historyInContext { requested.append($0) }
        let (controller, surface, _) = make(text, .suspend, history: history)
        controller.run(.rephrase, range: range(of: "Intro stays put.", in: text), text: text)
        controller.cancel()
        withExtendedLifetime(surface) {}
        XCTAssertEqual(requested, [passage], "cancel")
    }

    /// History was on, and the change was accepted: History comes back on the passage the accept
    /// recorded, not the one selected before.
    func testHistoryReturnsToTheAcceptedPassage() async throws {
        var requested: [UUID] = []
        let (history, passage, text) = try historyInContext { requested.append($0) }
        let (controller, surface, _) = make(text, replace(["Intro": "Opening"]), history: history)
        await runToCompletion(controller, .rephrase, range: range(of: "Intro stays put.", in: text), text: text)
        controller.handle(.acceptCurrent)
        XCTAssertEqual(requested.count, 1)
        XCTAssertNotEqual(requested.first, passage)
        let recorded = try XCTUnwrap(requested.first)
        XCTAssertTrue(history.showPassage(recorded, text: surface.string))
        XCTAssertEqual(history.display?.selectedID, recorded)
    }

    /// Try Again keeps the context (History comes back once, at the real end); typing and History
    /// opening on its own target drop it.
    func testRetryKeepsTheHistoryContextAndTypingDropsIt() async throws {
        var requested: [UUID] = []
        let (history, passage, text) = try historyInContext { requested.append($0) }
        let (controller, surface, _) = make(text, replace(["Intro": "Opening"]), history: history)
        await runToCompletion(controller, .rephrase, range: range(of: "Intro stays put.", in: text), text: text)
        controller.handle(.retry)
        await controller.runTask?.value
        XCTAssertEqual(requested, [], "the action is not over")
        controller.handle(.end)
        XCTAssertEqual(requested, [passage])
        withExtendedLifetime(surface) {}

        var typedRequests: [UUID] = []
        let (typedHistory, _, typedText) = try historyInContext { typedRequests.append($0) }
        let (typing, _, _) = make(typedText, replace(["Intro": "Opening"]), history: typedHistory)
        await runToCompletion(typing, .rephrase, range: range(of: "Intro stays put.", in: typedText), text: typedText)
        typing.handle(.typed("x"))
        XCTAssertEqual(typedRequests, [])

        var yieldRequests: [UUID] = []
        let (yieldHistory, _, yieldText) = try historyInContext { yieldRequests.append($0) }
        let (yielding, _, _) = make(yieldText, replace(["Intro": "Opening"]), history: yieldHistory)
        await runToCompletion(yielding, .rephrase, range: range(of: "Intro stays put.", in: yieldText), text: yieldText)
        yielding.yieldToHistory()
        yielding.handle(.end)
        XCTAssertEqual(yieldRequests, [])
    }

    /// History was off: an accept's passage is remembered for the next plain History entry; a
    /// reject remembers nothing.
    func testAcceptOutsideHistoryRemembersItsPassage() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        history.recordAccepted(range: range(of: "Outro stays too.", in: historyDoc), original: "Outro stays.",
                               accepted: "Outro stays too.", text: historyDoc)
        let (controller, surface, _) = make(historyDoc, replace(["big": "large"]), history: history)
        let sentence = range(of: "The big dog ran far away from home.", in: historyDoc)

        await runToCompletion(controller, .rephrase, range: sentence, text: historyDoc)
        controller.handle(.end)
        XCTAssertNil(history.rememberedPassageID, "a reject records and remembers nothing")

        await runToCompletion(controller, .rephrase, range: sentence, text: historyDoc)
        controller.handle(.acceptCurrent)
        let remembered = try XCTUnwrap(history.rememberedPassageID)
        XCTAssertFalse(history.isHistoryModeActive)
        XCTAssertTrue(history.enterHistoryModeFromTab(text: surface.string))
        XCTAssertEqual(history.display?.selectedID, remembered)
        XCTAssertNil(history.rememberedPassageID, "spent")
    }


    /// Editing is not History: an accept never opens History by itself (2026-11-13), not even a
    /// document's first. Its passage is remembered for the writer's own next History-tab click.
    func testAcceptNeverOpensHistory() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        var requested: [UUID] = []
        history.onRequestShowHistory = { requested.append($0) }
        let (controller, surface, _) = make(historyDoc, replace(["big": "large"]), history: history)
        await runToCompletion(controller, .rephrase, range: range(of: "The big dog ran far away from home.", in: historyDoc),
                              text: historyDoc)
        controller.handle(.acceptCurrent)
        XCTAssertEqual(requested, [])
        XCTAssertFalse(history.isHistoryModeActive)
        XCTAssertTrue(history.hasHistory)
        let remembered = try XCTUnwrap(history.rememberedPassageID)
        XCTAssertTrue(history.enterHistoryModeFromTab(text: surface.string))
        XCTAssertEqual(history.display?.selectedID, remembered)
    }

    /// A selection partly over a passage is widened to take it in, so the request carries the
    /// whole passage and the accept never straddles (and drops) it.
    func testPartialOverlapIsWidenedToThePassage() async throws {
        let text = "Intro.\n\nThe quick brown fox jumps over it.\n\nOutro."
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: text)
        let word = try XCTUnwrap(history.recordAccepted(range: range(of: "quick brown", in: text), original: "fast brown",
                                                        accepted: "quick brown", text: text))
        let (controller, surface, fake) = make(text, replace(["fox": "cat"]), history: history)
        XCTAssertTrue(controller.isAvailable(for: range(of: "brown fox", in: text), text: text))
        await runToCompletion(controller, .rephrase, range: range(of: "brown fox", in: text), text: text)
        XCTAssertEqual(FakeAIClient.segments(in: try XCTUnwrap(fake.prompts.first)), ["quick brown fox"])
        controller.handle(.acceptCurrent)
        XCTAssertEqual(surface.string, "Intro.\n\nThe quick brown cat jumps over it.\n\nOutro.")
        let kept = try XCTUnwrap(history.passage(word))
        XCTAssertEqual(kept.versions.map(\.text), ["fast brown", "quick brown"], "the word passage keeps its versions")
    }

    /// Changing one word of a line already rewritten: offered, applied, and recorded as a child of
    /// the line (a word inside a sentence passage); the line keeps its versions.
    func testWordInsideARewrittenLineNestsUnderIt() async throws {
        let text = "Intro.\n\nThe quick brown fox jumps over it.\n\nOutro."
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: text)
        let line = try XCTUnwrap(history.recordAccepted(range: range(of: "The quick brown fox jumps over it.", in: text),
                                                        original: "The fast brown fox jumps over it.",
                                                        accepted: "The quick brown fox jumps over it.", text: text))
        let (controller, surface, _) = make(text, replace(["jumps": "leaps"]), history: history)
        XCTAssertTrue(controller.isAvailable(for: range(of: "jumps", in: text), text: text))
        await runToCompletion(controller, .anotherWord, range: range(of: "jumps", in: text), text: text)
        controller.handle(.acceptCurrent)
        let word = try XCTUnwrap(history.rememberedPassageID)
        XCTAssertNotEqual(word, line)
        let child = try XCTUnwrap(history.passage(word))
        XCTAssertEqual(child.parentID, line)
        XCTAssertEqual(child.versions.map(\.text), ["jumps", "leaps"])
        XCTAssertEqual(try XCTUnwrap(history.passage(line)).versions.count, 2)
        XCTAssertTrue(surface.string.contains("leaps"))
    }

    /// Rewriting a sentence that contains a word passage keeps the word's versions, filed under
    /// the sentence's original version.
    func testRewritingAroundAPassageKeepsIt() async throws {
        let text = "Intro.\n\nThe quick brown fox jumps over it.\n\nOutro."
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: text)
        let word = try XCTUnwrap(history.recordAccepted(range: range(of: "quick", in: text), original: "fast",
                                                        accepted: "quick", text: text))
        let (controller, surface, _) = make(text, FakeAIClient.revising { _, _ in "A swift fox leaps over it." }, history: history)
        await runToCompletion(controller, .rephrase, range: range(of: "The quick brown fox jumps over it.", in: text), text: text)
        _ = try session(controller)
        controller.handle(.acceptCurrent)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.string, "Intro.\n\nA swift fox leaps over it.\n\nOutro.")
        let sentence = try XCTUnwrap(history.rememberedPassageID)
        let kept = try XCTUnwrap(history.passage(word))
        XCTAssertEqual(kept.versions.map(\.text), ["fast", "quick"])
        XCTAssertEqual(kept.parentID, sentence)
        XCTAssertEqual(kept.parentVersionIndex, 0)
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
        await runToCompletion(controller, .rephrase, range: NSRange(location: start, length: end - start), text: doc)
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

    func testNothingAcceptedRecordsNoHistory() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let (controller, surface, _) = make(historyDoc, replace(["big": "large", "far": "near"]), history: history)
        await runToCompletion(controller, .rephrase, range: range(of: "The big dog", in: historyDoc), text: historyDoc)
        controller.handle(.reject(0))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(history.hasHistory)
        XCTAssertEqual(surface.string, historyDoc)
    }

    /// Before 2026-11-13 a word passage refused AI on itself and inside itself; now only History
    /// mode refuses it.
    func testAvailableInsideWordPassageButNotInHistoryMode() {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        _ = history.handle(.add(range(of: "far", in: historyDoc)), text: historyDoc)
        let (controller, _, _) = make(historyDoc, .reply("{}"), history: history)
        XCTAssertTrue(controller.isAvailable(for: range(of: "far", in: historyDoc), text: historyDoc))
        XCTAssertTrue(controller.isAvailable(for: range(of: "a", in: "far").shifted(by: range(of: "far", in: historyDoc).location), text: historyDoc))
        XCTAssertTrue(controller.isAvailable(for: range(of: "Intro stays", in: historyDoc), text: historyDoc))
        XCTAssertTrue(controller.isAvailable(for: range(of: "The big dog ran far away", in: historyDoc), text: historyDoc),
                      "a selection containing the word passage is not inside it")
        XCTAssertTrue(history.enterHistoryMode(text: historyDoc))
        XCTAssertFalse(controller.isAvailable(for: range(of: "Intro stays", in: historyDoc), text: historyDoc))
        controller.run(.rephrase, range: range(of: "Intro stays", in: historyDoc), text: historyDoc)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(factoryCalls, 0)
    }

    // MARK: - Stale replies, cancel, reload

    func testAbandonOnReloadAppliesNothingAndRecordsNoHistory() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let (controller, surface, _) = make(historyDoc, replace(["big": "large", "far": "near"]), history: history)
        await runToCompletion(controller, .rephrase, range: range(of: "The big dog ran far away from home.", in: historyDoc), text: historyDoc)
        _ = try session(controller)
        controller.abandon()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(surface.editCalls.isEmpty, "abandon applies nothing")
        XCTAssertFalse(history.hasHistory, "reload wins: nothing is recorded")
        controller.handle(.acceptCurrent)
        XCTAssertTrue(surface.editCalls.isEmpty)

        // Abandon while running cancels the request.
        let (running, runningSurface, fake) = make(historyDoc, .suspend)
        running.run(.rephrase, range: whole(historyDoc), text: historyDoc)
        let task = running.runTask
        while fake.prompts.isEmpty { await Task.yield() }
        running.abandon()
        await task?.value
        XCTAssertTrue(fake.observedCancellation)
        XCTAssertEqual(running.state, .idle)
        XCTAssertTrue(runningSurface.editCalls.isEmpty)
    }

    // MARK: - Mark

    // MARK: - Limits

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

    // MARK: - Final-review fixes

    /// Minor 4: an edit the editor skips ends the review at once, records nothing, and says so —
    /// it never goes on with ranges that no longer describe the text. A multi-segment change is
    /// one call of several edits, so part of it can land: the caret then goes to the passage's
    /// REAL end.
    func testASkippedEditEndsTheReviewRecordingNothing() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let passage = range(of: "The big dog ran far away from home.", in: historyDoc)

        let (single, singleSurface, _) = make(historyDoc, replace(["big": "large", "far": "near"]), history: history)
        await runToCompletion(single, .rephrase, range: passage, text: historyDoc)
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
            await runToCompletion(multi, .rephrase, range: selection, text: historyDoc)
            multiSurface.skippedEditIndices = [1]
            multi.handle(command)
            XCTAssertEqual(multi.state, .message(AIActionController.editSkippedMessage), "\(command)")
            XCTAssertEqual(multiSurface.string, historyDoc.replacingOccurrences(of: "too.", with: "also."))
            XCTAssertEqual(multiSurface.collapsedSelections.last, (multiSurface.string as NSString).length, "\(command)")
            XCTAssertFalse(history.hasHistory)
        }
    }
}

private extension NSRange {
    func shifted(by offset: Int) -> NSRange { NSRange(location: location + offset, length: length) }

}

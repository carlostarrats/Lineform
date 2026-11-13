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

    func testRunProducesReviewWithChanges() async throws {
        let text = "The big dog ran far away from home."
        let (controller, surface, fake) = make(text, replace(["big": "large", "far": "near", "home": "here"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        let review = try session(controller)
        XCTAssertEqual(review.changes.map(\.original), ["big", "far", "home"])
        XCTAssertEqual(review.changes.map(\.replacement), ["large", "near", "here"])
        XCTAssertEqual(review.originalSelection, text)
        XCTAssertEqual(surface.string, text, "nothing reaches the document before it is accepted")
        XCTAssertTrue(surface.editCalls.isEmpty)
        XCTAssertEqual(fake.prompts.count, 1)
        XCTAssertEqual(FakeAIClient.segments(in: fake.prompts[0]), [text])
        XCTAssertEqual(surface.announcements.last, "3 changes suggested")
        XCTAssertFalse(controller.isAvailable(for: whole(text), text: text), "one action at a time")
    }

    func testAcceptingOneOfTwoIdenticalChangesEditsOnlyThatOne() async throws {
        let text = "It works. It works."
        let (controller, surface, _) = make(text, replace(["works": "runs"]))
        await runToCompletion(controller, .proofread, range: whole(text), text: text)
        XCTAssertEqual(try session(controller).changes.count, 2)
        controller.handle(.accept(1))
        XCTAssertEqual(surface.string, "It works. It runs.")
        XCTAssertEqual(surface.editCalls.count, 1)
        XCTAssertEqual(surface.editCalls.first?.actionName, "Accept Suggestion")
        XCTAssertEqual(surface.announcements.last, "Change 1 of 2")
        controller.handle(.reject(0))
        XCTAssertEqual(controller.state, .idle, "the last decision ends the review")
        XCTAssertEqual(surface.string, "It works. It runs.")
    }

    func testAcceptRemainingIsOneEditCall() async throws {
        let text = "The big dog ran far away from home."
        let (controller, surface, _) = make(text, replace(["big": "large", "far": "near", "home": "here"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        controller.handle(.acceptRemaining)
        XCTAssertEqual(surface.editCalls.count, 1)
        XCTAssertEqual(surface.editCalls.first?.edits.count, 3)
        XCTAssertEqual(surface.editCalls.first?.actionName, "Accept Suggestions")
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

    func testTypingEndsReviewThenTypes() async throws {
        let text = "The big dog ran far away from home."
        let (controller, surface, _) = make(text, replace(["big": "large"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        controller.handle(.typed("x"))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.typed, ["x"])
        XCTAssertTrue(surface.editCalls.isEmpty)
    }

    func testNavigationAndAcceptCurrent() async throws {
        let text = "The big dog ran far away from home."
        let (controller, surface, _) = make(text, replace(["big": "large", "far": "near", "home": "here"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        controller.handle(.next)
        XCTAssertEqual(surface.announcements.last, "Change 2 of 3")
        controller.handle(.acceptCurrent)
        XCTAssertEqual(surface.string, "The big dog ran near away from home.")
        controller.handle(.previous)
        XCTAssertEqual(try session(controller).currentID, 0)
        controller.handle(.rejectRemaining)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.string, "The big dog ran near away from home.")
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
        controller.handle(.accept(0))
        XCTAssertFalse(history.hasHistory, "History records once, when the review ends")
        controller.handle(.reject(1))
        controller.handle(.accept(2))
        XCTAssertEqual(controller.state, .idle)
        let accepted = "The large dog ran far away from here."
        XCTAssertEqual(surface.string, "Intro stays put.\n\n\(accepted)\n\nOutro stays too.")
        XCTAssertTrue(history.hasHistory)
        let rows = try versions(history, text: surface.string)
        XCTAssertEqual(rows.map(\.text), ["The big dog ran far away from home.", accepted])
        XCTAssertEqual(rows.map(\.author), [.you, .ai])
    }

    func testNothingAcceptedRecordsNoHistory() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let (controller, surface, _) = make(historyDoc, replace(["big": "large", "far": "near"]), history: history)
        await runToCompletion(controller, .rewrite, range: range(of: "The big dog", in: historyDoc), text: historyDoc)
        controller.handle(.rejectRemaining)
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

    func testAbandonOnReloadAppliesNothingAndRecordsNoHistory() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        history.open(url: nil, text: historyDoc)
        let (controller, surface, _) = make(historyDoc, replace(["big": "large", "far": "near"]), history: history)
        await runToCompletion(controller, .rewrite, range: range(of: "The big dog ran far away from home.", in: historyDoc), text: historyDoc)
        controller.handle(.accept(0))
        XCTAssertEqual(surface.editCalls.count, 1)
        controller.abandon()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.editCalls.count, 1, "abandon applies nothing")
        XCTAssertFalse(history.hasHistory, "reload wins: nothing is recorded")
        controller.handle(.acceptRemaining)
        XCTAssertEqual(surface.editCalls.count, 1)

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
        XCTAssertEqual(controller.state, .message("No changes suggested."))
        controller.handle(.acceptRemaining)
        XCTAssertTrue(surface.editCalls.isEmpty)
        XCTAssertEqual(surface.string, text)
        assertStructureSurvives(surface.string)

        // Half mangled, half honest: only the honest ones reach the document.
        let (mixed, mixedSurface, _) = make(text, FakeAIClient.revising { index, segment in
            index.isMultiple(of: 2) ? Self.mangle(index / 2, segment) : segment + " indeed"
        })
        await runToCompletion(mixed, .rewrite, range: whole(text), text: text)
        let review = try session(mixed)
        XCTAssertFalse(review.changes.isEmpty)
        XCTAssertTrue(review.changes.allSatisfy { change in
            !Self.mangles.contains { change.replacement.contains($0) }
        }, "\(review.changes)")
        mixed.handle(.acceptRemaining)
        XCTAssertEqual(mixedSurface.editCalls.count, 1)
        XCTAssertNotEqual(mixedSurface.string, text)
        assertStructureSurvives(mixedSurface.string)
    }

    func testHonestEditsApplyAndKeepStructure() async throws {
        let text = Self.fixture
        let (controller, surface, _) = make(text, replace(["prose": "writing", "item": "entry", "cell": "box", "quick": "swift"]))
        await runToCompletion(controller, .rewrite, range: whole(text), text: text)
        let review = try session(controller)
        XCTAssertGreaterThan(review.changes.count, 5)
        controller.handle(.acceptRemaining)
        XCTAssertNotEqual(surface.string, text)
        XCTAssertTrue(surface.string.contains("Final paragraph of plain writing."))
        XCTAssertTrue(surface.string.contains("let x = 1"), "code is never sent")
        assertStructureSurvives(surface.string)
    }

    /// Changes are checked one by one as they are accepted: a single change that would re-pair
    /// `$` into math is refused even though the whole reply kept the structure.
    func testPartialAcceptNeverChangesStructure() async throws {
        let text = "Price $5 or more today."
        var refused = 0
        for id in 0..<2 {
            let (controller, surface, _) = make(text, replace(["$5": "5$"]))
            await runToCompletion(controller, .proofread, range: whole(text), text: text)
            XCTAssertEqual(try session(controller).changes.count, 2, "the whole reply keeps the structure")
            controller.handle(.accept(id))
            XCTAssertEqual(signature(surface.string), signature(text), "change \(id)")
            if surface.announcements.contains(AIActionController.structureRefusedMessage) {
                refused += 1
                XCTAssertTrue(surface.editCalls.isEmpty)
            }
            controller.handle(.end)
        }
        XCTAssertEqual(refused, 1, "exactly one half of the move re-pairs `$` into math")
    }
}

private extension NSRange {
    func shifted(by offset: Int) -> NSRange { NSRange(location: location + offset, length: length) }
}

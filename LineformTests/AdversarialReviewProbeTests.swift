import XCTest
@testable import Lineform

/// An AI client that holds every request until the test releases it (or the task is cancelled), so
/// a test can change the world between request and reply.
final class GatedAIClient: AIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<String?, Never>] = []
    private var cancelledEarly = false
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }
    var waitingCount: Int { lock.withLock { waiters.count } }

    func complete(_ prompt: AIPrompt) async throws -> String {
        lock.withLock { calls += 1; cancelledEarly = false }
        let reply: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if cancelledEarly { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume(returning: nil) }
            }
        } onCancel: {
            let pending = lock.withLock { () -> [CheckedContinuation<String?, Never>] in
                cancelledEarly = true
                let all = waiters
                waiters = []
                return all
            }
            pending.forEach { $0.resume(returning: nil) }
        }
        guard let reply else { throw AIClientError.cancelled }
        return reply
    }

    func release(_ reply: String) {
        let next = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            waiters.isEmpty ? nil : waiters.removeFirst()
        }
        next?.resume(returning: reply)
    }
}

/// Adversarial probes of the AI review pipeline (parser → structure guard → word diff / change
/// builder → controller → session → apply). Written to find what the authors did not expect;
/// probes that exposed a real defect are wrapped in `XCTExpectFailure` with the defect named.
@MainActor
final class AdversarialReviewProbeTests: XCTestCase {
    private var suiteName = ""
    /// The controller holds its editor weakly: every surface is kept alive for the whole test.
    private var retained: [AnyObject] = []

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        retained = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> AIConnectionStore {
        suiteName = "AdversarialReviewProbeTests.\(UUID().uuidString)"
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, keychain: InMemoryAIKeychain())
        XCTAssertNil(store.connect(.claude, key: "test-key-not-real"))
        return store
    }

    private func make(_ text: String, client: AIClient, history: DocumentHistoryController? = nil)
        -> (AIActionController, FakeAIEditorSurface) {
        let controller = AIActionController(connectionStore: makeStore()) { _ in client }
        let surface = FakeAIEditorSurface(text)
        retained.append(surface)
        surface.history = history
        controller.editor = surface
        controller.history = history
        return (controller, surface)
    }

    private func make(_ text: String, _ behavior: FakeAIClient.Behavior, history: DocumentHistoryController? = nil)
        -> (AIActionController, FakeAIEditorSurface) {
        make(text, client: FakeAIClient(behavior), history: history)
    }

    private func whole(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

    private func run(_ controller: AIActionController, _ action: AIAction, _ range: NSRange, _ text: String) async {
        controller.run(action, range: range, text: text)
        await controller.runTask?.value
    }

    private func reviewSession(_ controller: AIActionController) -> AIReviewSession? {
        if case .reviewing(let session) = controller.state { return session }
        return nil
    }

    private func message(_ controller: AIActionController) -> String? {
        if case .message(let text) = controller.state { return text }
        return nil
    }

    private func replyJSON(_ segments: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["segments": segments])
        return String(decoding: data, as: UTF8.self)
    }

    private func replacing(_ pairs: [(String, String)]) -> FakeAIClient.Behavior {
        FakeAIClient.revising { _, segment in
            var result = segment
            for (old, new) in pairs { result = result.replacingOccurrences(of: old, with: new) }
            return result
        }
    }

    private func applyAll(_ changes: [AIChange], to text: String) -> String {
        let edits = changes.flatMap { $0.edits() }.sorted { $0.range.location > $1.range.location }
        return AIActionController.applying(edits, to: text)
    }

    private func segment(_ text: String) -> ProseSegment {
        ProseSegment(range: whole(text), text: text)
    }

    private func waitUntilWaiting(_ client: GatedAIClient, count: Int = 1) async {
        for _ in 0..<2000 where client.waitingCount < count { await Task.yield() }
    }

    // MARK: - 1. Hostile / odd replies through parser, guard and builders

    /// An NFD document (e + U+0301) proofread by a model that answers in NFC changes nothing the
    /// writer can see. The Rewrite builder already treats canonically equal text as unchanged.
    func testRewriteBuilderTreatsNFCReplyForNFDTextAsUnchanged() {
        let nfd = "The cafe\u{301} was open."
        let nfc = "The caf\u{E9} was open."
        XCTAssertNil(AIChangeBuilder.change(segments: [segment(nfd)], revisions: [nfc], in: nfd))
    }

    /// BUG: Proofread's word diff compares tokens by exact UTF-16, so the same NFC/NFD reply makes
    /// a "correction" that replaces "café" with "café" — a suggestion with no visible change.
    func testProofreadWordDiffReportsNoCorrectionForNormalizationOnlyReply() {
        let nfd = "The cafe\u{301} was open."
        let nfc = "The caf\u{E9} was open."
        XCTAssertEqual(AIWordDiff.corrections(segments: [segment(nfd)], revisions: [nfc], in: nfd).count, 0)
    }

    /// The same defect end to end: the writer sees "1 corrections suggested" for text that reads
    /// identically, instead of "No changes suggested."
    func testProofreadOfNFDDocumentWithNFCReplySaysNoChanges() async {
        let nfd = "Le cafe\u{301} e\u{301}tait ferme\u{301}."
        let (controller, _) = make(nfd, FakeAIClient.revising { _, s in s.precomposedStringWithCanonicalMapping })
        await run(controller, .proofread, whole(nfd), nfd)
        XCTAssertEqual(message(controller), AIActionController.noChangesMessage)
    }

    func testSmartQuotesAndEllipsisAreRealCorrectionsThatApplyExactly() {
        let text = "She said \"wait...\" - then left."
        let revised = "She said \u{201C}wait\u{2026}\u{201D} \u{2014} then left."
        let changes = AIWordDiff.corrections(segments: [segment(text)], revisions: [revised], in: text)
        XCTAssertFalse(changes.isEmpty)
        XCTAssertEqual(applyAll(changes, to: text), revised)
        XCTAssertEqual(applyAll([], to: text), text)
    }

    func testReplyWithOnlyTrailingNewlineIsNoChange() async {
        let text = "A clean sentence."
        let (controller, surface) = make(text, .reply(replyJSON([text + "\n"])))
        await run(controller, .proofread, whole(text), text)
        XCTAssertEqual(message(controller), AIActionController.noChangesMessage)
        XCTAssertEqual(surface.string, text)
    }

    func testParserRefusesWrongSegmentCountsAndNonStrings() {
        XCTAssertNil(AIResponseParser.segments(from: #"{"segments":["a"]}"#, expectedCount: 2))
        XCTAssertNil(AIResponseParser.segments(from: #"{"segments":["a","b","c"]}"#, expectedCount: 2))
        XCTAssertNil(AIResponseParser.segments(from: #"{"segments":["a",2]}"#, expectedCount: 2))
        XCTAssertNil(AIResponseParser.segments(from: #"{"segments":["a",null]}"#, expectedCount: 2))
        XCTAssertNil(AIResponseParser.segments(from: "no json at all", expectedCount: 1))
        XCTAssertNil(AIResponseParser.segments(from: "} backwards {", expectedCount: 1))
        // Braces inside a string after the object: last-`}` scanning must not crash.
        XCTAssertNil(AIResponseParser.segments(from: #"{"segments":["a"]} trailing } junk"#, expectedCount: 1))
        XCTAssertEqual(AIResponseParser.segments(from: "Sure!\n```json\n{\"segments\":[\"x\"]}\n```", expectedCount: 1), ["x"])
        XCTAssertNil(AIResponseParser.sentenceIndices(from: #"{"sentences":"1"}"#, sentenceCount: 3))
        XCTAssertEqual(AIResponseParser.sentenceIndices(from: #"{"sentences":[1e308, -1, 1.5, true, 2, 2]}"#, sentenceCount: 3), [1])
    }

    func testEmptySegmentReplyIsRefused() async {
        let text = "Keep this sentence."
        let (controller, surface) = make(text, .reply(replyJSON(["   "])))
        await run(controller, .rephrase, whole(text), text)
        XCTAssertNil(reviewSession(controller))
        XCTAssertEqual(surface.string, text)
    }

    func testMarkdownInjectionIsRefusedEverywhere() async {
        let text = "A plain line of prose here."
        for injected in ["A **plain** line of prose here.", "# A plain line of prose here.", "- A plain line of prose here.",
                         "A `plain` line of prose here.", "A $plain$ line of prose here.", "A plain line of [prose](x) here.",
                         "1. A plain line of prose here.", "> A plain line of prose here.", "A plain line\nof prose here."] {
            for action in [AIAction.proofread, .rephrase] {
                let (controller, surface) = make(text, .reply(replyJSON([injected])))
                await run(controller, action, whole(text), text)
                if let session = reviewSession(controller) {
                    // Whatever was admitted must leave the structure alone when all of it is accepted.
                    var s = session
                    s.acceptAllPending()
                    let result = AIActionController.applying(s.acceptedEdits, to: text)
                    XCTAssertTrue(MarkdownStructureGuard.verify(original: text, revised: result),
                                  "\(action) admitted structure from \(injected.debugDescription): \(result.debugDescription)")
                }
                XCTAssertEqual(surface.string, text)
            }
        }
    }

    func testControlAndFormatCharactersAreRefused() async {
        let text = "Ordinary words in a row."
        for hostile in ["Ordinary words\u{0007} in a row.", "Ordinary words\u{200B} in a row.",
                        "Ordinary \u{202E}words in a row.", "Ordinary words\u{2028}in a row.", "Ordinary words\u{0} in a row."] {
            let (controller, _) = make(text, .reply(replyJSON([hostile])))
            await run(controller, .proofread, whole(text), text)
            XCTAssertNil(reviewSession(controller), "admitted \(hostile.debugDescription)")
        }
    }

    func testEnormousReplyIsRefused() async {
        let text = "Short."
        let (controller, _) = make(text, .reply(replyJSON([String(repeating: "Very long. ", count: 100)])))
        await run(controller, .rephrase, whole(text), text)
        XCTAssertNil(reviewSession(controller))
    }

    /// A link's destination and a code span are structure: the model never sees them, and a reply
    /// can only reach the prose around them.
    func testLinkDestinationAndCodeSpanAreNeverChanged() async throws {
        let text = "See [the guide](https://example.com/a) and run `make all` today."
        let (controller, surface) = make(text, replacing([("guide", "manual"), ("today", "now"), ("example", "evil"), ("make", "rm")]))
        await run(controller, .proofread, whole(text), text)
        var session = try XCTUnwrap(reviewSession(controller))
        session.acceptAllPending()
        let result = AIActionController.applying(session.acceptedEdits, to: text)
        XCTAssertTrue(result.contains("(https://example.com/a)"))
        XCTAssertTrue(result.contains("`make all`"))
        XCTAssertTrue(result.contains("manual"))
        controller.handle(.acceptAll)
        XCTAssertEqual(surface.string, "See [the manual](https://example.com/a) and run `make all` now.")
    }

    /// A token MOVE ("$5" → "5$") diffs into a deletion and an insertion; the controller merges
    /// neighbours a structure check refuses. Whatever survives must apply to exactly the reply.
    func testDollarMoveProofreadsToTheReplyOrNothing() async {
        let text = "It costs $5 now."
        let (controller, surface) = make(text, replacing([("$5", "5$")]))
        await run(controller, .proofread, whole(text), text)
        if let session = reviewSession(controller) {
            var s = session
            s.acceptAllPending()
            XCTAssertEqual(AIActionController.applying(s.acceptedEdits, to: text), "It costs 5$ now.")
            controller.handle(.acceptAll)
            XCTAssertEqual(surface.string, "It costs 5$ now.")
        } else {
            XCTAssertEqual(surface.string, text)
            XCTFail("PROBE: the move was refused outright: \(String(describing: message(controller)))")
        }
    }

    func testNameAndNumberChangesAreSeparateCorrections() async throws {
        let text = "Richard paid $5 to Ann."
        let (controller, _) = make(text, replacing([("Richard", "Rick"), ("Ann", "Anne")]))
        await run(controller, .proofread, whole(text), text)
        let session = try XCTUnwrap(reviewSession(controller))
        XCTAssertEqual(session.changes.map(\.original), ["Richard", "Ann"])
        XCTAssertEqual(session.changes.map(\.replacement), ["Rick", "Anne"])
    }

    func testEmojiZWJSequenceIsReplacedWhole() {
        let text = "Family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} trip."
        let revised = "Family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466} trip."
        let changes = AIWordDiff.corrections(segments: [segment(text)], revisions: [revised], in: text)
        XCTAssertEqual(changes.count, 1)
        let ns = text as NSString
        for change in changes {
            XCTAssertEqual(ns.rangeOfComposedCharacterSequences(for: change.range), change.range)
        }
        XCTAssertEqual(applyAll(changes, to: text), revised)
    }

    func testRTLWordDiff() {
        let arabic = "\u{0647}\u{0630}\u{0627} \u{0646}\u{0635} \u{0642}\u{0635}\u{064A}\u{0631}."
        let revised = "\u{0647}\u{0630}\u{0627} \u{0646}\u{0635} \u{0637}\u{0648}\u{064A}\u{0644}."
        let changes = AIWordDiff.corrections(segments: [segment(arabic)], revisions: [revised], in: arabic)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.original, "\u{0642}\u{0635}\u{064A}\u{0631}")
        XCTAssertEqual(applyAll(changes, to: arabic), revised)
        let hebrew = "\u{05D6}\u{05D4} \u{05D8}\u{05E7}\u{05E1}\u{05D8}."
        let hebrewRevised = "\u{05D6}\u{05D4} \u{05D8}\u{05E7}\u{05E1}\u{05D8} \u{05D7}\u{05D3}\u{05E9}."
        XCTAssertEqual(applyAll(AIWordDiff.corrections(segments: [segment(hebrew)], revisions: [hebrewRevised], in: hebrew), to: hebrew),
                       hebrewRevised)
    }

    /// Japanese has no spaces: the tokenizer joins every letter run, so one fixed particle makes
    /// the whole clause one "correction". Applies exactly; the granularity is the finding.
    func testJapaneseCorrectionIsAsSmallAsTheChange() {
        let text = "私は昨日学校へ行きました。"
        let revised = "私は昨日学校に行きました。"
        let changes = AIWordDiff.corrections(segments: [segment(text)], revisions: [revised], in: text)
        XCTAssertEqual(applyAll(changes, to: text), revised, "applies exactly")
        XCTAssertLessThanOrEqual(changes.first.map { ($0.original as NSString).length } ?? 99, 3)
    }

    func testDecomposedAccentInsideWordNeverSplit() {
        let text = "Resume\u{301} draft."
        let revised = "Re\u{301}sume\u{301} draft."
        let changes = AIWordDiff.corrections(segments: [segment(text)], revisions: [revised], in: text)
        let ns = text as NSString
        for change in changes { XCTAssertEqual(ns.rangeOfComposedCharacterSequences(for: change.range), change.range) }
        XCTAssertEqual(applyAll(changes, to: text), revised)
    }

    // MARK: - 2. Seeded word-diff fuzz

    private static let vocabulary = [
        "the", "cat", "sat", "on", "a", "mat", "don't", "it's", "café", "cafe\u{301}", "naïve", "Zoë",
        "😀", "👍🏽", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "日本語", "は", "東京", "مرحبا", "שלום",
        "$5", "5%", "3.14", "e.g.", "…", "—", "-", "\"", "\u{201C}", "\u{201D}", "(", ")", ",", ".", "!", "?",
        "über", "straße", "ﬁne", "x", "I", "Richard", "Rick", "2024",
    ]
    private static let separators = [" ", " ", " ", "  ", "\t", ", ", "; "]

    private func randomText(_ rng: inout SplitMix64) -> String {
        let count = Int.random(in: 1...14, using: &rng)
        var out = ""
        for i in 0..<count {
            if i > 0 { out += Self.separators.randomElement(using: &rng)! }
            out += Self.vocabulary.randomElement(using: &rng)!
        }
        return out
    }

    private func mutate(_ text: String, _ rng: inout SplitMix64) -> String {
        var tokens = AIWordDiff.tokens(text).map { (text as NSString).substring(with: $0) }
        let mutations = Int.random(in: 1...3, using: &rng)
        for _ in 0..<mutations {
            let kind = Int.random(in: 0..<5, using: &rng)
            let index = tokens.isEmpty ? 0 : Int.random(in: 0..<tokens.count, using: &rng)
            switch kind {
            case 0 where !tokens.isEmpty: tokens[index] = Self.vocabulary.randomElement(using: &rng)!
            case 1: tokens.insert(Self.vocabulary.randomElement(using: &rng)! + " ", at: min(index, tokens.count))
            case 2 where tokens.count > 1: tokens.remove(at: index)
            case 3 where tokens.count > 1 && index + 1 < tokens.count: tokens.swapAt(index, index + 1)
            default: if !tokens.isEmpty { tokens[index] = tokens[index].uppercased() }
            }
        }
        return tokens.joined()
    }

    /// ≥ 500 seeded cases: all corrections give the reply exactly; none give the original; any
    /// subset changes only inside its corrections, on composed-character boundaries.
    func testSeededWordDiffFuzz() {
        var rng = SplitMix64(seed: 0x5EED_0F_D1FF)
        var failures: [String] = []
        for case_ in 0..<800 {
            let original = randomText(&rng)
            let revised = mutate(original, &rng)
            let ns = original as NSString
            let corrections = AIWordDiff.corrections(original: original, revised: revised)
            let changes = corrections.enumerated().map { i, c in
                AIChange(id: i, range: c.range, original: ns.substring(with: c.range), replacement: c.replacement)
            }
            // Ranges ordered, disjoint, in bounds, on composed boundaries.
            var last = -1
            for change in changes {
                if change.range.location < last { failures.append("#\(case_) overlap \(original.debugDescription) → \(revised.debugDescription)") }
                last = NSMaxRange(change.range)
                let aligned = change.range.length > 0
                    ? ns.rangeOfComposedCharacterSequences(for: change.range) == change.range
                    : change.range.location == ns.length || ns.rangeOfComposedCharacterSequence(at: change.range.location).location == change.range.location
                if NSMaxRange(change.range) > ns.length || !aligned {
                    failures.append("#\(case_) bad boundary \(change.range) in \(original.debugDescription)")
                }
            }
            // Canonical equality (2026-11-14): tokens that are canonically equal are no correction,
            // so the writer's own bytes stay there (an NFD "café" against an NFC reply).
            if applyAll(changes, to: original) != revised {
                failures.append("#\(case_) all≠revised: \(original.debugDescription) → \(revised.debugDescription) got \(applyAll(changes, to: original).debugDescription)")
            }
            if !applyAll([], to: original).utf16.elementsEqual(original.utf16) { failures.append("#\(case_) none≠original") }
            // Random subset through the real session ordering.
            if !changes.isEmpty {
                var session = AIReviewSession(action: .proofread, changes: changes, selectionRange: NSRange(location: 0, length: ns.length),
                                              originalSelection: original)
                var expected = NSMutableString(string: original)
                var chosen: [AIChange] = []
                for change in changes where Bool.random(using: &rng) {
                    session.accept(change.id)
                    chosen.append(change)
                }
                for change in chosen.reversed() { expected.replaceCharacters(in: change.range, with: change.replacement) }
                let got = AIActionController.applying(session.acceptedEdits, to: original)
                if !got.utf16.elementsEqual((expected as String).utf16) {
                    failures.append("#\(case_) subset mismatch \(original.debugDescription)")
                }
                // Untouched text outside every chosen correction survives in order.
                var cursor = 0
                var outside = ""
                for change in chosen { outside += ns.substring(with: NSRange(location: cursor, length: change.range.location - cursor)); cursor = NSMaxRange(change.range) }
                outside += ns.substring(from: cursor)
                var remaining = Substring(got)
                for character in outside {
                    guard let found = remaining.firstIndex(of: character) else {
                        failures.append("#\(case_) lost \(character) from \(original.debugDescription)"); break
                    }
                    remaining = remaining[remaining.index(after: found)...]
                }
                expected = NSMutableString()
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.prefix(10).joined(separator: "\n"))
    }

    /// The same fuzz through the CONTROLLER over a Markdown document: any accepted subset either
    /// applies with structure intact, or is refused whole — and an accepted subset of corrections
    /// that each passed the structure guard on their own should apply.
    func testSeededControllerProofreadFuzzKeepsStructure() async {
        var rng = SplitMix64(seed: 0xC0FFEE)
        var violations: [String] = []
        var refusedSubsets: [String] = []
        let templates = [
            "- %@\n- %@\n",
            "> %@\n> %@\n",
            "# %@\n\n%@ with `code here` inside.\n",
            "---\ntitle: Keep\n---\n%@\n\n```\nfenced %@\n```\n",
            "%@ [link text](https://example.com/x_y) %@\r\n\r\n%@\r\n",
            "\u{FEFF}%@\n\n1. %@\n",
            "Some *%@* and _%@_ ~~x~~ here.\n",
        ]
        for case_ in 0..<200 {
            let template = templates[case_ % templates.count]
            var text = template
            while let r = text.range(of: "%@") { text.replaceSubrange(r, with: randomText(&rng)) }
            let seed = rng.next()
            let client = FakeAIClient(.respond { prompt in
                var local = SplitMix64(seed: seed)
                let revised = FakeAIClient.segments(in: prompt).map { s -> String in
                    var tokens = AIWordDiff.tokens(s).map { (s as NSString).substring(with: $0) }
                    if !tokens.isEmpty {
                        let i = Int.random(in: 0..<tokens.count, using: &local)
                        tokens[i] = ["the", "dog", "café", "$", "*", "_", "5", "…", "Zoë"].randomElement(using: &local)!
                    }
                    return tokens.joined()
                }
                let data = try! JSONSerialization.data(withJSONObject: ["segments": revised])
                return String(decoding: data, as: UTF8.self)
            })
            let (controller, surface) = make(text, client: client)
            await run(controller, .proofread, whole(text), text)
            guard let session = reviewSession(controller) else { continue }
            var accepted: [AIChange] = []
            for change in session.changes where Bool.random(using: &rng) {
                controller.handle(.accept(change.id))
                accepted.append(change)
            }
            if reviewSession(controller) != nil { controller.handle(.end) }
            let result = surface.string
            if !MarkdownStructureGuard.verify(original: text, revised: result) {
                violations.append("#\(case_) structure changed:\n\(text.debugDescription)\n→ \(result.debugDescription)")
            }
            if !accepted.isEmpty, result == text, message(controller) == AIActionController.structureRefusedMessage {
                refusedSubsets.append("#\(case_) \(text.debugDescription) accepted \(accepted.map { "\($0.original)→\($0.replacement)" })")
            }
            // Fenced code and front matter are verbatim.
            for keep in ["title: Keep", "`code here`", "(https://example.com/x_y)", "```\nfenced"] where text.contains(keep) {
                if !result.contains(keep) { violations.append("#\(case_) lost \(keep): \(text.debugDescription) → \(result.debugDescription)") }
            }
            if text.components(separatedBy: "~~").count != result.components(separatedBy: "~~").count {
                violations.append("#\(case_) strikethrough delimiters changed")
            }
            // Fenced code bodies are verbatim.
            if let open = text.range(of: "```\n"), let close = text.range(of: "\n```", range: open.upperBound..<text.endIndex) {
                let body = String(text[open.upperBound..<close.lowerBound])
                if !result.contains(body) { violations.append("#\(case_) fenced code changed: \(body.debugDescription)") }
            }
            if text.hasPrefix("\u{FEFF}"), !result.hasPrefix("\u{FEFF}") { violations.append("#\(case_) lost BOM") }
            if text.components(separatedBy: "\r\n").count != result.components(separatedBy: "\r\n").count {
                violations.append("#\(case_) CRLF count changed")
            }
        }
        XCTAssertTrue(violations.isEmpty, violations.prefix(5).joined(separator: "\n"))
        // Accepting corrections that were each offered as safe, and having the whole review
        // refused, loses every decision the writer made.
        XCTAssertTrue(refusedSubsets.isEmpty, "individually-safe corrections refused together:\n" + refusedSubsets.prefix(5).joined(separator: "\n"))
    }

    // MARK: - 3. Document coordinates

    private func proofreadAcceptAll(_ text: String, selection: NSRange, _ pairs: [(String, String)]) async -> (String, AIActionController) {
        let (controller, surface) = make(text, replacing(pairs))
        await run(controller, .proofread, selection, text)
        if reviewSession(controller) != nil { controller.handle(.acceptAll) }
        return (surface.string, controller)
    }

    func testCRLFDocumentKeepsEveryCRLF() async {
        let text = "First teh line.\r\nSecond teh line.\r\n\r\n- teh item\r\n"
        let (result, _) = await proofreadAcceptAll(text, selection: whole(text), [("teh", "the")])
        XCTAssertEqual(result, "First the line.\r\nSecond the line.\r\n\r\n- the item\r\n")
    }

    func testBOMDocumentSelectionFromZero() async {
        let text = "\u{FEFF}Teh start of it."
        let (result, _) = await proofreadAcceptAll(text, selection: whole(text), [("Teh", "The")])
        XCTAssertEqual(result, "\u{FEFF}The start of it.")
    }

    func testSelectionStartingMidEmojiAndMidWord() async {
        let text = "Go 👍🏽 teh way home."
        let ns = text as NSString
        let emoji = ns.range(of: "👍🏽")
        // Starts on the skin-tone modifier, ends mid-"home".
        let selection = NSRange(location: emoji.location + 2, length: ns.range(of: "hom").location + 2 - (emoji.location + 2))
        let (result, _) = await proofreadAcceptAll(text, selection: selection, [("teh", "the")])
        XCTAssertEqual(result, "Go 👍🏽 the way home.")
    }

    func testListBlockquoteFrontMatterAndFenceBoundaries() async {
        let text = "---\nteh: teh\n---\n> teh quote\n- [ ] teh task\n\n```\nteh code\n```\nteh after `teh` [teh](teh.md)\n"
        let (result, _) = await proofreadAcceptAll(text, selection: whole(text), [("teh", "the")])
        XCTAssertEqual(result, "---\nteh: teh\n---\n> the quote\n- [ ] the task\n\n```\nteh code\n```\nthe after `teh` [the](teh.md)\n")
    }

    func testRewriteAcrossLinkAndCodeIsOneChangeThatKeepsThem() async throws {
        let text = "Use the [old tool](a.md) with `flag` quickly."
        let (controller, surface) = make(text, replacing([("old", "new"), ("quickly", "fast"), ("Use", "Try")]))
        await run(controller, .rephrase, whole(text), text)
        let session = try XCTUnwrap(reviewSession(controller))
        XCTAssertEqual(session.changes.count, 1)
        controller.handle(.acceptCurrent)
        XCTAssertEqual(surface.string, "Try the [new tool](a.md) with `flag` fast.")
    }

    // MARK: - 4. State races at the controller level

    func testDocumentTypedIntoWhileRequestRunsIsDiscarded() async {
        let text = "Teh original text."
        let client = GatedAIClient()
        let (controller, surface) = make(text, client: client)
        controller.run(.proofread, range: whole(text), text: text)
        await waitUntilWaiting(client)
        surface.string = "Teh original text!"   // typing landed while waiting
        client.release(replyJSON(["The original text."]))
        await controller.runTask?.value
        XCTAssertEqual(message(controller), AIActionController.textChangedMessage)
        XCTAssertTrue(surface.editCalls.isEmpty)
    }

    /// A renormalized document (same characters, different UTF-16) also counts as changed.
    func testRenormalizedDocumentWhileRequestRunsIsDiscarded() async {
        let text = "Teh cafe\u{301}."
        let client = GatedAIClient()
        let (controller, surface) = make(text, client: client)
        controller.run(.proofread, range: whole(text), text: text)
        await waitUntilWaiting(client)
        surface.string = text.precomposedStringWithCanonicalMapping
        client.release(replyJSON(["The cafe\u{301}."]))
        await controller.runTask?.value
        XCTAssertEqual(message(controller), AIActionController.textChangedMessage)
    }

    func testReplyAfterCancelIsIgnored() async {
        let text = "Teh text."
        let client = GatedAIClient()
        let (controller, surface) = make(text, client: client)
        controller.run(.proofread, range: whole(text), text: text)
        await waitUntilWaiting(client)
        controller.cancel()
        client.release(replyJSON(["The text."]))
        await controller.runTask?.value
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(surface.editCalls.isEmpty)
    }

    func testOldReplyArrivingDuringNewRequestIsIgnored() async throws {
        let text = "Teh text here."
        let client = GatedAIClient()
        let (controller, surface) = make(text, client: client)
        controller.run(.proofread, range: whole(text), text: text)
        await waitUntilWaiting(client)
        let firstTask = controller.runTask
        controller.cancel()
        await firstTask?.value
        controller.run(.proofread, range: whole(text), text: text)
        await waitUntilWaiting(client)
        client.release(replyJSON(["The text here."]))
        await controller.runTask?.value
        let session = try XCTUnwrap(reviewSession(controller))
        XCTAssertEqual(session.changes.map(\.replacement), ["The"])
        XCTAssertEqual(surface.string, text)
    }

    func testTryAgainTwiceQuicklySendsOneRequest() async throws {
        let text = "Teh text."
        let client = GatedAIClient()
        let (controller, _) = make(text, client: client)
        controller.run(.rephrase, range: whole(text), text: text)
        await waitUntilWaiting(client)
        client.release(replyJSON(["The text."]))
        await controller.runTask?.value
        _ = try XCTUnwrap(reviewSession(controller))
        controller.handle(.retry)
        controller.handle(.retry)
        await waitUntilWaiting(client)
        XCTAssertEqual(client.callCount, 2, "the second Try Again lands while running and does nothing")
        client.release(replyJSON(["A text."]))
        await controller.runTask?.value
        XCTAssertNotNil(reviewSession(controller))
    }

    func testAcceptAllThenEscAppliesOnce() async throws {
        let text = "Teh cat and teh dog."
        let (controller, surface) = make(text, replacing([("teh", "the"), ("Teh", "The")]))
        await run(controller, .proofread, whole(text), text)
        _ = try XCTUnwrap(reviewSession(controller))
        controller.handle(.acceptAll)
        controller.handle(.end)
        controller.handle(.rejectCurrent)
        XCTAssertEqual(surface.editCalls.count, 1)
        XCTAssertEqual(surface.string, "The cat and the dog.")
    }

    func testYieldToHistoryMidRequestDropsTheReply() async {
        let text = "Teh text."
        let client = GatedAIClient()
        let (controller, surface) = make(text, client: client)
        controller.run(.proofread, range: whole(text), text: text)
        await waitUntilWaiting(client)
        let task = controller.runTask
        controller.yieldToHistory()
        client.release(replyJSON(["The text."]))
        await task?.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(surface.editCalls.isEmpty)
    }

    /// Document swap mid-review (`endAIForDocumentChange`: endReview then abandon): accepted
    /// decisions land on the outgoing text, once.
    func testDocumentSwapMidReviewAppliesAcceptedOnly() async throws {
        let text = "Teh cat and teh dog."
        let (controller, surface) = make(text, replacing([("teh", "the"), ("Teh", "The")]))
        await run(controller, .proofread, whole(text), text)
        let session = try XCTUnwrap(reviewSession(controller))
        controller.handle(.accept(session.changes[1].id))
        controller.endReview()
        controller.abandon()
        XCTAssertEqual(surface.string, "Teh cat and the dog.")
        XCTAssertEqual(surface.editCalls.count, 1)
    }

    /// Defence in depth: if the text under a review ever changes by a path that does not end the
    /// review, Accept still splices at the old offsets. The controller checks only structure.
    func testAcceptAfterUnreportedTextChangeDoesNotCorrupt() async throws {
        let text = "The cat sat on teh mat."
        let (controller, surface) = make(text, replacing([("teh", "the")]))
        await run(controller, .proofread, whole(text), text)
        _ = try XCTUnwrap(reviewSession(controller))
        surface.string = "A cat sat on teh mat."  // two UTF-16 units shorter, unreported
        controller.handle(.acceptAll)
        XCTAssertTrue(surface.string == "A cat sat on the mat." || surface.string == "A cat sat on teh mat.",
                      "got \(surface.string.debugDescription)")
    }

    // MARK: - History around accepts

    func testAcceptCoveringSeveralPassagesFilesThemUnderTheNewOne() async throws {
        let history = DocumentHistoryController(store: NullPassageHistoryStore(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        var text = "Alpha beta gamma. Delta epsilon zeta."
        history.open(url: nil, text: text)
        // Two word passages with two versions each.
        var wordIDs: [UUID] = []
        for (old, new) in [("beta", "BETA"), ("epsilon", "EPSILON")] {
            let r = (text as NSString).range(of: old)
            history.noteUserEdit(r, replacement: new)
            text = (text as NSString).replacingCharacters(in: r, with: new)
            if let id = history.recordAccepted(range: NSRange(location: r.location, length: (new as NSString).length),
                                               original: old, accepted: new, text: text) { wordIDs.append(id) }
        }
        XCTAssertEqual(wordIDs.count, 2)
        let (controller, surface) = make(text, replacing([("Alpha", "Omega"), ("zeta", "eta")]), history: history)
        await run(controller, .rephrase, whole(text), text)
        _ = try XCTUnwrap(reviewSession(controller))
        controller.handle(.acceptCurrent)
        XCTAssertEqual(surface.string, "Omega BETA gamma. Delta EPSILON eta.")
        // Both word passages must still exist, filed under the accepted passage.
        let recorded = try XCTUnwrap(history.rememberedPassageID)
        for id in wordIDs {
            let word = try XCTUnwrap(history.passage(id), "a word passage the accept covered was dropped")
            XCTAssertEqual(word.parentID, recorded)
        }
    }
}

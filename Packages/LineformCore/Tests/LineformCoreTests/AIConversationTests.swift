import XCTest
@testable import LineformCore
import LineformCoreTestSupport

/// The AI drawer's pieces: the curated words, the question classifier, the structured reply
/// (answers, blanks), the controller's versions, and the conversation that drives them.
final class AIPromptLexiconTests: XCTestCase {
    private let words = AIPromptLexicon.english

    private func ids(_ text: String) -> [String] {
        AIPromptLexicon.matches(in: text, words: words).map(\.wordID)
    }

    func testTheListIsCuratedAndWellFormed() {
        XCTAssertGreaterThanOrEqual(words.count, 30)
        XCTAssertLessThanOrEqual(words.count, 40)
        XCTAssertEqual(Set(words.map(\.group)), Set(AIPromptWord.Group.allCases), "every group has words")
        XCTAssertEqual(Set(words.map(\.id)).count, words.count, "ids are unique")
        var formOwners: [String: String] = [:]
        for word in words {
            XCTAssertTrue((4...7).contains(word.refinements.count), "\(word.id): 4–7 refinements")
            XCTAssertEqual(Set(word.refinements.map(\.label)).count, word.refinements.count, "\(word.id): unique labels")
            XCTAssertFalse(word.defaults.isEmpty, word.id)
            for label in word.defaults { XCTAssertNotNil(word.refinement(label), "\(word.id): default \(label)") }
            XCTAssertTrue(word.question.hasSuffix("?"), word.id)
            for refinement in word.refinements {
                XCTAssertFalse(refinement.direction.isEmpty)
                XCTAssertTrue(refinement.direction.hasSuffix("."), "\(word.id): \(refinement.direction)")
            }
            for form in word.forms {
                XCTAssertEqual(form, form.lowercased(), "\(word.id): forms are lower case")
                if let owner = formOwners[form] { XCTFail("“\(form)” belongs to both \(owner) and \(word.id)") }
                formOwners[form] = word.id
            }
        }
    }

    /// No crude or offensive words anywhere in what the writer sees or the model receives.
    func testNothingCrudeOrOffensive() {
        let banned = ["damn", "hell", "crap", "shit", "fuck", "ass", "sexy", "stupid", "dumb", "idiot", "kill", "hate"]
        for word in words {
            let text = ([word.question] + word.forms + word.refinements.flatMap { [$0.label, $0.direction] })
                .joined(separator: " ").lowercased()
            let tokens = Set(text.components(separatedBy: CharacterSet.letters.inverted))
            for bad in banned { XCTAssertFalse(tokens.contains(bad), "\(word.id) contains \(bad)") }
        }
    }

    func testMatchesWordFormsAndPhrases() {
        XCTAssertEqual(ids("Make this more professional for the leadership team"), ["professional", "executives"])
        XCTAssertEqual(ids("write it professionally"), ["professional"])
        XCTAssertEqual(ids("Less stiff, please"), ["natural"])
        XCTAssertEqual(ids("Make it punchier and shorter"), ["punchier", "shorter"])
        XCTAssertEqual(ids("Smooth this out so it flows better"), ["flow", "flow"])
        XCTAssertEqual(ids("FRIENDLIER"), ["friendly"], "case-insensitive")
    }

    func testWholeWordsOnlyAndLongestFirst() {
        XCTAssertEqual(ids("unprofessional"), [], "inside a word is no match")
        XCTAssertEqual(ids("clearly"), [])
        let matches = AIPromptLexicon.matches(in: "more professional", words: words)
        XCTAssertEqual(matches.map(\.range), [NSRange(location: 0, length: 17)], "the phrase wins over the word")
        XCTAssertEqual(ids("a plain english version"), ["simpler"])
    }

    func testRangesAreUTF16() {
        let text = "🙂 make it warmer"
        let match = try? XCTUnwrap(AIPromptLexicon.matches(in: text, words: words).first)
        XCTAssertEqual((text as NSString).substring(with: match?.range ?? NSRange()), "warmer")
    }

    func testOnlyEnglishShipsAndOtherLanguagesUnderlineNothing() {
        XCTAssertEqual(AIPromptLexicon.words(forLanguage: "en").count, words.count)
        XCTAssertEqual(AIPromptLexicon.words(forLanguage: "en-GB").count, words.count)
        for code in ["de", "fr", "es", "ja", "zh-Hans"] {
            XCTAssertTrue(AIPromptLexicon.words(forLanguage: code).isEmpty, code)
        }
    }

    func testDirectionsUseChoicesOrDefaultsAndKeepTheWritersWord() throws {
        let typed = "Make it more professional and punchier"
        let defaults = AIPromptLexicon.instruction(typed, choices: [:], words: words)
        XCTAssertTrue(defaults.hasPrefix(typed + "\n\nDirections:\n"))
        XCTAssertTrue(defaults.contains("- “more professional” means: Replace slang and idioms with standard wording, and remove emoji. Use no exclamation marks."))
        XCTAssertTrue(defaults.contains("- “punchier” means: Use shorter sentences; fragments are allowed. Remove hedges."))
        XCTAssertTrue(defaults.hasSuffix(AIPromptLexicon.keepConstraint))

        let chosen = AIPromptLexicon.instruction(typed, choices: ["professional": ["keep it warm"]], words: words)
        XCTAssertTrue(chosen.contains("“more professional” means: Keep a warm, human tone; do not become cold or bureaucratic."))
        XCTAssertFalse(chosen.contains("Use no exclamation marks."))

        let plain = AIPromptLexicon.instruction("  Translate the dates  ", choices: [:], words: words)
        XCTAssertEqual(plain, "Translate the dates\n\n" + AIPromptLexicon.keepConstraint)
    }
}

final class AIRequestClassifierTests: XCTestCase {
    private func isQuestion(_ text: String) -> Bool {
        AIRequestClassifier.isQuestion(text, words: AIPromptLexicon.english)
    }

    func testQuestions() {
        XCTAssertTrue(isQuestion("Why does this paragraph sound so informal?"))
        XCTAssertTrue(isQuestion("What is the main point here?"))
        XCTAssertTrue(isQuestion("Is the second sentence too long?"))
        XCTAssertTrue(isQuestion("Does this read well"))
        XCTAssertTrue(isQuestion("この文は長すぎますか？"))
    }

    func testEditRequests() {
        XCTAssertFalse(isQuestion("Make this more professional"))
        XCTAssertFalse(isQuestion("Can you make this shorter?"))
        XCTAssertFalse(isQuestion("Could you please rewrite the opening?"))
        XCTAssertFalse(isQuestion("Is it possible to make it punchier?"), "a curated word asks for a change")
        XCTAssertFalse(isQuestion("Shorter."))
        XCTAssertFalse(isQuestion("   "))
    }
}

final class AIStructuredReplyTests: XCTestCase {
    func testAnswerReadsTheJSONOrThePlainTextFallback() {
        XCTAssertEqual(AIResponseParser.answer(from: #"{"answer": " It is the hedges. "}"#), "It is the hedges.")
        XCTAssertNil(AIResponseParser.answer(from: #"{"segments": ["x"]}"#))
        XCTAssertNil(AIResponseParser.answer(from: "Just prose."), "plain text only where allowed")
        XCTAssertEqual(AIResponseParser.answer(from: "Just prose.", allowsPlainText: true), "Just prose.")
        XCTAssertEqual(AIResponseParser.answer(from: "{\"answer\": \"a\\u0007b\"}"), "ab", "control characters dropped")
        XCTAssertNil(AIResponseParser.answer(from: #"{"answer": "   "}"#))
        let long = String(repeating: "a", count: 9_000)
        XCTAssertEqual(AIResponseParser.answer(from: "{\"answer\": \"\(long)\"}")?.count, AIResponseParser.maxAnswerLength)
    }

    func testAssumptionsAreValidatedNotRepaired() {
        let reply = """
        {"segments": ["I'll share the list by Friday."],
         "assumptions": [
           {"phrase": "by Friday", "line": "I assumed you'll share it by Friday.", "question": "When will you share it?",
            "options": ["by Friday", "next week", "next week", "by the end of the sprint", "later", "much later"]},
           {"phrase": "not in the text", "line": "I assumed not in the text.", "question": "Q?", "options": ["a", "b"]},
           {"phrase": "list", "line": "No phrase here.", "question": "Q?", "options": ["a"]},
           {"phrase": "share", "line": "I assumed you share.", "question": "Q?", "options": ["share"]}
         ]}
        """
        let found = AIResponseParser.assumptions(from: reply, revisions: ["I'll share the list by Friday."])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.options, ["by Friday", "next week", "by the end of the sprint", "later"])
        XCTAssertEqual(found.first?.lineParts.before, "I assumed you'll share it ")
        XCTAssertEqual(found.first?.lineParts.after, ".")
        XCTAssertEqual(AIResponseParser.assumptions(from: #"{"segments": ["x"]}"#, revisions: ["x"]), [])
        XCTAssertEqual(AIResponseParser.assumptions(from: "not json", revisions: ["x"]), [])
    }

    func testCustomPromptOffersAnswersAndBlanksOnly() {
        XCTAssertTrue(AIActionPrompt.editPrompt(.custom, segments: ["x"], note: "warmer").system
            .contains(AIActionPrompt.conversationInstruction))
        XCTAssertFalse(AIActionPrompt.editPrompt(.trim, segments: ["x"]).system.contains(AIActionPrompt.conversationInstruction))
        let question = AIActionPrompt.questionPrompt("  Why so long? ", segments: ["A.", "B."])
        XCTAssertEqual(question.user, #"{"passage":["A.","B."],"question":"Why so long?"}"#)
        XCTAssertEqual(question.system, AIActionPrompt.questionSystem)
    }
}

/// Settable script for the fake AI: each request gets the next reply.
private final class ReplyScript: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [@Sendable (AIPrompt) -> String]
    init(_ replies: [@Sendable (AIPrompt) -> String]) { self.replies = replies }
    func next(_ prompt: AIPrompt) -> String {
        let reply: (@Sendable (AIPrompt) -> String)? = lock.withLock { replies.isEmpty ? nil : replies.removeFirst() }
        return reply?(prompt) ?? "{}"
    }
}

@MainActor
final class AIConversationTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func segmentsReply(_ transform: @escaping @Sendable (String) -> String, extra: String = "") -> @Sendable (AIPrompt) -> String {
        { prompt in
            let revised = FakeAIClient.segments(in: prompt).map(transform)
            let data = try! JSONSerialization.data(withJSONObject: ["segments": revised])
            var json = String(decoding: data, as: UTF8.self)
            if !extra.isEmpty { json = String(json.dropLast()) + "," + extra + "}" }
            return json
        }
    }

    private func make(_ text: String, replies: [@Sendable (AIPrompt) -> String], selection: NSRange? = nil)
        -> (AIConversation, AIActionController, FakeAIEditorSurface, FakeAIClient) {
        suiteName = "AIConversationTests.\(UUID().uuidString)"
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, keychain: InMemoryAIKeychain())
        XCTAssertNil(store.connect(.claude, key: "test-key-not-real"))
        let script = ReplyScript(replies)
        let fake = FakeAIClient(.respond { script.next($0) })
        let controller = AIActionController(connectionStore: store) { _ in fake }
        let surface = FakeAIEditorSurface(text)
        controller.editor = surface
        let conversation = AIConversation(words: AIPromptLexicon.english)
        conversation.attach(controller)
        let range = selection ?? NSRange(location: 0, length: (text as NSString).length)
        conversation.target = {  AIConversation.Target(range: range, text: surface.string) }
        return (conversation, controller, surface, fake)
    }

    private func settle(_ controller: AIActionController) async {
        await controller.runTask?.value
        await Task.yield()
        await Task.yield()
    }

    func testStartsEmptyWithQuickActions() {
        let (conversation, _, _, _) = make("Hello there.", replies: [])
        XCTAssertFalse(conversation.hasStarted)
        XCTAssertEqual(AIConversation.quickActions, [.proofread, .trim, .cutInHalf, .rephrase, .simplify, .moreFormal, .moreCasual])
    }

    func testQuickActionMakesARequestAndAPendingSuggestion() async {
        let (conversation, controller, surface, _) = make("The big dog ran far away.", replies: [segmentsReply { _ in "The dog ran away." }])
        conversation.runQuickAction(.trim)
        XCTAssertTrue(conversation.hasStarted)
        XCTAssertTrue(conversation.isWorking)
        XCTAssertEqual(conversation.messages.first?.content, .request(AIAction.trim.title))
        await settle(controller)
        XCTAssertFalse(conversation.isWorking)
        XCTAssertEqual(conversation.pendingSuggestion?.suggestion.current.displayText, "The dog ran away.")
        XCTAssertEqual(surface.string, "The big dog ran far away.", "nothing enters the text before Accept")

        conversation.accept()
        XCTAssertEqual(surface.string, "The dog ran away.")
        XCTAssertEqual(surface.editCalls.count, 1, "one undo group")
        XCTAssertNil(conversation.pendingSuggestion, "the buttons go")
        XCTAssertEqual(conversation.messages.count, 2, "no Accepted message")
    }

    func testRejectRemovesTheRequestAndSuggestionAndReturnsToStart() async {
        let (conversation, controller, surface, _) = make("The big dog ran far away.", replies: [segmentsReply { _ in "A dog left." }])
        conversation.runQuickAction(.rephrase)
        await settle(controller)
        conversation.reject()
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertFalse(conversation.hasStarted)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(surface.string, "The big dog ran far away.")
    }

    func testTryAgainAddsAVersionToTheSameBubbleAndAcceptTakesTheOneOnScreen() async {
        let (conversation, controller, surface, fake) = make("The big dog ran far away.", replies: [
            segmentsReply { _ in "First version." }, segmentsReply { _ in "Second version." },
        ])
        conversation.runQuickAction(.rephrase)
        await settle(controller)
        conversation.tryAgain()
        XCTAssertTrue(conversation.isRetrying)
        await settle(controller)
        XCTAssertEqual(conversation.messages.count, 2, "the same bubble")
        let pending = try? XCTUnwrap(conversation.pendingSuggestion)
        XCTAssertEqual(pending?.suggestion.versions.map(\.displayText), ["First version.", "Second version."])
        XCTAssertEqual(pending?.suggestion.versionNumber, 2)
        XCTAssertTrue(FakeAIClient.segments(in: fake.prompts[1]).isEmpty == false)
        XCTAssertTrue(fake.prompts[1].system.contains(AIActionPrompt.differentResultInstruction))

        conversation.showVersion(0, of: pending!.id)
        XCTAssertEqual(conversation.pendingSuggestion?.suggestion.versionNumber, 1)
        XCTAssertEqual(fake.prompts.count, 2, "stepping sends nothing")
        conversation.accept()
        XCTAssertEqual(surface.string, "First version.")
    }

    func testAFailedTryAgainBringsTheVersionBack() async {
        let (conversation, controller, surface, _) = make("The big dog ran far away.", replies: [
            segmentsReply { _ in "First version." }, { _ in "not json" },
        ])
        conversation.runQuickAction(.rephrase)
        await settle(controller)
        conversation.tryAgain()
        await settle(controller)
        await Task.yield()
        XCTAssertEqual(conversation.pendingSuggestion?.suggestion.current.displayText, "First version.")
        XCTAssertTrue(conversation.messages.contains { $0.content == .notice(AIClientError.unusableResponse.message) })
        conversation.accept()
        XCTAssertEqual(surface.string, "First version.")
    }

    func testAQuestionGetsAPlainAnswerWithNoDecision() async {
        let (conversation, controller, surface, fake) = make("Hey team!! So we ran out of time.", replies: [
            { _ in #"{"answer": "Mostly the opening and the double exclamation mark."}"# },
        ])
        conversation.draft = "Why does this sound so informal?"
        conversation.send()
        XCTAssertEqual(conversation.draft, "")
        await settle(controller)
        XCTAssertEqual(conversation.messages.map(\.content), [
            .request("Why does this sound so informal?"),
            .answer("Mostly the opening and the double exclamation mark."),
        ])
        XCTAssertNil(conversation.pendingSuggestion)
        XCTAssertEqual(fake.prompts.first?.system, AIActionPrompt.questionSystem)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(surface.editCalls.isEmpty)
    }

    func testAnEditRequestTheModelAnswersInProseIsAnAnswer() async {
        let (conversation, controller, _, _) = make("Some text here.", replies: [{ _ in #"{"answer": "It already reads well."}"# }])
        conversation.draft = "make it better"
        conversation.send()
        await settle(controller)
        XCTAssertEqual(conversation.messages.last?.content, .answer("It already reads well."))
    }

    func testTypedWordsTravelAsDirections() async {
        let (conversation, controller, _, fake) = make("Hey team, we basically ran out of time!!", replies: [segmentsReply { _ in "We ran out of time." }])
        conversation.draft = "Make this more professional"
        XCTAssertEqual(conversation.matches.map(\.wordID), ["professional"])
        conversation.openWord(conversation.matches[0])
        XCTAssertEqual(conversation.card?.question, "Professional how?")
        XCTAssertEqual(conversation.cardSelection, ["no slang or emoji", "no exclamation marks"])
        XCTAssertFalse(conversation.canSend, "the card comes first")
        conversation.applyCard(["fewer jokes", "not a refinement"])
        XCTAssertNil(conversation.card)
        XCTAssertTrue(conversation.isChosen("professional"))
        conversation.send()
        await settle(controller)
        let note = try? XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(fake.prompts[0].user.utf8))) as? [String: Any])?["note"] as? String
        XCTAssertEqual(note, "Make this more professional\n\nDirections:\n- “more professional” means: Remove jokes and playful asides.\n\n"
                       + AIPromptLexicon.keepConstraint)
        XCTAssertEqual(conversation.messages.first?.content, .request("Make this more professional"), "sent as plain text")
        XCTAssertTrue(conversation.choices.isEmpty)
    }

    func testABlankRewritesTheSuggestionWithNoRequest() async {
        let text = "I will share the list soon."
        let (conversation, controller, surface, fake) = make(text, replies: [segmentsReply({ _ in "I'll share the list by Friday." }, extra:
            #""assumptions": [{"phrase": "by Friday", "line": "I assumed you'll share it by Friday.", "question": "When will you share it?", "options": ["by Friday", "next week"]}]"#)])
        conversation.draft = "make it firmer"
        conversation.send()
        await settle(controller)
        let pending = try? XCTUnwrap(conversation.pendingSuggestion)
        let assumption = try? XCTUnwrap(pending?.suggestion.current.assumptions.first)
        conversation.openBlank(assumption!, in: pending!.id)
        XCTAssertEqual(conversation.card?.question, "When will you share it?")
        conversation.applyCard(["on Tuesday"])
        let after = conversation.pendingSuggestion?.suggestion
        XCTAssertEqual(after?.current.displayText, "I'll share the list on Tuesday.")
        XCTAssertEqual(after?.current.assumptions, [], "the I assumed line goes")
        XCTAssertEqual(after?.versions.count, 1, "the reply itself changes; not a new version")
        XCTAssertEqual(fake.prompts.count, 1)
        conversation.accept()
        XCTAssertEqual(surface.string, "I'll share the list on Tuesday.")
    }

    func testABlankThatWouldChangeMarkdownIsRefused() async {
        let text = "I will share the list soon."
        let (conversation, controller, _, _) = make(text, replies: [segmentsReply({ _ in "I'll share the list by Friday." }, extra:
            #""assumptions": [{"phrase": "by Friday", "line": "I assumed by Friday.", "question": "When?", "options": ["by Friday", "next week"]}]"#)])
        conversation.draft = "make it firmer"
        conversation.send()
        await settle(controller)
        let pending = conversation.pendingSuggestion!
        conversation.openBlank(pending.suggestion.current.assumptions[0], in: pending.id)
        conversation.applyCard(["**soon**"])
        XCTAssertEqual(conversation.pendingSuggestion?.suggestion.current.displayText, "I'll share the list by Friday.")
    }

    func testTheWholeDocumentAsksAboveTheLimitAndSendsOnlyOnConfirm() async {
        let text = Array(repeating: "word", count: 1_600).joined(separator: " ") + "."
        let (conversation, controller, _, fake) = make(text, replies: [segmentsReply { $0 }], selection: NSRange(location: 0, length: 0))
        var asked: Int?
        var proceed: (() -> Void)?
        conversation.confirmWholeDocument = { words, go in asked = words; proceed = go }
        conversation.runQuickAction(.proofread)
        XCTAssertEqual(asked, 1_600)
        XCTAssertTrue(fake.prompts.isEmpty, "nothing is sent before Send")
        proceed?()
        await settle(controller)
        XCTAssertEqual(fake.prompts.count, 1)
    }

    func testResetClearsEverything() async {
        let (conversation, controller, _, _) = make("Text.", replies: [{ _ in #"{"answer": "Yes."}"# }])
        conversation.draft = "Is this fine?"
        conversation.send()
        await settle(controller)
        conversation.reset()
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertFalse(conversation.hasStarted)
    }
}

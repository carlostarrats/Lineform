import XCTest
@testable import LineformCore

/// The prompt words in German, French, Spanish, Japanese and Simplified Chinese: each language's
/// forms are found, its options card reads in the interface language, and no form matches inside
/// an unrelated word. Forms are matched in every language at once, so English text is checked
/// for stray matches too.
final class AIPromptLexiconLanguageTests: XCTestCase {
    private static let interfaceLanguages = ["de", "fr", "es", "ja", "zh-Hans"]

    private func ids(_ text: String, _ words: [AIPromptWord] = AIPromptLexicon.english) -> [String] {
        AIPromptLexicon.matches(in: text, words: words).map(\.wordID)
    }

    private func typed(_ text: String) -> [String] {
        let ns = text as NSString
        return AIPromptLexicon.matches(in: text, words: AIPromptLexicon.english).map { ns.substring(with: $0.range) }
    }

    // MARK: Found

    func testGermanWordsAreFound() {
        XCTAssertEqual(ids("Mach den Absatz kürzer und freundlicher"), ["shorter", "friendly"])
        XCTAssertEqual(ids("Bitte kürzen und etwas sachlicher formulieren"), ["shorter", "neutral"])
        XCTAssertEqual(ids("KÜRZER, bitte"), ["shorter"], "case-insensitive")
        XCTAssertEqual(ids("Schreib es für Einsteiger"), ["beginners"], "the phrase wins over the word")
        XCTAssertEqual(typed("Schreib es für Einsteiger"), ["für Einsteiger"])
        XCTAssertEqual(ids("Es soll menschlicher klingen"), ["humanize"], "longest form first")
    }

    func testFrenchWordsAreFound() {
        XCTAssertEqual(ids("Rends ce paragraphe plus court et plus chaleureux"), ["shorter", "friendly"])
        XCTAssertEqual(ids("Peux-tu raccourcir le texte ?"), ["shorter"])
        XCTAssertEqual(ids("plus precis"), ["specific"], "accents are optional")
        XCTAssertEqual(ids("Le texte doit être plus percutant"), ["punchier"])
        XCTAssertEqual(ids("Ça se lit mieux ainsi"), ["flow"], "the phrase wins over “mieux”")
    }

    func testSpanishWordsAreFound() {
        XCTAssertEqual(ids("Hazlo más corto y más profesional"), ["shorter", "professional"])
        XCTAssertEqual(ids("Acórtalo, por favor"), ["shorter"])
        XCTAssertEqual(ids("mas formal"), ["formal"], "accents are optional")
        XCTAssertEqual(ids("Que sea más claro para principiantes"), ["clearer", "beginners"])
    }

    func testJapaneseWordsAreFound() {
        XCTAssertEqual(ids("この段落をもっと短くして"), ["shorter"])
        XCTAssertEqual(ids("丁寧な表現で、分かりやすく書き直して"), ["polite", "clearer"])
        XCTAssertEqual(ids("AIっぽさを消して"), ["humanize"], "a Latin edge next to kana is a boundary")
        let text = "もっと短くして"
        let match = try? XCTUnwrap(AIPromptLexicon.matches(in: text, words: AIPromptLexicon.english).first)
        XCTAssertEqual((text as NSString).substring(with: match?.range ?? NSRange()), "もっと短く")
    }

    func testChineseWordsAreFound() {
        XCTAssertEqual(ids("把这段改得更简洁、更专业"), ["concise", "professional"])
        XCTAssertEqual(ids("写得通俗易懂一点"), ["simpler"], "the long form wins over 易懂")
        XCTAssertEqual(ids("去掉ai味"), ["humanize"])
        XCTAssertEqual(ids("给领导看的，条理清晰"), ["executives", "structured"])
    }

    func testAGermanWriterOnAnEnglishInterfaceAndTheReverse() {
        XCTAssertEqual(ids("Mach es kürzer", AIPromptLexicon.english), ["shorter"])
        XCTAssertEqual(ids("Make it shorter", AIPromptLexicon.words(forLanguage: "de")), ["shorter"])
        XCTAssertEqual(ids("更短", AIPromptLexicon.words(forLanguage: "fr")), ["shorter"])
    }

    // MARK: No false match

    func testGermanNoMatchInsideAnUnrelatedWord() {
        XCTAssertEqual(ids("Das war eine Unhöflichkeit"), [], "höflich inside a longer word")
        XCTAssertEqual(ids("Der kurzer Text"), [], "umlauts count: kurzer is not kürzer")
        XCTAssertEqual(ids("Schreib einen Brief für die Kinder"), [], "English brief/kinder stay off German nouns")
        XCTAssertEqual(ids("Natürlich, das Ergebnis"), [], "natürlich means “of course”")
    }

    func testFrenchNoMatchInsideAnUnrelatedWord() {
        XCTAssertEqual(ids("Un résultat imprécis"), [], "précis inside a longer word")
        XCTAssertEqual(ids("Le court de tennis"), [], "court alone is a court")
        XCTAssertEqual(ids("Garde la structure et ajoute une image"), [])
    }

    func testSpanishNoMatchInsideAnUnrelatedWord() {
        XCTAssertEqual(ids("Los inexpertos lo leerán"), [], "expertos inside a longer word")
        XCTAssertEqual(ids("Claro, la casa de tu madre"), [])
    }

    func testJapaneseNoMatchInsideAnUnrelatedWord() {
        XCTAssertEqual(ids("流れ星を見た"), [], "流れ inside 流れ星 (a shooting star)")
        XCTAssertEqual(ids("得体の知れない話"), [], "得体 inside 得体の知れない (mysterious)")
        XCTAssertEqual(ids("自然科学の本"), [])
    }

    func testChineseNoMatchInsideAnUnrelatedWord() {
        XCTAssertEqual(ids("正式版已经上线"), [], "正式 inside 正式版 (a release)")
        XCTAssertEqual(ids("文件的扩展名"), [], "扩展 inside 扩展名 (a file extension)")
        XCTAssertEqual(ids("写得太非正式了"), ["casual"], "非正式 is casual, not formal")
    }

    /// The other languages' forms are matched in English text too, so plain English instructions
    /// must find exactly the English words.
    func testEnglishTextGainsNoMatchFromOtherLanguages() {
        let sentences: [(String, [String])] = [
            ("Keep the structure and add an image", []),
            ("Put the chef's notes in the locker", []),
            ("Reduce the court summary to the main point", []),
            ("Assure the reader the plan is on track", []),
            ("Make it shorter for the kinder readers", ["shorter", "friendly"]),
            ("Brief and clear, please.", ["concise", "clearer"]),
            ("Rewrite the intro. Brief is better.", ["concise", "better"]),
        ]
        for (text, expected) in sentences { XCTAssertEqual(ids(text), expected, text) }
    }

    // MARK: The options card

    func testOptionsAreShownInTheInterfaceLanguage() throws {
        let english = AIPromptLexicon.english
        for language in Self.interfaceLanguages {
            XCTAssertNotNil(Bundle.lineformCore.path(forResource: language, ofType: "lproj"),
                            "\(language).lproj missing from LineformCore's bundle")
            let list = AIPromptLexicon.words(forLanguage: language)
            XCTAssertEqual(list.count, english.count, language)
            for (word, source) in zip(list, english) {
                XCTAssertNotEqual(word.question, source.question, "\(language): \(word.id)'s question is untranslated")
                XCTAssertTrue(word.question.hasSuffix("?") || word.question.hasSuffix("？"), "\(language): \(word.question)")
                XCTAssertEqual(word.refinements.count, source.refinements.count)
                XCTAssertEqual(Set(word.refinements.map(\.label)).count, word.refinements.count,
                               "\(language): \(word.id) has two chips with one label")
                for (refinement, sourceRefinement) in zip(word.refinements, source.refinements) {
                    XCTAssertFalse(refinement.label.isEmpty)
                    XCTAssertEqual(refinement.key, sourceRefinement.label, "the key is the English label")
                    XCTAssertEqual(refinement.direction, sourceRefinement.direction, "directions stay English")
                }
                XCTAssertEqual(word.defaults.count, source.defaults.count)
                for label in word.defaults { XCTAssertNotNil(word.refinement(label), "\(language): \(word.id) \(label)") }
            }
        }
        let german = AIPromptLexicon.words(forLanguage: "de")
        XCTAssertEqual(AIPromptLexicon.word("shorter", in: german)?.question, "Inwiefern kürzer?")
        XCTAssertEqual(AIPromptLexicon.word("shorter", in: AIPromptLexicon.words(forLanguage: "ja"))?.question, "どのように短く？")
        XCTAssertEqual(AIPromptLexicon.word("shorter", in: AIPromptLexicon.words(forLanguage: "zh-Hans"))?.question, "怎样更短？")
        XCTAssertEqual(AIPromptLexicon.word("shorter", in: AIPromptLexicon.words(forLanguage: "fr"))?.question, "En quoi plus court ?")
        XCTAssertEqual(AIPromptLexicon.word("shorter", in: AIPromptLexicon.words(forLanguage: "es"))?.question, "¿Más corto en qué sentido?")
    }

    /// A chip chosen in German sends its English direction, with the word as the writer typed it.
    func testAChoiceInAnotherLanguageSendsTheEnglishDirection() throws {
        let german = AIPromptLexicon.words(forLanguage: "de")
        let shorter = try XCTUnwrap(AIPromptLexicon.word("shorter", in: german))
        let half = try XCTUnwrap(shorter.refinements.first { $0.key == "about half" })
        XCTAssertEqual(half.label, "etwa halb so lang")
        let sent = AIPromptLexicon.instruction("Mach es kürzer", choices: ["shorter": [half.label]], words: german)
        XCTAssertEqual(sent, "Mach es kürzer\n\nDirections:\n- “kürzer” means: Make it about half as long.\n\n"
                       + AIPromptLexicon.keepConstraint)
        let defaults = AIPromptLexicon.instruction("この段落をもっと短くして", choices: [:],
                                                   words: AIPromptLexicon.words(forLanguage: "ja"))
        XCTAssertTrue(defaults.contains("- “もっと短く” means: Make it about a third shorter. Keep every key fact, number, date and name."),
                      defaults)
    }

    func testAConversationMatchesEveryLanguageAsTheWriterTypes() async {
        await MainActor.run {
            let conversation = AIConversation(words: AIPromptLexicon.words(forLanguage: "es"))
            conversation.draft = "Más corto, 更专业"
            XCTAssertEqual(conversation.matches.map(\.wordID), ["shorter", "professional"])
        }
    }

    // MARK: Speed

    /// Matching runs on every keystroke against about 1,500 forms; the table is compiled once.
    func testMatchingStaysCheapPerKeystroke() {
        let table = AIPromptTable(words: AIPromptLexicon.english)
        let text = String(repeating: "Make this paragraph more professional, mach es kürzer, plus court, 更简洁一点. ", count: 4)
        let start = Date()
        for _ in 0..<100 { _ = AIPromptLexicon.matches(in: text, table: table) }
        let perCall = Date().timeIntervalSince(start) / 100
        XCTAssertLessThan(perCall, 0.010, "per keystroke: \(perCall * 1000) ms (Debug, unoptimized)")
    }
}

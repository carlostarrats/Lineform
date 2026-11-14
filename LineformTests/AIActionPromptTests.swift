import XCTest
@testable import Lineform

final class AIActionPromptTests: XCTestCase {
    private static let languages = ["es", "fr", "de", "ja", "zh-Hans"]

    private func decode(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testEditPromptCarriesActionAndSegmentsAsJSON() throws {
        let prompt = AIActionPrompt.editPrompt(.trim, segments: ["a", "b"])
        let object = try decode(prompt.user)
        XCTAssertEqual(object["action"] as? String, "trim")
        XCTAssertEqual(object["segments"] as? [String], ["a", "b"])
        XCTAssertEqual(object.count, 2)
        XCTAssertEqual(prompt.user, #"{"action":"trim","segments":["a","b"]}"#, "sorted keys, compact")
        XCTAssertTrue(prompt.system.hasPrefix("You edit prose for a writer."))
        XCTAssertTrue(prompt.system.contains(#"{"segments": [...]}"#))
        XCTAssertTrue(prompt.system.hasSuffix("\nRemove needless words. Keep the meaning. Change as little as possible otherwise, but always remove at least some words: never return the passage unchanged."))
    }

    func testEditPromptsCarryTheirOwnInstruction() {
        XCTAssertTrue(AIActionPrompt.editPrompt(.cutInHalf, segments: ["x"]).system
            .hasSuffix("Make the passage about half as long. Keep the most important points. Never return the passage unchanged."))
        XCTAssertTrue(AIActionPrompt.editPrompt(.rewrite, segments: ["x"]).system
            .hasSuffix("Rewrite for clarity and flow. Keep the meaning and about the same length. Always change the wording: never return the passage unchanged."))
        XCTAssertTrue(AIActionPrompt.editPrompt(.proofread, segments: ["x"]).system
            .hasSuffix("Fix only spelling, typos, grammar slips and prose punctuation. Change nothing else."))
        XCTAssertTrue(AIActionPrompt.editPrompt(.cutInHalf, segments: ["x"]).user.contains(#""action":"cutInHalf""#))
        let another = AIActionPrompt.editPrompt(.anotherWord, segments: ["big"])
        XCTAssertTrue(another.system.hasPrefix("You edit prose for a writer."))
        XCTAssertTrue(another.system.hasSuffix("Return one different word, or a very short phrase, that could replace it: same meaning, same part of speech, matching its capitalization. Never return the same word."))
        XCTAssertEqual(another.user, #"{"action":"anotherWord","segments":["big"]}"#)
    }

    /// Try Again: the discarded suggestion's segments go on one last system line; the user
    /// message (what is sent of the document) is unchanged.
    func testEditPromptCanAskForADifferentResult() {
        let plain = AIActionPrompt.editPrompt(.rewrite, segments: ["a b", "c"])
        let retry = AIActionPrompt.editPrompt(.rewrite, segments: ["a b", "c"], avoiding: ["x y", "z"])
        XCTAssertEqual(retry.user, plain.user)
        XCTAssertEqual(retry.system, plain.system + "\n" + #"Give a different result than: {"segments":["x y","z"]}"#)
        XCTAssertFalse(plain.system.contains("Give a different result"))
    }

    func testMarkPromptNumbersNothingItself() throws {
        let prompt = AIActionPrompt.markPrompt(.markWeakest, sentences: ["One.", "Two."])
        let object = try decode(prompt.user)
        XCTAssertEqual(object["action"] as? String, "weakestSentences")
        XCTAssertEqual(object["sentences"] as? [String], ["One.", "Two."])
        XCTAssertTrue(prompt.system.contains("the first is 1"))
        XCTAssertTrue(prompt.system.contains("Choose at most a third of them."))
        XCTAssertTrue(prompt.system.hasSuffix("\nChoose the weakest sentences: vague, flat or unclear."))
        XCTAssertTrue(AIActionPrompt.markPrompt(.markLong, sentences: ["x"]).system
            .hasSuffix("\nChoose sentences too long to read comfortably."))
    }

    func testRawValuesAreStableIdentity() {
        XCTAssertEqual(AIAction.allCases.map(\.rawValue),
                       ["trim", "cutInHalf", "rewrite", "proofread", "anotherWord", "weakestSentences", "longSentences"])
        XCTAssertEqual(AIAction.allCases.filter(\.isMark), [.markWeakest, .markLong])
        // Proofread may legitimately find nothing; the others exist to change the text.
        XCTAssertEqual(AIAction.allCases.filter(\.mustChangeText), [.trim, .cutInHalf, .rewrite, .anotherWord])
    }

    func testEveryActionHasLocalizedTitle() throws {
        let titles = ["Trim", "Cut in half", "Rewrite", "Proofread", "Another Word", "Weakest sentences", "Long sentences"]
        let verbs = ["Trimming…", "Cutting…", "Rewriting…", "Proofreading…", "Finding another word…", "Marking…"]
        XCTAssertEqual(AIAction.allCases.map(\.title), titles)
        XCTAssertEqual(Array(Set(AIAction.allCases.map(\.progressVerb))).sorted(), verbs.sorted())
        for language in Self.languages {
            let bundle = try XCTUnwrap(
                Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
                "\(language).lproj missing from the test host"
            )
            for key in titles + verbs {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, "\(language): \(key) untranslated")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
            }
        }
    }
}

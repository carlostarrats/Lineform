import XCTest
@testable import Lineform

/// Pins the rule the first version of document-language voice selection broke: the user's own
/// Spoken Content voice wins unless the document is positively in a different language. Everything
/// here runs against a supplied voice list, never `AVSpeechSynthesisVoice.speechVoices()`, so the
/// assertions do not depend on which voices are installed on the machine running the suite.
final class SpeechVoiceResolverTests: XCTestCase {

    /// Shaped like a real macOS install: several English regions, two French, both Chinese scripts.
    private let installedVoices: [SpeechVoiceCandidate] = [
        SpeechVoiceCandidate(identifier: "voice.en-US.Samantha", language: "en-US"),
        SpeechVoiceCandidate(identifier: "voice.en-GB.Daniel", language: "en-GB"),
        SpeechVoiceCandidate(identifier: "voice.en-AU.Karen", language: "en-AU"),
        SpeechVoiceCandidate(identifier: "voice.fr-CA.Amelie", language: "fr-CA"),
        SpeechVoiceCandidate(identifier: "voice.fr-FR.Thomas", language: "fr-FR"),
        SpeechVoiceCandidate(identifier: "voice.zh-CN.Tingting", language: "zh-CN"),
        SpeechVoiceCandidate(identifier: "voice.zh-TW.Meijia", language: "zh-TW"),
        SpeechVoiceCandidate(identifier: "voice.ja-JP.Kyoko", language: "ja-JP"),
    ]

    private func decision(
        detected: String?,
        systemDefault: String?,
        region: String?,
        voices: [SpeechVoiceCandidate]? = nil
    ) -> SpeechVoiceDecision {
        SpeechVoiceResolver.decision(
            detectedLanguage: detected,
            systemDefaultLanguage: systemDefault,
            preferredRegion: region,
            availableVoices: voices ?? installedVoices
        )
    }

    // MARK: - Agreement means no override

    /// THE COMMON CASE, and the regression: an en-GB user reading ordinary English prose. The
    /// previous implementation forced en-US Samantha here, discarding a voice the user chose.
    func testEnglishDocumentOnAnEnglishMachineKeepsTheUsersVoice() {
        XCTAssertEqual(
            decision(detected: "en", systemDefault: "en-GB", region: "GB"),
            .keepSystemDefault
        )
    }

    func testAustralianEnglishAlsoKeepsTheUsersVoice() {
        XCTAssertEqual(
            decision(detected: "en", systemDefault: "en-AU", region: "AU"),
            .keepSystemDefault
        )
    }

    /// Agreement is judged on the language, not the exact tag: a `fr` document on a fr-FR machine
    /// must not be re-resolved (which is how fr-CA Amélie reached a French user).
    func testFrenchDocumentOnAFrenchMachineKeepsTheUsersVoice() {
        XCTAssertEqual(
            decision(detected: "fr", systemDefault: "fr-FR", region: "FR"),
            .keepSystemDefault
        )
    }

    func testDetectionDecliningLeavesTheVoiceAlone() {
        XCTAssertEqual(
            decision(detected: nil, systemDefault: "en-US", region: "US"),
            .keepSystemDefault
        )
    }

    func testUnknownSystemDefaultStillResolvesRatherThanCrashing() {
        XCTAssertEqual(
            decision(detected: "ja", systemDefault: nil, region: "JP"),
            .voice(identifier: "voice.ja-JP.Kyoko")
        )
    }

    // MARK: - Disagreement means override

    func testJapaneseDocumentOnAnEnglishMachineOverrides() {
        XCTAssertEqual(
            decision(detected: "ja", systemDefault: "en-US", region: "US"),
            .voice(identifier: "voice.ja-JP.Kyoko")
        )
    }

    /// The bug this feature was added for, from the other side: an English document on a Japanese
    /// machine must not be read by a Japanese voice.
    func testEnglishDocumentOnAJapaneseMachineOverrides() {
        XCTAssertEqual(
            decision(detected: "en", systemDefault: "ja-JP", region: "JP"),
            .voice(identifier: "voice.en-US.Samantha")
        )
    }

    func testNoInstalledVoiceFallsBackToTheBareLanguageTag() {
        XCTAssertEqual(
            decision(detected: "nl", systemDefault: "en-US", region: "US"),
            .language("nl")
        )
    }

    // MARK: - Region preference

    /// `AVSpeechSynthesisVoice(language: "fr")` returns fr-CA Amélie on this machine even with
    /// fr-FR Thomas installed. When the user is in France, the resolver must not.
    func testRegionPreferenceChoosesTheUsersRegionOverTheArbitraryFirstMatch() {
        XCTAssertEqual(
            decision(detected: "fr", systemDefault: "ja-JP", region: "FR"),
            .voice(identifier: "voice.fr-FR.Thomas")
        )
    }

    func testRegionPreferenceFollowsTheUserRatherThanTheListOrder() {
        XCTAssertEqual(
            decision(detected: "fr", systemDefault: "ja-JP", region: "CA"),
            .voice(identifier: "voice.fr-CA.Amelie")
        )
    }

    /// A script subtag is stronger evidence than the user's region: `zh-Hant` must find zh-TW
    /// Meijia, never zh-CN Tingting, whatever the machine's region says.
    func testTraditionalChineseChoosesATraditionalVoice() {
        XCTAssertEqual(
            decision(detected: "zh-Hant", systemDefault: "en-US", region: "US"),
            .voice(identifier: "voice.zh-TW.Meijia")
        )
    }

    func testSimplifiedChineseChoosesASimplifiedVoice() {
        XCTAssertEqual(
            decision(detected: "zh-Hans", systemDefault: "en-US", region: "US"),
            .voice(identifier: "voice.zh-CN.Tingting")
        )
    }

    /// A Traditional document on a Simplified system voice is a genuine mismatch — the language
    /// subtags agree, so only the inferred script keeps this from being read in Simplified.
    func testTraditionalChineseOverridesASimplifiedSystemVoice() {
        XCTAssertEqual(
            decision(detected: "zh-Hant", systemDefault: "zh-CN", region: "CN"),
            .voice(identifier: "voice.zh-TW.Meijia")
        )
    }

    func testSimplifiedChineseKeepsAMatchingSimplifiedSystemVoice() {
        XCTAssertEqual(
            decision(detected: "zh-Hans", systemDefault: "zh-CN", region: "CN"),
            .keepSystemDefault
        )
    }

    /// An explicit region in the DOCUMENT's tag outranks the machine's region.
    func testAnExplicitRegionInTheDetectedTagWins() {
        XCTAssertEqual(
            decision(detected: "en-GB", systemDefault: "ja-JP", region: "US"),
            .voice(identifier: "voice.en-GB.Daniel")
        )
    }

    /// Underscores appear in `Locale`-flavoured tags; they must parse the same as hyphens.
    func testUnderscoreSeparatedTagsParse() {
        XCTAssertEqual(
            decision(detected: "en", systemDefault: "en_GB", region: "GB"),
            .keepSystemDefault
        )
    }

    /// With no region match anywhere, the answer must still be deterministic: the first compatible
    /// voice in the order the system reported them.
    func testFallbackIsTheFirstCompatibleVoiceInListOrder() {
        XCTAssertEqual(
            decision(detected: "en", systemDefault: "ja-JP", region: "ZZ"),
            .voice(identifier: "voice.en-US.Samantha")
        )
    }

    /// A region-less voice is usable but unspecific, so a regioned one is preferred.
    func testARegionedVoiceOutranksABareLanguageVoice() {
        let voices = [
            SpeechVoiceCandidate(identifier: "voice.pt", language: "pt"),
            SpeechVoiceCandidate(identifier: "voice.pt-PT.Joana", language: "pt-PT"),
        ]
        XCTAssertEqual(
            decision(detected: "pt", systemDefault: "en-US", region: "PT", voices: voices),
            .voice(identifier: "voice.pt-PT.Joana")
        )
    }

    func testMalformedDetectionIsTreatedAsNoDetection() {
        XCTAssertEqual(
            decision(detected: "", systemDefault: "en-US", region: "US"),
            .keepSystemDefault
        )
    }
}

import Foundation
import NaturalLanguage

/// Picks the voice language from the DOCUMENT, not the UI.
///
/// `AVSpeechUtterance` with no `voice` falls back to the system default, which follows the UI
/// language — so a Japanese-UI user reading an English document heard English read by a Japanese
/// voice. Detection is a heuristic on user prose, so it is deliberately conservative: below the
/// confidence floor it returns nil and the caller keeps the old behaviour.
enum SpeechLanguageDetector {

    /// Below this, the guess is not worth acting on. A wrong voice is more jarring than the
    /// system default, which is at least the user's own language.
    private static let confidenceFloor = 0.65

    /// Shorter than this and there is nothing to judge — "ok" is not evidence of English.
    private static let minimumCharacters = 12

    /// Language identification saturates long before this; a few thousand characters is already
    /// far more evidence than the confidence floor needs. Without a cap, `processString` walked
    /// the WHOLE document on the Edit ▸ Speech path — a hitch proportional to document size, paid
    /// to reach the same answer. Read-aloud starts at the caret and reads on, so the opening of
    /// the passage is also the most representative sample there is.
    private static let maximumSampleCharacters = 4_000

    /// - Returns: a BCP-47 language code (`"en"`, `"ja"`, `"zh-Hans"`), or nil to leave the
    ///   synthesizer's default alone.
    static func language(for text: String) -> String? {
        // Dropping the leading whitespace lazily, then taking the prefix, keeps this O(sample)
        // rather than O(document): `trimmingCharacters` on the full string would copy all of it
        // just to find the head. Trailing whitespace inside the sample is harmless to the
        // recognizer, so only a short sample is trimmed at all.
        let sample = text.drop(while: \.isWhitespace).prefix(maximumSampleCharacters)
        // A prefix-bounded count: `sample.count` is a grapheme walk, and all this has to decide
        // is "at least twelve".
        guard sample.prefix(minimumCharacters).count == minimumCharacters else { return nil }
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= confidenceFloor else { return nil }

        return language.rawValue
    }
}

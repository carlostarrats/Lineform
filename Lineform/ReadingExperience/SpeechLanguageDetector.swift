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

    /// - Returns: a BCP-47 language code (`"en"`, `"ja"`, `"zh-Hans"`), or nil to leave the
    ///   synthesizer's default alone.
    static func language(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= confidenceFloor else { return nil }

        return language.rawValue
    }
}

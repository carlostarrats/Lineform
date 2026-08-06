import Foundation

struct DocumentStatistics: Equatable {
    var wordCount: Int
    var characterCount: Int
    /// True when more than half of the word-forming scalars are Han, Hiragana, or
    /// Katakana. CJK prose has no interword spaces, so the run-based word count
    /// degrades to a sentence count; the status bar suppresses it and reports
    /// characters only. Content-based on purpose — never keyed off the UI locale.
    /// Hangul is space-separated and counts correctly, so it deliberately does not
    /// participate.
    var isPredominantlyCJK: Bool

    init(text: String) {
        // Characters as the writer counts them — grapheme clusters, not UTF-16 code units. The
        // status line says "characters", and `NSString.length` reported a two-emoji document as
        // four and a decomposed accent as two. Same order of cost as the word scan below, which
        // already walks the whole string.
        characterCount = text.count
        let counts = Self.scan(text)
        wordCount = counts.words
        isPredominantlyCJK = counts.hanKana * 2 > counts.wordForming
    }

    private static func scan(_ text: String) -> (words: Int, wordForming: Int, hanKana: Int) {
        var words = 0
        var wordForming = 0
        var hanKana = 0
        var isInsideWord = false
        let wordCharacters = CharacterSet.alphanumerics

        for scalar in text.unicodeScalars {
            if wordCharacters.contains(scalar) {
                wordForming += 1
                if isHanOrKana(scalar) { hanKana += 1 }
                if !isInsideWord {
                    words += 1
                    isInsideWord = true
                }
            } else {
                isInsideWord = false
            }
        }

        return (words, wordForming, hanKana)
    }

    private static func isHanOrKana(_ scalar: Unicode.Scalar) -> Bool {
        // isIdeographic covers Han including the extension blocks; Kana are not
        // ideographic and need their ranges (Hiragana 3040–309F, Katakana 30A0–30FF).
        scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
    }
}

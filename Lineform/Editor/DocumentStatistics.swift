import Foundation

struct DocumentStatistics: Equatable {
    var wordCount: Int
    var characterCount: Int

    init(text: String) {
        // Characters as the writer counts them — grapheme clusters, not UTF-16 code units. The
        // status line says "characters", and `NSString.length` reported a two-emoji document as
        // four and a decomposed accent as two. Same order of cost as the word scan below, which
        // already walks the whole string.
        characterCount = text.count
        wordCount = Self.countWords(in: text)
    }

    private static func countWords(in text: String) -> Int {
        var count = 0
        var isInsideWord = false
        let wordCharacters = CharacterSet.alphanumerics

        for scalar in text.unicodeScalars {
            if wordCharacters.contains(scalar) {
                if !isInsideWord {
                    count += 1
                    isInsideWord = true
                }
            } else {
                isInsideWord = false
            }
        }

        return count
    }
}

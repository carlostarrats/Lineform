import Foundation

struct DocumentStatistics: Equatable {
    var wordCount: Int
    var characterCount: Int

    init(text: String) {
        characterCount = (text as NSString).length
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

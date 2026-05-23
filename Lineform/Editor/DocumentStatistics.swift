import Foundation

struct DocumentStatistics: Equatable {
    var wordCount: Int
    var characterCount: Int

    init(text: String) {
        characterCount = (text as NSString).length
        wordCount = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .count
    }
}

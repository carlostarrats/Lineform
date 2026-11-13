import Foundation

/// Who produced a version of a passage.
enum HistoryAuthor: String, Codable {
    case you, ai
}

/// How large a passage is. `allCases` order is display order; `<` means "larger".
enum HistoryLevel: String, Codable, CaseIterable, Comparable {
    case paragraph, sentence, word

    static func < (lhs: HistoryLevel, rhs: HistoryLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Localized display name. Never localize the raw value: it is persisted identity.
    var title: String {
        switch self {
        case .paragraph: return String(localized: "Paragraph")
        case .sentence: return String(localized: "Sentence")
        case .word: return String(localized: "Word")
        }
    }
}

struct HistoryVersion: Codable, Equatable {
    var text: String
    var author: HistoryAuthor
    var createdAt: Date
}

struct HistoryPassage: Codable, Equatable, Identifiable {
    let id: UUID
    var level: HistoryLevel
    var versions: [HistoryVersion]
    var currentIndex: Int
    var parentID: UUID?
    var parentVersionIndex: Int?
    var contextBefore: String
    var contextAfter: String
    var lastTouched: Date
}

struct DocumentHistory: Codable, Equatable {
    var passages: [HistoryPassage]
    var isEmpty: Bool { passages.isEmpty }
}

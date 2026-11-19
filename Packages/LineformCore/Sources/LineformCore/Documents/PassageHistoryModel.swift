import Foundation

/// Who produced a version of a passage.
public enum HistoryAuthor: String, Codable, Sendable {
    case you, ai
}

/// How large a passage is. `allCases` order is display order; `<` means "larger".
public enum HistoryLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case paragraph, sentence, word

    public static func < (lhs: HistoryLevel, rhs: HistoryLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Localized display name. Never localize the raw value: it is persisted identity.
    public var title: String {
        switch self {
        case .paragraph: return String(localized: "Paragraph", bundle: .module)
        case .sentence: return String(localized: "Sentence", bundle: .module)
        case .word: return String(localized: "Word", bundle: .module)
        }
    }
}

public struct HistoryVersion: Codable, Equatable, Sendable {
    public var text: String
    public var author: HistoryAuthor
    var createdAt: Date
}

public struct HistoryPassage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var level: HistoryLevel
    public var versions: [HistoryVersion]
    public var currentIndex: Int
    var parentID: UUID?
    var parentVersionIndex: Int?
    var contextBefore: String
    var contextAfter: String
    public var lastTouched: Date
}

public struct DocumentHistory: Codable, Equatable, Sendable {
    public var passages: [HistoryPassage]
    public var isEmpty: Bool { passages.isEmpty }

    public init(passages: [HistoryPassage]) {
        self.passages = passages
    }
}

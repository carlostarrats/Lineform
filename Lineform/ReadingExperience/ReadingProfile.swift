import Foundation

enum FontID: String, Codable, Equatable, CaseIterable {
    case sfPro
    case newYork
    case jetBrainsMono
    case lexend
    case atkinsonHyperlegible
    case openDyslexic
    case comicSans
}

enum FocusMode: String, Codable, Equatable, CaseIterable {
    case off
    case currentLine
    case currentSentence
    case currentParagraph

    var displayName: String {
        switch self {
        case .off:
            return "No Focus"
        case .currentLine:
            return "Current Line"
        case .currentSentence:
            return "Current Sentence"
        case .currentParagraph:
            return "Current Paragraph"
        }
    }
}

struct ReadingProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var fontID: FontID
    var themeID: ThemeID
    var fontSize: Double
    var lineHeightMultiple: Double
    var paragraphSpacing: Double
    var letterSpacing: Double
    var columnWidth: Double
    var marginWidth: Double
    var insertionPointWidth: Double
    var focusMode: FocusMode
    var typewriterModeEnabled: Bool
    var readingRulerEnabled: Bool
    var reduceMarkdownNoise: Bool
    var highContrastEnabled: Bool
    var reduceMotionEnabled: Bool
    var adaptiveReadabilityEnabled: Bool

    mutating func applyTheme(_ themeID: ThemeID) {
        self.themeID = themeID
    }

    static let original = ReadingProfile(
        id: UUID(uuidString: "1C7B19CC-A1ED-4828-8F77-94B6769F7260")!,
        name: "Original",
        fontID: .sfPro,
        themeID: .system,
        fontSize: 17,
        lineHeightMultiple: 1.5,
        paragraphSpacing: 12,
        letterSpacing: 0.5,
        columnWidth: 820,
        marginWidth: 40,
        insertionPointWidth: 2,
        focusMode: .off,
        typewriterModeEnabled: false,
        readingRulerEnabled: false,
        reduceMarkdownNoise: false,
        highContrastEnabled: false,
        reduceMotionEnabled: false,
        adaptiveReadabilityEnabled: false
    )
}

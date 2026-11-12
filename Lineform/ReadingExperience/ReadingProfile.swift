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

    // MARK: - Automatic Dark Mode

    /// Themes that are already dark keep their own colors under Automatic Dark Mode.
    static let automaticDarkModeExemptThemes: Set<ThemeID> = [.quiet, .night]

    /// The profile the editor and preview DRAW with. With Automatic Dark Mode on and the Mac in
    /// Dark Mode, any light theme is swapped for Quiet — font, size, spacing and every other
    /// field stay the preset's own. This is a display-time copy: the stored profile keeps the
    /// user's theme (so the picker still shows their selection and Light Mode restores it), and
    /// export/print deliberately use the stored profile, never this one.
    func displayProfile(automaticDarkMode: Bool, systemIsDark: Bool) -> ReadingProfile {
        guard automaticDarkMode, systemIsDark,
              !Self.automaticDarkModeExemptThemes.contains(themeID) else {
            return self
        }
        var profile = self
        profile.themeID = .quiet
        return profile
    }

    // MARK: - Column width range

    /// Narrowest reading column the slider allows.
    static let columnWidthMinimum: Double = 460
    /// Slider maximum. The top of the slider (at or above `columnWidthFullThreshold`) means **Full**
    /// width — the reading column fills to the margins on any window size — rather than a fixed
    /// pixel width. Fixed widths run from the minimum up to just below the threshold.
    static let columnWidthMaximum: Double = 1200
    /// At or above this, the column is "Full" (unbounded → clamps to the margins), not a fixed width.
    static let columnWidthFullThreshold: Double = 1160

    /// Whether a stored column width means "Full width" (fill to the margins) rather than a fixed px.
    static func isFullWidthColumn(_ columnWidth: Double) -> Bool {
        columnWidth >= columnWidthFullThreshold
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

import Foundation

struct ReadingPreset: Equatable, Identifiable {
    var id: UUID { profile.id }
    var profile: ReadingProfile

    static let original = ReadingPreset(profile: .original)

    static let paper = ReadingPreset(profile: ReadingProfile(
        id: UUID(uuidString: "B596C72F-418E-48B1-A857-6A8D639252C8")!,
        name: "Paper",
        fontID: .newYork,
        themeID: .paper,
        fontSize: 18,
        lineHeightMultiple: 1.42,
        paragraphSpacing: 10,
        letterSpacing: 0,
        columnWidth: 640,
        marginWidth: 48,
        insertionPointWidth: 1.5,
        focusMode: .off,
        typewriterModeEnabled: false,
        readingRulerEnabled: false,
        reduceMarkdownNoise: true,
        highContrastEnabled: false,
        reduceMotionEnabled: false,
        adaptiveReadabilityEnabled: false
    ))

    static let quiet = ReadingPreset(profile: ReadingProfile(
        id: UUID(uuidString: "06D3C3F5-3165-47BB-83D4-581030358012")!,
        name: "Quiet",
        fontID: .sfPro,
        themeID: .quiet,
        fontSize: 17,
        lineHeightMultiple: 1.45,
        paragraphSpacing: 9,
        letterSpacing: 0,
        columnWidth: 700,
        marginWidth: 56,
        insertionPointWidth: 1.5,
        focusMode: .off,
        typewriterModeEnabled: false,
        readingRulerEnabled: false,
        reduceMarkdownNoise: true,
        highContrastEnabled: false,
        reduceMotionEnabled: false,
        adaptiveReadabilityEnabled: false
    ))

    static let focus = ReadingPreset(profile: ReadingProfile(
        id: UUID(uuidString: "F3130E1E-9805-4105-9787-3C7E5E1190F7")!,
        name: "Focus",
        fontID: .sfPro,
        themeID: .focus,
        fontSize: 18,
        lineHeightMultiple: 1.5,
        paragraphSpacing: 10,
        letterSpacing: 0,
        columnWidth: 620,
        marginWidth: 64,
        insertionPointWidth: 2,
        focusMode: .currentParagraph,
        typewriterModeEnabled: true,
        readingRulerEnabled: false,
        reduceMarkdownNoise: true,
        highContrastEnabled: false,
        reduceMotionEnabled: false,
        adaptiveReadabilityEnabled: false
    ))

    static let accessible = ReadingPreset(profile: ReadingProfile(
        id: UUID(uuidString: "0DF7B3A2-A29E-4EA4-AE36-CC0B26FE6B72")!,
        name: "Accessible",
        fontID: .atkinsonHyperlegible,
        themeID: .accessible,
        fontSize: 19,
        lineHeightMultiple: 1.55,
        paragraphSpacing: 12,
        letterSpacing: 0.2,
        columnWidth: 720,
        marginWidth: 56,
        insertionPointWidth: 2,
        focusMode: .off,
        typewriterModeEnabled: false,
        readingRulerEnabled: false,
        reduceMarkdownNoise: true,
        highContrastEnabled: false,
        reduceMotionEnabled: false,
        adaptiveReadabilityEnabled: false
    ))

    static let dyslexia = ReadingPreset(profile: ReadingProfile(
        id: UUID(uuidString: "3BE5704B-B4DC-468B-A1B1-28031C046946")!,
        name: "Dyslexia",
        fontID: .openDyslexic,
        themeID: .dyslexia,
        fontSize: 19,
        lineHeightMultiple: 1.6,
        paragraphSpacing: 14,
        letterSpacing: 0.25,
        columnWidth: 740,
        marginWidth: 64,
        insertionPointWidth: 2,
        focusMode: .currentLine,
        typewriterModeEnabled: false,
        readingRulerEnabled: true,
        reduceMarkdownNoise: true,
        highContrastEnabled: false,
        reduceMotionEnabled: true,
        adaptiveReadabilityEnabled: false
    ))

    static let lowLight = ReadingPreset(profile: ReadingProfile(
        id: UUID(uuidString: "5B5BAEB3-7D4E-4E2A-B1E8-0E90A8DBA292")!,
        name: "Low Light",
        fontID: .sfPro,
        themeID: .night,
        fontSize: 18,
        lineHeightMultiple: 1.45,
        paragraphSpacing: 10,
        letterSpacing: 0,
        columnWidth: 680,
        marginWidth: 52,
        insertionPointWidth: 2,
        focusMode: .off,
        typewriterModeEnabled: false,
        readingRulerEnabled: false,
        reduceMarkdownNoise: true,
        highContrastEnabled: false,
        reduceMotionEnabled: false,
        adaptiveReadabilityEnabled: false
    ))

    static let highContrast = ReadingPreset(profile: ReadingProfile(
        id: UUID(uuidString: "8C4AEBB6-80E3-40B1-8F86-AFB9F8BC8137")!,
        name: "High Contrast",
        fontID: .sfPro,
        themeID: .highContrast,
        fontSize: 18,
        lineHeightMultiple: 1.5,
        paragraphSpacing: 12,
        letterSpacing: 0,
        columnWidth: 700,
        marginWidth: 56,
        insertionPointWidth: 3,
        focusMode: .off,
        typewriterModeEnabled: false,
        readingRulerEnabled: false,
        reduceMarkdownNoise: true,
        highContrastEnabled: true,
        reduceMotionEnabled: false,
        adaptiveReadabilityEnabled: false
    ))

    static let builtIn: [ReadingPreset] = [
        .original,
        .paper,
        .quiet,
        .focus,
        .accessible,
        .dyslexia,
        .lowLight,
        .highContrast
    ]
}

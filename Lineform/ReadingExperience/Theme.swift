import AppKit

enum ThemeID: String, Codable, Equatable, CaseIterable {
    case system
    case paper
    case quiet
    case focus
    case accessible
    case dyslexia
    case lowLight
    case highContrast
}

struct Theme: Equatable, Identifiable {
    var id: ThemeID
    var name: String
    var textColor: NSColor
    var backgroundColor: NSColor
    var caretColor: NSColor

    static let system = Theme(
        id: .system,
        name: "System",
        textColor: .labelColor,
        backgroundColor: .textBackgroundColor,
        caretColor: .labelColor
    )

    static let paper = Theme(
        id: .paper,
        name: "Paper",
        textColor: NSColor(calibratedWhite: 0.12, alpha: 1),
        backgroundColor: NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.92, alpha: 1),
        caretColor: NSColor(calibratedWhite: 0.12, alpha: 1)
    )

    static let quiet = Theme(
        id: .quiet,
        name: "Quiet",
        textColor: .labelColor,
        backgroundColor: .windowBackgroundColor,
        caretColor: .labelColor
    )

    static let focus = Theme(
        id: .focus,
        name: "Focus",
        textColor: NSColor(calibratedWhite: 0.13, alpha: 1),
        backgroundColor: NSColor(calibratedWhite: 0.985, alpha: 1),
        caretColor: NSColor(calibratedWhite: 0.13, alpha: 1)
    )

    static let accessible = Theme(
        id: .accessible,
        name: "Accessible",
        textColor: NSColor(calibratedWhite: 0.05, alpha: 1),
        backgroundColor: .white,
        caretColor: NSColor(calibratedWhite: 0.05, alpha: 1)
    )

    static let dyslexia = Theme(
        id: .dyslexia,
        name: "Dyslexia",
        textColor: NSColor(calibratedWhite: 0.09, alpha: 1),
        backgroundColor: NSColor(calibratedRed: 0.99, green: 0.98, blue: 0.93, alpha: 1),
        caretColor: NSColor(calibratedWhite: 0.09, alpha: 1)
    )

    static let lowLight = Theme(
        id: .lowLight,
        name: "Low Light",
        textColor: NSColor(calibratedWhite: 0.88, alpha: 1),
        backgroundColor: NSColor(calibratedWhite: 0.09, alpha: 1),
        caretColor: NSColor(calibratedWhite: 0.88, alpha: 1)
    )

    static let highContrast = Theme(
        id: .highContrast,
        name: "High Contrast",
        textColor: .textColor,
        backgroundColor: .textBackgroundColor,
        caretColor: .textColor
    )

    static let builtIn: [Theme] = [
        .system,
        .paper,
        .quiet,
        .focus,
        .accessible,
        .dyslexia,
        .lowLight,
        .highContrast
    ]

    static func theme(for id: ThemeID) -> Theme {
        builtIn.first { $0.id == id } ?? .system
    }
}

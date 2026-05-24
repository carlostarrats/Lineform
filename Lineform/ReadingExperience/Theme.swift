import AppKit

enum ThemeID: String, Codable, Equatable, CaseIterable {
    case system
    case paper
    case quiet
    case night

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue {
        case ThemeID.system.rawValue:
            self = .system
        case ThemeID.paper.rawValue:
            self = .paper
        case ThemeID.quiet.rawValue:
            self = .quiet
        case ThemeID.night.rawValue, "lowLight":
            self = .night
        default:
            self = .system
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct Theme: Equatable, Identifiable {
    var id: ThemeID
    var name: String
    var textColor: NSColor
    var backgroundColor: NSColor
    var caretColor: NSColor

    static let system = Theme(
        id: .system,
        name: "Original",
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

    static let night = Theme(
        id: .night,
        name: "Night",
        textColor: NSColor(calibratedWhite: 0.88, alpha: 1),
        backgroundColor: NSColor(calibratedWhite: 0.09, alpha: 1),
        caretColor: NSColor(calibratedWhite: 0.88, alpha: 1)
    )

    static let builtIn: [Theme] = [
        .system,
        .paper,
        .quiet,
        .night
    ]

    static let readerThemes: [Theme] = [
        .system,
        .paper,
        .quiet,
        .night
    ]

    static func theme(for id: ThemeID) -> Theme {
        builtIn.first { $0.id == id } ?? .system
    }

    static func theme(for profile: ReadingProfile) -> Theme {
        guard profile.highContrastEnabled else {
            return theme(for: profile.themeID)
        }

        return Theme(
            id: profile.themeID,
            name: "High Contrast",
            textColor: .textColor,
            backgroundColor: .textBackgroundColor,
            caretColor: .textColor
        )
    }
}

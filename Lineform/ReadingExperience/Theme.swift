import AppKit

enum ThemeID: String, Codable, Equatable, CaseIterable {
    case system
    case paper
    case calm
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
        case ThemeID.calm.rawValue:
            self = .calm
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

    var usesDarkChrome: Bool {
        let rgb = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
        let luminance = (0.2126 * rgb.redComponent) + (0.7152 * rgb.greenComponent) + (0.0722 * rgb.blueComponent)
        return luminance < 0.45
    }

    static let system = Theme(
        id: .system,
        name: "Original",
        textColor: LineformColors.primaryText,
        backgroundColor: LineformColors.originalBackground,
        caretColor: LineformColors.primaryText
    )

    static let paper = Theme(
        id: .paper,
        name: "Paper",
        textColor: LineformColors.primaryText,
        backgroundColor: LineformColors.paperBackground,
        caretColor: LineformColors.primaryText
    )

    static let calm = Theme(
        id: .calm,
        name: "Calm",
        textColor: LineformColors.primaryText,
        backgroundColor: LineformColors.calmBackground,
        caretColor: LineformColors.primaryText
    )

    static let quiet = Theme(
        id: .quiet,
        name: "Quiet",
        textColor: NSColor(calibratedWhite: 0.86, alpha: 1),
        backgroundColor: NSColor(calibratedWhite: 0.19, alpha: 1),
        caretColor: NSColor(calibratedWhite: 0.90, alpha: 1)
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
        .calm,
        .quiet,
        .night
    ]

    static let readerThemes: [Theme] = [
        .system,
        .paper,
        .calm,
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

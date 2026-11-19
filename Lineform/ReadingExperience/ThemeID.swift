import Foundation

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

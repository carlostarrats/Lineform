import AppKit

enum FontSource: String, Codable, Equatable {
    case system
    case bundled
    case userInstalled
}

struct FontOption: Equatable, Identifiable {
    var id: FontID
    var name: String
    var familyName: String
    var source: FontSource

    static let groupedOptions: [FontOptionGroup] = [
        FontOptionGroup(
            name: "System",
            options: [
                FontOption(id: .sfPro, name: "SF Pro", familyName: ".AppleSystemUIFont", source: .system),
                FontOption(id: .newYork, name: "New York", familyName: "New York", source: .system)
            ]
        ),
        FontOptionGroup(
            name: "Writing",
            options: [
                FontOption(id: .jetBrainsMono, name: "JetBrains Mono", familyName: "JetBrains Mono", source: .bundled),
                FontOption(id: .lexend, name: "Lexend", familyName: "Lexend", source: .bundled)
            ]
        ),
        FontOptionGroup(
            name: "Reading & Accessibility",
            options: [
                FontOption(id: .atkinsonHyperlegible, name: "Atkinson Hyperlegible", familyName: "Atkinson Hyperlegible", source: .bundled),
                FontOption(id: .openDyslexic, name: "OpenDyslexic", familyName: "OpenDyslexic", source: .bundled),
                FontOption(id: .comicSans, name: "Comic Sans MS", familyName: "Comic Sans MS", source: .system)
            ]
        )
    ]

    static func option(for id: FontID) -> FontOption? {
        groupedOptions.flatMap(\.options).first { $0.id == id }
    }

    func resolvedFont(size: CGFloat) -> NSFont {
        switch id {
        case .sfPro:
            return .systemFont(ofSize: size)
        case .jetBrainsMono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            return NSFont(name: familyName, size: size) ?? .systemFont(ofSize: size)
        }
    }
}

struct FontOptionGroup: Equatable, Identifiable {
    var id: String { name }
    var name: String
    var options: [FontOption]
}

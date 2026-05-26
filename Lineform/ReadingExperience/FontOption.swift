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
                FontOption(id: .jetBrainsMono, name: "Monospaced", familyName: ".AppleSystemUIFontMonospaced", source: .system)
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

    static var availableGroupedOptions: [FontOptionGroup] {
        groupedOptions.compactMap { group in
            let options = group.options.filter(\.isAvailable)
            guard !options.isEmpty else {
                return nil
            }
            return FontOptionGroup(name: group.name, options: options)
        }
    }

    var isAvailable: Bool {
        availableFont(size: 17) != nil
    }

    func availableFont(size: CGFloat) -> NSFont? {
        switch id {
        case .sfPro:
            return .systemFont(ofSize: size)
        case .newYork:
            return NSFont(name: familyName, size: size) ?? systemSerifFont(size: size)
        case .jetBrainsMono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            return NSFont(name: familyName, size: size)
        }
    }

    func resolvedFont(size: CGFloat) -> NSFont {
        availableFont(size: size) ?? .systemFont(ofSize: size)
    }

    private func systemSerifFont(size: CGFloat) -> NSFont? {
        if #available(macOS 11.0, *) {
            return NSFont
                .systemFont(ofSize: size)
                .fontDescriptor
                .withDesign(.serif)
                .flatMap { NSFont(descriptor: $0, size: size) }
        }
        return nil
    }
}

struct FontOptionGroup: Equatable, Identifiable {
    var id: String { name }
    var name: String
    var options: [FontOption]
}

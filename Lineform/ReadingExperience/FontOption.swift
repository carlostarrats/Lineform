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

    /// The option every unrecognized `FontID` falls back to. Declared separately from
    /// `groupedOptions` so it can never itself be nil.
    static let defaultOption = FontOption(id: .sfPro, name: "SF Pro", familyName: ".AppleSystemUIFont", source: .system)

    static let groupedOptions: [FontOptionGroup] = [
        FontOptionGroup(
            name: String(localized: "System"),
            options: [
                defaultOption,
                FontOption(id: .newYork, name: "New York", familyName: "New York", source: .system)
            ]
        ),
        FontOptionGroup(
            name: String(localized: "Writing"),
            options: [
                // "Monospaced" describes the typeface's role; it is not a typeface NAME like "SF Pro",
                // so unlike its siblings it localizes.
                FontOption(id: .jetBrainsMono, name: String(localized: "Monospaced"), familyName: ".AppleSystemUIFontMonospaced", source: .system)
            ]
        ),
        FontOptionGroup(
            name: String(localized: "Reading & Accessibility"),
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

    /// The option to actually RENDER with — never nil, so no call site needs a bare-font tail.
    ///
    /// A `FontID` can be RETIRED: still declared in the enum so persisted `ReadingProfile`s keep
    /// decoding, but removed from `groupedOptions` so it is no longer offered. `.lexend` is one
    /// today. `option(for:)` returns nil for those, and the three render sites' old
    /// `?? .systemFont(…)` tails then produced an UNCASCADED face — a profile persisted from a
    /// build where Lexend was selectable rendered CJK by per-glyph substitution while every other
    /// profile went through the declared cascade.
    ///
    /// Substituting the whole default OPTION rather than just a font also fixes the retired id's
    /// other properties, and makes the next retirement safe by construction.
    static func resolved(for id: FontID) -> FontOption {
        option(for: id) ?? defaultOption
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
        // The cascade is attached AFTER resolution, never via the family descriptor: a bogus
        // family must still resolve to nil, which is what `isAvailable` reads.
        switch id {
        case .sfPro:
            return MarkdownFontCascade.applying(to: .systemFont(ofSize: size))
        case .newYork:
            // The wrap covers the whole expression, not just the `NSFont(name:)` half —
            // `NSFont(name: "New York")` returns nil on macOS 26, so in practice it is always the
            // `systemSerifFont` branch that ships.
            return (NSFont(name: familyName, size: size) ?? systemSerifFont(size: size))
                .map(MarkdownFontCascade.applying(to:))
        case .jetBrainsMono:
            return MarkdownFontCascade.applying(to: .monospacedSystemFont(ofSize: size, weight: .regular))
        default:
            return NSFont(name: familyName, size: size).map(MarkdownFontCascade.applying(to:))
        }
    }

    func resolvedFont(size: CGFloat) -> NSFont {
        // The fallback is cascaded too: an unavailable font is the case MOST likely to be
        // rendering someone else's script.
        availableFont(size: size) ?? MarkdownFontCascade.applying(to: .systemFont(ofSize: size))
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

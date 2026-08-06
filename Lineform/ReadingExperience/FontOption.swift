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
    /// today. `option(for:)` returns nil for those, and a profile persisted from a build where
    /// Lexend was selectable used to reach the bare `?? .systemFont(…)` tail at each of the
    /// three render sites.
    ///
    /// That tail is NOT a live defect. `defaultOption` is SF Pro and its `availableFont` IS
    /// `.systemFont(ofSize:)`, so `option(for:)?.resolvedFont(size:) ?? .systemFont(size)` and
    /// `resolved(for:).resolvedFont(size:)` produce the same face for every declared `FontID`,
    /// retired or not — asserted by `testRetiredFontIDRendersTheSameFaceAsTheOldBareFontTail`.
    /// The picker agrees too: `ReadingExperienceInspector.visibleFontID` already shows the default
    /// for a retired id. The two only diverged while the (since removed) `MarkdownFontCascade`
    /// was attached — the tail produced an UNCASCADED face while every other font in the app got
    /// a cascade, which is how the gap was found in the first place.
    ///
    /// So this is kept as FORWARD INSURANCE, not as a fix for anything a user can see today:
    /// substituting the whole default OPTION also corrects the retired id's other properties, it
    /// makes the next retirement structurally incapable of reintroducing that divergence, and it
    /// deletes three copies of a fallback that otherwise has to be right independently.
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

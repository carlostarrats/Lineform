import CoreGraphics
import Foundation

public enum FontSource: String, Codable, Equatable, Sendable {
    case system
    case bundled
    case userInstalled
}

public struct FontOption: Equatable, Identifiable, Sendable {
    public var id: FontID
    public var name: String
    public var familyName: String
    public var source: FontSource

    public init(id: FontID, name: String, familyName: String, source: FontSource) {
        self.id = id
        self.name = name
        self.familyName = familyName
        self.source = source
    }

    /// The option every unrecognized `FontID` falls back to. Declared separately from
    /// `groupedOptions` so it can never itself be nil.
    public static let defaultOption = FontOption(id: .sfPro, name: "SF Pro", familyName: ".AppleSystemUIFont", source: .system)

    public static let groupedOptions: [FontOptionGroup] = [
        FontOptionGroup(
            name: String(localized: "System", bundle: .module),
            options: [
                defaultOption,
                FontOption(id: .newYork, name: "New York", familyName: "New York", source: .system),
                // "Monospaced" describes the typeface's role; it is not a typeface NAME like "SF Pro",
                // so unlike its siblings it localizes. The id stays `.jetBrainsMono` (persisted).
                FontOption(id: .jetBrainsMono, name: String(localized: "Monospaced", bundle: .module), familyName: ".AppleSystemUIFontMonospaced", source: .system)
            ]
        ),
        FontOptionGroup(
            name: String(localized: "Reading & Accessibility", bundle: .module),
            options: [
                FontOption(id: .atkinsonHyperlegible, name: "Atkinson Hyperlegible", familyName: "Atkinson Hyperlegible", source: .bundled),
                FontOption(id: .openDyslexic, name: "OpenDyslexic", familyName: "OpenDyslexic", source: .bundled),
                FontOption(id: .comicSans, name: "Comic Sans MS", familyName: "Comic Sans MS", source: .system)
            ]
        )
    ]

    public static func option(for id: FontID) -> FontOption? {
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
    public static func resolved(for id: FontID) -> FontOption {
        option(for: id) ?? defaultOption
    }

    public static var availableGroupedOptions: [FontOptionGroup] {
        groupedOptions.compactMap { group in
            let options = group.options.filter(\.isAvailable)
            guard !options.isEmpty else {
                return nil
            }
            return FontOptionGroup(name: group.name, options: options)
        }
    }

    public var isAvailable: Bool {
        availableFont(size: 17) != nil
    }

    public func availableFont(size: CGFloat) -> PlatformFont? {
        switch id {
        case .sfPro:
            return .systemFont(ofSize: size)
        case .newYork:
            return PlatformFont(name: familyName, size: size) ?? systemSerifFont(size: size)
        case .jetBrainsMono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            return PlatformFont(name: familyName, size: size)
        }
    }

    public func resolvedFont(size: CGFloat) -> PlatformFont {
        availableFont(size: size) ?? .systemFont(ofSize: size)
    }

    /// macOS: `NSFontDescriptor.withDesign(.serif)`; iOS: `UIFontDescriptor.withDesign(.serif)`.
    private func systemSerifFont(size: CGFloat) -> PlatformFont? {
        if #available(macOS 11.0, *) {
            return PlatformFont
                .systemFont(ofSize: size)
                .fontDescriptor
                .withDesign(.serif)
                .flatMap { PlatformFont(descriptor: $0, size: size) }
        }
        return nil
    }
}

public struct FontOptionGroup: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var options: [FontOption]
}

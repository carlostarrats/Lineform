import AppKit

/// The ONE definition of what a Lineform font falls back to for CJK text.
///
/// What the cascade is FOR: an explicit `.cascadeList` is a value the app owns, so it survives the
/// places where the implicit system fallback does not — chiefly `convert(_:toHaveTrait:)` below,
/// and the descriptor re-derivations behind headings, table cells, and the export/print faces.
/// It is what makes screen and export agree instead of each re-deriving a face on its own.
///
/// What it is NOT for: overriding CoreText's choice of Han face. Measured on macOS 26 with
/// `CTFontCreateForString`, the implicit substitution is NOT unchosen — it is locale-informed, and
/// on an `en` machine it already resolves every sample below (Chinese and Japanese alike) to
/// PingFang SC. An earlier revision of this file declared a fixed `["Hiragino Sans", "PingFang SC"]`
/// on the theory that the pairing was arbitrary. It was not: that order rendered PURE CHINESE in a
/// Japanese face for every character the two scripts share — which is most of a Chinese sentence,
/// and is exactly the failure the cascade was introduced to prevent. Flipping it fixed nothing; it
/// only moved the same harm onto Japanese.
///
/// So the order is DERIVED, from the one signal the platform gives us about who is reading:
/// `Bundle.main.preferredLocalizations`. A Japanese interface gets Hiragino Sans first; every other
/// interface — including Simplified Chinese, and including the five non-CJK languages we ship —
/// gets PingFang SC first, which is what the unmodified platform already does. Not
/// `Locale.language.languageCode`: it collapses `zh-Hans` to `zh` (standing invariant in Claude.md).
///
/// The subtlety is `convert(_:toHaveTrait:)`. Measured on macOS 26: `NSFontManager` PRESERVES an
/// attached `.cascadeList` for real named families (Helvetica, Atkinson Hyperlegible) and DROPS
/// it for `.systemFont`, `.monospacedSystemFont`, and `withDesign(.serif)` — which are exactly
/// the fonts most users read. Every trait conversion in the app therefore goes through
/// `convert(_:toHaveTrait:)` below, never `NSFontManager` directly.
enum MarkdownFontCascade {

    /// Both ship with macOS, and the list is always these two in one of two orders — the COUNT is
    /// invariant, only the order is derived, so nothing downstream has to reason about language.
    static let japaneseFirst = ["Hiragino Sans", "PingFang SC"]
    static let simplifiedChineseFirst = ["PingFang SC", "Hiragino Sans"]

    /// The order for a given set of preferred localizations, as `Bundle` reports them
    /// (`["ja"]`, `["zh-Hans"]`, `["en"]`, …). Pure, so it is testable without relaunching the app
    /// under another language.
    ///
    /// `simplifiedChineseFirst` is the default rather than a neutral "no opinion" because it IS the
    /// platform's existing resolution on a non-CJK machine — a default that changed it would be the
    /// regression, not the fix.
    static func resolvedFallbackFamilies(preferring localizations: [String]) -> [String] {
        let language = localizations.first?.split(separator: "-").first.map(String.init)?.lowercased()
        return language == "ja" ? japaneseFirst : simplifiedChineseFirst
    }

    static let fallbackFamilies = resolvedFallbackFamilies(preferring: Bundle.main.preferredLocalizations)

    private nonisolated(unsafe) static let descriptors: [NSFontDescriptor] = fallbackFamilies.map {
        NSFontDescriptor(fontAttributes: [.family: $0])
    }

    /// Returns `font` with the fallback list attached. Returns the input unchanged if the
    /// descriptor cannot be realized — a font without the cascade is degraded, not broken, and
    /// this must never be the reason text fails to draw.
    static func applying(to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: descriptors])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// `NSFontManager.convert` plus re-attachment. Use this everywhere instead of
    /// `NSFontManager.shared.convert(_:toHaveTrait:)`.
    static func convert(_ font: NSFont, toHaveTrait trait: NSFontTraitMask) -> NSFont {
        applying(to: NSFontManager.shared.convert(font, toHaveTrait: trait))
    }

    /// Cascaded monospaced faces, memoized by point size.
    ///
    /// `applying(to:)` builds a descriptor and realizes a font. The editor's code-span and
    /// code-fence tokens run it inside the debounced per-keystroke highlight loop — once per
    /// token, so a fenced block costs one realization per line. The face depends on nothing but
    /// the point size, so it is cached. Use this instead of `applying(to: .monospacedSystemFont(…))`.
    ///
    /// `NSCache` is thread-safe on its own, which is why this needs no lock of its own.
    private nonisolated(unsafe) static let monospacedCache = NSCache<NSNumber, NSFont>()

    static func monospaced(ofSize size: CGFloat) -> NSFont {
        let key = NSNumber(value: Double(size))
        if let cached = monospacedCache.object(forKey: key) {
            return cached
        }
        let font = applying(to: .monospacedSystemFont(ofSize: size, weight: .regular))
        monospacedCache.setObject(font, forKey: key)
        return font
    }
}

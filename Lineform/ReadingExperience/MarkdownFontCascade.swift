import AppKit

/// The ONE definition of what a Lineform font falls back to for CJK text.
///
/// Without an explicit cascade list CoreText substitutes per glyph, so the pairing is unchosen
/// and a mixed Chinese/Japanese document can render Chinese in a Japanese face. Declaring it
/// costs nothing and makes the choice ours.
///
/// The subtlety is `convert(_:toHaveTrait:)`. Measured on macOS 26: `NSFontManager` PRESERVES an
/// attached `.cascadeList` for real named families (Helvetica, Atkinson Hyperlegible) and DROPS
/// it for `.systemFont`, `.monospacedSystemFont`, and `withDesign(.serif)` — which are exactly
/// the fonts most users read. Every trait conversion in the app therefore goes through
/// `convert(_:toHaveTrait:)` below, never `NSFontManager` directly.
enum MarkdownFontCascade {

    /// Both ship with macOS. Order matters: CoreText walks the list, so Japanese resolves before
    /// Simplified Chinese for Han characters the two share.
    static let fallbackFamilies = ["Hiragino Sans", "PingFang SC"]

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
}

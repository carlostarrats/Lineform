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

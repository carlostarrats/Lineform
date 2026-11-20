import CoreGraphics

/// Fixed two-variant INK for block MATH, keyed only on light-vs-dark (never the specific theme) so
/// block math — which renders transparent — never re-renders on a theme switch. Block Mermaid
/// diagrams instead use the actual per-theme page color (they must, so Mermaid's node boxes get a
/// solid fill that matches every theme); the memory-sized cache keeps that affordable. Inline math
/// is unaffected (fully theme-aware).
public enum DiagramPalette {
    /// Ink for block math: the Original theme's text on light themes, the Quiet theme's on dark
    /// themes — so dark ink only ever lands on a light page and light ink only on a dark page. (All
    /// light themes share the Original text color and both dark themes are near-identical, so this
    /// matches surrounding prose on every theme while staying theme-independent.)
    public static func ink(isDark: Bool) -> PlatformColor {
        (isDark ? Theme.quiet : Theme.system).textColor
    }
}

/// Muted, monochrome-leaning token colors for fenced-code highlighting in Read/Preview. Derived
/// from the theme (light/dark aware), restrained so code reads calm rather than rainbow. `.plain`
/// reuses the theme's own text color (unchanged code foreground). Every colored role is AA-verified
/// against every `Theme.builtIn` background (`CodeSyntaxPaletteContrastTests`). Display-only.
public enum CodeSyntaxPalette {
    public static func color(for kind: CodeTokenKind, theme: Theme) -> PlatformColor {
        let dark = theme.usesDarkChrome
        switch kind {
        case .plain:
            return theme.textColor
        case .keyword:
            // A muted plum/violet — the one role allowed a little hue.
            return dark ? PlatformColor.lineformSRGB(red: 0.78, green: 0.62, blue: 0.86, alpha: 1)
                        : PlatformColor.lineformSRGB(red: 0.42, green: 0.24, blue: 0.55, alpha: 1)
        case .string:
            // Muted green.
            return dark ? PlatformColor.lineformSRGB(red: 0.55, green: 0.80, blue: 0.60, alpha: 1)
                        : PlatformColor.lineformSRGB(red: 0.16, green: 0.44, blue: 0.24, alpha: 1)
        case .comment:
            // Low-chroma grey — deliberately the quietest role, still AA.
            return dark ? PlatformColor.lineformSRGB(red: 0.68, green: 0.70, blue: 0.70, alpha: 1)
                        : PlatformColor.lineformSRGB(red: 0.42, green: 0.44, blue: 0.44, alpha: 1)
        case .number:
            // Muted amber/brown.
            return dark ? PlatformColor.lineformSRGB(red: 0.85, green: 0.70, blue: 0.48, alpha: 1)
                        : PlatformColor.lineformSRGB(red: 0.55, green: 0.38, blue: 0.12, alpha: 1)
        case .type:
            // Muted teal/blue.
            return dark ? PlatformColor.lineformSRGB(red: 0.55, green: 0.76, blue: 0.82, alpha: 1)
                        : PlatformColor.lineformSRGB(red: 0.15, green: 0.40, blue: 0.50, alpha: 1)
        }
    }
}

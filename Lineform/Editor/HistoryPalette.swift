import AppKit

/// The colours History mode draws with in the editor. Every one is derived from the theme's own
/// ink and page (the `Theme.readableInk` approach), so a theme change — including Automatic Dark
/// Mode's display-time swap to Quiet, which reaches the text view as its applied profile — moves
/// the palette with it. Values follow the History-mode mockup
/// (`docs/superpowers/specs/2026-11-12-history-mode-mockup.html`).
///
/// The three tints are TRANSLUCENT fills drawn behind full-ink text; `HistoryPaletteTests` asserts
/// the ink keeps ≥ 4.5:1 against each tint flattened onto the page, on every built-in theme.
enum HistoryPalette {
    /// A passage that has history: a light wash of the theme's own ink.
    static let tintAlpha: CGFloat = 0.06
    /// The passage under the pointer: a slightly stronger wash. Preview only.
    static let hoverTintAlpha: CGFloat = 0.11
    /// The selected passage: the system blue, resolved for the theme's light/dark appearance.
    static let selectionTintAlpha: CGFloat = 0.24
    /// Unchanged text recedes to this share of the ink before the readability floor is applied.
    static let recededInkAlpha: CGFloat = 0.45
    /// Receded text is de-emphasised, not hidden: it keeps at least this ratio against the page.
    static let recededInkMinimumRatio: CGFloat = 3.0
    /// Version dots, a graphical affordance: WCAG's 3:1 non-text floor.
    static let dotInkAlpha: CGFloat = 0.55
    static let dotInkMinimumRatio: CGFloat = 3.0

    static func tint(for theme: Theme) -> NSColor {
        ink(of: theme).withAlphaComponent(tintAlpha)
    }

    static func hoverTint(for theme: Theme) -> NSColor {
        ink(of: theme).withAlphaComponent(hoverTintAlpha)
    }

    static func selectionTint(for theme: Theme) -> NSColor {
        systemBlue(for: theme).withAlphaComponent(selectionTintAlpha)
    }

    static func recededInk(for theme: Theme) -> NSColor {
        theme.readableInk(
            ink(of: theme).withAlphaComponent(recededInkAlpha),
            minimumRatio: recededInkMinimumRatio
        )
    }

    static func dotInk(for theme: Theme) -> NSColor {
        theme.readableInk(
            ink(of: theme).withAlphaComponent(dotInkAlpha),
            minimumRatio: dotInkMinimumRatio
        )
    }

    /// `tint` composited onto the theme's page, as an OPAQUE colour. The hover and selection
    /// fills are drawn this way, last, so they REPLACE whatever nested washes lie beneath rather
    /// than stacking on them: three nested 6% washes under a translucent blue fell to 4.19:1 on
    /// Quiet. The selected passage therefore always sits on exactly page + blue — the pair the
    /// 4.5:1 test measures.
    static func opaqueFill(_ tint: NSColor, for theme: Theme) -> NSColor {
        let top = tint.usingColorSpace(.sRGB) ?? tint
        let page = resolved(theme.backgroundColor, for: theme)
        let alpha = top.alphaComponent
        func blend(_ base: CGFloat, _ over: CGFloat) -> CGFloat { base + (over - base) * alpha }
        return NSColor(
            srgbRed: blend(page.redComponent, top.redComponent),
            green: blend(page.greenComponent, top.greenComponent),
            blue: blend(page.blueComponent, top.blueComponent),
            alpha: 1
        )
    }

    private static func ink(of theme: Theme) -> NSColor {
        resolved(theme.textColor, for: theme)
    }

    private static func systemBlue(for theme: Theme) -> NSColor {
        resolved(.systemBlue, for: theme)
    }

    /// A dynamic colour (the high-contrast theme's `.textColor`, `.systemBlue`) resolved for the
    /// THEME's appearance — never the system's, which is not what the window is drawn in.
    private static func resolved(_ color: NSColor, for theme: Theme) -> NSColor {
        let appearance = NSAppearance(named: theme.usesDarkChrome ? .darkAqua : .aqua)
        var result = color
        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB) ?? color
            }
        } else {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }
}

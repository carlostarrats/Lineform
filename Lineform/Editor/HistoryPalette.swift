import AppKit

/// The colours History mode draws with in the editor. Every one is derived from the theme's own
/// ink and page (the `Theme.readableInk` approach), so a theme change — including Automatic Dark
/// Mode's display-time swap to Quiet, which reaches the text view as its applied profile — moves
/// the palette with it. Values follow the History-mode mockup
/// (`docs/superpowers/specs/2026-11-12-history-mode-mockup.html`).
///
/// The two tints are TRANSLUCENT fills drawn behind full-ink text; `HistoryPaletteTests` asserts
/// the ink keeps ≥ 4.5:1 against each tint flattened onto the page, on every built-in theme.
///
/// Focus (a passage clicked) carries no fill: the focused passage and its counter keep the full
/// ink (≥ 4.5:1), other passages fall to `focusOtherInk`, unchanged text to `deepRecededInk`.
/// The receded inks are de-emphasis, not body text; each keeps a documented floor.
enum HistoryPalette {
    /// A passage that has history: a light wash of the theme's own ink.
    static let tintAlpha: CGFloat = 0.06
    /// The passage under the pointer: a slightly stronger wash. Preview only.
    static let hoverTintAlpha: CGFloat = 0.11
    /// Unchanged text recedes to this share of the ink before the readability floor is applied.
    static let recededInkAlpha: CGFloat = 0.45
    /// Receded text is de-emphasised, not hidden: it keeps at least this ratio against the page.
    static let recededInkMinimumRatio: CGFloat = 3.0
    /// While a passage is focused: the OTHER passages (the hovered one uses `recededInk`, so it
    /// still reads as clickable).
    static let focusOtherInkAlpha: CGFloat = 0.38
    static let focusOtherInkMinimumRatio: CGFloat = 2.5
    /// While a passage is focused: unchanged text, receded further.
    static let deepRecededInkAlpha: CGFloat = 0.22
    static let deepRecededInkMinimumRatio: CGFloat = 2.0

    static func tint(for theme: Theme) -> NSColor {
        ink(of: theme).withAlphaComponent(tintAlpha)
    }

    static func hoverTint(for theme: Theme) -> NSColor {
        ink(of: theme).withAlphaComponent(hoverTintAlpha)
    }

    static func recededInk(for theme: Theme) -> NSColor {
        theme.readableInk(
            ink(of: theme).withAlphaComponent(recededInkAlpha),
            minimumRatio: recededInkMinimumRatio
        )
    }

    static func focusOtherInk(for theme: Theme) -> NSColor {
        theme.readableInk(
            ink(of: theme).withAlphaComponent(focusOtherInkAlpha),
            minimumRatio: focusOtherInkMinimumRatio
        )
    }

    static func deepRecededInk(for theme: Theme) -> NSColor {
        theme.readableInk(
            ink(of: theme).withAlphaComponent(deepRecededInkAlpha),
            minimumRatio: deepRecededInkMinimumRatio
        )
    }

    /// The AI review's replacement highlight (spec "AI review: option A"; the mockup's
    /// `--washStrong`): the system accent blue washed over the page, stronger on a dark page,
    /// where the same alpha reads weaker. Returned OPAQUE (`opaqueFill`), so what is drawn is
    /// exactly the pair `HistoryPaletteTests` measures: visibly off the page (≥ 1.15:1) with the
    /// text on it at AA, on every built-in theme.
    static let reviewInsertAccent = NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
    static let reviewInsertAlphaLight: CGFloat = 0.14
    static let reviewInsertAlphaDark: CGFloat = 0.26

    static func reviewInsertTint(for theme: Theme) -> NSColor {
        let alpha = theme.usesDarkChrome ? reviewInsertAlphaDark : reviewInsertAlphaLight
        return opaqueFill(reviewInsertAccent.withAlphaComponent(alpha), for: theme)
    }

    /// The focused passage's counter: the theme's full ink, like the passage it labels.
    static func counterInk(for theme: Theme) -> NSColor {
        theme.readableInk(ink(of: theme), minimumRatio: 4.5)
    }

    /// `tint` composited onto the theme's page, as an OPAQUE colour. The hover fill is drawn this
    /// way, last, so it REPLACES whatever nested washes lie beneath rather than stacking on them
    /// (stacked translucent fills once fell to 4.19:1 on Quiet). The hovered passage therefore
    /// always sits on exactly page + hover — the pair the 4.5:1 test measures.
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

    /// A dynamic colour (the high-contrast theme's `.textColor`) resolved for the
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

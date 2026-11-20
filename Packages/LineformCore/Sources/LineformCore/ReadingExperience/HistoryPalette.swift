import CoreGraphics
import Foundation

/// The colours History mode draws with in the editor. Every one is derived from the theme's own
/// ink and page (the `Theme.readableInk` approach), so a theme change — including Automatic Dark
/// Mode's display-time swap to Quiet, which reaches the text view as its applied profile — moves
/// the palette with it. Values follow the History-mode mockup
/// (`docs/superpowers/specs/2026-11-12-history-mode-mockup.html`).
///
/// The wash and hover tints are drawn behind full-ink text; `HistoryPaletteTests` asserts the ink
/// keeps ≥ 4.5:1 against each (the wash stacked three deep), on every built-in theme.
///
/// Focus (a passage clicked): the focused passage and its counter keep the full ink (≥ 4.5:1) and
/// no fill. The OTHER passages stay visibly highlighted — `focusOtherTint` (opaque, ≥ 1.15:1 off
/// the page) under `focusOtherInk` (≥ 3:1 on that tint) — and hovering one brings it to full
/// strength (full ink on the opaque hover fill). Unchanged text falls to `deepRecededInk`.
/// The receded inks are de-emphasis, not body text; each keeps a documented floor.
public enum HistoryPalette {
    /// A passage that has history: a light wash of the theme's own ink. 0.08 is the lightest wash
    /// that clears 1.15:1 off the page on the light themes; three nested washes still keep AA on
    /// Quiet (0.09 does not).
    public static let tintAlpha: CGFloat = 0.08
    /// The passage under the pointer: a stronger wash, drawn opaque. Preview only.
    public static let hoverTintAlpha: CGFloat = 0.15
    /// Unchanged text recedes to this share of the ink before the readability floor is applied.
    public static let recededInkAlpha: CGFloat = 0.45
    /// Receded text is de-emphasised, not hidden: it keeps at least this ratio against the page.
    public static let recededInkMinimumRatio: CGFloat = 3.0
    /// While a passage is focused: the OTHER passages' fill. Owner (QA 1.8): "dark enough for
    /// accessibility … it can't be too faint" — so stronger than the unfocused wash.
    public static let focusOtherTintAlpha: CGFloat = 0.10
    /// While a passage is focused: the OTHER passages' ink, measured ON `focusOtherTint`.
    public static let focusOtherInkAlpha: CGFloat = 0.38
    public static let focusOtherInkMinimumRatio: CGFloat = 3.0
    /// While a passage is focused: unchanged text, receded further.
    public static let deepRecededInkAlpha: CGFloat = 0.22
    public static let deepRecededInkMinimumRatio: CGFloat = 2.0

    // MARK: - Mark (2026-11-13)

    /// Mark's sentences: an OPAQUE wash of the theme's ink, stronger on a dark page, where the
    /// History tint (translucent, 0.08) was barely visible. At least as far off the page as the
    /// History tint, with the text on it at AA (`HistoryPaletteTests`).
    public static let markWashAlphaLight: CGFloat = 0.12
    public static let markWashAlphaDark: CGFloat = 0.20

    public static func markWash(for theme: Theme) -> PlatformColor {
        let alpha = theme.usesDarkChrome ? markWashAlphaDark : markWashAlphaLight
        return opaqueFill(ink(of: theme).withAlphaComponent(alpha), for: theme)
    }

    // MARK: - Layers (2026-11-13)

    /// Nested passages draw as LAYERED rounded boxes (the mockup's `.h .h`): each depth adds one
    /// more layer of its tint, composited OPAQUE so what is drawn is exactly what the AA tests
    /// measure. Deeper than this reuses the deepest layer.
    public static let maximumLayerDepth = 3
    /// The boxes' corner radius (the mockup's 3px).
    public static let layerCornerRadius: CGFloat = 3
    /// The selected passage: the system accent blue (the mockup's `.sel`), stronger on a dark page.
    public static let selectedAlphaLight: CGFloat = 0.20
    public static let selectedAlphaDark: CGFloat = 0.30
    /// A passage nested INSIDE the selected one: one ink layer per depth over the blue, so it still
    /// reads as its own box.
    public static let selectedChildTintAlpha: CGFloat = 0.07
    /// Each nested wash past the first adds this much (the first is `tintAlpha`): three full
    /// 0.08 washes sit right at AA on Quiet, leaving no room for hover to brighten a depth-3 box.
    public static let nestedTintAlpha: CGFloat = 0.05
    /// Hover adds this over the passage's own wash, so it always brightens it.
    public static let hoverStepAlpha: CGFloat = 0.07

    /// `alpha` stacked `depth` times (1…`maximumLayerDepth`).
    public static func layeredAlpha(_ alpha: CGFloat, depth: Int) -> CGFloat {
        1 - pow(1 - alpha, CGFloat(min(max(depth, 1), maximumLayerDepth)))
    }

    /// Nothing selected: a passage at `depth` (1 = outermost) — `tint` stacked `depth` deep.
    public static func washFill(for theme: Theme, depth: Int) -> PlatformColor {
        opaqueFill(ink(of: theme).withAlphaComponent(washAlpha(depth: depth)), for: theme)
    }

    /// The overview wash's alpha at `depth`: `tintAlpha`, then `nestedTintAlpha` per extra layer.
    public static func washAlpha(depth: Int) -> CGFloat {
        1 - (1 - tintAlpha) * (1 - layeredAlpha(nestedTintAlpha, depth: depth - 1) * (depth > 1 ? 1 : 0))
    }

    /// The hovered passage at `depth`: its own wash plus `hoverStepAlpha`.
    public static func hoverFill(for theme: Theme, depth: Int) -> PlatformColor {
        let alpha = 1 - (1 - washAlpha(depth: depth)) * (1 - hoverStepAlpha)
        return opaqueFill(ink(of: theme).withAlphaComponent(alpha), for: theme)
    }

    /// A passage selected: every OTHER passage at `depth`, `focusOtherTintAlpha` stacked.
    public static func focusOtherFill(for theme: Theme, depth: Int) -> PlatformColor {
        opaqueFill(ink(of: theme).withAlphaComponent(layeredAlpha(focusOtherTintAlpha, depth: depth)), for: theme)
    }

    /// The other passages' ink at `depth`, measured on that depth's fill (≥ 3:1).
    public static func focusOtherInk(for theme: Theme, depth: Int) -> PlatformColor {
        theme.readableInk(
            ink(of: theme).withAlphaComponent(focusOtherInkAlpha),
            minimumRatio: focusOtherInkMinimumRatio,
            on: focusOtherFill(for: theme, depth: depth)
        )
    }

    /// The selected passage's box: accent blue over the page, opaque.
    public static func selectedFill(for theme: Theme) -> PlatformColor {
        let alpha = theme.usesDarkChrome ? selectedAlphaDark : selectedAlphaLight
        return opaqueFill(reviewInsertAccent.withAlphaComponent(alpha), for: theme)
    }

    /// A passage `depth` levels inside the selected one (1 = its direct child): ink layers over
    /// the blue, opaque.
    public static func selectedChildFill(for theme: Theme, depth: Int) -> PlatformColor {
        composite(ink(of: theme).withAlphaComponent(layeredAlpha(selectedChildTintAlpha, depth: depth)),
                  over: selectedFill(for: theme))
    }

    /// `top` composited over the opaque `base`.
    public static func composite(_ top: PlatformColor, over base: PlatformColor) -> PlatformColor {
        let t = top.lineformSRGBComponentsOrOwn
        let b = base.lineformSRGBComponentsOrOwn
        let alpha = t.alpha
        func blend(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * alpha }
        return PlatformColor.lineformSRGB(red: blend(b.red, t.red), green: blend(b.green, t.green),
                                          blue: blend(b.blue, t.blue), alpha: 1)
    }

    public static func tint(for theme: Theme) -> PlatformColor {
        ink(of: theme).withAlphaComponent(tintAlpha)
    }

    public static func hoverTint(for theme: Theme) -> PlatformColor {
        ink(of: theme).withAlphaComponent(hoverTintAlpha)
    }

    public static func recededInk(for theme: Theme) -> PlatformColor {
        theme.readableInk(
            ink(of: theme).withAlphaComponent(recededInkAlpha),
            minimumRatio: recededInkMinimumRatio
        )
    }

    /// Opaque (`opaqueFill`), so nested passages never stack and what is drawn is exactly the
    /// pair `HistoryPaletteTests` measures.
    public static func focusOtherTint(for theme: Theme) -> PlatformColor {
        opaqueFill(ink(of: theme).withAlphaComponent(focusOtherTintAlpha), for: theme)
    }

    public static func focusOtherInk(for theme: Theme) -> PlatformColor {
        theme.readableInk(
            ink(of: theme).withAlphaComponent(focusOtherInkAlpha),
            minimumRatio: focusOtherInkMinimumRatio,
            on: focusOtherTint(for: theme)
        )
    }

    public static func deepRecededInk(for theme: Theme) -> PlatformColor {
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
    public static let reviewInsertAccent = PlatformColor.lineformSRGB(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
    public static let reviewInsertAlphaLight: CGFloat = 0.14
    public static let reviewInsertAlphaDark: CGFloat = 0.26

    /// Proofread's OTHER pending corrections (the current one is on `reviewInsertTint`): a lighter
    /// wash of the same blue, still visibly off the page, text AA on it.
    public static let reviewInsertOtherAlphaLight: CGFloat = 0.07
    public static let reviewInsertOtherAlphaDark: CGFloat = 0.14

    public static func reviewInsertOtherTint(for theme: Theme) -> PlatformColor {
        let alpha = theme.usesDarkChrome ? reviewInsertOtherAlphaDark : reviewInsertOtherAlphaLight
        return opaqueFill(reviewInsertAccent.withAlphaComponent(alpha), for: theme)
    }

    public static func reviewInsertTint(for theme: Theme) -> PlatformColor {
        let alpha = theme.usesDarkChrome ? reviewInsertAlphaDark : reviewInsertAlphaLight
        return opaqueFill(reviewInsertAccent.withAlphaComponent(alpha), for: theme)
    }

    /// `ink` as the review overlay draws it inside a replacement: it keeps on the tint the
    /// contrast it had on the page, up to AA. `readableInk` sets the link ink at 4.5:1 against
    /// the PAGE, so any visible tint takes it (and, on Quiet, inline code) under AA — and no tint
    /// light enough to fix that is still visible. Body text already reads on the tint and comes
    /// back as the same object; deliberately muted inks (Markdown markers) stay as muted as they
    /// were rather than being raised to AA.
    public static func reviewReplacementInk(_ ink: PlatformColor, for theme: Theme, on tint: PlatformColor? = nil) -> PlatformColor {
        let tint = tint ?? reviewInsertTint(for: theme)
        let target = min(4.5, Theme.contrastRatio(ink, theme.backgroundColor))
        guard Theme.contrastRatio(ink, tint) < target else { return ink }
        return theme.readableInk(ink, minimumRatio: target, on: tint)
    }

    /// The focused passage's counter: the theme's full ink, like the passage it labels.
    public static func counterInk(for theme: Theme) -> PlatformColor {
        theme.readableInk(ink(of: theme), minimumRatio: 4.5)
    }

    /// `tint` composited onto the theme's page, as an OPAQUE colour. The hover fill is drawn this
    /// way, last, so it REPLACES whatever nested washes lie beneath rather than stacking on them
    /// (stacked translucent fills once fell to 4.19:1 on Quiet). The hovered passage therefore
    /// always sits on exactly page + hover — the pair the 4.5:1 test measures.
    public static func opaqueFill(_ tint: PlatformColor, for theme: Theme) -> PlatformColor {
        let top = tint.lineformSRGBComponentsOrOwn
        let page = resolved(theme.backgroundColor, for: theme).lineformSRGBComponentsOrOwn
        let alpha = top.alpha
        func blend(_ base: CGFloat, _ over: CGFloat) -> CGFloat { base + (over - base) * alpha }
        return PlatformColor.lineformSRGB(
            red: blend(page.red, top.red),
            green: blend(page.green, top.green),
            blue: blend(page.blue, top.blue),
            alpha: 1
        )
    }

    private static func ink(of theme: Theme) -> PlatformColor {
        resolved(theme.textColor, for: theme)
    }

    /// A dynamic colour (the high-contrast theme's `.textColor`) resolved for the
    /// THEME's appearance — never the system's, which is not what the window is drawn in.
    private static func resolved(_ color: PlatformColor, for theme: Theme) -> PlatformColor {
        color.lineformResolvedSRGB(dark: theme.usesDarkChrome)
    }
}

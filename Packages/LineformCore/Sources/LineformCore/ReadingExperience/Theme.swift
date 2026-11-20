import CoreGraphics
import Foundation

public struct Theme: Equatable, Identifiable, Sendable {
    public var id: ThemeID
    public var name: String
    public var textColor: PlatformColor
    public var backgroundColor: PlatformColor
    public var caretColor: PlatformColor
    /// Whether chrome may wear this theme's hue. High contrast deliberately strips theme color
    /// from the page, so it strips it from the modal field too.
    public var usesThemeTintedChrome = true

    /// Which hue the Muse modal field wears. It is NOT `id`: the high-contrast theme keeps the
    /// user's `themeID` so the theme picker still shows their selection, which is exactly why
    /// keying the field off `id` would tint a surface that is supposed to be neutral.
    public var chromeTintID: ThemeID {
        usesThemeTintedChrome ? id : .system
    }

    // MARK: - Contrast

    /// WCAG 2.1 relative luminance. Lives here, in production, rather than only in the test file:
    /// a contrast rule asserted by a definition the app itself does not use is a paired definition
    /// waiting to disagree.
    public static func relativeLuminance(_ color: PlatformColor) -> CGFloat {
        let rgb = color.lineformSRGBComponentsOrOwn
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(rgb.red)
            + 0.7152 * linearized(rgb.green)
            + 0.0722 * linearized(rgb.blue)
    }

    /// WCAG 2.1 contrast ratio between two opaque colors.
    public static func contrastRatio(_ first: PlatformColor, _ second: PlatformColor) -> CGFloat {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `base` flattened onto this theme's page and, if it does not reach `minimumRatio` against it,
    /// blended toward the theme's own ink until it does.
    ///
    /// Two inks needed this. Link and image-reference text used `NSColor.linkColor` — the only ink
    /// in the highlighter not derived from the theme — which reads 3.70:1 on Quiet, below AA. The
    /// diagram/math fallback caption used the theme text at 0.6 alpha, below AA on four of five
    /// themes while being drawn SMALLER than body text. Blending toward the theme ink preserves
    /// the hue as far as the page allows instead of replacing it outright.
    ///
    /// `surface` measures against something drawn ON the page instead (the AI review's opaque
    /// replacement tint); it must itself carry the theme ink at `minimumRatio`.
    public func readableInk(_ base: PlatformColor, minimumRatio: CGFloat = 4.5, on surface: PlatformColor? = nil) -> PlatformColor {
        let ground = surface ?? backgroundColor
        // `page` is the ground's sRGB conversion, or the ground itself when that fails; its
        // luminance is `relativeLuminance(ground)` either way.
        let page = ground.lineformSRGBComponentsOrOwn
        let ink = textColor.lineformSRGBComponentsOrOwn
        guard let source = base.lineformSRGBComponents else { return textColor }

        // Flatten any alpha against the page — a translucent ink's effective color is what the
        // reader sees, and it is what the ratio must be measured against.
        let alpha = source.alpha
        func blend(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        let flattened = SRGBComponents(
            red: blend(page.red, source.red, alpha),
            green: blend(page.green, source.green, alpha),
            blue: blend(page.blue, source.blue, alpha),
            alpha: 1
        )

        // Each candidate blends the ORIGINAL colour toward the ink by `step`. Compounding from the
        // previous candidate instead reaches the ink after a handful of iterations, so a colour
        // that was one percent short of AA came back as plain body text — the link blue destroyed
        // rather than nudged. This finds the SMALLEST adjustment that clears the floor.
        var current = PlatformColor.lineformSRGB(
            red: flattened.red, green: flattened.green, blue: flattened.blue, alpha: 1
        )
        var step: CGFloat = 0
        while step < 1, Self.contrastRatio(current, ground) < minimumRatio {
            step += 0.05
            current = PlatformColor.lineformSRGB(
                red: blend(flattened.red, ink.red, step),
                green: blend(flattened.green, ink.green, step),
                blue: blend(flattened.blue, ink.blue, step),
                alpha: 1
            )
        }
        return Self.contrastRatio(current, ground) >= minimumRatio ? current : textColor
    }

    public var usesDarkChrome: Bool {
        let rgb = backgroundColor.lineformSRGBComponentsOrOwn
        let luminance = (0.2126 * rgb.red) + (0.7152 * rgb.green) + (0.0722 * rgb.blue)
        return luminance < 0.45
    }

    public static let system = Theme(
        id: .system,
        name: "Original",
        textColor: LineformColors.primaryText,
        backgroundColor: LineformColors.originalBackground,
        caretColor: LineformColors.primaryText
    )

    public static let paper = Theme(
        id: .paper,
        name: "Paper",
        textColor: LineformColors.primaryText,
        backgroundColor: LineformColors.paperBackground,
        caretColor: LineformColors.primaryText
    )

    public static let calm = Theme(
        id: .calm,
        name: "Calm",
        textColor: LineformColors.primaryText,
        backgroundColor: LineformColors.calmBackground,
        caretColor: LineformColors.primaryText
    )

    public static let quiet = Theme(
        id: .quiet,
        name: "Quiet",
        textColor: PlatformColor.lineformCalibratedWhite( 0.86, alpha: 1),
        backgroundColor: PlatformColor.lineformCalibratedWhite( 0.19, alpha: 1),
        caretColor: PlatformColor.lineformCalibratedWhite( 0.90, alpha: 1)
    )

    public static let night = Theme(
        id: .night,
        name: "Night",
        textColor: PlatformColor.lineformCalibratedWhite( 0.88, alpha: 1),
        backgroundColor: PlatformColor.lineformCalibratedWhite( 0.09, alpha: 1),
        caretColor: PlatformColor.lineformCalibratedWhite( 0.88, alpha: 1)
    )

    public static let builtIn: [Theme] = [
        .system,
        .paper,
        .calm,
        .quiet,
        .night
    ]

    public static func theme(for id: ThemeID) -> Theme {
        builtIn.first { $0.id == id } ?? .system
    }

    public static func theme(for profile: ReadingProfile) -> Theme {
        guard profile.highContrastEnabled else {
            return theme(for: profile.themeID)
        }

        return Theme(
            id: profile.themeID,
            name: "High Contrast",
            textColor: .lineformText,
            backgroundColor: .lineformTextBackground,
            caretColor: .lineformText,
            usesThemeTintedChrome: false
        )
    }
}

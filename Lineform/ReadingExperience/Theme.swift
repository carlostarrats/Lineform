import AppKit

enum ThemeID: String, Codable, Equatable, CaseIterable {
    case system
    case paper
    case calm
    case quiet
    case night

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue {
        case ThemeID.system.rawValue:
            self = .system
        case ThemeID.paper.rawValue:
            self = .paper
        case ThemeID.calm.rawValue:
            self = .calm
        case ThemeID.quiet.rawValue:
            self = .quiet
        case ThemeID.night.rawValue, "lowLight":
            self = .night
        default:
            self = .system
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct Theme: Equatable, Identifiable {
    var id: ThemeID
    var name: String
    var textColor: NSColor
    var backgroundColor: NSColor
    var caretColor: NSColor
    /// Whether chrome may wear this theme's hue. High contrast deliberately strips theme color
    /// from the page, so it strips it from the modal field too.
    var usesThemeTintedChrome = true

    /// Which hue the Muse modal field wears. It is NOT `id`: the high-contrast theme keeps the
    /// user's `themeID` so the theme picker still shows their selection, which is exactly why
    /// keying the field off `id` would tint a surface that is supposed to be neutral.
    var chromeTintID: ThemeID {
        usesThemeTintedChrome ? id : .system
    }

    // MARK: - Contrast

    /// WCAG 2.1 relative luminance. Lives here, in production, rather than only in the test file:
    /// a contrast rule asserted by a definition the app itself does not use is a paired definition
    /// waiting to disagree.
    static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(rgb.redComponent)
            + 0.7152 * linearized(rgb.greenComponent)
            + 0.0722 * linearized(rgb.blueComponent)
    }

    /// WCAG 2.1 contrast ratio between two opaque colors.
    static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
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
    func readableInk(_ base: NSColor, minimumRatio: CGFloat = 4.5) -> NSColor {
        let page = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
        let ink = textColor.usingColorSpace(.sRGB) ?? textColor
        guard let source = base.usingColorSpace(.sRGB) else { return textColor }

        // Flatten any alpha against the page — a translucent ink's effective color is what the
        // reader sees, and it is what the ratio must be measured against.
        let alpha = source.alphaComponent
        func blend(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        let flattened = NSColor(
            srgbRed: blend(page.redComponent, source.redComponent, alpha),
            green: blend(page.greenComponent, source.greenComponent, alpha),
            blue: blend(page.blueComponent, source.blueComponent, alpha),
            alpha: 1
        )

        // Each candidate blends the ORIGINAL colour toward the ink by `step`. Compounding from the
        // previous candidate instead reaches the ink after a handful of iterations, so a colour
        // that was one percent short of AA came back as plain body text — the link blue destroyed
        // rather than nudged. This finds the SMALLEST adjustment that clears the floor.
        var current = flattened
        var step: CGFloat = 0
        while step < 1, Self.contrastRatio(current, page) < minimumRatio {
            step += 0.05
            current = NSColor(
                srgbRed: blend(flattened.redComponent, ink.redComponent, step),
                green: blend(flattened.greenComponent, ink.greenComponent, step),
                blue: blend(flattened.blueComponent, ink.blueComponent, step),
                alpha: 1
            )
        }
        return Self.contrastRatio(current, page) >= minimumRatio ? current : textColor
    }

    var usesDarkChrome: Bool {
        let rgb = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
        let luminance = (0.2126 * rgb.redComponent) + (0.7152 * rgb.greenComponent) + (0.0722 * rgb.blueComponent)
        return luminance < 0.45
    }

    static let system = Theme(
        id: .system,
        name: "Original",
        textColor: LineformColors.primaryText,
        backgroundColor: LineformColors.originalBackground,
        caretColor: LineformColors.primaryText
    )

    static let paper = Theme(
        id: .paper,
        name: "Paper",
        textColor: LineformColors.primaryText,
        backgroundColor: LineformColors.paperBackground,
        caretColor: LineformColors.primaryText
    )

    static let calm = Theme(
        id: .calm,
        name: "Calm",
        textColor: LineformColors.primaryText,
        backgroundColor: LineformColors.calmBackground,
        caretColor: LineformColors.primaryText
    )

    static let quiet = Theme(
        id: .quiet,
        name: "Quiet",
        textColor: NSColor(calibratedWhite: 0.86, alpha: 1),
        backgroundColor: NSColor(calibratedWhite: 0.19, alpha: 1),
        caretColor: NSColor(calibratedWhite: 0.90, alpha: 1)
    )

    static let night = Theme(
        id: .night,
        name: "Night",
        textColor: NSColor(calibratedWhite: 0.88, alpha: 1),
        backgroundColor: NSColor(calibratedWhite: 0.09, alpha: 1),
        caretColor: NSColor(calibratedWhite: 0.88, alpha: 1)
    )

    static let builtIn: [Theme] = [
        .system,
        .paper,
        .calm,
        .quiet,
        .night
    ]

    static func theme(for id: ThemeID) -> Theme {
        builtIn.first { $0.id == id } ?? .system
    }

    static func theme(for profile: ReadingProfile) -> Theme {
        guard profile.highContrastEnabled else {
            return theme(for: profile.themeID)
        }

        return Theme(
            id: profile.themeID,
            name: "High Contrast",
            textColor: .textColor,
            backgroundColor: .textBackgroundColor,
            caretColor: .textColor,
            usesThemeTintedChrome: false
        )
    }
}

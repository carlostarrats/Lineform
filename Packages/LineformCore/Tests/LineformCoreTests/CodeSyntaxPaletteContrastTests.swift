import XCTest
@testable import LineformCore

final class CodeSyntaxPaletteContrastTests: XCTestCase {
    /// Every colored token role must clear WCAG AA (4.5:1) against every built-in theme's code
    /// background (the theme's own page color — code has no distinct box).
    func testEveryTokenColorMeetsAAAgainstEveryThemeBackground() {
        let coloredKinds: [CodeTokenKind] = [.keyword, .string, .comment, .number, .type]
        for theme in Theme.builtIn {
            for kind in coloredKinds {
                let fg = CodeSyntaxPalette.color(for: kind, theme: theme)
                let ratio = Self.contrastRatio(fg, theme.backgroundColor)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(kind) on \(theme.name) was \(ratio)"
                )
            }
        }
    }

    func testPlainReusesThemeTextColor() {
        for theme in Theme.builtIn {
            XCTAssertEqual(
                CodeSyntaxPalette.color(for: .plain, theme: theme),
                theme.textColor
            )
        }
    }

    private static func contrastRatio(_ a: PlatformColor, _ b: PlatformColor) -> CGFloat {
        func lum(_ c: PlatformColor) -> CGFloat {
            // macOS: `(c.usingColorSpace(.sRGB) ?? c)`'s components, as before the move.
            let s = c.lineformSRGBComponentsOrOwn
            func chan(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * chan(s.red) + 0.7152 * chan(s.green) + 0.0722 * chan(s.blue)
        }
        let l1 = lum(a), l2 = lum(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

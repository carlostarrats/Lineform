/// The chrome wash both apps lay behind their full-window chrome: the Mac's modal field (⌘K, the
/// Muse modals) and the iPhone's word menu. A vertical base gradient whose light hue follows the
/// reader theme (cool blue for System, Quiet and Night; warm for Paper; mint for Calm), crossed by
/// two neutral diagonal washes at `diagonalOpacity`. Dark chrome has one near-black pair for every
/// theme. One definition, so the two apps can never drift apart (owner, 2026-11-24: "the same
/// things apply" on iPhone as on the Mac).
///
/// Colours are sRGB components, 0–1, written from the designer's hex stops; do not round them.
public enum ChromeWash {
    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    // MARK: Base, top to bottom

    public static let lightTop = RGB(1.0, 1.0, 1.0)                 // #FFFFFF
    public static let lightBottom = RGB(0.945, 0.969, 1.0)          // #F1F7FF
    public static let darkTop = RGB(0.192, 0.188, 0.188)            // #313030
    public static let darkBottom = RGB(0.071, 0.071, 0.071)         // #121212
    public static let paperTop = RGB(0.996, 0.992, 0.980)           // #FEFDFA
    public static let paperBottom = RGB(0.984, 0.965, 0.929)        // #FBF6ED
    public static let calmTop = RGB(0.980, 0.996, 0.988)            // #FAFEFC
    public static let calmBottom = RGB(0.925, 0.980, 0.949)         // #ECFAF2

    /// The base gradient's two stops for a theme's chrome tint (`Theme.chromeTintID`).
    public static func base(for themeID: ThemeID, usesDarkChrome: Bool) -> (top: RGB, bottom: RGB) {
        guard !usesDarkChrome else { return (darkTop, darkBottom) }
        switch themeID {
        case .paper: return (paperTop, paperBottom)
        case .calm: return (calmTop, calmBottom)
        case .system, .quiet, .night: return (lightTop, lightBottom)
        }
    }

    /// The whole wash (base and diagonals) is laid at this opacity over the page, so a tenth of
    /// the page shows through: the Mac over a blur of the document, the iPhone over the page colour.
    public static let fieldOpacity: Double = 0.90

    // MARK: Diagonals

    public static let diagonalLightTop = RGB(0.957, 0.957, 0.957)   // #F4F4F4
    public static let diagonalLightBottom = RGB(0.835, 0.835, 0.835) // #D5D5D5
    public static let diagonalDarkTop = RGB(0.173, 0.173, 0.173)    // #2C2C2C
    public static let diagonalDarkBottom = RGB(0.071, 0.071, 0.071) // #121212
    public static let diagonalOpacity: Double = 0.20

    public static func diagonal(usesDarkChrome: Bool) -> (top: RGB, bottom: RGB) {
        usesDarkChrome ? (diagonalDarkTop, diagonalDarkBottom) : (diagonalLightTop, diagonalLightBottom)
    }
}

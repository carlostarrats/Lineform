import CoreGraphics
import Foundation

/// The editors' selection, drawn as a calm marker stroke instead of the system's flat fill
/// (iPhone TestFlight feedback §21, `docs/mockups/selection.html`): one straight stroke per line
/// fragment, edges only very slightly soft, ends that lean a touch and overshoot the text by a
/// varying amount, a slightly rounded nib, and consecutive lines just touching with about 2 pt of
/// overlap (so the two translucent fills darken where they meet).
///
/// Everything here is pure geometry and colour. Both editors draw it BEHIND the text from TextKit 1
/// line fragments (`HighlighterSelectionLayout`), and nothing is ever written to the text storage.
///
/// Deterministic: every random-looking value comes from the line's `seed` (the character index the
/// line fragment starts at), so a stroke never shimmers while a drag extends the selection.
public enum HighlighterSelection {
    /// One selected line, in the drawing view's coordinates.
    public struct Line: Hashable, Sendable {
        /// The selected text's left and right edges on this line (`minX == maxX` for a selected
        /// empty line or a lone line break).
        public var minX: CGFloat
        public var maxX: CGFloat
        /// The vertical centre of the line's glyphs.
        public var centerY: CGFloat
        /// The glyphs' height (the font's ascender to descender).
        public var textHeight: CGFloat
        /// The distance from this line to the next (the line fragment's height).
        public var pitch: CGFloat
        /// The character index the line fragment starts at: the stroke's identity.
        public var seed: Int

        public init(minX: CGFloat, maxX: CGFloat, centerY: CGFloat, textHeight: CGFloat, pitch: CGFloat, seed: Int) {
            self.minX = minX
            self.maxX = maxX
            self.centerY = centerY
            self.textHeight = textHeight
            self.pitch = pitch
            self.seed = seed
        }
    }

    /// A selected empty line still shows this much stroke, so the writer can see it is selected.
    public static let emptyLineWidth: CGFloat = 4
    /// Consecutive lines overlap by this much.
    public static let lineOverlap: CGFloat = 2
    /// A stroke is never taller than this multiple of its text (the mockup's cap), so a very loose
    /// line height leaves a calm gap between strokes rather than a slab.
    public static let maximumHeightRatio: CGFloat = 1.45

    /// The furthest a stroke reaches past `Line`'s box: the left overshoot (2–8 pt) plus half the
    /// lean, the right overshoot (1–10 pt) plus half the lean and the nib's bow. Used to invalidate.
    public static let horizontalReach: CGFloat = 20
    public static let verticalReach: CGFloat = 4

    /// The stroke's box before its ends are shaped: full line pitch plus the overlap, capped.
    public static func strokeBox(for line: Line) -> CGRect {
        let height = min(line.pitch + lineOverlap, line.textHeight * maximumHeightRatio)
        let width = max(line.maxX - line.minX, emptyLineWidth)
        return CGRect(x: line.minX, y: line.centerY - height / 2, width: width, height: height)
    }

    /// The area a line's stroke can paint (for invalidation).
    public static func paintBounds(for line: Line) -> CGRect {
        strokeBox(for: line).insetBy(dx: -horizontalReach, dy: -verticalReach)
    }

    /// The stroke for one line: a straight band with quadratic edges (the mockup's `stroke()`).
    public static func path(for line: Line) -> CGPath {
        let box = strokeBox(for: line)
        return strokePath(x: box.minX, y: box.minY, width: box.width, height: box.height, seed: line.seed)
    }

    /// A seeded value in 0..<1 (the mockup's `rnd`, a classic shader hash): the same seed always
    /// gives the same value, on every platform.
    static func unit(_ seed: Double) -> Double {
        let x = sin(seed * 12.9898) * 43758.5453
        return x - floor(x)
    }

    static func strokePath(x: CGFloat, y: CGFloat, width w: CGFloat, height h: CGFloat, seed: Int) -> CGPath {
        // The seed is folded into a small range first: `sin` of a huge argument loses precision,
        // and a 1 MB document's offsets would otherwise all hash alike.
        let base = Double(seed % 100_003) * 1.618
        func u(_ n: Double) -> CGFloat { CGFloat(unit(base + n)) }
        func j(_ n: Double, _ amplitude: CGFloat) -> CGFloat { (u(n) - 0.5) * amplitude }

        // Each line's ends differ: how far the marker overshoots, how much it leans, how round the nib.
        let left = x - 2 - u(1) * 6
        let right = x + w + 1 + u(2) * 9
        let t0 = y + j(3, 1.2), t1 = y + j(4, 1.2)
        let b0 = y + h + j(5, 1.2), b1 = y + h + j(6, 1.2)
        let leanL = j(7, 7), leanR = j(8, 8)
        let lt = left + leanL / 2, lb = left - leanL / 2
        let rt = right + leanR / 2, rb = right - leanR / 2
        let bowL = 1 + u(9) * 3, bowR = 1 + u(10) * 4

        let path = CGMutablePath()
        path.move(to: CGPoint(x: lt, y: t0))
        path.addQuadCurve(to: CGPoint(x: rt, y: t1),
                          control: CGPoint(x: (lt + rt) / 2, y: (t0 + t1) / 2 + j(11, 1)))
        path.addQuadCurve(to: CGPoint(x: rb, y: b1),
                          control: CGPoint(x: max(rt, rb) + bowR, y: (t1 + b1) / 2 + j(12, 3)))
        path.addQuadCurve(to: CGPoint(x: lb, y: b0),
                          control: CGPoint(x: (lb + rb) / 2, y: (b0 + b1) / 2 + j(13, 1)))
        path.addQuadCurve(to: CGPoint(x: lt, y: t0),
                          control: CGPoint(x: min(lt, lb) - bowL, y: (t0 + b0) / 2 + j(14, 3)))
        path.closeSubpath()
        return path
    }

    // MARK: - Colour

    /// Lineform blue (#2F6BDE) on light pages; the lighter blue (#6F9BFF) on dark ones.
    public static let lightInk = (red: 0x2F, green: 0x6B, blue: 0xDE)
    public static let darkInk = (red: 0x6F, green: 0x9B, blue: 0xFF)

    /// The fill's opacity: calm by default, stronger under Increase Contrast so low-vision readers
    /// keep a clearly visible selection. Text on one fill stays AA (4.5:1) in every theme at both
    /// strengths (`HighlighterSelectionTests`). On a dark page a stronger blue LIGHTENS the ground
    /// under light ink, so the dark step is smaller than the light one.
    public static func opacity(usesDarkChrome: Bool, increasedContrast: Bool) -> CGFloat {
        switch (usesDarkChrome, increasedContrast) {
        case (false, false): return 0.19
        case (true, false): return 0.30
        case (false, true): return 0.34
        case (true, true): return 0.38
        }
    }

    /// Whether neighbouring strokes darken where they overlap (the marker look). Under Increase
    /// Contrast the strokes are filled as one shape instead, so the overlap never takes the ground
    /// under the ink below AA.
    public static func darkensOverlaps(increasedContrast: Bool) -> Bool {
        !increasedContrast
    }

    /// The stroke's fill for a theme.
    public static func fillColor(for theme: Theme, increasedContrast: Bool) -> PlatformColor {
        let ink = theme.usesDarkChrome ? darkInk : lightInk
        return PlatformColor.lineformSRGB(
            red: CGFloat(ink.red) / 255,
            green: CGFloat(ink.green) / 255,
            blue: CGFloat(ink.blue) / 255,
            alpha: opacity(usesDarkChrome: theme.usesDarkChrome, increasedContrast: increasedContrast)
        )
    }
}

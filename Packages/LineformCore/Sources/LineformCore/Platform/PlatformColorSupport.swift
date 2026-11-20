import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A colour's components in sRGB.
public struct SRGBComponents: Equatable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// The sRGB value (red = green = blue) macOS converts each `NSColor(calibratedWhite:)` used by
/// `Theme` to. iOS has no calibrated colour space, so it draws these whites from this table.
/// Computed on macOS with `NSColor(calibratedWhite: w, alpha: 1).usingColorSpace(.sRGB)` and
/// pinned by `PlatformSeamTests.testCalibratedWhiteTableMatchesMacConversion`.
enum CalibratedWhiteTable {
    static let sRGB: [CGFloat: CGFloat] = [
        0.86: 0.88716357946395874,
        0.19: 0.24861118197441101,
        0.90: 0.91984230279922485,
        0.88: 0.90354937314987183,
        0.09: 0.11835422366857529,
    ]
}

extension PlatformColor {
    /// macOS: `NSColor(srgbRed:green:blue:alpha:)`. iOS: `UIColor(red:green:blue:alpha:)`.
    public static func lineformSRGB(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> PlatformColor {
        #if os(macOS)
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #else
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }

    /// macOS: `NSColor(calibratedWhite:alpha:)`, unchanged. iOS: the sRGB colour macOS converts
    /// that white to, from `CalibratedWhiteTable`; a white not in the table is a programming
    /// error (assertion in debug) and falls back to `UIColor(white:alpha:)`.
    public static func lineformCalibratedWhite(_ white: CGFloat, alpha: CGFloat) -> PlatformColor {
        #if os(macOS)
        NSColor(calibratedWhite: white, alpha: alpha)
        #else
        if let value = CalibratedWhiteTable.sRGB[white] {
            return UIColor(red: value, green: value, blue: value, alpha: alpha)
        }
        assertionFailure("no CalibratedWhiteTable entry for \(white)")
        return UIColor(white: white, alpha: alpha)
        #endif
    }

    /// macOS: the components of `usingColorSpace(.sRGB)`, nil when that conversion fails.
    /// iOS: `getRed(_:green:blue:alpha:)`, nil when it returns false.
    public var lineformSRGBComponents: SRGBComponents? {
        #if os(macOS)
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        return SRGBComponents(red: rgb.redComponent, green: rgb.greenComponent,
                              blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return SRGBComponents(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }

    /// `lineformSRGBComponents`, with a fallback when the sRGB conversion fails.
    ///
    /// macOS: falls back to the colour's own components, so this is exactly
    /// `(usingColorSpace(.sRGB) ?? color).redComponent` and so on, the fallback `Theme`'s
    /// contrast arithmetic has always used. iOS: a colour `getRed(_:green:blue:alpha:)` cannot
    /// convert gives black (red = green = blue = 0) with the colour's own alpha, so
    /// `MermaidHexColor` turns such a colour into `#000000`.
    var lineformSRGBComponentsOrOwn: SRGBComponents {
        if let rgb = lineformSRGBComponents { return rgb }
        #if os(macOS)
        return SRGBComponents(red: redComponent, green: greenComponent, blue: blueComponent, alpha: alphaComponent)
        #else
        return SRGBComponents(red: 0, green: 0, blue: 0, alpha: cgColor.alpha)
        #endif
    }

    /// The colour resolved for a light or dark page. A dynamic colour (the high-contrast theme's
    /// text colour) resolves for the THEME's appearance, never the system's.
    ///
    /// macOS: converted to sRGB (the colour itself when the conversion fails) with
    /// `usingColorSpace(.sRGB) ?? self` inside `NSAppearance(named: dark ? .darkAqua : .aqua)`'s
    /// `performAsCurrentDrawingAppearance`, or outside it when that appearance is missing, the
    /// call `HistoryPalette` has always made. iOS: `resolvedColor(with:)` for the matching
    /// interface style, returned as resolved, with no sRGB conversion.
    func lineformResolvedSRGB(dark: Bool) -> PlatformColor {
        #if os(macOS)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var result = self
        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                result = self.usingColorSpace(.sRGB) ?? self
            }
        } else {
            result = usingColorSpace(.sRGB) ?? self
        }
        return result
        #else
        resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        #endif
    }

    /// macOS: `.linkColor`. iOS: `.link`.
    public static var lineformLink: PlatformColor {
        #if os(macOS)
        .linkColor
        #else
        .link
        #endif
    }

    /// macOS: `.textColor`. iOS: `.label`.
    public static var lineformText: PlatformColor {
        #if os(macOS)
        .textColor
        #else
        .label
        #endif
    }

    /// macOS: `.textBackgroundColor`. iOS: `.systemBackground`.
    public static var lineformTextBackground: PlatformColor {
        #if os(macOS)
        .textBackgroundColor
        #else
        .systemBackground
        #endif
    }
}

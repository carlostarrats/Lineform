import Foundation

/// The Reading Experience panel's rules: slider ranges, value wording and the font the picker
/// shows. The Mac panel (`ReadingExperienceInspector`) and the iPhone Styling sheet both read
/// these, so a range or a unit can never differ between the two apps.
public enum ReadingExperienceControls {
    public static let fontSizeRange: ClosedRange<Double> = 12...48
    public static let lineHeightRange: ClosedRange<Double> = 0.5...1.8
    public static let blockSpacingRange: ClosedRange<Double> = 0...24
    public static let letterSpacingRange: ClosedRange<Double> = 0...1.2
    public static var columnWidthRange: ClosedRange<Double> {
        ReadingProfile.columnWidthMinimum...ReadingProfile.columnWidthMaximum
    }

    /// The font the picker shows. A profile persisted with a retired or unavailable font shows
    /// the default — the one `FontOption.resolved(for:)` actually renders.
    public static func visibleFontID(for profile: ReadingProfile) -> FontID {
        guard FontOption.option(for: profile.fontID)?.isAvailable == true else {
            // One definition of "the default", shared with `FontOption.resolved(for:)` — a second
            // hardcoded `.sfPro` here could drift out of agreement with what actually renders.
            return FontOption.defaultOption.id
        }
        return profile.fontID
    }

    public static func valueText(
        for keyPath: KeyPath<ReadingProfile, Double>,
        in profile: ReadingProfile,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let value = profile[keyPath: keyPath]

        switch keyPath {
        case \ReadingProfile.fontSize:
            return String(localized: "\(roundedInteger(value)) pt", bundle: .module, locale: locale)
        case \ReadingProfile.lineHeightMultiple:
            return decimalText(value, maximumFractionDigits: 2, locale: locale)
        case \ReadingProfile.columnWidth:
            return ReadingProfile.isFullWidthColumn(value)
                ? String(localized: "Full", bundle: .module, locale: locale)
                : String(localized: "\(roundedInteger(value)) px", bundle: .module, locale: locale)
        case \ReadingProfile.paragraphSpacing, \ReadingProfile.insertionPointWidth:
            return String(localized: "\(roundedInteger(value)) px", bundle: .module, locale: locale)
        case \ReadingProfile.letterSpacing:
            return decimalText(value, maximumFractionDigits: 1, locale: locale)
        default:
            return decimalText(value, maximumFractionDigits: 2, locale: locale)
        }
    }

    public static func decimalText(
        _ value: Double,
        maximumFractionDigits: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(maximumFractionDigits)f", value)
    }

    public static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func roundedInteger(_ value: Double) -> Int {
        Int(value.rounded())
    }
}

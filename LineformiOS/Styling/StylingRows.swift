import SwiftUI

/// The Mac panel's row type: labels 13 pt medium, qualifiers 11 pt regular secondary, values
/// 13 pt semibold secondary at least 54 pt wide.
enum StylingRowStyle {
    static let labelFontSize: CGFloat = 13
    static let qualifierFontSize: CGFloat = 11
    static let valueFontSize: CGFloat = 13
    static let valueMinWidth: CGFloat = 54
    static let pickerMaxWidth: CGFloat = 170

    static var labelFont: Font { .system(size: labelFontSize, weight: .medium) }
    static var qualifierFont: Font { .system(size: qualifierFontSize, weight: .regular) }
    static var valueFont: Font { .system(size: valueFontSize, weight: .semibold) }

    /// The slider's spoken value, worded as on the Mac ("Block Spacing (Read / Preview) value 12 px").
    static func sliderAccessibilityValue(title: String, subtitle: String?, valueText: String) -> String {
        let spokenTitle = accessibilityTitle(title: title, subtitle: subtitle)
        return String(localized: "\(spokenTitle) value \(valueText)")
    }

    static func accessibilityTitle(title: String, subtitle: String?) -> String {
        if let subtitle {
            return "\(title) \(subtitle)"
        }
        return title
    }

    static func toggleAccessibilityValue(_ isOn: Bool) -> String {
        isOn ? String(localized: "On") : String(localized: "Off")
    }
}

/// The Mac panel's row inset (`InspectorControlRow`).
struct StylingControlRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A title with a trailing picker (the Font row).
struct StylingPickerRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        StylingControlRow {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(StylingRowStyle.labelFont)
                Spacer(minLength: 12)
                content
                    .font(StylingRowStyle.labelFont)
                    .frame(maxWidth: StylingRowStyle.pickerMaxWidth, alignment: .trailing)
            }
        }
    }
}

/// A title (and optional qualifier), the value trailing, and a continuous slider beneath.
struct StylingSliderRow: View {
    var title: String
    var subtitle: String?
    var valueText: String
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        StylingControlRow {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(StylingRowStyle.labelFont)
                        if let subtitle {
                            Text(subtitle)
                                .font(StylingRowStyle.qualifierFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHidden(true)

                    Spacer(minLength: 12)

                    Text(valueText)
                        .font(StylingRowStyle.valueFont)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: StylingRowStyle.valueMinWidth, alignment: .trailing)
                        .accessibilityLabel(StylingRowStyle.sliderAccessibilityValue(
                            title: title, subtitle: subtitle, valueText: valueText
                        ))
                }

                Slider(value: $value, in: range)
                    .accessibilityLabel(StylingRowStyle.accessibilityTitle(title: title, subtitle: subtitle))
                    .accessibilityValue(valueText)
            }
        }
    }
}

/// A title, its description beneath, and a trailing switch.
struct StylingToggleRow: View {
    var title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        StylingControlRow {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(StylingRowStyle.labelFont)
                    if let subtitle {
                        Text(subtitle)
                            .font(StylingRowStyle.qualifierFont)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityValue(StylingRowStyle.toggleAccessibilityValue(isOn))
            }
        }
    }
}

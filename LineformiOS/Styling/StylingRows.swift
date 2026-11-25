import LineformCore
import SwiftUI

/// The Mac panel's row type: labels 13 pt medium, qualifiers 11 pt regular secondary, values
/// 13 pt semibold secondary at least 54 pt wide.
///
/// On iPhone every size scales with Dynamic Type from the Mac's value (`stylingFont`): exactly the
/// Mac's points at the default text size, growing like `labelTextStyle` / `qualifierTextStyle`.
enum StylingRowStyle {
    static let labelFontSize: CGFloat = 13
    static let qualifierFontSize: CGFloat = 11
    static let valueFontSize: CGFloat = 13
    static let valueMinWidth: CGFloat = 54
    /// How far a font name may shrink before the row stacks instead: the name is always one
    /// line and takes the row's whole width beside its title (owner review 4: "Atkinson
    /// Hyperlegible" wrapped under the old 170 pt cap).
    static let pickerMinimumScaleFactor: CGFloat = 0.85
    /// A control row is at least this tall, its 6 pt inset included: a 44 pt target.
    static let minimumRowHeight: CGFloat = 44
    static let rowVerticalInset: CGFloat = 6

    /// The text styles the sizes scale with: 13 pt is `.footnote`, 11 pt is `.caption2`.
    static let labelTextStyle: Font.TextStyle = .footnote
    static let qualifierTextStyle: Font.TextStyle = .caption2

    /// A control's spoken name: "Block Spacing (Read / Preview)". A localized format, so a
    /// language joins the two its own way (Japanese and Chinese use no space).
    static func accessibilityTitle(title: String, subtitle: String?) -> String {
        if let subtitle {
            return String(
                localized: "\(title) \(subtitle)",
                comment: "A Styling control's spoken name: its title, then its qualifier, e.g. Block Spacing (Read / Preview)."
            )
        }
        return title
    }

    static func toggleAccessibilityValue(_ isOn: Bool) -> String {
        isOn ? String(localized: "On") : String(localized: "Off")
    }

    /// The value one VoiceOver swipe up (or down) moves to: the next multiple of `step`, clamped.
    static func adjusted(_ value: Double, by step: Double, increment: Bool, in range: ClosedRange<Double>) -> Double {
        guard step > 0 else { return value }
        // A hair of tolerance, so 17.0000001 counts as 17.
        let position = value / step
        let next = increment ? (position + 1e-6).rounded(.down) + 1 : (position - 1e-6).rounded(.up) - 1
        return ReadingExperienceControls.clamped(next * step, to: range)
    }
}

/// A fixed point size that scales with Dynamic Type relative to `textStyle`: exactly `size` at the
/// default text size, so the sheet matches the Mac panel there.
private struct StylingScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design

    init(size: CGFloat, relativeTo textStyle: Font.TextStyle, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// `size` points at the default text size, scaled with Dynamic Type like `textStyle`.
    func stylingFont(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(StylingScaledFont(size: size, relativeTo: textStyle, weight: weight, design: design))
    }

    /// The row label: 13 pt medium.
    func stylingLabelFont() -> some View {
        stylingFont(size: StylingRowStyle.labelFontSize, relativeTo: StylingRowStyle.labelTextStyle, weight: .medium)
    }

    /// The qualifier and the description: 11 pt regular.
    func stylingQualifierFont() -> some View {
        stylingFont(size: StylingRowStyle.qualifierFontSize, relativeTo: StylingRowStyle.qualifierTextStyle)
    }

    /// The slider's value: 13 pt semibold.
    func stylingValueFont() -> some View {
        stylingFont(size: StylingRowStyle.valueFontSize, relativeTo: StylingRowStyle.labelTextStyle, weight: .semibold)
    }
}

/// The Mac panel's row inset (`InspectorControlRow`).
struct StylingControlRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, StylingRowStyle.rowVerticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row's two parts side by side, or stacked: always at the accessibility text sizes, and, when
/// `stacksWhenTooWide`, whenever the two cannot share a line (a long translation).
struct StylingRowLayout<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var stacksWhenTooWide = true
    @ViewBuilder var content: (_ isStacked: Bool) -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else if stacksWhenTooWide {
            ViewThatFits(in: .horizontal) {
                sideBySide
                stacked
            }
        } else {
            sideBySide
        }
    }

    private var sideBySide: some View {
        HStack(alignment: alignment, spacing: 12) { content(false) }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 6) { content(true) }
    }
}

/// A title with a trailing picker (the Font row).
struct StylingPickerRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        StylingControlRow {
            StylingRowLayout { isStacked in
                Text(title)
                    .stylingLabelFont()
                    .lineLimit(1)
                    .fixedSize()
                    // The picker carries the same name.
                    .accessibilityHidden(true)
                if !isStacked { Spacer(minLength: 12) }
                // The system's menu button, at its own size (about 34 pt tall at the default
                // text size; it does not grow with a frame). The name stays on one line and
                // takes the room left beside the title.
                content
                    .stylingLabelFont()
                    .lineLimit(1)
                    .minimumScaleFactor(StylingRowStyle.pickerMinimumScaleFactor)
                    .layoutPriority(1)
            }
        }
    }
}

/// A title (and optional qualifier), the value trailing, and a continuous slider beneath.
///
/// One VoiceOver stop: the row is a single adjustable element named by the title (and qualifier),
/// valued by the value text, that a swipe up or down moves by `step`.
struct StylingSliderRow: View {
    var title: String
    var subtitle: String?
    var valueText: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    /// What one VoiceOver adjustment moves the value by.
    var step: Double
    /// The secondary ink (`PhoneInk`) for the qualifier and the value.
    var secondaryInk: Color
    /// True when a drag starts, false when it ends (`StylingDrag`).
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        StylingControlRow {
            VStack(alignment: .leading, spacing: 7) {
                StylingRowLayout(alignment: .firstTextBaseline) { isStacked in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .stylingLabelFont()
                        if let subtitle {
                            Text(subtitle)
                                .stylingQualifierFont()
                                .foregroundStyle(secondaryInk)
                        }
                    }
                    if !isStacked { Spacer(minLength: 12) }
                    Text(valueText)
                        .stylingValueFont()
                        .foregroundStyle(secondaryInk)
                        .frame(
                            minWidth: isStacked ? nil : StylingRowStyle.valueMinWidth,
                            alignment: isStacked ? .leading : .trailing
                        )
                }

                Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                    // The system blue the sliders have always drawn, not the app's accent colour
                    // (AccentColor is Lineform blue for untinted controls; the sliders keep theirs).
                    .tint(Color(uiColor: .systemBlue))
            }
        }
        // The element's frame is the whole row, its inset included.
        .contentShape(.accessibility, Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StylingRowStyle.accessibilityTitle(title: title, subtitle: subtitle))
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = StylingRowStyle.adjusted(value, by: step, increment: true, in: range)
            case .decrement: value = StylingRowStyle.adjusted(value, by: step, increment: false, in: range)
            @unknown default: break
            }
        }
    }
}

/// A title, its description beneath, and a trailing switch (beneath, at the accessibility sizes).
///
/// One VoiceOver stop: the row is a switch named by the title, with the description as its hint,
/// and the whole row is its frame.
struct StylingToggleRow: View {
    var title: String
    var subtitle: String?
    @Binding var isOn: Bool
    /// The secondary ink (`StylingSheet.Inks`) for the description.
    var secondaryInk: Color
    /// The switch's on fill: Lineform blue, as Settings' switches.
    var switchFill: Color

    var body: some View {
        StylingControlRow {
            // The description wraps rather than pushing the switch beneath it.
            StylingRowLayout(stacksWhenTooWide: false) { isStacked in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .stylingLabelFont()
                    if let subtitle {
                        Text(subtitle)
                            .stylingQualifierFont()
                            .foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !isStacked { Spacer(minLength: 12) }
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .tint(switchFill)
            }
            .frame(minHeight: StylingRowStyle.minimumRowHeight - 2 * StylingRowStyle.rowVerticalInset)
        }
        // The element's frame is the whole row, its inset included (at least 44 pt tall).
        .contentShape(.accessibility, Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        // The qualifier is already localized; no hint without one.
        .accessibilityHint(Text(verbatim: subtitle ?? ""))
        .accessibilityValue(StylingRowStyle.toggleAccessibilityValue(isOn))
        .accessibilityAddTraits([.isButton, .isToggle])
        .accessibilityAction { isOn.toggle() }
    }
}

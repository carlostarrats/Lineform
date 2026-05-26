import SwiftUI

struct ReadingExperienceInspector: View {
    @ObservedObject var store: ReadingProfileStore

    static let visibleControlLabels = [
        "Theme",
        "Font",
        "Font Size",
        "Line Height",
        "Paragraph Spacing",
        "Letter Spacing",
        "Column Width",
        "Reduce Markdown Noise",
        "Focus",
        "Reading Ruler",
        "Typewriter Mode",
        "Caret Width",
        "Reset to Default",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorSectionLabel("Appearance")

                PickerRow(title: "Theme") {
                    Picker("Theme", selection: themeSelection) {
                        ForEach(Theme.readerThemes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                PickerRow(title: "Font") {
                    Picker("Font", selection: fontSelection) {
                        ForEach(FontOption.availableGroupedOptions) { group in
                            Section(group.name) {
                                ForEach(group.options) { option in
                                    Text(option.name).tag(option.id)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                InspectorSliderRow(
                    title: "Font Size",
                    valueText: Self.valueText(for: \.fontSize, in: store.activeProfile),
                    value: numericBinding(\.fontSize, range: 13...28),
                    range: 13...28
                )

                InspectorSliderRow(
                    title: "Line Height",
                    valueText: Self.valueText(for: \.lineHeightMultiple, in: store.activeProfile),
                    value: numericBinding(\.lineHeightMultiple, range: 1.1...1.8),
                    range: 1.1...1.8
                )

                InspectorSliderRow(
                    title: "Paragraph Spacing",
                    valueText: Self.valueText(for: \.paragraphSpacing, in: store.activeProfile),
                    value: numericBinding(\.paragraphSpacing, range: 0...24),
                    range: 0...24
                )

                InspectorSliderRow(
                    title: "Letter Spacing",
                    valueText: Self.valueText(for: \.letterSpacing, in: store.activeProfile),
                    value: numericBinding(\.letterSpacing, range: 0...1.2),
                    range: 0...1.2
                )

                InspectorSliderRow(
                    title: "Column Width",
                    valueText: Self.valueText(for: \.columnWidth, in: store.activeProfile),
                    value: numericBinding(\.columnWidth, range: 460...900),
                    range: 460...900
                )

                InspectorSectionLabel("Reading Aids")

                Toggle("Reduce Markdown Noise", isOn: boolBinding(\.reduceMarkdownNoise))

                PickerRow(title: "Focus") {
                    Picker("Focus", selection: focusSelection) {
                        ForEach(FocusMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Toggle("Reading Ruler", isOn: boolBinding(\.readingRulerEnabled))

                Toggle("Typewriter Mode", isOn: boolBinding(\.typewriterModeEnabled))

                InspectorSliderRow(
                    title: "Caret Width",
                    valueText: Self.valueText(for: \.insertionPointWidth, in: store.activeProfile),
                    value: numericBinding(\.insertionPointWidth, range: 1...4),
                    range: 1...4
                )

                Button("Reset to Default") {
                    store.resetToDefault()
                }
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reading Experience Inspector")
    }

    private var themeSelection: Binding<ThemeID> {
        Binding(
            get: { store.activeProfile.themeID },
            set: { themeID in
                store.update { $0.applyTheme(themeID) }
            }
        )
    }

    private var fontSelection: Binding<FontID> {
        Binding(
            get: { Self.visibleFontID(for: store.activeProfile) },
            set: { fontID in
                store.update { $0.fontID = fontID }
            }
        )
    }

    static func visibleFontID(for profile: ReadingProfile) -> FontID {
        guard FontOption.option(for: profile.fontID)?.isAvailable == true else {
            return .sfPro
        }
        return profile.fontID
    }

    static func valueText(for keyPath: KeyPath<ReadingProfile, Double>, in profile: ReadingProfile) -> String {
        let value = profile[keyPath: keyPath]

        switch keyPath {
        case \ReadingProfile.fontSize:
            return "\(roundedInteger(value)) pt"
        case \ReadingProfile.lineHeightMultiple:
            return decimalText(value, maximumFractionDigits: 2)
        case \ReadingProfile.paragraphSpacing, \ReadingProfile.columnWidth, \ReadingProfile.insertionPointWidth:
            return "\(roundedInteger(value)) px"
        case \ReadingProfile.letterSpacing:
            return decimalText(value, maximumFractionDigits: 1)
        default:
            return decimalText(value, maximumFractionDigits: 2)
        }
    }

    private var focusSelection: Binding<FocusMode> {
        Binding(
            get: { store.activeProfile.focusMode },
            set: { mode in
                store.update { $0.focusMode = mode }
            }
        )
    }

    private func numericBinding(_ keyPath: WritableKeyPath<ReadingProfile, Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { store.activeProfile[keyPath: keyPath] },
            set: { value in
                store.update { $0[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound) }
            }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<ReadingProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.activeProfile[keyPath: keyPath] },
            set: { value in
                store.update { $0[keyPath: keyPath] = value }
            }
        )
    }

    private static func roundedInteger(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private static func decimalText(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(maximumFractionDigits)f", value)
    }
}

private struct InspectorSectionLabel: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private struct PickerRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            content
                .frame(maxWidth: 170, alignment: .trailing)
        }
    }
}

private struct InspectorSliderRow: View {
    var title: String
    var valueText: String
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(valueText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 54, alignment: .trailing)
                    .accessibilityLabel("\(title) value \(valueText)")
            }

            Slider(value: $value, in: range)
        }
    }
}

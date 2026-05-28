import SwiftUI

struct ReadingExperienceInspector: View {
    @ObservedObject var store: ReadingProfileStore
    var usesDarkChrome = false

    static let visibleControlLabels = [
        "Themes",
        "Font",
        "Font Size",
        "Line Height",
        "Paragraph Spacing",
        "Letter Spacing",
        "Column Width",
        "Reading Aids",
        "Reduce Markdown Noise",
        "Reading Ruler",
        "Typewriter Mode",
        "Caret Width",
        "Reset to Default",
    ]
    static let resetTopSpacing: CGFloat = 20
    static let usesResetSeparator = false
    static let presetGridColumnCount = 3
    static let themeTitle = "Themes"
    static let themeTitleFontSize: CGFloat = 13
    static let controlLabelFontSize: CGFloat = 13
    static let valueFontSize: CGFloat = 13
    static let unselectedPresetOpacity = 1.0
    static let unselectedPresetContentOpacity: Double = 1
    static let themeToFontSpacing: CGFloat = 10
    static let usesReadingAidsSectionLabel = true
    static let sectionLabelFontSize: CGFloat = 13
    static let usesNativeUIFontOutsideThemePreviews = true
    static let usesMonospacedInspectorValueFont = false
    static let usesNativeControlHoverOnly = true
    static let resetButtonShowsHoverFeedback = true
    static let resetButtonHoverFillOpacity = 0.08
    static let presetCardHoverFillOpacity = 0.07

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                presetGrid
                    .padding(.bottom, Self.themeToFontSpacing)

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

                if Self.usesReadingAidsSectionLabel {
                    InspectorSectionLabel("Reading Aids")
                }

                InspectorToggleRow(title: "Reduce Markdown Noise", isOn: boolBinding(\.reduceMarkdownNoise))

                InspectorToggleRow(title: "Reading Ruler", isOn: boolBinding(\.readingRulerEnabled))

                InspectorToggleRow(title: "Typewriter Mode", isOn: boolBinding(\.typewriterModeEnabled))

                InspectorSliderRow(
                    title: "Caret Width",
                    valueText: Self.valueText(for: \.insertionPointWidth, in: store.activeProfile),
                    value: numericBinding(\.insertionPointWidth, range: 1...4),
                    range: 1...4
                )

                VStack(alignment: .leading, spacing: 12) {
                    InspectorControlRow {
                        HoverFeedbackButton("Reset to Default") {
                            store.resetToDefault()
                        }
                    }
                }
                .padding(.top, Self.resetTopSpacing)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: Self.backgroundColor(usesDarkChrome: usesDarkChrome)))
        .font(Self.inspectorUIFont())
        .environment(\.colorScheme, Self.colorScheme(usesDarkChrome: usesDarkChrome))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reading Experience Inspector")
    }

    static func inspectorUIFont(size: CGFloat = controlLabelFontSize, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight)
    }

    static func colorScheme(usesDarkChrome: Bool) -> ColorScheme {
        usesDarkChrome ? .dark : .light
    }

    static func backgroundColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(calibratedWhite: 0.20, alpha: 1)
            : LineformColors.inspectorLightBackground
    }

    private var presetGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 10),
            count: Self.presetGridColumnCount
        )
        let selectedPresetID = ReadingPreset.matchingPresetID(for: store.activeProfile)

        return VStack(alignment: .leading, spacing: 10) {
            Text(Self.themeTitle)
                .font(Self.inspectorUIFont(size: Self.themeTitleFontSize))
                .foregroundStyle(.primary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(ReadingPreset.builtIn) { preset in
                    ReadingPresetCard(
                        preset: preset,
                        isSelected: selectedPresetID == preset.id
                    ) {
                        store.applyPreset(preset)
                    }
                }
            }
        }
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
            .font(ReadingExperienceInspector.inspectorUIFont(size: ReadingExperienceInspector.sectionLabelFontSize))
            .foregroundStyle(.primary)
    }
}

private struct PickerRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        InspectorControlRow {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(ReadingExperienceInspector.inspectorUIFont())
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                content
                    .font(ReadingExperienceInspector.inspectorUIFont())
                    .frame(maxWidth: 170, alignment: .trailing)
            }
        }
    }
}

private struct ReadingPresetCard: View {
    var preset: ReadingPreset
    var isSelected: Bool
    var apply: () -> Void
    @State private var isHovered = false

    private var theme: Theme {
        Theme.theme(for: preset.profile)
    }

    var body: some View {
        Button(action: apply) {
            VStack(spacing: 2) {
                Text("Aa")
                    .font(previewFont(size: 30))
                    .foregroundStyle(Color(nsColor: theme.textColor))
                    .lineLimit(1)

                Text(preset.profile.name)
                    .font(previewFont(size: 12))
                    .foregroundStyle(Color(nsColor: theme.textColor))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .opacity(ReadingExperienceInspector.unselectedPresetContentOpacity)
            .frame(maxWidth: .infinity, minHeight: 82)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: theme.backgroundColor).opacity(isSelected ? 1 : ReadingExperienceInspector.unselectedPresetOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? ReadingExperienceInspector.presetCardHoverFillOpacity : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? selectedStrokeColor : Color.black.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("\(preset.profile.name) reading theme")
    }

    private var selectedStrokeColor: Color {
        let background = theme.backgroundColor.usingColorSpace(.deviceRGB)
        let brightness = ((background?.redComponent ?? 1) + (background?.greenComponent ?? 1) + (background?.blueComponent ?? 1)) / 3
        return brightness < 0.45 ? .white : .primary
    }

    private func previewFont(size: CGFloat) -> Font {
        switch preset.profile.fontID {
        case .sfPro:
            return .system(size: size, weight: .regular)
        case .newYork:
            return .system(size: size, weight: .regular, design: .serif)
        case .jetBrainsMono:
            return .system(size: size, weight: .regular, design: .monospaced)
        case .atkinsonHyperlegible:
            return .custom("AtkinsonHyperlegible-Regular", size: size)
        case .openDyslexic:
            return .custom("OpenDyslexic-Regular", size: size)
        case .lexend, .comicSans:
            return .system(size: size, weight: .regular)
        }
    }
}

private struct InspectorSliderRow: View {
    var title: String
    var valueText: String
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        InspectorControlRow {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .font(ReadingExperienceInspector.inspectorUIFont())
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Text(valueText)
                        .font(ReadingExperienceInspector.inspectorUIFont(
                            size: ReadingExperienceInspector.valueFontSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 54, alignment: .trailing)
                        .accessibilityLabel("\(title) value \(valueText)")
                }

                Slider(value: $value, in: range)
            }
        }
    }
}

private struct InspectorToggleRow: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        InspectorControlRow {
            Toggle(title, isOn: $isOn)
                .font(ReadingExperienceInspector.inspectorUIFont())
        }
    }
}

private struct HoverFeedbackButton: View {
    var title: String
    var action: () -> Void
    @State private var isHovered = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .font(ReadingExperienceInspector.inspectorUIFont())
            .buttonStyle(.bordered)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? ReadingExperienceInspector.resetButtonHoverFillOpacity : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
    }
}

private struct InspectorControlRow<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

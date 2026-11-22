import LineformCore
import SwiftUI

/// The Styling sheet: the Mac's Reading Experience panel in a bottom sheet, opened by the "Aa"
/// button (`StylingButton`). Every control writes through `ReadingProfileStore`, which
/// `DocumentScreen` observes, so the editor and the Read view restyle live.
///
/// `DocumentScreen` presents it with `stylingSheetChrome(theme:)` for the live profile's theme:
/// the page colour, and the theme's own light or dark, never the system appearance, so a dark
/// preset draws a dark sheet with readable labels whatever the phone is set to.
struct StylingSheet: View {
    @ObservedObject var store: ReadingProfileStore

    static let detents: Set<PresentationDetent> = [.medium, .large]
    static let cornerRadius: CGFloat = LineformDesign.Radius.modal
    static let headerTitleFontSize: CGFloat = 15
    /// The Mac panel's section spacing and padding.
    static let sectionSpacing: CGFloat = 18
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 16
    static var headerTitle: String { String(localized: "Reading") }

    /// The theme's own light or dark, independent of the trait collection.
    static func colorScheme(for theme: Theme) -> ColorScheme {
        theme.usesDarkChrome ? .dark : .light
    }

    // The Mac panel's labels, in its order (`ReadingExperienceInspector.visibleControlLabels`).
    // The rows draw these same constants, so the inventory and the screen cannot disagree.
    static var themesTitle: String { String(localized: "Themes") }
    static var fontTitle: String { String(localized: "Font") }
    static var fontSizeTitle: String { String(localized: "Font Size") }
    static var lineHeightTitle: String { String(localized: "Line Height") }
    static var blockSpacingTitle: String { String(localized: "Block Spacing") }
    static var blockSpacingQualifier: String { String(localized: "(Read / Preview)") }
    static var letterSpacingTitle: String { String(localized: "Letter Spacing") }
    static var columnWidthTitle: String { String(localized: "Column Width") }
    static var readingRulerTitle: String { String(localized: "Reading Ruler") }
    static var readingRulerDescription: String {
        String(localized: "Highlights the current line while you write.")
    }
    static var typewriterModeTitle: String { String(localized: "Typewriter Mode") }
    static var typewriterModeDescription: String {
        String(localized: "Keeps the current line centered as you write.")
    }
    static var resetTitle: String { String(localized: "Reset to Default") }

    static var controlLabels: [String] {
        [
            themesTitle,
            fontTitle,
            fontSizeTitle,
            lineHeightTitle,
            blockSpacingTitle,
            blockSpacingQualifier,
            letterSpacingTitle,
            columnWidthTitle,
            readingRulerTitle,
            readingRulerDescription,
            typewriterModeTitle,
            typewriterModeDescription,
            resetTitle,
        ]
    }

    /// The Mac panel's layout values.
    static let presetGridColumnCount = 3
    static let presetGridSpacing: CGFloat = 10
    static let themeTitleFontSize: CGFloat = 13
    static let themeToFontSpacing: CGFloat = 10
    static let resetTopSpacing: CGFloat = 20
    /// The Mac header's gap above the scrolling controls.
    static let headerBottomPadding: CGFloat = 8

    private var theme: Theme { Theme.theme(for: store.activeProfile) }
    private var bindings: Bindings { Bindings(store: store) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    presetGrid
                        .padding(.bottom, Self.themeToFontSpacing)

                    StylingPickerRow(title: Self.fontTitle) {
                        Picker(Self.fontTitle, selection: bindings.font) {
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

                    sliderRow(Self.fontSizeTitle, \.fontSize, ReadingExperienceControls.fontSizeRange)
                    sliderRow(Self.lineHeightTitle, \.lineHeightMultiple, ReadingExperienceControls.lineHeightRange)
                    sliderRow(
                        Self.blockSpacingTitle,
                        subtitle: Self.blockSpacingQualifier,
                        \.paragraphSpacing,
                        ReadingExperienceControls.blockSpacingRange
                    )
                    sliderRow(Self.letterSpacingTitle, \.letterSpacing, ReadingExperienceControls.letterSpacingRange)
                    sliderRow(Self.columnWidthTitle, \.columnWidth, ReadingExperienceControls.columnWidthRange)

                    StylingToggleRow(
                        title: Self.readingRulerTitle,
                        subtitle: Self.readingRulerDescription,
                        isOn: bindings.toggle(\.readingRulerEnabled)
                    )
                    StylingToggleRow(
                        title: Self.typewriterModeTitle,
                        subtitle: Self.typewriterModeDescription,
                        isOn: bindings.toggle(\.typewriterModeEnabled)
                    )

                    StylingControlRow {
                        Button(Self.resetTitle) { bindings.reset() }
                            .font(StylingRowStyle.labelFont)
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, Self.resetTopSpacing)
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, Self.verticalPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(Color(uiColor: theme.textColor))
    }

    private var header: some View {
        Text(Self.headerTitle)
            .font(.system(size: Self.headerTitleFontSize, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity)
            .padding(.top, Self.verticalPadding + 8)
            .padding(.bottom, Self.headerBottomPadding)
            .padding(.horizontal, Self.horizontalPadding)
    }

    private var presetGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: Self.presetGridSpacing),
            count: Self.presetGridColumnCount
        )
        let selectedPresetID = bindings.selectedPresetID
        let usesDarkChrome = theme.usesDarkChrome
        return VStack(alignment: .leading, spacing: Self.presetGridSpacing) {
            Text(Self.themesTitle)
                .font(.system(size: Self.themeTitleFontSize, weight: .medium))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.presetGridSpacing) {
                ForEach(ReadingPreset.builtIn) { preset in
                    StylingPresetCard(
                        preset: preset,
                        isSelected: selectedPresetID == preset.id,
                        usesDarkChrome: usesDarkChrome
                    ) {
                        bindings.selectPreset(preset)
                    }
                }
            }
        }
    }

    private func sliderRow(
        _ title: String,
        subtitle: String? = nil,
        _ keyPath: WritableKeyPath<ReadingProfile, Double>,
        _ range: ClosedRange<Double>
    ) -> some View {
        StylingSliderRow(
            title: title,
            subtitle: subtitle,
            valueText: ReadingExperienceControls.valueText(for: keyPath, in: store.activeProfile),
            value: bindings.numeric(keyPath, range: range),
            range: range
        )
    }
}

extension StylingSheet {
    /// How every control writes the store — the Mac panel's bindings, value for value. The view
    /// builds its controls from these, and the tests drive the store through them directly.
    @MainActor
    struct Bindings {
        let store: ReadingProfileStore

        /// The preset card drawn selected: the active slot, else the preset the profile matches.
        var selectedPresetID: UUID? {
            store.activePresetID ?? ReadingPreset.matchingPresetID(for: store.activeProfile)
        }

        /// The font the picker shows: a retired or unavailable font shows the default.
        var font: Binding<FontID> {
            let store = store
            return Binding(
                get: { ReadingExperienceControls.visibleFontID(for: store.activeProfile) },
                set: { fontID in store.update { $0.fontID = fontID } }
            )
        }

        func numeric(
            _ keyPath: WritableKeyPath<ReadingProfile, Double>,
            range: ClosedRange<Double>
        ) -> Binding<Double> {
            let store = store
            return Binding(
                get: { store.activeProfile[keyPath: keyPath] },
                set: { value in
                    store.update { $0[keyPath: keyPath] = ReadingExperienceControls.clamped(value, to: range) }
                }
            )
        }

        func toggle(_ keyPath: WritableKeyPath<ReadingProfile, Bool>) -> Binding<Bool> {
            let store = store
            return Binding(
                get: { store.activeProfile[keyPath: keyPath] },
                set: { value in store.update { $0[keyPath: keyPath] = value } }
            )
        }

        func selectPreset(_ preset: ReadingPreset) {
            store.applyPreset(preset)
        }

        /// Drops only the current preset's edits; the other presets keep theirs.
        func reset() {
            store.resetCurrentPreset()
        }
    }
}

extension View {
    /// The Styling sheet's presentation: medium and large detents, the theme's page colour, the
    /// modal corner radius, a visible drag indicator, and the theme's own colour scheme.
    func stylingSheetChrome(theme: Theme) -> some View {
        presentationDetents(StylingSheet.detents)
            .presentationBackground(Color(uiColor: theme.backgroundColor))
            .presentationCornerRadius(StylingSheet.cornerRadius)
            .presentationDragIndicator(.visible)
            .environment(\.colorScheme, StylingSheet.colorScheme(for: theme))
    }
}

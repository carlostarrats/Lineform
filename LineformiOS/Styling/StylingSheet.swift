import LineformCore
import SwiftUI

/// The Styling sheet: the Mac’s Reading Experience panel in a bottom sheet, opened by the word
/// menu’s Themes. Every control writes through `ReadingProfileStore`, which
/// `DocumentScreen` observes, so the editor and the Read view restyle live.
///
/// `DocumentScreen` presents it with `stylingSheetChrome(theme:)` for the live profile's theme:
/// the page colour, and the theme's own light or dark, never the system appearance, so a dark
/// preset draws a dark sheet with readable labels whatever the phone is set to.
struct StylingSheet: View {
    @ObservedObject var store: ReadingProfileStore

    static let detents: Set<PresentationDetent> = [.medium, .large]

    /// How much darker than a light page the sheet is: its brightness times this (hue and
    /// saturation kept, so Paper stays warm and Calm stays mint). White becomes #F2F2F2.
    static let lightSurfaceBrightness: CGFloat = 0.95

    /// The sheet's surface, always a step apart from the page so the sheet reads as its own
    /// surface (owner review 4): on a light theme the page colour a little darker
    /// (`lightSurfaceBrightness`); on a dark one #1F1F1F, so the Quiet card (the page's own
    /// colour) never blends into the sheet. Every ink on it is measured on this surface
    /// (`Inks`).
    static func surface(for theme: Theme) -> UIColor {
        guard theme.usesDarkChrome else {
            let page = theme.backgroundColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            guard page.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return page }
            return UIColor(hue: hue, saturation: saturation, brightness: brightness * lightSurfaceBrightness, alpha: 1)
        }
        let darker = UIColor(white: 0x1F / 255, alpha: 1)
        // A page darker still (Low Light) keeps its own colour: the sheet never gets lighter.
        return Theme.relativeLuminance(theme.backgroundColor) < Theme.relativeLuminance(darker) ? theme.backgroundColor : darker
    }
    static let cornerRadius: CGFloat = LineformDesign.Radius.modal
    /// The Mac panel's section spacing and padding.
    static let sectionSpacing: CGFloat = 18
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 16
    /// The space above the "Themes" label: the mockup's sheet padding (8), grabber (5 + 4) and
    /// gap (10). The sheet has no title (`word-menu.html`, `openThemes()`).
    static let topPadding: CGFloat = 27

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
    /// Fewer, wider cards at the accessibility text sizes, so a title fits.
    static func presetGridColumnCount(for size: DynamicTypeSize) -> Int {
        guard size.isAccessibilitySize else { return presetGridColumnCount }
        return size >= .accessibility3 ? 1 : 2
    }
    static let presetGridSpacing: CGFloat = 10
    /// 13 pt at the default text size, scaled like `.footnote`.
    static let themeTitleFontSize: CGFloat = 13
    static let themeToFontSpacing: CGFloat = 10
    static let resetTopSpacing: CGFloat = 20
    /// The page behind the medium detent stays undimmed and usable, so a change shows live.
    static let backgroundInteraction: PresentationBackgroundInteraction = .enabled(upThrough: .medium)

    /// What one VoiceOver swipe moves each slider by: one step of what its value text shows.
    static func accessibilityStep(for keyPath: WritableKeyPath<ReadingProfile, Double>) -> Double {
        switch keyPath {
        case \.fontSize, \.paragraphSpacing: return 1
        case \.lineHeightMultiple: return 0.05
        case \.letterSpacing: return 0.1
        case \.columnWidth: return 20
        default: return 1
        }
    }

    /// The theme the page draws with — the DISPLAY theme (Automatic Dark Mode applied), the same
    /// one the presentation's surface and colour scheme come from. Nil (tests) is the store's
    /// own theme. Reading the store's theme here while the chrome used the display theme drew
    /// Original's near-black labels on the dark sheet (owner review 4).
    var displayTheme: Theme? = nil

    private var theme: Theme { displayTheme ?? Theme.theme(for: store.activeProfile) }
    private var inks: Inks { Inks(theme: theme) }
    /// The qualifier, value and description ink, readable (AA) on the sheet's surface.
    private var secondaryInk: Color { Color(uiColor: inks.secondary) }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Coalesces slider drags (`StylingDrag`).
    @State private var coalescer = ProfileUpdateCoalescer()
    private var bindings: Bindings { Bindings(store: store, coalescer: coalescer) }

    var body: some View {
        VStack(spacing: 0) {
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
                        // The chosen name is text: Lineform blue made readable on the sheet.
                        .tint(Color(uiColor: inks.pickerInk))
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
                        isOn: bindings.toggle(\.readingRulerEnabled),
                        secondaryInk: secondaryInk,
                        switchFill: Color(uiColor: inks.switchFill)
                    )
                    StylingToggleRow(
                        title: Self.typewriterModeTitle,
                        subtitle: Self.typewriterModeDescription,
                        isOn: bindings.toggle(\.typewriterModeEnabled),
                        secondaryInk: secondaryInk,
                        switchFill: Color(uiColor: inks.switchFill)
                    )

                    StylingControlRow {
                        Button { bindings.reset() } label: {
                            Text(Self.resetTitle).stylingLabelFont()
                        }
                        .buttonStyle(.bordered)
                        .tint(Color(uiColor: inks.resetInk))
                    }
                    .padding(.top, Self.resetTopSpacing)
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.top, Self.topPadding)
                .padding(.bottom, Self.verticalPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        // Every label ("Font", "Font Size", …) draws in the primary ink, measured on the surface.
        .foregroundStyle(Color(uiColor: inks.primary))
        .onAppear { WordMenuTiming.end(.themes) }
        // A sheet dismissed mid-drag never reports the drag's end: end it here, or the Read view
        // would wait for it.
        .onDisappear { coalescer.endAllDrags() }
        // An interrupted touch (a call, Control Center) may never report its end.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            coalescer.endAllDrags()
        }
    }

    private var presetGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: Self.presetGridSpacing),
            count: Self.presetGridColumnCount(for: dynamicTypeSize)
        )
        let selectedPresetID = bindings.selectedPresetID
        let usesDarkChrome = theme.usesDarkChrome
        return VStack(alignment: .leading, spacing: Self.presetGridSpacing) {
            Text(Self.themesTitle)
                .stylingFont(size: Self.themeTitleFontSize, relativeTo: StylingRowStyle.labelTextStyle, weight: .semibold)
                .foregroundStyle(secondaryInk)
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
            range: range,
            step: Self.accessibilityStep(for: keyPath),
            secondaryInk: secondaryInk,
            onEditingChanged: { [coalescer] editing in
                if editing { coalescer.beginDrag() } else { coalescer.endDrag() }
            }
        )
    }
}

extension StylingSheet {
    /// How every control writes the store — the Mac panel's bindings, value for value. The view
    /// builds its controls from these, and the tests drive the store through them directly.
    @MainActor
    struct Bindings {
        let store: ReadingProfileStore
        /// Slider writes go through it, so a drag writes the store at most once per run-loop turn.
        var coalescer: ProfileUpdateCoalescer? = nil

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
            let coalescer = coalescer
            return Binding(
                get: { store.activeProfile[keyPath: keyPath] },
                set: { value in
                    let clamped = ReadingExperienceControls.clamped(value, to: range)
                    if let coalescer {
                        coalescer.submit(to: store) { $0[keyPath: keyPath] = clamped }
                    } else {
                        store.update { $0[keyPath: keyPath] = clamped }
                    }
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

extension StylingSheet {
    /// Every ink on the sheet, each made readable on the sheet's own surface
    /// (`StylingSheet.surface(for:)`), never on the page: text 4.5:1, the switch fill 3:1.
    /// `StylingSheetTests.testEveryInkMeetsAAOnTheSheetInEveryDisplayTheme` measures `entries`.
    @MainActor
    struct Inks {
        /// The sheet's surface, resolved for the theme's own appearance.
        let surface: UIColor
        /// The labels: Font, Font Size, Line Height, … Reset's title is `resetInk`.
        let primary: UIColor
        /// The qualifier, the values, the descriptions and the Themes label.
        let secondary: UIColor
        /// The Font menu's chosen name (the picker's tint): Lineform blue as text.
        let pickerInk: UIColor
        /// Reset to Default's title: Lineform blue as text, on its bordered fill.
        let resetInk: UIColor
        /// The bordered button's fill as it lands: the tint at `resetFillAlpha` over the surface.
        let resetFill: UIColor
        /// The switches' on fill: Lineform blue, as Settings' switches (`WordMenuPalette.blueFill`).
        let switchFill: UIColor

        /// A conservative stand-in for the bordered style's tinted fill.
        static let resetFillAlpha: CGFloat = 0.2

        init(theme: Theme) {
            let style: UIUserInterfaceStyle = theme.usesDarkChrome ? .dark : .light
            // Dynamic colours (the high-contrast theme) resolved for the forced appearance.
            var sheet = PhoneInk(theme: theme, userInterfaceStyle: style).theme
            let surface = StylingSheet.surface(for: sheet)
            sheet.backgroundColor = surface
            self.surface = surface
            primary = sheet.readableInk(sheet.textColor, minimumRatio: PhoneInk.Role.textMinimum)
            secondary = sheet.readableInk(sheet.textColor.withAlphaComponent(0.6), minimumRatio: PhoneInk.Role.textMinimum)
            // Lineform blue as text, as the word menu's (`WordMenuPalette.blueText`).
            let blue = sheet.usesDarkChrome
                ? UIColor(red: 0x7F / 255, green: 0xA6 / 255, blue: 0xF5 / 255, alpha: 1)
                : UIColor(red: 0x2F / 255, green: 0x6B / 255, blue: 0xDE / 255, alpha: 1)
            pickerInk = sheet.readableInk(blue, minimumRatio: PhoneInk.Role.textMinimum)
            let resetFill = PhoneInk.flatten(blue, alpha: Self.resetFillAlpha, over: surface)
            self.resetFill = resetFill
            resetInk = sheet.readableInk(blue, minimumRatio: PhoneInk.Role.textMinimum, on: resetFill)
            switchFill = WordMenuPalette.forTheme(theme).blueFill
        }

        /// Every pair the contrast test measures.
        var entries: [PhoneInk.Entry] {
            [
                PhoneInk.Entry(name: "primary", color: primary, surface: surface, minimumRatio: PhoneInk.Role.textMinimum),
                PhoneInk.Entry(name: "secondary", color: secondary, surface: surface, minimumRatio: PhoneInk.Role.textMinimum),
                PhoneInk.Entry(name: "picker", color: pickerInk, surface: surface, minimumRatio: PhoneInk.Role.textMinimum),
                PhoneInk.Entry(name: "reset", color: resetInk, surface: resetFill, minimumRatio: PhoneInk.Role.textMinimum),
                PhoneInk.Entry(name: "switchFill", color: switchFill, surface: surface, minimumRatio: PhoneInk.Role.nonTextMinimum),
            ]
        }
    }
}

extension View {
    /// The Styling sheet's presentation: medium and large detents, the theme's page colour, the
    /// modal corner radius, a visible drag indicator, and the theme's own colour scheme.
    func stylingSheetChrome(theme: Theme) -> some View {
        presentationDetents(StylingSheet.detents)
            .presentationBackground(Color(uiColor: StylingSheet.surface(for: theme)))
            .presentationCornerRadius(StylingSheet.cornerRadius)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(StylingSheet.backgroundInteraction)
            .environment(\.colorScheme, StylingSheet.colorScheme(for: theme))
            // The presentation's own chrome (the grabber, the Font menu) follows the theme too,
            // not the phone's appearance.
            .preferredColorScheme(StylingSheet.colorScheme(for: theme))
    }
}

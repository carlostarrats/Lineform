import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The Styling sheet's presentation (opened by the word menu's Themes): the detents and corner
/// radius, its surface, and a colour scheme taken from the theme, never the system.
@MainActor
final class StylingSheetTests: XCTestCase {
    /// In dark, the sheet is a step darker than the Quiet card, so Quiet never blends into it;
    /// a light theme keeps its page colour; the sheet never gets lighter than a darker page.
    func testDarkSheetIsDarkerThanTheQuietCard() {
        let quiet = Theme.quiet
        XCTAssertLessThan(Theme.relativeLuminance(StylingSheet.surface(for: quiet)), Theme.relativeLuminance(quiet.backgroundColor))
        XCTAssertEqual(StylingSheet.surface(for: .night), Theme.night.backgroundColor)
        // Every preset card has a visible edge on the dark sheet.
        let edge = StylingPresetCard.unselectedStrokeColor(usesDarkChrome: true)
        XCTAssertGreaterThan(edge.cgColor.alpha, 0.2)
    }

    /// Owner review 4: in a light theme the sheet is a step darker than the page, so it reads as
    /// its own surface, and keeps the page's hue (Paper stays warm, Calm stays mint).
    func testLightSheetIsAStepDarkerThanThePageInItsHue() {
        for theme in Theme.builtIn where !theme.usesDarkChrome {
            let page = theme.backgroundColor
            let surface = StylingSheet.surface(for: theme)
            var ph: CGFloat = 0, ps: CGFloat = 0, pb: CGFloat = 0, pa: CGFloat = 0
            var sh: CGFloat = 0, ss: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
            XCTAssertTrue(page.getHue(&ph, saturation: &ps, brightness: &pb, alpha: &pa))
            XCTAssertTrue(surface.getHue(&sh, saturation: &ss, brightness: &sb, alpha: &sa))
            XCTAssertEqual(sb, pb * StylingSheet.lightSurfaceBrightness, accuracy: 0.002, theme.name)
            XCTAssertEqual(ss, ps, accuracy: 0.002, "\(theme.name) keeps its saturation")
            if ps > 0.01 { XCTAssertEqual(sh, ph, accuracy: 0.002, "\(theme.name) keeps its hue") }
            XCTAssertLessThan(Theme.relativeLuminance(surface), Theme.relativeLuminance(page), theme.name)
            // A step, not a different colour.
            XCTAssertLessThan(Theme.contrastRatio(surface, page), 1.25, theme.name)
        }
        // Original's white page under a #F2F2F2 sheet.
        var white: CGFloat = 0, alpha: CGFloat = 0
        StylingSheet.surface(for: .system).getWhite(&white, alpha: &alpha)
        XCTAssertEqual(white * 255, 0xF2, accuracy: 0.6)
    }

    /// Owner review 4: every text on the sheet reads at AA (4.5:1) and the switch fill at 3:1 on
    /// the SHEET's surface, in every theme the page can show — the five built-in themes, the
    /// high-contrast theme, and every theme as Automatic Dark Mode draws it — and the labels are
    /// the display theme's, never the stored one's (Original's ink on the dark sheet was black
    /// on black).
    func testEveryInkMeetsAAOnTheSheetInEveryDisplayTheme() {
        var themes: [(String, Theme)] = Theme.builtIn.map { ($0.name, $0) }
        var highContrast = ReadingProfile.original
        highContrast.highContrastEnabled = true
        themes.append(("High Contrast", Theme.theme(for: highContrast)))
        for theme in Theme.builtIn {
            var profile = ReadingProfile.original
            profile.themeID = theme.id
            let display = AppSettings.displayProfile(profile, automaticDarkMode: true, userInterfaceStyle: .dark)
            themes.append(("automatic dark from \(theme.name)", Theme.theme(for: display)))
        }
        for (name, theme) in themes {
            let inks = StylingSheet.Inks(theme: theme)
            for entry in inks.entries {
                let ratio = Theme.contrastRatio(entry.color, entry.surface)
                XCTAssertGreaterThanOrEqual(ratio, entry.minimumRatio, "\(entry.name) on \(name): \(String(format: "%.2f", ratio)):1")
            }
            XCTAssertEqual(inks.surface, StylingSheet.surface(for: PhoneInk(theme: theme, userInterfaceStyle: theme.usesDarkChrome ? .dark : .light).theme), name)
        }
        // The switches are Lineform blue, as in Settings.
        XCTAssertEqual(StylingSheet.Inks(theme: .night).switchFill, WordMenuPalette.forTheme(.night).blueFill)
        XCTAssertEqual(StylingSheet.Inks(theme: .paper).switchFill, WordMenuPalette.forTheme(.paper).blueFill)
        // On the dark sheet the labels are light.
        let dark = StylingSheet.Inks(theme: .quiet)
        XCTAssertGreaterThan(Theme.relativeLuminance(dark.primary), 0.5)
    }

    func testSheetDetentsAreMediumAndLarge() {
        XCTAssertEqual(StylingSheet.detents, [.medium, .large])
    }

    func testSheetColorSchemeFollowsTheme() {
        // A pure function of the theme: there is no trait collection to consult, so the sheet is
        // dark for Quiet and light for Original whatever the system appearance is.
        XCTAssertEqual(StylingSheet.colorScheme(for: .quiet), .dark)
        XCTAssertEqual(StylingSheet.colorScheme(for: .night), .dark)
        XCTAssertEqual(StylingSheet.colorScheme(for: .system), .light)
        XCTAssertEqual(StylingSheet.colorScheme(for: .paper), .light)
    }

    /// The mockup's sheet has no title: it starts with the small "Themes" label and the cards.
    func testSheetStartsWithTheThemesLabel() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(StylingSheet.themesTitle, "Themes")
        XCTAssertEqual(StylingSheet.themeTitleFontSize, 13)
        XCTAssertEqual(StylingSheet.topPadding, 27)
    }

    // MARK: - The controls

    /// A store on its own defaults suite, removed when the test ends.
    private func makeStore() -> ReadingProfileStore {
        let suiteName = "StylingSheetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return ReadingProfileStore(defaults: defaults)
    }

    /// By the English name's place in the built-in order (pinned by `testSixPresetsInDesktopOrder`),
    /// so the lookup works in every interface language.
    private func preset(_ title: String) -> ReadingPreset {
        let order = ["Original", "Quiet", "Paper", "Code", "Calm", "Focus"]
        return ReadingPreset.builtIn[order.firstIndex(of: title)!]
    }

    func testControlLabelsMatchDesktopOrder() throws {
        try skipUnlessEnglishInterface()
        // `ReadingExperienceInspector.visibleControlLabels`, verbatim and in order.
        XCTAssertEqual(StylingSheet.controlLabels, [
            "Themes",
            "Font",
            "Font Size",
            "Line Height",
            "Block Spacing",
            "(Read / Preview)",
            "Letter Spacing",
            "Column Width",
            "Reading Ruler",
            "Highlights the current line while you write.",
            "Typewriter Mode",
            "Keeps the current line centered as you write.",
            // The mockup's and §17's wording (the Mac's panel says Reset to Default).
            "Reset to Theme",
        ])
    }

    /// §17: a tap on the grabber or on the page above the sheet closes it. The grabber is the
    /// mockup's (36 × 5, 8 pt down) with a spoken name; the system one would only change detents.
    /// (The taps themselves are checked in the simulator: a sheet cannot be presented here.)
    func testGrabberMatchesTheMockup() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(StylingSheet.closeTitle, "Close Themes")
        XCTAssertEqual(StylingSheet.grabberSize, CGSize(width: 36, height: 5))
        XCTAssertEqual(StylingSheet.grabberTop, 8)
    }

    func testSixPresetsInDesktopOrder() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(
            ReadingPreset.builtIn.map(\.title),
            ["Original", "Quiet", "Paper", "Code", "Calm", "Focus"]
        )
        XCTAssertEqual(StylingSheet.presetGridColumnCount, 3)
        XCTAssertEqual(StylingSheet.presetGridSpacing, 10)
        XCTAssertEqual(StylingPresetCard.minHeight, 82)
        XCTAssertEqual(StylingPresetCard.cornerRadius, LineformDesign.Radius.card)
        XCTAssertEqual(StylingPresetCard.specimenFontSize, 30)
        XCTAssertEqual(StylingPresetCard.titleFontSize, 12)
        XCTAssertEqual(
            StylingPresetCard.accessibilityLabel(for: preset("Paper")),
            "Paper reading theme"
        )
    }

    func testSelectingPresetAppliesItsProfile() {
        let store = makeStore()
        let bindings = StylingSheet.Bindings(store: store)
        bindings.selectPreset(preset("Paper"))

        XCTAssertEqual(store.activeProfile.fontID, .newYork)
        XCTAssertEqual(store.activeProfile.themeID, .paper)
        XCTAssertEqual(store.activeProfile.fontSize, 18)
        XCTAssertEqual(bindings.selectedPresetID, preset("Paper").id)
    }

    func testSliderClampsToRange() {
        let store = makeStore()
        let bindings = StylingSheet.Bindings(store: store)

        let fontSize = bindings.numeric(\.fontSize, range: ReadingExperienceControls.fontSizeRange)
        fontSize.wrappedValue = 100
        XCTAssertEqual(store.activeProfile.fontSize, 48)
        XCTAssertEqual(fontSize.wrappedValue, 48)

        let lineHeight = bindings.numeric(\.lineHeightMultiple, range: ReadingExperienceControls.lineHeightRange)
        lineHeight.wrappedValue = 0.1
        XCTAssertEqual(store.activeProfile.lineHeightMultiple, 0.5)
    }

    func testResetResetsOnlyCurrentPreset() {
        let store = makeStore()
        let bindings = StylingSheet.Bindings(store: store)
        let fontSize = bindings.numeric(\.fontSize, range: ReadingExperienceControls.fontSizeRange)

        bindings.selectPreset(preset("Paper"))
        fontSize.wrappedValue = 30
        bindings.selectPreset(preset("Calm"))
        fontSize.wrappedValue = 40
        bindings.reset()

        XCTAssertEqual(store.activeProfile, preset("Calm").profile)
        bindings.selectPreset(preset("Paper"))
        XCTAssertEqual(store.activeProfile.fontSize, 30, "Paper keeps its own edit")
    }

    func testFontPickerOmitsComicSansOnIPhone() {
        let offered = FontOption.availableGroupedOptions.flatMap(\.options).map(\.id)
        XCTAssertFalse(offered.contains(.comicSans))
        XCTAssertFalse(offered.contains(.lexend))
        XCTAssertEqual(offered, [.sfPro, .newYork, .jetBrainsMono, .atkinsonHyperlegible, .openDyslexic])
    }

    func testRetiredFontShowsDefault() {
        let store = makeStore()
        let bindings = StylingSheet.Bindings(store: store)

        store.update { $0.fontID = .lexend }
        XCTAssertEqual(bindings.font.wrappedValue, FontOption.defaultOption.id)
        store.update { $0.fontID = .comicSans }
        XCTAssertEqual(bindings.font.wrappedValue, FontOption.defaultOption.id)

        bindings.font.wrappedValue = .openDyslexic
        XCTAssertEqual(store.activeProfile.fontID, .openDyslexic)
        XCTAssertEqual(bindings.font.wrappedValue, .openDyslexic)
    }

    func testTogglesWriteRulerAndTypewriter() throws {
        try skipUnlessEnglishInterface()
        let store = makeStore()
        let bindings = StylingSheet.Bindings(store: store)

        bindings.toggle(\.readingRulerEnabled).wrappedValue = true
        XCTAssertTrue(store.activeProfile.readingRulerEnabled)
        bindings.toggle(\.typewriterModeEnabled).wrappedValue = true
        XCTAssertTrue(store.activeProfile.typewriterModeEnabled)
        bindings.toggle(\.readingRulerEnabled).wrappedValue = false
        XCTAssertFalse(store.activeProfile.readingRulerEnabled)
        XCTAssertTrue(store.activeProfile.typewriterModeEnabled)

        XCTAssertEqual(StylingRowStyle.toggleAccessibilityValue(true), "On")
        XCTAssertEqual(StylingRowStyle.toggleAccessibilityValue(false), "Off")
    }

    func testSliderAccessibilityTitleJoinsTheQualifier() throws {
        try skipUnlessEnglishInterface()
        // The slider row is one adjustable element: this is its label, the value text its value.
        XCTAssertEqual(
            StylingRowStyle.accessibilityTitle(title: "Block Spacing", subtitle: "(Read / Preview)"),
            "Block Spacing (Read / Preview)"
        )
        XCTAssertEqual(StylingRowStyle.labelFontSize, 13)
        XCTAssertEqual(StylingRowStyle.qualifierFontSize, 11)
        XCTAssertEqual(StylingRowStyle.valueFontSize, 13)
        XCTAssertEqual(StylingRowStyle.valueMinWidth, 54)
        XCTAssertEqual(StylingSheet.resetTopSpacing, 20)
    }

    func testDarkPresetCardsGetTheDarkStroke() {
        XCTAssertEqual(
            StylingPresetCard.unselectedStrokeColor(usesDarkChrome: true),
            UIColor.white.withAlphaComponent(0.26)
        )
        XCTAssertEqual(
            StylingPresetCard.unselectedStrokeColor(usesDarkChrome: false),
            UIColor.black.withAlphaComponent(0.08)
        )
        // Resolved for the forced scheme, so Quiet draws dark-mode blue on a light phone.
        XCTAssertEqual(
            StylingPresetCard.selectedStrokeColor(usesDarkChrome: true),
            UIColor.systemBlue.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        )
    }

    func testEveryStylingStringIsInSixLanguages() throws {
        try skipUnlessEnglishInterface()
        let keys = StylingSheet.controlLabels + [
            "Reading Experience", "%@ reading theme", "%@ %@", "On", "Off",
        ]

        // English is the source language: every key must be in the iPhone catalog itself.
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LineformiOS/Localizable.xcstrings")
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for key in keys {
            XCTAssertNotNil(strings[key], "\(key) missing from the iPhone catalog")
        }

        // The other five, as the built app resolves them.
        let missing = "\u{0}missing"
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: language, ofType: "lproj"),
                "No \(language).lproj in the app bundle"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: missing, table: nil)
                XCTAssertNotEqual(value, missing, "\(key) missing in \(language)")
                XCTAssertNotEqual(value, key, "\(key) untranslated in \(language)")
            }
        }
    }
}

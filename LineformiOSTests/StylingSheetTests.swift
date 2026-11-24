import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The "Aa" button and the Styling sheet's presentation: the Menu button's size, the Mac's label,
/// the detents and corner radius, and a colour scheme taken from the theme, never the system.
@MainActor
final class StylingSheetTests: XCTestCase {
    func testStylingButtonLabelIsReadingExperience() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(StylingButton.accessibilityLabel, String(localized: "Reading Experience"))
        XCTAssertEqual(StylingButton.accessibilityLabel, "Reading Experience")
        XCTAssertNotNil(UIImage(systemName: StylingButton.symbolName))
    }

    func testStylingButtonMatchesMenuButtonDiameter() {
        XCTAssertEqual(StylingButton.diameter, 44)
        XCTAssertEqual(StylingButton.diameter, MenuButton.diameter)
    }

    func testStylingButtonSitsInTheBottomRowClearOfTheNoticeAndReadClearance() {
        // The Aa button shares the Menu button's row (same height), so the notice, placed above a
        // Menu-button-high row, and the Read view's bottom clearance stay clear of it too.
        XCTAssertLessThanOrEqual(StylingButton.diameter, MenuButton.diameter)
        XCTAssertGreaterThanOrEqual(
            DocumentScreen.bottomChromeClearance,
            MarkdownEditor.chromeMargin + StylingButton.diameter
        )
    }

    func testSheetDetentsAreMediumAndLarge() {
        XCTAssertEqual(StylingSheet.detents, [.medium, .large])
    }

    func testSheetCornerRadiusIsModal() {
        XCTAssertEqual(StylingSheet.cornerRadius, 20)
        XCTAssertEqual(StylingSheet.cornerRadius, LineformDesign.Radius.modal)
    }

    func testSheetColorSchemeFollowsTheme() {
        // A pure function of the theme: there is no trait collection to consult, so the sheet is
        // dark for Quiet and light for Original whatever the system appearance is.
        XCTAssertEqual(StylingSheet.colorScheme(for: .quiet), .dark)
        XCTAssertEqual(StylingSheet.colorScheme(for: .night), .dark)
        XCTAssertEqual(StylingSheet.colorScheme(for: .system), .light)
        XCTAssertEqual(StylingSheet.colorScheme(for: .paper), .light)
    }

    func testSheetHeaderIsReading() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(StylingSheet.headerTitle, "Reading")
        XCTAssertEqual(StylingSheet.headerTitleFontSize, 15)
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
            "Reset to Default",
        ])
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
            UIColor.white.withAlphaComponent(0.18)
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
            "Reading", "Reading Experience", "%@ reading theme", "%@ %@", "On", "Off",
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

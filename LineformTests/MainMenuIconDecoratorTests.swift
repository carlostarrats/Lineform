import AppKit
import XCTest
@testable import Lineform

@MainActor
final class MainMenuIconDecoratorTests: XCTestCase {
    /// A misspelled SF Symbol fails silently — `NSImage(systemSymbolName:)` returns nil and the
    /// row just renders bare, which is exactly the mixed look the decorator exists to prevent.
    func testEverySymbolNameResolvesOnThisSystem() {
        let allSymbols = Set(
            MainMenuIconDecorator.symbolsByAction.values
        ).union(MainMenuIconDecorator.symbolsByTitle.values)

        for symbol in allSymbols.sorted() {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "SF Symbol \"\(symbol)\" does not resolve"
            )
        }
    }

    func testNormalizedTitleStripsEllipsisPeriodsAndAppName() {
        XCTAssertEqual(MainMenuIconDecorator.normalizedTitle("Save As..."), "save as")
        XCTAssertEqual(MainMenuIconDecorator.normalizedTitle("Jump to File…"), "jump to file")
        XCTAssertEqual(MainMenuIconDecorator.normalizedTitle("About Lineform"), "about")
        XCTAssertEqual(MainMenuIconDecorator.normalizedTitle("Quit Lineform"), "quit")
        XCTAssertEqual(MainMenuIconDecorator.normalizedTitle("Hide Lineform"), "hide")
    }

    /// The app menu's rows are SwiftUI `Button`s sharing one private action, so they resolve by
    /// title alone. If `AppMenuConfiguration` retitles one, this catches the orphaned mapping.
    func testConfiguredCommandTitlesAllHaveIcons() {
        let titles = [
            AppMenuConfiguration.aboutCommandTitle,
            AppMenuConfiguration.settingsCommandTitle,
            AppMenuConfiguration.checkForUpdatesCommandTitle,
            AppMenuConfiguration.installCommandLineToolCommandTitle,
            AppMenuConfiguration.privacyPolicyCommandTitle,
            AppMenuConfiguration.termsOfUseCommandTitle,
            AppMenuConfiguration.guideCommandTitle,
            AppMenuConfiguration.saveCommandTitle,
            AppMenuConfiguration.saveAsCommandTitle,
            AppMenuConfiguration.renameFileCommandTitle,
            AppMenuConfiguration.deleteFileCommandTitle,
            AppMenuConfiguration.jumpToFileCommandTitle,
            AppMenuConfiguration.printCommandTitle,
            AppMenuConfiguration.findCommandTitle,
            AppMenuConfiguration.findReplaceCommandTitle,
            AppMenuConfiguration.showHiddenFoldersCommandTitle
        ] + AppMenuConfiguration.markdownFormattingCommandTitles

        // Every one of these titles is now a localization-catalog key, and the decorator
        // resolves its localized form by looking the ENGLISH key up in the catalog. That
        // only works if the key is listed in `allEnglishTitleKeys`, which is hand-maintained
        // — so completeness is asserted here rather than remembered.
        let englishKeys = Set(AppMenuConfiguration.allEnglishTitleKeys.map(MainMenuIconDecorator.normalizedTitle))

        for title in titles {
            let key = MainMenuIconDecorator.normalizedTitle(title)
            XCTAssertNotNil(
                MainMenuIconDecorator.symbolsByTitle[key],
                "Menu title \"\(title)\" (key \"\(key)\") has no icon mapping"
            )
            XCTAssertTrue(
                englishKeys.contains(key),
                "Menu title \"\(title)\" (key \"\(key)\") is missing from AppMenuConfiguration.allEnglishTitleKeys — "
                    + "its icon would be lost in every non-English locale"
            )
        }
    }

    /// The runtime map deliberately keeps the English keys as a safety net, so probing it
    /// can never fail. The thing that can actually regress is the LOCALIZED alias, which is
    /// what this asserts.
    func testEveryTitleKeyedEntryGainsALocalizedAliasInAllShippedLocales() {
        // Passwords / Credit Card: the spec records these AutoFill rows as having no Apple
        // translation source. macOS 26.5's InputManager.loctable does carry them, so they in
        // fact resolve today — the exemption stays because that is an AppKit implementation
        // detail we do not control, and losing these two icons is accepted either way.
        let acceptedLosses: Set<String> = ["passwords", "credit card"]

        // Rows that need no localized alias because they never reach the title map:
        // `symbolName(for:)` matches `symbolsByAction` FIRST, and these three carry a
        // selector. Their `symbolsByTitle` entries are belt-and-braces for English.
        let selectorForExemptTitle = [
            "hide others": "hideOtherApplications:",
            "new": "newDocument:",
            "zoom": "performZoom:"
        ]
        for (title, selector) in selectorForExemptTitle {
            XCTAssertNotNil(
                MainMenuIconDecorator.symbolsByAction[selector],
                "\"\(title)\" is exempt from the localized-alias rule ONLY because \(selector) covers it"
            )
        }
        let resolvedBySelector = Set(selectorForExemptTitle.keys)

        // "Split" is a toolbar/mode label, not a menu row — no Swift literal spells it as a
        // menu title (the View ▸ Mode picker shows "Preview" for .split), so there is
        // nothing to translate. The map entry is defensive.
        let notAMenuTitle: Set<String> = ["split"]

        let exempt = acceptedLosses.union(resolvedBySelector).union(notAMenuTitle)
        let languages = ["es", "fr", "de", "ja", "zh-Hans"]
        let aliasesByLanguage = Dictionary(
            uniqueKeysWithValues: languages.map { ($0, MainMenuIconDecorator.localizedAliases(languageCode: $0)) }
        )

        for englishNormalized in MainMenuIconDecorator.symbolsByTitle.keys where !exempt.contains(englishNormalized) {
            for language in languages {
                XCTAssertNotNil(aliasesByLanguage[language]?[englishNormalized],
                                "\(englishNormalized): no localized title in \(language)")
            }

            // A system-provided entry carries real Apple translations, so at least one
            // language must differ from the English key — otherwise the generated table
            // is degenerate for that row (this is how the FunctionKeyNames keycap rows,
            // whose "translation" of Find/Print/Stop was the English word, were caught).
            // Not "all five": French legitimately keeps "Services", "Substitutions",
            // "Transformations", and German keeps "Link".
            if MainMenuIconDecorator.systemProvidedNormalizedKeys.contains(englishNormalized) {
                XCTAssertTrue(
                    languages.contains { aliasesByLanguage[$0]?[englishNormalized] != englishNormalized },
                    "\(englishNormalized): every alias is just the English title — no real translation source"
                )
            }
        }
    }

    func testRuntimeLanguageDerivationMatchesCatalogFolderNames() {
        // Locale.language.languageCode collapses zh-Hans to "zh", which matches neither
        // the SystemMenuItemTitles keys nor the compiled zh-Hans.lproj folder. The
        // runtime code must use Bundle.main.preferredLocalizations — this pin keeps it so.
        XCTAssertEqual(MainMenuIconDecorator.runtimeLanguageCode(preferredLocalizations: ["zh-Hans", "en"]),
                       "zh-Hans")
        XCTAssertEqual(MainMenuIconDecorator.runtimeLanguageCode(preferredLocalizations: []), "en")
    }

    /// Guards the "quit is not a document action" class of copy/paste error in the table:
    /// two different rows may share a glyph, but a row must never lose one.
    func testKnownStandardSelectorsAreMapped() {
        let required = [
            "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:", "delete:",
            "hide:", "hideOtherApplications:", "unhideAllApplications:", "terminate:",
            "newDocument:", "openDocument:", "printDocument:",
            "performMiniaturize:", "performZoom:", "arrangeInFront:"
        ]

        for selector in required {
            XCTAssertNotNil(
                MainMenuIconDecorator.symbolsByAction[selector],
                "Standard selector \(selector) has no icon mapping"
            )
        }
    }

    func testSeparatorsAreNeverDecorated() {
        XCTAssertNil(MainMenuIconDecorator.symbolName(for: .separator()))
    }

    /// The Format menu drew bare on every row for weeks while its items provably resolved the
    /// right symbols. Cause: when a `CommandMenu` is about to open, SwiftUI updates its EXISTING
    /// items rather than inserting new ones, and that update clears `image`. No `didAddItem`
    /// fires for it, so decoration never ran again and the bare menu is what got drawn.
    ///
    /// This pins the recovery path: a `didChangeItem` on a menu must re-apply the icons.
    func testDidChangeItemReappliesClearedIcons() {
        MainMenuIconDecorator.installIfNeeded()

        let menu = NSMenu()
        let item = NSMenuItem(title: "Bold", action: nil, keyEquivalent: "")
        menu.addItem(item)
        XCTAssertNotNil(item.image, "insertion should have decorated the row")

        // Exactly what SwiftUI's update does to a row it owns.
        item.image = nil
        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: menu)

        XCTAssertNotNil(item.image, "a cleared icon was never re-applied — Format renders bare")
    }

    /// Assigning `image` posts `didChangeItem`, the very notification that triggers decoration.
    /// The re-entrancy guard plus the identity check must make that settle instead of recursing.
    func testDecoratingDoesNotRecurseThroughItsOwnNotifications() {
        MainMenuIconDecorator.installIfNeeded()

        let menu = NSMenu()
        for title in ["Bold", "Italic", "Link", "Blockquote"] {
            menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        for item in menu.items {
            item.image = nil
        }

        // Would hang or blow the stack if each write re-entered a full walk.
        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: menu)

        for item in menu.items {
            XCTAssertNotNil(item.image, "\(item.title) was left bare")
        }
    }
}

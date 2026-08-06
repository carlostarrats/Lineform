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

        for title in titles {
            let key = MainMenuIconDecorator.normalizedTitle(title)
            XCTAssertNotNil(
                MainMenuIconDecorator.symbolsByTitle[key],
                "Menu title \"\(title)\" (key \"\(key)\") has no icon mapping"
            )
        }
    }

    /// `allEnglishTitleKeys` is hand-maintained and is how the decorator learns each of our
    /// own rows' LOCALIZED title. A key left out costs that row its icon in every non-English
    /// locale, invisibly — nothing about the English build changes.
    ///
    /// This must scan the SOURCE, not a list maintained here: a second hand-maintained list
    /// only fails when someone remembers to update it too, which is the same failure mode.
    /// 28 of the keys are also in the AppKit table, so the locale test's alias check is
    /// satisfied by `systemAliases` and would never notice their absence from the array.
    func testEveryLocalizedMenuTitleLiteralIsInAllEnglishTitleKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Lineform/App/AppCommands.swift"), encoding: .utf8)
        let keys = Set(AppMenuConfiguration.allEnglishTitleKeys)

        let literals = source.matches(of: /String\(localized: "([^"]+)"/).map { String($0.1) }
        // If the call style ever changes, the regex stops matching and every assertion below
        // passes vacuously. Fail instead.
        XCTAssertFalse(literals.isEmpty, "no String(localized:) literals found — the scan has gone blind")

        for literal in literals {
            XCTAssertTrue(keys.contains(literal), "\"\(literal)\" is missing from allEnglishTitleKeys")
        }

        // Menu titles declared outside AppCommands.swift: the Export As submenu's rows and the
        // View ▸ Mode picker's rows.
        for title in ExportFormat.allCases.map(\.title) + EditorDisplayMode.allCases.map(\.title) {
            XCTAssertTrue(keys.contains(title), "\"\(title)\" is missing from allEnglishTitleKeys")
        }
    }

    /// A localized title claimed by two English keys with different symbols draws one row's
    /// glyph on the other, and written out of an unordered Dictionary the survivor varied
    /// between processes. ONE such collision is live: `fr` collapses AppKit's "AutoFill" and
    /// "Fill" to "Remplir", which is Apple's wording and not ours to rename, so determinism is
    /// the whole fix. The `zh-Hans` Title/Heading collision was RESOLVED instead — see below.
    func testLocalizedAliasCollisionsResolveDeterministically() {
        // The live collision, pinned by name. A `where` filter cannot skip it into passing,
        // and it fails outright if either table's wording changes.
        let french = MainMenuIconDecorator.localizedSymbolsByNormalizedTitle(languageCode: "fr")
        XCTAssertEqual(french["remplir"], MainMenuIconDecorator.symbolsByTitle["autofill"],
                       "fr: \"Remplir\" is both AutoFill and Fill — \"autofill\" sorts first and must win")
        // zh-Hans USED to collapse "Title" and "Heading" to 标题, so the Format menu showed
        // ⌘1 and the H3-H6 submenu under one label and the survivor was decided by sort order.
        // Task 13 renamed Heading to 小标题 in BOTH the catalog and SystemMenuItemTitles, so
        // the collision is gone and each row keeps its own symbol. Asserted, not assumed: if
        // either table drifts back to 标题 this fails rather than silently re-colliding.
        let chinese = MainMenuIconDecorator.localizedSymbolsByNormalizedTitle(languageCode: "zh-Hans")
        XCTAssertEqual(chinese["标题"], MainMenuIconDecorator.symbolsByTitle["title"],
                       "zh-Hans: 标题 is Title alone now — Heading is 小标题")
        XCTAssertEqual(chinese["小标题"], MainMenuIconDecorator.symbolsByTitle["heading"],
                       "zh-Hans: 小标题 is Heading")

        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let first = MainMenuIconDecorator.localizedSymbolsByNormalizedTitle(languageCode: language)
            let second = MainMenuIconDecorator.localizedSymbolsByNormalizedTitle(languageCode: language)
            XCTAssertEqual(first, second, "\(language): the map is not stable across builds")

            // The known collisions must land on the first-sorted English key's symbol.
            let aliases = MainMenuIconDecorator.localizedAliases(languageCode: language)
            var claimant: [String: String] = [:]
            for englishNormalized in aliases.keys.sorted() {
                guard let localized = aliases[englishNormalized],
                      let symbol = MainMenuIconDecorator.symbolsByTitle[englishNormalized] else { continue }
                if let existing = claimant[localized] {
                    XCTAssertEqual(
                        first[localized], MainMenuIconDecorator.symbolsByTitle[existing],
                        "\(language): \"\(localized)\" is claimed by both \"\(existing)\" and "
                            + "\"\(englishNormalized)\" — the earlier English key must win"
                    )
                } else {
                    claimant[localized] = englishNormalized
                    XCTAssertEqual(first[localized], symbol,
                                   "\(language): \"\(localized)\" did not resolve to \(symbol)")
                }
            }
        }
    }

    /// `language:englishNormalizedKey` pairs where Apple's translation IS the English word.
    /// The complete set at macOS 26.5 — anything else equal to English means a degenerate
    /// table row, not a translation.
    static let englishIsTheTranslation: Set<String> = [
        "fr:services", "fr:substitutions", "fr:transformations", "fr:contact",
        "de:link", "de:pause", "fr:pause"
    ]

    /// The runtime map deliberately keeps the English keys as a safety net, so probing it
    /// can never fail. The thing that can actually regress is the LOCALIZED alias, which is
    /// what this asserts.
    func testEveryTitleKeyedEntryGainsALocalizedAliasInAllShippedLocales() {
        // "Passwords" / "Credit Card" used to be exempted here as having no Apple translation
        // source. They do have one — macOS 26.5's InputManager.loctable carries both and the
        // generated SystemMenuItemTitles.swift picks them up — so the exemption was asserting
        // less than the code delivers. Removed: they now go through the same rule as every
        // other row, and if AppKit ever drops them this fails instead of passing quietly.

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

        let exempt = resolvedBySelector.union(notAMenuTitle)
        let languages = ["es", "fr", "de", "ja", "zh-Hans"]
        let aliasesByLanguage = Dictionary(
            uniqueKeysWithValues: languages.map { ($0, MainMenuIconDecorator.localizedAliases(languageCode: $0)) }
        )

        for englishNormalized in MainMenuIconDecorator.symbolsByTitle.keys where !exempt.contains(englishNormalized) {
            for language in languages {
                XCTAssertNotNil(aliasesByLanguage[language]?[englishNormalized],
                                "\(englishNormalized): no localized title in \(language)")
            }

            // A system-provided entry carries a real Apple translation, so EVERY language
            // must differ from the English key — with seven named exceptions below where the
            // English word genuinely is the translation. The strict form is what keeps
            // `EXCLUDED_TABLES` in extract-system-menu-titles.py load-bearing: drop
            // FunctionKeyNames.loctable and its keycap legends re-win Find/Print/Pause/Stop
            // (it sorts before InputManager and the script uses setdefault), shipping ja
            // "Find" and zh "Pause" as menu titles. A "some language differs" form passes on
            // all four of those and would let the regeneration through.
            if MainMenuIconDecorator.systemProvidedNormalizedKeys.contains(englishNormalized) {
                for language in languages
                where !Self.englishIsTheTranslation.contains("\(language):\(englishNormalized)") {
                    XCTAssertNotEqual(aliasesByLanguage[language]?[englishNormalized], englishNormalized,
                                      "\(englishNormalized): \(language) alias is just the English title")
                }
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

        // The pure function above stays green even if the DEFAULT argument is switched to
        // Locale.current.language.languageCode — which is the exact forbidden regression.
        // This pins the default itself to preferredLocalizations.
        XCTAssertEqual(MainMenuIconDecorator.runtimeLanguageCode(),
                       Bundle.main.preferredLocalizations.first ?? "en")
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

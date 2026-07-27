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

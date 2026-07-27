import AppKit

/// Selector target for the `NSMenu` notifications. Exists only because the block-based observer
/// API cannot hand a non-Sendable `NSMenu` to a main-actor closure.
@MainActor
final class MenuNotificationObserver: NSObject {
    @objc func menuChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        MainMenuIconDecorator.decorate(menu)
    }
}

/// Puts an SF Symbol on every main-menu row, matching the iconed menus Apple's own apps
/// ship on macOS 26 (Safari, Finder, TextEdit).
///
/// Why this is an AppKit pass instead of SwiftUI `Label`s in `AppCommands`: SwiftUI only
/// owns the items we declare. Undo/Redo, Cut/Copy/Paste, Services, Hide/Quit, Minimize/Zoom
/// and the whole Window menu come from AppKit and never pass through `Commands`. A File menu
/// where our rows have glyphs and the inherited ones don't reads as broken, so the entire
/// menu bar is decorated in one place.
///
/// Matching is by action selector first (stable, localization-proof) and by normalized title
/// second (the only handle SwiftUI's command items offer — they all share a private action).
/// Unmapped rows are left bare rather than given a filler glyph.
@MainActor
enum MainMenuIconDecorator {
    private static var installed = false
    private static let observer = MenuNotificationObserver()

    /// A single pass at launch is not enough. Two things discard the images afterwards:
    ///
    /// - `CommandMenu("Format")` is a menu SwiftUI owns outright, and it repopulates the whole
    ///   thing lazily when the menu is about to open — after any tracking-start hook has run.
    ///   Decorating only on `didBeginTracking` left Format as the one bare menu in the bar.
    /// - The Format menu's items also swap wholesale between the Markdown and plain-text sets.
    ///
    /// So insertion itself is the trigger: `didAddItem` fires exactly when SwiftUI rebuilds a
    /// menu, and it cannot feed back on itself — assigning `image` posts `didChangeItem`, a
    /// different notification, which is deliberately not observed.
    static func installIfNeeded() {
        guard !installed else { return }
        installed = true

        // Selector-based observation, not the closure form: the closure form cannot touch the
        // notification's `object` (NSMenu is not Sendable), and the posting menu is exactly what
        // must be decorated. SwiftUI builds a replacement Format menu DETACHED, fills it, and
        // only then swaps it in — so a walk of `NSApp.mainMenu` at insertion time decorates the
        // outgoing menu and the fresh, bare one is what gets drawn.
        for name in [NSMenu.didAddItemNotification, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(
                observer,
                selector: #selector(MenuNotificationObserver.menuChanged(_:)),
                name: name,
                object: nil
            )
        }

        decorateMainMenu()
    }

    static func decorateMainMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        decorate(mainMenu, recursive: true)
    }

    /// Decorates one menu and its submenus, wherever it currently lives — including a menu that
    /// is still detached from the menu bar.
    static func decorate(_ menu: NSMenu) {
        decorate(menu, recursive: true)
    }

    private static func decorate(_ menu: NSMenu, recursive: Bool) {
        // The menu bar's own row (Lineform, File, Edit, …) never takes an icon — Apple's apps
        // don't, and an image there would push the titles apart.
        let isMenuBar = menu === NSApp.mainMenu

        for item in menu.items {
            if !isMenuBar, let symbol = symbolName(for: item) {
                let icon = image(named: symbol)
                // Identity check, not just nil: `didAddItem` fires once per inserted row, so a
                // menu rebuild re-walks the bar dozens of times. Skipping settled rows keeps
                // that to a pointer comparison.
                if item.image !== icon {
                    item.image = icon
                }
            }

            if recursive, let submenu = item.submenu {
                decorate(submenu, recursive: true)
            }
        }
    }

    // MARK: - Symbol lookup

    static func symbolName(for item: NSMenuItem) -> String? {
        if item.isSeparatorItem { return nil }

        if let action = item.action, let symbol = symbolsByAction[NSStringFromSelector(action)] {
            return symbol
        }

        return symbolsByTitle[normalizedTitle(item.title)]
    }

    /// Lowercases, drops trailing ellipses, and removes the app name so "About Lineform",
    /// "Hide Lineform" and "Quit Lineform" map without hard-coding the product name twice.
    static func normalizedTitle(_ title: String) -> String {
        var normalized = title.replacingOccurrences(of: "Lineform", with: "")
        normalized = normalized.trimmingCharacters(in: .whitespaces)
        while normalized.hasSuffix("…") || normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Cached so repeated decoration passes reuse one `NSImage` per symbol — which is also what
    /// makes the identity check in `decorate` meaningful.
    private static var imageCache: [String: NSImage] = [:]

    private static func image(named symbol: String) -> NSImage? {
        if let cached = imageCache[symbol] {
            return cached
        }

        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return nil
        }

        // Menu font is 14pt; matching the symbol to it keeps rows at their natural height.
        let configured = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        )
        configured?.isTemplate = true
        imageCache[symbol] = configured
        return configured
    }

    /// Standard AppKit items, keyed by selector. Deliberately covers the items SwiftUI
    /// inherits rather than declares.
    static let symbolsByAction: [String: String] = [
        // Application menu
        "orderFrontStandardAboutPanel:": "info.circle",
        "hide:": "eye.slash",
        "hideOtherApplications:": "eye.slash.circle",
        "unhideAllApplications:": "eye",
        "terminate:": "power",
        // File menu
        "newDocument:": "doc.badge.plus",
        "openDocument:": "folder",
        "clearRecentDocuments:": "clock.arrow.circlepath",
        "performClose:": "xmark.circle",
        "saveDocument:": "square.and.arrow.down",
        "saveDocumentAs:": "square.and.arrow.down.on.square",
        "revertDocumentToSaved:": "arrow.uturn.backward.circle",
        "duplicateDocument:": "plus.square.on.square",
        "runPageLayout:": "doc",
        "printDocument:": "printer",
        // Edit menu
        "undo:": "arrow.uturn.backward",
        "redo:": "arrow.uturn.forward",
        "cut:": "scissors",
        "copy:": "doc.on.doc",
        "paste:": "doc.on.clipboard",
        "pasteAsPlainText:": "doc.on.clipboard",
        "delete:": "delete.left",
        "selectAll:": "checkmark.circle",
        "startDictation:": "mic",
        "orderFrontCharacterPalette:": "face.smiling",
        "showGuessPanel:": "text.book.closed",
        "checkSpelling:": "textformat.abc.dottedunderline",
        // View menu
        "toggleToolbarShown:": "menubar.rectangle",
        "runToolbarCustomizationPalette:": "wrench.adjustable",
        "toggleSidebar:": "sidebar.left",
        "toggleFullScreen:": "arrow.up.left.and.arrow.down.right",
        // Window menu
        "performMiniaturize:": "minus.circle",
        "performZoom:": "arrow.up.left.and.arrow.down.right.square",
        "arrangeInFront:": "square.stack",
        "toggleTabBar:": "rectangle.topthird.inset.filled",
        "toggleTabOverview:": "square.grid.2x2",
        "mergeAllWindows:": "square.stack.3d.down.right",
        "moveTabToNewWindow:": "macwindow.on.rectangle"
    ]

    /// SwiftUI-declared items (all share one private action, so title is the only handle),
    /// plus AppKit rows that carry no selector of their own — keys are `normalizedTitle`
    /// output, so lowercase with ellipses and the app name already stripped.
    static let symbolsByTitle: [String: String] = [
        // Application menu
        "about": "info.circle",
        "settings": "gearshape",
        "check for updates": "arrow.triangle.2.circlepath",
        "install command line tool": "terminal",
        "privacy policy": "hand.raised",
        "terms of use": "doc.text",
        "services": "square.grid.2x2",
        "hide others": "eye.slash.circle",
        "show all": "eye",
        // File menu
        "new": "doc.badge.plus",
        "new tab": "plus.square.on.square",
        "open": "folder",
        "open recent": "clock.arrow.circlepath",
        "clear menu": "trash",
        "jump to file": "doc.text.magnifyingglass",
        "close": "xmark.circle",
        "close tab": "xmark.rectangle",
        "save": "square.and.arrow.down",
        "save as": "square.and.arrow.down.on.square",
        // Export As pairs against Save: down means bytes land in your file, up means a copy leaves.
        "export as": "square.and.arrow.up",
        "html": "chevron.left.forwardslash.chevron.right",
        "pdf": "doc.plaintext",
        "styled pdf": "doc.richtext",
        "rich text (.rtf)": "textformat",
        "rename": "pencil",
        "delete": "trash",
        "select next tab": "arrow.right",
        "select previous tab": "arrow.left",
        "print": "printer",
        // Edit menu
        "find": "magnifyingglass",
        "find & replace": "text.magnifyingglass",
        "speech": "waveform",
        "start speaking": "play.circle",
        "pause": "pause.circle",
        "resume": "play.circle",
        "stop": "stop.circle",
        "spelling and grammar": "textformat.abc.dottedunderline",
        "substitutions": "textformat",
        "transformations": "textformat.size",
        "emoji & symbols": "face.smiling",
        // Edit ▸ Writing Tools and ▸ AutoFill are injected by AppKit, not declared anywhere in
        // this app. Every row shares one selector, so these can only match by title.
        "writing tools": "wand.and.stars",
        "show writing tools": "sparkles",
        "proofread": "text.badge.checkmark",
        "rewrite": "pencil.line",
        "make friendly": "face.smiling",
        "make professional": "briefcase",
        "make concise": "arrow.down.right.and.arrow.up.left",
        "summarize": "text.alignleft",
        "create key points": "list.bullet",
        "make list": "list.bullet.rectangle",
        "make table": "tablecells",
        "compose": "square.and.pencil",
        "autofill": "rectangle.and.pencil.and.ellipsis",
        "contact": "person.crop.circle",
        "passwords": "key",
        "credit card": "creditcard",
        // Format menu
        "title": "textformat.size.larger",
        "section": "textformat.size.smaller",
        "heading": "textformat",
        "heading 3": "textformat.size.smaller",
        "heading 4": "textformat.size.smaller",
        "heading 5": "textformat.size.smaller",
        "heading 6": "textformat.size.smaller",
        "body": "textformat.size",
        "bold": "bold",
        "italic": "italic",
        "code": "chevron.left.forwardslash.chevron.right",
        "strikethrough": "strikethrough",
        "blockquote": "text.quote",
        "bulleted list": "list.bullet",
        "numbered list": "list.number",
        "link": "link",
        "insert table": "tablecells",
        "reformat table": "tablecells.badge.ellipsis",
        "convert to plain text": "arrow.left.arrow.right",
        "convert to markdown": "arrow.left.arrow.right",
        // View menu
        "mode": "rectangle.split.2x1",
        "write": "pencil",
        "read": "book",
        "split": "rectangle.split.2x1",
        "preview": "rectangle.split.2x1",
        "toggle write / read": "book.pages",
        "toggle outline": "list.bullet.indent",
        "show hidden folders": "eye",
        "reading experience": "slider.horizontal.3",
        "show toolbar": "menubar.rectangle",
        "hide toolbar": "menubar.rectangle",
        "customize toolbar": "wrench.adjustable",
        "show sidebar": "sidebar.left",
        "hide sidebar": "sidebar.left",
        "enter full screen": "arrow.up.left.and.arrow.down.right",
        "exit full screen": "arrow.down.right.and.arrow.up.left",
        // Window menu
        "minimize": "minus.circle",
        "zoom": "arrow.up.left.and.arrow.down.right.square",
        "fill": "rectangle.fill",
        "center": "rectangle.center.inset.filled",
        "move & resize": "macwindow.on.rectangle",
        "full screen tile": "rectangle.split.2x1",
        "remove window from set": "minus.rectangle",
        "bring all to front": "square.stack",
        "show previous tab": "arrow.left",
        "show next tab": "arrow.right",
        "move tab to new window": "macwindow.on.rectangle",
        "merge all windows": "square.stack.3d.down.right"
    ]

    // MARK: - Debug

    /// Dumps the live menu tree (title, selector, resolved symbol) so the mapping above can be
    /// checked against what AppKit + SwiftUI actually build. Enabled with
    /// `LINEFORM_DUMP_MAIN_MENU=1`; never runs in a normal launch.
    static func dumpMainMenuIfRequested() {
        guard ProcessInfo.processInfo.environment["LINEFORM_DUMP_MAIN_MENU"] == "1" else { return }
        // Deferred: SwiftUI populates its command menus after the delegate callback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let mainMenu = NSApp.mainMenu else { return }
            emit("=== LINEFORM MAIN MENU DUMP ===")
            dump(mainMenu, depth: 0)
            emit("=== END MAIN MENU DUMP ===")
        }
    }

    /// stderr, not `print`: stdout is block-buffered when redirected to a file and the dump is
    /// read from a process that gets killed rather than exiting cleanly.
    private static func emit(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func dump(_ menu: NSMenu, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        for item in menu.items {
            if item.isSeparatorItem {
                emit("\(indent)---")
            } else {
                let selector = item.action.map(NSStringFromSelector) ?? "-"
                let symbol = symbolName(for: item) ?? "MISSING"
                emit("\(indent)\(item.title) | \(selector) | \(symbol)")
            }
            if let submenu = item.submenu {
                dump(submenu, depth: depth + 1)
            }
        }
    }
}

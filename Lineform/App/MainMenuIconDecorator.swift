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
    /// So insertion itself is a trigger: `didAddItem` fires when SwiftUI rebuilds a menu.
    ///
    /// Insertion alone is still not enough. When a `CommandMenu` is about to open, SwiftUI
    /// updates its EXISTING items in place rather than inserting fresh ones — and that update
    /// clears the image. No `didAddItem` fires for it, and it lands after `didBeginTracking`,
    /// so Format drew bare on every row while every other menu was iconed. The only
    /// notification that reports it is `didChangeItem`, which is why it is observed here
    /// despite being the one our own writes post: `isDecorating` swallows the re-entrant round,
    /// and the identity check in `decorate` means a settled row is never written twice anyway.
    static func installIfNeeded() {
        guard !installed else { return }
        installed = true

        // Selector-based observation, not the closure form: the closure form cannot touch the
        // notification's `object` (NSMenu is not Sendable), and the posting menu is exactly what
        // must be decorated. SwiftUI builds a replacement Format menu DETACHED, fills it, and
        // only then swaps it in — so a walk of `NSApp.mainMenu` at insertion time decorates the
        // outgoing menu and the fresh, bare one is what gets drawn.
        for name in [
            NSMenu.didAddItemNotification,
            NSMenu.didChangeItemNotification,
            NSMenu.didBeginTrackingNotification,
        ] {
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

    /// Guards the `didChangeItem` observation: assigning `image` posts that same notification,
    /// so without this every write would re-enter the walk. The identity check below already
    /// makes the recursion terminate, but this keeps it to one pass instead of one per row.
    private static var isDecorating = false

    private static func decorate(_ menu: NSMenu, recursive: Bool) {
        guard !isDecorating else { return }
        isDecorating = true
        defer { isDecorating = false }

        decorateItems(of: menu, recursive: recursive)
    }

    /// Identifier stamped on menus this decorator must leave alone.
    ///
    /// The observers are registered with `object: nil` — every `NSMenu` in the process — because
    /// SwiftUI builds a replacement `CommandMenu` DETACHED and only swaps it in afterwards, so the
    /// posting menu is the only reliable handle and a supermenu-chain test would reject exactly the
    /// case this exists for. The cost is that CONTEXT menus were stamped too: the editor's
    /// right-click menu came up with semantic SF Symbols on rows that read as main-menu commands,
    /// which no macOS app does. Tagging the app's own context menus is the narrow fix that keeps
    /// the detached-menu behavior intact.
    static let excludedMenuIdentifier = NSUserInterfaceItemIdentifier("com.lineform.menu.undecorated")

    private static func decorateItems(of menu: NSMenu, recursive: Bool) {
        // The menu bar's own row (Lineform, File, Edit, …) never takes an icon — Apple's apps
        // don't, and an image there would push the titles apart.
        let isMenuBar = menu === NSApp.mainMenu
        guard menu.identifier != excludedMenuIdentifier else { return }

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
                decorateItems(of: submenu, recursive: true)
            }
        }
    }

    // MARK: - Symbol lookup

    static func symbolName(for item: NSMenuItem) -> String? {
        if item.isSeparatorItem { return nil }

        if let action = item.action, let symbol = symbolsByAction[NSStringFromSelector(action)] {
            return symbol
        }

        return runtimeTitleMap[normalizedTitle(item.title)]
    }

    // MARK: - Localized title matching

    /// The resolved app language, in the form that matches both the compiled
    /// `<lang>.lproj` folder names and `SystemMenuItemTitles`' keys. NEVER derive this
    /// from `Locale.language.languageCode` — it collapses "zh-Hans" to "zh", which
    /// matches neither (verified), silently losing every title-keyed icon in Chinese.
    static func runtimeLanguageCode(
        preferredLocalizations: [String] = Bundle.main.preferredLocalizations
    ) -> String {
        preferredLocalizations.first ?? "en"
    }

    /// englishNormalizedKey → the localized title's NORMALIZED form, taken from the
    /// generated AppKit table. Sorted so a key that two English spellings normalize to
    /// ("Bold"/"bold") resolves deterministically, and to the Title-cased row — the one
    /// a menu actually shows.
    private static func systemAliases(languageCode: String) -> [String: String] {
        var aliases: [String: String] = [:]
        for englishTitle in SystemMenuItemTitles.titles.keys.sorted() {
            let normalized = normalizedTitle(englishTitle)
            guard symbolsByTitle[normalized] != nil, aliases[normalized] == nil else { continue }
            if let localized = SystemMenuItemTitles.titles[englishTitle]?[languageCode] {
                aliases[normalized] = normalizedTitle(localized)
            }
        }
        return aliases
    }

    /// englishNormalizedKey → the localized title's NORMALIZED form, taken from our own
    /// localization catalog. The catalog key is the pre-normalization English title,
    /// exactly as the `AppCommands` literal reads (ASCII "..." kept).
    ///
    /// Falls back to the English title when the language has no compiled `.lproj` yet or
    /// the key is untranslated — the same value `localizedString(forKey:value:)` returns
    /// once it does exist, so the alias set does not change shape as translations land.
    private static func catalogAliases(languageCode: String) -> [String: String] {
        let bundle = Bundle.main.path(forResource: languageCode, ofType: "lproj")
            .flatMap(Bundle.init(path:))

        var aliases: [String: String] = [:]
        for title in AppMenuConfiguration.allEnglishTitleKeys {
            let normalized = normalizedTitle(title)
            guard symbolsByTitle[normalized] != nil, aliases[normalized] == nil else { continue }
            let localized = bundle?.localizedString(forKey: title, value: title, table: nil) ?? title
            aliases[normalized] = normalizedTitle(localized)
        }
        return aliases
    }

    /// englishNormalizedKey → the localized title's NORMALIZED form, for every entry
    /// that has a translation source (the generated system table, or our catalog).
    /// Split out from the map builder so the test can assert aliases exist without
    /// the English fallback masking a miss.
    static func localizedAliases(languageCode: String) -> [String: String] {
        var aliases = systemAliases(languageCode: languageCode)
        for (key, localized) in catalogAliases(languageCode: languageCode) where aliases[key] == nil {
            aliases[key] = localized
        }
        return aliases
    }

    /// English normalized keys that resolve from the generated system table — the
    /// test uses this to know which aliases must differ from English pre-translation.
    static var systemProvidedNormalizedKeys: Set<String> {
        Set(SystemMenuItemTitles.titles.keys.map(normalizedTitle))
            .intersection(symbolsByTitle.keys)
    }

    /// Per-language lookup used by `symbolName(for:)`. English keys stay in the map
    /// unconditionally: harmless in English, the safety net everywhere else. Built
    /// once per process — the menu language cannot change mid-run.
    ///
    /// BOTH alias sources are registered, not just the one `localizedAliases` picked:
    /// ~25 titles ("Bold", "Save", "Stop", "Strikethrough"…) exist in AppKit's table AND
    /// in our catalog, and a translator who chooses a different word than Apple for one
    /// of our own rows would otherwise lose that row's icon. Extra aliases are free —
    /// this is a lookup table, and a miss is what costs an icon.
    static func localizedSymbolsByNormalizedTitle(languageCode: String) -> [String: String] {
        var map = symbolsByTitle
        for aliases in [systemAliases(languageCode: languageCode), catalogAliases(languageCode: languageCode)] {
            // Two English titles can share ONE localized title — fr collapses "AutoFill" and
            // "Fill" to "Remplir", zh-Hans collapses "Title" and "Heading" to 标题 — and those
            // pairs carry DIFFERENT symbols. Written straight out of an unordered Dictionary,
            // the survivor varied between processes: in Chinese, Format ▸ Title drew Heading's
            // glyph or the reverse, differently on each launch. First sorted English key wins,
            // so the collision resolves the same way every time.
            var claimed = Set<String>()
            for englishNormalized in aliases.keys.sorted() {
                guard let localized = aliases[englishNormalized],
                      let symbol = symbolsByTitle[englishNormalized],
                      claimed.insert(localized).inserted else { continue }
                map[localized] = symbol
            }
        }
        return map
    }

    private static let runtimeTitleMap: [String: String] =
        localizedSymbolsByNormalizedTitle(languageCode: runtimeLanguageCode())

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
        // The submenu's own three rows. Without these it was the only bare submenu in the bar —
        // and it is the app's ONLY off switch for spell checking, so it is the last one that
        // should look unfinished.
        "check spelling while typing": "text.badge.checkmark",
        "show spelling and grammar": "textformat.abc.dottedunderline",
        "check document now": "doc.text.magnifyingglass",
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
        "merge all windows": "square.stack.3d.down.right",
        // Help menu
        "guide": "book"
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
                // Resolution and application are different failures: a row can map to the right
                // symbol and still draw bare if nothing ever assigned the image.
                let applied = item.image == nil ? "NO IMAGE" : "image"
                emit("\(indent)\(item.title) | \(selector) | \(symbol) | \(applied)")
            }
            if let submenu = item.submenu {
                dump(submenu, depth: depth + 1)
            }
        }
    }
}

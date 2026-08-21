import AppKit
import SwiftUI

enum AppMenuCommandPlacement: Equatable {
    case view
}

enum ManualSaveIntentMonitor {
    @MainActor private static var installed = false

    /// Observes ⌘S / ⌘⇧S so a keyboard-initiated Save is attributed to the user
    /// (green "Saved") rather than an autosave (green "Autosaved"). Pure observation:
    /// it returns the event unchanged and never swallows the keystroke or touches the
    /// save machinery itself.
    @MainActor
    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandS = mods.contains(.command)
                && !mods.contains(.option)
                && !mods.contains(.control)
                && event.charactersIgnoringModifiers?.lowercased() == "s"
            if isCommandS {
                DocumentSaveStatus.shared.noteManualSaveIntent()
            }
            return event
        }
    }
}

enum AppMenuConfiguration {
    static let aboutCommandTitle = String(localized: "About Lineform")
    static let settingsCommandTitle = String(localized: "Settings…")
    /// MUST match `MARKETING_VERSION` in the project. This is a hand-maintained string, so it
    /// drifts silently on a version bump — it shipped as V1.2.0 while the app was 1.3.0. The
    /// release checklist in `Lineform/Resources/ReleaseReadiness.md` now calls it out explicitly.
    static let aboutVersionDisplay = "V1.6.1"
    /// The Info.plist `NSHumanReadableCopyright` pair for `ReleaseResourceTests`, not display
    /// copy — the visible About-panel copyright comes from `NSHumanReadableCopyright` itself
    /// (localized via `Lineform/InfoPlist.xcstrings`), which macOS's standard About panel reads
    /// automatically. This constant must stay a plain English literal matching the Info.plist
    /// SOURCE string exactly; wrapping it in `String(localized:)` would compare a resolved
    /// string against a source string and quietly stop testing what it exists to test.
    static let aboutCopyright = "Copyright © 2026 Carlos Tarrats. All rights reserved."
    static let saveCommandTitle = String(localized: "Save")
    static let saveAsCommandTitle = String(localized: "Save As...")
    static let saveAsCommandKeyEquivalent = "S"
    // Three-period ellipsis matches the surrounding File-menu titles ("Save As...").
    static let renameFileCommandTitle = String(localized: "Rename...")
    static let deleteFileCommandTitle = String(localized: "Delete...")
    static let jumpToFileCommandTitle = String(localized: "Jump to File…")
    static let jumpToFileCommandKeyEquivalent = "k"
    static let closeTabCommandKeyEquivalent = "w"
    static let closeTabCommandModifiers: EventModifiers = .command
    /// Format > Link's shortcut letter. Was "k" until quick-open claimed Cmd+K
    /// (2026-07-17 spec); the text view's right-click menu hint must stay in sync.
    static let linkCommandKeyEquivalent = "l"
    static let printCommandTitle = String(localized: "Print...")
    static let privacyPolicyCommandTitle = String(localized: "Privacy Policy")
    static let termsOfUseCommandTitle = String(localized: "Terms of Use")
    static let privacyPolicyURL = "https://lineform.app/privacy"
    static let termsOfUseURL = "https://lineform.app/terms"
    static let guideCommandTitle = String(localized: "Lineform Guide")
    static let guideURL = "https://lineform.app/info/"
    /// The Help menu still replaces AppKit's default "Lineform Help" row (which opens a help book
    /// this app does not ship); it now carries the online guide instead of being empty.
    static let suppressesDefaultHelpMenu = true
    static let readingCommandPlacement = AppMenuCommandPlacement.view
    static let showHiddenFoldersCommandTitle = String(localized: "Show Hidden Folders")
    static let showHiddenFoldersCommandKeyEquivalent = "."
    static let findCommandTitle = String(localized: "Find")
    static let findCommandKeyEquivalent = "f"
    // ⌥⌘F — the macOS-standard Find & Replace shortcut (TextEdit/Pages).
    static let findReplaceCommandTitle = String(localized: "Find & Replace…")
    static let spellingMenuTitle = String(localized: "Spelling and Grammar")
    static let checkSpellingWhileTypingTitle = String(localized: "Check Spelling While Typing")
    static let showSpellingPanelTitle = String(localized: "Show Spelling and Grammar")
    static let checkDocumentNowTitle = String(localized: "Check Document Now")
    static let findReplaceCommandKeyEquivalent = "f"
    static let usesTopLevelReadingMenu = false
    static let addsWritingToolsToEditMenu = false
    static let exposesAppleWritingTools = false
    static let markdownFormattingCommandTitles = [
        String(localized: "Title"),
        String(localized: "Section"),
        String(localized: "Bold"),
        String(localized: "Italic"),
        String(localized: "Code"),
        String(localized: "Bulleted List"),
        String(localized: "Link")
    ]

    /// Every English menu title this app declares, byte-for-byte as the literal reads —
    /// including the deliberate mix of ASCII "..." and real "…" ellipses, because these
    /// are localization-catalog keys and a catalog lookup is an exact string match.
    ///
    /// `MainMenuIconDecorator` reads this to learn each row's LOCALIZED title: its icon
    /// table is keyed by normalized English, so without the localized alias ~108 menu
    /// rows lose their SF Symbol in every non-English locale — invisibly, since nothing
    /// in the English build changes. Completeness is asserted by
    /// `MainMenuIconDecoratorTests.testConfiguredCommandTitlesAllHaveIcons`, not remembered.
    ///
    /// A registrar that appended keys as the constants above initialize was rejected:
    /// Swift static stored properties are lazy, so the array would be empty or partial
    /// at the moment the decorator builds its map.
    static let allEnglishTitleKeys: [String] = [
        // Application menu
        "About Lineform",
        "Settings…",
        "Privacy Policy",
        "Terms of Use",
        // File menu
        "Save",
        "Save As...",
        "Export As",
        // ExportFormat.title — the Export As submenu's rows.
        "HTML",
        "PDF",
        "Styled PDF",
        "Rich Text (.rtf)",
        "Rename...",
        "Delete...",
        "Jump to File…",
        "Print...",
        "New Tab",
        "Close Tab",
        "Select Next Tab",
        "Select Previous Tab",
        // Edit menu
        "Find",
        "Find & Replace…",
        "Spelling and Grammar",
        "Check Spelling While Typing",
        "Show Spelling and Grammar",
        "Check Document Now",
        "Speech",
        "Start Speaking",
        "Pause",
        "Resume",
        "Stop",
        // Format menu
        "Format",
        "Title",
        "Section",
        "Heading",
        "Heading 3",
        "Heading 4",
        "Heading 5",
        "Heading 6",
        "Body",
        "Bold",
        "Italic",
        "Code",
        "Strikethrough",
        "Blockquote",
        "Bulleted List",
        "Numbered List",
        "Link",
        "Insert Table",
        "Reformat Table",
        "Convert to Plain Text",
        "Convert to Markdown",
        // View menu
        "Mode",
        // EditorDisplayMode.title — the Mode picker's rows.
        "Write",
        "Read",
        "Preview",
        "Toggle Write / Read",
        "Toggle Outline",
        "Show Hidden Folders",
        "Reading Experience",
        // Window menu
        "New Window",
        // Help menu
        "Lineform Guide"
    ]

    static func formatCommandTitles(for textFormat: LineformTextFormat) -> [String] {
        switch textFormat {
        case .markdown:
            return markdownFormattingCommandTitles + [conversionCommandTitle(for: textFormat)]
        case .plainText:
            return [conversionCommandTitle(for: textFormat)]
        }
    }

    static func conversionCommandTitle(for textFormat: LineformTextFormat) -> String {
        switch textFormat {
        case .markdown:
            return String(localized: "Convert to Plain Text")
        case .plainText:
            return String(localized: "Convert to Markdown")
        }
    }

    static func aboutPanelOptions(bundle: Bundle = .main) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationVersion: aboutVersionDisplay
        ]

        if
            let iconURL = bundle.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        {
            options[.applicationIcon] = icon
        }

        return options
    }
}

@MainActor
final class LineformTextFormatMenuState: ObservableObject {
    static let shared = LineformTextFormatMenuState()

    @Published private(set) var textFormat: LineformTextFormat

    init(textFormat: LineformTextFormat = .markdown) {
        self.textFormat = textFormat
    }

    func setTextFormat(_ textFormat: LineformTextFormat) {
        guard self.textFormat != textFormat else {
            return
        }

        self.textFormat = textFormat
        NSApp.mainMenu?.update()
    }
}

@MainActor
final class LineformDisplayModeMenuState: ObservableObject {
    static let shared = LineformDisplayModeMenuState()

    @Published private(set) var displayMode: EditorDisplayMode

    init(displayMode: EditorDisplayMode = .write) {
        self.displayMode = displayMode
    }

    func setDisplayMode(_ displayMode: EditorDisplayMode) {
        guard self.displayMode != displayMode else {
            return
        }

        self.displayMode = displayMode
        NSApp.mainMenu?.update()
    }
}

/// Shared source of truth for the "Show Hidden Folders" View-menu toggle and its checkmark.
///
/// The Files sidebar's `OutlineFileBrowserStore` is a per-window `@StateObject`, so a menu
/// command cannot mutate "the one store". This holds the app-wide preference (backed by the
/// same `UserDefaults` key the store reads at init) so the menu checkmark stays live, and
/// broadcasts `toggleHiddenFolders`. A window applies it to its store only while its Files tab
/// is visible, and otherwise reconciles when that tab next appears — keeping the store's
/// expensive iCloud scan deferred to that sanctioned point. The store's own `didSet` also
/// persists the key; both write it, and they agree because the menu is the sole toggle entry.
@MainActor
final class HiddenFoldersMenuState: ObservableObject {
    static let shared = HiddenFoldersMenuState()

    @Published private(set) var isOn: Bool

    private let defaults: UserDefaults
    private let defaultsKey: String

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = OutlineFileBrowserStore.showsHiddenFoldersDefaultsKey
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.isOn = defaults.bool(forKey: defaultsKey)
    }

    func setShowsHiddenFolders(_ on: Bool) {
        guard on != isOn else {
            return
        }

        isOn = on
        defaults.set(on, forKey: defaultsKey)
        NSApp.mainMenu?.update()
        LineformAppNotification.toggleHiddenFolders.post()
    }
}

/// Tracks the key window's current on-disk file so the File-menu Rename…/Delete…
/// commands can enable/disable correctly (untitled documents have no file to act on).
/// Same shared-state pattern as the other menu states: each window's editor container
/// updates it when it becomes key or its file URL changes.
@MainActor
final class LineformCurrentFileMenuState: ObservableObject {
    static let shared = LineformCurrentFileMenuState()

    @Published private(set) var currentFileURL: URL?

    func setCurrentFileURL(_ url: URL?) {
        guard url != currentFileURL else {
            return
        }

        currentFileURL = url
        NSApp.mainMenu?.update()
    }
}

/// Tracks the key window's `SpeechController` state so the Edit ▸ Speech submenu's Pause·Resume
/// label and enablement track the frontmost window. Same shared-state pattern as
/// `LineformCurrentFileMenuState`: each window's editor container pushes its controller's state
/// in whenever it becomes key or the state changes.
@MainActor
final class LineformSpeechMenuState: ObservableObject {
    static let shared = LineformSpeechMenuState()

    @Published private(set) var state: SpeechState = .idle

    func setState(_ state: SpeechState) {
        guard state != self.state else {
            return
        }

        self.state = state
        NSApp.mainMenu?.update()
    }
}

struct AppCommands: Commands {
    @ObservedObject private var textFormatMenuState: LineformTextFormatMenuState
    @ObservedObject private var displayModeMenuState: LineformDisplayModeMenuState
    @ObservedObject private var hiddenFoldersMenuState: HiddenFoldersMenuState
    @ObservedObject private var currentFileMenuState: LineformCurrentFileMenuState
    @ObservedObject private var speechMenuState: LineformSpeechMenuState
    @ObservedObject private var settingsStore: LineformSettingsStore

    init(
        textFormatMenuState: LineformTextFormatMenuState = .shared,
        displayModeMenuState: LineformDisplayModeMenuState = .shared,
        hiddenFoldersMenuState: HiddenFoldersMenuState = .shared,
        currentFileMenuState: LineformCurrentFileMenuState = .shared,
        speechMenuState: LineformSpeechMenuState = .shared,
        settingsStore: LineformSettingsStore = .shared
    ) {
        _textFormatMenuState = ObservedObject(wrappedValue: textFormatMenuState)
        _displayModeMenuState = ObservedObject(wrappedValue: displayModeMenuState)
        _hiddenFoldersMenuState = ObservedObject(wrappedValue: hiddenFoldersMenuState)
        _currentFileMenuState = ObservedObject(wrappedValue: currentFileMenuState)
        _speechMenuState = ObservedObject(wrappedValue: speechMenuState)
        _settingsStore = ObservedObject(wrappedValue: settingsStore)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(AppMenuConfiguration.aboutCommandTitle) {
                NSApp.orderFrontStandardAboutPanel(options: AppMenuConfiguration.aboutPanelOptions())
            }

            Divider()

            // Settings presents as a Muse-style in-window modal (SettingsModal) in the
            // MAIN document window — the app deliberately has no `Settings { }` scene,
            // so this button (with the standard ⌘,) is the whole entry point. With no
            // documents open, make one first (what ⌘N would do) so ⌘, always works;
            // a silent no-op here would break the platform expectation that Settings
            // opens from any app state.
            Button(AppMenuConfiguration.settingsCommandTitle) {
                if NSDocumentController.shared.documents.isEmpty {
                    NSDocumentController.shared.newDocument(nil)
                    // Let the fresh window become main before the modal presents.
                    DispatchQueue.main.async {
                        LineformAppNotification.showSettings.post()
                    }
                } else {
                    LineformAppNotification.showSettings.post()
                }
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button(AppMenuConfiguration.privacyPolicyCommandTitle) {
                if let url = URL(string: AppMenuConfiguration.privacyPolicyURL) {
                    NSWorkspace.shared.open(url)
                }
            }

            Button(AppMenuConfiguration.termsOfUseCommandTitle) {
                if let url = URL(string: AppMenuConfiguration.termsOfUseURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        // Replace the native save group (Save + Duplicate/Rename/Move/Revert) so Save As sits
        // directly under Save and owns ⌘⇧S — macOS otherwise binds ⌘⇧S to Duplicate and pushes a
        // custom Save As below the native items.
        CommandGroup(replacing: .saveItem) {
            Button(String(localized: "Save")) {
                DocumentSaveStatus.shared.noteManualSaveIntent()
                // An untitled tab has no destination. Route its first save through the
                // same Save As panel as ⌘⇧S so the iCloud-sidebar preference can choose
                // a non-iCloud starting folder. Sending AppKit's generic saveDocument:
                // here lets the document system reopen its iCloud document scope even
                // after the user hid it.
                if currentFileMenuState.currentFileURL == nil {
                    LineformAppNotification.saveAsDocument.post(
                        object: LineformAppNotification.activeWindowPayload()
                    )
                } else {
                    NSApp.sendAction(NSSelectorFromString("saveDocument:"), to: nil, from: nil)
                }
            }
            .keyboardShortcut("s", modifiers: .command)

            Button(AppMenuConfiguration.saveAsCommandTitle) {
                DocumentSaveStatus.shared.noteManualSaveIntent()
                LineformAppNotification.saveAsDocument.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut(
                KeyEquivalent(Character(AppMenuConfiguration.saveAsCommandKeyEquivalent)),
                modifiers: [.command, .shift]
            )

            // Export writes a COPY in another format and never touches the open document —
            // deliberately separate from Save As, which retargets the .md file itself. No
            // keyboard shortcuts: exporting is infrequent and a four-row submenu is already fast.
            Menu(String(localized: "Export As")) {
                ForEach(ExportFormat.allCases, id: \.rawValue) { format in
                    Button(format.title + "...") {
                        LineformAppNotification.exportDocument.post(
                            object: LineformAppNotification.activeWindowPayload(value: String(format.rawValue))
                        )
                    }
                }
            }

            Divider()

            // Same dialogs and behavior as the sidebar's right-click actions, targeting
            // the key window's current file. Deliberately no keyboard shortcuts: Delete
            // must never be one accidental keystroke away.
            Button(AppMenuConfiguration.renameFileCommandTitle) {
                LineformAppNotification.renameCurrentFile.post(object: LineformAppNotification.activeWindowPayload())
            }
            .disabled(currentFileMenuState.currentFileURL == nil)

            Button(AppMenuConfiguration.deleteFileCommandTitle) {
                LineformAppNotification.deleteCurrentFile.post(object: LineformAppNotification.activeWindowPayload())
            }
            .disabled(currentFileMenuState.currentFileURL == nil)
        }

        // Print + rich export live in the natural Print slot of the File menu. All render
        // the document the way Read mode does (white page, black ink), regardless of the current
        // display mode. Always enabled like Save As…; a post with no key window is a safe no-op.
        CommandGroup(replacing: .printItem) {
            Button(AppMenuConfiguration.printCommandTitle) {
                LineformAppNotification.printDocument.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("p", modifiers: .command)

        }

        CommandMenu(String(localized: "Format")) {
            if activeTextFormat == .markdown {
                Button(String(localized: "Title")) {
                    NSApp.sendAction(#selector(LineformTextView.toggleTitleMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button(String(localized: "Section")) {
                    NSApp.sendAction(#selector(LineformTextView.toggleSectionMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("2", modifiers: .command)

                Menu(String(localized: "Heading")) {
                    Button(String(localized: "Heading 3")) {
                        NSApp.sendAction(#selector(LineformTextView.toggleHeading3Markdown(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("3", modifiers: .command)

                    Button(String(localized: "Heading 4")) {
                        NSApp.sendAction(#selector(LineformTextView.toggleHeading4Markdown(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("4", modifiers: .command)

                    Button(String(localized: "Heading 5")) {
                        NSApp.sendAction(#selector(LineformTextView.toggleHeading5Markdown(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("5", modifiers: .command)

                    Button(String(localized: "Heading 6")) {
                        NSApp.sendAction(#selector(LineformTextView.toggleHeading6Markdown(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("6", modifiers: .command)

                    Divider()

                    Button(String(localized: "Body")) {
                        NSApp.sendAction(#selector(LineformTextView.toggleBodyMarkdown(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("0", modifiers: .command)
                }

                Divider()

                Button(String(localized: "Bold")) {
                    NSApp.sendAction(#selector(LineformTextView.toggleBoldMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button(String(localized: "Italic")) {
                    NSApp.sendAction(#selector(LineformTextView.toggleItalicMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button(String(localized: "Code")) {
                    NSApp.sendAction(#selector(LineformTextView.toggleInlineCodeMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("`", modifiers: .command)

                Button(String(localized: "Strikethrough")) {
                    NSApp.sendAction(#selector(LineformTextView.toggleStrikethroughMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])

                Divider()

                Button(String(localized: "Blockquote")) {
                    NSApp.sendAction(#selector(LineformTextView.toggleBlockquoteMarkdown(_:)), to: nil, from: nil)
                }

                Button(String(localized: "Bulleted List")) {
                    NSApp.sendAction(#selector(LineformTextView.toggleUnorderedListMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("8", modifiers: [.command, .shift])

                Button(String(localized: "Numbered List")) {
                    NSApp.sendAction(#selector(LineformTextView.toggleOrderedListMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("7", modifiers: [.command, .shift])

                Button(String(localized: "Link")) {
                    NSApp.sendAction(#selector(LineformTextView.toggleLinkMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(AppMenuConfiguration.linkCommandKeyEquivalent)),
                    modifiers: .command
                )

                Divider()

                Button(String(localized: "Insert Table")) {
                    NSApp.sendAction(#selector(LineformTextView.insertMarkdownTable(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .control])

                Button(String(localized: "Reformat Table")) {
                    NSApp.sendAction(#selector(LineformTextView.reformatMarkdownTable(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .control])

                Divider()
            }

            switch activeTextFormat {
            case .markdown:
                Button(AppMenuConfiguration.conversionCommandTitle(for: .markdown)) {
                    LineformAppNotification.convertTextFormat.post(
                        object: LineformAppNotification.activeWindowPayload(value: LineformTextFormat.plainText.rawValue)
                    )
                }
            case .plainText:
                Button(AppMenuConfiguration.conversionCommandTitle(for: .plainText)) {
                    LineformAppNotification.convertTextFormat.post(
                        object: LineformAppNotification.activeWindowPayload(value: LineformTextFormat.markdown.rawValue)
                    )
                }
            }
        }

        CommandGroup(after: .toolbar) {
            Picker(String(localized: "Mode"), selection: displayModeSelection) {
                ForEach(EditorDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Button(String(localized: "Toggle Write / Read")) {
                let target = displayModeMenuState.displayMode.toggledWriteRead
                displayModeMenuState.setDisplayMode(target)
                LineformAppNotification.setDisplayMode.post(
                    object: LineformAppNotification.activeWindowPayload(value: target.rawValue)
                )
            }
            .keyboardShortcut("e", modifiers: .command)

            Button(String(localized: "Toggle Outline")) {
                LineformAppNotification.toggleOutline.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("0", modifiers: [.command, .option])

            Toggle(AppMenuConfiguration.showHiddenFoldersCommandTitle, isOn: hiddenFoldersSelection)
                .keyboardShortcut(
                    KeyEquivalent(Character(AppMenuConfiguration.showHiddenFoldersCommandKeyEquivalent)),
                    modifiers: [.command, .shift]
                )

            Button(String(localized: "Reading Experience")) {
                LineformAppNotification.showReadingExperience.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Divider()
        }

        CommandGroup(after: .pasteboard) {
            Button(AppMenuConfiguration.findCommandTitle) {
                LineformAppNotification.focusSearch.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut(KeyEquivalent(Character(AppMenuConfiguration.findCommandKeyEquivalent)), modifiers: .command)

            Button(AppMenuConfiguration.findReplaceCommandTitle) {
                LineformAppNotification.showFindReplace.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut(
                KeyEquivalent(Character(AppMenuConfiguration.findReplaceCommandKeyEquivalent)),
                modifiers: [.command, .option]
            )

            Divider()

            // SwiftUI does NOT build a Spelling and Grammar submenu, and this app replaces the
            // Edit menu, so nothing provides one for free — verified by dumping the live menu
            // via Accessibility on 2026-07-26. Without this, live spell checking has no off
            // switch and `toggleContinuousSpellChecking` is unreachable.
            //
            // Every item routes to the first responder (the text view), exactly as AppKit's own
            // spelling menu does. `LineformTextView.toggleContinuousSpellChecking` then persists
            // the result, so the checkmark below and the stored preference cannot drift apart.
            Menu(AppMenuConfiguration.spellingMenuTitle) {
                Toggle(AppMenuConfiguration.checkSpellingWhileTypingTitle, isOn: Binding(
                    get: { settingsStore.checksSpellingWhileTyping },
                    set: { _ in
                        NSApp.sendAction(
                            #selector(NSTextView.toggleContinuousSpellChecking(_:)),
                            to: nil,
                            from: nil
                        )
                    }
                ))

                Divider()

                Button(AppMenuConfiguration.showSpellingPanelTitle) {
                    NSApp.sendAction(#selector(NSText.showGuessPanel(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(":", modifiers: .command)

                Button(AppMenuConfiguration.checkDocumentNowTitle) {
                    NSApp.sendAction(#selector(NSText.checkSpelling(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(";", modifiers: .command)
            }

            Divider()

            // No default keyboard shortcuts (macOS ships none for read-aloud transport; avoid
            // collisions). Always enabled like Print — a post with no key window is a safe no-op.
            Menu(String(localized: "Speech")) {
                Button(String(localized: "Start Speaking")) {
                    LineformAppNotification.startSpeaking.post(object: LineformAppNotification.activeWindowPayload())
                }

                Button(speechMenuState.state == .paused ? String(localized: "Resume") : String(localized: "Pause")) {
                    LineformAppNotification.pauseResumeSpeech.post(object: LineformAppNotification.activeWindowPayload())
                }
                .disabled(speechMenuState.state == .idle)

                Button(String(localized: "Stop")) {
                    LineformAppNotification.stopSpeech.post(object: LineformAppNotification.activeWindowPayload())
                }
                .disabled(speechMenuState.state == .idle)
            }
        }

        // Tab commands live in the File menu, alongside the standard document commands.
        // Replacing `.saveItem` above also removes SwiftUI's implicit Close command, so this
        // command must own the standard ⌘W shortcut. The existing close-tab path closes the
        // selected tab when siblings remain and closes the window when it was the last tab.
        CommandGroup(after: .newItem) {
            Button(String(localized: "New Tab")) {
                LineformAppNotification.newTab.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("t", modifiers: .command)

            // Jump to File lives beside New Tab: both are "get to a document" actions,
            // unlike the Save As/Rename/Delete group that acts on the current file.
            Button(AppMenuConfiguration.jumpToFileCommandTitle) {
                LineformAppNotification.showQuickOpen.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut(
                KeyEquivalent(Character(AppMenuConfiguration.jumpToFileCommandKeyEquivalent)),
                modifiers: .command
            )
        }

        CommandGroup(after: .saveItem) {
            Button(String(localized: "Close Tab")) {
                LineformAppNotification.closeTab.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut(
                KeyEquivalent(Character(AppMenuConfiguration.closeTabCommandKeyEquivalent)),
                modifiers: AppMenuConfiguration.closeTabCommandModifiers
            )

            Divider()

            Button(String(localized: "Select Next Tab")) {
                LineformAppNotification.selectNextTab.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("]", modifiers: .command)

            Button(String(localized: "Select Previous Tab")) {
                LineformAppNotification.selectPreviousTab.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("[", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button(AppMenuConfiguration.guideCommandTitle) {
                if let url = URL(string: AppMenuConfiguration.guideURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        // Put New Window in AppKit's existing Window menu. Declaring a second CommandMenu named
        // "Window" produces two top-level Window menus while a document is open. Anchoring the
        // command before the system-maintained window list keeps the route available after the
        // last document closes without duplicating the menu bar entry.
        CommandGroup(before: .windowList) {
            Button(String(localized: "New Window")) {
                NSDocumentController.shared.newDocument(nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    private var activeTextFormat: LineformTextFormat {
        textFormatMenuState.textFormat
    }

    private var displayModeSelection: Binding<EditorDisplayMode> {
        Binding(
            get: { displayModeMenuState.displayMode },
            set: { mode in
                displayModeMenuState.setDisplayMode(mode)
                LineformAppNotification.setDisplayMode.post(
                    object: LineformAppNotification.activeWindowPayload(value: mode.rawValue)
                )
            }
        )
    }

    private var hiddenFoldersSelection: Binding<Bool> {
        Binding(
            get: { hiddenFoldersMenuState.isOn },
            set: { hiddenFoldersMenuState.setShowsHiddenFolders($0) }
        )
    }
}

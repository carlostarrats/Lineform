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
    static let aboutCommandTitle = "About Lineform"
    static let settingsCommandTitle = "Settings…"
    static let aboutVersionDisplay = "V1.2.0"
    static let aboutCopyright = "Copyright © 2026 Carlos Tarrats. All rights reserved."
    static let saveCommandTitle = "Save"
    static let saveAsCommandTitle = "Save As..."
    static let saveAsCommandKeyEquivalent = "S"
    static let saveAsCommandSelector = NSSelectorFromString("saveDocumentAs:")
    // Three-period ellipsis matches the surrounding File-menu titles ("Save As...").
    static let renameFileCommandTitle = "Rename..."
    static let deleteFileCommandTitle = "Delete..."
    static let jumpToFileCommandTitle = "Jump to File…"
    static let jumpToFileCommandKeyEquivalent = "k"
    /// Format > Link's shortcut letter. Was "k" until quick-open claimed Cmd+K
    /// (2026-07-17 spec); the text view's right-click menu hint must stay in sync.
    static let linkCommandKeyEquivalent = "l"
    static let printCommandTitle = "Print..."
    static let exportPDFCommandTitle = "Export as PDF..."
    static let exportAsMenuTitle = "Export As"
    static let exportPDFSubmenuTitle = "PDF…"
    static let exportRTFCommandTitle = "Rich Text (RTF)…"
    static let checkForUpdatesCommandTitle = "Check for Updates..."
    static let installCommandLineToolCommandTitle = "Install Command Line Tool..."
    static let privacyPolicyCommandTitle = "Privacy Policy"
    static let termsOfUseCommandTitle = "Terms of Use"
    static let privacyPolicyURL = "https://lineform-atv.pages.dev/privacy"
    static let termsOfUseURL = "https://lineform-atv.pages.dev/terms"
    static let suppressesDefaultHelpMenu = true
    static let readingCommandPlacement = AppMenuCommandPlacement.view
    static let showHiddenFoldersCommandTitle = "Show Hidden Folders"
    static let showHiddenFoldersCommandKeyEquivalent = "."
    static let findCommandTitle = "Find"
    static let findCommandKeyEquivalent = "f"
    // ⌥⌘F — the macOS-standard Find & Replace shortcut (TextEdit/Pages).
    static let findReplaceCommandTitle = "Find & Replace…"
    static let findReplaceCommandKeyEquivalent = "f"
    static let usesTopLevelReadingMenu = false
    static let addsWritingToolsToEditMenu = false
    static let exposesAppleWritingTools = false
    static let markdownFormattingCommandTitles = [
        "Title",
        "Section",
        "Bold",
        "Italic",
        "Code",
        "Bulleted List",
        "Link"
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
            return "Convert to Plain Text"
        case .plainText:
            return "Convert to Markdown"
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
    private let updaterController: LineformUpdaterController

    init(
        textFormatMenuState: LineformTextFormatMenuState = .shared,
        displayModeMenuState: LineformDisplayModeMenuState = .shared,
        hiddenFoldersMenuState: HiddenFoldersMenuState = .shared,
        currentFileMenuState: LineformCurrentFileMenuState = .shared,
        speechMenuState: LineformSpeechMenuState = .shared,
        updaterController: LineformUpdaterController = .shared
    ) {
        _textFormatMenuState = ObservedObject(wrappedValue: textFormatMenuState)
        _displayModeMenuState = ObservedObject(wrappedValue: displayModeMenuState)
        _hiddenFoldersMenuState = ObservedObject(wrappedValue: hiddenFoldersMenuState)
        _currentFileMenuState = ObservedObject(wrappedValue: currentFileMenuState)
        _speechMenuState = ObservedObject(wrappedValue: speechMenuState)
        self.updaterController = updaterController
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

            Button(AppMenuConfiguration.checkForUpdatesCommandTitle) {
                updaterController.checkForUpdates()
            }

            Button(AppMenuConfiguration.installCommandLineToolCommandTitle) {
                CommandLineToolInstaller.presentInstaller()
            }

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

        CommandGroup(after: .saveItem) {
            Button(AppMenuConfiguration.saveAsCommandTitle) {
                DocumentSaveStatus.shared.noteManualSaveIntent()
                NSApp.sendAction(AppMenuConfiguration.saveAsCommandSelector, to: nil, from: nil)
            }
            .keyboardShortcut(
                KeyEquivalent(Character(AppMenuConfiguration.saveAsCommandKeyEquivalent)),
                modifiers: [.command, .shift]
            )

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

            Menu(AppMenuConfiguration.exportAsMenuTitle) {
                Button(AppMenuConfiguration.exportPDFSubmenuTitle) {
                    LineformAppNotification.exportPDF.post(object: LineformAppNotification.activeWindowPayload())
                }
                Button(AppMenuConfiguration.exportRTFCommandTitle) {
                    LineformAppNotification.exportRTF.post(object: LineformAppNotification.activeWindowPayload())
                }
            }
        }

        CommandMenu("Format") {
            if activeTextFormat == .markdown {
                Button("Title") {
                    NSApp.sendAction(#selector(LineformTextView.toggleTitleMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Section") {
                    NSApp.sendAction(#selector(LineformTextView.toggleSectionMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()

                Button("Bold") {
                    NSApp.sendAction(#selector(LineformTextView.toggleBoldMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Italic") {
                    NSApp.sendAction(#selector(LineformTextView.toggleItalicMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Code") {
                    NSApp.sendAction(#selector(LineformTextView.toggleInlineCodeMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("`", modifiers: .command)

                Button("Strikethrough") {
                    NSApp.sendAction(#selector(LineformTextView.toggleStrikethroughMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])

                Divider()

                Button("Blockquote") {
                    NSApp.sendAction(#selector(LineformTextView.toggleBlockquoteMarkdown(_:)), to: nil, from: nil)
                }

                Button("Bulleted List") {
                    NSApp.sendAction(#selector(LineformTextView.toggleUnorderedListMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("8", modifiers: [.command, .shift])

                Button("Numbered List") {
                    NSApp.sendAction(#selector(LineformTextView.toggleOrderedListMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("7", modifiers: [.command, .shift])

                Button("Link") {
                    NSApp.sendAction(#selector(LineformTextView.toggleLinkMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(AppMenuConfiguration.linkCommandKeyEquivalent)),
                    modifiers: .command
                )

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
            Picker("Mode", selection: displayModeSelection) {
                ForEach(EditorDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Button("Toggle Write / Read") {
                let target = displayModeMenuState.displayMode.toggledWriteRead
                displayModeMenuState.setDisplayMode(target)
                LineformAppNotification.setDisplayMode.post(
                    object: LineformAppNotification.activeWindowPayload(value: target.rawValue)
                )
            }
            .keyboardShortcut("e", modifiers: .command)

            Button("Toggle Outline") {
                LineformAppNotification.toggleOutline.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("0", modifiers: [.command, .option])

            Toggle(AppMenuConfiguration.showHiddenFoldersCommandTitle, isOn: hiddenFoldersSelection)
                .keyboardShortcut(
                    KeyEquivalent(Character(AppMenuConfiguration.showHiddenFoldersCommandKeyEquivalent)),
                    modifiers: [.command, .shift]
                )

            Button("Reading Experience") {
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

            // No default keyboard shortcuts (macOS ships none for read-aloud transport; avoid
            // collisions). Always enabled like Print — a post with no key window is a safe no-op.
            Menu("Speech") {
                Button("Start Speaking") {
                    LineformAppNotification.startSpeaking.post(object: LineformAppNotification.activeWindowPayload())
                }

                Button(speechMenuState.state == .paused ? "Resume" : "Pause") {
                    LineformAppNotification.pauseResumeSpeech.post(object: LineformAppNotification.activeWindowPayload())
                }
                .disabled(speechMenuState.state == .idle)

                Button("Stop") {
                    LineformAppNotification.stopSpeech.post(object: LineformAppNotification.activeWindowPayload())
                }
                .disabled(speechMenuState.state == .idle)
            }
        }

        // Tab commands live in the File menu, alongside the standard document commands.
        // Close Tab uses ⌘⇧W so it does not collide with the system Close Window (⌘W).
        CommandGroup(after: .newItem) {
            Button("New Tab") {
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
            Button("Close Tab") {
                LineformAppNotification.closeTab.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])

            Divider()

            Button("Select Next Tab") {
                LineformAppNotification.selectNextTab.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("]", modifiers: .command)

            Button("Select Previous Tab") {
                LineformAppNotification.selectPreviousTab.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("[", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            EmptyView()
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

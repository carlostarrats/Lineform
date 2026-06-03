import AppKit
import SwiftUI

enum AppMenuCommandPlacement: Equatable {
    case view
}

enum AppMenuConfiguration {
    static let aboutCommandTitle = "About Lineform"
    static let aboutVersionDisplay = "V1.0.2"
    static let aboutCopyright = "Copyright © 2026 Carlos Tarrats. All rights reserved."
    static let saveCommandTitle = "Save"
    static let saveAsCommandTitle = "Save As..."
    static let saveAsCommandKeyEquivalent = "S"
    static let saveAsCommandSelector = NSSelectorFromString("saveDocumentAs:")
    static let checkForUpdatesCommandTitle = "Check for Updates..."
    static let suppressesDefaultHelpMenu = true
    static let readingCommandPlacement = AppMenuCommandPlacement.view
    static let findCommandTitle = "Find"
    static let findCommandKeyEquivalent = "f"
    static let keepsTopLevelIntelligenceMenu = false
    static let usesTopLevelReadingMenu = false
    static let intelligencePrimaryCommandTitle: String? = nil
    static let lineformIntelligenceCommandTitles = IntelligentEditingAction.menuBarActions.map(\.title)
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

struct AppCommands: Commands {
    @ObservedObject private var textFormatMenuState: LineformTextFormatMenuState
    @ObservedObject private var displayModeMenuState: LineformDisplayModeMenuState
    private let updaterController: LineformUpdaterController

    init(
        textFormatMenuState: LineformTextFormatMenuState = .shared,
        displayModeMenuState: LineformDisplayModeMenuState = .shared,
        updaterController: LineformUpdaterController = .shared
    ) {
        _textFormatMenuState = ObservedObject(wrappedValue: textFormatMenuState)
        _displayModeMenuState = ObservedObject(wrappedValue: displayModeMenuState)
        self.updaterController = updaterController
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(AppMenuConfiguration.aboutCommandTitle) {
                NSApp.orderFrontStandardAboutPanel(options: AppMenuConfiguration.aboutPanelOptions())
            }

            Divider()

            Button(AppMenuConfiguration.checkForUpdatesCommandTitle) {
                updaterController.checkForUpdates()
            }
        }

        CommandGroup(after: .saveItem) {
            Button(AppMenuConfiguration.saveAsCommandTitle) {
                NSApp.sendAction(AppMenuConfiguration.saveAsCommandSelector, to: nil, from: nil)
            }
            .keyboardShortcut(
                KeyEquivalent(Character(AppMenuConfiguration.saveAsCommandKeyEquivalent)),
                modifiers: [.command, .shift]
            )
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

                Divider()

                Button("Bulleted List") {
                    NSApp.sendAction(#selector(LineformTextView.toggleUnorderedListMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("8", modifiers: [.command, .shift])

                Button("Link") {
                    NSApp.sendAction(#selector(LineformTextView.toggleLinkMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

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

            Button("Toggle Outline") {
                LineformAppNotification.toggleOutline.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("0", modifiers: [.command, .option])

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
        }

        CommandGroup(replacing: .help) {
            EmptyView()
        }

        if AppMenuConfiguration.keepsTopLevelIntelligenceMenu {
            CommandMenu("Intelligence") {
                ForEach(IntelligentEditingAction.menuBarActions) { action in
                    Button(action.title) {
                        LineformAppNotification.runIntelligentEditingAction.post(
                            object: LineformAppNotification.activeWindowPayload(value: action.rawValue)
                        )
                    }
                    .keyboardShortcut(KeyEquivalent(Character(action.keyEquivalent)), modifiers: [.command, .option])
                    .disabled(!intelligenceAvailable)
                }
            }
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

    private var intelligenceAvailable: Bool {
        IntelligenceAvailabilityService().currentStatus().isAvailable
    }
}

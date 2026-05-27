import AppKit
import SwiftUI

enum AppMenuCommandPlacement: Equatable {
    case view
}

enum AppMenuConfiguration {
    static let readingCommandPlacement = AppMenuCommandPlacement.view
    static let keepsTopLevelIntelligenceMenu = true
    static let usesTopLevelReadingMenu = false
    static let intelligencePrimaryCommandTitle: String? = nil
    static let lineformIntelligenceCommandTitles = IntelligentEditingAction.menuBarActions.map(\.title)
    static let addsWritingToolsToEditMenu = false
    static let exposesAppleWritingTools = false
    static let formatCommandTitles = [
        "Title",
        "Section",
        "Bold",
        "Italic",
        "Code",
        "Bulleted List",
        "Link"
    ]
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandMenu("Format") {
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

        CommandGroup(replacing: .help) {
            Button("Lineform Markdown Guide") {
                LineformHelp.openMarkdownGuide()
            }
        }
    }

    private var displayModeSelection: Binding<EditorDisplayMode> {
        Binding(
            get: { .write },
            set: { mode in
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

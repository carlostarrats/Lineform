import AppKit
import SwiftUI

struct AppCommands: Commands {
    var body: some Commands {
        CommandMenu("Format") {
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
        }

        CommandMenu("Reading") {
            Picker("Mode", selection: displayModeSelection) {
                ForEach(EditorDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Button("Toggle Outline") {
                LineformAppNotification.toggleOutline.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("0", modifiers: [.command, .option])

            Divider()

            Button("Reading Experience") {
                LineformAppNotification.showReadingExperience.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }

        CommandMenu("Intelligence") {
            ForEach(IntelligentEditingAction.allCases) { action in
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

        CommandGroup(after: .textEditing) {
            if #available(macOS 15.2, *) {
                Divider()

                Button("Show Writing Tools") {
                    NSApp.sendAction(#selector(NSResponder.showWritingTools(_:)), to: nil, from: nil)
                }
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

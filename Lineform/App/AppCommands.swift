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
            Button("Reading Experience") {
                LineformAppNotification.showReadingExperience.post()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }
}

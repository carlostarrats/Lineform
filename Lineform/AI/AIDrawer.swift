import AppKit
import LineformCore
import SwiftUI

/// What the window's right-side inspector shows (2026-11-24): the Reading Experience panel or the
/// AI drawer. They share ONE `.inspector` slot, one at a time, so the inspector rules hold as they
/// are (the tab bar stays inside `editorShell`, the toolbar band and its Sonoma workaround follow
/// `isShowingReadingInspector`, which now means "the inspector is open").
enum EditorInspectorContent: Equatable {
    case readingExperience
    case ai

    /// The inspector after the writer presses this content's toolbar button: it opens on it,
    /// switches to it, or — when it is already showing — closes.
    static func toggled(_ requested: EditorInspectorContent, isOpen: Bool,
                        showing: EditorInspectorContent) -> (isOpen: Bool, content: EditorInspectorContent) {
        if isOpen, showing == requested { return (false, showing) }
        return (true, requested)
    }
}

/// The window's AI conversations, one per open document (tab ID + document ID): a tab switch
/// keeps each document's conversation, and closing a tab — or replacing its document — drops
/// it. Memory only; nothing is ever written.
@MainActor
final class AIConversationStore: ObservableObject {
    struct Key: Hashable {
        let tab: UUID
        let document: UUID
    }

    private var conversations: [Key: AIConversation] = [:]

    func conversation(for key: Key) -> AIConversation {
        if let existing = conversations[key] { return existing }
        let made = AIConversation()
        conversations[key] = made
        return made
    }

    /// Drops every conversation whose document is no longer open in this window.
    func keepOnly(_ live: Set<Key>) {
        for key in conversations.keys where !live.contains(key) {
            conversations[key]?.detach()
            conversations[key]?.reset()
            conversations[key] = nil
        }
    }

    var count: Int { conversations.count }
}

/// The AI drawer: the conversation, in the Reading Experience inspector's column (ideal 320 pt).
struct AIDrawerView: View {
    @ObservedObject var conversation: AIConversation
    let theme: Theme
    let pageBackground: Color
    let onClose: () -> Void

    var body: some View {
        AIConversationView(conversation: conversation, style: Self.style(theme: theme, surface: pageBackground),
                           onClose: onClose)
            .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
    }

    static func style(theme: Theme, surface: Color) -> AIConversationStyle {
        AIConversationStyle(
            surface: surface,
            page: Color(nsColor: theme.backgroundColor),
            ink: Color(nsColor: theme.textColor),
            secondaryInk: MuseModalChrome.secondaryTextColor(usesDarkChrome: theme.usesDarkChrome),
            isDark: theme.usesDarkChrome
        )
    }
}

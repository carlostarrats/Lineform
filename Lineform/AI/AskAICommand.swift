import AppKit
import LineformCore

/// Edit ▸ Ask AI… (2026-11-22; the drawer 2026-11-24). It opens the AI drawer — the right-side
/// conversation (`AIDrawerView`), in the Reading Experience inspector's slot — as the toolbar's
/// AI button and the selection toolbar's Ask do. What a request goes to is decided when the
/// writer sends (`AIConversation`): the selection, or with nothing selected the whole document,
/// through `WholeDocumentAIPolicy` (`plan`): up to 1,500 words directly, above that after this
/// confirmation (Send / Cancel, Cancel the default), and past `AILimits` refused on a notice.
///
/// No keyboard shortcut (2026-11-22): `AppCommands` binds no ⌘J, ⇧⌘A or ⌃⌘A, but none of them is
/// a macOS convention for "ask the AI" (⌘J is AppKit's Jump to Selection), so it stays menu-only
/// like Speech.
@MainActor
enum AskAICommand {
    enum Plan: Equatable {
        /// The selection's comment card.
        case selection(NSRange)
        /// The whole-document comment card.
        case wholeDocument
        /// Confirm, then the whole-document comment card.
        case confirmWholeDocument(words: Int)
        /// The refusal, on the AI's message card.
        case refuseWholeDocument
    }

    static func plan(selection: NSRange, text: String) -> Plan {
        if selection.length > 0 { return .selection(selection) }
        switch WholeDocumentAIPolicy.decision(for: text) {
        case .run: return .wholeDocument
        case .confirm(let words): return .confirmWholeDocument(words: words)
        case .refuse: return .refuseWholeDocument
        }
    }

    /// Connected, not in History mode, an editor on screen (Write or Split: Read has no editor to
    /// take a suggestion), and an editable document with text in it: with nothing to send, or
    /// nowhere to accept a suggestion, it is not offered. A request or review in progress does
    /// not disable it: it only opens the drawer, where that request is.
    static func isEnabled(isConnected: Bool, isHistoryModeActive: Bool, state: AIActionController.State,
                          displayMode: EditorDisplayMode, isEditable: Bool, hasText: Bool) -> Bool {
        isConnected && !isHistoryModeActive && displayMode != .read && isEditable && hasText
    }

    /// The document has something to send: not empty, and not only white space.
    static func hasText(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    static func confirmationAlert(words: Int, recipient: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = WholeDocumentAIPolicy.confirmationTitle(words: words, recipient: recipient)
        let send = alert.addButton(withTitle: WholeDocumentAIPolicy.sendTitle)
        let cancel = alert.addButton(withTitle: WholeDocumentAIPolicy.cancelTitle)
        // Cancel is the default: Return never sends a whole document by accident.
        send.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert
    }
}

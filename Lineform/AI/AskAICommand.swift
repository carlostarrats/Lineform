import AppKit
import LineformCore

/// Edit ▸ Ask AI… (2026-11-22). With a selection it opens the selection toolbar's comment card for
/// that selection, exactly as the toolbar's Ask button does — no length policy, as before. With
/// nothing selected it opens the same card for the whole document, at the top centre of the
/// editor, after `WholeDocumentAIPolicy`: up to 1,500 words directly, above that after a
/// confirmation (Send / Cancel, Cancel the default), and past `AILimits` it is refused through
/// the AI's message card.
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

    /// Connected, not in History mode, no request or review in progress, and an editor on screen
    /// (Write or Split: Read has no editor to hold the card).
    static func isEnabled(isConnected: Bool, isHistoryModeActive: Bool, state: AIActionController.State,
                          displayMode: EditorDisplayMode) -> Bool {
        guard isConnected, !isHistoryModeActive, displayMode != .read else { return false }
        switch state {
        case .running, .reviewing: return false
        case .idle, .marking, .message: return true
        }
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

    /// Runs the command in `textView`'s editor. The comment card's Send then runs the action
    /// (`AITextCommand.run` for a selection, `.runWholeDocument` for the whole document).
    static func perform(in textView: LineformTextView, controller: AIActionController,
                        connectionStore: AIConnectionStore = .shared) {
        guard let provider = connectionStore.connectedProvider else { return }
        let text = textView.string
        switch plan(selection: textView.selectedRange(), text: text) {
        case .selection:
            textView.openSelectionToolbarCommentFromMenu()
        case .wholeDocument:
            textView.openWholeDocumentAIComment()
        case .refuseWholeDocument:
            controller.refuseWholeDocument()
        case .confirmWholeDocument(let words):
            let alert = confirmationAlert(
                words: words,
                recipient: WholeDocumentAIPolicy.recipient(for: provider, otherEndpoint: connectionStore.otherEndpoint)
            )
            let proceed: (NSApplication.ModalResponse) -> Void = { [weak textView] response in
                guard response == .alertFirstButtonReturn, let textView else { return }
                textView.openWholeDocumentAIComment()
            }
            if let window = textView.window {
                alert.beginSheetModal(for: window) { response in proceed(response) }
            } else {
                proceed(alert.runModal())
            }
        }
    }
}

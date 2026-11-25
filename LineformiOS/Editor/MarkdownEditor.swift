import LineformCore
import SwiftUI
import UIKit

/// The Markdown editor for SwiftUI: wraps `LineformTextView` and binds its text. It replaces the
/// step-3 `PlainTextEditor`.
///
/// The coordinator is the text view's delegate. It writes each change back to the binding (so
/// `OpenDocument` autosaves) and schedules the debounced highlight pass; `scrollViewDidScroll`
/// schedules the visible-window coverage check; `shouldChangeTextIn` routes Return through the
/// editing rules; a selection change or an edit refreshes the reading assists (ruler, typewriter);
/// the edit menu leads with spelling guesses on a misspelling; Writing Tools is told which
/// Markdown regions to leave alone. A settled selection raises the selection row
/// (`SelectionController`). A pasted or dropped image is saved beside `imageHost`'s
/// document (`LineformiOSTextView+ImagePaste.swift`).
///
/// A text that changes from outside (a live reload, another file) replaces the editor's text and
/// clears its undo history, so undo never puts older text over the new. A checkbox or Reconnect
/// made in Read is not from outside: the document hands it to this editor (`readEditDocument`),
/// which applies it as a ranged edit with its own undo, so the document has ONE undo history in
/// Write, Read and Preview.
struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    var profile: ReadingProfile
    /// The document a pasted or dropped image is saved beside (`OpenDocument`).
    var imageHost: (any ImageInsertionHost)?
    /// Told which text view is the editor, for the mode switch's position restore.
    var positionKeeper: ModePositionKeeper?
    /// Preview's linked scrolling; nil in Write and Read.
    var linkedScroll: LinkedScroll?
    /// Preview's editor pane keeps the caret in view when the keyboard resizes it.
    var keepsCaretVisibleOnResize = false
    /// Extra room above the first line for the floating mode control.
    var topChromeInset: CGFloat = 0
    /// The document whose Read edits this editor applies (`OpenDocument.readEditor`).
    var readEditDocument: OpenDocument?
    /// Settings › Check spelling while typing.
    var checksSpelling = true
    /// The open document's History: told about every edit, and the only thing that applies
    /// History's own edits (`PhoneHistoryController.attach`).
    var history: PhoneHistoryController?
    /// The selection row and comment field (`SelectionController`), told of every selection change.
    var selectionController: SelectionController?
    /// The document's name at the top of the page (`DocumentNameTag`); nil hides it.
    var documentName: String?
    /// Whether the name offers Rename… (the document has a file).
    var canRename = false
    var onRename: () -> Void = {}

    /// Padding for the chrome that floats over the page (the menu button, the save notice).
    static let chromeMargin: CGFloat = 20

    func makeUIView(context: Context) -> LineformTextView {
        let textView = LineformTextView.make(profile: profile)
        textView.checksSpellingWhileTyping = checksSpelling
        textView.setDocumentText(text)
        context.coordinator.documentIdentity = readEditDocument?.imageInsertionDocumentIdentity
        textView.delegate = context.coordinator
        textView.imageInsertionHost = imageHost
        textView.keepsCaretVisibleOnResize = keepsCaretVisibleOnResize
        textView.setTopChromeInset(topChromeInset)
        positionKeeper?.editor = textView
        linkedScroll?.connect(editor: textView)
        readEditDocument?.readEditor = textView
        history?.attach(textView)
        selectionController?.attach(textView)
        return textView
    }

    func updateUIView(_ textView: LineformTextView, context: Context) {
        context.coordinator.parent = self
        configure(textView, coordinator: context.coordinator)
    }

    /// Hands `textView` this value's inputs. Internal so tests update an editor the same way.
    ///
    /// The text check runs on every screen update (opening the word menu is one), so it must not
    /// walk the text: `textView.text != text` bridges the storage and compares with Unicode
    /// normalisation, about 50 ms for 1 MB in the simulator and several times that on a phone. The
    /// coordinator keeps the text it last knew the editor to hold (`knownText`); when the binding
    /// still holds that same string (the same storage, which `==` answers at once) and the lengths
    /// agree, nothing is compared.
    func configure(_ textView: LineformTextView, coordinator: Coordinator? = nil) {
        textView.profile = profile
        let rename = onRename
        textView.setDocumentName(documentName, canRename: canRename, onRename: { rename() })
        selectionController?.editorProfileDidChange(profile)
        textView.checksSpellingWhileTyping = checksSpelling
        textView.imageInsertionHost = imageHost
        textView.keepsCaretVisibleOnResize = keepsCaretVisibleOnResize
        textView.setTopChromeInset(topChromeInset)
        positionKeeper?.editor = textView
        linkedScroll?.connect(editor: textView)
        readEditDocument?.readEditor = textView
        history?.attach(textView)
        selectionController?.attach(textView)
        // Another document (OpenDocument's identity moved on: an open, New Document) starts at its
        // top; a live reload of the same one keeps the caret where it was, clamped.
        let identity = readEditDocument?.imageInsertionDocumentIdentity
        let isNewDocument = coordinator.map { $0.documentIdentity != nil && $0.documentIdentity != identity } ?? false
        coordinator?.documentIdentity = identity
        if !isNewDocument, let known = coordinator?.knownText, known == text,
           textView.textStorage.length == text.utf16.count {
            return
        }
        if isNewDocument || textView.text != text {
            // An outside replacement (a live reload, another document): an AI request or review
            // for the old text is abandoned first, recording and applying nothing.
            selectionController?.editorTextWillBeReplaced()
            // An outside replacement: the editor's undo steps describe the old text.
            textView.setDocumentText(text, isNewDocument: isNewDocument)
            textView.undoManager?.removeAllActions()
        }
        coordinator?.knownText = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        /// The text the editor was last known to hold (`configure`'s cheap check).
        var knownText: String?
        /// The open document's identity when the editor last took its text
        /// (`OpenDocument.imageInsertionDocumentIdentity`): a change means another document.
        var documentIdentity: Int?

        init(parent: MarkdownEditor) { self.parent = parent }

        /// Return's list continuation and CRLF rule (`LineformTextView.handlesChange`). Typing while
        /// History mode is up leaves it first, then the keystroke goes through.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard let textView = textView as? LineformTextView else { return true }
            // Typing, Delete, dictation and autocorrection are refused while an AI review is up.
            if textView.refusesEditForAI() { return false }
            textView.exitHistoryModeBeforeUserEdit()
            return !textView.handlesChange(in: range, replacementText: text)
        }

        func textViewDidChange(_ textView: UITextView) {
            let text: String = textView.text
            knownText = text
            parent.text = text
            // An open comment field closes: its range no longer names the same text.
            parent.selectionController?.editorTextDidChange()
            guard let textView = textView as? LineformTextView else { return }
            textView.textDidChangeForHighlighting()
            textView.refreshReadingAssists()
        }

        /// The Reading Ruler follows the caret, and Typewriter Mode re-centres it. The selection row
        /// rises once a non-empty selection settles; when it collapses the row becomes the caret's
        /// (software keyboard up) or goes.
        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? LineformTextView)?.refreshReadingAssists()
            (textView as? LineformTextView)?.highlighterSelectionDidChange()
            parent.selectionController?.editorSelectionDidChange()
        }

        /// The caret's row shows only while the editor has the software keyboard: it follows
        /// the focus (on the next turn).
        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.selectionController?.editorFocusDidChange()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.selectionController?.editorFocusDidChange()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? LineformTextView)?.visibleRangeDidChange()
            parent.linkedScroll?.editorDidScroll(scrollView)
        }

        /// On a misspelling, the spelling group (guesses, Learn, Ignore) leads the system's menu.
        /// Nothing else is added: Replace With… is on the selection row.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let textView = textView as? LineformTextView else { return nil }
            let leading = Self.leadingMenuElements(for: textView, range: range)
            guard !leading.isEmpty else { return nil }
            return UIMenu(children: leading + suggestedActions)
        }

        /// The app's own items ahead of the system's: the spelling group only. Internal so tests
        /// read the menu.
        static func leadingMenuElements(for textView: LineformTextView, range: NSRange) -> [UIMenuElement] {
            var elements: [UIMenuElement] = []
            if let spelling = textView.spellingMenu(for: range) { elements.append(spelling) }
            return elements
        }

        /// The Markdown regions Writing Tools must leave alone, should it ever be turned on.
        func textView(_ textView: UITextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
            (textView as? LineformTextView)?.writingToolsIgnoredRanges(in: enclosingRange) ?? []
        }
    }
}

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

    /// Padding for the chrome that floats over the page (the menu button, the save notice).
    static let chromeMargin: CGFloat = 20

    func makeUIView(context: Context) -> LineformTextView {
        let textView = LineformTextView.make(profile: profile)
        textView.checksSpellingWhileTyping = checksSpelling
        textView.setDocumentText(text)
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
        configure(textView)
    }

    /// Hands `textView` this value's inputs. Internal so tests update an editor the same way.
    func configure(_ textView: LineformTextView) {
        textView.profile = profile
        textView.checksSpellingWhileTyping = checksSpelling
        textView.imageInsertionHost = imageHost
        textView.keepsCaretVisibleOnResize = keepsCaretVisibleOnResize
        textView.setTopChromeInset(topChromeInset)
        positionKeeper?.editor = textView
        linkedScroll?.connect(editor: textView)
        readEditDocument?.readEditor = textView
        history?.attach(textView)
        selectionController?.attach(textView)
        if textView.text != text {
            // An outside replacement (a live reload, another document): an AI request or review
            // for the old text is abandoned first, recording and applying nothing.
            selectionController?.editorTextWillBeReplaced()
            // An outside replacement: the editor's undo steps describe the old text.
            textView.setDocumentText(text)
            textView.undoManager?.removeAllActions()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor

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
            parent.text = textView.text
            guard let textView = textView as? LineformTextView else { return }
            textView.textDidChangeForHighlighting()
            textView.refreshReadingAssists()
        }

        /// The Reading Ruler follows the caret, and Typewriter Mode re-centres it. The selection row
        /// rises once a non-empty selection settles, and goes when it collapses.
        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? LineformTextView)?.refreshReadingAssists()
            parent.selectionController?.editorSelectionDidChange()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? LineformTextView)?.visibleRangeDidChange()
            parent.linkedScroll?.editorDidScroll(scrollView)
        }

        /// On a misspelling, the spelling group (guesses, Learn, Ignore) leads the system's menu;
        /// on a selection History can keep, Replace With… comes next (outside History mode).
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let textView = textView as? LineformTextView else { return nil }
            let leading = Self.leadingMenuElements(for: textView, range: range)
            guard !leading.isEmpty else { return nil }
            return UIMenu(children: leading + suggestedActions)
        }

        /// The app's own items ahead of the system's: spelling, then Replace With…. Internal so
        /// tests read the menu.
        static func leadingMenuElements(for textView: LineformTextView, range: NSRange) -> [UIMenuElement] {
            var elements: [UIMenuElement] = []
            if let spelling = textView.spellingMenu(for: range) { elements.append(spelling) }
            if let replace = textView.replaceWithMenuAction(for: range) { elements.append(replace) }
            return elements
        }

        /// The Markdown regions Writing Tools must leave alone, should it ever be turned on.
        func textView(_ textView: UITextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
            (textView as? LineformTextView)?.writingToolsIgnoredRanges(in: enclosingRange) ?? []
        }
    }
}

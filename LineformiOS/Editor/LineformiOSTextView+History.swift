import LineformCore
import UIKit

/// History's side of the editor: edit reporting, typing that leaves History mode, and the two
/// ways History changes the text (`applyHistoryEdit`, `applyHistoryExit`).
///
/// - **One reporting hook.** Every character change reaches History from the text storage's
///   `didProcessEditing` (`.editedCharacters`): typing, dictation, paste, the editing rules,
///   undo and redo alike. The pre-change range is `(editedRange.location, editedRange.length -
///   changeInLength)`, the replacement the storage's text at `editedRange`. `setDocumentText`
///   and any edit spanning more than `historyWholeTextThreshold` UTF-16 units are reported as a
///   whole-text replacement instead (the next locate re-finds passages literally).
/// - **History's own edits are never reported**: they run inside `performHistoryEdit`, and the
///   engine already moved its live ranges for them.
/// - **Typing leaves History mode** first, with the session's collapse, then goes through (the
///   Mac's `.typedWhileInHistoryMode`): `exitHistoryModeBeforeUserEdit` runs from the delegate's
///   `shouldChangeTextIn` and from `applyRuleEdit`.
extension LineformTextView {
    /// Edits longer than this are reported as a whole-text replacement.
    static let historyWholeTextThreshold = 1000

    /// The open document's History, attached by `PhoneHistoryController.attach`.
    var historyController: PhoneHistoryController? {
        get { state.historyController }
        set { state.historyController = newValue }
    }

    /// True while History applies its own edit.
    var isApplyingHistoryEdit: Bool { state.isApplyingHistoryEdit }

    func observeTextStorageForHistory() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textStorageDidProcessEditingForHistory(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textStorage
        )
    }

    @objc private func textStorageDidProcessEditingForHistory(_ notification: Notification) {
        let storage = textStorage
        guard storage.editedMask.contains(.editedCharacters),
              !state.isApplyingHistoryEdit,
              let controller = state.historyController else { return }
        if state.isReplacingWholeText {
            controller.noteWholeTextReplacement()
            return
        }
        let edited = storage.editedRange
        let before = NSRange(location: edited.location, length: edited.length - storage.changeInLength)
        let length = (storage.string as NSString).length
        guard edited.location != NSNotFound, before.length >= 0, NSMaxRange(edited) <= length,
              before.length <= Self.historyWholeTextThreshold,
              edited.length <= Self.historyWholeTextThreshold
        else {
            controller.noteWholeTextReplacement()
            return
        }
        let replacement = edited.length == 0 ? "" : (storage.string as NSString).substring(with: edited)
        controller.noteUserEdit(before, replacement: replacement)
    }

    /// A user edit is about to land while History mode is up: leave it first, with the
    /// collapse, so the edit goes into the document text on the real undo stack. Never while
    /// undoing or redoing (History mode's stand-in manager holds nothing to undo).
    func exitHistoryModeBeforeUserEdit() {
        guard !state.isApplyingHistoryEdit,
              let controller = state.historyController, controller.isHistoryModeActive else { return }
        controller.exitHistoryMode(text: textStorage.string)
    }

    /// Runs an edit History applies without it being reported or mistaken for typing.
    func performHistoryEdit(_ body: () -> Void) {
        let wasApplying = state.isApplyingHistoryEdit
        state.isApplyingHistoryEdit = true
        defer { state.isApplyingHistoryEdit = wasApplying }
        body()
    }

    /// Shows another version: one localized replace that registers NO undo — the whole
    /// History-mode session becomes one undo step on exit (`applyHistoryExit`) — and not reported.
    func applyHistoryEdit(_ edit: HistoryEdit) {
        performHistoryEdit {
            replaceForHistory(edit.range, with: edit.replacement)
        }
    }

    /// Leaves History mode. When the session changed the text, the entry text is put back with
    /// registration disabled, then `exit.collapse` (entry → exit) is applied as an undoable ranged
    /// edit, in ONE undo group with the controller's version undo around it: one undo after
    /// leaving restores the entry text AND the entry versions. Skipped when this view no longer
    /// shows the text History mode left (it then belongs to another document). Returns whether
    /// the collapse was applied.
    @discardableResult
    func applyHistoryExit(_ exit: HistoryExit, controller: PhoneHistoryController) -> Bool {
        guard let collapse = exit.collapse, textStorage.string == exit.exitText else { return false }
        performHistoryEdit {
            if let restore = HistoryUndoCollapse.minimalEdit(from: exit.exitText, to: exit.entryText) {
                replaceForHistory(restore.range, with: restore.replacement)
            }
            guard let manager = undoManager else {
                applyRuleEdit(replacing: collapse.range, with: collapse.replacement)
                return
            }
            manager.beginUndoGrouping()
            controller.registerUndoBeforeExitCollapse(exit, on: manager)
            applyRuleEdit(replacing: collapse.range, with: collapse.replacement)
            controller.registerUndoAfterExitCollapse(exit, on: manager)
            manager.endUndoGrouping()
        }
        return true
    }

    /// The localized replace History uses: base attributes, the input delegate told, the binding
    /// told (so autosave sees it), the debounced highlight scheduled. It registers NO undo: a
    /// text-storage edit is invisible to UITextView's undo manager (`applyRuleEdit` registers its
    /// own for that reason). Toggling `disableUndoRegistration` around it is not an option either:
    /// `_UITextUndoManager` resets its registration state on a storage edit and then raises on the
    /// matching `enableUndoRegistration`. The caret goes to the end of the replacement.
    private func replaceForHistory(_ range: NSRange, with replacement: String) {
        let storage = textStorage
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= storage.length else { return }
        inputDelegate?.textWillChange(self)
        storage.replaceCharacters(
            in: range,
            with: NSAttributedString(string: replacement, attributes: MarkdownTextStyle.baseAttributes(for: profile))
        )
        inputDelegate?.textDidChange(self)
        selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        delegate?.textViewDidChange?(self)
        textDidChangeForHighlighting()
    }
}

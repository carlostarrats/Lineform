import LineformCore
import UIKit

/// What the Menu sheet's sections may do to the open document's editor: move to a place, select,
/// insert or align a table, and replace text. Every edit goes through the editor's one rule-edit
/// path (`LineformTextView.applyRuleEdit`), so each command is ONE undo step in the document's
/// one undo history and reaches `OpenDocument` (and so autosave) like typing does.
@MainActor
protocol EditorCommands {
    /// The text as the editor holds it now (the document's text before the editor exists).
    var currentText: String { get }
    /// Scrolls the visible surface (Write, Read or both Preview panes) so `range` starts at the top.
    func scrollToCharacterRange(_ range: NSRange)
    /// Selects `range` in the editor (clamped to the text).
    func selectRange(_ range: NSRange)
    /// Inserts the 3×2 starter table at the selection, as ⌃⌘T does.
    func insertTable()
    /// Aligns the table under the selection, as ⌃⌘R does; nothing outside a table.
    func reformatTable()
    /// Replaces `range` as one undo step. False when nothing changed or the edit was refused.
    @discardableResult func replace(range: NSRange, with replacement: String) -> Bool
    /// Replaces every one of `ranges` (non-overlapping) as ONE undo step. Text between the ranges,
    /// line endings included, is kept byte for byte. False when nothing changed or a range is
    /// invalid.
    @discardableResult func replaceAll(ranges: [NSRange], with replacement: String) -> Bool
    /// Check Document Now: one spelling pass over the whole document; the first misspelling after
    /// the selection is selected and brought into view. False when there is none.
    @discardableResult func checkDocumentNow() -> Bool
}

extension EditorCommands {
    @discardableResult func checkDocumentNow() -> Bool { false }
}

/// The screen's commands over the live editor, which stays mounted in every mode.
@MainActor
struct LiveEditorCommands: EditorCommands {
    var positionKeeper: ModePositionKeeper
    var document: OpenDocument
    /// The mode on screen while the sheet is up (it cannot change under the sheet).
    var mode: EditorDisplayMode

    private var editor: LineformTextView? { positionKeeper.editor }

    var currentText: String { editor?.textStorage.string ?? document.text }

    func scrollToCharacterRange(_ range: NSRange) {
        positionKeeper.restore(range.location, in: mode)
    }

    func selectRange(_ range: NSRange) {
        guard let editor else { return }
        let length = editor.textStorage.length
        let location = min(max(0, range.location), length)
        editor.selectedRange = NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    func insertTable() { editor?.insertTable() }

    func reformatTable() { editor?.reformatTable() }

    @discardableResult
    func checkDocumentNow() -> Bool {
        guard let editor, editor.checkDocumentNow() else { return false }
        // Into view on the surface on screen (Read and Preview too), as a search match is.
        positionKeeper.restore(editor.selectedRange.location, in: mode)
        return true
    }

    @discardableResult
    func replace(range: NSRange, with replacement: String) -> Bool {
        editor?.applyRuleEdit(replacing: range, with: replacement) ?? false
    }

    @discardableResult
    func replaceAll(ranges: [NSRange], with replacement: String) -> Bool {
        guard let editor,
              let edit = Self.combinedReplacement(in: editor.textStorage.string, ranges: ranges, with: replacement)
        else { return false }
        return editor.applyRuleEdit(replacing: edit.range, with: edit.replacement, selecting: edit.caret)
    }

    /// One span that replaces every range at once: from the first range's start to the last
    /// one's end, with the text between the ranges copied through unchanged. Nil for no ranges,
    /// an out-of-bounds range or overlapping ranges.
    static func combinedReplacement(
        in text: String, ranges: [NSRange], with replacement: String
    ) -> (range: NSRange, replacement: String, caret: NSRange)? {
        let source = text as NSString
        let sorted = ranges.sorted { $0.location < $1.location }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        var previousEnd = 0
        for range in sorted {
            guard range.location >= previousEnd, NSMaxRange(range) <= source.length else { return nil }
            previousEnd = NSMaxRange(range)
        }
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let built = NSMutableString()
        var cursor = first.location
        for range in sorted {
            built.append(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            built.append(replacement)
            cursor = NSMaxRange(range)
        }
        let caret = NSRange(location: span.location + built.length, length: 0)
        return (span, built as String, caret)
    }
}

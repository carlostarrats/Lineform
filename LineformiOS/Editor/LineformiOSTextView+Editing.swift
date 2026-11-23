import LineformCore
import UIKit

/// The editing rules: list continuation on Return, table Tab, headings, the formatting commands
/// and their hardware-keyboard shortcuts (the Mac's keys, from `AppCommands`).
///
/// - **IME-safe.** No rule runs while there is marked text. Return is decided in the delegate's
///   `textView(_:shouldChangeTextIn:replacementText:)` (reached only once the input method has
///   resolved the keypress), Tab and Shift-Tab are `UIKeyCommand`s; no raw key event is handled.
/// - **One undo step.** Every rule edit goes through `applyRuleEdit`, a localized
///   `replaceCharacters` that registers exactly one undo step and calls the delegate's
///   `textViewDidChange`, so `OpenDocument` autosaves. An edit that changes nothing registers no
///   undo step and posts nothing. No rule forces a synchronous re-highlight; the debounced
///   typing-delay pass picks the edit up.
/// - **History hears every rule edit** through the text storage hook
///   (`LineformiOSTextView+History.swift`); a rule edit while History mode is up leaves it first.
/// - **Read edits are rule edits.** A checkbox toggle or a Reconnect made in Read or Preview comes
///   here (`applyReadEdit`), so the document has one undo history in every mode.
/// - **AI review.** While a review is up every rule edit is refused (`refusesEditForAI`): Search's
///   Replace and Replace All, Read's checkbox and Reconnect, the formatting commands, image paste.
extension LineformTextView: ReadEditApplying {
    // MARK: - Return

    /// Decides a change the delegate was asked about. Returns `true` when a rule handled it (the
    /// delegate then answers `false`); `false` leaves it to the system.
    ///
    /// Only a bare Return with no marked text is ours. On a list, task or quote line it continues
    /// or ends the construct (`MarkdownListContinuation`); otherwise a CRLF document gets CRLF
    /// (`MarkdownLineEnding.inForce`) and an LF document gets the system's own newline.
    func handlesChange(in range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n", markedTextRange == nil else { return false }
        let string = textStorage.string
        if let outcome = MarkdownListContinuation.outcome(for: string, selectedRange: range) {
            switch outcome {
            case let .continue(insertion):
                applyRuleEdit(replacing: range, with: insertion)
            case let .terminate(clearing):
                applyRuleEdit(replacing: clearing, with: "")
            }
            return true
        }
        let ending = MarkdownLineEnding.inForce(at: range.location, in: string as NSString)
        guard ending == .crlf else { return false }
        applyRuleEdit(replacing: range, with: ending.text)
        return true
    }

    // MARK: - Tables

    /// The Tab outcome under the caret, or `nil` outside a table (or while composing), where the
    /// Tab key command declines and Tab does what it always does.
    func tableTabOutcome(forward: Bool) -> MarkdownTableEditing.TabOutcome? {
        guard markedTextRange == nil else { return nil }
        return MarkdownTableEditing.tabTarget(in: textStorage.string, selectedRange: selectedRange, forward: forward)
    }

    @objc func tableTabForward(_ sender: Any?) {
        applyTableTab(forward: true)
    }

    @objc func tableTabBackward(_ sender: Any?) {
        applyTableTab(forward: false)
    }

    /// `.select` edits nothing, so most Tabs inside a table cost no undo step and no write.
    /// `.appendRow` is the one Tab that writes: one localized insertion.
    private func applyTableTab(forward: Bool) {
        guard let outcome = tableTabOutcome(forward: forward) else { return }
        switch outcome {
        case .stay:
            return
        case let .select(range):
            selectedRange = range
            scrollRangeToVisible(range)
        case let .appendRow(insertion, at, selecting):
            applyRuleEdit(replacing: NSRange(location: at, length: 0), with: insertion, selecting: selecting)
        }
    }

    /// Inserts the 3×2 starter table (`MarkdownTableEditing.insertion`).
    func insertTable() {
        applyMarkdownEdit(MarkdownTableEditing.insertion(in: textStorage.string, selectedRange: selectedRange))
    }

    /// Aligns the table under the caret. Does nothing (and adds no undo step) outside a table or
    /// when it is already aligned.
    func reformatTable() {
        guard let edit = MarkdownTableEditing.reformat(in: textStorage.string, selectedRange: selectedRange) else { return }
        applyMarkdownEdit(edit)
    }

    // MARK: - Headings and formatting

    /// Sets the selected lines to heading `level` (1–6), or to body text for `nil`. A no-op adds
    /// no undo step.
    func setHeadingLevel(_ level: Int?) {
        guard let edit = MarkdownHeadingEditing.setLevel(level, in: textStorage.string, selectedRange: selectedRange) else {
            return
        }
        applyMarkdownEdit(edit)
    }

    /// Applies a formatting command to the selection.
    func apply(_ command: MarkdownFormattingCommand) {
        applyMarkdownEdit(command.apply(to: textStorage.string, selectedRange: selectedRange))
    }

    @objc func toggleBoldMarkdown(_ sender: Any?) { apply(.bold) }
    @objc func toggleItalicMarkdown(_ sender: Any?) { apply(.italic) }
    @objc func toggleInlineCodeMarkdown(_ sender: Any?) { apply(.inlineCode) }
    @objc func toggleStrikethroughMarkdown(_ sender: Any?) { apply(.strikethrough) }
    @objc func toggleUnorderedListMarkdown(_ sender: Any?) { apply(.unorderedList) }
    @objc func toggleOrderedListMarkdown(_ sender: Any?) { apply(.orderedList) }
    @objc func toggleLinkMarkdown(_ sender: Any?) { apply(.link) }
    @objc func toggleBlockquoteMarkdown(_ sender: Any?) { apply(.blockquote) }
    @objc func toggleTitleMarkdown(_ sender: Any?) { setHeadingLevel(1) }
    @objc func toggleSectionMarkdown(_ sender: Any?) { setHeadingLevel(2) }
    @objc func toggleHeading3Markdown(_ sender: Any?) { setHeadingLevel(3) }
    @objc func toggleHeading4Markdown(_ sender: Any?) { setHeadingLevel(4) }
    @objc func toggleHeading5Markdown(_ sender: Any?) { setHeadingLevel(5) }
    @objc func toggleHeading6Markdown(_ sender: Any?) { setHeadingLevel(6) }
    @objc func toggleBodyMarkdown(_ sender: Any?) { setHeadingLevel(nil) }
    @objc func insertMarkdownTable(_ sender: Any?) { insertTable() }
    @objc func reformatMarkdownTable(_ sender: Any?) { reformatTable() }

    // MARK: - Key commands

    /// The Mac's Format-menu shortcuts (`Lineform/App/AppCommands.swift`), plus Tab and Shift-Tab
    /// for tables. Each claims priority over UIKit's own handling (⌘B and ⌘I are the system's
    /// rich-text bold and italic otherwise); Tab declines through `canPerformAction` outside a
    /// table, so there it stays an ordinary Tab.
    static func makeMarkdownKeyCommands() -> [UIKeyCommand] {
        func command(_ title: String, _ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tableTabForward(_:)))
        tab.wantsPriorityOverSystemBehavior = true
        let backtab = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(tableTabBackward(_:)))
        backtab.wantsPriorityOverSystemBehavior = true
        return [
            tab,
            backtab,
            command(String(localized: "Title"), "1", .command, #selector(toggleTitleMarkdown(_:))),
            command(String(localized: "Section"), "2", .command, #selector(toggleSectionMarkdown(_:))),
            command(String(localized: "Heading 3"), "3", .command, #selector(toggleHeading3Markdown(_:))),
            command(String(localized: "Heading 4"), "4", .command, #selector(toggleHeading4Markdown(_:))),
            command(String(localized: "Heading 5"), "5", .command, #selector(toggleHeading5Markdown(_:))),
            command(String(localized: "Heading 6"), "6", .command, #selector(toggleHeading6Markdown(_:))),
            command(String(localized: "Body"), "0", .command, #selector(toggleBodyMarkdown(_:))),
            command(String(localized: "Bold"), "b", .command, #selector(toggleBoldMarkdown(_:))),
            command(String(localized: "Italic"), "i", .command, #selector(toggleItalicMarkdown(_:))),
            command(String(localized: "Code"), "`", .command, #selector(toggleInlineCodeMarkdown(_:))),
            command(String(localized: "Strikethrough"), "x", [.command, .shift], #selector(toggleStrikethroughMarkdown(_:))),
            command(String(localized: "Bulleted List"), "8", [.command, .shift], #selector(toggleUnorderedListMarkdown(_:))),
            command(String(localized: "Numbered List"), "7", [.command, .shift], #selector(toggleOrderedListMarkdown(_:))),
            command(String(localized: "Link"), "l", .command, #selector(toggleLinkMarkdown(_:))),
            command(String(localized: "Insert Table"), "t", [.command, .control], #selector(insertMarkdownTable(_:))),
            command(String(localized: "Reformat Table"), "r", [.command, .control], #selector(reformatMarkdownTable(_:))),
        ]
    }

    /// The selectors of the formatting commands, for `canPerformAction`.
    static let markdownCommandActions: Set<Selector> = [
        #selector(toggleBoldMarkdown(_:)), #selector(toggleItalicMarkdown(_:)),
        #selector(toggleInlineCodeMarkdown(_:)), #selector(toggleStrikethroughMarkdown(_:)),
        #selector(toggleUnorderedListMarkdown(_:)), #selector(toggleOrderedListMarkdown(_:)),
        #selector(toggleLinkMarkdown(_:)), #selector(toggleBlockquoteMarkdown(_:)), #selector(toggleTitleMarkdown(_:)),
        #selector(toggleSectionMarkdown(_:)), #selector(toggleHeading3Markdown(_:)),
        #selector(toggleHeading4Markdown(_:)), #selector(toggleHeading5Markdown(_:)),
        #selector(toggleHeading6Markdown(_:)), #selector(toggleBodyMarkdown(_:)),
        #selector(insertMarkdownTable(_:)), #selector(reformatMarkdownTable(_:)),
    ]

    /// `nil` when `action` is not one of ours; otherwise whether it can run now.
    func canPerformMarkdownAction(_ action: Selector) -> Bool? {
        if action == #selector(tableTabForward(_:)) {
            return isEditable && tableTabOutcome(forward: true) != nil
        }
        if action == #selector(tableTabBackward(_:)) {
            return isEditable && tableTabOutcome(forward: false) != nil
        }
        if Self.markdownCommandActions.contains(action) {
            return isEditable && markedTextRange == nil
        }
        return nil
    }

    // MARK: - The one edit path

    /// Applies a whole-text `MarkdownEdit` as ONE localized replacement: only the span between
    /// the common prefix and suffix is rewritten, never the whole document.
    func applyMarkdownEdit(_ edit: MarkdownEdit) {
        let (replaced, insertion) = Self.localizedReplacement(from: textStorage.string, to: edit.text)
        applyRuleEdit(replacing: replaced, with: insertion, selecting: edit.selectedRange)
    }

    /// The one span that turns `oldText` into `newText`: the range between their common prefix
    /// and suffix, and what replaces it. Never splits a surrogate pair.
    static func localizedReplacement(from oldText: String, to newText: String) -> (range: NSRange, replacement: String) {
        let old = oldText as NSString
        let new = newText as NSString
        let oldLength = old.length
        let newLength = new.length
        var prefix = 0
        let limit = min(oldLength, newLength)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix,
              old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) {
            suffix += 1
        }
        // Never split a surrogate pair: back the boundaries off to whole UTF-16 code points.
        while prefix > 0, prefix < oldLength, UTF16.isTrailSurrogate(old.character(at: prefix)) { prefix -= 1 }
        while suffix > 0, oldLength - suffix > prefix, UTF16.isTrailSurrogate(old.character(at: oldLength - suffix)) {
            suffix -= 1
        }
        let replaced = NSRange(location: prefix, length: oldLength - prefix - suffix)
        let insertion = new.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))
        return (replaced, insertion)
    }

    /// A Read edit (a checkbox toggle, a Reconnect; `ReadEditApplying`): `newText` as one ranged
    /// edit through `applyRuleEdit`, so it is one step in THIS editor's undo history, the one the
    /// document has in every mode. The selection stays on the text it was on, and nothing scrolls:
    /// the editor may be hidden under Read, or be Preview's other pane.
    func applyReadEdit(_ newText: String) -> Bool {
        let (range, replacement) = Self.localizedReplacement(from: textStorage.string, to: newText)
        let delta = (replacement as NSString).length - range.length
        let selection = selectedRange
        let kept: NSRange
        if NSMaxRange(selection) <= range.location {
            kept = selection
        } else if selection.location >= NSMaxRange(range) {
            kept = NSRange(location: selection.location + delta, length: selection.length)
        } else {
            kept = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        }
        return applyRuleEdit(replacing: range, with: replacement, selecting: kept, revealsSelection: false)
    }

    /// Replaces `range` with `replacement` as one undo step and tells the delegate, so autosave
    /// sees it. The caret goes to `selecting`, or just past the replacement, as on the Mac.
    /// A replacement equal to what is there writes nothing, registers nothing and posts nothing
    /// (it only moves the selection). Refused while there is marked text.
    /// `revealsSelection` false (a Read edit) leaves the scroll position alone, for the edit and
    /// for its undo and redo.
    @discardableResult
    func applyRuleEdit(
        replacing range: NSRange,
        with replacement: String,
        selecting: NSRange? = nil,
        revealsSelection: Bool = true
    ) -> Bool {
        // Read-only while an AI review is up (its own accept passes); real edits dismiss Mark.
        guard !refusesEditForAI() else { return false }
        guard markedTextRange == nil else { return false }
        let storage = textStorage
        guard range.location >= 0, NSMaxRange(range) <= storage.length else { return false }
        // A rule edit while History mode is up leaves it first (with the session's collapse; the
        // text, and so `range`, is the same afterwards). History's own collapse passes.
        if undoManager?.isUndoing != true, undoManager?.isRedoing != true {
            exitHistoryModeBeforeUserEdit()
        }
        let replacedText = (storage.string as NSString).substring(with: range)
        let replacementLength = (replacement as NSString).length
        let caret = selecting ?? NSRange(location: range.location + replacementLength, length: 0)
        guard replacedText != replacement else {
            if selectedRange != caret { selectedRange = caret }
            return false
        }

        let previousSelection = selectedRange
        let inserted = NSRange(location: range.location, length: replacementLength)
        if let undoManager {
            let groups = !undoManager.isUndoing && !undoManager.isRedoing
            if groups { undoManager.beginUndoGrouping() }
            undoManager.registerUndo(withTarget: self) { textView in
                MainActor.assumeIsolated {
                    _ = textView.applyRuleEdit(
                        replacing: inserted, with: replacedText, selecting: previousSelection,
                        revealsSelection: revealsSelection
                    )
                }
            }
            if groups { undoManager.endUndoGrouping() }
        }

        inputDelegate?.textWillChange(self)
        storage.replaceCharacters(
            in: range,
            with: NSAttributedString(string: replacement, attributes: MarkdownTextStyle.baseAttributes(for: profile))
        )
        inputDelegate?.textDidChange(self)
        selectedRange = caret
        if revealsSelection { scrollRangeToVisible(caret) }
        delegate?.textViewDidChange?(self)
        textDidChangeForHighlighting()
        return true
    }
}

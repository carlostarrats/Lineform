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
/// - **Trimmed to the minimal span** (the Mac invariant): an undo, redo or grouped edit reports
///   its whole range even where the text did not change, and the engine drops every passage an
///   edit straddles. The storage has already changed when it reports, so the hook keeps a copy of
///   the text (`State.historyShadowText`, made when History attaches, kept in step by every
///   report) and trims old against new with `HistoryUndoCollapse.unambiguousEdit`, the Mac's
///   per-edit trim: when a change in repeated text has several valid placements it reports their
///   union, so a passage there is DROPPED rather than left on an identical but different
///   occurrence. A copy out of step is remade and the edit reported as a whole-text replacement.
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
        set {
            state.historyController = newValue
            // The text before each edit, for trimming (nil while nothing listens).
            state.historyShadowText = newValue == nil ? nil : NSMutableString(string: textStorage.string)
        }
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
        guard storage.editedMask.contains(.editedCharacters) else { return }
        guard let controller = state.historyController else {
            state.historyShadowText = nil
            return
        }
        let edited = storage.editedRange
        let before = NSRange(location: edited.location, length: edited.length - storage.changeInLength)
        let current = storage.string as NSString
        let valid = edited.location != NSNotFound && before.length >= 0 && NSMaxRange(edited) <= current.length

        // Keep the copy in step: replace the old span with the new one. A copy out of step (or
        // none) is remade, and this edit cannot be trimmed.
        var old: String?
        if valid, let shadow = state.historyShadowText, NSMaxRange(before) <= shadow.length,
           shadow.length + storage.changeInLength == current.length {
            let small = before.length <= Self.historyWholeTextThreshold && edited.length <= Self.historyWholeTextThreshold
            if small { old = shadow.substring(with: before) }
            shadow.replaceCharacters(in: before, with: current.substring(with: edited))
        } else {
            state.historyShadowText = NSMutableString(string: current as String)
        }

        guard !state.isApplyingHistoryEdit else { return }
        if state.isReplacingWholeText {
            controller.noteWholeTextReplacement()
            return
        }
        guard valid, let old,
              before.length <= Self.historyWholeTextThreshold,
              edited.length <= Self.historyWholeTextThreshold
        else {
            controller.noteWholeTextReplacement()
            return
        }
        let replacement = edited.length == 0 ? "" : current.substring(with: edited)
        guard let trimmed = HistoryUndoCollapse.unambiguousEdit(from: old, to: replacement) else {
            controller.noteWholeTextReplacement()
            return
        }
        controller.noteUserEdit(
            NSRange(location: before.location + trimmed.range.location, length: trimmed.range.length),
            replacement: trimmed.replacement)
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

// MARK: - History mode on screen

/// What the editor does while History mode is up (D10): the text is READ-ONLY (`isEditable`
/// false, so the keyboard goes and a tap selects instead of placing a caret), every located
/// passage is drawn on a wash (`HistoryWashLayer.swift`), a tap selects the innermost passage
/// under it (ordinary text deselects), the page leaves room under the text for the History card,
/// and a hardware keyboard steps versions with ← / → and leaves with Esc (deselecting first).
/// A printable key on a hardware keyboard leaves History mode, with the collapse, and types —
/// the Mac's `.typedWhileInHistoryMode`.
extension LineformTextView {
    /// Room below the last line while History mode is up, so the card never hides the end of the
    /// document: about the card's height with a passage selected.
    static let historyCardClearance: CGFloat = 300

    /// The controller's display changed (any `revision` bump, and attach): follow the mode and
    /// redraw the washes on the next layout pass.
    func historyDisplayDidChange() {
        let active = historyController?.isHistoryModeActive == true
        if active != state.isShowingHistoryMode {
            state.isShowingHistoryMode = active
            let wasFirstResponder = isFirstResponder
            if active, selectedRange.length > 0 {
                // A selection left under the read-only text would be the next keystroke's target.
                selectedRange = NSRange(location: NSMaxRange(selectedRange), length: 0)
            }
            isEditable = !active
            // Hardware keys reach the view only while it is first responder; read-only keeps no
            // keyboard on screen.
            if wasFirstResponder, !isFirstResponder { becomeFirstResponder() }
            historyTapRecognizer().isEnabled = active
            contentInset.bottom = active ? Self.historyCardClearance : 0
            verticalScrollIndicatorInsets.bottom = contentInset.bottom
        }
        setNeedsHistoryWashRedraw()
    }

    /// True while the view shows History mode (read-only, washes, History keys).
    var isShowingHistoryMode: Bool { state.isShowingHistoryMode }

    // MARK: Taps

    /// The tap that selects a passage, made on first use and enabled only in History mode.
    func historyTapRecognizer() -> UITapGestureRecognizer {
        if let existing = state.historyTapRecognizer { return existing }
        let tap = UITapGestureRecognizer(target: self, action: #selector(historyTapped(_:)))
        tap.cancelsTouchesInView = false
        // Its delegate lets it recognise alongside the text view's own gestures.
        tap.delegate = historyWashView ?? {
            let view = HistoryWashView(frame: .zero)
            historyWashView = view
            return view
        }()
        tap.isEnabled = false
        addGestureRecognizer(tap)
        state.historyTapRecognizer = tap
        return tap
    }

    @objc private func historyTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        selectHistoryPassage(at: recognizer.location(in: self))
    }

    /// A tap at `point` (content coordinates): the innermost passage under it is selected; a tap
    /// on ordinary text goes back to the overview (History stays on).
    func selectHistoryPassage(at point: CGPoint) {
        guard let controller = historyController, controller.isHistoryModeActive else { return }
        controller.select(historyPassage(at: point)?.id)
    }

    /// The innermost located passage whose glyphs are under `point`, or nil.
    func historyPassage(at point: CGPoint) -> LocatedPassage? {
        guard let display = historyWashDisplay, textStorage.length > 0 else { return nil }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.insetBy(dx: -Self.historyWashOutset, dy: 0).contains(inContainer) else { return nil }
        return display.innermostPassage(containing: layoutManager.characterIndexForGlyph(at: glyph))
    }

    // MARK: Hardware keys

    /// ← / → step the selected passage, Esc deselects then leaves; only in History mode.
    static let historyKeyCommands: [UIKeyCommand] = {
        func command(_ input: String, _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return [
            command(UIKeyCommand.inputLeftArrow, #selector(historyPreviousVersion(_:))),
            command(UIKeyCommand.inputRightArrow, #selector(historyNextVersion(_:))),
            command(UIKeyCommand.inputEscape, #selector(historyEscape(_:))),
        ]
    }()

    @objc func historyPreviousVersion(_ sender: Any?) {
        guard let controller = historyController else { return }
        controller.step(by: -1, text: textStorage.string)
    }

    @objc func historyNextVersion(_ sender: Any?) {
        guard let controller = historyController else { return }
        controller.step(by: 1, text: textStorage.string)
    }

    /// Esc: back to the overview when a passage is selected, else out of History mode.
    @objc func historyEscape(_ sender: Any?) {
        guard let controller = historyController, controller.isHistoryModeActive else { return }
        if controller.selectedPassageID != nil {
            controller.select(nil)
        } else {
            controller.exitHistoryMode(text: textStorage.string)
        }
    }

    /// A printable key while History mode is up: leave it (with the collapse), make the text
    /// editable again, and type `characters` at the caret through the normal path. False outside
    /// History mode.
    @discardableResult
    func typeWhileInHistoryMode(_ characters: String) -> Bool {
        guard let controller = historyController, controller.isHistoryModeActive, !characters.isEmpty else { return false }
        controller.exitHistoryMode(text: textStorage.string)
        guard isEditable else { return false }
        if !isFirstResponder { becomeFirstResponder() }
        insertText(characters)
        return true
    }

    /// A printable key from a hardware keyboard while History mode is up types (leaving it);
    /// everything else — arrows, Esc, shortcuts — goes on as usual. Any key also makes an
    /// app-set selection the writer's (`writerPressedKey`, the selection row's rule).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        writerPressedKey()
        if isShowingHistoryMode, let key = presses.first?.key,
           key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty,
           let typed = Self.historyTypedCharacters(key.characters) {
            typeWhileInHistoryMode(typed)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    /// `characters` when they are text a key would type (no control characters, no function-key
    /// codes), else nil.
    static func historyTypedCharacters(_ characters: String) -> String? {
        guard !characters.isEmpty, !characters.hasPrefix("UIKeyInput"),
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0)
                  && !(0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        return characters
    }

    // MARK: Replace With…

    /// Whether the selection row offers Replace With… for `range`: outside History mode only, and
    /// only where the controller can add the passage (one line, no front matter, fenced code or
    /// math — `PhoneHistoryController.canAdd`, the Mac rule). The row is its one entry point.
    func offersReplaceWith(for range: NSRange) -> Bool {
        guard markedTextRange == nil, let controller = historyController, !controller.isHistoryModeActive,
              range.length > 0 else { return false }
        return controller.canAdd(range, text: textStorage.string)
    }

    /// Replace With…: the selection becomes a passage (its text the original), History mode opens
    /// on it and the card opens its "Type a replacement" field.
    @discardableResult
    func performReplaceWith(_ range: NSRange) -> Bool {
        guard let controller = historyController, !controller.isHistoryModeActive else { return false }
        return controller.add(range, text: textStorage.string) != nil
    }
}

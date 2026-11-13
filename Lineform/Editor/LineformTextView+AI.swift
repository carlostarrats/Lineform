import AppKit

/// What the text view asks the AI controller to do.
enum AITextCommand: Equatable {
    /// An action chosen from the context menu, for this selection.
    case run(AIAction, NSRange)
    /// Esc while a request runs.
    case cancel
    /// Esc, or a real edit, while Mark's sentences are shown.
    case dismissMarks
}

extension LineformTextView: AIEditorSurface {
    /// Applies an accepted decision (spec §4.1). `edits` arrive in the order to apply them, each in
    /// the coordinates the previous one left (the controller sends a batch descending, in pre-batch
    /// coordinates). All of them are ONE undo group named `actionName`, so one decision is one ⌘Z.
    ///
    /// Each edit goes through the localized `shouldChangeText → textStorage.replaceCharacters →
    /// didChangeText` path — never `applyWholeTextReplacement` — so History hears it from its one
    /// user-edit source in pre-change coordinates and its live ranges stay right. An edit that
    /// would split a composed character, or that touches a line ending or a BOM (structure: never
    /// in a replacement), is skipped rather than widened.
    func applyAIEdits(_ edits: [AIReviewEdit], actionName: String) {
        guard !edits.isEmpty else { return }
        performAIEdit {
            let manager = undoManager
            manager?.beginUndoGrouping()
            // Inside the group: breaking coalescing registers with the undo manager, and the
            // accept must never merge into the writer's preceding typing (or the next keystroke).
            breakUndoCoalescing()
            for edit in edits {
                replaceForAI(edit.range, with: edit.replacement)
            }
            breakUndoCoalescing()
            // Named while the group is open: naming a closed group registers outside any group.
            manager?.setActionName(actionName)
            manager?.endUndoGrouping()
        }
    }

    /// Typing during a review ends it (the controller) and then types here, at the selection.
    /// The controller calls this right after ending the review, before SwiftUI pushes its new
    /// state, so the review flag is cleared HERE — otherwise the read-only backstop in
    /// `shouldChangeText` would refuse, and drop, the very keystroke that ended the review.
    func insertTypedText(_ text: String) {
        isAIReviewActive = false
        isAIRequestRunning = false
        window?.makeFirstResponder(self)
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Spoken status, never written into the text view's AX value.
    func announceAI(_ message: String) {
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

extension LineformTextView {
    /// Runs the review's own edits, which the review backstop in `shouldChangeText` lets through.
    func performAIEdit(_ body: () -> Void) {
        let wasApplying = isApplyingAIEdit
        isApplyingAIEdit = true
        defer { isApplyingAIEdit = wasApplying }
        body()
    }

    private static let structureUnits: Set<unichar> = [0x0A, 0x0D, 0x2028, 0x2029, 0x0085, 0xFEFF]

    private static func containsStructureUnit(_ text: String) -> Bool {
        text.utf16.contains { structureUnits.contains($0) }
    }

    private func replaceForAI(_ range: NSRange, with replacement: String) {
        let ns = string as NSString
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= ns.length else { return }
        // The same alignment the formatting commands use: an edit it would move is refused here.
        guard MarkdownFormattingCommand.composedCharacterAligned(range, in: string) == range,
              !Self.containsStructureUnit(replacement),
              !Self.containsStructureUnit(ns.substring(with: range)),
              shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
    }

    // MARK: - Keys and edits

    /// Esc: cancels a running request, else dismisses Mark's sentences. Hooked through
    /// `doCommand(by:)`, never `keyDown`. False when there is nothing for Esc to do.
    func handleAICommand(_ selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if isAIRequestRunning {
            aiCommandHandler?(.cancel)
            return true
        }
        if !aiMarkRangesStorage.isEmpty {
            aiCommandHandler?(.dismissMarks)
            return true
        }
        return false
    }

    /// From `shouldChangeText`. True refuses the edit: the document is read-only during a review
    /// (a backstop — the review overlay holds focus). A real edit while marks are shown dismisses
    /// them and proceeds.
    func refusesEditForAI(replacement: String?) -> Bool {
        // History's own edits pass too: History mode and a review cannot overlap (AI is
        // unavailable in History mode), but the backstop must never block History's restore.
        guard !isApplyingAIEdit, !isApplyingHistoryEdit else { return false }
        if isAIReviewActive { return true }
        if replacement != nil, !aiMarkRangesStorage.isEmpty {
            aiCommandHandler?(.dismissMarks)
            aiMarkRanges = []
        }
        return false
    }

    // MARK: - Marks

    /// Mark's sentences, as layout-manager TEMPORARY `.backgroundColor` in History's tint — the
    /// text storage (the file, the undo stack, the highlighting) is never touched. Setting an
    /// equal value is a no-op.
    func applyAIMarkRanges(_ ranges: [NSRange]) {
        guard ranges != aiMarkRangesStorage else { return }
        aiMarkRangesStorage = ranges
        refreshAIMarks()
    }

    /// Re-derives the wash, e.g. after a theme change.
    func refreshAIMarks() {
        guard let layoutManager else { return }
        let length = (string as NSString).length
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        if !aiMarkRangesStorage.isEmpty {
            let wash = HistoryPalette.tint(for: Theme.theme(for: appliedReadingProfile))
            for range in aiMarkRangesStorage {
                let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
                guard clamped.length > 0 else { continue }
                layoutManager.addTemporaryAttribute(.backgroundColor, value: wash, forCharacterRange: clamped)
            }
        }
        needsDisplay = true
    }

    // MARK: - Context menu

    /// Rewrite ▸ Trim · Cut in half · Rewrite; Proofread; Mark ▸ Weakest · Long — for a
    /// non-empty selection the controller accepts. ABSENT, not disabled, otherwise. The handler
    /// does whole-document structure analysis, so it is asked HERE, when the menu is built.
    func addAIItemsIfAvailable(to menu: NSMenu) {
        let selection = selectedRange()
        guard selection.length > 0, aiAvailabilityHandler?(selection) == true else { return }
        menu.addItem(.separator())
        menu.addItem(aiSubmenuItem(LineformTextContextMenuPresentation.aiRewriteMenuTitle, [.trim, .cutInHalf, .rewrite]))
        menu.addItem(aiActionItem(.proofread))
        menu.addItem(aiSubmenuItem(LineformTextContextMenuPresentation.aiMarkMenuTitle, [.markWeakest, .markLong]))
    }

    private func aiActionItem(_ action: AIAction) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: #selector(runAIAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        return item
    }

    private func aiSubmenuItem(_ title: String, _ actions: [AIAction]) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        // Keeps `MainMenuIconDecorator` off it, like the context menu itself.
        submenu.identifier = MainMenuIconDecorator.excludedMenuIdentifier
        for action in actions { submenu.addItem(aiActionItem(action)) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc func runAIAction(_ sender: Any?) {
        guard let action = (sender as? NSMenuItem)?.representedObject as? AIAction else { return }
        let range = selectedRange()
        guard range.length > 0 else { return }
        aiCommandHandler?(.run(action, range))
    }
}

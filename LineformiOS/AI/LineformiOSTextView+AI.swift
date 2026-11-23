import LineformCore
import UIKit

/// The iPhone editor as an AI action sees it (`AIEditorSurface`), the Mac's
/// `LineformTextView+AI.swift` on UIKit.
///
/// - **One decision, one undo step.** `applyAIEdits` opens ONE undo group on the editor's own undo
///   manager and runs each edit through the editor's one edit path (`applyRuleEdit`: a localized
///   `textStorage.replaceCharacters` with its undo registration, then the delegate's
///   `textViewDidChange`, so the binding and `OpenDocument`'s autosave hear it). Never a whole-text
///   replacement. An edit that would split a composed character or touch a line ending or BOM is
///   skipped, never widened.
/// - **Read-only review.** While `isAIReviewActive`, `refusesEditForAI` refuses every edit except
///   the review's own (`performAIEdit`): typing, Delete, dictation, paste and image paste, the
///   formatting commands, Read's checkbox and Reconnect edits, and Search's Replace / Replace All.
///   A refusal tells the selection controller, which says the review's status again. The overlay
///   holds focus during a review; this is the backstop.
/// - **Mark's wash is drawn, never stored.** UIKit's TextKit 1 has no temporary attributes, so the
///   wash is a filled shape layer BEHIND the text, built from the layout manager's rects the way
///   the spelling underlines are stroked. The text storage, undo stack and file never see it. A
///   real edit dismisses the marks.
extension LineformTextView: AIEditorSurface {
    var string: String { textStorage.string }

    @discardableResult
    func applyAIEdits(_ edits: [AIReviewEdit], actionName: String) -> Bool {
        guard !edits.isEmpty else { return true }
        var appliedAll = true
        performAIEdit {
            let manager = undoManager
            manager?.beginUndoGrouping()
            for edit in edits where !replaceForAI(edit.range, with: edit.replacement) {
                appliedAll = false
            }
            // Named while the group is open: naming a closed group registers outside any group.
            manager?.setActionName(actionName)
            manager?.endUndoGrouping()
        }
        return appliedAll
    }

    /// The one place a review's end (or Mark's result) reaches the selection: clamped, on a
    /// composed-character boundary, and set as the APP's selection, so the selection row does not
    /// rise for it.
    func collapseSelectionForAI(at location: Int) {
        let ns = textStorage.string as NSString
        var caret = min(max(0, location), ns.length)
        if caret > 0, caret < ns.length {
            let character = ns.rangeOfComposedCharacterSequence(at: caret)
            if character.location != caret { caret = NSMaxRange(character) }
        }
        selectProgrammatically(NSRange(location: caret, length: 0))
    }

    /// The controller's `.typed` path. On iPhone the overlay never sends it (typing is refused
    /// during a review), but the surface honours it as the Mac does: the review has just ended,
    /// so the backstop is cleared here before the text goes in.
    func insertTypedText(_ text: String) {
        isAIReviewActive = false
        if !isFirstResponder { becomeFirstResponder() }
        insertText(text)
    }

    /// Spoken status, never written into the text view's accessibility value.
    func announceAI(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

extension LineformTextView {
    // MARK: - State

    /// A review is up: the document is read-only (the selection controller sets it).
    var isAIReviewActive: Bool {
        get { state.isAIReviewActive }
        set { state.isAIReviewActive = newValue }
    }

    var isApplyingAIEdit: Bool { state.isApplyingAIEdit }

    /// Told when an edit was refused during a review.
    var aiRefusalHandler: (() -> Void)? {
        get { state.aiRefusalHandler }
        set { state.aiRefusalHandler = newValue }
    }

    /// Told when a real edit dismisses Mark's sentences.
    var aiDismissMarksHandler: (() -> Void)? {
        get { state.aiDismissMarksHandler }
        set { state.aiDismissMarksHandler = newValue }
    }

    /// Runs the review's own edits, which the backstop lets through.
    func performAIEdit(_ body: () -> Void) {
        let was = state.isApplyingAIEdit
        state.isApplyingAIEdit = true
        defer { state.isApplyingAIEdit = was }
        body()
    }

    private static let structureUnits: Set<unichar> = [0x0A, 0x0D, 0x2028, 0x2029, 0x0085, 0xFEFF]

    private static func containsStructureUnit(_ text: String) -> Bool {
        text.utf16.contains { structureUnits.contains($0) }
    }

    /// One edit of a decision, through the editor's one edit path, leaving the scroll alone (the
    /// controller collapses the selection afterwards). False when skipped.
    private func replaceForAI(_ range: NSRange, with replacement: String) -> Bool {
        let text = textStorage.string
        let ns = text as NSString
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= ns.length,
              MarkdownFormattingCommand.composedCharacterAligned(range, in: text) == range,
              !Self.containsStructureUnit(replacement),
              !Self.containsStructureUnit(ns.substring(with: range)) else { return false }
        // Equal text is no edit, and nothing was skipped.
        if ns.substring(with: range) == replacement { return true }
        return applyRuleEdit(replacing: range, with: replacement, revealsSelection: false)
    }

    // MARK: - The backstop

    /// True refuses the edit: the document is read-only during a review, and the refusal is
    /// reported (`aiRefusalHandler`). A real edit while Mark's sentences are shown dismisses them
    /// and goes ahead. The review's own accept passes.
    func refusesEditForAI() -> Bool {
        guard !state.isApplyingAIEdit else { return false }
        if state.isAIReviewActive {
            aiRefusalHandler?()
            return true
        }
        if !state.aiMarkRanges.isEmpty {
            applyAIMarkRanges([])
            aiDismissMarksHandler?()
        }
        return false
    }

    /// Editing actions that change the text, refused (absent from the edit menu) during a review.
    static let aiRefusedActions: Set<Selector> = [
        #selector(UIResponderStandardEditActions.paste(_:)),
        #selector(UIResponderStandardEditActions.cut(_:)),
        #selector(UIResponderStandardEditActions.delete(_:)),
        #selector(UIResponderStandardEditActions.pasteAndMatchStyle(_:)),
        #selector(UIResponderStandardEditActions.toggleBoldface(_:)),
        #selector(UIResponderStandardEditActions.toggleItalics(_:)),
        #selector(UIResponderStandardEditActions.toggleUnderline(_:)),
        #selector(UIResponderStandardEditActions.makeTextWritingDirectionLeftToRight(_:)),
        #selector(UIResponderStandardEditActions.makeTextWritingDirectionRightToLeft(_:)),
    ]

    /// `false` for an editing action during a review (`nil` otherwise, deferring).
    func canPerformDuringAIReview(_ action: Selector) -> Bool? {
        guard state.isAIReviewActive else { return nil }
        if Self.aiRefusedActions.contains(action) || Self.markdownCommandActions.contains(action)
            || action == #selector(tableTabForward(_:)) || action == #selector(tableTabBackward(_:)) {
            return false
        }
        return nil
    }

    // Key input that can bypass the delegate's `shouldChangeTextIn` (no delegate, a hardware key).
    override func insertText(_ text: String) {
        guard !refusesEditForAI() else { return }
        super.insertText(text)
    }

    override func deleteBackward() {
        guard !refusesEditForAI() else { return }
        super.deleteBackward()
    }

    override func cut(_ sender: Any?) {
        guard !refusesEditForAI() else { return }
        super.cut(sender)
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard !refusesEditForAI() else { return }
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    override func replace(_ range: UITextRange, withText text: String) {
        guard !refusesEditForAI() else { return }
        super.replace(range, withText: text)
    }

    // MARK: - Mark's wash

    /// Mark's sentences (the selection controller sets them from the controller's state).
    var aiMarkRanges: [NSRange] { state.aiMarkRanges }

    /// An equal value is a no-op.
    func applyAIMarkRanges(_ ranges: [NSRange]) {
        guard ranges != state.aiMarkRanges else { return }
        state.aiMarkRanges = ranges
        setNeedsAIMarkWashRedraw()
    }

    /// The layer that fills the wash: the LOWEST sublayer, behind the text and the reading ruler,
    /// in content coordinates so it scrolls with the text. Made on first use.
    var aiMarkWashLayer: CAShapeLayer? { state.aiMarkWashLayer }

    func setNeedsAIMarkWashRedraw() {
        state.needsAIMarkWashRedraw = true
        setNeedsLayout()
    }

    /// Called from `layoutSubviews`, after the spelling underlines.
    func redrawAIMarkWashIfNeeded() {
        guard state.needsAIMarkWashRedraw else { return }
        redrawAIMarkWash()
    }

    /// Fills each marked range's enclosing rects, offset by the text container inset.
    func redrawAIMarkWash() {
        state.needsAIMarkWashRedraw = false
        guard !state.aiMarkRanges.isEmpty || state.aiMarkWashLayer != nil else { return }
        let layer = markWashLayer()
        let path = UIBezierPath()
        let length = textStorage.length
        let inset = textContainerInset
        for range in state.aiMarkRanges {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clamped.length > 0 else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                path.append(UIBezierPath(rect: rect.offsetBy(dx: inset.left, dy: inset.top)))
            }
        }
        layer.fillColor = Self.markWashColor(for: profile, traits: traitCollection).cgColor
        layer.path = path.isEmpty ? nil : path.cgPath
    }

    /// `HistoryPalette.markWash` (opaque: the theme's own ink over the page, text on it at AA),
    /// resolved for this view's traits, as the Original theme's page is dynamic.
    static func markWashColor(for profile: ReadingProfile, traits: UITraitCollection) -> UIColor {
        HistoryPalette.markWash(for: Theme.theme(for: profile)).resolvedColor(with: traits)
    }

    private func markWashLayer() -> CAShapeLayer {
        if let existing = state.aiMarkWashLayer { return existing }
        let layer = CAShapeLayer()
        layer.strokeColor = nil
        layer.contentsScale = traitCollection.displayScale
        self.layer.insertSublayer(layer, at: 0)
        state.aiMarkWashLayer = layer
        return layer
    }

    // MARK: - The app's own selections

    /// Sets the selection as the APP's, not the writer's: a Search jump, Check Document Now, a
    /// position restore, a review's end. The selection row never rises for it.
    func selectProgrammatically(_ range: NSRange) {
        state.programmaticSelection = range
        state.isSettingSelectionProgrammatically = true
        selectedRange = range
        state.isSettingSelectionProgrammatically = false
    }

    /// The selection is one the app set (being set now, or the last one it set, unchanged since).
    var isSelectionProgrammatic: Bool {
        state.isSettingSelectionProgrammatically || state.programmaticSelection == selectedRange
    }

    /// The writer moved the selection: the app's last one no longer stands.
    func forgetProgrammaticSelection() {
        state.programmaticSelection = nil
    }

    /// Told when the writer takes the app's selection as their own (`SelectionController`).
    var writerInteractionHandler: (() -> Void)? {
        get { state.writerInteractionHandler }
        set { state.writerInteractionHandler = newValue }
    }

    /// A touch that lands on the app's selection (a Search match, say) makes it the writer's: their
    /// gesture there may raise the row, which tapping inside a selection would otherwise never do
    /// (it moves no selection). A touch elsewhere moves the selection itself.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, event?.type == .touches { writerTouched(at: point) }
        return hit
    }

    /// A touch at `point` (this view's coordinates): on the app's selection, it is the writer's now.
    func writerTouched(at point: CGPoint) {
        guard state.programmaticSelection != nil, selectedRange.length > 0, touchesSelection(at: point) else { return }
        writerTookSelection()
    }

    /// A key in the editor (an arrow, a modifier, a shortcut) is the writer's too.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if state.programmaticSelection != nil { writerTookSelection() }
        super.pressesBegan(presses, with: event)
    }

    private func writerTookSelection() {
        forgetProgrammaticSelection()
        writerInteractionHandler?()
    }

    /// The point (in this view's coordinates) is on the selection, or on a handle beside it.
    private func touchesSelection(at point: CGPoint) -> Bool {
        guard let range = selectedTextRange else { return false }
        return selectionRects(for: range).contains { $0.rect.insetBy(dx: -22, dy: -22).contains(point) }
    }
}

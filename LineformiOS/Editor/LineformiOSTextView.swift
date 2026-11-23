import LineformCore
import UIKit

/// The iPhone Markdown editor: a TextKit 1 `UITextView` (`init(usingTextLayoutManager: false)`)
/// styled from the reading profile, with the Mac editor's highlighting rules.
///
/// - **Base attributes are whole-document.** Every full pass (load, text replacement, profile
///   change) writes `MarkdownTextStyle.baseAttributes(for:)` over the whole document, so layout is
///   uniform everywhere. Only token inks are scoped: to the visible character range plus
///   `highlightMargin`, snapped to line boundaries (`MarkdownTokenScope`).
/// - **Debounced.** After an edit the token pass runs `typingHighlightDelay` (0.25 s) after the
///   last keystroke, as on the Mac. A scroll re-tokenizes only once the visible window is no
///   longer covered by the last pass. No edit forces a synchronous re-highlight.
/// - **IME-safe.** Every pass, the typing-delay one included, is skipped while an input method is
///   composing (`markedTextRange != nil`), so the composing range is never restyled. A skipped
///   full pass is remembered and the first pass after composition ends catches up.
final class LineformTextView: UITextView {
    /// Characters tokenized on each side of the visible range (the Mac's `highlightMargin`).
    static let highlightMargin = 3000
    /// The pause after the last edit before the visible window is re-tokenized (the Mac's 0.25 s).
    static let typingHighlightDelay: TimeInterval = 0.25
    /// Coalesces scroll ticks before the coverage check (the Mac's `scrollHighlightDebounce`).
    static let scrollHighlightDebounce: TimeInterval = 0.05
    /// Top and bottom page inset, in points. The horizontal inset comes from `EditorReadingLayout`.
    static let verticalInset: CGFloat = 20

    /// The reading profile. Setting a different one re-applies the base attributes over the whole
    /// document, the typing attributes, the page, caret and selection colours, and the column
    /// insets from `EditorReadingLayout`.
    var profile: ReadingProfile {
        get { state.profile }
        set {
            let oldValue = state.profile
            state.profile = newValue
            if newValue != oldValue || !hasAppliedProfile {
                let restoredOffset = updateTypewriterScrollState(from: oldValue, to: newValue)
                applyProfile()
                if let restoredOffset { restoreOffsetBeforeTypewriterMode(restoredOffset) }
            }
        }
    }

    // MARK: - Stored state

    /// Every piece of editor state that has a starting value. It lives in one object made on first
    /// use, never in stored properties with default values: UIKit builds this class through the
    /// `textViewUsingTextLayoutManager:` factory, and on that path Swift's property initializers
    /// do not run. Memory is zeroed instead, so a `let` with a default read as nil and crashed, and
    /// an optional `CGPoint` read as `(0, 0)` rather than nil. The only stored property is this
    /// optional class reference, whose zeroed value is nil on every path (`init(usingTextLayoutManager:)`,
    /// `init(frame:textContainer:)`, `init?(coder:)`). `EditorConstructionTests` reads every value
    /// through each path.
    final class State {
        var profile: ReadingProfile = .original
        var readingRulerView: UIView?
        var scrollOffsetBeforeTypewriterMode: CGPoint?
        var isKeyboardAnimating = false
        var spellCheck: SpellCheckPass?
        /// Settings › Check spelling while typing. Off, no pass is scheduled or run.
        var checksSpellingWhileTyping = true
        var spellingUnderlines: CAShapeLayer?
        var needsSpellingUnderlineRedraw = false
        var lastHighlightedTokenRange: NSRange?
        var needsFullHighlight = false
        var hasAppliedProfile = false
        var lastLayoutSize: CGSize = .zero
        weak var imageInsertionHost: (any ImageInsertionHost)?
        var imagePasteTask: Task<Void, Never>?
        var imageDropInteraction: UIDropInteraction?
        /// A cross-mode position restore, re-asserted for a few ticks (`scrollCharacterRangeToTopPersistently`).
        var persistentScrollTarget: NSRange?
        var persistentScrollReassertsRemaining = 0
        /// Preview's editor pane: after a size change (the keyboard, the split) the caret is
        /// scrolled back into view.
        var keepsCaretVisibleOnResize = false
        /// The open document's History (`PhoneHistoryController.attach`). Weak: the document owns it.
        weak var historyController: PhoneHistoryController?
        /// True while History applies its own edit (`performHistoryEdit`): the storage hook does
        /// not report it, and it never counts as typing.
        var isApplyingHistoryEdit = false
        /// History mode is ending because the writer typed: the typed character's own echo says
        /// so, and "History closed" would talk over it.
        var isLeavingHistoryForTyping = false
        /// True while `setDocumentText` replaces the whole text: reported as one whole-text
        /// replacement, never as an edit.
        var isReplacingWholeText = false
        /// The text before the next edit, while History listens: each report trims its edit to
        /// the minimal span against it (`textStorageDidProcessEditingForHistory`).
        var historyShadowText: NSMutableString?
        /// History mode's empty undo manager: steps are not undoable one by one. Made on first use.
        var historyStandInUndoManager: UndoManager?
        /// History mode as the view last showed it (read-only, washes, History keys).
        var isShowingHistoryMode = false
        /// The washes History mode draws behind the text. Made on first use.
        var historyWashView: HistoryWashView?
        var needsHistoryWashRedraw = false
        /// The tap that selects a passage in History mode. Made on first use.
        var historyTapRecognizer: UITapGestureRecognizer?
        // AI (logic in LineformiOS/AI/LineformiOSTextView+AI.swift).
        var isAIReviewActive = false
        var isApplyingAIEdit = false
        var aiMarkRanges: [NSRange] = []
        var aiMarkWashLayer: CAShapeLayer?
        var needsAIMarkWashRedraw = false
        var aiRefusalHandler: (() -> Void)?
        var aiDismissMarksHandler: (() -> Void)?
        /// A selection the app set itself (`selectProgrammatically`), and whether it is being set now.
        var programmaticSelection: NSRange?
        var isSettingSelectionProgrammatically = false
        /// The writer touched the app's selection or pressed a key (`SelectionController`).
        var writerInteractionHandler: (() -> Void)?
        #if DEBUG
        var pasteboardForTesting: UIPasteboard?
        #endif
    }

    private var stateStorage: State?

    var state: State {
        if let stateStorage { return stateStorage }
        let state = State()
        stateStorage = state
        return state
    }

    // MARK: Reading assists state (logic in LineformiOSTextView+ReadingAssists.swift)

    /// The Reading Ruler band: the lowest subview, so it sits behind the text. Made on first use.
    var readingRulerView: UIView? {
        get { state.readingRulerView }
        set { state.readingRulerView = newValue }
    }
    /// Where the page was when Typewriter Mode came on; turning it off scrolls back here.
    var scrollOffsetBeforeTypewriterMode: CGPoint? {
        get { state.scrollOffsetBeforeTypewriterMode }
        set { state.scrollOffsetBeforeTypewriterMode = newValue }
    }
    /// The keyboard is animating its frame; Typewriter Mode waits so it does not fight keyboard
    /// avoidance.
    var isKeyboardAnimating: Bool {
        get { state.isKeyboardAnimating }
        set { state.isKeyboardAnimating = newValue }
    }

    // MARK: Spell-check state (logic in LineformiOSTextView+SpellCheck.swift)

    /// This document's spell-check pass and checker, made on first use.
    var spellCheck: SpellCheckPass {
        if let pass = state.spellCheck { return pass }
        let pass = SpellCheckPass()
        state.spellCheck = pass
        return pass
    }
    /// The shape layer that strokes the misspelling underlines. Made on first use.
    var spellingUnderlines: CAShapeLayer? {
        get { state.spellingUnderlines }
        set { state.spellingUnderlines = newValue }
    }
    /// An edit or a re-style moved the text; the next layout pass re-strokes the underlines.
    var needsSpellingUnderlineRedraw: Bool {
        get { state.needsSpellingUnderlineRedraw }
        set { state.needsSpellingUnderlineRedraw = newValue }
    }

    // MARK: Image paste state (logic in LineformiOSTextView+ImagePaste.swift)

    /// The document a pasted or dropped image is saved beside. `MarkdownEditor` sets it to the
    /// open `OpenDocument`; without one, an image paste does nothing.
    var imageInsertionHost: (any ImageInsertionHost)? {
        get { state.imageInsertionHost }
        set { state.imageInsertionHost = newValue }
    }
    /// The image paste or drop in flight, if any (reading the image, saving a new document,
    /// writing the file). Tests await it.
    var imagePasteTask: Task<Void, Never>? {
        get { state.imagePasteTask }
        set { state.imagePasteTask = newValue }
    }

    // MARK: Highlighting state

    /// The range the last token pass covered; a scroll inside it does no work.
    private(set) var lastHighlightedTokenRange: NSRange? {
        get { state.lastHighlightedTokenRange }
        set { state.lastHighlightedTokenRange = newValue }
    }
    #if DEBUG
    /// Lets a test make the next scroll pass find its window uncovered.
    var lastHighlightedTokenRangeForTesting: NSRange? {
        get { lastHighlightedTokenRange }
        set { lastHighlightedTokenRange = newValue }
    }
    #endif
    /// A full pass was skipped during composition; the next pass runs it instead.
    private(set) var needsFullHighlight: Bool {
        get { state.needsFullHighlight }
        set { state.needsFullHighlight = newValue }
    }
    private(set) var hasAppliedProfile: Bool {
        get { state.hasAppliedProfile }
        set { state.hasAppliedProfile = newValue }
    }
    private(set) var lastLayoutSize: CGSize {
        get { state.lastLayoutSize }
        set { state.lastLayoutSize = newValue }
    }

    /// A configured editor. Separate from `MarkdownEditor.makeUIView` so tests build one directly.
    static func make(profile: ReadingProfile = .original) -> LineformTextView {
        let textView = LineformTextView(usingTextLayoutManager: false)
        textView.configureForMarkdownEditing()
        textView.observeKeyboardForTypewriterMode()
        textView.observeTextStorageForSpellCheck()
        textView.observeTextStorageForHistory()
        textView.configureImagePasteAndDrop()
        textView.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (textView: LineformTextView, _) in
            textView.redrawSpellingUnderlines()
            textView.setNeedsHistoryWashRedraw()
        }
        textView.profile = profile
        if !textView.hasAppliedProfile { textView.applyProfile() }
        return textView
    }

    /// The Mac's `configureForMarkdownEditing`: no silent rewrites (autocorrection, smart quotes,
    /// dashes and inserts are off), the system spell checker off because it cannot skip Markdown
    /// (the app's `SpellCheckPass` replaces it), and Writing Tools off with `writingToolsBehavior
    /// = .none` (the Mac's `configureWritingTools`).
    private func configureForMarkdownEditing() {
        autocapitalizationType = .sentences
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        writingToolsBehavior = .none
        allowedWritingToolsResultOptions = [.plainText, .list]
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        textContainer.lineFragmentPadding = 0
        accessibilityLabel = String(localized: "Markdown editor")
    }

    // MARK: - Profile

    private func applyProfile() {
        hasAppliedProfile = true
        let theme = Theme.theme(for: profile)
        backgroundColor = theme.backgroundColor
        // On iOS the tint colours both the caret and the selection.
        tintColor = theme.caretColor
        keyboardAppearance = theme.usesDarkChrome ? .dark : .default
        typingAttributes = MarkdownTextStyle.baseAttributes(for: profile)
        updateTextContainerInset()
        refreshHighlighting()
        refreshReadingAssists()
        setNeedsSpellingUnderlineRedraw()
        setNeedsHistoryWashRedraw()
        setNeedsAIMarkWashRedraw()
    }

    private func updateTextContainerInset() {
        let side = EditorReadingLayout.horizontalInset(forContainerWidth: bounds.width, profile: profile)
        let inset = UIEdgeInsets(top: Self.verticalInset, left: side, bottom: Self.verticalInset, right: side)
        if textContainerInset != inset {
            textContainerInset = inset
        }
    }

    override func layoutSubviews() {
        updateTextContainerInset()
        super.layoutSubviews()
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            // A new size can uncover lines the last pass never reached. Deferred: no storage
            // writes from inside layout.
            visibleRangeDidChange()
            refreshReadingAssists()
            needsSpellingUnderlineRedraw = true
            state.needsHistoryWashRedraw = true
            if state.keepsCaretVisibleOnResize, isFirstResponder {
                // Deferred: never scroll from inside layout.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isFirstResponder else { return }
                    self.scrollRangeToVisible(self.selectedRange)
                }
            }
        }
        // After super: the underlines follow this layout pass (an edit, a re-style, a new size).
        redrawSpellingUnderlinesIfNeeded()
        redrawHistoryWashIfNeeded()
        redrawAIMarkWashIfNeeded()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateReadingRulerColor()
    }

    // MARK: - Key commands (rules in LineformiOSTextView+Editing.swift)

    private static let markdownKeyCommands = makeMarkdownKeyCommands()

    override var keyCommands: [UIKeyCommand]? {
        // History mode's ← / → / Esc first, so they win over the text view's own arrow handling.
        (state.isShowingHistoryMode ? Self.historyKeyCommands : []) + (super.keyCommands ?? []) + Self.markdownKeyCommands
    }

    /// In History mode the steps are not undoable one by one (the Mac's stand-in manager): ⌘Z,
    /// shake and the undo key find an empty manager. History's own edits and its exit use the real
    /// one, so the session collapses into ONE undoable edit on the document's own stack.
    override var undoManager: UndoManager? {
        if state.historyController?.isHistoryModeActive == true, !state.isApplyingHistoryEdit {
            if let standIn = state.historyStandInUndoManager { return standIn }
            let standIn = UndoManager()
            state.historyStandInUndoManager = standIn
            return standIn
        }
        return super.undoManager
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        canPerformDuringAIReview(action)
            ?? canPerformMarkdownAction(action)
            ?? canPerformImagePaste(action)
            ?? super.canPerformAction(action, withSender: sender)
    }

    // MARK: - Text

    /// Replaces the whole text, styled with the base attributes, then runs a full pass. The
    /// selection is kept where it was, clamped to the new text, so a live reload does not throw
    /// the caret to the end.
    func setDocumentText(_ text: String) {
        let selection = selectedRange
        let attributes = MarkdownTextStyle.baseAttributes(for: profile)
        state.isReplacingWholeText = true
        attributedText = NSAttributedString(string: text, attributes: attributes)
        state.isReplacingWholeText = false
        typingAttributes = attributes
        let length = (text as NSString).length
        let location = min(selection.location, length)
        // The app's own selection (a position restore): it never raises the selection row.
        selectProgrammatically(NSRange(location: location, length: min(selection.length, length - location)))
        refreshHighlighting()
        refreshReadingAssists()
        scheduleSpellCheck()
    }

    // MARK: - Highlighting

    /// Full pass: base attributes over the whole document, token inks over the visible window
    /// plus margin. Skipped (and remembered) while an input method is composing.
    func refreshHighlighting() {
        guard markedTextRange == nil else {
            needsFullHighlight = true
            return
        }
        needsFullHighlight = false
        let scope = currentTokenScope()
        MarkdownTokenStyler.apply(to: textStorage, profile: profile, tokenScope: scope)
        lastHighlightedTokenRange = scope
        typingAttributes = MarkdownTextStyle.baseAttributes(for: profile)
    }

    /// Typing-pause pass: re-tokenizes only the visible window. Base is already whole-document
    /// from the last full pass and edits insert base-styled text, so nothing else is written.
    @objc func refreshHighlightingAfterTypingDelay() {
        guard markedTextRange == nil else { return }
        guard !needsFullHighlight else {
            refreshHighlighting()
            return
        }
        let scope = currentTokenScope()
        MarkdownTokenStyler.applyTokens(to: textStorage, profile: profile, scope: scope)
        lastHighlightedTokenRange = scope
    }

    /// Scroll pass: re-tokenizes only when the visible window is no longer covered by the last
    /// pass, so an ordinary in-margin scroll does no work.
    @objc func refreshVisibleTokensIfNeeded() {
        guard markedTextRange == nil else { return }
        guard !needsFullHighlight else {
            refreshHighlighting()
            return
        }
        let scope = currentTokenScope()
        if let last = lastHighlightedTokenRange, MarkdownTokenScope.range(last, covers: scope) {
            return
        }
        MarkdownTokenStyler.applyTokens(to: textStorage, profile: profile, scope: scope)
        lastHighlightedTokenRange = scope
    }

    /// Called for every text change: schedules the typing-delay pass and the spell-check pass,
    /// never a synchronous one.
    func textDidChangeForHighlighting() {
        let selector = #selector(refreshHighlightingAfterTypingDelay)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
        perform(selector, with: nil, afterDelay: Self.typingHighlightDelay, inModes: [.common])
        scheduleSpellCheck()
    }

    /// Called from `scrollViewDidScroll` and on a size change.
    func visibleRangeDidChange() {
        let selector = #selector(refreshVisibleTokensIfNeeded)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
        perform(selector, with: nil, afterDelay: Self.scrollHighlightDebounce, inModes: [.common])
        scheduleSpellCheck()
    }

    /// The visible character range expanded by `highlightMargin` and snapped to line boundaries.
    /// Before the view has a size, the window is the caret's neighbourhood, never the whole
    /// document; the first layout schedules a coverage check that fills in the real window.
    func currentTokenScope() -> NSRange {
        let text = textStorage.string as NSString
        let visible = visibleCharacterRange()
            ?? NSRange(location: min(selectedRange.location, text.length), length: 0)
        return MarkdownTokenScope.scopedTokenRange(in: text, around: visible, margin: Self.highlightMargin)
    }

    /// The on-screen character range. `glyphRange(forBoundingRect:)` lays out lazily, only what
    /// the rect needs, so this stays cheap on a large document.
    func visibleCharacterRange() -> NSRange? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var rect = bounds
        rect.origin.x -= textContainerInset.left
        rect.origin.y -= textContainerInset.top
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    // MARK: - Position (the mode switch)

    /// Space left above a line scrolled to the top, as on the Mac and in Read.
    static let scrollTopMargin: CGFloat = 8
    /// How far below the exact top the position probe reads (the Mac's `visibleTopProbeInset`):
    /// a line parked 8 pt below the top is the one found, not the sliver of the line above.
    static let visibleTopProbeInset: CGFloat = 14
    /// How many runloop ticks a cross-mode restore is re-asserted for (the Mac's 5).
    static let persistentScrollReasserts = 5

    /// The source offset of the first line at the top of the page (the editor's text is the
    /// source), read `visibleTopProbeInset` below the exact top as on the Mac; nil before the view
    /// has a size.
    func topVisibleSourceLocation() -> Int? {
        let length = textStorage.length
        guard length > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let probe = Self.visibleTopProbeInset
        let visibleHeight = max(1, bounds.height - adjustedContentInset.top - adjustedContentInset.bottom - probe)
        let rect = CGRect(
            x: 0,
            y: max(0, contentOffset.y + adjustedContentInset.top + probe - textContainerInset.top),
            width: max(1, textContainer.size.width),
            height: visibleHeight
        )
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return min(max(0, characters.location), length - 1)
    }

    /// Parks the line holding `range`'s start at the top of the page, 8 pt below it (the Mac's
    /// `scrollCharacterRangeToTop`), clamped to the laid-out page. Never selects text.
    func scrollCharacterRangeToTop(_ range: NSRange) {
        let length = textStorage.length
        let top = -adjustedContentInset.top
        guard length > 0, bounds.height > 0 else {
            setContentOffset(CGPoint(x: contentOffset.x, y: top), animated: false)
            return
        }
        let location = min(max(0, range.location), length - 1)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: location, length: 1),
            actualCharacterRange: nil
        )
        // The prefix through the target is laid out, so its line's position is exact (TextKit 1
        // layout here is non-contiguous), then one page below it, never the rest of the document:
        // laying out the whole text cost about 600 ms on 1 MB for a target near the top.
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: NSMaxRange(glyphRange)))
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let targetTop = max(0, rect.minY + textContainerInset.top - Self.scrollTopMargin)
        let y = max(top, targetTop - adjustedContentInset.top)
        let page = CGRect(x: 0, y: rect.minY, width: max(1, textContainer.size.width), height: bounds.height + Self.scrollTopMargin)
        layoutManager.ensureLayout(forBoundingRect: page, in: textContainer)
        let pageGlyphs = layoutManager.glyphRange(forBoundingRect: page, in: textContainer)
        if NSMaxRange(pageGlyphs) < layoutManager.numberOfGlyphs {
            // More than a page follows: the offset can never pass the end.
            if abs(contentOffset.y - y) > 0.5 {
                setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false)
            }
            return
        }
        // The document ends within the page, and all of it is laid out now: clamp to its end.
        let contentHeight = layoutManager.usedRect(for: textContainer).height
            + textContainerInset.top + textContainerInset.bottom
        let maximumY = max(top, contentHeight + adjustedContentInset.bottom - bounds.height)
        let clamped = min(y, maximumY)
        if abs(contentOffset.y - clamped) > 0.5 {
            setContentOffset(CGPoint(x: contentOffset.x, y: clamped), animated: false)
        }
    }

    /// Scrolls `range` to the top and keeps it there for the next few runloop ticks (the Mac's
    /// `scrollCharacterRangeToTopPersistently`): a view just resized by the mode switch, or UIKit
    /// growing `contentSize` behind it, can put the offset back a tick later. A touch on the page
    /// ends the re-asserting at once.
    func scrollCharacterRangeToTopPersistently(_ range: NSRange) {
        state.persistentScrollTarget = range
        state.persistentScrollReassertsRemaining = Self.persistentScrollReasserts
        reassertPersistentScrollIfNeeded()
    }

    private func reassertPersistentScrollIfNeeded() {
        guard let range = state.persistentScrollTarget,
              state.persistentScrollReassertsRemaining > 0,
              !isTracking, !isDecelerating
        else {
            state.persistentScrollTarget = nil
            return
        }
        state.persistentScrollReassertsRemaining -= 1
        scrollCharacterRangeToTop(range)
        DispatchQueue.main.async { [weak self] in
            self?.reassertPersistentScrollIfNeeded()
        }
    }

    /// Preview's editor pane keeps the caret in view when its size changes (the keyboard).
    var keepsCaretVisibleOnResize: Bool {
        get { state.keepsCaretVisibleOnResize }
        set { state.keepsCaretVisibleOnResize = newValue }
    }
}

// MARK: - Accessibility: rotors and History's actions

/// The non-visual paths to what the editor only DRAWS (the accessibility mirror rule): custom
/// rotors over the misspellings (`SpellCheckPass`'s results — the system checker is off, so
/// VoiceOver's own Misspelled Words rotor would find nothing), Mark's sentences while they show,
/// and History's passages in History mode; and History mode's commands as custom actions (the
/// Mac's `HistoryModeAccessibilityAction`). The text view's accessibility VALUE is its text and is
/// never overridden.
extension LineformTextView {
    override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get {
            var rotors: [UIAccessibilityCustomRotor] = [misspellingRotor()]
            if !state.aiMarkRanges.isEmpty { rotors.append(markedSentenceRotor()) }
            if isShowingHistoryMode { rotors.append(historyPassageRotor()) }
            return rotors
        }
        set {}
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let base = super.accessibilityCustomActions ?? []
            return base + historyAccessibilityActions()
        }
        set {}
    }

    /// The rotor's name for Mark's sentences.
    static var markedSentencesRotorName: String { String(localized: "Marked sentences") }
    /// The rotor's name for History's passages.
    static var historyPassagesRotorName: String { String(localized: "Passages") }

    /// The range a rotor lands on from `current` (nil: the rotor starts at `caret`): the first of
    /// `ranges` after it going forward, the last before it going back. Nil at either end.
    static func rotorTarget(in ranges: [NSRange], from current: NSRange?, caret: Int, forward: Bool) -> NSRange? {
        let sorted = ranges.filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted { ($0.location, $1.length) < ($1.location, $0.length) }
        if let current {
            return forward
                ? sorted.first { $0.location > current.location || ($0.location == current.location && $0.length < current.length) }
                : sorted.last { $0.location < current.location || ($0.location == current.location && $0.length > current.length) }
        }
        return forward ? sorted.first { $0.location >= caret } : sorted.last { $0.location < caret }
    }

    /// The text range of `range`, clamped to the text; nil when it falls outside.
    func accessibilityTextRange(for range: NSRange) -> UITextRange? {
        guard range.location != NSNotFound, NSMaxRange(range) <= textStorage.length,
              let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length) else { return nil }
        return textRange(from: start, to: end)
    }

    /// A rotor over `ranges()` (read each time it moves). `landed` runs on the range it lands on.
    private func rangeRotor(
        _ make: (@escaping UIAccessibilityCustomRotor.Search) -> UIAccessibilityCustomRotor,
        ranges: @escaping @MainActor (LineformTextView) -> [NSRange],
        landed: (@MainActor (LineformTextView, NSRange) -> Void)? = nil
    ) -> UIAccessibilityCustomRotor {
        make { [weak self] predicate in
            guard let self else { return nil }
            return MainActor.assumeIsolated {
                var current: NSRange?
                if let item = predicate.currentItem.targetRange, predicate.currentItem.targetElement === self {
                    current = NSRange(location: self.offset(from: self.beginningOfDocument, to: item.start),
                                      length: self.offset(from: item.start, to: item.end))
                }
                guard let target = Self.rotorTarget(in: ranges(self), from: current, caret: self.selectedRange.location,
                                                    forward: predicate.searchDirection == .next),
                      let textRange = self.accessibilityTextRange(for: target) else { return nil }
                landed?(self, target)
                return UIAccessibilityCustomRotorItemResult(targetElement: self, targetRange: textRange)
            }
        }
    }

    private func misspellingRotor() -> UIAccessibilityCustomRotor {
        rangeRotor({ search in UIAccessibilityCustomRotor(systemType: .misspelledWord, itemSearch: search) },
                   ranges: { view in view.spellCheck.misspelledRanges })
    }

    private func markedSentenceRotor() -> UIAccessibilityCustomRotor {
        rangeRotor({ search in UIAccessibilityCustomRotor(name: Self.markedSentencesRotorName, itemSearch: search) },
                   ranges: { view in view.aiMarkRanges })
    }

    /// History's passages in text order. Landing on one selects it, as a tap on its wash does, so
    /// the card shows its versions. The selection waits for the next turn of the run loop (after
    /// VoiceOver has the item), and it is quiet: VoiceOver is reading the passage, and the card's
    /// "Paragraph, version 2 of 3" would talk over it.
    private func historyPassageRotor() -> UIAccessibilityCustomRotor {
        rangeRotor({ search in UIAccessibilityCustomRotor(name: Self.historyPassagesRotorName, itemSearch: search) },
                   ranges: { view in view.historyWashDisplay?.passages.map(\.range) ?? [] },
                   landed: { view, range in
                       guard let display = view.historyWashDisplay,
                             let passage = display.passages.first(where: { $0.range == range }),
                             view.historyController?.selectedPassageID != passage.id else { return }
                       let id = passage.id
                       Task { @MainActor [weak view] in
                           view?.historyController?.select(id, announces: false)
                       }
                   })
    }

    /// History mode's commands, in the Mac's rotor order: Select Next / Previous Passage, then
    /// (a passage selected) Previous / Next Version, then Exit History. None outside History mode.
    func historyAccessibilityActions() -> [UIAccessibilityCustomAction] {
        guard isShowingHistoryMode, let controller = historyController, controller.isHistoryModeActive else { return [] }
        var actions: [(String, @MainActor (LineformTextView) -> Void)] = [
            (HistoryCardModel.nextPassageTitle, { view in view.historyController?.moveSelection(by: 1) }),
            (HistoryCardModel.previousPassageTitle, { view in view.historyController?.moveSelection(by: -1) }),
        ]
        if controller.selectedPassageID != nil {
            actions.append((String(localized: "Previous Version"), { view in view.historyPreviousVersion(nil) }))
            actions.append((String(localized: "Next Version"), { view in view.historyNextVersion(nil) }))
        }
        actions.append((HistoryCardModel.exitTitle, { view in
            view.historyController?.exitHistoryMode(text: view.textStorage.string)
        }))
        return actions.map { name, perform in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let self else { return false }
                MainActor.assumeIsolated { perform(self) }
                return true
            }
        }
    }
}

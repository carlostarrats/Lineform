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
        textView.configureImagePasteAndDrop()
        textView.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (textView: LineformTextView, _) in
            textView.redrawSpellingUnderlines()
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
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateReadingRulerColor()
    }

    // MARK: - Key commands (rules in LineformiOSTextView+Editing.swift)

    private static let markdownKeyCommands = makeMarkdownKeyCommands()

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + Self.markdownKeyCommands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        canPerformMarkdownAction(action)
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
        attributedText = NSAttributedString(string: text, attributes: attributes)
        typingAttributes = attributes
        let length = (text as NSString).length
        let location = min(selection.location, length)
        selectedRange = NSRange(location: location, length: min(selection.length, length - location))
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
        layoutManager.ensureLayout(for: textContainer)
        let location = min(max(0, range.location), length - 1)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: location, length: 1),
            actualCharacterRange: nil
        )
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let targetTop = max(0, rect.minY + textContainerInset.top - Self.scrollTopMargin)
        let contentHeight = layoutManager.usedRect(for: textContainer).height
            + textContainerInset.top + textContainerInset.bottom
        let maximumY = max(top, contentHeight + adjustedContentInset.bottom - bounds.height)
        let y = min(max(top, targetTop - adjustedContentInset.top), maximumY)
        if abs(contentOffset.y - y) > 0.5 {
            setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false)
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

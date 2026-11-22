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
    var profile: ReadingProfile = .original {
        didSet {
            if profile != oldValue || !hasAppliedProfile { applyProfile() }
        }
    }

    /// The range the last token pass covered; a scroll inside it does no work.
    private(set) var lastHighlightedTokenRange: NSRange?
    #if DEBUG
    /// Lets a test make the next scroll pass find its window uncovered.
    var lastHighlightedTokenRangeForTesting: NSRange? {
        get { lastHighlightedTokenRange }
        set { lastHighlightedTokenRange = newValue }
    }
    #endif
    /// A full pass was skipped during composition; the next pass runs it instead.
    private(set) var needsFullHighlight = false
    private var hasAppliedProfile = false
    private var lastLayoutSize: CGSize = .zero

    /// A configured editor. Separate from `MarkdownEditor.makeUIView` so tests build one directly.
    static func make(profile: ReadingProfile = .original) -> LineformTextView {
        let textView = LineformTextView(usingTextLayoutManager: false)
        textView.configureForMarkdownEditing()
        textView.profile = profile
        if !textView.hasAppliedProfile { textView.applyProfile() }
        return textView
    }

    private func configureForMarkdownEditing() {
        autocapitalizationType = .sentences
        smartQuotesType = .no
        smartDashesType = .no
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
        }
    }

    // MARK: - Key commands (rules in LineformiOSTextView+Editing.swift)

    private static let markdownKeyCommands = makeMarkdownKeyCommands()

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + Self.markdownKeyCommands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        canPerformMarkdownAction(action) ?? super.canPerformAction(action, withSender: sender)
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

    /// Called for every text change: schedules the typing-delay pass, never a synchronous one.
    func textDidChangeForHighlighting() {
        let selector = #selector(refreshHighlightingAfterTypingDelay)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
        perform(selector, with: nil, afterDelay: Self.typingHighlightDelay, inModes: [.common])
    }

    /// Called from `scrollViewDidScroll` and on a size change.
    func visibleRangeDidChange() {
        let selector = #selector(refreshVisibleTokensIfNeeded)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
        perform(selector, with: nil, afterDelay: Self.scrollHighlightDebounce, inModes: [.common])
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
    private func visibleCharacterRange() -> NSRange? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var rect = bounds
        rect.origin.x -= textContainerInset.left
        rect.origin.y -= textContainerInset.top
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }
}

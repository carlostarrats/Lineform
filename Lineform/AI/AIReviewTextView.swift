import AppKit

/// The review overlay (spec "AI review: option A"): a read-only text view laid exactly over the
/// editor while a review is up, showing `AIReviewComposition` — the original struck through in
/// the receded ink, the replacement on the review highlight. Nothing in it is clickable: the
/// decision is the card's, or Return / Esc. The document's own text storage never holds a
/// suggestion, so autosave, live reload and undo can never write one to the `.md`.
///
/// It holds the keyboard during review, like search: Return accepts the change, Esc rejects it
/// and ends the review, and typing ends it and types into the document. Keys
/// arrive through `doCommand(by:)` and `insertText` — never `keyDown`. Its undo manager is an
/// empty private one, so ⌘Z during a review can never pop the document's undo stack underneath.
final class AIReviewTextView: NSTextView {
    var commandHandler: ((AIReviewCommand) -> Void)?
    /// The editor underneath. A key that is not a review key ends the review and is re-sent to
    /// it, so the editor's own input context handles plain text, dead keys and input methods.
    weak var handOffEditor: NSTextView?

    private(set) var composition = AIReviewComposition.empty
    private(set) var currentID: Int?
    private let emptyUndoManager = UndoManager()
    private let highlighter = MarkdownSyntaxHighlighter()

    /// A TextKit 1 stack, like the editor's: the overlay must lay out line for line as it does.
    static func make() -> AIReviewTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        return AIReviewTextView(frame: .zero, textContainer: textContainer)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isEditable = false
        isSelectable = false
        isRichText = true
        allowsUndo = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        usesFindPanel = false
        if #available(macOS 15.0, *) {
            writingToolsBehavior = .none
        }
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = false
        drawsBackground = true
        setAccessibilityLabel(String(localized: "Suggested changes"))
        setAccessibilityRole(.textArea)
    }

    // MARK: - Presenting

    /// Draws `composition`: Markdown highlighting as the editor has it, the removed originals in
    /// History's receded ink with a single strikethrough, and the replacements on
    /// `HistoryPalette.reviewInsertTint` (their inks re-measured against it,
    /// `reviewReplacementInk`). All are layout-manager TEMPORARY attributes: the
    /// storage keeps only the highlighter's attributes, so a span pass and a whole pass agree.
    ///
    /// A decision re-presents with the SAME profile, and its composition differs from the last
    /// one only around the decided change. That case replaces just the differing span and
    /// re-tokenizes just its lines (`MarkdownRangeAnalyzer` is line-local, so the result is
    /// identical to a whole pass). Measured on a 700 KB document: the whole pass cost ~80 ms of
    /// highlighting plus ~500 ms of re-layout per decision; the span pass keeps the layout of
    /// everything it does not touch. The first present (and a profile change) is a whole pass.
    func present(_ composition: AIReviewComposition, currentID: Int?, profile: ReadingProfile) {
        let previous = self.composition
        self.composition = composition
        self.currentID = currentID
        let theme = Theme.theme(for: profile)
        let receded = HistoryPalette.recededInk(for: theme)
        let base = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        backgroundColor = theme.backgroundColor
        // Never `font =` / `textColor =`: each rewrites the WHOLE storage (~100 ms at 700 KB), and
        // the storage carries the base attributes already.
        typingAttributes = base

        guard let textStorage, let layoutManager else { return }
        let isIncremental = presentedProfile == profile && textStorage.length > 0
            && textStorage.string.utf16.elementsEqual(previous.string.utf16)
        presentedProfile = profile
        if isIncremental {
            if let span = Self.differingSpan(from: previous.string, to: composition.string) {
                textStorage.replaceCharacters(in: span.old,
                                              with: NSAttributedString(string: (composition.string as NSString).substring(with: span.new),
                                                                       attributes: base))
                let lines = (composition.string as NSString).lineRange(for: span.new)
                highlighter.refreshTokens(textView: self, profile: profile, scope: lines)
            }
        } else {
            textStorage.setAttributedString(NSAttributedString(string: composition.string, attributes: base))
            highlighter.highlight(textView: self, profile: profile)
        }

        let whole = NSRange(location: 0, length: textStorage.length)
        for key in [NSAttributedString.Key.foregroundColor, .strikethroughStyle, .backgroundColor] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: whole)
        }
        for range in composition.removedRanges.values.joined() {
            let clamped = NSIntersectionRange(range, whole)
            guard clamped.length > 0 else { continue }
            layoutManager.addTemporaryAttributes([.foregroundColor: receded,
                                                  .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                                                 forCharacterRange: clamped)
        }
        // The CURRENT change's replacement is on the full review highlight; with several pending
        // (Proofread), the others are on a lighter one. Accepted ones are plain text.
        for (id, ranges) in composition.replacementRanges {
            let isCurrent = id == currentID || composition.replacementRanges.count == 1
            let tint = isCurrent ? HistoryPalette.reviewInsertTint(for: theme) : HistoryPalette.reviewInsertOtherTint(for: theme)
            for range in ranges {
                let clamped = NSIntersectionRange(range, whole)
                guard clamped.length > 0 else { continue }
                layoutManager.addTemporaryAttribute(.backgroundColor, value: tint, forCharacterRange: clamped)
                // The highlighter's inks are set against the page; on the tint a link (and, on
                // Quiet, code) falls under AA. Re-ink just the runs that need it; body text keeps
                // its ink.
                textStorage.enumerateAttribute(.foregroundColor, in: clamped) { value, run, _ in
                    guard let ink = value as? NSColor else { return }
                    let onTint = HistoryPalette.reviewReplacementInk(ink, for: theme, on: tint)
                    guard onTint !== ink else { return }
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: onTint, forCharacterRange: run)
                }
            }
        }
        // A whole pass sizes the view now (the scroll hand-over reads line positions at once). A
        // span pass leaves it to the layout manager: `sizeToFit` would lay out the WHOLE
        // document after the span (~450 ms at 700 KB); unforced, only what is shown is laid out
        // now, the rest in background layout, and the view grows with it (vertically resizable).
        if !isIncremental { sizeToFit() }
        needsDisplay = true
    }

    private var presentedProfile: ReadingProfile?

    /// The one span where `old` and `new` differ: the range to replace in `old`, and the range of
    /// its replacement in `new` (between their common UTF-16 prefix and suffix). Nil when equal.
    static func differingSpan(from old: String, to new: String) -> (old: NSRange, new: NSRange)? {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var prefix = 0
        let shorter = min(a.count, b.count)
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        if prefix == a.count, prefix == b.count { return nil }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return (NSRange(location: prefix, length: a.count - suffix - prefix),
                NSRange(location: prefix, length: b.count - suffix - prefix))
    }

    /// Lays the overlay out exactly as `editor` is laid out, so its lines sit on the editor's.
    func matchGeometry(of editor: NSTextView) {
        textContainerInset = editor.textContainerInset
        if let mine = textContainer, let theirs = editor.textContainer {
            mine.lineFragmentPadding = theirs.lineFragmentPadding
            mine.widthTracksTextView = false
            if mine.containerSize.width != theirs.containerSize.width {
                mine.containerSize = NSSize(width: theirs.containerSize.width, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        if frame.width != editor.frame.width {
            setFrameSize(NSSize(width: editor.frame.width, height: frame.height))
        }
        defaultParagraphStyle = editor.defaultParagraphStyle
        backgroundColor = editor.backgroundColor
        drawsBackground = true
    }

    /// The range to scroll into view for the current change.
    var currentChangeRange: NSRange? {
        currentID.flatMap { composition.changeRanges[$0] }
    }

    // MARK: - Read-only

    override var acceptsFirstResponder: Bool { true }

    /// The overlay takes the keyboard the moment it is in a window. The representable's own grab
    /// runs on the next turn and again on later updates, but SwiftUI can insert the view after that
    /// turn and push no further update — then Return (accept) went to the read-only editor and did
    /// nothing until some other key happened to trigger an update.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, commandHandler != nil, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }
    override var undoManager: UndoManager? { emptyUndoManager }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool { false }

    // MARK: - Keys

    /// Routing, not interception. A key that is not a review key (and carries no ⌘ or ⌃) ends
    /// the review and is re-sent, unchanged, to the editor — which then handles it exactly as if
    /// it had been typed there: plain text, a dead key (⌥E, ⌥U, ^), or the first key of an input
    /// method's composition (Japanese, Chinese). Ending the review in `insertText` instead would
    /// drop that first keystroke, because a dead key or an input method never reaches
    /// `insertText` on its first press.
    ///
    /// Review keys go to `interpretKeyEvents`: a NON-editable NSTextView drops key events before
    /// key binding, so the overlay runs it itself, and the decisions are made in
    /// `doCommand(by:)`. The editor still never intercepts `keyDown` (CLAUDE.md invariant); this
    /// is the overlay choosing which view the event belongs to.
    ///
    /// Delete (⌫) only ENDS the review: it is not re-sent. Ending collapses the editor's selection
    /// to the passage's end (the controller), so a re-sent ⌫ would eat the passage's last
    /// character — a deletion the writer aimed at the review, not at the text.
    override func keyDown(with event: NSEvent) {
        if Self.handsOffToEditor(event), let editor = handOffEditor {
            commandHandler?(.end)
            (editor as? LineformTextView)?.prepareForAIHandOff()
            editor.window?.makeFirstResponder(editor)
            if !Self.deletionKeyCodes.contains(event.keyCode) {
                editor.keyDown(with: event)
            }
            return
        }
        interpretKeyEvents([event])
    }

    /// Delete (⌫). Forward Delete (⌦) is a function key, so it never hands off at all.
    static let deletionKeyCodes: Set<UInt16> = [51]

    /// Return / Enter, Esc, ← / → (move between changes), ↑ / ↓ (scroll), Page Up/Down, Home and
    /// End belong to the review.
    static let reviewKeyCodes: Set<UInt16> = [125, 126, 123, 124, 36, 76, 53, 116, 121, 115, 119]

    /// Whether `event` ends the review and goes to the editor: any key but a review key, unless
    /// ⌘ or ⌃ is held (shortcuts stay with the menus and key bindings) or it is a function key
    /// (F1…, which types nothing).
    static func handsOffToEditor(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !reviewKeyCodes.contains(event.keyCode) else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control]).isEmpty else { return false }
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           (0xF700...0xF8FF).contains(scalar.value) {
            return false
        }
        return true
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            commandHandler?(.acceptCurrent)
        case #selector(NSResponder.cancelOperation(_:)):
            // Rejects the current change (a one-change review then ends; Proofread moves on).
            commandHandler?(.rejectCurrent)
        case #selector(NSResponder.moveLeft(_:)):
            commandHandler?(.move(-1))
        case #selector(NSResponder.moveRight(_:)):
            commandHandler?(.move(1))
        case #selector(NSResponder.moveUp(_:)):
            super.doCommand(by: #selector(NSResponder.scrollLineUp(_:)))
        case #selector(NSResponder.moveDown(_:)):
            super.doCommand(by: #selector(NSResponder.scrollLineDown(_:)))
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.scrollPageDown(_:)),
             #selector(NSResponder.pageUp(_:)), #selector(NSResponder.pageDown(_:)),
             #selector(NSResponder.scrollToBeginningOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)),
             #selector(NSResponder.scrollLineUp(_:)), #selector(NSResponder.scrollLineDown(_:)):
            super.doCommand(by: selector)
        default:
            // Nothing else edits or moves anything during a review.
            break
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        commandHandler?(.typed(text))
    }

    /// Fallback only (`keyDown` normally routes such keys to the editor first): an input method
    /// starting a composition here ends the review rather than composing into a read-only view.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        commandHandler?(.end)
    }

    override func hasMarkedText() -> Bool { false }

    // MARK: - Mouse

    /// A click on a pending change makes it current (Proofread); nothing else is clickable — the
    /// decisions are the card's, Return and Esc.
    override func mouseDown(with event: NSEvent) {
        guard let layoutManager, let container = textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        if let id = composition.changeID(at: index) { commandHandler?(.select(id)) }
    }

    /// The pointer stays an arrow over the overlay: nothing in it is text to edit or select.
    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    // MARK: - Accessibility

    /// The decisions VoiceOver, Switch Control and the keyboard reach: the same three the card
    /// and Return / Esc give — one change, one decision.
    static func accessibilityActionTitles(bundle: Bundle = .main) -> [String] {
        [
            String(localized: "Accept Change", bundle: bundle),
            String(localized: "Reject Change", bundle: bundle),
            String(localized: "End Review", bundle: bundle),
            String(localized: "Accept All", bundle: bundle),
            String(localized: "Next Change", bundle: bundle),
            String(localized: "Previous Change", bundle: bundle),
        ]
    }

    /// How many changes are still pending (set by the representable): Accept All and moving
    /// between changes are offered only with two or more.
    var pendingCount = 1

    override func accessibilityValue() -> String? {
        composition.string
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let titles = Self.accessibilityActionTitles()
        var commands: [(String, AIReviewCommand)] = []
        if let id = currentID {
            commands.append((titles[0], .accept(id)))
            commands.append((titles[1], .reject(id)))
        }
        if pendingCount > 1 {
            commands.append((titles[3], .acceptAll))
            commands.append((titles[4], .move(1)))
            commands.append((titles[5], .move(-1)))
        }
        commands.append((titles[2], .end))
        return commands.map { title, command in
            NSAccessibilityCustomAction(name: title) { [weak self] in
                guard let handler = self?.commandHandler else { return false }
                handler(command)
                return true
            }
        }
    }
}

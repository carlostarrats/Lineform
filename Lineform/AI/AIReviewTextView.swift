import AppKit

/// The review overlay (spec §4.1): a read-only text view laid exactly over the editor while a
/// review is up, showing `AIReviewComposition` — removed text dimmed, insertions inline in the
/// normal ink, a ✓|✕ pill at the end of each change. The document's own text storage never holds
/// a suggestion, so autosave, live reload and undo can never write one to the `.md`.
///
/// It holds the keyboard during review, like search: ← / → move between changes, Return accepts
/// the current one, Esc ends the review, and typing ends it and types into the document. Keys
/// arrive through `doCommand(by:)` and `insertText` — never `keyDown`. Its undo manager is an
/// empty private one, so ⌘Z during a review can never pop the document's undo stack underneath.
final class AIReviewTextView: NSTextView {
    var commandHandler: ((AIReviewCommand) -> Void)?
    /// The editor underneath. A key that is not a review key ends the review and is re-sent to
    /// it, so the editor's own input context handles plain text, dead keys and input methods.
    weak var handOffEditor: NSTextView?

    private(set) var composition = AIReviewComposition.empty
    private(set) var currentID: Int?
    private(set) var hasDecided = false
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
    /// History's receded ink (temporary attributes — the storage keeps its colours), and a pill
    /// per change (the current one in the theme's ink, the others receded).
    ///
    /// A decision re-presents with the SAME profile, and its composition differs from the last
    /// one only around the decided change. That case replaces just the differing span and
    /// re-tokenizes just its lines (`MarkdownRangeAnalyzer` is line-local, so the result is
    /// identical to a whole pass). Measured on a 700 KB document: the whole pass cost ~80 ms of
    /// highlighting plus ~500 ms of re-layout per decision; the span pass keeps the layout of
    /// everything it does not touch. The first present (and a profile change) is a whole pass.
    func present(_ composition: AIReviewComposition, currentID: Int?, profile: ReadingProfile, hasDecided: Bool = false) {
        let previous = self.composition
        self.composition = composition
        self.currentID = currentID
        self.hasDecided = hasDecided
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

        // After highlighting: its base pass resets every attribute, attachments included.
        let capHeight = (base[.font] as? NSFont)?.capHeight ?? 11
        let baselineOffset = ((capHeight - AIReviewPillCell.size.height) / 2).rounded()
        textStorage.beginEditing()
        for (id, index) in composition.pillIndices where index < textStorage.length {
            let isCurrent = id == currentID
            let cell = AIReviewPillCell(changeID: id, isCurrent: isCurrent, ink: isCurrent ? theme.textColor : receded)
            cell.baselineOffsetY = baselineOffset
            let attachment = NSTextAttachment()
            attachment.attachmentCell = cell
            textStorage.addAttribute(.attachment, value: attachment, range: NSRange(location: index, length: 1))
        }
        textStorage.endEditing()

        let whole = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        for range in composition.removedRanges.values {
            let clamped = NSIntersectionRange(range, whole)
            guard clamped.length > 0 else { continue }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: receded, forCharacterRange: clamped)
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

    /// Arrows, Return / Enter, Esc, Page Up/Down, Home and End belong to the review.
    static let reviewKeyCodes: Set<UInt16> = [123, 124, 125, 126, 36, 76, 53, 116, 121, 115, 119]

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
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveForward(_:)):
            commandHandler?(.next)
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveBackward(_:)):
            commandHandler?(.previous)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            commandHandler?(.acceptCurrent)
        case #selector(NSResponder.cancelOperation(_:)):
            commandHandler?(.end)
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let command = command(at: point) {
            commandHandler?(command)
        }
    }

    /// What a click at `point` (view coordinates) decides: a pill's ✓ or ✕, or keeping a dimmed
    /// original (or no longer keeping a kept one). Nil anywhere else.
    func command(at point: NSPoint) -> AIReviewCommand? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: 0, dy: -2).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        if let id = composition.changeID(atPill: index) {
            let cell = (textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment)?
                .attachmentCell as? AIReviewPillCell
            let part = cell?.part(at: local, in: rect) ?? (local.x < rect.midX ? .accept : .reject)
            return part == .accept ? .accept(id) : .reject(id)
        }
        if let id = composition.changeID(atRemovedOrKept: index) {
            return .toggleKeep(id)
        }
        return nil
    }

    // MARK: - Accessibility

    /// The decisions VoiceOver, Switch Control and the keyboard reach without the pills. The
    /// per-change ones act on the current change; the batch ones follow `hasDecided`.
    static func accessibilityActionTitles(hasDecided: Bool, bundle: Bundle = .main) -> [String] {
        let batch = AIReviewCardPresentation.buttonTitles(hasDecided: hasDecided, bundle: bundle)
        return [
            String(localized: "Accept Change", bundle: bundle),
            String(localized: "Reject Change", bundle: bundle),
            String(localized: "Keep Removed Text", bundle: bundle),
            String(localized: "Next Change", bundle: bundle),
            String(localized: "Previous Change", bundle: bundle),
            batch.accept,
            batch.reject,
            String(localized: "End Review", bundle: bundle),
        ]
    }

    /// The pills are drawn as attachments (U+FFFC); VoiceOver reaches them through the custom
    /// actions, so the spoken value leaves them out rather than reading "object replacement".
    override func accessibilityValue() -> String? {
        composition.string.replacingOccurrences(of: AIReviewComposition.pillCharacter, with: "")
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let titles = Self.accessibilityActionTitles(hasDecided: hasDecided)
        var commands: [(String, AIReviewCommand)] = []
        if let id = currentID {
            commands.append((titles[0], .accept(id)))
            commands.append((titles[1], .reject(id)))
            if composition.removedRanges[id] != nil || composition.keptRanges[id] != nil {
                commands.append((titles[2], .toggleKeep(id)))
            }
        }
        commands.append((titles[3], .next))
        commands.append((titles[4], .previous))
        commands.append((titles[5], .acceptRemaining))
        commands.append((titles[6], .rejectRemaining))
        commands.append((titles[7], .end))
        return commands.map { title, command in
            NSAccessibilityCustomAction(name: title) { [weak self] in
                guard let handler = self?.commandHandler else { return false }
                handler(command)
                return true
            }
        }
    }
}

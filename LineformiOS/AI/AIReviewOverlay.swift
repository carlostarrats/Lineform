import LineformCore
import SwiftUI
import UIKit

/// The iPhone review overlay (spec "AI review: option A"), the Mac's `AIReviewTextView`: a
/// read-only TextKit 1 `UITextView` laid exactly over the editor while a review is up, showing
/// `AIReviewComposition` — each pending original struck through in History's receded ink, its
/// replacement on the review tint (inks re-measured against the tint, `reviewReplacementInk`). The
/// document's text storage never holds a suggestion, so autosave, live reload and undo can never
/// write one to the `.md`.
///
/// - **Same page.** The editor's profile, text container inset, content inset (the mode control's
///   clearance), line-fragment padding and page colour (`matchGeometry`), so its lines sit on the
///   editor's. The styling here IS stored, but in the overlay's own storage, which is thrown away.
/// - **Read-only.** Not editable, not selectable, its own EMPTY undo manager (an undo during a
///   review can never pop the document's stack). It takes the keyboard focus while it is up, so
///   the software keyboard goes down and the editor underneath gets no keys.
/// - **Keys.** Hardware-keyboard `UIKeyCommand`s mirror the Mac's: Return accepts, Esc rejects,
///   ← / → move between changes. A typed key is refused, with the review's status said again.
///   No key hints are drawn: a phone usually has no keyboard.
/// - **Touch.** It scrolls on its own. A tap on a pending change makes it current (Proofread).
/// - **Accessibility.** "Suggested changes", its value the current change in words ("Replace “X”
///   with “Y”", `spokenChange`), and custom actions: Accept Change, Reject Change, Accept All,
///   Next / Previous Change (two or more pending), End Review. VoiceOver focus moves to it when the
///   review opens, and it is read again after each decision.
final class AIReviewOverlayTextView: UITextView {
    enum ReviewKey { case accept, reject, previous, next }

    /// Every stored value with a starting value, in one object made on first use: UIKit builds
    /// this class through `init(usingTextLayoutManager:)`, where Swift's property initializers do
    /// not run (`LineformTextView.State`).
    @MainActor
    final class State {
        var composition = AIReviewComposition.empty
        var currentID: Int?
        /// The profile the storage was last styled for; nil before the first present.
        var presentedProfile: ReadingProfile?
        var pendingCount = 1
        var commandHandler: ((AIReviewCommand) -> Void)?
        var refusalHandler: (() -> Void)?
        let emptyUndoManager = UndoManager()
        weak var editor: LineformTextView?
        /// The editor held the keyboard when the review opened: it gets it back at the end.
        var editorHadFocus = false
    }

    private var stateStorage: State?

    var reviewState: State {
        if let stateStorage { return stateStorage }
        let state = State()
        stateStorage = state
        return state
    }

    var commandHandler: ((AIReviewCommand) -> Void)? {
        get { reviewState.commandHandler }
        set { reviewState.commandHandler = newValue }
    }

    var refusalHandler: (() -> Void)? {
        get { reviewState.refusalHandler }
        set { reviewState.refusalHandler = newValue }
    }

    var composition: AIReviewComposition { reviewState.composition }
    var currentID: Int? { reviewState.currentID }

    /// How many changes are still pending: Accept All and moving between changes need two.
    var pendingCount: Int {
        get { reviewState.pendingCount }
        set { reviewState.pendingCount = newValue }
    }

    /// A TextKit 1 stack, like the editor's: the overlay must lay out line for line as it does.
    static func make() -> AIReviewOverlayTextView {
        let view = AIReviewOverlayTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = false
        view.alwaysBounceVertical = true
        view.writingToolsBehavior = .none
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityLabel = AIReviewCardPresentation.reviewCardLabel
        view.accessibilityIdentifier = "ai.reviewOverlay"
        let tap = UITapGestureRecognizer(target: view, action: #selector(tapped(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    // MARK: - Presenting

    /// Draws `composition` with the editor's Markdown styling for `profile`, then the review's
    /// strike, dimming and tint. The current change's replacement is on the full tint; with several
    /// pending (Proofread), the others on the lighter one.
    ///
    /// A decision (accept, reject, a new current change) re-presents a composition that differs
    /// from the one on screen in one span and a few changes' tints. With the same profile, only
    /// that span is replaced and only the lines it and the re-tinted changes touch are restyled
    /// (`presentIncrementally`): restyling and re-laying out the whole composition cost about
    /// 680 ms per decision on 1 MB. The result is attribute for attribute what a whole present
    /// draws (`PhonePerformanceBudgetTests.testIncrementalPresentDrawsWhatAWholePresentDraws`).
    func present(_ composition: AIReviewComposition, currentID: Int?, profile: ReadingProfile) {
        let previous = reviewState.composition
        let previousCurrentID = reviewState.currentID
        let previousProfile = reviewState.presentedProfile
        reviewState.composition = composition
        reviewState.currentID = currentID
        reviewState.presentedProfile = profile
        let theme = Theme.theme(for: profile)
        let storage = textStorage
        if previousProfile == profile, storage.length > 0, storage.length == (previous.string as NSString).length {
            presentIncrementally(composition, currentID: currentID, replacing: previous,
                                 previousCurrentID: previousCurrentID, profile: profile, theme: theme)
        } else {
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString(string: composition.string,
                                                           attributes: MarkdownTextStyle.baseAttributes(for: profile)))
            MarkdownTokenStyler.apply(to: storage, profile: profile, tokenScope: nil)
            Self.applyReviewStyling(composition, currentID: currentID, theme: theme, to: storage,
                                    within: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        backgroundColor = theme.backgroundColor
        indicatorStyle = theme.usesDarkChrome ? .white : .black
    }

    /// The strike and dimming of every pending original, and the tint (with re-measured inks) of
    /// every replacement, inside `scope` only. Over freshly styled text, so the re-ink starts from
    /// the highlighter's inks.
    private static func applyReviewStyling(_ composition: AIReviewComposition, currentID: Int?, theme: Theme,
                                           to storage: NSTextStorage, within scope: NSRange) {
        let receded = HistoryPalette.recededInk(for: theme)
        for range in composition.removedRanges.values.joined() {
            let clamped = NSIntersectionRange(range, scope)
            guard clamped.length > 0 else { continue }
            storage.addAttributes([.foregroundColor: receded,
                                   .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: clamped)
        }
        for (id, ranges) in composition.replacementRanges {
            let isCurrent = id == currentID || composition.replacementRanges.count == 1
            let tint = isCurrent ? HistoryPalette.reviewInsertTint(for: theme) : HistoryPalette.reviewInsertOtherTint(for: theme)
            for range in ranges {
                let clamped = NSIntersectionRange(range, scope)
                guard clamped.length > 0 else { continue }
                storage.addAttribute(.backgroundColor, value: tint, range: clamped)
                // The highlighter's inks are set against the page; on the tint a link (and, on
                // Quiet, code) falls under AA. Re-ink just the runs that need it.
                storage.enumerateAttribute(.foregroundColor, in: clamped) { value, run, _ in
                    guard let ink = value as? UIColor else { return }
                    let onTint = HistoryPalette.reviewReplacementInk(ink, for: theme, on: tint)
                    guard onTint !== ink else { return }
                    storage.addAttribute(.foregroundColor, value: onTint, range: run)
                }
            }
        }
    }

    /// How a change is drawn: absent (plain document or accepted text), pending on the full tint,
    /// or pending on the lighter one.
    private enum ChangeLook: Equatable { case plain, current, other }

    private static func look(of id: Int, in composition: AIReviewComposition, currentID: Int?) -> ChangeLook {
        guard composition.changeRanges[id] != nil || composition.removedRanges[id] != nil
            || composition.replacementRanges[id] != nil else { return .plain }
        return id == currentID || composition.replacementRanges.count == 1 ? .current : .other
    }

    private static func ranges(of id: Int, in composition: AIReviewComposition) -> [NSRange] {
        (composition.removedRanges[id] ?? []) + (composition.replacementRanges[id] ?? [])
            + (composition.changeRanges[id].map { [$0] } ?? [])
    }

    /// Replaces the one span where the two compositions' strings differ, then restyles (base,
    /// tokens, review styling) only the whole lines that span and every change whose look changed
    /// touch. Everything else keeps the attributes it was drawn with, moved with its text. The
    /// token analyzer is line-local, so tokens of whole lines are the whole document's tokens.
    private func presentIncrementally(_ composition: AIReviewComposition, currentID: Int?,
                                      replacing previous: AIReviewComposition, previousCurrentID: Int?,
                                      profile: ReadingProfile, theme: Theme) {
        let storage = textStorage
        let old = previous.string as NSString
        let new = composition.string as NSString
        let prefix = Self.commonPrefixLength(old, new)
        let suffix = Self.commonSuffixLength(old, new, limit: min(old.length, new.length) - prefix)
        let oldSpan = NSRange(location: prefix, length: old.length - prefix - suffix)
        let newSpan = NSRange(location: prefix, length: new.length - prefix - suffix)
        let delta = newSpan.length - oldSpan.length
        /// An index in the previous string, in the new one: inside the replaced span it goes to
        /// the span's start (a range's start) or end (a range's end).
        func mapped(_ range: NSRange) -> NSRange {
            func map(_ index: Int, isEnd: Bool) -> Int {
                if index <= oldSpan.location { return index }
                if index >= NSMaxRange(oldSpan) { return index + delta }
                return isEnd ? NSMaxRange(newSpan) : newSpan.location
            }
            let start = map(range.location, isEnd: false)
            return NSRange(location: start, length: max(0, map(NSMaxRange(range), isEnd: true) - start))
        }

        var regions: [NSRange] = []
        let textChanged = oldSpan.length > 0 || newSpan.length > 0
        if textChanged { regions.append(newSpan) }
        let ids = Set(previous.changeRanges.keys).union(previous.removedRanges.keys).union(previous.replacementRanges.keys)
            .union(composition.changeRanges.keys).union(composition.removedRanges.keys).union(composition.replacementRanges.keys)
        for id in ids {
            let newRanges = Self.ranges(of: id, in: composition)
            let touchesSpan = textChanged && newRanges.contains { NSIntersectionRange($0, newSpan).length > 0
                || NSLocationInRange(newSpan.location, $0) }
            guard touchesSpan || Self.look(of: id, in: previous, currentID: previousCurrentID)
                    != Self.look(of: id, in: composition, currentID: currentID) else { continue }
            regions += newRanges
            regions += Self.ranges(of: id, in: previous).map { mapped($0) }
        }

        // Whole lines, merged where they overlap.
        let lineScopes = regions
            .map { MarkdownTokenScope.scopedTokenRange(in: new, around: $0, margin: 0) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        var scopes: [NSRange] = []
        for scope in lineScopes {
            if let last = scopes.last, scope.location <= NSMaxRange(last) {
                scopes[scopes.count - 1] = NSUnionRange(last, scope)
            } else {
                scopes.append(scope)
            }
        }

        storage.beginEditing()
        if textChanged {
            storage.replaceCharacters(in: oldSpan, with: NSAttributedString(
                string: new.substring(with: newSpan), attributes: MarkdownTextStyle.baseAttributes(for: profile)))
        }
        for scope in scopes {
            MarkdownTokenStyler.applyTokens(to: storage, profile: profile, scope: scope)
            Self.applyReviewStyling(composition, currentID: currentID, theme: theme, to: storage, within: scope)
        }
        storage.endEditing()
    }

    /// UTF-16 units the two strings share at their start, compared a chunk at a time.
    static func commonPrefixLength(_ a: NSString, _ b: NSString) -> Int {
        let limit = min(a.length, b.length)
        let chunk = 4096
        var bufferA = [unichar](repeating: 0, count: chunk)
        var bufferB = [unichar](repeating: 0, count: chunk)
        var offset = 0
        while offset < limit {
            let count = min(chunk, limit - offset)
            a.getCharacters(&bufferA, range: NSRange(location: offset, length: count))
            b.getCharacters(&bufferB, range: NSRange(location: offset, length: count))
            for index in 0..<count where bufferA[index] != bufferB[index] { return offset + index }
            offset += count
        }
        return limit
    }

    /// UTF-16 units the two strings share at their end, at most `limit`.
    static func commonSuffixLength(_ a: NSString, _ b: NSString, limit: Int) -> Int {
        let chunk = 4096
        var bufferA = [unichar](repeating: 0, count: chunk)
        var bufferB = [unichar](repeating: 0, count: chunk)
        var matched = 0
        while matched < limit {
            let count = min(chunk, limit - matched)
            a.getCharacters(&bufferA, range: NSRange(location: a.length - matched - count, length: count))
            b.getCharacters(&bufferB, range: NSRange(location: b.length - matched - count, length: count))
            var index = count - 1
            while index >= 0 {
                if bufferA[index] != bufferB[index] { return matched + (count - 1 - index) }
                index -= 1
            }
            matched += count
        }
        return limit
    }

    /// Lays the overlay out exactly as `editor` is laid out.
    func matchGeometry(of editor: LineformTextView) {
        reviewState.editor = editor
        if textContainerInset != editor.textContainerInset { textContainerInset = editor.textContainerInset }
        if contentInset != editor.contentInset { contentInset = editor.contentInset }
        if textContainer.lineFragmentPadding != editor.textContainer.lineFragmentPadding {
            textContainer.lineFragmentPadding = editor.textContainer.lineFragmentPadding
        }
        backgroundColor = editor.backgroundColor
    }

    override func layoutSubviews() {
        // The editor's side insets follow its width (`EditorReadingLayout`); the overlay has the same.
        if let editor = reviewState.editor { matchGeometry(of: editor) }
        super.layoutSubviews()
    }

    /// Every drawn range of the current change: struck, replacements and the change itself.
    var currentChangeRanges: [NSRange] {
        guard let id = currentID else { return [] }
        return (composition.removedRanges[id] ?? []) + (composition.replacementRanges[id] ?? [])
            + (composition.changeRanges[id].map { [$0] } ?? [])
    }

    // MARK: - Read-only

    override var undoManager: UndoManager? { reviewState.emptyUndoManager }
    override var canBecomeFirstResponder: Bool { true }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    // MARK: - Keys

    private static let reviewKeyCommands: [UIKeyCommand] = {
        func command(_ input: String, _ action: Selector, _ title: String) -> UIKeyCommand {
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: [])
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return [
            command("\r", #selector(acceptKey(_:)), AIReviewCardsPresentation.accessibilityActionTitles()[0]),
            command(UIKeyCommand.inputEscape, #selector(rejectKey(_:)), AIReviewCardsPresentation.accessibilityActionTitles()[1]),
            command(UIKeyCommand.inputLeftArrow, #selector(previousKey(_:)), AIReviewCardsPresentation.accessibilityActionTitles()[5]),
            command(UIKeyCommand.inputRightArrow, #selector(nextKey(_:)), AIReviewCardsPresentation.accessibilityActionTitles()[4]),
        ]
    }()

    override var keyCommands: [UIKeyCommand]? { Self.reviewKeyCommands }

    @objc private func acceptKey(_ sender: Any?) { performReviewKey(.accept) }
    @objc private func rejectKey(_ sender: Any?) { performReviewKey(.reject) }
    @objc private func previousKey(_ sender: Any?) { performReviewKey(.previous) }
    @objc private func nextKey(_ sender: Any?) { performReviewKey(.next) }

    /// Return accepts the current change; Esc rejects it (a one-change review then ends, Proofread
    /// moves on); ← / → move between pending changes.
    func performReviewKey(_ key: ReviewKey) {
        switch key {
        case .accept: commandHandler?(.acceptCurrent)
        case .reject: commandHandler?(.rejectCurrent)
        case .previous: commandHandler?(.move(-1))
        case .next: commandHandler?(.move(1))
        }
    }

    /// A key that would type is refused, with the review's status said again. Arrows, Return and
    /// Esc are the key commands; shortcuts with ⌘ or ⌃ are left to the system.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let types = presses.compactMap(\.key).filter { key in
            key.modifierFlags.intersection([.command, .control]).isEmpty && !key.characters.isEmpty
                && !key.characters.unicodeScalars.contains { $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) }
        }
        if !types.isEmpty { refusalHandler?() }
        super.pressesBegan(presses, with: event)
    }

    // MARK: - Touch

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: inContainer, in: textContainer,
                                                 fractionOfDistanceBetweenInsertionPoints: &fraction)
        if let id = composition.changeID(at: index) { commandHandler?(.select(id)) }
    }

    // MARK: - Accessibility

    /// The CURRENT change in words ("Replace “X” with “Y”"), never the struck original and the
    /// replacement read as one run with nothing saying which is which.
    override var accessibilityValue: String? {
        get { Self.spokenChange(in: composition, currentID: currentID) ?? composition.string }
        set {}
    }

    /// The change VoiceOver speaks: `currentID`'s (or the only change's) struck text and its
    /// replacement, each part of a change joined by an ellipsis. Insert / Delete when one side is
    /// empty; nil when there is no change.
    static func spokenChange(in composition: AIReviewComposition, currentID: Int?) -> String? {
        let ids = Set(composition.changeRanges.keys).union(composition.removedRanges.keys)
            .union(composition.replacementRanges.keys)
        guard let id = currentID ?? (ids.count == 1 ? ids.first : nil) else { return nil }
        let ns = composition.string as NSString
        func text(_ ranges: [NSRange]?) -> String {
            (ranges ?? [])
                .map { NSIntersectionRange($0, NSRange(location: 0, length: ns.length)) }
                .filter { $0.length > 0 }
                .map { ns.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " … ")
        }
        let removed = text(composition.removedRanges[id])
        let inserted = text(composition.replacementRanges[id])
        switch (removed.isEmpty, inserted.isEmpty) {
        case (false, false): return String(localized: "Replace “\(removed)” with “\(inserted)”")
        case (true, false): return String(localized: "Insert “\(inserted)”")
        case (false, true): return String(localized: "Delete “\(removed)”")
        case (true, true): return nil
        }
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let titles = AIReviewCardsPresentation.accessibilityActionTitles()
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
                UIAccessibilityCustomAction(name: title) { [weak self] _ in
                    guard let handler = self?.commandHandler else { return false }
                    handler(command)
                    return true
                }
            }
        }
        set {}
    }

    /// VoiceOver's escape (two-finger scrub) ends the review, as Done on the card does.
    override func accessibilityPerformEscape() -> Bool {
        guard let handler = commandHandler else { return false }
        handler(.end)
        return true
    }

    // MARK: - Scroll hand-over by character

    /// The first character of the line at the top of `textView`'s visible area, and how far the
    /// visible top is below that line's top (NEGATIVE while the top inset still shows). Never a
    /// pixel y: past the first change the overlay is taller than the document.
    static func topAnchor(of textView: UITextView) -> (index: Int, offset: CGFloat)? {
        let layoutManager = textView.layoutManager
        guard textView.textStorage.length > 0 else { return nil }
        let visibleTop = textView.contentOffset.y + textView.adjustedContentInset.top - textView.textContainerInset.top
        let glyph = layoutManager.glyphIndex(for: CGPoint(x: 0, y: max(0, visibleTop)), in: textView.textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange()
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let offset = visibleTop < line.minY ? visibleTop - line.minY : max(0, visibleTop - line.minY)
        return (layoutManager.characterIndexForGlyph(at: lineGlyphs.location), offset)
    }

    /// Puts `index`'s line at the top of `textView`, `offset` into it, clamped to the scrollable range.
    static func scroll(_ textView: UITextView, showing index: Int, offset: CGFloat) {
        let storage = textView.textStorage
        guard storage.length > 0 else { return }
        let character = min(max(0, index), storage.length - 1)
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: character + 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = line.minY + min(offset, line.height) + textView.textContainerInset.top - textView.adjustedContentInset.top
        setOffset(textView, y: y)
    }

    private static func setOffset(_ textView: UITextView, y: CGFloat) {
        textView.layoutIfNeeded()
        let top = -textView.adjustedContentInset.top
        let maximum = max(top, textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        let clamped = min(max(top, y), maximum)
        if abs(textView.contentOffset.y - clamped) > 0.5 {
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: clamped), animated: false)
        }
    }

    /// Scrolls the least amount that shows the current change ABOVE the cards (`bottomObscured`
    /// covers the visible bottom). Nothing moves when it already shows. The Mac's
    /// `revealCurrentChange` / `revealOriginY`.
    func revealCurrentChange(bottomObscured: CGFloat, margin: CGFloat = 8) {
        let ranges = currentChangeRanges.filter { $0.length > 0 }
        guard let end = ranges.map(NSMaxRange).max(), bounds.height > 0 else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(end, textStorage.length)))
        var rect = CGRect.null
        for range in ranges {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            rect = rect.union(layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer))
        }
        guard !rect.isNull else { return }
        rect = rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
        let top = contentOffset.y + adjustedContentInset.top
        let bottom = contentOffset.y + bounds.height - max(adjustedContentInset.bottom, bottomObscured)
        if rect.minY >= top, rect.maxY <= bottom { return }
        let visibleTop: CGFloat
        if rect.minY < top {
            visibleTop = rect.minY - margin
        } else {
            visibleTop = min(top + (rect.maxY - bottom), rect.minY - margin)
        }
        Self.setOffset(self, y: visibleTop - adjustedContentInset.top)
    }
}

/// Hosts the review overlay over the editor (Write and Preview's top pane; Read allows no AI). On
/// make it takes the editor's scroll position BY CHARACTER and the keyboard focus; on dismantle it
/// hands both back: the editor scrolls to the overlay's top character and, if it held the
/// keyboard, becomes first responder again.
struct AIReviewOverlay: UIViewRepresentable {
    let composition: AIReviewComposition
    let currentID: Int?
    var pendingCount = 1
    let profile: ReadingProfile
    /// The editor underneath.
    let editor: LineformTextView?
    /// How much of the overlay's bottom the cards cover, measured when asked.
    var bottomObscured: (UIView) -> CGFloat = { _ in 0 }
    let onCommand: (AIReviewCommand) -> Void
    var onRefused: () -> Void = {}

    final class Coordinator {
        var presented: (AIReviewComposition, Int?, ReadingProfile)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AIReviewOverlayTextView {
        let view = AIReviewOverlayTextView.make()
        update(view, context: context)
        guard let editor else { return view }
        view.reviewState.editorHadFocus = editor.isFirstResponder
        let anchor = AIReviewOverlayTextView.topAnchor(of: editor)
        let bottomObscured = bottomObscured
        // Applied once SwiftUI has given the overlay its frame (the next turn), then again on the
        // one after, when the cards have been measured.
        let showAnchor = { [weak view] in
            guard let view, view.window != nil else { return }
            view.layoutIfNeeded()
            if let anchor {
                AIReviewOverlayTextView.scroll(view, showing: view.composition.overlayIndex(forDocumentIndex: anchor.index),
                                               offset: anchor.offset)
            }
            view.revealCurrentChange(bottomObscured: bottomObscured(view))
        }
        DispatchQueue.main.async { [weak view] in
            showAnchor()
            // The overlay holds the keyboard focus: the software keyboard goes down, and the
            // read-only editor underneath gets no keys.
            if let view, view.window != nil, !view.isFirstResponder { view.becomeFirstResponder() }
            // VoiceOver goes to the review: it hears "Suggested changes" and the change itself,
            // with Accept, Reject and the rest as its actions.
            if let view, view.window != nil, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .screenChanged, argument: view)
            }
            DispatchQueue.main.async { showAnchor() }
        }
        return view
    }

    func updateUIView(_ view: AIReviewOverlayTextView, context: Context) {
        let previousCurrent = context.coordinator.presented?.1
        let previousComposition = context.coordinator.presented?.0
        let hadPresented = context.coordinator.presented != nil
        update(view, context: context)
        if hadPresented, previousCurrent != currentID {
            view.revealCurrentChange(bottomObscured: bottomObscured(view))
        }
        // An accept, a reject or a move changed the current change: VoiceOver reads it again.
        if hadPresented, context.coordinator.presented?.0 != previousComposition || previousCurrent != currentID,
           UIAccessibility.isVoiceOverRunning, view.accessibilityElementIsFocused() {
            UIAccessibility.post(notification: .layoutChanged, argument: view)
        }
    }

    private func update(_ view: AIReviewOverlayTextView, context: Context) {
        view.commandHandler = { command in onCommand(command) }
        view.refusalHandler = { onRefused() }
        view.pendingCount = pendingCount
        if let editor { view.matchGeometry(of: editor) }
        let key = (composition, currentID, profile)
        if let presented = context.coordinator.presented, presented == key { return }
        context.coordinator.presented = key
        view.present(composition, currentID: currentID, profile: profile)
        if let editor { view.matchGeometry(of: editor) }
    }

    static func dismantleUIView(_ view: AIReviewOverlayTextView, coordinator: Coordinator) {
        view.commandHandler = nil
        view.refusalHandler = nil
        guard let editor = view.reviewState.editor else { return }
        // The overlay's top character, mapped back into the document. After an accept the text
        // after it moved; a top line before the last change is exact.
        if let anchor = AIReviewOverlayTextView.topAnchor(of: view) {
            AIReviewOverlayTextView.scroll(editor, showing: view.composition.documentIndex(forOverlayIndex: anchor.index),
                                           offset: anchor.offset)
        }
        if view.reviewState.editorHadFocus, editor.window != nil {
            // Taking the focus scrolls a text view to its caret, which is now at the change's end,
            // maybe far below: the position just handed back is held instead (the caret is placed
            // without scrolling).
            let restored = editor.contentOffset
            editor.becomeFirstResponder()
            holdOffset(restored, of: editor)
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    /// When the hand-over's position is re-asserted after the editor takes the focus: at once, and
    /// across the keyboard's arrival, unless the writer starts scrolling.
    static let offsetHoldDelays: [TimeInterval] = [0, 0.05, 0.15, 0.3, 0.5]

    /// Also the AI split's close, which hands the focus back the same way.
    static func holdOffset(_ offset: CGPoint, of editor: UIScrollView) {
        // Held as a distance below the top inset, not a raw offset: the inset moves while the
        // keyboard arrives (the safe area changes under it), and a raw offset re-asserted then
        // landed that much off the handed-back line.
        let belowTop = offset.y + editor.adjustedContentInset.top
        func reassert() {
            let top = -editor.adjustedContentInset.top
            let target = belowTop + top
            guard !editor.isTracking, !editor.isDecelerating,
                  abs(editor.contentOffset.y - target) > 0.5 else { return }
            let maximum = max(top, editor.contentSize.height + editor.adjustedContentInset.bottom - editor.bounds.height)
            editor.setContentOffset(CGPoint(x: editor.contentOffset.x, y: min(max(top, target), maximum)), animated: false)
        }
        reassert()
        for delay in offsetHoldDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak editor] in
                guard editor != nil else { return }
                reassert()
            }
        }
    }
}

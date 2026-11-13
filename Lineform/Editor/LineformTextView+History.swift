import AppKit

/// The focused passage's version counter, drawn after its last glyph: "current/total", e.g.
/// "2/3". `current` is zero-based.
struct HistoryCounter: Equatable {
    let count: Int
    let current: Int

    /// Numerals and a slash only — nothing to localize.
    var text: String { "\(current + 1)/\(count)" }
}

/// What History mode shows in the text view. `nil` on the view means normal writing, which draws
/// no history markers at all.
///
/// `hoveredID` is owned by the VIEW: it is set from the pointer (redraw only, no handler call).
/// The controller always passes `nil`, and the view keeps its own hover across those updates.
struct HistoryModeDisplay: Equatable {
    var passages: [LocatedPassage]
    var selectedID: UUID?
    var hoveredID: UUID?
    var counter: HistoryCounter?

    /// The innermost passage containing `characterIndex`: the shortest range, ties broken by the
    /// deeper level. This is what a click selects, so a word inside a changed sentence selects
    /// the word.
    func innermostPassage(containing characterIndex: Int) -> LocatedPassage? {
        passages
            .filter { NSLocationInRange(characterIndex, $0.range) }
            .min { lhs, rhs in
                if lhs.range.length != rhs.range.length {
                    return lhs.range.length < rhs.range.length
                }
                return lhs.level > rhs.level
            }
    }

    var selectedPassage: LocatedPassage? {
        guard let selectedID else { return nil }
        return passages.first { $0.id == selectedID }
    }
}

/// What the text view asks its controller to do while History is involved.
enum HistoryTextCommand: Equatable {
    /// "Add to History" from the context menu, for this selection.
    case add(NSRange)
    /// A click on a passage with history.
    case select(UUID)
    /// ← / → : step the selected passage's versions.
    case step(Int)
    /// ↑ / ↓ : the keyboard path between passages.
    case moveSelection(Int)
    /// Esc.
    case exit
    /// A keystroke edited the document while in History mode. Sent BEFORE the edit; the
    /// controller leaves History mode synchronously and the keystroke then types normally.
    case typedWhileInHistoryMode
}

/// VoiceOver text for the selected passage — announced, never set as the text view's AX value.
enum HistoryModeAnnouncement {
    static func text(level: HistoryLevel, counter: HistoryCounter?) -> String {
        guard let counter else { return level.title }
        let position = counter.current + 1
        let count = counter.count
        return String(localized: "\(level.title), version \(position) of \(count)")
    }
}

/// History mode's commands as accessibility custom actions on the text view, in rotor order. The
/// click and arrow-key paths are hit-tested; this is their mirror for assistive tech.
enum HistoryModeAccessibilityAction: CaseIterable {
    case nextPassage, previousPassage, previousVersion, nextVersion, exit

    var name: String {
        switch self {
        case .nextPassage: return String(localized: "Select Next Passage")
        case .previousPassage: return String(localized: "Select Previous Passage")
        case .previousVersion: return String(localized: "Previous Version")
        case .nextVersion: return String(localized: "Next Version")
        case .exit: return String(localized: "Exit History")
        }
    }

    var command: HistoryTextCommand {
        switch self {
        case .nextPassage: return .moveSelection(1)
        case .previousPassage: return .moveSelection(-1)
        case .previousVersion: return .step(-1)
        case .nextVersion: return .step(1)
        case .exit: return .exit
        }
    }
}

/// What the History controller drives in the editor. Implemented by `LineformTextView`.
@MainActor
protocol HistoryEditorSurface: AnyObject {
    var string: String { get }
    var historyDisplay: HistoryModeDisplay? { get set }
    var undoManager: UndoManager? { get }
    func applyHistoryEdit(_ edit: HistoryEdit)
    /// True when `collapse` was applied as an undoable edit. `beforeCollapse` runs, with undo
    /// registration enabled, immediately before the collapse is applied — in the same undo group,
    /// so whatever it registers is undone AFTER the collapse and redone BEFORE it.
    @discardableResult
    func applyHistoryExit(restoring entry: String, collapse: HistoryEdit?, expecting current: String,
                          beforeCollapse: () -> Void) -> Bool
}

extension LineformTextView: HistoryEditorSurface {}

extension LineformTextView {
    // MARK: - Display state

    func applyHistoryDisplay(_ newValue: HistoryModeDisplay?) {
        var incoming = newValue
        // Keep the view's own hover across controller updates, which always pass nil for it.
        if var display = incoming,
           display.hoveredID == nil,
           let hovered = historyDisplayStorage?.hoveredID,
           display.passages.contains(where: { $0.id == hovered }) {
            display.hoveredID = hovered
            incoming = display
        }

        guard incoming != historyDisplayStorage else { return }
        let previous = historyDisplayStorage
        historyDisplayStorage = incoming

        guard let incoming else {
            removeHistoryRecededInk()
            updateHistoryCounterSpacing(for: nil, anchoringAt: previous?.selectedPassage?.range.location)
            removeHistoryTrackingArea()
            updateInsertionPointStateAndRestartTimer(true)
            needsDisplay = true
            return
        }

        if previous == nil {
            // A selection carried in (⌘Z after a whole-text command selects the whole document)
            // would be REPLACED by the keystroke that leaves History mode. Collapse it; the
            // selection override keeps it collapsed for the whole mode.
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            updateInsertionPointStateAndRestartTimer(true)
        }
        if let selected = incoming.selectedPassage,
           previous?.selectedPassage?.id != selected.id || previous?.selectedPassage?.range != selected.range {
            // The hidden caret follows the selected passage, so leaving by typing inserts there.
            let end = min(NSMaxRange(selected.range), (string as NSString).length)
            setSelectedRange(NSRange(location: end, length: 0))
        }

        if previous?.passages != incoming.passages || previous == nil
            || previous?.selectedID != incoming.selectedID || previous?.hoveredID != incoming.hoveredID {
            refreshHistoryRecededInk()
        }
        if previous?.selectedPassage != incoming.selectedPassage || previous?.counter != incoming.counter {
            // Only the FOCUSED passage shows a counter, so entering History mode reflows nothing.
            updateHistoryCounterSpacing(for: incoming.counter == nil ? nil : incoming.selectedPassage,
                                        anchoringAt: incoming.selectedPassage?.range.location)
        }
        installHistoryTrackingAreaIfNeeded()

        if incoming.selectedID != nil,
           previous?.selectedID != incoming.selectedID || previous?.counter != incoming.counter {
            announceHistorySelection(incoming)
        }
        needsDisplay = true
    }

    /// Hover is a redraw, not a command: no handler call, no announcement. While a passage is
    /// focused, hover lifts another passage to the receded ink, so the ink is refreshed then.
    func setHistoryHoveredID(_ id: UUID?) {
        guard var display = historyDisplayStorage, display.hoveredID != id else { return }
        display.hoveredID = id
        historyDisplayStorage = display
        if display.selectedID != nil { refreshHistoryRecededInk() }
        needsDisplay = true
    }

    /// Runs an edit the HISTORY CONTROLLER applies (showing another version) without it being
    /// mistaken for the writer typing — which would leave History mode.
    func performHistoryEdit(_ body: () -> Void) {
        let wasApplying = isApplyingHistoryEdit
        isApplyingHistoryEdit = true
        defer { isApplyingHistoryEdit = wasApplying }
        body()
    }

    // MARK: - Receded ink

    /// History mode's inks, as layout-manager TEMPORARY `.foregroundColor` — the text storage
    /// (and so the file, the undo stack and the syntax highlighting) is never touched. Applied over
    /// the visible window (with the highlighter's margin) and re-applied when a scroll leaves it.
    ///
    /// Nothing focused: unchanged text receded, every passage full ink (on its tint).
    /// A passage focused: unchanged text DEEP receded; every other passage at the focus-other
    /// ink (the hovered one at the receded ink, so it reads as clickable); the focused passage
    /// — with anything nested inside it — full ink.
    func refreshHistoryRecededInk() {
        guard let layoutManager, let display = historyDisplayStorage else { return }
        let length = (string as NSString).length
        let fullRange = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        historyRecededInkRange = nil
        guard length > 0 else { return }

        let target = historyInkWindow() ?? fullRange
        let theme = Theme.theme(for: appliedReadingProfile)
        let focused = display.selectedPassage
        let gapInk = focused == nil ? HistoryPalette.recededInk(for: theme) : HistoryPalette.deepRecededInk(for: theme)
        for gap in Self.historyGaps(in: target, excluding: display.passages.map(\.range)) {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: gapInk, forCharacterRange: gap)
        }
        if let focused {
            let otherInk = HistoryPalette.focusOtherInk(for: theme)
            let hoverInk = HistoryPalette.recededInk(for: theme)
            // Outer first, so a nested passage's own ink wins over its parent's.
            for other in display.passages.sorted(by: { $0.range.length > $1.range.length }) where other.id != focused.id {
                let range = NSIntersectionRange(other.range, target)
                guard range.length > 0 else { continue }
                layoutManager.addTemporaryAttribute(.foregroundColor,
                                                    value: other.id == display.hoveredID ? hoverInk : otherInk,
                                                    forCharacterRange: range)
            }
            let range = NSIntersectionRange(focused.range, target)
            if range.length > 0 {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            }
        }
        historyRecededInkRange = target
    }

    /// Called on scroll. Cheap when the visible range is still inside the inked window.
    func refreshHistoryRecededInkAfterScrollIfNeeded() {
        guard historyDisplayStorage != nil else { return }
        if let inked = historyRecededInkRange,
           let visible = visibleCharacterRangeForLayoutPreservation(),
           visible.location >= inked.location,
           NSMaxRange(visible) <= NSMaxRange(inked) {
            return
        }
        refreshHistoryRecededInk()
    }

    func removeHistoryRecededInk() {
        guard let layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        historyRecededInkRange = nil
    }

    private func historyInkWindow() -> NSRange? {
        guard let visible = visibleCharacterRangeForLayoutPreservation() else { return nil }
        let length = (string as NSString).length
        let start = max(0, visible.location - Self.highlightMargin)
        let end = min(length, NSMaxRange(visible) + Self.highlightMargin)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// `target` minus every range in `excluded`, as ascending non-empty pieces.
    static func historyGaps(in target: NSRange, excluding excluded: [NSRange]) -> [NSRange] {
        let clipped = excluded
            .map { NSIntersectionRange($0, target) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        var gaps: [NSRange] = []
        var cursor = target.location
        for range in clipped {
            if range.location > cursor {
                gaps.append(NSRange(location: cursor, length: range.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(range))
        }
        if cursor < NSMaxRange(target) {
            gaps.append(NSRange(location: cursor, length: NSMaxRange(target) - cursor))
        }
        return gaps
    }

    // MARK: - Drawing

    /// Nothing focused: a translucent wash behind every visible passage, outer first (a nested
    /// passage reads as a deeper wash), and the hovered one drawn LAST and OPAQUE
    /// (`HistoryPalette.opaqueFill`) so it replaces the washes beneath. A passage focused: no
    /// fills at all — focus is carried by the inks — and the focused passage's counter.
    func drawHistoryIfNeeded() {
        guard let display = historyDisplayStorage else { return }
        let theme = Theme.theme(for: appliedReadingProfile)

        if let focused = display.selectedPassage {
            if let counter = display.counter { drawHistoryCounter(counter, after: focused.range, theme: theme) }
            return
        }

        let visible = visibleCharacterRangeForLayoutPreservation()
        func fill(_ passage: LocatedPassage, with color: NSColor) {
            let range = visible.map { NSIntersectionRange(passage.range, $0) } ?? passage.range
            guard range.length > 0 else { return }
            color.setFill()
            for rect in rectsForCharacterRange(range) {
                rect.fill(using: .sourceOver)
            }
        }
        let wash = HistoryPalette.tint(for: theme)
        for passage in display.passages
            .filter({ $0.id != display.hoveredID })
            .sorted(by: { $0.range.length > $1.range.length }) {
            fill(passage, with: wash)
        }
        if let hoveredID = display.hoveredID,
           let hovered = display.passages.first(where: { $0.id == hoveredID }) {
            fill(hovered, with: HistoryPalette.opaqueFill(HistoryPalette.hoverTint(for: theme), for: theme))
        }
    }

    private func drawHistoryCounter(_ counter: HistoryCounter, after range: NSRange, theme: Theme) {
        guard let frame = historyCounterFrame(for: range, counter: counter) else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: HistoryCounterLayout.font,
            .foregroundColor: HistoryPalette.counterInk(for: theme),
        ]
        (counter.text as NSString).draw(with: frame, options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    // MARK: - Counter

    /// The passage's last non-whitespace character: the counter goes after it.
    private func historyCounterAnchorCharacter(in range: NSRange) -> Int? {
        let ns = string as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return nil }
        var last = NSMaxRange(range) - 1
        while last > range.location,
              let scalar = Unicode.Scalar(ns.character(at: last)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            last -= 1
        }
        return last
    }

    /// Where the counter is drawn (view coordinates; the rect's top is the counter line's top):
    /// `HistoryCounterLayout.leadingGap` after the last glyph's NATURAL advance (its own kern
    /// included, the reserved space not), cap-aligned with the text. Nil when not laid out.
    func historyCounterFrame(for range: NSRange, counter: HistoryCounter) -> NSRect? {
        guard let layoutManager, let textStorage,
              let last = historyCounterAnchorCharacter(in: range) else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: last, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0, NSMaxRange(glyphs) <= layoutManager.numberOfGlyphs else { return nil }
        let glyph = NSMaxRange(glyphs) - 1
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        let textFont = (textStorage.attribute(.font, at: last, effectiveRange: nil) as? NSFont)
            ?? font ?? .systemFont(ofSize: CGFloat(appliedReadingProfile.fontSize))
        let advance = textFont.advancement(forCGGlyph: layoutManager.cgGlyph(at: glyph)).width
        let ownKern = HistoryCounterSpacing.originalKern(at: last, in: textStorage)
        let glyphEndX = textContainerOrigin.x + lineRect.minX + location.x + advance + ownKern
        let baselineY = textContainerOrigin.y + lineRect.minY + location.y
        let width = HistoryCounterLayout.width(of: counter.text)
        return NSRect(
            x: HistoryCounterLayout.originX(afterGlyphEndingAt: glyphEndX),
            y: HistoryCounterLayout.top(baselineY: baselineY, textCapHeight: textFont.capHeight),
            width: width,
            height: HistoryCounterLayout.font.ascender - HistoryCounterLayout.font.descender
        )
    }

    /// Reserves room for the focused passage's counter as extra KERN on its last character —
    /// layout only: attribute writes straight to the text storage (as the highlighter makes),
    /// never through `shouldChangeText`, with undo registration disabled. The string, the file,
    /// the dirty state and the undo stack are untouched, and the extra kern is removed exactly
    /// (`HistoryCounterSpacing`) when focus moves or History mode ends. The reflow keeps the
    /// focused passage's first line where it was on screen.
    func updateHistoryCounterSpacing(for passage: LocatedPassage?, anchoringAt anchor: Int?) {
        guard let textStorage else { return }
        let target: (index: Int, width: CGFloat)? = {
            guard let passage, let counter = historyDisplayStorage?.counter,
                  let last = historyCounterAnchorCharacter(in: passage.range) else { return nil }
            return (last, HistoryCounterLayout.reservedWidth(for: counter.text))
        }()
        guard HistoryCounterSpacing.needsUpdate(in: textStorage, target: target) else { return }
        let manager = undoManager
        manager?.disableUndoRegistration()
        defer { manager?.enableUndoRegistration() }
        preserveVisibleLayoutAnchorDuring(anchoringCharacterAt: anchor) {
            HistoryCounterSpacing.apply(target, in: textStorage)
        }
        needsDisplay = true
    }

    /// The highlighter resets attributes with `setAttributes`, which wipes the reserved space; it
    /// calls this after every pass so the focused passage's counter keeps its room.
    func reapplyHistoryCounterSpacingIfNeeded() {
        guard let display = historyDisplayStorage else { return }
        updateHistoryCounterSpacing(for: display.counter == nil ? nil : display.selectedPassage,
                                    anchoringAt: display.selectedPassage?.range.location)
    }

    // MARK: - Input

    /// A click in History mode selects the innermost passage under it and never moves the caret.
    /// A click on unchanged text does nothing (the selection stays). Returns true when History
    /// mode consumed the click.
    func handleHistoryMouseDown(_ event: NSEvent) -> Bool {
        // A Control-click is a right-click: let AppKit route it to the context menu.
        guard let display = historyDisplayStorage, !event.modifierFlags.contains(.control) else { return false }
        if let index = historyCharacterIndex(at: event),
           let passage = display.innermostPassage(containing: index) {
            historyCommandHandler?(.select(passage.id))
        }
        return true
    }

    func handleHistoryMouseMoved(_ event: NSEvent) {
        guard let display = historyDisplayStorage else { return }
        let hovered = historyCharacterIndex(at: event).flatMap { display.innermostPassage(containing: $0)?.id }
        setHistoryHoveredID(hovered)
    }

    /// Arrow keys and Esc in History mode. Hooked through `doCommand(by:)`, never `keyDown`
    /// (repo invariant: `keyDown` runs before input-method handling).
    func handleHistoryCommand(_ selector: Selector) -> Bool {
        guard historyDisplayStorage != nil else { return false }
        let command: HistoryTextCommand
        switch selector {
        case #selector(NSResponder.moveLeft(_:)):
            command = .step(-1)
        case #selector(NSResponder.moveRight(_:)):
            command = .step(1)
        case #selector(NSResponder.moveUp(_:)):
            command = .moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)):
            command = .moveSelection(1)
        case #selector(NSResponder.cancelOperation(_:)):
            command = .exit
        default:
            // Every other caret or selection move (shift/option/command arrows, Home/End, page
            // keys) is swallowed: History mode never moves the caret.
            let name = NSStringFromSelector(selector)
            return name.hasPrefix("move") || name.hasPrefix("page")
        }
        historyCommandHandler?(command)
        return true
    }

    /// True while History mode is on: the caret is hidden (the selection is the passage tint).
    var hidesInsertionPointForHistory: Bool { historyDisplayStorage != nil }

    /// History mode never holds a text selection: a requested non-empty selection is refused and
    /// the collapsed caret stays where it is. Nil outside History mode (select as usual).
    func historyClampedSelection(_ ranges: [NSValue]) -> [NSValue]? {
        guard historyDisplayStorage != nil else { return nil }
        if ranges.count == 1, let only = ranges.first, only.rangeValue.length == 0 { return nil }
        let caret = ranges.first.map { $0.rangeValue.length == 0 ? $0.rangeValue.location : selectedRange().location }
            ?? selectedRange().location
        return [NSValue(range: NSRange(location: caret, length: 0))]
    }

    /// Defence in depth for the exit-by-typing path: a user edit in History mode that would
    /// REPLACE a surviving SELECTION with new text is refused — History mode is left, the caret
    /// goes to the selection's end, and nothing is replaced. Only the stale selection itself:
    /// commands that replace a range on their own (formatting and heading keys, tables, Find &
    /// Replace, spelling corrections) leave History mode and apply as before.
    func refusesHistoryModeReplacement(_ range: NSRange, replacement: String?) -> Bool {
        guard historyDisplayStorage != nil, !isApplyingHistoryEdit, let replacement,
              !replacement.isEmpty, range.length > 0, range == selectedRange() else { return false }
        historyCommandHandler?(.typedWhileInHistoryMode)
        let end = min(NSMaxRange(range), (string as NSString).length)
        setSelectedRange(NSRange(location: end, length: 0))
        return true
    }

    /// Sent from `shouldChangeText` before a TEXT edit lands while in History mode.
    func noteHistoryTypingIfNeeded() {
        guard historyDisplayStorage != nil, !isApplyingHistoryEdit else { return }
        historyCommandHandler?(.typedWhileInHistoryMode)
    }

    /// Sent from `shouldChangeText` once AppKit allowed a text edit. History's own edits are
    /// skipped (the engine already moved its live ranges for them).
    ///
    /// Every edit is TRIMMED to its minimal changed span first (`HistoryUndoCollapse.unambiguousEdit`
    /// of the replaced text against the replacement). Formatting commands and Find & Replace
    /// replace the whole text, and NSTextView undoes and redoes those as one document-spanning
    /// `shouldChangeText` — reported untrimmed it straddled every passage and dropped them all.
    /// Trimmed, passages outside the change keep their live ranges. When repeated text lets the
    /// change sit at more than one offset, the trim reports the union of the placements
    /// (`HistoryUndoCollapse.unambiguousEdit`), so passages in that region are dropped rather
    /// than left reading a different, identical occurrence. Reads only the replaced range (empty
    /// while typing), never the document.
    func noteHistoryUserEditIfNeeded(_ range: NSRange, replacement: String) {
        guard !isApplyingHistoryEdit, let handler = historyUserEditHandler else { return }
        let length = (string as NSString).length
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= length else {
            handler(range, replacement)
            return
        }
        let replaced = range.length == 0 ? "" : (string as NSString).substring(with: range)
        guard let minimal = HistoryUndoCollapse.unambiguousEdit(from: replaced, to: replacement) else { return }
        handler(NSRange(location: range.location + minimal.range.location, length: minimal.range.length),
                minimal.replacement)
    }

    // MARK: - Applying History's edits

    /// Shows another version: one localized replace with undo registration DISABLED — the whole
    /// History-mode session becomes one undo step on exit (`applyHistoryExit`).
    func applyHistoryEdit(_ edit: HistoryEdit) {
        performHistoryEdit {
            let manager = undoManager
            manager?.disableUndoRegistration()
            defer { manager?.enableUndoRegistration() }
            replaceForHistory(edit.range, with: edit.replacement)
        }
    }

    /// Leaves History mode. When `collapse` is non-nil the session changed the text: restore the
    /// entry text with registration disabled, then apply `collapse` (entry → exit) through the
    /// normal undoable path, so one ⌘Z after leaving restores the entry text exactly. Skipped
    /// when this view no longer shows the text History mode left (`expecting`) — it then belongs
    /// to another document and must not be touched.
    @discardableResult
    func applyHistoryExit(restoring entry: String, collapse: HistoryEdit?, expecting current: String,
                          beforeCollapse: () -> Void = {}) -> Bool {
        historyDisplay = nil
        guard let collapse, string == current else { return false }
        performHistoryEdit {
            if let restore = HistoryUndoCollapse.minimalEdit(from: current, to: entry) {
                let manager = undoManager
                manager?.disableUndoRegistration()
                replaceForHistory(restore.range, with: restore.replacement)
                manager?.enableUndoRegistration()
            }
            breakUndoCoalescing()
            beforeCollapse()
            replaceForHistory(collapse.range, with: collapse.replacement)
            breakUndoCoalescing()
        }
        return true
    }

    /// The localized `shouldChangeText → replaceCharacters → didChangeText` path — never
    /// `applyWholeTextReplacement`. Line endings and a BOM outside `range` are untouched.
    private func replaceForHistory(_ range: NSRange, with replacement: String) {
        let length = (string as NSString).length
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= length,
              shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
    }

    /// The character under the pointer, or nil when the pointer is not over a glyph (past a
    /// line's end, in the margin) — so hovering empty space never lights a passage.
    private func historyCharacterIndex(at event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let length = (string as NSString).length
        guard length > 0 else { return nil }

        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.contains(point) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return characterIndex < length ? characterIndex : nil
    }

    // MARK: - Hover tracking

    private func installHistoryTrackingAreaIfNeeded() {
        guard historyTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        historyTrackingArea = area
    }

    private func removeHistoryTrackingArea() {
        guard let area = historyTrackingArea else { return }
        removeTrackingArea(area)
        historyTrackingArea = nil
    }

    // MARK: - Context menu

    /// "Add to History" for a non-empty selection the controller accepts. `historyCanAddHandler`
    /// is an O(document) engine call, so it is asked HERE — when the menu is built — and never on
    /// selection change or per keystroke.
    func addHistoryItemIfAllowed(to menu: NSMenu) {
        let selection = selectedRange()
        guard selection.length > 0, historyCanAddHandler?(selection) == true else { return }
        menu.addItem(.separator())
        let item = NSMenuItem(
            title: LineformTextContextMenuPresentation.addToHistoryTitle,
            action: #selector(addSelectionToHistory(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = NSValue(range: selection)
        menu.addItem(item)
    }

    @objc func addSelectionToHistory(_ sender: Any?) {
        let range = ((sender as? NSMenuItem)?.representedObject as? NSValue)?.rangeValue ?? selectedRange()
        guard range.length > 0 else { return }
        historyCommandHandler?(.add(range))
    }

    // MARK: - Accessibility

    func historyAccessibilityCustomActions() -> [NSAccessibilityCustomAction] {
        HistoryModeAccessibilityAction.allCases.map { action in
            NSAccessibilityCustomAction(name: action.name) { [weak self] in
                guard let self, self.historyDisplayStorage != nil, let handler = self.historyCommandHandler else { return false }
                handler(action.command)
                return true
            }
        }
    }

    private func announceHistorySelection(_ display: HistoryModeDisplay) {
        guard let passage = display.selectedPassage else { return }
        let text = HistoryModeAnnouncement.text(level: passage.level, counter: display.counter)
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}


/// The counter's geometry, pure so it is pinned by tests: 10pt medium, tabular numerals, top-
/// aligned to the text's cap height, `leadingGap` after the last glyph, `trailingGap` before
/// whatever follows on the line.
enum HistoryCounterLayout {
    static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium) }
    static let leadingGap: CGFloat = 3
    static let trailingGap: CGFloat = 2

    static func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The extra advance reserved after the last glyph: the counter can never reach the next glyph.
    static func reservedWidth(for text: String) -> CGFloat {
        leadingGap + width(of: text) + trailingGap
    }

    static func originX(afterGlyphEndingAt glyphEndX: CGFloat) -> CGFloat {
        glyphEndX + leadingGap
    }

    /// The top of the counter's line box (flipped) so its cap height starts where the text's does.
    static func top(baselineY: CGFloat, textCapHeight: CGFloat) -> CGFloat {
        baselineY - textCapHeight - (font.ascender - font.capHeight)
    }
}

/// The reserved counter space as storage attributes: extra `.kern` on one character, marked with
/// `marker` holding the kern it replaced and the kern written, so it is removed EXACTLY — and so a
/// highlighter pass that rewrote the attributes (marker gone, or kern no longer ours) is detected.
enum HistoryCounterSpacing {
    static let marker = NSAttributedString.Key("LineformHistoryCounterSpacing")

    private struct Record {
        let original: CGFloat?
        let applied: CGFloat
    }

    private static func record(at index: Int, in storage: NSTextStorage) -> Record? {
        guard let value = storage.attribute(marker, at: index, effectiveRange: nil) as? [String: Any],
              let applied = value["applied"] as? CGFloat else { return nil }
        return Record(original: value["original"] as? CGFloat, applied: applied)
    }

    private static func kern(at index: Int, in storage: NSTextStorage) -> CGFloat? {
        (storage.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    /// The character's kern without any reserved space.
    static func originalKern(at index: Int, in storage: NSTextStorage) -> CGFloat {
        guard index < storage.length else { return 0 }
        if let record = record(at: index, in: storage), kern(at: index, in: storage) == record.applied {
            return record.original ?? 0
        }
        return kern(at: index, in: storage) ?? 0
    }

    /// Every character that carries live reserved space (marker present and the kern still ours).
    static func spacedCharacters(in storage: NSTextStorage) -> [Int] {
        var found: [Int] = []
        storage.enumerateAttribute(marker, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            for index in range.location..<NSMaxRange(range) { found.append(index) }
        }
        return found
    }

    static func needsUpdate(in storage: NSTextStorage, target: (index: Int, width: CGFloat)?) -> Bool {
        let spaced = spacedCharacters(in: storage)
        guard let target else { return !spaced.isEmpty }
        guard spaced == [target.index], let record = record(at: target.index, in: storage) else { return true }
        return kern(at: target.index, in: storage) != record.applied
            || record.applied != (record.original ?? 0) + target.width
    }

    /// Removes every reserved space, then reserves `target`'s. One editing batch.
    static func apply(_ target: (index: Int, width: CGFloat)?, in storage: NSTextStorage) {
        storage.beginEditing()
        defer { storage.endEditing() }
        for index in spacedCharacters(in: storage) {
            let range = NSRange(location: index, length: 1)
            if let record = record(at: index, in: storage), kern(at: index, in: storage) == record.applied {
                if let original = record.original {
                    storage.addAttribute(.kern, value: original, range: range)
                } else {
                    storage.removeAttribute(.kern, range: range)
                }
            }
            // Kern no longer ours (a highlighter pass rewrote it): leave it, drop the marker.
            storage.removeAttribute(marker, range: range)
        }
        guard let target, target.index < storage.length else { return }
        let range = NSRange(location: target.index, length: 1)
        let original = kern(at: target.index, in: storage)
        let applied = (original ?? 0) + target.width
        storage.addAttribute(.kern, value: applied, range: range)
        var value: [String: Any] = ["applied": applied]
        if let original { value["original"] = original }
        storage.addAttribute(marker, value: value, range: range)
    }
}

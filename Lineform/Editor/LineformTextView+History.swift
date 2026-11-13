import AppKit

/// The version dots drawn under the selected passage's first glyph: `count` circles, `current`
/// (zero-based) filled.
struct HistoryDots: Equatable {
    let count: Int
    let current: Int
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
    var dots: HistoryDots?

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
    static func text(level: HistoryLevel, dots: HistoryDots?) -> String {
        guard let dots else { return level.title }
        let position = dots.current + 1
        let count = dots.count
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
    static let historyDotGap: CGFloat = 3
    static let historyDotStrokeWidth: CGFloat = 0.75

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

        if previous?.passages != incoming.passages || previous == nil {
            refreshHistoryRecededInk()
        }
        installHistoryTrackingAreaIfNeeded()

        if incoming.selectedID != nil,
           previous?.selectedID != incoming.selectedID || previous?.dots != incoming.dots {
            announceHistorySelection(incoming)
        }
        needsDisplay = true
    }

    /// Hover is a redraw, not a command: no handler call, no ink refresh, no announcement.
    func setHistoryHoveredID(_ id: UUID?) {
        guard var display = historyDisplayStorage, display.hoveredID != id else { return }
        display.hoveredID = id
        historyDisplayStorage = display
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

    /// Unchanged text is drawn with the receded ink through a layout-manager TEMPORARY
    /// `.foregroundColor` — the text storage (and so the file, the undo stack and the syntax
    /// highlighting) is never touched. Applied over the visible window (with the highlighter's
    /// margin) minus the passages, and re-applied when a scroll leaves that window.
    func refreshHistoryRecededInk() {
        guard let layoutManager, let display = historyDisplayStorage else { return }
        let length = (string as NSString).length
        let fullRange = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        historyRecededInkRange = nil
        guard length > 0 else { return }

        let target = historyInkWindow() ?? fullRange
        let ink = HistoryPalette.recededInk(for: Theme.theme(for: appliedReadingProfile))
        for gap in Self.historyGaps(in: target, excluding: display.passages.map(\.range)) {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: ink, forCharacterRange: gap)
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

    /// Tints behind every visible passage, then the version dots under the selected one.
    ///
    /// Plain passages get a translucent wash, outer first, so a nested passage reads as a deeper
    /// wash. The hovered and then the selected passage are drawn LAST and OPAQUE
    /// (`HistoryPalette.opaqueFill`), replacing the washes beneath — stacking a translucent blue
    /// on nested washes fell below 4.5:1 on Quiet. Selected wins over hovered.
    func drawHistoryIfNeeded() {
        guard let display = historyDisplayStorage else { return }
        let theme = Theme.theme(for: appliedReadingProfile)
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
        let plain = display.passages
            .filter { $0.id != display.selectedID && $0.id != display.hoveredID }
            .sorted { $0.range.length > $1.range.length }
        for passage in plain {
            fill(passage, with: wash)
        }
        if let hoveredID = display.hoveredID, hoveredID != display.selectedID,
           let hovered = display.passages.first(where: { $0.id == hoveredID }) {
            fill(hovered, with: HistoryPalette.opaqueFill(HistoryPalette.hoverTint(for: theme), for: theme))
        }
        if let selected = display.selectedPassage {
            fill(selected, with: HistoryPalette.opaqueFill(HistoryPalette.selectionTint(for: theme), for: theme))
        }

        if let selected = display.selectedPassage, let dots = display.dots, dots.count > 0 {
            drawHistoryDots(dots, at: selected.range, theme: theme)
        }
    }

    private func drawHistoryDots(_ dots: HistoryDots, at range: NSRange, theme: Theme) {
        guard let placement = historyDotsPlacement(for: range) else { return }
        let diameter = placement.diameter
        let ink = HistoryPalette.dotInk(for: theme)
        for index in 0..<dots.count {
            let rect = NSRect(
                x: placement.origin.x + CGFloat(index) * (diameter + Self.historyDotGap),
                y: placement.origin.y,
                width: diameter,
                height: diameter
            )
            if index == dots.current {
                ink.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                let inset = Self.historyDotStrokeWidth / 2
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
                path.lineWidth = Self.historyDotStrokeWidth
                ink.setStroke()
                path.stroke()
            }
        }
    }

    /// The dots under the passage's FIRST glyph: the first dot's top-left corner and the dot
    /// diameter (`HistoryDotPlacement.place`). Nil when the passage has no laid-out glyph.
    func historyDotsPlacement(for range: NSRange) -> (origin: NSPoint, diameter: CGFloat)? {
        let ns = string as NSString
        guard let layoutManager, range.length > 0, range.location < ns.length else { return nil }
        func fontAt(_ index: Int) -> NSFont {
            (textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
                ?? font ?? .systemFont(ofSize: CGFloat(appliedReadingProfile.fontSize))
        }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: range.location)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphs)
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        let firstFont = fontAt(range.location)
        let baselineY = textContainerOrigin.y + lineRect.minY + glyphLocation.y

        // The next line's ascender top, from its real layout when there is one.
        let nextLineTopY: CGFloat
        let nextGlyph = NSMaxRange(lineGlyphs)
        if nextGlyph < layoutManager.numberOfGlyphs {
            let nextRect = layoutManager.lineFragmentRect(forGlyphAt: nextGlyph, effectiveRange: nil)
            let nextLocation = layoutManager.location(forGlyphAt: nextGlyph)
            let nextFont = fontAt(min(layoutManager.characterIndexForGlyph(at: nextGlyph), ns.length - 1))
            nextLineTopY = textContainerOrigin.y + nextRect.minY + nextLocation.y - nextFont.ascender
        } else {
            nextLineTopY = textContainerOrigin.y + lineRect.maxY + glyphLocation.y - firstFont.ascender
        }

        let placed = HistoryDotPlacement.place(baselineY: baselineY, fontSize: firstFont.pointSize,
                                               nextLineTopY: nextLineTopY)
        let left = textContainerOrigin.x + lineRect.minX + glyphLocation.x
        return (NSPoint(x: left, y: placed.top), placed.diameter)
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
        let text = HistoryModeAnnouncement.text(level: passage.level, dots: display.dots)
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


/// Where the version dots go, in flipped view coordinates (y grows down). Pure, so the geometry is
/// pinned by tests rather than eyeballed. Always under the passage's FIRST glyph — never at the
/// passage's end (tried and rejected by the owner, 2026-11-12: confusing).
enum HistoryDotPlacement {
    /// As in the approved mockup (`top: 1.32em` on the first word): the dots' top edge sits this
    /// share of the font size below the baseline, hugging the first line just under its
    /// descenders and leaving the rest of the line gap open above the next line.
    static let baselineOffsetRatio: CGFloat = 0.32
    static let diameter: CGFloat = 5
    /// Used when the regular dots would come within `minimumNextLineClearance` of the next
    /// line's ascender (very tight line heights). They still hug the first line.
    static let compactDiameter: CGFloat = 4
    static let minimumNextLineClearance: CGFloat = 1

    static func place(baselineY: CGFloat, fontSize: CGFloat, nextLineTopY: CGFloat) -> (top: CGFloat, diameter: CGFloat) {
        let top = baselineY + baselineOffsetRatio * fontSize
        let fits = top + diameter <= nextLineTopY - minimumNextLineClearance
        return (top, fits ? diameter : compactDiameter)
    }
}

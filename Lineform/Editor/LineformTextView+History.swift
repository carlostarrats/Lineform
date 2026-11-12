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

extension LineformTextView {
    static let historyDotDiameter: CGFloat = 5
    static let historyDotGap: CGFloat = 3
    static let historyDotStrokeWidth: CGFloat = 0.75
    /// The dots' top edge sits this share of a line height below the baseline — clear of
    /// descenders, so they never crowd the text.
    static let historyDotBaselineOffsetRatio: CGFloat = 0.32

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
            needsDisplay = true
            return
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
        guard
            let layoutManager,
            range.length > 0,
            range.location < (string as NSString).length
        else {
            return
        }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: range.location)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return }
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        let lineHeight = layoutManager.defaultLineHeight(
            for: font ?? .systemFont(ofSize: CGFloat(appliedReadingProfile.fontSize))
        )
        let baselineY = textContainerOrigin.y + lineRect.minY + glyphLocation.y
        let top = baselineY + Self.historyDotBaselineOffsetRatio * lineHeight
        let left = textContainerOrigin.x + lineRect.minX + glyphLocation.x

        let ink = HistoryPalette.dotInk(for: theme)
        for index in 0..<dots.count {
            let rect = NSRect(
                x: left + CGFloat(index) * (Self.historyDotDiameter + Self.historyDotGap),
                y: top,
                width: Self.historyDotDiameter,
                height: Self.historyDotDiameter
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
            return false
        }
        historyCommandHandler?(command)
        return true
    }

    /// Sent from `shouldChangeText` before an edit lands while in History mode.
    func noteHistoryTypingIfNeeded() {
        guard historyDisplayStorage != nil, !isApplyingHistoryEdit else { return }
        historyCommandHandler?(.typedWhileInHistoryMode)
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

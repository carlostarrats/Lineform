import AppKit
import SwiftUI
import LineformCore

/// Owns the selection toolbar for one text view (`SelectionToolbar.swift`).
@MainActor
final class SelectionToolbarController {
    let model = SelectionToolbarModel()
    lazy var hostingView: SelectionToolbarHostingView = {
        let view = SelectionToolbarHostingView(rootView: SelectionToolbarRoot(model: model))
        // Measured through `intrinsicContentSize`; the frame is still set by hand (no constraints
        // against the text view).
        view.sizingOptions = [.intrinsicContentSize]
        return view
    }()
    /// The selection the bar was shown for; the comment card sends against exactly this range.
    var anchorRange: NSRange?
    /// The range drawn with the active selection colour while the comment card holds focus.
    var heldHighlightRange: NSRange?
    /// Set while the toolbar itself moves the selection (opening / closing the comment card).
    var isAdjustingSelection = false
    var isVisible: Bool { hostingView.superview != nil }
    var hasPendingUpdate = false
    /// Whether the card sits above its selection (it grows upward when it turns into the comment
    /// card, so it never covers the passage) or below it.
    var placedAbove = true
    /// Screen-space pointer and frame origin when a drag began.
    var dragStart: (mouse: NSPoint, origin: NSPoint)?
    /// The comment card is for the whole document (Edit ▸ Ask AI… with nothing selected):
    /// `anchorRange` is the whole text, Send runs `.runWholeDocument`, and Esc puts back the
    /// caret it was opened at (`wholeDocumentCaret`) rather than selecting everything.
    var isWholeDocument = false
    var wholeDocumentCaret: NSRange?
}

extension LineformTextView {
    var selectionToolbar: SelectionToolbarController {
        if let existing = selectionToolbarStorage { return existing }
        let controller = SelectionToolbarController()
        let model = controller.model
        model.onCommand = { [weak self] selector in self?.performSelectionToolbarCommand(selector) }
        model.onMenu = { [weak self] menu in self?.popUpSelectionToolbarMenu(menu) }
        model.onOpenComment = { [weak self] in self?.openSelectionToolbarComment() }
        model.onSend = { [weak self] in self?.sendSelectionToolbarComment() }
        model.onClose = { [weak self] in self?.closeSelectionToolbarComment() }
        model.onDrag = { [weak self] translation, ended in self?.dragSelectionToolbar(translation: translation, ended: ended) }
        controller.hostingView.onSizeChange = { [weak self] in self?.selectionToolbarContentSizeChanged() }
        selectionToolbarStorage = controller
        return controller
    }

    var isSelectionToolbarVisible: Bool { selectionToolbarStorage?.isVisible == true }

    // MARK: - When it shows

    /// From `setSelectedRanges`. Mid-drag the bar hides; once the selection settles it shows —
    /// but only for a selection the WRITER made here (a click or drag in this view, or a key while
    /// this view is first responder). Programmatic selections — Find, an outline jump, undo —
    /// never summon it.
    func selectionToolbarSelectionDidChange(stillSelecting: Bool) {
        guard selectionToolbarStorage?.isAdjustingSelection != true else { return }
        guard selectionToolbarStorage != nil || selectedRange().length > 0 else { return }
        if stillSelecting {
            hideSelectionToolbar()
            return
        }
        guard selectedRange().length > 0 else {
            hideSelectionToolbar()
            return
        }
        guard isUserSelectionEvent(NSApp.currentEvent) else {
            // A programmatic change of the selection the bar was shown for: it no longer belongs.
            if selectionToolbarStorage?.anchorRange != selectedRange() { hideSelectionToolbar() }
            return
        }
        scheduleSelectionToolbarUpdate()
    }

    private func isUserSelectionEvent(_ event: NSEvent?) -> Bool {
        guard let event, let window, event.window === window else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return visibleRect.contains(convert(event.locationInWindow, from: nil))
        case .keyDown:
            return window.firstResponder === self
        default:
            return false
        }
    }

    private func scheduleSelectionToolbarUpdate() {
        let controller = selectionToolbar
        guard !controller.hasPendingUpdate else { return }
        controller.hasPendingUpdate = true
        // Coalesces a burst (shift-arrow repeat, a formatting command's own selection changes).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectionToolbar.hasPendingUpdate = false
            self.showSelectionToolbarForCurrentSelection()
        }
    }

    private var allowsSelectionToolbar: Bool {
        window != nil && isEditable && historyDisplay == nil && !isAIRequestRunning && !isAIReviewActive
            && aiMarkRangesStorage.isEmpty && !hasMarkedText()
    }

    private func showSelectionToolbarForCurrentSelection() {
        let range = selectedRange()
        guard range.length > 0, allowsSelectionToolbar else {
            hideSelectionToolbar()
            return
        }
        let controller = selectionToolbar
        let model = controller.model
        let provider = aiCommandHandler == nil ? nil : AIConnectionStore.shared.connectedProvider
        let aiName = provider.map { SelectionToolbarPresentation.aiName(for: $0) }
        let showsFormatting = textFormat == .markdown
        guard showsFormatting || aiName != nil else {
            hideSelectionToolbar()
            return
        }
        if controller.anchorRange == range, controller.isVisible {
            // Same selection: the card stays exactly where it is.
            return
        }
        controller.anchorRange = range
        model.mode = .toolbar
        model.aiName = aiName
        model.showsFormatting = showsFormatting
        model.usesDarkChrome = Theme.theme(for: appliedReadingProfile).usesDarkChrome
        if !controller.isVisible {
            addSubview(controller.hostingView)
        }
        positionSelectionToolbar()
    }

    func hideSelectionToolbar() {
        guard let controller = selectionToolbarStorage else { return }
        let hadFocus = controller.isVisible && window?.firstResponder is NSView
            && (window?.firstResponder as? NSView)?.isDescendant(of: controller.hostingView) == true
        controller.hostingView.removeFromSuperview()
        controller.hostingView.pinnedTop = nil
        controller.hostingView.alphaValue = 1
        controller.dragStart = nil
        releaseCommentHighlight()
        controller.anchorRange = nil
        controller.isWholeDocument = false
        controller.model.isWholeDocument = false
        controller.wholeDocumentCaret = nil
        controller.model.mode = .toolbar
        if hadFocus { window?.makeFirstResponder(self) }
    }

    /// A theme change re-inks the card. It never moves it: once placed (or dragged), the card
    /// stays put — a subview of the text view, it scrolls with its passage.
    func refreshSelectionToolbarIfVisible() {
        guard let controller = selectionToolbarStorage, controller.isVisible else { return }
        let dark = Theme.theme(for: appliedReadingProfile).usesDarkChrome
        if controller.model.usesDarkChrome != dark { controller.model.usesDarkChrome = dark }
    }

    private func positionSelectionToolbar() {
        guard let controller = selectionToolbarStorage, let range = controller.anchorRange,
              let layoutManager, let textContainer else { return }
        let hosting = controller.hostingView
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.intrinsicContentSize
        guard size.width > 0, size.height > 0 else {
            // Not measured yet (first frame of a new mode): try again on the next pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionToolbarStorage?.isVisible == true,
                      self.selectionToolbarStorage?.hostingView.intrinsicContentSize.width ?? 0 > 0 else { return }
                self.positionSelectionToolbar()
            }
            return
        }
        let length = (string as NSString).length
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        let glyphs = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return hideSelectionToolbar() }
        let origin = textContainerOrigin
        func lineRect(at glyph: Int) -> NSRect {
            var lineGlyphs = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            let rect = layoutManager.boundingRect(forGlyphRange: NSIntersectionRange(glyphs, lineGlyphs), in: textContainer)
            return rect.offsetBy(dx: origin.x, dy: origin.y)
        }
        let inset = SelectionToolbarHostingView.shadowInset
        let first = lineRect(at: glyphs.location)
        let visible = visibleRect
        let cardSize = NSSize(width: size.width - inset * 2, height: size.height - inset * 2)
        // The last line is only needed when the bar cannot sit above the first (a large
        // selection's last line forces layout of everything between).
        let needsBelow = first.minY - 8 - cardSize.height < visible.minY + 8
        let last = needsBelow ? lineRect(at: NSMaxRange(glyphs) - 1) : first
        let cardOrigin = SelectionToolbarPresentation.origin(barSize: cardSize, firstLine: first,
                                                              lastLine: last, visible: visible)
        controller.placedAbove = cardOrigin.y + cardSize.height <= first.minY
        hosting.move(to: NSRect(x: cardOrigin.x - inset, y: cardOrigin.y - inset,
                                width: size.width, height: size.height))
    }

    // MARK: - Commands

    /// Runs a formatting command with the bar held still: the command rewrites the text and
    /// moves the selection programmatically (sometimes through an empty selection), which used to
    /// hide and re-show the bar — a visible flash — and re-place it over the new text. Now the bar
    /// only adopts the resulting selection as its own.
    private func performSelectionToolbarCommand(_ selector: Selector) {
        guard let controller = selectionToolbarStorage else { return }
        window?.makeFirstResponder(self)
        controller.isAdjustingSelection = true
        NSApp.sendAction(selector, to: self, from: nil)
        controller.isAdjustingSelection = false
        let range = selectedRange()
        if range.length > 0 {
            controller.anchorRange = range
        } else {
            hideSelectionToolbar()
        }
    }

    /// Dragging the card by any part that is not a control. Tracked in SCREEN space from where
    /// the drag began (the view moves under the pointer, so its own coordinates would drift),
    /// kept inside the text view.
    private func dragSelectionToolbar(translation: CGSize, ended: Bool) {
        guard let controller = selectionToolbarStorage, controller.isVisible else { return }
        let hosting = controller.hostingView
        let mouse = NSEvent.mouseLocation
        if controller.dragStart == nil {
            // Where the press was, in screen space (SwiftUI's translation grows downward).
            controller.dragStart = (NSPoint(x: mouse.x - translation.width, y: mouse.y + translation.height),
                                    hosting.frame.origin)
        }
        guard let start = controller.dragStart else { return }
        // The release lands the card where the pointer is, then the drag is over.
        defer { if ended { controller.dragStart = nil } }
        // The text view is flipped: screen y grows up, the view's y grows down.
        var origin = NSPoint(x: start.origin.x + (mouse.x - start.mouse.x),
                             y: start.origin.y - (mouse.y - start.mouse.y))
        let inset = SelectionToolbarHostingView.shadowInset
        origin.x = min(max(origin.x, bounds.minX - inset), bounds.maxX - hosting.frame.width + inset)
        origin.y = min(max(origin.y, bounds.minY - inset), bounds.maxY - hosting.frame.height + inset)
        hosting.move(to: NSRect(origin: origin, size: hosting.frame.size))
    }

    private func popUpSelectionToolbarMenu(_ kind: SelectionToolbarMenu) {
        guard let controller = selectionToolbarStorage, controller.isVisible else { return }
        let model = controller.model
        let menu = NSMenu()
        // Keeps `MainMenuIconDecorator` off it, like the context menu.
        menu.identifier = MainMenuIconDecorator.excludedMenuIdentifier
        menu.autoenablesItems = false
        let anchor: CGRect
        switch kind {
        case .heading:
            anchor = model.headingButtonFrame
            let groups: [[(String, Selector, String)]] = [
                [(String(localized: "Title"), #selector(toggleTitleMarkdown(_:)), "1"),
                 (String(localized: "Section"), #selector(toggleSectionMarkdown(_:)), "2")],
                [(String(localized: "Heading 3"), #selector(toggleHeading3Markdown(_:)), "3"),
                 (String(localized: "Heading 4"), #selector(toggleHeading4Markdown(_:)), "4"),
                 (String(localized: "Heading 5"), #selector(toggleHeading5Markdown(_:)), "5"),
                 (String(localized: "Heading 6"), #selector(toggleHeading6Markdown(_:)), "6")],
                [(String(localized: "Body"), #selector(toggleBodyMarkdown(_:)), "0")],
            ]
            addCommandGroups(groups, modifiers: .command, to: menu)
        case .list:
            anchor = model.listButtonFrame
            addCommandGroups([
                [(String(localized: "Bulleted List"), #selector(toggleUnorderedListMarkdown(_:)), "8"),
                 (String(localized: "Numbered List"), #selector(toggleOrderedListMarkdown(_:)), "7")],
            ], modifiers: [.command, .shift], to: menu)
            menu.addItem(.separator())
            menu.addItem(selectionToolbarCommandItem(String(localized: "Blockquote"),
                                                    #selector(toggleBlockquoteMarkdown(_:)), key: "", modifiers: []))
        case .action:
            anchor = model.actionButtonFrame
            let range = controller.anchorRange ?? selectedRange()
            let text = string
            let selected = (text as NSString).substring(with: NSIntersectionRange(range, NSRange(location: 0, length: (text as NSString).length)))
            let groups = SelectionToolbarPresentation.actionGroups(
                selectedText: selected,
                sentenceCount: { AISentenceSplitter.sentences(in: text, selection: range).count }
            )
            for (index, group) in groups.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                for action in group {
                    let item = NSMenuItem(title: SelectionToolbarPresentation.menuTitle(for: action),
                                          action: #selector(selectSelectionToolbarAction(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = action
                    item.state = action == model.action ? .on : .off
                    menu.addItem(item)
                }
            }
        }
        let hosting = controller.hostingView
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.maxY + 4), in: hosting)
    }

    private func addCommandGroups(_ groups: [[(String, Selector, String)]], modifiers: NSEvent.ModifierFlags,
                                  to menu: NSMenu) {
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for (title, selector, key) in group {
                menu.addItem(selectionToolbarCommandItem(title, selector, key: key, modifiers: modifiers))
            }
        }
    }

    /// The key equivalent is shown (right-aligned, grey — the native menu's own rendering) so the
    /// toolbar teaches the shortcut; the main menu's identical binding is what normally handles it.
    private func selectionToolbarCommandItem(_ title: String, _ selector: Selector, key: String,
                                             modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runSelectionToolbarMenuCommand(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = NSStringFromSelector(selector)
        return item
    }

    @objc private func runSelectionToolbarMenuCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        performSelectionToolbarCommand(NSSelectorFromString(name))
    }

    @objc private func selectSelectionToolbarAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? AIAction, let controller = selectionToolbarStorage else { return }
        controller.model.action = action
        controller.model.focusToken += 1
    }

    // MARK: - Comment card

    /// The toolbar's Ask (2026-11-24): opens the window's AI drawer, the same route as Edit ▸ Ask
    /// AI…. The selection stays as it is: the drawer's requests go to it.
    private func openSelectionToolbarComment() {
        LineformAppNotification.askAI.post(object: LineformAppNotification.Payload(
            windowNumber: window?.windowNumber, value: nil, selectedRange: selectedRange()))
    }

    // MARK: - Edit ▸ Ask AI…

    /// Edit ▸ Ask AI… with a selection: the comment card for it, exactly as the toolbar's Ask
    /// button opens it (the bar is shown first if it was not up — a programmatic selection, or
    /// one the writer dismissed with Esc).
    func openSelectionToolbarCommentFromMenu() {
        guard selectedRange().length > 0, aiCommandHandler != nil,
              AIConnectionStore.shared.connectedProvider != nil else { return }
        let controller = selectionToolbar
        if controller.model.mode == .comment, controller.isVisible, !controller.isWholeDocument { return }
        if controller.isWholeDocument { hideSelectionToolbar() }
        showSelectionToolbarForCurrentSelection()
        guard controller.isVisible else { return }
        openSelectionToolbarComment()
    }

    /// Edit ▸ Ask AI… with nothing selected (after `WholeDocumentAIPolicy`): the same comment card,
    /// for the whole document, at the top centre of the visible editor. Nothing is highlighted —
    /// the whole document is the subject — and the caret stays where it was.
    func openWholeDocumentAIComment() {
        guard allowsSelectionToolbar, let provider = aiCommandHandler == nil ? nil : AIConnectionStore.shared.connectedProvider
        else { return }
        let length = (string as NSString).length
        guard length > 0 else { return }
        let caret = selectedRange()
        hideSelectionToolbar()
        let controller = selectionToolbar
        let model = controller.model
        controller.anchorRange = NSRange(location: 0, length: length)
        controller.isWholeDocument = true
        controller.wholeDocumentCaret = caret
        model.aiName = SelectionToolbarPresentation.aiName(for: provider)
        model.showsFormatting = false
        model.usesDarkChrome = Theme.theme(for: appliedReadingProfile).usesDarkChrome
        model.note = ""
        model.action = .custom
        model.isWholeDocument = true
        let probeModel = SelectionToolbarModel()
        probeModel.mode = .comment
        probeModel.aiName = model.aiName
        probeModel.usesDarkChrome = model.usesDarkChrome
        probeModel.isWholeDocument = true
        let size = NSHostingView(rootView: SelectionToolbarRoot(model: probeModel)).fittingSize
        let hosting = controller.hostingView
        addSubview(hosting)
        if size.width > 0, size.height > 0 {
            let visible = visibleRect
            let inset = SelectionToolbarHostingView.shadowInset
            let x = min(max(visible.midX - size.width / 2, visible.minX), visible.maxX - size.width)
            hosting.move(to: NSRect(x: x.rounded(), y: (visible.minY + 8 - inset).rounded(),
                                    width: size.width, height: size.height))
        }
        model.mode = .comment
        DispatchQueue.main.async { [weak self] in
            guard self != nil, controller.isVisible else { return }
            self?.window?.makeFirstResponder(hosting)
            model.focusToken += 1
        }
    }

    private func sendSelectionToolbarComment() {
        guard let controller = selectionToolbarStorage, let range = controller.anchorRange else { return }
        let model = controller.model
        guard model.canSend else { return }
        let action = model.action
        let note = model.note
        let wholeDocument = controller.isWholeDocument
        hideSelectionToolbar()
        window?.makeFirstResponder(self)
        aiCommandHandler?(wholeDocument ? .runWholeDocument(action, note: note) : .run(action, range, note: note))
    }

    private func closeSelectionToolbarComment() {
        let anchor = selectionToolbarStorage?.isWholeDocument == true
            ? selectionToolbarStorage?.wholeDocumentCaret : selectionToolbarStorage?.anchorRange
        hideSelectionToolbar()
        window?.makeFirstResponder(self)
        // Esc gives the writer their selection back, as it was before the card opened.
        if let anchor, let controller = selectionToolbarStorage,
           NSMaxRange(anchor) <= (string as NSString).length {
            controller.isAdjustingSelection = true
            setSelectedRange(anchor)
            controller.isAdjustingSelection = false
        }
    }

    /// While the note field has focus the text view is not first responder, and the writer must
    /// still see what the comment is about. The passage keeps the highlighter stroke
    /// (`heldHighlightRange`, drawn behind the text like the selection, never in the text storage)
    /// until the card closes.
    private func holdCommentHighlight() {
        guard let controller = selectionToolbarStorage, let range = controller.anchorRange else { return }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: (string as NSString).length))
        guard clamped.length > 0 else { return }
        controller.heldHighlightRange = clamped
        // The real selection collapses while the card is open (the card sends against
        // `anchorRange`, not the live selection), so typing in the editor can never replace the
        // passage. Esc restores it.
        controller.isAdjustingSelection = true
        setSelectedRange(NSRange(location: NSMaxRange(clamped), length: 0))
        controller.isAdjustingSelection = false
        refreshHighlighterSelection()
    }

    private func releaseCommentHighlight() {
        guard let controller = selectionToolbarStorage, controller.heldHighlightRange != nil else { return }
        controller.heldHighlightRange = nil
        refreshHighlighterSelection()
    }

    /// The note wrapped (or unwrapped) a line: the comment card keeps its TOP edge and grows or
    /// shrinks downward, so what the writer typed stays in view. If that would run past the bottom
    /// of the visible text, it moves up just enough. The bar never changes size on its own.
    private func selectionToolbarContentSizeChanged() {
        guard let controller = selectionToolbarStorage, controller.isVisible,
              controller.model.mode == .comment, controller.dragStart == nil else { return }
        let hosting = controller.hostingView
        let size = hosting.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = hosting.frame
        frame.size = size
        if let top = hosting.pinnedTop { frame.origin.y = top }
        let inset = SelectionToolbarHostingView.shadowInset
        let visibleBottom = visibleRect.maxY + inset
        if frame.maxY > visibleBottom {
            frame.origin.y = max(visibleRect.minY - inset, visibleBottom - frame.height)
        }
        hosting.move(to: frame)
    }

    /// The comment card takes the bar's place: same centre, and the same edge toward the passage —
    /// its bottom where the bar's bottom was when the bar sat above the selection (it grows
    /// upward, off the text), its top where the bar's top was when it sat below. Kept on screen.
    private func commentCardFrame(size: NSSize, replacing bar: NSRect, growsUp: Bool) -> NSRect {
        let visible = visibleRect
        var x = bar.midX - size.width / 2
        x = min(max(x, visible.minX), visible.maxX - size.width)
        var y = growsUp ? bar.maxY - size.height : bar.minY
        y = min(max(y, visible.minY), visible.maxY - size.height)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Esc while the bar is up dismisses it and keeps the selection. From `doCommand(by:)`.
    func handleSelectionToolbarCommand(_ selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), isSelectionToolbarVisible else { return false }
        hideSelectionToolbar()
        return true
    }
}

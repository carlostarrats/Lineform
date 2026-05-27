import AppKit

final class LineformTextView: NSTextView {
    let emptyStatePlaceholder = "Start writing..."
    static let readingRulerFillOpacity: CGFloat = 0.12
    private let markdownHighlighter = MarkdownSyntaxHighlighter()
    private var activeReadingProfile = ReadingProfile.original
    private var hasAppliedTypography = false
    private(set) var isLineformWritingToolsSessionActive = false
    private var activeIntelligentSuggestionRange: NSRange?
    private var scrollOriginBeforeTypewriterMode: NSPoint?
    private var selectionChangeIsMouseDriven = false

    convenience init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        self.init(frame: .zero, textContainer: textContainer)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureForMarkdownEditing()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureForMarkdownEditing()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func applyDefaultTypography() {
        applyTypography(.original)
    }

    var appliedReadingProfile: ReadingProfile {
        activeReadingProfile
    }

    func applyTypography(_ profile: ReadingProfile) {
        guard profile != activeReadingProfile || !hasAppliedTypography else {
            updateTextContainerLayout(for: profile)
            return
        }

        let previousProfile = activeReadingProfile
        updateTypewriterScrollState(from: previousProfile, to: profile)
        activeReadingProfile = profile
        hasAppliedTypography = true

        let theme = Theme.theme(for: profile)
        let resolvedFont = FontOption.option(for: profile.fontID)?.resolvedFont(size: CGFloat(profile.fontSize)) ?? .systemFont(ofSize: CGFloat(profile.fontSize))
        font = resolvedFont
        textColor = theme.textColor
        backgroundColor = theme.backgroundColor
        drawsBackground = true
        insertionPointColor = theme.caretColor
        updateTextContainerLayout(for: profile)
        typingAttributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        refreshMarkdownHighlighting()
        refreshReadingAssists()
    }

    func refreshMarkdownHighlighting() {
        markdownHighlighter.highlight(textView: self, profile: activeReadingProfile)
    }

    func refreshReadingAssists() {
        needsDisplay = true
        centerSelectionForTypewriterModeIfNeeded()
    }

    @objc func toggleBoldMarkdown(_ sender: Any?) {
        applyFormattingCommand(.bold)
    }

    @objc func toggleTitleMarkdown(_ sender: Any?) {
        applyFormattingCommand(.title)
    }

    @objc func toggleSectionMarkdown(_ sender: Any?) {
        applyFormattingCommand(.section)
    }

    @objc func toggleItalicMarkdown(_ sender: Any?) {
        applyFormattingCommand(.italic)
    }

    @objc func toggleInlineCodeMarkdown(_ sender: Any?) {
        applyFormattingCommand(.inlineCode)
    }

    @objc func toggleUnorderedListMarkdown(_ sender: Any?) {
        applyFormattingCommand(.unorderedList)
    }

    @objc func toggleLinkMarkdown(_ sender: Any?) {
        applyFormattingCommand(.link)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "v"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Title", action: #selector(toggleTitleMarkdown(_:)), keyEquivalent: "1"))
        menu.addItem(NSMenuItem(title: "Section", action: #selector(toggleSectionMarkdown(_:)), keyEquivalent: "2"))
        menu.addItem(NSMenuItem(title: "Bold", action: #selector(toggleBoldMarkdown(_:)), keyEquivalent: "b"))
        menu.addItem(NSMenuItem(title: "Italic", action: #selector(toggleItalicMarkdown(_:)), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "Code", action: #selector(toggleInlineCodeMarkdown(_:)), keyEquivalent: "`"))
        menu.addItem(NSMenuItem(title: "Bulleted List", action: #selector(toggleUnorderedListMarkdown(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Link", action: #selector(toggleLinkMarkdown(_:)), keyEquivalent: "k"))
        menu.addItem(.separator())
        menu.addItem(intelligenceMenuItem())
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        markSelectionChangeAsMouseDriven()
        super.mouseDown(with: event)
        openAutomaticIntelligenceMenuIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        markSelectionChangeAsKeyboardDriven()
        super.keyDown(with: event)
    }

    func markSelectionChangeAsMouseDriven() {
        selectionChangeIsMouseDriven = true
    }

    func markSelectionChangeAsKeyboardDriven() {
        selectionChangeIsMouseDriven = false
    }

    func shouldOpenAutomaticIntelligenceMenuAfterMouseUp() -> Bool {
        selectionChangeIsMouseDriven
    }

    func makeAutomaticIntelligenceMenuForCurrentSelection() -> NSMenu? {
        guard let selectedText = currentSelectedText(), !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let menu = NSMenu(title: "Intelligence")
        let availability = IntelligenceAvailabilityService().currentStatus()

        for action in IntelligentEditingAction.contextualActions(for: selectedText) {
            menu.addItem(intelligentEditingMenuItem(for: action, enabled: availability.isAvailable, showsShortcut: false))
        }

        if #available(macOS 15.2, *) {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: AppMenuConfiguration.intelligencePrimaryCommandTitle,
                action: #selector(NSResponder.showWritingTools(_:)),
                keyEquivalent: ""
            ))
        }

        return menu
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: Self.insertionPointRect(for: rect, profile: activeReadingProfile), color: color, turnedOn: flag)
    }

    static func insertionPointRect(for rect: NSRect, profile: ReadingProfile) -> NSRect {
        var caretRect = rect
        caretRect.size.width = max(rect.width, CGFloat(profile.insertionPointWidth))
        return caretRect
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawEmptyStatePlaceholderIfNeeded()
        drawIntelligentSuggestionHighlightIfNeeded()
        drawReadingRulerIfNeeded()
    }

    func setIntelligentSuggestionRange(_ range: NSRange?) {
        activeIntelligentSuggestionRange = range
        needsDisplay = true
    }

    private func configureForMarkdownEditing() {
        allowsUndo = true
        isRichText = false
        importsGraphics = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = true
        usesFindPanel = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        setAccessibilityLabel("Markdown editor")
        setAccessibilityRole(.textArea)
        setAccessibilityHelp(emptyStatePlaceholder)
        configureWritingTools()
        applyDefaultTypography()
    }

    private func configureWritingTools() {
        if #available(macOS 15.0, *) {
            writingToolsBehavior = .complete
            allowedWritingToolsResultOptions = [.plainText, .list]
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTextContainerLayout(for: activeReadingProfile)
    }

    func writingToolsWillBegin() {
        isLineformWritingToolsSessionActive = true
    }

    func writingToolsDidEnd() {
        isLineformWritingToolsSessionActive = false
    }

    func writingToolsIgnoredRanges(in enclosingRange: NSRange) -> [NSValue] {
        MarkdownWritingToolsProtection
            .ignoredRanges(in: string, enclosingRange: enclosingRange)
            .map { NSValue(range: $0) }
    }

    @objc func runIntelligentEditingAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else {
            return
        }

        LineformAppNotification.runIntelligentEditingAction.post(
            object: LineformAppNotification.Payload(windowNumber: window?.windowNumber, value: rawValue)
        )
    }

    private func intelligenceMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Intelligence")
        let availability = IntelligenceAvailabilityService().currentStatus()

        if #available(macOS 15.2, *) {
            submenu.addItem(NSMenuItem(
                title: AppMenuConfiguration.intelligencePrimaryCommandTitle,
                action: #selector(NSResponder.showWritingTools(_:)),
                keyEquivalent: ""
            ))
            submenu.addItem(.separator())
        }

        if !availability.isAvailable {
            let unavailableItem = NSMenuItem(title: availability.message, action: nil, keyEquivalent: "")
            unavailableItem.isEnabled = false
            submenu.addItem(unavailableItem)
            submenu.addItem(.separator())
        }

        for action in IntelligentEditingAction.rightClickActions {
            submenu.addItem(intelligentEditingMenuItem(for: action, enabled: availability.isAvailable, showsShortcut: true))
        }

        let item = NSMenuItem(title: "Intelligence", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func currentSelectedText() -> String? {
        let range = selectedRange()
        let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: (string as NSString).length))
        guard safeRange.length > 0 else {
            return nil
        }

        return (string as NSString).substring(with: safeRange)
    }

    private func intelligentEditingMenuItem(for action: IntelligentEditingAction, enabled: Bool, showsShortcut: Bool) -> NSMenuItem {
        let item = NSMenuItem(
            title: action.title,
            action: #selector(runIntelligentEditingAction(_:)),
            keyEquivalent: showsShortcut ? action.keyEquivalent : ""
        )
        if showsShortcut {
            item.keyEquivalentModifierMask = [.command, .option]
        }
        item.representedObject = action.rawValue
        item.isEnabled = enabled
        return item
    }

    private func openAutomaticIntelligenceMenuIfNeeded() {
        guard shouldOpenAutomaticIntelligenceMenuAfterMouseUp() else {
            return
        }

        selectionChangeIsMouseDriven = false

        guard let menu = makeAutomaticIntelligenceMenuForCurrentSelection() else {
            return
        }

        menu.popUp(positioning: menu.items.first, at: automaticIntelligenceMenuAnchorPoint(), in: self)
    }

    private func automaticIntelligenceMenuAnchorPoint() -> NSPoint {
        let range = selectedRange()
        guard
            range.length > 0,
            let layoutManager,
            let textContainer
        else {
            return NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y

        let preferredX = min(max(rect.midX, bounds.minX + 18), bounds.maxX - 18)
        let preferredY = min(max(rect.maxY + 8, bounds.minY + 18), bounds.maxY - 18)
        return NSPoint(x: preferredX, y: preferredY)
    }

    private func drawIntelligentSuggestionHighlightIfNeeded() {
        guard let activeIntelligentSuggestionRange else {
            return
        }

        guard let rect = rectForAssistRange(activeIntelligentSuggestionRange) else {
            return
        }

        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        rect.insetBy(dx: -8, dy: -4).fill()
    }

    private func drawEmptyStatePlaceholderIfNeeded() {
        guard string.isEmpty, window?.firstResponder !== self else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: CGFloat(activeReadingProfile.fontSize)),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        emptyStatePlaceholder.draw(at: origin, withAttributes: attributes)
    }

    private func drawReadingRulerIfNeeded() {
        guard activeReadingProfile.readingRulerEnabled else {
            return
        }

        guard let rect = rectForAssistRange(ReadingAssistRangeResolver.focusRange(
            in: string,
            selectedRange: selectedRange(),
            mode: .currentLine
        )) else {
            return
        }

        NSColor.controlAccentColor.withAlphaComponent(Self.readingRulerFillOpacity).setFill()
        rect.insetBy(dx: -6, dy: -2).fill()
    }

    private func rectForAssistRange(_ characterRange: NSRange?) -> NSRect? {
        guard
            let characterRange,
            characterRange.length > 0,
            let layoutManager,
            let textContainer
        else {
            return nil
        }

        let safeRange = NSIntersectionRange(characterRange, NSRange(location: 0, length: (string as NSString).length))
        guard safeRange.length > 0 else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size.width = max(rect.width, bounds.width - textContainerInset.width * 2)
        return rect
    }

    private func centerSelectionForTypewriterModeIfNeeded() {
        guard activeReadingProfile.typewriterModeEnabled else {
            return
        }

        guard let scrollView = enclosingScrollView else {
            return
        }

        guard let rect = rectForAssistRange(ReadingAssistRangeResolver.focusRange(
            in: string,
            selectedRange: selectedRange(),
            mode: .currentLine
        )) else {
            return
        }

        let visibleBounds = scrollView.contentView.bounds
        scrollView.contentView.setBoundsOrigin(Self.typewriterScrollOrigin(for: rect, visibleBounds: visibleBounds))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    static func typewriterScrollOrigin(for lineRect: NSRect, visibleBounds: NSRect) -> NSPoint {
        NSPoint(
            x: visibleBounds.origin.x,
            y: max(0, lineRect.midY - visibleBounds.height / 2)
        )
    }

    private func updateTypewriterScrollState(from previousProfile: ReadingProfile, to profile: ReadingProfile) {
        guard previousProfile.typewriterModeEnabled != profile.typewriterModeEnabled else {
            return
        }

        if profile.typewriterModeEnabled {
            scrollOriginBeforeTypewriterMode = enclosingScrollView?.contentView.bounds.origin
            return
        }

        guard let scrollOriginBeforeTypewriterMode, let scrollView = enclosingScrollView else {
            self.scrollOriginBeforeTypewriterMode = nil
            return
        }

        scrollView.contentView.setBoundsOrigin(scrollOriginBeforeTypewriterMode)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        self.scrollOriginBeforeTypewriterMode = nil
    }

    private func updateTextContainerLayout(for profile: ReadingProfile) {
        textContainerInset = NSSize(
            width: EditorReadingLayout.horizontalInset(forContainerWidth: bounds.width, profile: profile),
            height: 32
        )
        textContainer?.widthTracksTextView = true
    }

    private func applyFormattingCommand(_ command: MarkdownFormattingCommand) {
        let edit = command.apply(to: string, selectedRange: selectedRange())
        let fullRange = NSRange(location: 0, length: (string as NSString).length)

        guard shouldChangeText(in: fullRange, replacementString: edit.text) else {
            return
        }

        textStorage?.setAttributedString(NSAttributedString(string: edit.text, attributes: MarkdownSyntaxHighlighter.baseAttributes(for: activeReadingProfile)))
        didChangeText()
        setSelectedRange(edit.selectedRange)
        refreshMarkdownHighlighting()
    }
}

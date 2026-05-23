import AppKit

final class LineformTextView: NSTextView {
    let emptyStatePlaceholder = "Start writing..."
    private let markdownHighlighter = MarkdownSyntaxHighlighter()
    private var activeReadingProfile = ReadingProfile.original
    private(set) var isLineformWritingToolsSessionActive = false
    private var activeIntelligentSuggestionRange: NSRange?

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

    func applyTypography(_ profile: ReadingProfile) {
        activeReadingProfile = profile

        let theme = Theme.theme(for: profile.themeID)
        let resolvedFont = FontOption.option(for: profile.fontID)?.resolvedFont(size: CGFloat(profile.fontSize)) ?? .systemFont(ofSize: CGFloat(profile.fontSize))
        font = resolvedFont
        textColor = theme.textColor
        backgroundColor = theme.backgroundColor
        drawsBackground = true
        insertionPointColor = theme.caretColor
        textContainerInset = NSSize(width: CGFloat(profile.marginWidth), height: 32)
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

    @objc func toggleItalicMarkdown(_ sender: Any?) {
        applyFormattingCommand(.italic)
    }

    @objc func toggleInlineCodeMarkdown(_ sender: Any?) {
        applyFormattingCommand(.inlineCode)
    }

    @objc func toggleUnorderedListMarkdown(_ sender: Any?) {
        applyFormattingCommand(.unorderedList)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Bold", action: #selector(toggleBoldMarkdown(_:)), keyEquivalent: "b"))
        menu.addItem(NSMenuItem(title: "Italic", action: #selector(toggleItalicMarkdown(_:)), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "Code", action: #selector(toggleInlineCodeMarkdown(_:)), keyEquivalent: "`"))
        menu.addItem(NSMenuItem(title: "Bulleted List", action: #selector(toggleUnorderedListMarkdown(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(intelligenceMenuItem())
        if #available(macOS 15.2, *) {
            menu.addItem(.separator())
            for item in NSMenuItem.writingToolsItems {
                if let menuItem = item.copy() as? NSMenuItem {
                    menu.addItem(menuItem)
                }
            }
        }
        return menu
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var caretRect = rect
        caretRect.size.width = max(rect.width, CGFloat(activeReadingProfile.insertionPointWidth))
        super.drawInsertionPoint(in: caretRect, color: color, turnedOn: flag)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawEmptyStatePlaceholderIfNeeded()
        drawIntelligentSuggestionHighlightIfNeeded()
        drawFocusHighlightIfNeeded()
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

        LineformAppNotification.runIntelligentEditingAction.post(object: rawValue)
    }

    private func intelligenceMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Intelligence")
        for action in IntelligentEditingAction.allCases {
            let item = NSMenuItem(
                title: action.title,
                action: #selector(runIntelligentEditingAction(_:)),
                keyEquivalent: action.keyEquivalent
            )
            item.keyEquivalentModifierMask = [.command, .option]
            item.representedObject = action.rawValue
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "Intelligence", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
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

        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.insetBy(dx: -6, dy: -2).fill()
    }

    private func drawFocusHighlightIfNeeded() {
        guard activeReadingProfile.focusMode != .off else {
            return
        }

        guard let rect = rectForAssistRange(ReadingAssistRangeResolver.focusRange(
            in: string,
            selectedRange: selectedRange(),
            mode: activeReadingProfile.focusMode
        )) else {
            return
        }

        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.10).setFill()
        rect.insetBy(dx: -8, dy: -4).fill()
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
        let targetY = max(0, rect.midY - visibleBounds.height / 2)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: visibleBounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
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

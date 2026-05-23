import AppKit

final class LineformTextView: NSTextView {
    private let markdownHighlighter = MarkdownSyntaxHighlighter()
    private var activeReadingProfile = ReadingProfile.original

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
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
    }

    func refreshMarkdownHighlighting() {
        markdownHighlighter.highlight(textView: self, profile: activeReadingProfile)
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
        return menu
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var caretRect = rect
        caretRect.size.width = max(rect.width, CGFloat(activeReadingProfile.insertionPointWidth))
        super.drawInsertionPoint(in: caretRect, color: color, turnedOn: flag)
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
        applyDefaultTypography()
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

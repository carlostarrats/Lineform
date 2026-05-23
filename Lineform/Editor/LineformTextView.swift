import AppKit

final class LineformTextView: NSTextView {
    private let markdownHighlighter = MarkdownSyntaxHighlighter()

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
        font = NSFont.systemFont(ofSize: CGFloat(ReadingProfile.original.fontSize))
        textColor = .labelColor
        backgroundColor = .textBackgroundColor
        insertionPointColor = .labelColor
        textContainerInset = NSSize(width: 40, height: 32)
        typingAttributes = MarkdownSyntaxHighlighter.baseAttributes
    }

    func refreshMarkdownHighlighting() {
        markdownHighlighter.highlight(textView: self)
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

        textStorage?.setAttributedString(NSAttributedString(string: edit.text, attributes: MarkdownSyntaxHighlighter.baseAttributes))
        didChangeText()
        setSelectedRange(edit.selectedRange)
        refreshMarkdownHighlighting()
    }
}

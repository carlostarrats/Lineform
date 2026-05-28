import AppKit

final class LineformTextView: NSTextView {
    let emptyStatePlaceholder = "Start writing..."
    static let readingRulerFillOpacity: CGFloat = 0.12
    private let markdownHighlighter = MarkdownSyntaxHighlighter()
    private var activeReadingProfile = ReadingProfile.original
    private var hasAppliedTypography = false
    private var hasAppliedTextContainerLayout = false
    private(set) var isLineformWritingToolsSessionActive = false
    private var activeIntelligentSuggestionRange: NSRange?
    private var searchHighlightRanges: [NSRange] = []
    private var activeSearchHighlightRange: NSRange?
    private var scrollOriginBeforeTypewriterMode: NSPoint?
    private var pendingDeferredVisualLayoutAnchor: VisualLayoutAnchor?
    private var pendingDeferredVerticalScrollOrigin: CGFloat?
    private var hasScheduledDeferredVisualLayoutAnchorRestore = false
    private var hasScheduledDeferredVerticalScrollOriginRestore = false
    var textFormat = LineformTextFormat.markdown
    var lastPlainTextConversion: MarkdownPlainTextConversion?
    var textFormatChangeHandler: ((LineformTextFormat, MarkdownPlainTextConversion?) -> Void)?
    var smoothsHorizontalInsetChanges = false
    var horizontalInsetAnimationDuration: TimeInterval {
        EditorInspectorTextResponse.horizontalInsetAnimationDuration
    }

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        if
            let window,
            EditorFloatingControlHitTestRegistry.contains(
                windowPoint: convert(point, to: nil),
                in: window
            )
        {
            return nil
        }

        return super.hitTest(point)
    }

    override func mouseMoved(with event: NSEvent) {
        if isEventInsideFloatingControl(event) {
            return
        }

        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEventInsideFloatingControl(event) {
            return
        }

        super.cursorUpdate(with: event)
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

    @objc func convertMarkdownToPlainText(_ sender: Any?) {
        guard textFormat == .markdown else {
            return
        }

        let nsText = string as NSString
        let selection = selectedRange()
        let conversionRange = selection.length > 0
            ? selection
            : NSRange(location: 0, length: nsText.length)
        guard conversionRange.length > 0, NSMaxRange(conversionRange) <= nsText.length else {
            return
        }

        let originalMarkdown = nsText.substring(with: conversionRange)
        let plainText = MarkdownPlainTextConverter.plainText(from: originalMarkdown)
        let conversion = MarkdownPlainTextConversion(
            originalMarkdown: originalMarkdown,
            plainText: plainText,
            range: NSRange(location: conversionRange.location, length: (plainText as NSString).length)
        )

        applyWholeTextEdit(
            replacing: conversionRange,
            with: plainText,
            selectedRange: conversion.range
        )
        lastPlainTextConversion = conversion
        textFormat = .plainText
        LineformTextFormatMenuState.shared.setTextFormat(.plainText)
        textFormatChangeHandler?(.plainText, conversion)
    }

    @objc func restoreConvertedMarkdown(_ sender: Any?) {
        if
            let conversion = lastPlainTextConversion,
            let edit = conversion.restoredMarkdown(in: string)
        {
            applyWholeTextReplacement(edit)
        }

        lastPlainTextConversion = nil
        textFormat = .markdown
        LineformTextFormatMenuState.shared.setTextFormat(.markdown)
        textFormatChangeHandler?(.markdown, nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cancelPendingAutomaticIntelligenceMenu()
        let contextMenuTextFormat = LineformTextFormatMenuState.shared.textFormat
        textFormat = contextMenuTextFormat
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = LineformTextContextMenuPresentation.allowsContextMenuPlugIns
        menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.cutTitle, action: #selector(cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.copyTitle, action: #selector(copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.pasteTitle, action: #selector(paste(_:)), keyEquivalent: "v"))
        if contextMenuTextFormat == .markdown {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.titleTitle, action: #selector(toggleTitleMarkdown(_:)), keyEquivalent: "1"))
            menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.sectionTitle, action: #selector(toggleSectionMarkdown(_:)), keyEquivalent: "2"))
            menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.boldTitle, action: #selector(toggleBoldMarkdown(_:)), keyEquivalent: "b"))
            menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.italicTitle, action: #selector(toggleItalicMarkdown(_:)), keyEquivalent: "i"))
            menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.codeTitle, action: #selector(toggleInlineCodeMarkdown(_:)), keyEquivalent: "`"))
            menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.bulletedListTitle, action: #selector(toggleUnorderedListMarkdown(_:)), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.linkTitle, action: #selector(toggleLinkMarkdown(_:)), keyEquivalent: "k"))
        }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        if
            let window,
            EditorFloatingControlHitTestRegistry.handleMouseDown(
                windowPoint: event.locationInWindow,
                in: window
            )
        {
            return
        }

        markSelectionChangeAsMouseDriven()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        markSelectionChangeAsKeyboardDriven()
        super.keyDown(with: event)
    }

    func markSelectionChangeAsMouseDriven() {
    }

    func markSelectionChangeAsKeyboardDriven() {
    }

    func shouldOpenAutomaticIntelligenceMenuAfterMouseUp() -> Bool {
        false
    }

    var hasPendingAutomaticIntelligenceMenu: Bool {
        false
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
        drawSearchHighlightsIfNeeded()
        drawIntelligentSuggestionHighlightIfNeeded()
        drawReadingRulerIfNeeded()
    }

    func setIntelligentSuggestionRange(_ range: NSRange?) {
        activeIntelligentSuggestionRange = range
        needsDisplay = true
    }

    func setSearchHighlights(_ ranges: [NSRange], activeRange: NSRange?) {
        searchHighlightRanges = ranges
        activeSearchHighlightRange = activeRange
        needsDisplay = true
    }

    func selectionAnchorRectInEnclosingScrollView() -> CGRect? {
        guard let enclosingScrollView else {
            return nil
        }

        guard let rect = rectForCharacterRange(selectedRange()) else {
            return nil
        }

        return convert(rect, to: enclosingScrollView)
    }

    func visibleCharacterRangeForLayoutPreservation() -> NSRange? {
        guard
            let layoutManager,
            let textContainer,
            let scrollView = enclosingScrollView
        else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        var visibleRect = scrollView.contentView.bounds
        visibleRect.origin.x -= textContainerOrigin.x
        visibleRect.origin.y -= textContainerOrigin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
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
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(
            width: EditorReadingLayout.textContainerWidth(forContainerWidth: bounds.width, profile: activeReadingProfile),
            height: CGFloat.greatestFiniteMagnitude
        )
        setAccessibilityLabel("Markdown editor")
        setAccessibilityRole(.textArea)
        setAccessibilityHelp(emptyStatePlaceholder)
        configureWritingTools()
        applyDefaultTypography()
    }

    private func configureWritingTools() {
        if #available(macOS 15.0, *) {
            writingToolsBehavior = .none
            allowedWritingToolsResultOptions = [.plainText, .list]
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousVerticalScrollOrigin = enclosingScrollView?.contentView.bounds.origin.y
        preserveVisibleLayoutAnchorDuring(
            preservesVisualAnchor: shouldPreserveVisualLayoutAnchor(forProposedFrameWidth: newSize.width),
            restoresAfterDeferredLayout: true
        ) {
            super.setFrameSize(sizePreservingScrollableDocumentHeight(for: newSize))
            updateTextContainerLayout(for: activeReadingProfile, preservingVerticalScrollOrigin: previousVerticalScrollOrigin)
            restoreVerticalScrollOrigin(previousVerticalScrollOrigin)
        }
    }

    func preserveVisibleLayoutAnchorDuring(
        preservesVisualAnchor: Bool = true,
        restoresAfterDeferredLayout: Bool = false,
        verticalScrollOrigin: CGFloat? = nil,
        _ updates: () -> Void
    ) {
        if !preservesVisualAnchor {
            pendingDeferredVisualLayoutAnchor = nil
        }

        let verticalScrollOriginToRestore = preservesVisualAnchor
            ? nil
            : verticalScrollOrigin ?? enclosingScrollView?.contentView.bounds.origin.y
        let visualAnchor = preservesVisualAnchor ? visualLayoutAnchorForPreservation() : nil
        updates()
        if let visualAnchor {
            restoreVisualLayoutAnchor(visualAnchor)
        } else {
            restoreVerticalScrollOrigin(verticalScrollOriginToRestore)
        }
        if restoresAfterDeferredLayout {
            if let visualAnchor {
                restoreVisualLayoutAnchorAfterDeferredLayout(visualAnchor)
            } else {
                restoreVerticalScrollOriginAfterDeferredLayout(verticalScrollOriginToRestore)
            }
        }
    }

    func shouldPreserveVisualLayoutAnchor(forProposedFrameWidth proposedFrameWidth: CGFloat) -> Bool {
        guard !smoothsHorizontalInsetChanges else {
            return false
        }

        let currentWidth = textContainer?.containerSize.width
        let targetWidth = EditorReadingLayout.textContainerWidth(
            forContainerWidth: proposedFrameWidth,
            profile: activeReadingProfile
        )
        guard let currentWidth else {
            return true
        }

        return abs(currentWidth - targetWidth) <= 0.5
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
            object: LineformAppNotification.Payload(
                windowNumber: window?.windowNumber,
                value: rawValue,
                selectedRange: selectedRange()
            )
        )
    }

    func scheduleAutomaticIntelligenceMenuIfNeeded() {
    }

    func cancelPendingAutomaticIntelligenceMenu() {
    }

    private func drawIntelligentSuggestionHighlightIfNeeded() {
        guard let activeIntelligentSuggestionRange else {
            return
        }

        guard let rect = rectForCharacterRange(activeIntelligentSuggestionRange) else {
            return
        }

        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        rect.insetBy(dx: -8, dy: -4).fill()
    }

    private func drawSearchHighlightsIfNeeded() {
        guard !searchHighlightRanges.isEmpty else {
            return
        }

        let rangesToDraw = EditorSearchResolver.visibleMatches(
            searchHighlightRanges,
            activeRange: activeSearchHighlightRange,
            visibleCharacterRange: visibleCharacterRangeForSearchHighlights()
        )

        for range in rangesToDraw {
            let isActive = range == activeSearchHighlightRange
            let color = isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.22)
                : NSColor.systemYellow.withAlphaComponent(0.28)
            color.setFill()

            for rect in rectsForCharacterRange(range) {
                rect.insetBy(dx: -2, dy: -1).fill()
            }
        }
    }

    private func visibleCharacterRangeForSearchHighlights() -> NSRange? {
        visibleCharacterRangeForLayoutPreservation()
    }

    private func isEventInsideFloatingControl(_ event: NSEvent) -> Bool {
        guard let window else {
            return false
        }

        return EditorFloatingControlHitTestRegistry.contains(
            windowPoint: event.locationInWindow,
            in: window
        )
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
        guard let rect = rectForCharacterRange(characterRange) else {
            return nil
        }

        var fullWidthRect = rect
        fullWidthRect.size.width = max(rect.width, bounds.width - textContainerInset.width * 2)
        return fullWidthRect
    }

    private func rectForCharacterRange(_ characterRange: NSRange?) -> NSRect? {
        rectsForCharacterRange(characterRange).first
    }

    private func rectsForCharacterRange(_ characterRange: NSRange?) -> [NSRect] {
        guard
            let characterRange,
            characterRange.length > 0,
            let layoutManager,
            let textContainer
        else {
            return []
        }

        let safeRange = NSIntersectionRange(characterRange, NSRange(location: 0, length: (string as NSString).length))
        guard safeRange.length > 0 else {
            return []
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
        var rects: [NSRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            var adjustedRect = rect
            adjustedRect.origin.x += self.textContainerOrigin.x
            adjustedRect.origin.y += self.textContainerOrigin.y
            rects.append(adjustedRect)
        }

        if rects.isEmpty {
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            rects.append(rect)
        }

        return rects
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

    private func updateTextContainerLayout(
        for profile: ReadingProfile,
        preservingVerticalScrollOrigin previousVerticalScrollOrigin: CGFloat? = nil
    ) {
        let verticalScrollOriginToRestore = previousVerticalScrollOrigin ?? enclosingScrollView?.contentView.bounds.origin.y
        setTextContainerInset(
            NSSize(
                width: EditorReadingLayout.horizontalInset(forContainerWidth: bounds.width, profile: profile),
                height: 32
            ),
            preservingVerticalScrollOrigin: verticalScrollOriginToRestore
        )
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(
            width: EditorReadingLayout.textContainerWidth(forContainerWidth: bounds.width, profile: profile),
            height: CGFloat.greatestFiniteMagnitude
        )
        restoreVerticalScrollOrigin(verticalScrollOriginToRestore)
    }

    private func sizePreservingScrollableDocumentHeight(for proposedSize: NSSize) -> NSSize {
        guard
            isVerticallyResizable,
            enclosingScrollView != nil,
            let layoutManager,
            let textContainer
        else {
            return proposedSize
        }

        let targetContainerWidth = EditorReadingLayout.textContainerWidth(
            forContainerWidth: proposedSize.width,
            profile: activeReadingProfile
        )
        textContainer.widthTracksTextView = false
        textContainer.containerSize = NSSize(
            width: targetContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)

        let minimumDocumentHeight = ceil(
            layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
        )
        return NSSize(
            width: proposedSize.width,
            height: max(proposedSize.height, minimumDocumentHeight)
        )
    }

    private func setTextContainerInset(
        _ targetInset: NSSize,
        preservingVerticalScrollOrigin previousVerticalScrollOrigin: CGFloat? = nil
    ) {
        defer {
            hasAppliedTextContainerLayout = true
        }

        let verticalScrollOriginToRestore = previousVerticalScrollOrigin ?? enclosingScrollView?.contentView.bounds.origin.y

        guard
            smoothsHorizontalInsetChanges,
            hasAppliedTextContainerLayout,
            abs(textContainerInset.width - targetInset.width) > 0.5
        else {
            textContainerInset = targetInset
            restoreVerticalScrollOrigin(verticalScrollOriginToRestore)
            return
        }

        textContainerInset = targetInset
        restoreVerticalScrollOrigin(verticalScrollOriginToRestore)
    }

    private func restoreVerticalScrollOrigin(_ previousVerticalScrollOrigin: CGFloat?) {
        guard
            let previousVerticalScrollOrigin,
            let scrollView = enclosingScrollView
        else {
            return
        }

        var restoredOrigin = scrollView.contentView.bounds.origin
        guard abs(restoredOrigin.y - previousVerticalScrollOrigin) > 0.01 else {
            return
        }

        restoredOrigin.y = previousVerticalScrollOrigin
        scrollView.contentView.setBoundsOrigin(restoredOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private struct VisualLayoutAnchor {
        let characterRange: NSRange
        let yInWindow: CGFloat
    }

    private func visualLayoutAnchorForPreservation() -> VisualLayoutAnchor? {
        guard
            let visibleRange = visibleCharacterRangeForLayoutPreservation(),
            visibleRange.location < (string as NSString).length,
            enclosingScrollView != nil
        else {
            return nil
        }

        let characterRange = NSRange(location: visibleRange.location, length: 1)
        guard let yInWindow = yPositionInWindow(for: characterRange) else {
            return nil
        }

        return VisualLayoutAnchor(characterRange: characterRange, yInWindow: yInWindow)
    }

    private func restoreVisualLayoutAnchor(_ anchor: VisualLayoutAnchor?) {
        guard
            let anchor,
            let scrollView = enclosingScrollView,
            let currentY = yPositionInWindow(for: anchor.characterRange)
        else {
            return
        }

        let verticalDelta = currentY - anchor.yInWindow
        guard abs(verticalDelta) > 0.5 else {
            return
        }

        var restoredOrigin = scrollView.contentView.bounds.origin
        restoredOrigin.y -= verticalDelta
        scrollView.contentView.setBoundsOrigin(restoredOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func restoreVisualLayoutAnchorAfterDeferredLayout(_ anchor: VisualLayoutAnchor?) {
        guard anchor != nil else {
            return
        }

        pendingDeferredVisualLayoutAnchor = anchor
        guard !hasScheduledDeferredVisualLayoutAnchorRestore else {
            return
        }

        hasScheduledDeferredVisualLayoutAnchorRestore = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            let pendingAnchor = pendingDeferredVisualLayoutAnchor
            pendingDeferredVisualLayoutAnchor = nil
            hasScheduledDeferredVisualLayoutAnchorRestore = false
            restoreVisualLayoutAnchor(pendingAnchor)
        }
    }

    private func restoreVerticalScrollOriginAfterDeferredLayout(_ verticalScrollOrigin: CGFloat?) {
        guard let verticalScrollOrigin else {
            return
        }

        pendingDeferredVerticalScrollOrigin = verticalScrollOrigin
        guard !hasScheduledDeferredVerticalScrollOriginRestore else {
            return
        }

        hasScheduledDeferredVerticalScrollOriginRestore = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            let pendingScrollOrigin = pendingDeferredVerticalScrollOrigin
            pendingDeferredVerticalScrollOrigin = nil
            hasScheduledDeferredVerticalScrollOriginRestore = false
            restoreVerticalScrollOrigin(pendingScrollOrigin)
        }
    }

    private func yPositionInWindow(for characterRange: NSRange) -> CGFloat? {
        guard let rect = rectForCharacterRange(characterRange) else {
            return nil
        }

        return convert(rect, to: nil).midY
    }

    private func applyFormattingCommand(_ command: MarkdownFormattingCommand) {
        let edit = command.apply(to: string, selectedRange: selectedRange())
        applyWholeTextReplacement(edit)
    }

    private func applyWholeTextEdit(replacing range: NSRange, with replacement: String, selectedRange: NSRange) {
        var edited = string
        guard let swiftRange = Range(range, in: edited) else {
            return
        }
        edited.replaceSubrange(swiftRange, with: replacement)
        applyWholeTextReplacement(MarkdownEdit(text: edited, selectedRange: selectedRange))
    }

    private func applyWholeTextReplacement(_ edit: MarkdownEdit) {
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

enum LineformTextContextMenuPresentation {
    static let allowsContextMenuPlugIns = false
    static let cutTitle = "Cut"
    static let copyTitle = "Copy"
    static let pasteTitle = "Paste"
    static let titleTitle = "Title"
    static let sectionTitle = "Section"
    static let boldTitle = "Bold"
    static let italicTitle = "Italic"
    static let codeTitle = "Code"
    static let bulletedListTitle = "Bulleted List"
    static let linkTitle = "Link"
    static let convertToPlainTextTitle = "Convert to Plain Text"
    static let convertToMarkdownTitle = "Convert to Markdown"
    static let excludedSystemPluginTitles = ["Autofill", "AutoFill", "Services"]

    static func conversionTitle(for textFormat: LineformTextFormat) -> String {
        switch textFormat {
        case .markdown:
            return convertToPlainTextTitle
        case .plainText:
            return convertToMarkdownTitle
        }
    }

    static func conversionAction(for textFormat: LineformTextFormat) -> Selector {
        switch textFormat {
        case .markdown:
            return #selector(LineformTextView.convertMarkdownToPlainText(_:))
        case .plainText:
            return #selector(LineformTextView.restoreConvertedMarkdown(_:))
        }
    }

    static func commandTitles(for textFormat: LineformTextFormat) -> [String] {
        let rawTextCommands = [
            cutTitle,
            copyTitle,
            pasteTitle
        ]

        switch textFormat {
        case .markdown:
            return rawTextCommands + [
            titleTitle,
            sectionTitle,
            boldTitle,
            italicTitle,
            codeTitle,
            bulletedListTitle,
            linkTitle
        ]
        case .plainText:
            return rawTextCommands
        }
    }

    static var commandTitles: [String] {
        commandTitles(for: .markdown)
    }
}

import AppKit
import SwiftUI

struct MarkdownPreviewViewRepresentable: NSViewRepresentable {
    var text: String
    var profile: ReadingProfile
    /// Called when the user clicks a rendered task checkbox, with the `NSRange` of its `[ ]`/`[x]`
    /// marker in the source document. The container toggles that span in `document.text`.
    var onCheckboxToggle: (NSRange) -> Void = { _ in }
    /// Called when the visible top of the rendered text changes. The range is in rendered-text
    /// coordinates; use `.headingSourceRange` attributes to map headings back to source positions.
    var onVisibleTopRangeChanged: ((NSRange) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = MarkdownPreviewTextView()
        textView.setAccessibilityLabel("Markdown read view")
        textView.setAccessibilityRole(.textArea)
        textView.onCheckboxToggle = onCheckboxToggle
        textView.onVisibleTopRangeChanged = onVisibleTopRangeChanged

        scrollView.documentView = textView
        textView.apply(text: text, profile: profile)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownPreviewTextView else {
            return
        }

        // Re-bind the closure each update so it captures the current document binding.
        textView.onCheckboxToggle = onCheckboxToggle
        textView.onVisibleTopRangeChanged = onVisibleTopRangeChanged
        textView.apply(text: text, profile: profile)
    }
}

final class MarkdownPreviewTextView: NSTextView, NSTextViewDelegate {
    /// Set by the representable; invoked with a checkbox's source-marker range on a click that lands
    /// on a rendered checkbox glyph.
    var onCheckboxToggle: (NSRange) -> Void = { _ in }
    /// Called when the visible character range changes due to scrolling. For Read/Preview mode this
    /// is a range in the rendered text; the receiver maps it back to the source via the
    /// `.headingSourceRange` attribute attached to headings.
    var onVisibleTopRangeChanged: ((NSRange) -> Void)?
    private var activeProfile = ReadingProfile.original
    private var renderedText: String?
    private var renderedProfile: ReadingProfile?
    private let mermaidProvider = MermaidImageProvider()
    private let mathProvider = MathImageProvider()
    private let diagramLog = DiagramLogStore()
    private let reportRegistry = DiagramReportRegistry()
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    private static let visibleTopRangeReportDebounce: TimeInterval = 0.08
    private var lastReportedVisibleTopRange: NSRange?

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
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        // Capture BEFORE the width change: which character sits at the top of the viewport, and
        // where. A narrower column rewraps the text, so the same scroll offset would show a
        // different passage — the "text jumps when a side drawer opens" bug. Mirrors Write
        // mode's visual-anchor preservation (LineformTextView), scoped to width changes only.
        // NOT during a manual window drag: there the text must simply rewrap downward under a
        // fixed scroll origin, like plain text (user decision, 2026-07-17 — see
        // LineformTextView.shouldPreserveVisualLayoutAnchorDuringLayoutTransition).
        let reflowAnchor = (widthChanged && !inLiveResize) ? reflowAnchorForWidthChange() : nil
        super.setFrameSize(newSize)
        updateTextContainerLayout()
        // Refit block diagrams/equations on EVERY width change — the same place `updateTextContainerLayout`
        // already tracks the window (so it works during a live window/split drag, unlike the
        // unreliable `viewDidEndLiveResize` on a scroll view's documentView). During a live resize
        // the refit is deferred to the next runloop tick so its `ensureLayout` doesn't run
        // re-entrantly inside AppKit's in-progress resize layout pass; scaling the cached raster is
        // cheap, so per-tick is fine (no re-render).
        if widthChanged {
            if inLiveResize {
                scheduleBlockAttachmentRefit()
            } else {
                refitBlockAttachments()
            }
        }
        // Restore last, after the refit has settled attachment sizes for this pass.
        if let reflowAnchor {
            restoreReflowAnchor(reflowAnchor)
        }
    }

    /// The character at the top of the viewport and its offset from the viewport top, captured
    /// before a width change so the passage being read can be pinned through the rewrap.
    private struct ReflowAnchor {
        let characterIndex: Int
        let offsetFromViewportTop: CGFloat
        /// A view at the very top stays pinned to 0 outright — character-anchoring wobbles by
        /// ±1 line per resize frame, which at the top reads as bouncing (see LineformTextView).
        let capturedAtTop: Bool
    }

    private func reflowAnchorForWidthChange() -> ReflowAnchor? {
        guard
            let layoutManager,
            let textContainer,
            let textStorage,
            textStorage.length > 0,
            let clipView = enclosingScrollView?.contentView
        else {
            return nil
        }

        var visibleRect = clipView.bounds
        visibleRect.origin.x -= textContainerOrigin.x
        visibleRect.origin.y -= textContainerOrigin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterIndex = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
        guard characterIndex < textStorage.length else {
            return nil
        }

        guard let yInContainer = reflowAnchorY(forCharacterAt: characterIndex) else {
            return nil
        }

        return ReflowAnchor(
            characterIndex: characterIndex,
            offsetFromViewportTop: yInContainer + textContainerOrigin.y - clipView.bounds.origin.y,
            capturedAtTop: clipView.bounds.origin.y <= 1
        )
    }

    private func restoreReflowAnchor(_ anchor: ReflowAnchor) {
        guard
            let textStorage,
            anchor.characterIndex < textStorage.length,
            let scrollView = enclosingScrollView
        else {
            return
        }

        if anchor.capturedAtTop {
            var restoredOrigin = scrollView.contentView.bounds.origin
            guard restoredOrigin.y > 0.5 else {
                return
            }
            restoredOrigin.y = 0
            scrollView.contentView.setBoundsOrigin(restoredOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }

        guard let yInContainer = reflowAnchorY(forCharacterAt: anchor.characterIndex) else {
            return
        }

        let restoredY = yInContainer + textContainerOrigin.y - anchor.offsetFromViewportTop
        var restoredOrigin = scrollView.contentView.bounds.origin
        guard abs(restoredOrigin.y - restoredY) > 0.5 else {
            return
        }

        restoredOrigin.y = max(0, restoredY)
        scrollView.contentView.setBoundsOrigin(restoredOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func reflowAnchorY(forCharacterAt characterIndex: Int) -> CGFloat? {
        guard let layoutManager, let textContainer else {
            return nil
        }

        // Lay out only up to the anchor — enough for a correct Y without typesetting the tail.
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: characterIndex + 1))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterIndex, length: 1),
            actualCharacterRange: nil
        )
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).minY
    }

    override func viewDidEndLiveResize() {
        // AppKit's end-of-live-resize revalidation snaps the clip origin to the topmost line
        // boundary (at the document top: exactly the top inset — the "text jumps up" resize
        // bug). Pin the pre-snap origin, same as LineformTextView.viewDidEndLiveResize.
        let originBeforeEndResize = enclosingScrollView?.contentView.bounds.origin.y
        super.viewDidEndLiveResize()
        if
            let originBeforeEndResize,
            let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView
        {
            let maximumOriginY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
            let clampedOriginY = min(max(originBeforeEndResize, 0), maximumOriginY)
            if abs(scrollView.contentView.bounds.origin.y - clampedOriginY) > 0.5 {
                var restoredOrigin = scrollView.contentView.bounds.origin
                restoredOrigin.y = clampedOriginY
                scrollView.contentView.setBoundsOrigin(restoredOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        // Final settle once the drag ends (inLiveResize is false here, so refit immediately).
        refitBlockAttachments()
    }

    private var blockRefitScheduled = false

    /// Coalesce refits requested during a live resize and run them once, outside the in-progress
    /// frame/layout pass.
    private func scheduleBlockAttachmentRefit() {
        guard !blockRefitScheduled else { return }
        blockRefitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.blockRefitScheduled = false
            self.refitBlockAttachments()
        }
    }

    func apply(text: String, profile: ReadingProfile) {
        activeProfile = profile
        let theme = Theme.theme(for: profile)
        backgroundColor = theme.backgroundColor
        textColor = theme.textColor
        updateTextContainerLayout()

        guard text != renderedText || profile != renderedProfile else {
            return
        }

        textStorage?.setAttributedString(
            MarkdownPreviewRenderer().render(
                text,
                profile: profile,
                columnWidth: EditorReadingLayout.textColumnMaxWidth(for: profile),
                mermaidProvider: mermaidProvider,
                mathProvider: mathProvider,
                diagramLog: diagramLog,
                reportRegistry: reportRegistry,
                appVersion: appVersion
            )
        )
        renderedText = text
        renderedProfile = profile
        // The renderer fits diagrams/equations to the reading column; refit to the current window
        // width so a fresh render on a narrow window doesn't overflow until the next resize.
        refitBlockAttachments()
    }

    /// Scale block diagram/equation attachments to the current window's available width, in place,
    /// without re-rendering (the raster is high-res; only the width number was stale). Inline math
    /// already fits, so it is left untouched and keeps its baseline offset.
    private func refitBlockAttachments() {
        guard let textStorage, let layoutManager, let textContainer, textStorage.length > 0 else { return }
        // Before the view is in a window its width is 0; refitting then would collapse every
        // diagram to ~1pt. Wait for a real width (the next real setFrameSize/apply refits).
        guard bounds.width > 1 else { return }
        let fitWidth = EditorReadingLayout.blockAttachmentFitWidth(forContainerWidth: bounds.width, profile: activeProfile)
        var didChange = false
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            // Only block diagrams/equations are refit; inline math is small, baseline-aligned, and
            // must never be rescaled (that would break its -descent baseline offset).
            guard let attachment = value as? BlockRenderedAttachment, let image = attachment.image else { return }
            guard let newBounds = BlockAttachmentRefit.refittedBounds(
                naturalSize: image.size,
                currentBounds: attachment.bounds,
                fitWidth: fitWidth
            ) else { return }
            attachment.bounds = newBounds
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            didChange = true
        }
        if didChange {
            layoutManager.ensureLayout(for: textContainer)
        }
    }

    // MARK: - Hover "Copy" pill (code blocks)

    /// The source range (in `renderedText`, the raw source markdown) of the currently-hovered code
    /// block, or nil when the pointer is not over one. Set by `mouseMoved`/`mouseExited`.
    private var hoveredCodeBlockSourceRange: NSRange?
    /// The hovered block's pill hit rect, in the text view's own (document) coordinate space —
    /// valid only while `hoveredCodeBlockSourceRange != nil`.
    private var hoveredCodePillRect: NSRect = .zero
    private var isShowingCopiedFeedback = false
    private var copyFeedbackGeneration = 0
    private var hoverTrackingArea: NSTrackingArea?

    private static let copyPillSize = NSSize(width: 58, height: 20)
    private static let copyPillInset: CGFloat = 8
    private static let copyPillCornerRadius: CGFloat = 10
    private static let copiedFeedbackDuration: TimeInterval = 1.0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredCodeBlock(at: event)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        clearHoveredCodeBlock()
        super.mouseExited(with: event)
    }

    /// Hit-tests the pointer to a code block's full `.codeBlockSourceRange` attribute run (mirrors
    /// `checkboxSourceRange(at:)`'s point→glyph→character math) and, when found, positions the
    /// "Copy" pill in that run's rendered bounding rect.
    private func updateHoveredCodeBlock(at event: NSEvent) {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else {
            clearHoveredCodeBlock()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y - textContainerInset.height)
        guard bounds.contains(point) else {
            clearHoveredCodeBlock()
            return
        }
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            clearHoveredCodeBlock()
            return
        }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < textStorage.length else {
            clearHoveredCodeBlock()
            return
        }

        var runRange = NSRange(location: NSNotFound, length: 0)
        guard let sourceValue = textStorage.attribute(
            .codeBlockSourceRange,
            at: charIndex,
            longestEffectiveRange: &runRange,
            in: NSRange(location: 0, length: textStorage.length)
        ) as? NSValue else {
            clearHoveredCodeBlock()
            return
        }

        let glyphRunRange = layoutManager.glyphRange(forCharacterRange: runRange, actualCharacterRange: nil)
        let blockRect = layoutManager.boundingRect(forGlyphRange: glyphRunRange, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

        let pillSize = Self.copyPillSize
        let pillRect = NSRect(
            x: blockRect.maxX - pillSize.width - Self.copyPillInset,
            y: blockRect.minY + Self.copyPillInset,
            width: pillSize.width,
            height: pillSize.height
        )

        let sourceRange = sourceValue.rangeValue
        if hoveredCodeBlockSourceRange == sourceRange && hoveredCodePillRect == pillRect {
            return
        }
        hoveredCodeBlockSourceRange = sourceRange
        hoveredCodePillRect = pillRect
        isShowingCopiedFeedback = false
        needsDisplay = true
    }

    private func clearHoveredCodeBlock() {
        guard hoveredCodeBlockSourceRange != nil else { return }
        hoveredCodeBlockSourceRange = nil
        isShowingCopiedFeedback = false
        needsDisplay = true
    }

    /// Overlay-drawn only — never inserted into the attributed string, so it cannot affect layout,
    /// selection, wrapping, or exported/printed output (`DocumentExportRenderer` uses its own
    /// `ExportTextView`, a different class, which never installs this pill).
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hoveredCodeBlockSourceRange != nil, dirtyRect.intersects(hoveredCodePillRect) else { return }

        let theme = Theme.theme(for: activeProfile)
        let tint: NSColor = theme.usesDarkChrome ? .white : .black
        let path = NSBezierPath(
            roundedRect: hoveredCodePillRect,
            xRadius: Self.copyPillCornerRadius,
            yRadius: Self.copyPillCornerRadius
        )
        tint.withAlphaComponent(isShowingCopiedFeedback ? 0.18 : 0.12).setFill()
        path.fill()
        tint.withAlphaComponent(0.24).setStroke()
        path.lineWidth = 1
        path.stroke()

        let label = isShowingCopiedFeedback ? "Copied" : "Copy"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: theme.textColor
        ]
        let labelSize = label.size(withAttributes: attributes)
        let labelOrigin = NSPoint(
            x: hoveredCodePillRect.midX - labelSize.width / 2,
            y: hoveredCodePillRect.midY - labelSize.height / 2
        )
        label.draw(at: labelOrigin, withAttributes: attributes)
    }

    /// Copies the hovered code block's raw source (sliced from the retained source markdown, since
    /// `apply(text:profile:)` keeps `renderedText == text`) to the pasteboard and briefly flips the
    /// pill label to "Copied". Read-only — never mutates the document.
    private func copyHoveredCodeBlock() {
        guard
            let sourceRange = hoveredCodeBlockSourceRange,
            let source = renderedText as NSString?,
            NSMaxRange(sourceRange) <= source.length
        else {
            return
        }
        let code = source.substring(with: sourceRange)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)

        isShowingCopiedFeedback = true
        needsDisplay = true
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFeedbackDuration) { [weak self] in
            guard let self, self.copyFeedbackGeneration == generation else { return }
            self.isShowingCopiedFeedback = false
            self.needsDisplay = true
        }
    }

    // MARK: - Checkbox click handling

    override func mouseDown(with event: NSEvent) {
        if hoveredCodeBlockSourceRange != nil {
            let point = convert(event.locationInWindow, from: nil)
            if hoveredCodePillRect.contains(point) {
                copyHoveredCodeBlock()
                return
            }
        }
        if let range = checkboxSourceRange(at: event) {
            onCheckboxToggle(range)
            return
        }
        super.mouseDown(with: event)
    }

    /// The source range of a task checkbox whose glyph the event's point lands on, or nil. Requires
    /// the click to fall inside the glyph's bounding rect (not merely the same line) so clicking
    /// empty space never toggles.
    private func checkboxSourceRange(at event: NSEvent) -> NSRange? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else {
            return nil
        }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y - textContainerInset.height)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < textStorage.length,
              let value = textStorage.attribute(.checkboxSourceRange, at: charIndex, effectiveRange: nil) as? NSValue else {
            return nil
        }
        return value.rangeValue
    }

    // MARK: - "Report this" link handling

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let asURL = link as? URL { url = asURL }
        else if let asString = link as? String { url = URL(string: asString) }
        else { url = nil }
        guard let url, let hash = DiagramReportLink.hash(from: url),
              let pending = reportRegistry.report(for: hash) else {
            return false
        }
        presentReportDialog(source: pending.source, error: pending.error)
        return true
    }

    private func presentReportDialog(source: String, error: String) {
        let alert = NSAlert()
        alert.messageText = "Report rendering issue?"
        alert.informativeText = "The diagram text and error will be sent to the developer to improve rendering."
        alert.addButton(withTitle: "Report")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let version = appVersion
        Task { @MainActor in
            let result = await DiagramReportService.send(source: source, error: error, appVersion: version)
            let done = NSAlert()
            switch result {
            case .sent:
                done.messageText = "Thanks — sent."
            case .failed:
                done.messageText = "Couldn’t send. Saved locally."
                done.informativeText = "The diagram is still recorded in your local diagram log."
            }
            done.addButton(withTitle: "OK")
            done.runModal()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTextContainerLayout()
        updateScrollBoundsObservation()
    }

    private func updateScrollBoundsObservation() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        scheduleVisibleTopRangeReportAfterScroll()
    }

    private func scheduleVisibleTopRangeReportAfterScroll() {
        let selector = #selector(reportVisibleTopRangeAfterScroll)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
        perform(selector, with: nil, afterDelay: Self.visibleTopRangeReportDebounce, inModes: [.common])
    }

    @objc private func reportVisibleTopRangeAfterScroll() {
        guard let sourceRange = sourceRangeAtTopOfViewport() else { return }
        guard !NSEqualRanges(sourceRange, lastReportedVisibleTopRange ?? NSRange(location: NSNotFound, length: 0)) else { return }
        lastReportedVisibleTopRange = sourceRange
        onVisibleTopRangeChanged?(sourceRange)
    }

    /// Returns the source-document range of the heading nearest the top of the viewport, or the
    /// top of the visible rect if no heading is there. The outline sidebar uses this to bold the
    /// active heading in all display modes.
    private func sourceRangeAtTopOfViewport() -> NSRange? {
        guard
            let layoutManager,
            let textContainer,
            let textStorage,
            textStorage.length > 0,
            let scrollView = enclosingScrollView
        else {
            return nil
        }
        var visibleRect = scrollView.contentView.bounds
        visibleRect.origin.x -= textContainerOrigin.x
        visibleRect.origin.y -= textContainerOrigin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        // Prefer the first heading whose rendered text intersects the top of the viewport.
        var headingSourceRange: NSRange?
        textStorage.enumerateAttribute(.headingSourceRange, in: charRange, options: []) { value, _, stop in
            if let value = value as? NSValue {
                headingSourceRange = value.rangeValue
                stop.pointee = true
            }
        }
        if let headingSourceRange {
            return headingSourceRange
        }

        // No heading is on screen (scrolled into a section's body): report the SOURCE range of
        // the most recent heading ABOVE the viewport top. The old code fell back to the rendered
        // `charRange` here, but the outline compares `.location` against SOURCE offsets
        // (OutlineSidebarView.activeItemID), and rendered offsets differ from source offsets
        // (stripped syntax, single-char math/mermaid/image attachments) — so the wrong item was
        // bolded whenever the reader scrolled between headings. Returning nil (before the first
        // heading) simply leaves the previous highlight untouched.
        guard charRange.location > 0 else { return nil }
        var lastHeadingAbove: NSRange?
        textStorage.enumerateAttribute(
            .headingSourceRange,
            in: NSRange(location: 0, length: charRange.location),
            options: []
        ) { value, _, _ in
            if let value = value as? NSValue {
                lastHeadingAbove = value.rangeValue
            }
        }
        return lastHeadingAbove
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        delegate = self
        isRichText = false
        drawsBackground = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        updateTextContainerLayout()
    }

    private func updateTextContainerLayout() {
        let inset = NSSize(
            width: EditorReadingLayout.horizontalInset(forContainerWidth: bounds.width, profile: activeProfile),
            height: 32
        )
        if textContainerInset != inset {
            textContainerInset = inset
        }
        textContainer?.widthTracksTextView = true
    }
}

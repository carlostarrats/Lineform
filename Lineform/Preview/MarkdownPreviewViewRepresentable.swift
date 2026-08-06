import AppKit
import SwiftUI

struct MarkdownPreviewViewRepresentable: NSViewRepresentable {
    var text: String
    var profile: ReadingProfile
    /// Called when the user clicks a rendered task checkbox, with the `NSRange` of its `[ ]`/`[x]`
    /// marker in the source document. The container toggles that span in `document.text`.
    var onCheckboxToggle: (NSRange) -> Void = { _ in }
    /// Called when the user clicks the "Reconnect" pill on a broken/unresolved image placeholder,
    /// with the `NSRange` of the `![alt](path)` syntax in the source document. The container
    /// presents an image `NSOpenPanel` and rewrites that span in `document.text`.
    var onImageReconnect: (NSRange) -> Void = { _ in }
    /// Called when the visible top of the rendered text changes. The range is in rendered-text
    /// coordinates; use `.headingSourceRange` attributes to map headings back to source positions.
    var onVisibleTopRangeChanged: ((NSRange) -> Void)?
    /// The open document's containing folder, used to resolve relative local image paths. `nil`
    /// for an unsaved/untitled document (relative image references stay unresolved).
    var documentDirectory: URL?
    /// A one-shot request (in SOURCE-document coordinates) to scroll the section at/above that
    /// location to the top of the viewport — set by an outline click or a mode-switch position
    /// restore, then cleared. Mirrors the Write-mode editor's `requestedScrollToTopRange`.
    @Binding var requestedScrollToTopRange: NSRange?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = MarkdownPreviewTextView()
        textView.setAccessibilityLabel(String(localized: "Markdown read view"))
        textView.setAccessibilityRole(.textArea)
        textView.onCheckboxToggle = onCheckboxToggle
        textView.onImageReconnect = onImageReconnect
        textView.onVisibleTopRangeChanged = onVisibleTopRangeChanged

        scrollView.documentView = textView
        textView.apply(text: text, profile: profile, documentDirectory: documentDirectory)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownPreviewTextView else {
            return
        }

        // Re-bind the closure each update so it captures the current document binding.
        textView.onCheckboxToggle = onCheckboxToggle
        textView.onImageReconnect = onImageReconnect
        textView.onVisibleTopRangeChanged = onVisibleTopRangeChanged
        textView.apply(text: text, profile: profile, documentDirectory: documentDirectory)

        if let range = requestedScrollToTopRange {
            // A SOURCE range (heading or arbitrary caret position). Do NOT clamp against the
            // rendered `textView.string` length — rendered and source offsets differ. The text
            // view maps it back to a rendered heading itself.
            textView.scrollSourceRangeToTop(range)
            DispatchQueue.main.async {
                requestedScrollToTopRange = nil
            }
        }
    }
}

final class MarkdownPreviewTextView: NSTextView, NSTextViewDelegate {
    /// Set by the representable; invoked with a checkbox's source-marker range on a click that lands
    /// on a rendered checkbox glyph.
    var onCheckboxToggle: (NSRange) -> Void = { _ in }
    /// Set by the representable; invoked with a broken/unresolved image placeholder's
    /// `![alt](path)` source range on a click that lands on its "Reconnect" pill.
    var onImageReconnect: (NSRange) -> Void = { _ in }
    /// Called when the visible character range changes due to scrolling. For Read/Preview mode this
    /// is a range in the rendered text; the receiver maps it back to the source via the
    /// `.headingSourceRange` attribute attached to headings.
    var onVisibleTopRangeChanged: ((NSRange) -> Void)?
    private var activeProfile = ReadingProfile.original
    private var renderedText: String?
    private var renderedProfile: ReadingProfile?
    private var renderedDocumentDirectory: URL?
    private let mermaidProvider = MermaidImageProvider()
    private let mathProvider = MathImageProvider()
    private let imageProvider = ImageAttachmentProvider()
    private let diagramLog = DiagramLogStore()
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
        // A cross-mode scroll restore requested before this view was sized applies now (and wins
        // over the reflow anchor, since it is an explicit move, not a rewrap-preservation).
        applyPendingScrollIfPossible()
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

    /// Scrolls so the source line at or above `sourceRange.location` parks at the top of the
    /// viewport. The argument is in SOURCE-document coordinates; it is mapped back to the rendered
    /// text via the `.sourceSpan` attribute the renderer attaches to every run — so the
    /// restore is exact to the source line, not just the nearest heading. Used for outline jumps in
    /// Read/Preview and for restoring the EXACT reading position across a display-mode switch. If no
    /// tagged run is at or above the target, scrolls to the very top. Never selects text.
    /// Set while a scroll-to-source request is waiting for the view to be laid out. On a display-mode
    /// switch the incoming preview is created and asked to scroll BEFORE it has a real viewport size,
    /// so the first attempt can't stick; it is retried from `setFrameSize`/`viewDidMoveToWindow`
    /// until the view is sized, then cleared.
    private var pendingScrollSourceLocation: Int?

    func scrollSourceRangeToTop(_ sourceRange: NSRange) {
        pendingScrollSourceLocation = sourceRange.location
        applyPendingScrollIfPossible()
    }

    private func applyPendingScrollIfPossible() {
        guard let target = pendingScrollSourceLocation else { return }
        // Need a real viewport size, or a bounds-origin change won't hold through the next layout.
        guard let scrollView = enclosingScrollView, scrollView.contentView.bounds.height > 1, bounds.width > 1 else {
            return
        }
        if performScrollToSourceLine(target, scrollView: scrollView) {
            pendingScrollSourceLocation = nil
        }
    }

    @discardableResult
    private func performScrollToSourceLine(_ target: Int, scrollView: NSScrollView) -> Bool {
        guard
            let layoutManager,
            let textContainer,
            let textStorage,
            textStorage.length > 0
        else {
            return false
        }
        layoutManager.ensureLayout(for: textContainer)

        // Find the rendered run whose SOURCE span starts nearest at/below the target.
        var bestRenderedRange: NSRange?
        var bestSourceLocation = -1
        textStorage.enumerateAttribute(
            .sourceSpan,
            in: NSRange(location: 0, length: textStorage.length),
            options: []
        ) { value, renderedRange, _ in
            guard let value = value as? NSValue else { return }
            let location = value.rangeValue.location
            if location <= target, location > bestSourceLocation {
                bestSourceLocation = location
                bestRenderedRange = renderedRange
            }
        }

        let targetY: CGFloat
        if let bestRenderedRange {
            // Sub-line precision: land at how far into the run the target source offset sits, not the
            // run start (symmetric with the report side). Clamped within the rendered run, so a
            // target inside a multi-line block can't scroll past the block.
            let offsetIntoSource = max(0, target - bestSourceLocation)
            let renderedChar = min(bestRenderedRange.location + offsetIntoSource, NSMaxRange(bestRenderedRange) - 1)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: renderedChar, length: 1),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.y += textContainerOrigin.y
            let topMargin: CGFloat = 8
            targetY = max(0, rect.minY - topMargin)
        } else {
            targetY = 0
        }
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    func apply(text: String, profile: ReadingProfile, documentDirectory: URL? = nil) {
        activeProfile = profile
        let theme = Theme.theme(for: profile)
        backgroundColor = theme.backgroundColor
        updateTextContainerLayout()

        guard
            text != renderedText || profile != renderedProfile || documentDirectory != renderedDocumentDirectory
        else {
            return
        }

        // Set the blanket text color ONLY on the re-render path, right before we replace the
        // storage. `NSTextView.textColor` flattens EVERY per-character foreground attribute, so
        // running it on the no-change early-return path above would wipe the code-syntax colors a
        // beat after they're drawn (SwiftUI calls apply() repeatedly). The rendered attributed
        // string already carries the body ink on every run, so this is only a backstop for any
        // unattributed glyph — and it must never run without a following setAttributedString.
        textColor = theme.textColor

        textStorage?.setAttributedString(
            MarkdownPreviewRenderer().render(
                text,
                profile: profile,
                columnWidth: EditorReadingLayout.textColumnMaxWidth(for: profile),
                mermaidProvider: mermaidProvider,
                mathProvider: mathProvider,
                diagramLog: diagramLog,
                appVersion: appVersion,
                documentDirectory: documentDirectory,
                imageProvider: imageProvider
            )
        )
        renderedText = text
        renderedProfile = profile
        renderedDocumentDirectory = documentDirectory
        // The renderer fits diagrams/equations to the reading column; refit to the current window
        // width so a fresh render on a narrow window doesn't overflow until the next resize.
        refitBlockAttachments()
        // Pills moved with the new content; recompute their pointing-hand cursor rects.
        window?.invalidateCursorRects(for: self)
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
        // Real on-screen viewport height (the scroll view's visible content area), used ONLY to
        // cap block IMAGE height on refit (`ImageFit.maxHeight`). Mermaid/math attachments pass
        // no maxHeight (defaults to `.infinity`) and are therefore unaffected — width-only refit,
        // byte-identical to before this cap existed.
        let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? bounds.height
        let imageMaxHeight = ImageFit.maxHeight(visibleViewportHeight: viewportHeight)
        var didChange = false
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            // Only block diagrams/equations/images are refit; inline math is small, baseline-aligned,
            // and must never be rescaled (that would break its -descent baseline offset).
            guard let attachment = value as? BlockRenderedAttachment, let image = attachment.image else { return }
            guard let newBounds = BlockAttachmentRefit.refittedBounds(
                naturalSize: image.size,
                currentBounds: attachment.bounds,
                fitWidth: fitWidth,
                maxHeight: attachment.appliesViewportHeightCap ? imageMaxHeight : .infinity
            ) else { return }
            attachment.bounds = newBounds
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            didChange = true
        }
        if didChange {
            layoutManager.ensureLayout(for: textContainer)
        }
    }

    // MARK: - Overlay pills — a copy icon on every code block, a Reconnect pill on every broken
    // image. Always visible (not hover-gated); the pill under the cursor draws in a hover state and
    // shows a pointing-hand cursor. Overlay-drawn only — never inserted into the attributed string,
    // so they can't affect layout/selection/wrapping/export (export uses a different text view).

    private enum PreviewPillKind { case copy, reconnect }
    private struct PreviewPill {
        let kind: PreviewPillKind
        let rect: NSRect
        let sourceRange: NSRange
    }

    /// The pill rect under the cursor (drawn in the hover state), or nil.
    private var hoveredPillRect: NSRect?
    /// The rect of the copy pill currently showing its "copied" checkmark, or nil.
    private var copiedFeedbackRect: NSRect?
    private var copyFeedbackGeneration = 0
    private var hoverTrackingArea: NSTrackingArea?

    private static let copyPillSize = NSSize(width: 26, height: 26) // square → drawn as a circle
    private static let pillInset: CGFloat = 8
    private static let pillCornerRadius: CGFloat = 11
    private static let reconnectPillHeight: CGFloat = 22
    private static let reconnectPillVerticalNudge: CGFloat = 6
    private static let reconnectPillGap: CGFloat = 5
    private static let copiedFeedbackDuration: TimeInterval = 1.0
    private static let pillLabelFont = MarkdownFontCascade.applying(to: .systemFont(ofSize: 11, weight: .medium))

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let overPill = pill(at: point) != nil
        if (overPill ? pill(at: point)?.rect : nil) != hoveredPillRect {
            hoveredPillRect = overPill ? pill(at: point)?.rect : nil
            needsDisplay = true
        }
        super.mouseMoved(with: event)
        // Set the cursor AFTER super: NSTextView sets its I-beam programmatically inside
        // super.mouseMoved, so this must run last to win. cursorUpdate covers the stationary case.
        if overPill { NSCursor.arrow.set() }
    }

    /// The pills are buttons, so show a pointing-hand cursor over them. Driven by the tracking
    /// area's `.cursorUpdate` (covers the mouse-stationary-over-pill case; the post-super set in
    /// `mouseMoved` covers the moving case).
    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if pill(at: point) != nil {
            NSCursor.arrow.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredPillRect != nil {
            hoveredPillRect = nil
            needsDisplay = true
        }
        super.mouseExited(with: event)
    }

    /// Every pill currently laid out: one copy pill per `.codeBlockSourceRange` run (top-right of the
    /// block) and one Reconnect pill per `.imageReconnect` placeholder run (trailing it). Enumerating
    /// the two attributes is O(number of blocks) — a handful per document.
    private func previewPills() -> [PreviewPill] {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return [] }
        var pills: [PreviewPill] = []
        let full = NSRange(location: 0, length: textStorage.length)

        textStorage.enumerateAttribute(.codeBlockSourceRange, in: full, options: []) { value, range, _ in
            guard let value = value as? NSValue else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let blockRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let size = Self.copyPillSize
            // Pin the pill to the far-right of the reading column, not the end of the code text:
            // a short code line's glyph bounds end mid-column, so `blockRect.maxX` would sit the
            // pill on top of the code. The container's usable right edge is stable regardless of
            // how long the code line is.
            let columnRightEdge = textContainerOrigin.x + textContainer.size.width - textContainer.lineFragmentPadding
            let rect = NSRect(
                x: columnRightEdge - size.width - Self.pillInset,
                y: blockRect.minY + Self.pillInset,
                width: size.width,
                height: size.height
            )
            pills.append(PreviewPill(kind: .copy, rect: rect, sourceRange: value.rangeValue))
        }

        let reconnectWidth = Self.reconnectPillWidth
        textStorage.enumerateAttribute(.imageReconnect, in: full, options: []) { value, range, _ in
            guard value != nil,
                  let sourceValue = textStorage.attribute(.imageSourceRange, at: range.location, effectiveRange: nil) as? NSValue else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let runRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let rect = NSRect(
                x: runRect.maxX + 8,
                // Nudge down: the placeholder run's line fragment carries leading above the glyph
                // baseline, so a raw midY centering sits the pill visibly high relative to the
                // emoji/text next to it.
                y: runRect.midY - Self.reconnectPillHeight / 2 + Self.reconnectPillVerticalNudge,
                width: reconnectWidth,
                height: Self.reconnectPillHeight
            )
            pills.append(PreviewPill(kind: .reconnect, rect: rect, sourceRange: sourceValue.rangeValue))
        }
        return pills
    }

    /// The pill's drawn label. One constant, because its WIDTH is measured from it — two
    /// literals would let a translation change the text without changing the hit rect.
    static let reconnectPillLabel = String(localized: "Reconnect")

    private static let reconnectPillWidth: CGFloat = {
        let labelWidth = (reconnectPillLabel as NSString).size(withAttributes: [.font: pillLabelFont]).width
        return ceil(labelWidth + reconnectPillGap + 11 + 24) // label + gap + glyph + horizontal padding
    }()

    private func pill(at point: NSPoint) -> PreviewPill? {
        previewPills().first { $0.rect.contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for pill in previewPills() where dirtyRect.intersects(pill.rect) {
            let hovered = hoveredPillRect == pill.rect
            switch pill.kind {
            case .copy:
                drawCopyPill(in: pill.rect, hovered: hovered, showingCopied: copiedFeedbackRect == pill.rect)
            case .reconnect:
                drawReconnectPill(in: pill.rect, hovered: hovered)
            }
        }
    }

    /// A quiet, theme-aware pill background: a light grey in light chrome (lighter still at rest,
    /// brighter on hover), a translucent white in dark chrome.
    private func fillPill(_ rect: NSRect, cornerRadius: CGFloat, hovered: Bool, dark: Bool) {
        let tint: NSColor = dark ? .white : .black
        let restAlpha: CGFloat = dark ? 0.13 : 0.05
        let hoverAlpha: CGFloat = dark ? 0.22 : 0.11
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        tint.withAlphaComponent(hovered ? hoverAlpha : restAlpha).setFill()
        path.fill()
        tint.withAlphaComponent(dark ? 0.22 : 0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawTintedSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            color.set()
            glyph.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }

    private func drawCopyPill(in rect: NSRect, hovered: Bool, showingCopied: Bool) {
        let theme = Theme.theme(for: activeProfile)
        fillPill(rect, cornerRadius: rect.height / 2, hovered: hovered, dark: theme.usesDarkChrome)
        let symbol = showingCopied ? "checkmark" : "doc.on.doc"
        let size = NSSize(width: 13, height: 13)
        drawTintedSymbol(
            symbol,
            in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
            color: theme.textColor.withAlphaComponent(0.85)
        )
    }

    /// The "Reconnect" label with the `arrow.counterclockwise` glyph AFTER it.
    private func drawReconnectPill(in rect: NSRect, hovered: Bool) {
        let theme = Theme.theme(for: activeProfile)
        fillPill(rect, cornerRadius: Self.pillCornerRadius, hovered: hovered, dark: theme.usesDarkChrome)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.pillLabelFont,
            .foregroundColor: theme.textColor.withAlphaComponent(0.85)
        ]
        let label = Self.reconnectPillLabel as NSString
        let labelSize = label.size(withAttributes: attributes)
        let glyphSize = NSSize(width: 11, height: 11)
        let contentWidth = labelSize.width + Self.reconnectPillGap + glyphSize.width
        let startX = rect.midX - contentWidth / 2
        label.draw(at: NSPoint(x: startX, y: rect.midY - labelSize.height / 2), withAttributes: attributes)
        drawTintedSymbol(
            "arrow.counterclockwise",
            in: NSRect(x: startX + labelSize.width + Self.reconnectPillGap, y: rect.midY - glyphSize.height / 2, width: glyphSize.width, height: glyphSize.height),
            color: theme.textColor.withAlphaComponent(0.85)
        )
    }

    /// Copies a code block's raw source (sliced from the retained source markdown, since
    /// `apply(text:profile:)` keeps `renderedText == text`) to the pasteboard and briefly shows a
    /// checkmark on its pill. Read-only — never mutates the document.
    /// Writes a code block's raw source to the general pasteboard. Returns false if the range is
    /// stale (out of bounds), so the accessibility action can report failure. Read-only.
    @discardableResult
    private func copyCodeBlockToPasteboard(sourceRange: NSRange) -> Bool {
        guard
            let source = renderedText as NSString?,
            NSMaxRange(sourceRange) <= source.length
        else {
            return false
        }
        let code = source.substring(with: sourceRange)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        return true
    }

    private func copyCodeBlock(sourceRange: NSRange, pillRect: NSRect) {
        guard copyCodeBlockToPasteboard(sourceRange: sourceRange) else { return }

        copiedFeedbackRect = pillRect
        needsDisplay = true
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFeedbackDuration) { [weak self] in
            guard let self, self.copyFeedbackGeneration == generation else { return }
            self.copiedFeedbackRect = nil
            self.needsDisplay = true
        }
    }

    // MARK: - Checkbox click handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let pill = pill(at: point) {
            switch pill.kind {
            case .copy: copyCodeBlock(sourceRange: pill.sourceRange, pillRect: pill.rect)
            case .reconnect: onImageReconnect(pill.sourceRange)
            }
            return
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

    // MARK: - Accessibility for overlay pills + checkboxes
    //
    // The copy pill, Reconnect pill, and rendered task checkboxes are drawn as overlay geometry and
    // activated only via `mouseDown` hit-testing — invisible and unreachable to VoiceOver / keyboard
    // users. Surface each as a custom action so assistive tech can trigger it (VoiceOver actions
    // rotor). Ranges are captured now and re-validated when invoked, so a stale range is a safe no-op.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let textStorage, textStorage.length > 0 else { return super.accessibilityCustomActions() }
        var actions: [NSAccessibilityCustomAction] = []
        let full = NSRange(location: 0, length: textStorage.length)
        let string = textStorage.string as NSString

        var codeBlockNumber = 0
        textStorage.enumerateAttribute(.codeBlockSourceRange, in: full, options: []) { value, _, _ in
            guard let value = value as? NSValue else { return }
            codeBlockNumber += 1
            let sourceRange = value.rangeValue
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Copy code block \(codeBlockNumber)")) { [weak self] in
                self?.copyCodeBlockToPasteboard(sourceRange: sourceRange) ?? false
            })
        }

        textStorage.enumerateAttribute(.imageReconnect, in: full, options: []) { value, range, _ in
            guard value != nil,
                  let sourceValue = textStorage.attribute(.imageSourceRange, at: range.location, effectiveRange: nil) as? NSValue else { return }
            let sourceRange = sourceValue.rangeValue
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Reconnect image")) { [weak self] in
                self?.onImageReconnect(sourceRange)
                return true
            })
        }

        textStorage.enumerateAttribute(.checkboxSourceRange, in: full, options: []) { value, range, _ in
            guard let value = value as? NSValue else { return }
            let sourceRange = value.rangeValue
            let lineText = string.substring(with: string.lineRange(for: range))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = lineText.isEmpty
                ? String(localized: "Toggle task")
                : String(localized: "Toggle task: \(lineText)")
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                self?.onCheckboxToggle(sourceRange)
                return true
            })
        }

        return actions.isEmpty ? super.accessibilityCustomActions() : actions
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTextContainerLayout()
        updateScrollBoundsObservation()
        // A restore requested before the view had a window/size retries now that it does.
        applyPendingScrollIfPossible()
    }

    deinit {
        // Symmetry with LineformTextView. Selector-based observers are zeroing-weak on modern macOS
        // so this is defensive, not load-bearing; also drop any queued scroll-report perform.
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NSObject.cancelPreviousPerformRequests(withTarget: self)
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

    /// Returns the EXACT source-document offset (as a length-1 range) of the run at the top of the
    /// viewport, read from the `.sourceSpan` attribute the renderer attaches to every run.
    /// This drives two things: the outline sidebar bolds the enclosing heading (its `activeItemID`
    /// maps any source offset to the last heading at/above it, exactly as it already does for Write
    /// mode's exact reporting), and a mode switch restores this exact position rather than the
    /// nearest heading. Returns nil if no tagged run is found (leaves the previous state untouched).
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
        let topChar = min(max(0, charRange.location), textStorage.length - 1)
        guard let info = sourceLineInfo(at: topChar, in: textStorage) else { return nil }
        // Sub-line precision: add how far into the run's RENDERED range the viewport top sits, so a
        // reader parked mid-paragraph restores to that spot in Write, not the paragraph start. The
        // offset is CLAMPED to the run's SOURCE span length, so a position deep inside a multi-line
        // block (blockquote/list/table) stays inside that block instead of overshooting past it
        // (which would mis-restore and bold the wrong outline heading). Exact for plain prose.
        let renderedOffset = max(0, topChar - info.renderedRange.location)
        let clampedOffset = min(renderedOffset, max(0, info.sourceSpan.length - 1))
        return NSRange(location: info.sourceSpan.location + clampedOffset, length: 1)
    }

    /// The `.sourceSpan` value at `charIndex` and the rendered run it belongs to — or, if that exact
    /// run lacks one (rare), the nearest tagged run before it. Walks backward by attribute-run so it
    /// never scans char by char.
    private func sourceLineInfo(at charIndex: Int, in textStorage: NSTextStorage) -> (sourceSpan: NSRange, renderedRange: NSRange)? {
        var index = min(max(0, charIndex), textStorage.length - 1)
        while index >= 0 {
            var effectiveRange = NSRange(location: 0, length: 0)
            if let value = textStorage.attribute(.sourceSpan, at: index, effectiveRange: &effectiveRange) as? NSValue {
                return (value.rangeValue, effectiveRange)
            }
            index = effectiveRange.location - 1
        }
        return nil
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

import LineformCore
import UIKit

/// The iPhone Read view: the Mac's `MarkdownPreviewTextView` on UIKit. A non-editable, selectable
/// TextKit 1 `UITextView` (`init(usingTextLayoutManager: false)`, the same stack as the Mac's),
/// filled by the shared `MarkdownPreviewRenderer` with the real providers.
///
/// - **Renders only when an input changes** (`apply`): the text, the profile, the document's
///   folder, or the display scale, as the Mac's `apply` does. The blanket text colour is set only
///   on that path, right before the storage is replaced, because it would flatten the code
///   colours. Rendering waits until the view is in a window, so every render passes real
///   `RenderDisplayMetrics`: the view's `displayScale` and its window's height.
/// - **A width change** (rotation, a split) keeps the character at the top of the page where it
///   was (the Mac's reflow anchor; a page at the very top stays pinned at the top), refits block
///   diagrams, equations and images (`BlockAttachmentRefit`), and refits table rows.
/// - **Edits only through checkboxes and Reconnect.** A tap inside a task checkbox's glyph calls
///   `onCheckboxToggle` with its `.checkboxSourceRange`; a Reconnect pill calls
///   `onImageReconnect` with the image's `.imageSourceRange`. The Copy pill copies the code body's
///   source to the pasteboard and never edits.
/// - **Tables** are the shared iOS tab-stop rows, with a hairline grid drawn behind them.
/// - **Accessibility:** every pill and checkbox has a mirror custom action, named as on the Mac.
/// - **Position:** `onVisibleTopSourceLocationChanged` reports the source offset at the top of
///   the page 0.08 s after scrolling stops; `scrollSourceLocationToTop` parks a source offset at
///   the top, retrying until the view has a size.
///
/// UIKit can build this class through the `textViewUsingTextLayoutManager:` factory, on which
/// Swift's property initializers never run (see `LineformTextView`). All state with a starting
/// value therefore lives in `State`, behind the one optional stored property.
final class LineformReadView: UITextView {
    /// Top and bottom page inset, the Mac Read view's 32 pt. The sides come from
    /// `EditorReadingLayout`.
    static let verticalInset: CGFloat = 32
    /// The visible-top report waits this long after the last scroll (the Mac's 0.08 s).
    static let visibleTopReportDebounce: TimeInterval = 0.08
    /// Preview renders a text change this long after the last edit (the Mac's preview debounce).
    static let previewTextDelay: TimeInterval = 0.12
    /// How long a Copy pill shows its checkmark (the Mac's 1.0 s).
    static let copiedFeedbackDuration: TimeInterval = 1.0
    /// A scroll-to-source parks the line this far below the top of the page (the Mac's 8 pt).
    static let scrollTopMargin: CGFloat = 8
    /// How far below the exact top the position probe reads (the Mac editor's
    /// `visibleTopProbeInset`); it must exceed `scrollTopMargin`.
    static let visibleTopProbeInset: CGFloat = 14
    /// The grid's ink: the theme ink at this alpha, through `readableInk` at `tableGridMinimumRatio`.
    /// `nonisolated`: Print draws the same grid on the print system's threads.
    nonisolated static let tableGridAlpha: CGFloat = 0.15
    nonisolated static let tableGridMinimumRatio: CGFloat = 1.5

    // MARK: - Stored state

    @MainActor
    final class State {
        var profile: ReadingProfile = .original
        /// What `apply` was last given.
        var desiredText: String?
        var desiredDocumentDirectory: URL?
        /// What the text storage holds now.
        var renderedText: String?
        var renderedProfile: ReadingProfile?
        var renderedDocumentDirectory: URL?
        var renderedScale: CGFloat = 0
        var hasRendered = false
        var lastRenderMetrics: RenderDisplayMetrics?
        /// The column width the table rows' tab stops are placed for.
        var tableTabBasisWidth: CGFloat = 0
        let mermaidProvider = MermaidImageProvider()
        let mathProvider = MathImageProvider()
        let imageProvider = ImageAttachmentProvider()
        let diagramLog = DiagramLogStore()
        var onCheckboxToggle: (NSRange) -> Void = { _ in }
        var onImageReconnect: (NSRange) -> Void = { _ in }
        var onVisibleTopSourceLocationChanged: ((Int) -> Void)?
        var lastReportedVisibleTop: Int?
        var pendingScrollSourceLocation: Int?
        /// An offset set from code while the layout below it may still grow `contentSize`; the
        /// next layout pass sets it once more (UITextView can put a scroll past the laid-out
        /// content back while it grows).
        var pendingContentOffsetY: CGFloat?
        var isHandlingWidthChange = false
        var lastLayoutWidth: CGFloat = 0
        var needsOverlayLayout = true
        var overlayButtons: [ReadOverlayButton] = []
        var copiedSourceRange: NSRange?
        var copyFeedbackGeneration = 0
        var tableGridView: ReadTableGridView?
        var checkboxTap: UITapGestureRecognizer?
        /// Become first responder once in a window (Read was chosen before the view was mounted).
        var wantsFocus = false
        /// Every scroll, for Preview's linked scrolling. Not called for the offset changes a render,
        /// a refit or a width change make on their own.
        var onScroll: ((UIScrollView) -> Void)?
        /// Set while the view moves its own offset for a layout change (no linked-scroll report).
        var isAdjustingLayout = false
        /// Set while an explicit position restore (`scrollSourceLocationToTop`) moves the page,
        /// which Preview's linked scrolling does follow.
        var isRestoringPosition = false
        /// Set from a tap on the status bar until the page reaches the top.
        var isScrollingToTop = false
        /// Called once, after the first render (Preview aligns itself to the editor then).
        var onFirstRender: (() -> Void)?
        /// The undo manager of the editor under Read: the document's one undo history.
        var undoManagerProvider: (() -> UndoManager?)?
        #if DEBUG
        var pasteboardForTesting: UIPasteboard?
        #endif
    }

    private var stateStorage: State?

    var state: State {
        if let stateStorage { return stateStorage }
        let state = State()
        stateStorage = state
        return state
    }

    /// Called with a checkbox's `[ ]`/`[x]` source range when a tap lands inside its glyph.
    var onCheckboxToggle: (NSRange) -> Void {
        get { state.onCheckboxToggle }
        set { state.onCheckboxToggle = newValue }
    }
    /// Called with an image line's source range when its Reconnect pill is tapped.
    var onImageReconnect: (NSRange) -> Void {
        get { state.onImageReconnect }
        set { state.onImageReconnect = newValue }
    }
    /// Called with the source offset at the top of the page, 0.08 s after scrolling stops, when it
    /// changed.
    var onVisibleTopSourceLocationChanged: ((Int) -> Void)? {
        get { state.onVisibleTopSourceLocationChanged }
        set { state.onVisibleTopSourceLocationChanged = newValue }
    }
    /// Every scroll the reader makes, or a position restore (Preview's linked scrolling).
    var onScroll: ((UIScrollView) -> Void)? {
        get { state.onScroll }
        set { state.onScroll = newValue }
    }
    /// The editor's undo manager, so a shake, ⌘Z or a three-finger swipe in Read undoes a
    /// checkbox toggle or a Reconnect, and the typing before it: the editor applied them, and a
    /// document has one undo history in every mode.
    var undoManagerProvider: (() -> UndoManager?)? {
        get { state.undoManagerProvider }
        set { state.undoManagerProvider = newValue }
    }
    /// Called once, after the first render.
    var onFirstRender: (() -> Void)? {
        get { state.onFirstRender }
        set { state.onFirstRender = newValue }
    }
    /// The source text the storage was rendered from; nil before the first render.
    var renderedSourceText: String? { state.renderedText }
    /// The metrics the last render passed to the renderer.
    var lastRenderMetrics: RenderDisplayMetrics? { state.lastRenderMetrics }
    /// The Copy and Reconnect pills, in reading order (Copy pills first, as the attributes are
    /// enumerated).
    var overlayButtons: [ReadOverlayButton] { state.overlayButtons }
    #if DEBUG
    /// Lets a test copy into its own pasteboard, never the user's.
    var pasteboardForTesting: UIPasteboard? {
        get { state.pasteboardForTesting }
        set { state.pasteboardForTesting = newValue }
    }
    #endif

    override var undoManager: UndoManager? {
        state.undoManagerProvider?() ?? super.undoManager
    }

    // MARK: - Undo keys

    /// ⌘Z and ⇧⌘Z while Read has the focus: the editor's undo (a non-editable text view offers no
    /// undo of its own). In Write, and in Preview's editor, the editor answers them itself.
    private static let undoKeyCommands: [UIKeyCommand] = {
        let undo = UIKeyCommand(title: String(localized: "Undo"), action: #selector(undoDocumentEdit(_:)),
                                input: "z", modifierFlags: .command)
        let redo = UIKeyCommand(title: String(localized: "Redo"), action: #selector(redoDocumentEdit(_:)),
                                input: "z", modifierFlags: [.command, .shift])
        undo.wantsPriorityOverSystemBehavior = true
        redo.wantsPriorityOverSystemBehavior = true
        return [undo, redo]
    }()

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + Self.undoKeyCommands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undoDocumentEdit(_:)) { return undoManager?.canUndo ?? false }
        if action == #selector(redoDocumentEdit(_:)) { return undoManager?.canRedo ?? false }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func undoDocumentEdit(_ sender: Any?) {
        guard let undoManager, undoManager.canUndo else { return }
        undoManager.undo()
    }

    @objc func redoDocumentEdit(_ sender: Any?) {
        guard let undoManager, undoManager.canRedo else { return }
        undoManager.redo()
    }

    // MARK: - Making

    /// A configured Read view. Separate from `ReadViewRepresentable.makeUIView` so tests build
    /// one directly.
    static func make(profile: ReadingProfile = .original) -> LineformReadView {
        let view = LineformReadView(usingTextLayoutManager: false)
        view.configure()
        NotificationCenter.default.addObserver(view, selector: #selector(stylingDragDidEnd),
                                               name: StylingDrag.didEndNotification, object: nil)
        view.state.profile = profile
        view.applyChrome()
        return view
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        delegate = self
        dataDetectorTypes = []
        alwaysBounceVertical = true
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        accessibilityLabel = String(localized: "Markdown read view")

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCheckboxTap(_:)))
        addGestureRecognizer(tap)
        state.checkboxTap = tap

        let grid = ReadTableGridView()
        insertSubview(grid, at: 0)
        state.tableGridView = grid

        registerForTraitChanges([UITraitDisplayScale.self]) { (view: LineformReadView, _) in
            view.renderIfNeeded()
        }
    }

    // MARK: - Rendering

    /// Shows `text` rendered for `profile`, resolving relative images against
    /// `documentDirectory`. Renders only when an input changed (or the display scale did); the
    /// render itself waits until the view is in a window, so it always has real metrics.
    ///
    /// With a `textDelay` (Preview: `previewTextDelay`), a change of the text alone renders that
    /// long after the last one, so typing in the editor above does not re-render per keystroke;
    /// any other change renders at once.
    func apply(text: String, profile: ReadingProfile, documentDirectory: URL?, textDelay: TimeInterval = 0) {
        let selector = #selector(renderAfterTextDelay)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
        let onlyTextChanged = state.hasRendered
            && text != state.renderedText
            && profile == state.renderedProfile
            && documentDirectory == state.renderedDocumentDirectory
        let deferredForDrag = StylingDrag.isActive && state.hasRendered && profile != state.renderedProfile
        state.profile = profile
        state.desiredText = text
        state.desiredDocumentDirectory = documentDirectory
        // A Styling slider drag: a render costs over a second on 1 MB, so the newest profile waits
        // for the drag's end (`stylingDragDidEnd`), chrome included (new insets re-lay the text).
        if deferredForDrag { return }
        applyChrome()
        if textDelay > 0, onlyTextChanged {
            perform(selector, with: nil, afterDelay: textDelay, inModes: [.common])
        } else {
            renderIfNeeded()
        }
    }

    @objc private func renderAfterTextDelay() {
        renderIfNeeded()
    }

    @objc func stylingDragDidEnd() {
        applyChrome()
        renderIfNeeded()
    }

    private func applyChrome() {
        let theme = Theme.theme(for: state.profile)
        backgroundColor = theme.backgroundColor
        // On iOS the tint colours the selection.
        tintColor = theme.caretColor
        indicatorStyle = theme.usesDarkChrome ? .white : .black
        updateTextContainerInset()
    }

    /// The display scale renders are drawn for: the view's own `displayScale`.
    private var currentDisplayScale: CGFloat {
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : (window?.screen.scale ?? 1)
    }

    func renderIfNeeded() {
        guard let text = state.desiredText, let window else { return }
        let profile = state.profile
        let directory = state.desiredDocumentDirectory
        let scale = currentDisplayScale
        guard !state.hasRendered
            || text != state.renderedText
            || profile != state.renderedProfile
            || directory != state.renderedDocumentDirectory
            || scale != state.renderedScale
        else { return }

        // A new profile (a font size, a theme) rewraps everything: keep the passage at the top by
        // its SOURCE position, which survives the new storage.
        let sourceAnchor = (state.hasRendered && profile != state.renderedProfile) ? sourceAnchorAtTop() : nil

        let isFirstRender = !state.hasRendered
        state.isAdjustingLayout = true
        defer { state.isAdjustingLayout = false }
        let metrics = RenderDisplayMetrics(scale: scale, visibleViewportHeight: window.bounds.height)
        let columnWidth = renderColumnWidth(for: profile, window: window)
        let rendered = MarkdownPreviewRenderer().render(
            text,
            profile: profile,
            columnWidth: columnWidth,
            mermaidProvider: state.mermaidProvider,
            mathProvider: state.mathProvider,
            diagramLog: state.diagramLog,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            documentDirectory: directory,
            imageProvider: state.imageProvider,
            displayMetrics: metrics
        )
        // Only here, right before the storage is replaced: the blanket colour would flatten the
        // code colours. The rendered string carries the ink on every run; this is a backstop.
        textColor = Theme.theme(for: profile).textColor
        textStorage.setAttributedString(rendered)
        state.renderedText = text
        state.renderedProfile = profile
        state.renderedDocumentDirectory = directory
        state.renderedScale = scale
        state.hasRendered = true
        state.lastRenderMetrics = metrics
        state.tableTabBasisWidth = columnWidth
        state.lastReportedVisibleTop = nil

        updateTextContainerInset()
        refitBlockAttachments()
        refitTableRows()
        if let sourceAnchor { restoreSourceAnchor(sourceAnchor) }
        setNeedsOverlayLayout()
        applyPendingScrollIfPossible()
        if isFirstRender, let onFirstRender = state.onFirstRender {
            // Next turn, once laid out, so the page has its whole content size (an offset past
            // the laid-out content would be clamped short).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.layoutManager.ensureLayout(for: self.textContainer)
                self.layoutIfNeeded()
                onFirstRender()
            }
        }
    }

    /// The column the renderer fits to: the profile's reading column (as on the Mac), but never
    /// wider than the window's longest side, so a Full Width profile still gets real raster and
    /// table sizes. The width-change refit then fits it to the view.
    private func renderColumnWidth(for profile: ReadingProfile, window: UIWindow) -> CGFloat {
        let longestSide = max(window.bounds.width, window.bounds.height, 1)
        return min(EditorReadingLayout.textColumnMaxWidth(for: profile), longestSide)
    }

    /// The profile the on-screen render is laid out for. During a Styling slider drag the newest
    /// profile waits (`apply`), so a layout pass in the meantime (a scroll, a rotation) keeps the
    /// rendered profile's column and fit width instead of re-wrapping the old render at new ones.
    private var layoutProfile: ReadingProfile {
        (StylingDrag.isActive ? state.renderedProfile : nil) ?? state.profile
    }

    private func updateTextContainerInset() {
        let side = EditorReadingLayout.horizontalInset(forContainerWidth: bounds.width, profile: layoutProfile)
        let inset = UIEdgeInsets(top: Self.verticalInset, left: side, bottom: Self.verticalInset, right: side)
        if textContainerInset != inset {
            textContainerInset = inset
        }
    }

    /// Scale block diagrams, equations and images to the view's width, in place, without
    /// re-rendering (the Mac's `refitBlockAttachments`). Inline math is never touched. A block
    /// image's height is also capped to the visible page (`ImageFit.maxHeight`).
    private func refitBlockAttachments() {
        guard textStorage.length > 0, bounds.width > 1 else { return }
        let fitWidth = EditorReadingLayout.blockAttachmentFitWidth(forContainerWidth: bounds.width, profile: layoutProfile)
        let viewportHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        let imageMaxHeight = ImageFit.maxHeight(visibleViewportHeight: viewportHeight > 1 ? viewportHeight : bounds.height)
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let attachment = value as? BlockRenderedAttachment, let image = attachment.image else { return }
            guard let newBounds = BlockAttachmentRefit.refittedBounds(
                naturalSize: image.size,
                currentBounds: attachment.bounds,
                fitWidth: fitWidth,
                maxHeight: attachment.appliesViewportHeightCap ? imageMaxHeight : .infinity
            ) else { return }
            attachment.bounds = newBounds
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    /// Re-place every table row's tab stops for the view's column: the renderer placed them at
    /// `tableTabBasisWidth` (each column's share of that width), so they scale by the ratio.
    private func refitTableRows() {
        guard textStorage.length > 0, bounds.width > 1, state.tableTabBasisWidth > 0 else { return }
        let fitWidth = EditorReadingLayout.blockAttachmentFitWidth(forContainerWidth: bounds.width, profile: layoutProfile)
        guard fitWidth > 0, abs(fitWidth - state.tableTabBasisWidth) > 0.5 else { return }
        let ratio = fitWidth / state.tableTabBasisWidth
        var restyled: [(NSRange, NSParagraphStyle)] = []
        textStorage.enumerateAttribute(.markdownTableRow, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard value != nil,
                  let style = textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let mutable = style.mutableCopy() as? NSMutableParagraphStyle
            else { return }
            mutable.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location * ratio, options: $0.options) }
            restyled.append((range, mutable))
        }
        state.tableTabBasisWidth = fitWidth
        guard !restyled.isEmpty else { return }
        textStorage.beginEditing()
        for (range, style) in restyled {
            textStorage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        textStorage.endEditing()
    }

    // MARK: - Width changes

    override var frame: CGRect {
        get { super.frame }
        set {
            let oldWidth = super.frame.width
            handleWidthChange(from: oldWidth, to: newValue.width) { super.frame = newValue }
        }
    }

    override var bounds: CGRect {
        get { super.bounds }
        set {
            let oldWidth = super.bounds.width
            handleWidthChange(from: oldWidth, to: newValue.width) { super.bounds = newValue }
        }
    }

    /// Captures the reading position BEFORE the width changes (a narrower column rewraps, so the
    /// same offset would show another passage), applies the change, refits, then restores it.
    private func handleWidthChange(from oldWidth: CGFloat, to newWidth: CGFloat, _ change: () -> Void) {
        guard abs(newWidth - oldWidth) > 0.5, stateStorage != nil, !state.isHandlingWidthChange else {
            change()
            return
        }
        state.isHandlingWidthChange = true
        state.isAdjustingLayout = true
        defer {
            state.isHandlingWidthChange = false
            state.isAdjustingLayout = false
        }
        let anchor = reflowAnchor()
        change()
        updateTextContainerInset()
        let containerWidth = max(0, bounds.width - textContainerInset.left - textContainerInset.right)
        if abs(textContainer.size.width - containerWidth) > 0.5 {
            textContainer.size = CGSize(width: containerWidth, height: textContainer.size.height)
        }
        refitBlockAttachments()
        refitTableRows()
        if let anchor { restoreReflowAnchor(anchor) }
        setNeedsOverlayLayout()
        applyPendingScrollIfPossible()
    }

    /// The character at the top of the page and its offset from the page top.
    struct ReflowAnchor {
        let characterIndex: Int
        let offsetFromViewportTop: CGFloat
        /// A page at the very top stays pinned there outright: character-anchoring wobbles by a
        /// line per frame, which at the top reads as bouncing (the Mac's rule).
        let capturedAtTop: Bool
    }

    /// The top of the visible page in view (content) coordinates.
    private var visibleTopY: CGFloat { contentOffset.y + adjustedContentInset.top }
    /// The offset that shows the very top of the page.
    private var topContentOffsetY: CGFloat { -adjustedContentInset.top }

    /// The first character on the page, or nil. `probeInset` reads that far below the exact top.
    private func topCharacterIndex(probeInset: CGFloat = 0) -> Int? {
        guard textStorage.length > 0, bounds.height > 0 else { return nil }
        let visibleHeight = max(1, bounds.height - adjustedContentInset.top - adjustedContentInset.bottom - probeInset)
        let rect = CGRect(
            x: 0,
            y: max(0, visibleTopY + probeInset - textContainerInset.top),
            width: max(1, textContainer.size.width),
            height: visibleHeight
        )
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return min(max(0, characters.location), textStorage.length - 1)
    }

    func reflowAnchor() -> ReflowAnchor? {
        guard let index = topCharacterIndex(), let y = anchorY(forCharacterAt: index) else { return nil }
        return ReflowAnchor(
            characterIndex: index,
            offsetFromViewportTop: y + textContainerInset.top - visibleTopY,
            capturedAtTop: contentOffset.y <= topContentOffsetY + 1
        )
    }

    private func restoreReflowAnchor(_ anchor: ReflowAnchor) {
        guard anchor.characterIndex < textStorage.length else { return }
        if anchor.capturedAtTop {
            setContentOffsetY(topContentOffsetY)
            return
        }
        guard let y = anchorY(forCharacterAt: anchor.characterIndex) else { return }
        let restoredTop = y + textContainerInset.top - anchor.offsetFromViewportTop
        setContentOffsetY(max(topContentOffsetY, restoredTop - adjustedContentInset.top))
    }

    /// The passage at the top by source position, for a re-render.
    private struct SourceAnchor {
        let sourceLocation: Int
        let offsetFromViewportTop: CGFloat
        let capturedAtTop: Bool
    }

    private func sourceAnchorAtTop() -> SourceAnchor? {
        guard let anchor = reflowAnchor(),
              let location = SourcePosition.sourceLocation(atRenderedIndex: anchor.characterIndex, in: textStorage)
        else { return nil }
        return SourceAnchor(sourceLocation: location, offsetFromViewportTop: anchor.offsetFromViewportTop, capturedAtTop: anchor.capturedAtTop)
    }

    private func restoreSourceAnchor(_ anchor: SourceAnchor) {
        if anchor.capturedAtTop {
            setContentOffsetY(topContentOffsetY)
            return
        }
        guard let index = SourcePosition.renderedIndex(forSourceLocation: anchor.sourceLocation, in: textStorage),
              let y = anchorY(forCharacterAt: index)
        else { return }
        let restoredTop = y + textContainerInset.top - anchor.offsetFromViewportTop
        setContentOffsetY(max(topContentOffsetY, restoredTop - adjustedContentInset.top))
    }

    /// The top of `characterIndex`'s glyph in container coordinates, laying out only up to it.
    private func anchorY(forCharacterAt characterIndex: Int) -> CGFloat? {
        guard characterIndex < textStorage.length else { return nil }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: characterIndex + 1))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterIndex, length: 1),
            actualCharacterRange: nil
        )
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).minY
    }

    private func setContentOffsetY(_ y: CGFloat) {
        if abs(contentOffset.y - y) > 0.5 {
            contentOffset = CGPoint(x: contentOffset.x, y: y)
        }
        state.pendingContentOffsetY = y
        // Only the layout passes of this turn may put it back; after that the page belongs to the
        // reader (and to Preview's linked scrolling), and an old target must never pull it back.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state.pendingContentOffsetY == y else { return }
            self.state.pendingContentOffsetY = nil
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        updateTextContainerInset()
        super.layoutSubviews()
        if let pending = state.pendingContentOffsetY {
            state.pendingContentOffsetY = nil
            if abs(contentOffset.y - pending) > 0.5 {
                state.isAdjustingLayout = true
                contentOffset = CGPoint(x: contentOffset.x, y: pending)
                state.isAdjustingLayout = false
            }
        }
        if abs(bounds.width - state.lastLayoutWidth) > 0.5 {
            state.lastLayoutWidth = bounds.width
            state.needsOverlayLayout = true
        }
        if state.needsOverlayLayout {
            state.needsOverlayLayout = false
            layoutOverlays()
        }
        applyPendingScrollIfPossible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, state.wantsFocus {
            state.wantsFocus = false
            // Next tick: a view just mounted by SwiftUI cannot hold first responder yet.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        }
        renderIfNeeded()
        applyPendingScrollIfPossible()
    }

    /// Takes the keyboard focus (so a shake or ⌘Z reaches the document's undo), now or as soon as
    /// the view is in a window. Not editable, so no keyboard appears.
    func takeFocusWhenInWindow() {
        if window != nil {
            becomeFirstResponder()
        } else {
            state.wantsFocus = true
        }
    }

    func setNeedsOverlayLayout() {
        state.needsOverlayLayout = true
        setNeedsLayout()
    }

    // MARK: - Pills

    struct Pill {
        let kind: ReadOverlayButton.Kind
        let rect: CGRect
        let sourceRange: NSRange
    }

    /// Every pill for the current layout, in view (content) coordinates: one Copy pill per
    /// `.codeBlockSourceRange` run, pinned to the column's right edge at the block's top, and one
    /// Reconnect pill per `.imageReconnect` placeholder, after its run (the Mac's geometry).
    func overlayPills() -> [Pill] {
        guard textStorage.length > 0 else { return [] }
        var pills: [Pill] = []
        let full = NSRange(location: 0, length: textStorage.length)
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)

        textStorage.enumerateAttribute(.codeBlockSourceRange, in: full, options: []) { value, range, _ in
            guard let value = value as? NSValue else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let blockRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                .offsetBy(dx: origin.x, dy: origin.y)
            let size = ReadOverlayButton.copyPillSize
            // The column's right edge, not the end of the code: a short line ends mid-column.
            let columnRightEdge = origin.x + textContainer.size.width - textContainer.lineFragmentPadding
            let rect = CGRect(
                x: columnRightEdge - size.width - ReadOverlayButton.pillInset,
                y: blockRect.minY + ReadOverlayButton.pillInset,
                width: size.width,
                height: size.height
            )
            pills.append(Pill(kind: .copy, rect: rect, sourceRange: value.rangeValue))
        }

        textStorage.enumerateAttribute(.imageReconnect, in: full, options: []) { value, range, _ in
            guard value != nil,
                  let sourceValue = textStorage.attribute(.imageSourceRange, at: range.location, effectiveRange: nil) as? NSValue
            else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let runRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                .offsetBy(dx: origin.x, dy: origin.y)
            let rect = Self.reconnectPillRect(after: runRect, columnMinX: origin.x, columnMaxX: origin.x + textContainer.size.width)
            pills.append(Pill(kind: .reconnect, rect: rect, sourceRange: sourceValue.rangeValue))
        }
        return pills
    }

    /// The Reconnect pill for a placeholder run: after the run, as on the Mac, while it fits inside
    /// the reading column; otherwise (a long label on a narrow phone) under the run, 4 pt below
    /// it, at the run's start, never past the column's right edge.
    static func reconnectPillRect(after runRect: CGRect, columnMinX: CGFloat, columnMaxX: CGFloat) -> CGRect {
        let width = ReadOverlayButton.reconnectPillWidth
        let height = ReadOverlayButton.reconnectPillHeight
        let afterX = runRect.maxX + ReadOverlayButton.reconnectPillLeadingGap
        if afterX + width <= columnMaxX {
            return CGRect(
                x: afterX,
                y: runRect.midY - height / 2 + ReadOverlayButton.reconnectPillVerticalNudge,
                width: width,
                height: height
            )
        }
        let x = max(columnMinX, min(runRect.minX, columnMaxX - width))
        return CGRect(x: x, y: runRect.maxY + 4, width: width, height: height)
    }

    /// Places the pills and redraws the table grid for the current layout. Pills are subviews in
    /// content coordinates, so a scroll needs no work; this runs after a render, a refit, a width
    /// change or a profile change.
    func layoutOverlays() {
        let pills = overlayPills()
        let theme = Theme.theme(for: state.profile)
        var reusable = state.overlayButtons
        var placed: [ReadOverlayButton] = []
        var codeBlockNumber = 0
        for pill in pills {
            let button: ReadOverlayButton
            if let index = reusable.firstIndex(where: { $0.kind == pill.kind }) {
                button = reusable.remove(at: index)
            } else {
                button = ReadOverlayButton(kind: pill.kind, sourceRange: pill.sourceRange)
                button.addTarget(self, action: #selector(overlayButtonTapped(_:)), for: .touchUpInside)
                addSubview(button)
            }
            button.sourceRange = pill.sourceRange
            if pill.kind == .copy {
                codeBlockNumber += 1
                button.codeBlockNumber = codeBlockNumber
                button.isShowingCopied = state.copiedSourceRange.map { NSEqualRanges($0, pill.sourceRange) } ?? false
            }
            button.apply(theme: theme)
            button.frame = pill.rect
            bringSubviewToFront(button)
            placed.append(button)
        }
        for leftover in reusable {
            leftover.removeFromSuperview()
        }
        state.overlayButtons = placed
        layoutTableGrid(theme: theme)
    }

    @objc private func overlayButtonTapped(_ button: ReadOverlayButton) {
        switch button.kind {
        case .copy: copyCodeBlockShowingFeedback(button)
        case .reconnect: onImageReconnect(button.sourceRange)
        }
    }

    private var pasteboard: UIPasteboard {
        #if DEBUG
        if let pasteboardForTesting { return pasteboardForTesting }
        #endif
        return UIPasteboard.general
    }

    /// Copies a code block's source (sliced from the source this view rendered) to the
    /// pasteboard. False, and nothing copied, when the range is stale. Never edits.
    @discardableResult
    func copyCodeBlock(sourceRange: NSRange) -> Bool {
        guard let source = state.renderedText as NSString?,
              sourceRange.location >= 0,
              NSMaxRange(sourceRange) <= source.length
        else { return false }
        pasteboard.string = source.substring(with: sourceRange)
        return true
    }

    private func copyCodeBlockShowingFeedback(_ button: ReadOverlayButton) {
        guard copyCodeBlock(sourceRange: button.sourceRange) else { return }
        state.copiedSourceRange = button.sourceRange
        button.isShowingCopied = true
        state.copyFeedbackGeneration += 1
        let generation = state.copyFeedbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFeedbackDuration) { [weak self] in
            guard let self, self.state.copyFeedbackGeneration == generation else { return }
            self.state.copiedSourceRange = nil
            for button in self.state.overlayButtons where button.kind == .copy {
                button.isShowingCopied = false
            }
        }
    }

    // MARK: - Checkboxes

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === state.checkboxTap {
            return checkboxSourceRange(at: gestureRecognizer.location(in: self)) != nil
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleCheckboxTap(_ recognizer: UITapGestureRecognizer) {
        activateCheckbox(at: recognizer.location(in: self))
    }

    /// The tap's work: toggles the checkbox whose glyph contains `point` (view coordinates).
    /// Returns false, and does nothing, anywhere else.
    @discardableResult
    func activateCheckbox(at point: CGPoint) -> Bool {
        guard let range = checkboxSourceRange(at: point) else { return false }
        onCheckboxToggle(range)
        return true
    }

    /// The source range of the task checkbox whose glyph `point` lands inside, or nil. The point
    /// must fall inside the glyph's own rect, not merely on its line, so a tap in empty space never
    /// toggles (the Mac's rule).
    func checkboxSourceRange(at point: CGPoint) -> NSRange? {
        guard textStorage.length > 0 else { return nil }
        let containerPoint = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length,
              let value = textStorage.attribute(.checkboxSourceRange, at: characterIndex, effectiveRange: nil) as? NSValue
        else { return nil }
        return value.rangeValue
    }

    /// The rect of the checkbox glyph for `sourceRange`, in view coordinates (tests aim taps).
    func checkboxGlyphRect(forSourceRange sourceRange: NSRange) -> CGRect? {
        var found: CGRect?
        textStorage.enumerateAttribute(.checkboxSourceRange, in: NSRange(location: 0, length: textStorage.length)) { value, range, stop in
            guard let value = value as? NSValue, NSEqualRanges(value.rangeValue, sourceRange) else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            found = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
            stop.pointee = true
        }
        return found
    }

    // MARK: - Accessibility

    /// The pills and checkboxes as custom actions, named as on the Mac. Each range is captured
    /// now and checked again when invoked, so a stale one is a safe no-op.
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let actions = readAccessibilityActions()
            return actions + (super.accessibilityCustomActions ?? [])
        }
        set { super.accessibilityCustomActions = newValue }
    }

    func readAccessibilityActions() -> [UIAccessibilityCustomAction] {
        guard textStorage.length > 0 else { return [] }
        var actions: [UIAccessibilityCustomAction] = []
        let full = NSRange(location: 0, length: textStorage.length)
        let string = textStorage.string as NSString

        var codeBlockNumber = 0
        textStorage.enumerateAttribute(.codeBlockSourceRange, in: full, options: []) { value, _, _ in
            guard let value = value as? NSValue else { return }
            codeBlockNumber += 1
            let sourceRange = value.rangeValue
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Copy code block \(codeBlockNumber)")) { [weak self] _ in
                self?.copyCodeBlock(sourceRange: sourceRange) ?? false
            })
        }

        textStorage.enumerateAttribute(.imageReconnect, in: full, options: []) { value, range, _ in
            guard value != nil,
                  let sourceValue = textStorage.attribute(.imageSourceRange, at: range.location, effectiveRange: nil) as? NSValue
            else { return }
            let sourceRange = sourceValue.rangeValue
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Reconnect image")) { [weak self] _ in
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
            actions.append(UIAccessibilityCustomAction(name: name) { [weak self] _ in
                self?.onCheckboxToggle(sourceRange)
                return true
            })
        }
        return actions
    }

    // MARK: - Position

    /// The source offset of the first line at the top of the page, or nil. Read 14 pt below the
    /// exact top, the Mac editor's `visibleTopProbeInset`: a line parked 8 pt below the top (a
    /// scroll to a source location) is the one found, not the sliver of the line above it, so a
    /// Write → Read → Write round trip never drifts up a line.
    func sourceLocationAtTopOfViewport() -> Int? {
        guard let index = topCharacterIndex(probeInset: Self.visibleTopProbeInset) else { return nil }
        return SourcePosition.sourceLocation(atRenderedIndex: index, in: textStorage)
    }

    fileprivate func scheduleVisibleTopReport() {
        let selector = #selector(reportVisibleTop)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
        perform(selector, with: nil, afterDelay: Self.visibleTopReportDebounce, inModes: [.common])
    }

    @objc private func reportVisibleTop() {
        guard let location = sourceLocationAtTopOfViewport(), location != state.lastReportedVisibleTop else { return }
        state.lastReportedVisibleTop = location
        onVisibleTopSourceLocationChanged?(location)
    }

    /// Parks the source line at or above `location` at the top of the page (8 pt below it, as on
    /// the Mac), with sub-line precision. Before the view has a size or a render, the request
    /// waits and is retried from layout. Never selects text.
    func scrollSourceLocationToTop(_ location: Int) {
        state.pendingScrollSourceLocation = location
        applyPendingScrollIfPossible()
    }

    private func applyPendingScrollIfPossible() {
        guard let target = state.pendingScrollSourceLocation,
              state.hasRendered,
              window != nil,
              bounds.width > 1,
              bounds.height > 1
        else { return }
        state.pendingScrollSourceLocation = nil
        state.isRestoringPosition = true
        defer { state.isRestoringPosition = false }
        performScrollToSourceLocation(target)
    }

    private func performScrollToSourceLocation(_ target: Int) {
        guard textStorage.length > 0 else {
            setContentOffsetY(topContentOffsetY)
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let targetTop: CGFloat
        if let renderedIndex = SourcePosition.renderedIndex(forSourceLocation: target, in: textStorage) {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: renderedIndex, length: 1),
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            targetTop = max(0, rect.minY + textContainerInset.top - Self.scrollTopMargin)
        } else {
            targetTop = 0
        }
        // Never past the end of the laid-out page (the Mac's clip view clamps the same way).
        let contentHeight = layoutManager.usedRect(for: textContainer).height + textContainerInset.top + textContainerInset.bottom
        let maximumY = max(topContentOffsetY, contentHeight + adjustedContentInset.bottom - bounds.height)
        setContentOffsetY(min(max(topContentOffsetY, targetTop - adjustedContentInset.top), maximumY))
    }

    // MARK: - Table grid

    /// A hairline grid behind the table rows (`.markdownTableRow`): a line above the header, one
    /// under every row, and a line at each column edge given by the rows' tab stops, in the theme
    /// ink at 0.15 through `readableInk` (ratio 1.5).
    private func layoutTableGrid(theme: Theme) {
        guard let grid = state.tableGridView else { return }
        sendSubviewToBack(grid)
        let ink = theme.readableInk(theme.textColor.withAlphaComponent(Self.tableGridAlpha), minimumRatio: Self.tableGridMinimumRatio)
        let lineWidth = 1 / max(1, currentDisplayScale)
        grid.shapeLayer.strokeColor = ink.cgColor
        grid.shapeLayer.lineWidth = lineWidth
        grid.shapeLayer.fillColor = nil
        let path = tableGridPath()
        let height = max(contentSize.height, bounds.height, path.bounds.maxY + 1)
        grid.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: height)
        grid.shapeLayer.path = path.isEmpty ? nil : path.cgPath
    }

    /// The table rows as (row index, character range), in order.
    private func tableRows() -> [(index: Int, range: NSRange)] {
        guard textStorage.length > 0 else { return [] }
        var rows: [(Int, NSRange)] = []
        textStorage.enumerateAttribute(.markdownTableRow, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let number = value as? NSNumber else { return }
            rows.append((number.intValue, range))
        }
        return rows
    }

    /// The grid's lines, in view coordinates.
    func tableGridPath() -> UIBezierPath {
        let path = UIBezierPath()
        let rows = tableRows()
        guard !rows.isEmpty else { return path }
        let originX = textContainerInset.left
        let originY = textContainerInset.top
        // The width the rows' stops were placed for (`blockAttachmentFitWidth` once refitted):
        // the row lines end there, and the column edges are its shares.
        let fitWidth = state.tableTabBasisWidth > 0 ? state.tableTabBasisWidth : textContainer.size.width

        // Split into tables: a row index of 0 (the header) starts a new one.
        var tables: [[NSRange]] = []
        for row in rows {
            if row.index == 0 || tables.isEmpty {
                tables.append([row.range])
            } else {
                tables[tables.count - 1].append(row.range)
            }
        }

        for table in tables {
            var rowTops: [CGFloat] = []
            var bottom: CGFloat = 0
            for range in table {
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let last = layoutManager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
                rowTops.append(first.minY + originY)
                bottom = last.maxY + originY
            }
            guard let top = rowTops.first else { continue }
            for y in rowTops + [bottom] {
                path.move(to: CGPoint(x: originX, y: y))
                path.addLine(to: CGPoint(x: originX + fitWidth, y: y))
            }
            if let first = table.first,
               let fractions = textStorage.attribute(.markdownTableColumnFractions, at: first.location, effectiveRange: nil) as? [NSNumber] {
                for x in Self.columnEdges(fractions: fractions.map { CGFloat($0.doubleValue) }, fitWidth: fitWidth) {
                    path.move(to: CGPoint(x: originX + x, y: top))
                    path.addLine(to: CGPoint(x: originX + x, y: bottom))
                }
            }
        }
        return path
    }

    /// The inner column edges: the running sum of the renderer's column fractions
    /// (`fitColumnPercentages`, the numbers the tab stops are placed with) times the fit width. A
    /// column's edge is where its share ends, whatever its alignment, so a long right-aligned cell
    /// after a centred column never has a line through it.
    nonisolated static func columnEdges(fractions: [CGFloat], fitWidth: CGFloat) -> [CGFloat] {
        guard fractions.count > 1 else { return [] }
        var edges: [CGFloat] = []
        var running: CGFloat = 0
        for fraction in fractions.dropLast() {
            running += fraction
            edges.append(running * fitWidth)
        }
        return edges
    }
}

// MARK: - Scrolling

extension LineformReadView: UITextViewDelegate {
    /// Only the reader's own scrolling (a drag, its deceleration, a tap on the status bar) and an
    /// explicit position restore reach Preview's linked scrolling. An offset UIKit or a layout pass
    /// changes (content growing, a render, a refit) never drives the editor.
    var forwardsScrollToLink: Bool {
        guard !state.isAdjustingLayout else { return false }
        return isTracking || isDragging || isDecelerating || state.isRestoringPosition || state.isScrollingToTop
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scheduleVisibleTopReport()
        if forwardsScrollToLink { state.onScroll?(scrollView) }
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        state.isScrollingToTop = true
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        state.isScrollingToTop = false
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        state.isScrollingToTop = false
    }
}

/// The table grid's layer: the lowest subview of the Read view, behind the text, never touched.
final class ReadTableGridView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReadTableGridView is made in code")
    }
}

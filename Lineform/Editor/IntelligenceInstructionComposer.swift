import SwiftUI

struct IntelligenceInstructionComposer: View {
    @Binding var instruction: String
    let isActionEnabled: Bool
    var isLoading = false
    var usesDarkChrome = false
    var reduceMotion = false
    var allowsAutomaticFocus = true
    let onFocusChanged: (Bool) -> Void
    let submitInstruction: (String) -> Void

    var body: some View {
        IntelligenceInstructionComposerOverlayHost(
            instruction: $instruction,
            isActionEnabled: isActionEnabled,
            isLoading: isLoading,
            usesDarkChrome: usesDarkChrome,
            reduceMotion: reduceMotion,
            allowsAutomaticFocus: allowsAutomaticFocus,
            onFocusChanged: onFocusChanged,
            submitInstruction: submitInstruction
        )
    }
}

struct IntelligenceInstructionComposerOverlayHost: NSViewRepresentable {
    @Binding var instruction: String
    let isActionEnabled: Bool
    let isLoading: Bool
    let usesDarkChrome: Bool
    let reduceMotion: Bool
    let allowsAutomaticFocus: Bool
    let onFocusChanged: (Bool) -> Void
    let submitInstruction: (String) -> Void

    func makeNSView(context: Context) -> IntelligenceInstructionComposerOverlayNSView {
        IntelligenceInstructionComposerOverlayNSView(
            instruction: instruction,
            isActionEnabled: isActionEnabled,
            isLoading: isLoading,
            usesDarkChrome: usesDarkChrome,
            reduceMotion: reduceMotion,
            allowsAutomaticFocus: allowsAutomaticFocus,
            textChanged: { instruction = $0 },
            onFocusChanged: onFocusChanged,
            submitInstruction: submitInstruction
        )
    }

    func updateNSView(_ nsView: IntelligenceInstructionComposerOverlayNSView, context: Context) {
        nsView.update(
            instruction: instruction,
            isActionEnabled: isActionEnabled,
            isLoading: isLoading,
            usesDarkChrome: usesDarkChrome,
            reduceMotion: reduceMotion,
            allowsAutomaticFocus: allowsAutomaticFocus,
            textChanged: { instruction = $0 },
            onFocusChanged: onFocusChanged,
            submitInstruction: submitInstruction
        )
    }
}

final class IntelligenceInstructionComposerOverlayNSView: NSView {
    private let composerView: IntelligenceInstructionComposerNSView

    init(
        instruction: String,
        isActionEnabled: Bool,
        isLoading: Bool = false,
        usesDarkChrome: Bool,
        reduceMotion: Bool,
        allowsAutomaticFocus: Bool = true,
        textChanged: @escaping (String) -> Void,
        onFocusChanged: @escaping (Bool) -> Void,
        submitInstruction: @escaping (String) -> Void
    ) {
        composerView = IntelligenceInstructionComposerNSView(
            instruction: instruction,
            isActionEnabled: isActionEnabled,
            isLoading: isLoading,
            usesDarkChrome: usesDarkChrome,
            reduceMotion: reduceMotion,
            allowsAutomaticFocus: allowsAutomaticFocus,
            textChanged: textChanged,
            onFocusChanged: onFocusChanged,
            submitInstruction: submitInstruction
        )
        super.init(frame: .zero)
        addSubview(composerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var isFlipped: Bool {
        true
    }

    func update(
        instruction: String,
        isActionEnabled: Bool,
        isLoading: Bool = false,
        usesDarkChrome: Bool = false,
        reduceMotion: Bool = false,
        allowsAutomaticFocus: Bool = true,
        textChanged: @escaping (String) -> Void,
        onFocusChanged: @escaping (Bool) -> Void,
        submitInstruction: @escaping (String) -> Void
    ) {
        composerView.update(
            instruction: instruction,
            isActionEnabled: isActionEnabled,
            isLoading: isLoading,
            usesDarkChrome: usesDarkChrome,
            reduceMotion: reduceMotion,
            allowsAutomaticFocus: allowsAutomaticFocus,
            textChanged: textChanged,
            onFocusChanged: onFocusChanged,
            submitInstruction: submitInstruction
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let width = min(
            IntelligenceInstructionComposerPresentation.maximumWidth,
            max(0, bounds.width - 48)
        )
        composerView.frame = NSRect(
            x: (bounds.width - width) / 2,
            y: max(0, bounds.height - IntelligenceActionRailPresentation.bottomInset - IntelligenceInstructionComposerPresentation.height),
            width: width,
            height: IntelligenceInstructionComposerPresentation.height
        )
        composerView.layoutSubtreeIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let composerPoint = convert(point, to: composerView)
        return composerView.hitTest(composerPoint)
    }
}

final class IntelligenceInstructionComposerNSView: NSView {
    private let textView = IntelligenceInstructionTextView()
    private let submitButton: IntelligenceInstructionSubmitButtonNSView
    private let loadingSkeletonView = IntelligenceInstructionLoadingSkeletonNSView()
    private var textChanged: (String) -> Void
    private var onFocusChanged: (Bool) -> Void
    private var submitInstruction: (String) -> Void
    private var mouseDownMonitor: LocalEventMonitor?
    private var usesDarkChrome: Bool
    private var allowsAutomaticFocus: Bool
    private var reduceMotion: Bool {
        didSet {
            applyLoadingState()
        }
    }
    private var isLoading: Bool {
        didSet {
            applyLoadingState()
        }
    }
    private var isInputFocused = false {
        didSet {
            needsDisplay = true
        }
    }
    private var hasExplicitInputInteraction = false {
        didSet {
            needsDisplay = true
        }
    }

    init(
        instruction: String,
        isActionEnabled: Bool,
        isLoading: Bool = false,
        usesDarkChrome: Bool = false,
        reduceMotion: Bool = false,
        allowsAutomaticFocus: Bool = true,
        textChanged: @escaping (String) -> Void,
        onFocusChanged: @escaping (Bool) -> Void,
        submitInstruction: @escaping (String) -> Void
    ) {
        self.textChanged = textChanged
        self.onFocusChanged = onFocusChanged
        self.submitInstruction = submitInstruction
        self.usesDarkChrome = usesDarkChrome
        self.allowsAutomaticFocus = allowsAutomaticFocus
        self.reduceMotion = reduceMotion
        self.isLoading = isLoading
        submitButton = IntelligenceInstructionSubmitButtonNSView(
            isActionEnabled: isActionEnabled,
            usesDarkChrome: usesDarkChrome,
            performAction: {}
        )
        super.init(frame: .zero)
        configureTextView()
        configureLoadingViews()
        configureTextViewCallbacks()
        textView.string = instruction
        submitButton.performAction = { [weak self] in
            self?.submitIfReady()
        }
        addSubview(textView)
        addSubview(submitButton)
        addSubview(loadingSkeletonView)
        wantsLayer = true
        applyLoadingState()
        updateLayerShadow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    func update(
        instruction: String,
        isActionEnabled: Bool,
        isLoading: Bool = false,
        usesDarkChrome: Bool = false,
        reduceMotion: Bool = false,
        allowsAutomaticFocus: Bool = true,
        textChanged: @escaping (String) -> Void,
        onFocusChanged: @escaping (Bool) -> Void,
        submitInstruction: @escaping (String) -> Void
    ) {
        self.textChanged = textChanged
        self.onFocusChanged = onFocusChanged
        self.submitInstruction = submitInstruction
        self.allowsAutomaticFocus = allowsAutomaticFocus
        if self.usesDarkChrome != usesDarkChrome {
            self.usesDarkChrome = usesDarkChrome
            applyAppearanceStyling()
        }
        if self.reduceMotion != reduceMotion {
            self.reduceMotion = reduceMotion
        }
        self.isLoading = isLoading
        submitButton.isActionEnabled = isActionEnabled
        submitButton.usesDarkChrome = usesDarkChrome
        configureTextViewCallbacks()
        yieldFocusIfAutomaticFocusIsDisabled()
        if window?.firstResponder !== textView && textView.string != instruction {
            textView.string = instruction
            textView.needsDisplay = true
        }
        submitButton.performAction = { [weak self] in
            self?.submitIfReady()
        }
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateLayerShadow()

        let horizontalPadding = IntelligenceInstructionComposerPresentation.horizontalPadding
        let sparklesWidth: CGFloat = 20
        let buttonSize = IntelligenceInstructionComposerPresentation.sendButtonSize
        let controlHeight: CGFloat = 24
        let centerY = bounds.midY
        submitButton.frame = NSRect(
            x: bounds.width - horizontalPadding - buttonSize,
            y: centerY - buttonSize / 2,
            width: buttonSize,
            height: buttonSize
        )
        textView.frame = NSRect(
            x: horizontalPadding + sparklesWidth + 10,
            y: centerY - controlHeight / 2,
            width: max(0, bounds.width - horizontalPadding * 2 - sparklesWidth - 20 - buttonSize),
            height: controlHeight
        )
        let loadingInset = IntelligenceInstructionComposerPresentation.loadingSkeletonCapsuleInset
        loadingSkeletonView.frame = bounds.insetBy(dx: loadingInset, dy: loadingInset)
        registerHitTestRegion()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        registerHitTestRegion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        registerHitTestRegion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearanceStyling()
        registerHitTestRegion()
        if window == nil {
            removeMouseDownMonitor()
            EditorFloatingControlHitTestRegistry.remove(owner: self)
        } else {
            installMouseDownMonitorIfNeeded()
            focusTextViewAutomaticallyIfAllowed()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceStyling()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard !isLoading else { return self }

        let submitPoint = convert(point, to: submitButton)
        if let submitHit = submitButton.hitTest(submitPoint) {
            return submitHit
        }

        if textView.frame.contains(point) {
            return textView
        }

        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        if !isLoading {
            addCursorRect(textView.frame, cursor: .iBeam)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard !isLoading else { return }

        let point = convert(event.locationInWindow, from: nil)
        if textView.frame.contains(point) {
            NSCursor.iBeam.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLoading else { return }

        let point = convert(event.locationInWindow, from: nil)
        guard !submitButton.frame.contains(point) else {
            super.mouseDown(with: event)
            return
        }

        focusTextView(insertingAt: event.locationInWindow, showingOutline: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: IntelligenceInstructionComposerPresentation.cornerRadius,
            yRadius: IntelligenceInstructionComposerPresentation.cornerRadius
        )
        let backgroundColor = isLoading
            ? IntelligenceInstructionComposerPresentation.loadingBackgroundColor(usesDarkAppearance: usesDarkChrome)
            : IntelligenceInstructionComposerPresentation.backgroundColor(usesDarkAppearance: usesDarkChrome)
        backgroundColor.setFill()
        path.fill()

        if !isLoading && IntelligenceInstructionComposerPresentation.drawsInputBorder(
            usesDarkAppearance: usesDarkChrome,
            isFocused: isInputFocused,
            hasExplicitInputInteraction: hasExplicitInputInteraction
        ) {
            let borderColor = IntelligenceInstructionComposerPresentation.borderColor(
                usesDarkAppearance: usesDarkChrome,
                isFocused: isInputFocused
            )
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        if !isLoading {
            drawSparkles()
        }
    }

    deinit {
        EditorFloatingControlHitTestRegistry.remove(owner: self)
    }

    private func configureTextView() {
        textView.placeholder = IntelligenceInstructionComposerPresentation.prompt
        textView.font = .systemFont(ofSize: 15, weight: .regular)
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.setAccessibilityLabel(IntelligenceInstructionComposerPresentation.inputAccessibilityLabel)
        textView.setAccessibilityHelp(IntelligenceInstructionComposerPresentation.inputAccessibilityHelp)
        applyAppearanceStyling()
    }

    private func configureLoadingViews() {
        loadingSkeletonView.isHidden = true
        loadingSkeletonView.usesDarkChrome = usesDarkChrome
    }

    private func configureTextViewCallbacks() {
        textView.onTextChanged = { [weak self] text in
            self?.textChanged(text)
        }
        textView.onFocusChanged = { [weak self] isFocused in
            guard let self else { return }
            isInputFocused = isFocused
            if !isFocused {
                hasExplicitInputInteraction = false
            }
            onFocusChanged(isFocused)
        }
        textView.onSubmit = { [weak self] in
            self?.submitIfReady()
        }
    }

    private func focusTextViewAutomaticallyIfAllowed() {
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                self.window != nil,
                self.shouldAutomaticallyFocusTextView()
            else {
                return
            }
            self.focusTextView()
        }
    }

    private func shouldAutomaticallyFocusTextView() -> Bool {
        guard !isLoading, allowsAutomaticFocus else {
            return false
        }

        guard let firstResponder = window?.firstResponder else {
            return true
        }

        if firstResponder === textView {
            return false
        }

        return firstResponder is LineformTextView
    }

    private func yieldFocusIfAutomaticFocusIsDisabled() {
        guard !allowsAutomaticFocus, window?.firstResponder === textView else {
            return
        }

        isInputFocused = false
        onFocusChanged(false)
        window?.makeFirstResponder(nil)
    }

    private func submitIfReady() {
        guard !isLoading else { return }

        let trimmedInstruction = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard submitButton.isActionEnabled, !trimmedInstruction.isEmpty else {
            return
        }

        textView.string = ""
        textView.needsDisplay = true
        textChanged("")
        submitInstruction(trimmedInstruction)
    }

    private func focusTextView(showingOutline: Bool = false) {
        guard !isLoading else { return }

        if showingOutline {
            hasExplicitInputInteraction = true
        }
        isInputFocused = true
        onFocusChanged(true)
        window?.makeFirstResponder(textView)
    }

    private func focusTextView(insertingAt windowPoint: NSPoint?, showingOutline: Bool = false) {
        guard !isLoading else { return }

        focusTextView(showingOutline: showingOutline)
        guard let windowPoint else { return }

        let point = convert(windowPoint, from: nil)
        if textView.frame.contains(point) {
            let textViewPoint = textView.convert(windowPoint, from: nil)
            textView.setSelectedRange(NSRange(location: textView.characterIndexForInsertion(at: textViewPoint), length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
    }

    private func installMouseDownMonitorIfNeeded() {
        guard mouseDownMonitor == nil else { return }

        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            guard
                let self,
                let window = self.window,
                event.window === window
            else {
                return event
            }

            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else {
                if self.focusEditorForMouseDownIfNeeded(event, in: window) {
                    return nil
                }
                return event
            }

            guard !self.isLoading else {
                return nil
            }

            if self.submitButton.frame.contains(point) {
                self.submitIfReady()
            } else if self.textView.frame.contains(point) {
                self.hasExplicitInputInteraction = true
                self.textView.handleMouseDown(with: event)
            } else {
                self.focusTextView(insertingAt: event.locationInWindow, showingOutline: true)
            }
            return nil
        }) else { return }
        mouseDownMonitor = LocalEventMonitor(monitor)
    }

    private func focusEditorForMouseDownIfNeeded(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard window.firstResponder === textView else {
            return false
        }

        guard !EditorFloatingControlHitTestRegistry.contains(windowPoint: event.locationInWindow, in: window) else {
            return false
        }

        guard
            let contentView = window.contentView,
            let editorTextView = Self.lineformTextView(at: event.locationInWindow, in: contentView)
        else {
            return false
        }

        guard editorTextView.selectedRange().length > 0 else {
            return false
        }

        guard
            window.makeFirstResponder(editorTextView),
            window.firstResponder === editorTextView
        else {
            return false
        }

        editorTextView.needsDisplay = true
        return true
    }

    private static func lineformTextView(at windowPoint: NSPoint, in view: NSView) -> LineformTextView? {
        for subview in view.subviews.reversed() {
            if let match = lineformTextView(at: windowPoint, in: subview) {
                return match
            }
        }

        guard let textView = view as? LineformTextView else {
            return nil
        }

        let localPoint = textView.convert(windowPoint, from: nil)
        return textView.bounds.contains(localPoint) ? textView : nil
    }

    private func removeMouseDownMonitor() {
        mouseDownMonitor?.remove()
        mouseDownMonitor = nil
    }

    private func applyAppearanceStyling() {
        textView.usesDarkChrome = usesDarkChrome
        textView.textColor = IntelligenceInstructionComposerPresentation.foregroundColor(
            usesDarkAppearance: usesDarkChrome
        )
        textView.insertionPointColor = IntelligenceInstructionComposerPresentation.insertionPointColor(
            usesDarkAppearance: usesDarkChrome
        )
        submitButton.usesDarkChrome = usesDarkChrome
        loadingSkeletonView.usesDarkChrome = usesDarkChrome
        textView.needsDisplay = true
        submitButton.needsDisplay = true
        loadingSkeletonView.needsDisplay = true
        needsDisplay = true
    }

    private func applyLoadingState() {
        textView.isHidden = isLoading
        submitButton.isHidden = isLoading
        loadingSkeletonView.isHidden = !isLoading
        loadingSkeletonView.setAnimating(isLoading, reduceMotion: reduceMotion)
        if isLoading {
            window?.makeFirstResponder(nil)
            isInputFocused = false
            hasExplicitInputInteraction = false
        }
        needsDisplay = true
        needsLayout = true
        discardCursorRects()
    }

    private func drawSparkles() {
        guard let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) else {
            return
        }

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let colorConfiguration = NSImage.SymbolConfiguration(
            hierarchicalColor: IntelligenceInstructionComposerPresentation.iconColor(
                usesDarkAppearance: usesDarkChrome
            )
        )
        let configuredImage = image.withSymbolConfiguration(
            symbolConfiguration.applying(colorConfiguration)
        ) ?? image
        let imageRect = NSRect(
            x: IntelligenceInstructionComposerPresentation.horizontalPadding,
            y: bounds.midY - 8,
            width: 16,
            height: 16
        )
        configuredImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func updateLayerShadow() {
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(IntelligenceInstructionComposerPresentation.shadowOpacity)
        layer?.shadowRadius = IntelligenceInstructionComposerPresentation.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -IntelligenceInstructionComposerPresentation.shadowYOffset)
    }

    private func registerHitTestRegion() {
        guard let window else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            return
        }

        EditorFloatingControlHitTestRegistry.setRegion(
            owner: self,
            window: window,
            rect: convert(bounds, to: nil),
            mouseDownHandler: { [weak self] in
                self?.focusTextView(showingOutline: true)
            }
        )
    }
}

final class IntelligenceInstructionLoadingSkeletonNSView: NSView {
    var usesDarkChrome = false {
        didSet {
            needsDisplay = true
        }
    }
    private var reduceMotion = false

    private var animationStartDate = Date()
    private var animationTimer: Timer?
    var isAnimatingForAccessibilityTesting: Bool {
        animationTimer != nil
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else if !isHidden && !reduceMotion {
            startAnimating()
        }
    }

    func setAnimating(_ isAnimating: Bool, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        if isAnimating, !reduceMotion, window != nil {
            startAnimating()
        } else {
            stopAnimating()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rowCount = IntelligenceInstructionComposerPresentation.loadingSkeletonMinimumRows
        let columnCount = IntelligenceInstructionComposerPresentation.loadingSkeletonColumns
        let blockHeight = IntelligenceInstructionComposerPresentation.loadingSkeletonBlockHeight
        let spacing = IntelligenceInstructionComposerPresentation.loadingSkeletonSpacing
        let rowHeight = blockHeight + spacing
        let gridHeight = CGFloat(rowCount) * blockHeight + CGFloat(rowCount - 1) * spacing
        let originY = max(0, (bounds.height - gridHeight) / 2)
        let availableWidth = max(0, bounds.width - CGFloat(columnCount - 1) * spacing)
        let cellWidth = max(
            IntelligenceInstructionComposerPresentation.loadingSkeletonMinimumCellWidth,
            availableWidth / CGFloat(columnCount)
        )

        for row in 0..<rowCount {
            for column in 0..<columnCount {
                let cellIndex = row * columnCount + column
                guard shouldDrawSkeletonBlock(row: row, column: column, cellIndex: cellIndex) else {
                    continue
                }

                let scale = skeletonScale(cellIndex: cellIndex)
                let width = min(
                    cellWidth,
                    max(
                        IntelligenceInstructionComposerPresentation.loadingSkeletonMinimumBlockWidth,
                        cellWidth * scale
                    )
                )
                let x = CGFloat(column) * (cellWidth + spacing) + (cellWidth - width) / 2
                let y = originY + CGFloat(row) * rowHeight
                let rect = NSRect(x: x, y: y, width: width, height: blockHeight)
                drawSkeletonBlock(in: rect, alpha: skeletonAlpha(row: row, column: column, cellIndex: cellIndex))
            }
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }

        animationStartDate = Date()
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func drawSkeletonBlock(in rect: NSRect, alpha: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let baseColor = IntelligenceInstructionComposerPresentation.loadingSkeletonBaseColor(
            usesDarkAppearance: usesDarkChrome,
            alpha: alpha
        )
        baseColor.setFill()
        path.fill()

        guard let gradient = NSGradient(
            colors: IntelligenceInstructionComposerPresentation.loadingSkeletonGradientColors(
                usesDarkAppearance: usesDarkChrome,
                alpha: alpha
            )
        ) else {
            return
        }
        gradient.draw(in: path, angle: 0)
    }

    private func shouldDrawSkeletonBlock(row: Int, column: Int, cellIndex: Int) -> Bool {
        let preserveEdges = column == 0 || column == IntelligenceInstructionComposerPresentation.loadingSkeletonColumns - 1
        return preserveEdges || seededNoise(Double(cellIndex + 101)) >= 0.16
    }

    private func skeletonAlpha(row: Int, column: Int, cellIndex: Int) -> CGFloat {
        let elapsed = Date().timeIntervalSince(animationStartDate)
        let phase = (elapsed - skeletonDelay(row: row, column: column, cellIndex: cellIndex))
            / skeletonDuration(cellIndex: cellIndex)
        let wave = (sin(phase * .pi * 2 - .pi / 2) + 1) / 2
        return CGFloat(wave)
    }

    private func skeletonDelay(row: Int, column: Int, cellIndex: Int) -> TimeInterval {
        let secondaryNoise = seededNoise(Double(cellIndex + 101) * 3.17)
        return Double(column) * 0.026 + Double((row * 7) % 5) * 0.016 + secondaryNoise * 0.07
    }

    private func skeletonDuration(cellIndex: Int) -> TimeInterval {
        0.72 + seededNoise(Double(cellIndex) * 2.11 + 100) * 0.34
    }

    private func skeletonScale(cellIndex: Int) -> CGFloat {
        0.82 + CGFloat(seededNoise(Double(cellIndex) * 4.61 + 100)) * 0.18
    }

    private func seededNoise(_ seed: Double) -> Double {
        let value = sin(seed * 12.9898) * 43758.5453
        return value - floor(value)
    }
}

private final class LocalEventMonitor: @unchecked Sendable {
    private var monitor: Any?

    init(_ monitor: Any) {
        self.monitor = monitor
    }

    func remove() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    deinit {
        remove()
    }
}

final class IntelligenceInstructionTextView: NSTextView {
    var placeholder = "" {
        didSet {
            needsDisplay = true
        }
    }
    var usesDarkChrome = false {
        didSet {
            needsDisplay = true
        }
    }
    var onTextChanged: (String) -> Void = { _ in }
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    convenience init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        self.init(frame: .zero, textContainer: textContainer)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        handleMouseDown(with: event)
    }

    func handleMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let localPoint = convert(event.locationInWindow, from: nil)
        let textLength = (string as NSString).length

        if event.clickCount >= 3 {
            setSelectedRange(NSRange(location: 0, length: textLength))
            return
        }

        let characterIndex = characterIndexForInsertion(at: localPoint)
        if event.clickCount == 2, textLength > 0 {
            let wordLocation = min(max(characterIndex, 0), textLength - 1)
            setSelectedRange(selectionRange(
                forProposedRange: NSRange(location: wordLocation, length: 0),
                granularity: .selectByWord
            ))
            return
        }

        setSelectedRange(NSRange(location: characterIndex, length: 0))
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            onFocusChanged(true)
            needsDisplay = true
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder {
            onFocusChanged(false)
            needsDisplay = true
        }
        return resignedFirstResponder
    }

    override func didChangeText() {
        super.didChangeText()
        string = string.replacingOccurrences(of: "\n", with: " ")
        onTextChanged(string)
        needsDisplay = true
    }

    override func insertNewline(_ sender: Any?) {
        onSubmit()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: IntelligenceInstructionComposerPresentation.placeholderColor(
                usesDarkAppearance: usesDarkChrome
            )
        ]
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: attributes
        )
    }
}

struct IntelligenceInstructionSubmitButton: NSViewRepresentable {
    let isActionEnabled: Bool
    var usesDarkChrome = false
    let performAction: () -> Void

    func makeNSView(context: Context) -> IntelligenceInstructionSubmitButtonNSView {
        IntelligenceInstructionSubmitButtonNSView(
            isActionEnabled: isActionEnabled,
            usesDarkChrome: usesDarkChrome,
            performAction: performAction
        )
    }

    func updateNSView(_ nsView: IntelligenceInstructionSubmitButtonNSView, context: Context) {
        nsView.isActionEnabled = isActionEnabled
        nsView.usesDarkChrome = usesDarkChrome
        nsView.performAction = performAction
    }
}

final class IntelligenceInstructionSubmitButtonNSView: NSView {
    var isActionEnabled: Bool {
        didSet {
            if oldValue != isActionEnabled {
                if !isActionEnabled {
                    setHovering(false)
                }
                setAccessibilityEnabled(isActionEnabled)
                window?.invalidateCursorRects(for: self)
            }
            needsDisplay = true
        }
    }
    var usesDarkChrome: Bool {
        didSet {
            needsDisplay = true
        }
    }
    var performAction: () -> Void

    private(set) var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    init(isActionEnabled: Bool, usesDarkChrome: Bool = false, performAction: @escaping () -> Void) {
        self.isActionEnabled = isActionEnabled
        self.usesDarkChrome = usesDarkChrome
        self.performAction = performAction
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(IntelligenceInstructionComposerPresentation.submitAccessibilityLabel)
        setAccessibilityHelp(IntelligenceInstructionComposerPresentation.submitAccessibilityHelp)
        setAccessibilityEnabled(isActionEnabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: IntelligenceInstructionComposerPresentation.sendButtonSize,
            height: IntelligenceInstructionComposerPresentation.sendButtonSize
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        isActionEnabled
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        guard isActionEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }

        registerHitTestRegion()

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea

        super.updateTrackingAreas()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        registerHitTestRegion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        registerHitTestRegion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerHitTestRegion()
        window?.invalidateCursorRects(for: self)
        if window == nil {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            setHovering(false)
        }
    }

    override func layout() {
        super.layout()
        registerHitTestRegion()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isActionEnabled else {
            setHovering(false)
            return
        }
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isActionEnabled else { return }
        reassertCursorIfHovering()
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isActionEnabled else { return }
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        performActionIfEnabled()
    }

    override func keyDown(with event: NSEvent) {
        let activatesButton = event.keyCode == 36 || event.keyCode == 49
        if activatesButton, performActionIfEnabled() {
            return
        }

        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        performActionIfEnabled()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        IntelligenceInstructionComposerPresentation.sendButtonFillColor(
            usesDarkAppearance: usesDarkChrome,
            isHovered: isHovering,
            isEnabled: isActionEnabled
        )
        .setFill()
        NSBezierPath(ovalIn: bounds).fill()

        guard let image = NSImage(
            systemSymbolName: IntelligenceInstructionComposerPresentation.submitSystemImage,
            accessibilityDescription: "Run AI instruction"
        ) else {
            return
        }

        let symbolPointSize = IntelligenceInstructionComposerPresentation.sendButtonSymbolPointSize
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .bold)
        let colorConfiguration = NSImage.SymbolConfiguration(
            hierarchicalColor: IntelligenceInstructionComposerPresentation.sendButtonSymbolColor(
                usesDarkAppearance: usesDarkChrome,
                isEnabled: isActionEnabled
            )
        )
        let configuredImage = image.withSymbolConfiguration(
            symbolConfiguration.applying(colorConfiguration)
        ) ?? image
        let imageSize = NSSize(width: symbolPointSize, height: symbolPointSize)
        let imageRect = NSRect(
            x: bounds.midX - imageSize.width / 2,
            y: bounds.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )

        configuredImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    deinit {
        let wasHovering = isHovering
        let ownerID = ObjectIdentifier(self)
        EditorFloatingControlHitTestRegistry.remove(ownerID: ownerID)
        if wasHovering {
            NSCursor.pop()
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }

        isHovering = hovering
        if hovering {
            NSCursor.pointingHand.push()
            NSCursor.pointingHand.set()
        } else {
            NSCursor.pop()
        }
        needsDisplay = true
    }

    private func reassertCursorIfHovering() {
        guard isHovering else { return }
        NSCursor.pointingHand.set()
    }

    @discardableResult
    private func performActionIfEnabled() -> Bool {
        guard isActionEnabled else {
            return false
        }

        performAction()
        return true
    }

    private func registerHitTestRegion() {
        guard let window else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            return
        }

        EditorFloatingControlHitTestRegistry.setRegion(
            owner: self,
            window: window,
            rect: convert(bounds, to: nil),
            mouseDownHandler: { [weak self] in
                self?.performActionIfEnabled()
            }
        )
    }
}


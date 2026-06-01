import SwiftUI

struct IntelligenceActionRail: View {
    let actions: [IntelligentEditingAction]
    let isActionEnabled: Bool
    let runAction: (IntelligentEditingAction) -> Void

    var body: some View {
        HStack(spacing: IntelligenceActionRailPresentation.railSpacing) {
            ForEach(actions) { action in
                IntelligenceActionRailButton(
                    action: action,
                    isEnabled: isActionEnabled,
                    runAction: runAction
                )
            }
        }
    }
}
struct IntelligenceActionRailOverlayHost: NSViewRepresentable {
    let actions: [IntelligentEditingAction]
    let isActionEnabled: Bool
    let runAction: (IntelligentEditingAction) -> Void

    func makeNSView(context: Context) -> IntelligenceActionRailOverlayNSView {
        IntelligenceActionRailOverlayNSView(
            actions: actions,
            isActionEnabled: isActionEnabled,
            runAction: runAction
        )
    }

    func updateNSView(_ nsView: IntelligenceActionRailOverlayNSView, context: Context) {
        nsView.update(
            actions: actions,
            isActionEnabled: isActionEnabled,
            runAction: runAction
        )
    }
}

final class IntelligenceActionRailOverlayNSView: NSView {
    private var actions: [IntelligentEditingAction]
    private var isActionEnabled: Bool
    private var runAction: (IntelligentEditingAction) -> Void
    private var buttonViews: [ActionRailButtonNSView] = []

    init(
        actions: [IntelligentEditingAction],
        isActionEnabled: Bool,
        runAction: @escaping (IntelligentEditingAction) -> Void
    ) {
        self.actions = actions
        self.isActionEnabled = isActionEnabled
        self.runAction = runAction
        super.init(frame: .zero)
        rebuildButtons()
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
        actions: [IntelligentEditingAction],
        isActionEnabled: Bool,
        runAction: @escaping (IntelligentEditingAction) -> Void
    ) {
        let needsRebuild = actions != self.actions
        self.actions = actions
        self.isActionEnabled = isActionEnabled
        self.runAction = runAction

        if needsRebuild {
            rebuildButtons()
        } else {
            buttonViews.forEach { buttonView in
                buttonView.isEnabled = isActionEnabled
                buttonView.performAction = { [weak self, action = buttonView.action] in
                    self?.runAction(action)
                }
            }
        }

        needsLayout = true
    }

    override func layout() {
        super.layout()

        let width = min(railWidth, bounds.width)
        let height = IntelligenceActionRailPresentation.buttonHeight
        let origin = NSPoint(
            x: (bounds.width - width) / 2,
            y: max(0, bounds.height - IntelligenceActionRailPresentation.bottomInset - height)
        )

        for (index, buttonView) in buttonViews.enumerated() {
            buttonView.frame = NSRect(
                x: origin.x + CGFloat(index) * (IntelligenceActionRailPresentation.buttonWidth + IntelligenceActionRailPresentation.railSpacing),
                y: origin.y,
                width: IntelligenceActionRailPresentation.buttonWidth,
                height: IntelligenceActionRailPresentation.buttonHeight
            )
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for buttonView in buttonViews.reversed() {
            let buttonPoint = convert(point, to: buttonView)
            if let hitView = buttonView.hitTest(buttonPoint) {
                return hitView
            }
        }

        return nil
    }

    private var railWidth: CGFloat {
        guard !buttonViews.isEmpty else { return 0 }
        return CGFloat(buttonViews.count) * IntelligenceActionRailPresentation.buttonWidth
            + CGFloat(buttonViews.count - 1) * IntelligenceActionRailPresentation.railSpacing
    }

    private func rebuildButtons() {
        buttonViews.forEach { $0.removeFromSuperview() }
        buttonViews = actions.map { action in
            let buttonView = ActionRailButtonNSView(
                action: action,
                isEnabled: isActionEnabled,
                performAction: { [weak self] in
                    self?.runAction(action)
                }
            )
            addSubview(buttonView)
            return buttonView
        }
        needsLayout = true
    }
}

final class ActionRailButtonNSView: NSView {
    let action: IntelligentEditingAction
    var performAction: () -> Void
    var isEnabled: Bool {
        didSet {
            if isEnabled {
                registerHitTestRegion()
            } else {
                setHovering(false)
                removeHoverTrackingArea()
                EditorFloatingControlHitTestRegistry.remove(owner: self)
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    init(
        action: IntelligentEditingAction,
        isEnabled: Bool,
        performAction: @escaping () -> Void
    ) {
        self.action = action
        self.isEnabled = isEnabled
        self.performAction = performAction
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: IntelligenceActionRailPresentation.buttonWidth,
            height: IntelligenceActionRailPresentation.buttonHeight
        )
    }

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled && bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        removeHoverTrackingArea()

        guard isEnabled else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            super.updateTrackingAreas()
            return
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

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEnabled else { return }
        reassertCursorIfHovering()
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isEnabled else { return }
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        performAction()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: IntelligenceActionRailPresentation.cornerRadius,
            yRadius: IntelligenceActionRailPresentation.cornerRadius
        )
        NSColor.actionRailBackground(isHovered: isHovering).setFill()
        path.fill()

        NSColor.controlAccentColor
            .withAlphaComponent(isHovering ? IntelligenceActionRailPresentation.hoverBorderOpacity : IntelligenceActionRailPresentation.borderOpacity)
            .setStroke()
        path.lineWidth = 1
        path.stroke()

        drawIcon(in: bounds)
        drawLabel(in: bounds)
    }

    deinit {
        let wasHovering = isHovering
        let ownerID = ObjectIdentifier(self)
        EditorFloatingControlHitTestRegistry.remove(ownerID: ownerID)
        if wasHovering {
            NSCursor.pop()
        }
    }

    private func drawIcon(in rect: NSRect) {
        guard let image = NSImage(
            systemSymbolName: action.railSystemImage,
            accessibilityDescription: action.title
        ) else {
            return
        }

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: IntelligenceActionRailPresentation.iconSize,
            weight: .semibold
        )
        let iconColor = NSColor.controlAccentColor.withAlphaComponent(
            isEnabled ? 1 : IntelligenceActionRailPresentation.disabledContentOpacity
        )
        let colorConfiguration = NSImage.SymbolConfiguration(hierarchicalColor: iconColor)
        let configuredImage = image.withSymbolConfiguration(
            symbolConfiguration.applying(colorConfiguration)
        ) ?? image

        let iconSize = NSSize(
            width: IntelligenceActionRailPresentation.iconSize + 3,
            height: IntelligenceActionRailPresentation.iconSize + 3
        )
        let iconRect = NSRect(
            x: rect.midX - iconSize.width / 2,
            y: 12,
            width: iconSize.width,
            height: iconSize.height
        )

        configuredImage.draw(
            in: iconRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    private func drawLabel(in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: IntelligenceActionRailPresentation.labelSize,
                weight: .semibold
            ),
            .foregroundColor: NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : IntelligenceActionRailPresentation.disabledContentOpacity),
            .paragraphStyle: paragraphStyle
        ]
        let label = NSAttributedString(string: action.railDisplayTitle, attributes: attributes)
        label.draw(
            in: NSRect(
                x: 5,
                y: rect.height - 20,
                width: rect.width - 10,
                height: 14
            )
        )
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

    private func registerHitTestRegion() {
        guard isEnabled, let window else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            return
        }

        EditorFloatingControlHitTestRegistry.setRegion(
            owner: self,
            window: window,
            rect: convert(bounds, to: nil)
        )
    }

    private func removeHoverTrackingArea() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        hoverTrackingArea = nil
    }
}

extension NSColor {
    static func actionRailBackground(isHovered: Bool) -> NSColor {
        NSColor(
            srgbRed: isHovered
                ? IntelligenceActionRailPresentation.hoverBackgroundRedComponent
                : IntelligenceActionRailPresentation.backgroundRedComponent,
            green: isHovered
                ? IntelligenceActionRailPresentation.hoverBackgroundGreenComponent
                : IntelligenceActionRailPresentation.backgroundGreenComponent,
            blue: isHovered
                ? IntelligenceActionRailPresentation.hoverBackgroundBlueComponent
                : IntelligenceActionRailPresentation.backgroundBlueComponent,
            alpha: IntelligenceActionRailPresentation.backgroundAlpha
        )
    }
}

struct IntelligenceActionRailButton: View {
    let action: IntelligentEditingAction
    let isEnabled: Bool
    let runAction: (IntelligentEditingAction) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            if isEnabled {
                runAction(action)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.railSystemImage)
                    .font(.system(size: IntelligenceActionRailPresentation.iconSize, weight: .semibold))

                Text(action.railDisplayTitle)
                    .font(.system(size: IntelligenceActionRailPresentation.labelSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.accentColor.opacity(isEnabled ? 1 : IntelligenceActionRailPresentation.disabledContentOpacity))
            .frame(
                width: IntelligenceActionRailPresentation.buttonWidth,
                height: IntelligenceActionRailPresentation.buttonHeight
            )
            .background(
                RoundedRectangle(cornerRadius: IntelligenceActionRailPresentation.cornerRadius)
                    .fill(IntelligenceActionRailPresentation.backgroundColor(isHovered: isHovered))
            )
            .overlay {
                RoundedRectangle(cornerRadius: IntelligenceActionRailPresentation.cornerRadius)
                    .strokeBorder(
                        IntelligenceActionRailPresentation.borderColor(isHovered: isHovered),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: .black.opacity(IntelligenceActionRailPresentation.shadowOpacity),
                radius: IntelligenceActionRailPresentation.shadowRadius,
                y: IntelligenceActionRailPresentation.shadowYOffset
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: IntelligenceActionRailPresentation.cornerRadius))
        .help(action.title)
        .accessibilityLabel(action.title)
        .overlay {
            ActionRailButtonEventView(
                isEnabled: isEnabled,
                onHoverChanged: { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHovered = hovering
                    }
                },
                performAction: {
                    guard isEnabled else { return }
                    runAction(action)
                }
            )
        }
    }
}

struct ActionRailButtonEventView: NSViewRepresentable {
    let isEnabled: Bool
    let onHoverChanged: (Bool) -> Void
    let performAction: () -> Void

    func makeNSView(context: Context) -> ActionRailButtonEventNSView {
        ActionRailButtonEventNSView(
            isEnabled: isEnabled,
            onHoverChanged: onHoverChanged,
            performAction: performAction
        )
    }

    func updateNSView(_ nsView: ActionRailButtonEventNSView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onHoverChanged = onHoverChanged
        nsView.performAction = performAction
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class ActionRailButtonEventNSView: NSView {
    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled {
                setHovering(false)
                EditorFloatingControlHitTestRegistry.remove(owner: self)
            } else {
                registerHitTestRegion()
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onHoverChanged: (Bool) -> Void
    var performAction: () -> Void

    init(
        isEnabled: Bool,
        onHoverChanged: @escaping (Bool) -> Void,
        performAction: @escaping () -> Void
    ) {
        self.isEnabled = isEnabled
        self.onHoverChanged = onHoverChanged
        self.performAction = performAction
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        registerHitTestRegion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        registerHitTestRegion()
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }

        guard isEnabled else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            super.updateTrackingAreas()
            return
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled else { return nil }
        return bounds.contains(point) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEnabled else { return }
        reassertCursorIfHovering()
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEnabled && isHovering {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        performAction()
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
        onHoverChanged(hovering)
    }

    private func reassertCursorIfHovering() {
        guard isHovering else { return }
        NSCursor.pointingHand.set()
    }

    private func registerHitTestRegion() {
        guard isEnabled, let window else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            return
        }

        EditorFloatingControlHitTestRegistry.setRegion(
            owner: self,
            window: window,
            rect: convert(bounds, to: nil)
        )
    }
}


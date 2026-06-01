import SwiftUI

struct FloatingControlRegionRegistrationView: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> FloatingControlRegionRegistrationNSView {
        FloatingControlRegionRegistrationNSView(isEnabled: isEnabled)
    }

    func updateNSView(_ nsView: FloatingControlRegionRegistrationNSView, context: Context) {
        nsView.isEnabled = isEnabled
        DispatchQueue.main.async {
            nsView.refreshFloatingHitTestRegion()
        }
    }
}

final class FloatingControlRegionRegistrationNSView: NSView {
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            refreshFloatingHitTestRegion()
        }
    }

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
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
        refreshFloatingHitTestRegion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshFloatingHitTestRegion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshFloatingHitTestRegion()
        if window == nil {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
        }
    }

    override func layout() {
        super.layout()
        refreshFloatingHitTestRegion()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        EditorFloatingControlHitTestRegistry.remove(owner: self)
    }

    func refreshFloatingHitTestRegion() {
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

enum EditorFloatingControlHitTestRegistry {
    private final class Region {
        weak var window: NSWindow?
        var rect: NSRect
        var mouseDownHandler: (() -> Void)?

        init(window: NSWindow, rect: NSRect, mouseDownHandler: (() -> Void)?) {
            self.window = window
            self.rect = rect
            self.mouseDownHandler = mouseDownHandler
        }
    }

    nonisolated(unsafe) private static var regions: [ObjectIdentifier: Region] = [:]

    static func setRegion(
        owner: AnyObject,
        window: NSWindow,
        rect: NSRect,
        mouseDownHandler: (() -> Void)? = nil
    ) {
        regions[ObjectIdentifier(owner)] = Region(
            window: window,
            rect: rect,
            mouseDownHandler: mouseDownHandler
        )
    }

    static func remove(owner: AnyObject) {
        regions.removeValue(forKey: ObjectIdentifier(owner))
    }

    static func remove(ownerID: ObjectIdentifier) {
        regions.removeValue(forKey: ownerID)
    }

    static func contains(windowPoint: NSPoint, in window: NSWindow) -> Bool {
        regions = regions.filter { _, region in
            region.window != nil
        }

        return regions.values.contains { region in
            region.window === window && region.rect.contains(windowPoint)
        }
    }

    @discardableResult
    static func handleMouseDown(windowPoint: NSPoint, in window: NSWindow) -> Bool {
        regions = regions.filter { _, region in
            region.window != nil
        }

        let matchingRegions = regions.values
            .filter { region in
                region.window === window && region.rect.contains(windowPoint)
            }
            .sorted { lhs, rhs in
                switch (lhs.mouseDownHandler == nil, rhs.mouseDownHandler == nil) {
                case (false, true):
                    return true
                case (true, false):
                    return false
                default:
                    break
                }

                return lhs.rect.width * lhs.rect.height < rhs.rect.width * rhs.rect.height
            }

        guard let region = matchingRegions.first else {
            return false
        }

        region.mouseDownHandler?()
        return true
    }
}

struct RestoringHoverCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var hasPushedCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    pushCursor()
                } else {
                    popCursorIfNeeded()
                }
            }
            .onDisappear {
                popCursorIfNeeded()
            }
    }

    private func pushCursor() {
        guard !hasPushedCursor else { return }
        cursor.push()
        cursor.set()
        hasPushedCursor = true
    }

    private func popCursorIfNeeded() {
        guard hasPushedCursor else { return }
        NSCursor.pop()
        hasPushedCursor = false
    }
}

extension View {
    func restoringHoverCursor(_ cursor: NSCursor) -> some View {
        modifier(RestoringHoverCursorModifier(cursor: cursor))
    }
}

struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> CursorRectNSView {
        CursorRectNSView(cursor: cursor, onHoverChanged: onHoverChanged)
    }

    func updateNSView(_ nsView: CursorRectNSView, context: Context) {
        nsView.cursor = cursor
        nsView.onHoverChanged = onHoverChanged
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class CursorRectNSView: NSView {
    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    var cursor: NSCursor {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }
    var onHoverChanged: (Bool) -> Void

    init(cursor: NSCursor, onHoverChanged: @escaping (Bool) -> Void) {
        self.cursor = cursor
        self.onHoverChanged = onHoverChanged
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

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

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        reassertCursorIfHovering()
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isHovering {
            cursor.set()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
        if window == nil {
            setHovering(false)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        if isHovering {
            NSCursor.pop()
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }

        isHovering = hovering
        if hovering {
            cursor.push()
            cursor.set()
        } else {
            NSCursor.pop()
        }
        onHoverChanged(hovering)
    }

    private func reassertCursorIfHovering() {
        guard isHovering else { return }
        cursor.set()
    }
}

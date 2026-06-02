import AppKit
import SwiftUI
import WebKit

@MainActor
enum LineformLaunchDefaults {
    static let firstPublicReleaseDefaultsInitializedKey = "LineformPublicReleaseDefaultsInitialized"
    static let firstLaunchIntroCompletedKey = "LineformFirstLaunchIntroCompleted.v1_0"
    static let legacyFirstLaunchIntroCompletedKey = "LineformFirstLaunchIntroCompleted"

    private static let staleFirstPublicReleaseKeys = [
        legacyFirstLaunchIntroCompletedKey,
        "Lineform.outline.workspaceBookmark",
        "Lineform.outline.workspaceSnapshot"
    ]

    private static var restoresApplicationStateForCurrentLaunch: Bool?

    static func prepareForLaunch(defaults: UserDefaults = .standard) {
        #if DEBUG
        restoresApplicationStateForCurrentLaunch = true
        #else
        let shouldRestoreApplicationState = defaults.bool(forKey: firstPublicReleaseDefaultsInitializedKey)
        restoresApplicationStateForCurrentLaunch = shouldRestoreApplicationState

        _ = migrateFirstPublicReleaseDefaultsIfNeeded(defaults: defaults) {
            NSDocumentController.shared.clearRecentDocuments(nil)
        }
        #endif
    }

    static func shouldRestoreApplicationState(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        return true
        #else
        if let restoresApplicationStateForCurrentLaunch {
            return restoresApplicationStateForCurrentLaunch
        }

        return defaults.bool(forKey: firstPublicReleaseDefaultsInitializedKey)
        #endif
    }

    @discardableResult
    static func migrateFirstPublicReleaseDefaultsIfNeeded(
        defaults: UserDefaults,
        clearRecentDocuments: () -> Void
    ) -> Bool {
        guard !defaults.bool(forKey: firstPublicReleaseDefaultsInitializedKey) else {
            return false
        }

        for key in staleFirstPublicReleaseKeys {
            defaults.removeObject(forKey: key)
        }
        clearRecentDocuments()
        defaults.set(true, forKey: firstPublicReleaseDefaultsInitializedKey)
        return true
    }

    static func hasCompletedFirstLaunchIntro(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: firstLaunchIntroCompletedKey)
    }

    static func markFirstLaunchIntroCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: firstLaunchIntroCompletedKey)
    }
}

@MainActor
final class LineformAppDelegate: NSObject, NSApplicationDelegate {
    private let firstLaunchIntroPresenter = FirstLaunchIntroPresenter()

    func applicationWillFinishLaunching(_ notification: Notification) {
        LineformLaunchDefaults.prepareForLaunch()
        firstLaunchIntroPresenter.showIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [firstLaunchIntroPresenter] in
            firstLaunchIntroPresenter.showIfNeeded()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if firstLaunchIntroPresenter.shouldAllowUntitledDocumentOpen() {
            return true
        }

        firstLaunchIntroPresenter.openUntitledDocumentAfterDismiss()
        return false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        LineformLaunchDefaults.shouldRestoreApplicationState()
    }
}

@MainActor
final class FirstLaunchIntroPresenter {
    private var window: NSWindow?
    private var hiddenAppWindows: [NSWindow] = []
    private var shouldOpenUntitledDocumentAfterDismiss = false
    private var shouldAllowNextUntitledDocumentOpen = false

    static var shouldShowIntro: Bool {
        let environmentForcesIntro = ProcessInfo.processInfo.environment["LINEFORM_SHOW_FIRST_LAUNCH_INTRO"] == "1"
        return environmentForcesIntro || !LineformLaunchDefaults.hasCompletedFirstLaunchIntro()
    }

    func openUntitledDocumentAfterDismiss() {
        shouldOpenUntitledDocumentAfterDismiss = true
    }

    func shouldAllowUntitledDocumentOpen() -> Bool {
        if shouldAllowNextUntitledDocumentOpen {
            shouldAllowNextUntitledDocumentOpen = false
            return true
        }

        return !Self.shouldShowIntro
    }

    func showIfNeeded() {
        guard Self.shouldShowIntro else {
            return
        }

        show()
    }

    private func show() {
        guard window == nil, let screen = NSScreen.main else {
            return
        }

        hideVisibleAppWindows()

        let overlay = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        overlay.backgroundColor = .clear
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.hasShadow = false
        overlay.isMovable = false
        overlay.isOpaque = false
        overlay.level = .screenSaver
        overlay.titleVisibility = .hidden

        let hostingView = NSHostingView(rootView:
            FirstLaunchIntroOverlayView { [weak self] in
                self?.dismiss()
            }
        )
        hostingView.frame = screen.frame
        overlay.contentView = hostingView
        overlay.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = overlay
        DispatchQueue.main.async { [weak self] in
            self?.hideVisibleAppWindows()
        }
    }

    private func dismiss() {
        LineformLaunchDefaults.markFirstLaunchIntroCompleted()
        shouldOpenUntitledDocumentAfterDismiss = true
        guard let window else {
            openInitialUntitledDocumentIfNeeded()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = FirstLaunchIntroOverlayMetrics.dismissAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                window.orderOut(nil)
                self?.window = nil
                self?.restoreHiddenAppWindows()
                self?.openInitialUntitledDocumentIfNeeded()
            }
        }
    }

    private func hideVisibleAppWindows() {
        for appWindow in NSApp.windows where appWindow !== window && appWindow.isVisible {
            if !hiddenAppWindows.contains(where: { $0 === appWindow }) {
                hiddenAppWindows.append(appWindow)
            }
            appWindow.orderOut(nil)
        }
    }

    private func restoreHiddenAppWindows() {
        let windowsToRestore = hiddenAppWindows
        hiddenAppWindows.removeAll()
        for appWindow in windowsToRestore {
            appWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openInitialUntitledDocumentIfNeeded() {
        guard shouldOpenUntitledDocumentAfterDismiss else {
            return
        }

        shouldOpenUntitledDocumentAfterDismiss = false
        shouldAllowNextUntitledDocumentOpen = true
        do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            if document.windowControllers.isEmpty {
                document.makeWindowControllers()
            }
            for windowController in document.windowControllers {
                windowController.window?.animationBehavior = .none
                windowController.showWindow(nil)
                windowController.window?.makeKeyAndOrderFront(nil)
            }
        } catch {
            NSDocumentController.shared.newDocument(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum FirstLaunchIntroOverlayMetrics {
    static let dismissAnimationDuration: TimeInterval = 0.32
    static let startButtonSize = CGSize(width: 214, height: 62)
    static let startButtonVerticalPosition: CGFloat = 0.755
    static let startButtonRevealDelay: Duration = .milliseconds(1000)
    static let startButtonRevealAnimationDuration: TimeInterval = 0.28
}

struct FirstLaunchIntroOverlayView: View {
    let dismiss: () -> Void
    @State private var isButtonVisible = false

    var body: some View {
        ZStack {
            FirstLaunchIntroWebView(dismiss: dismiss)
                .ignoresSafeArea()

            GeometryReader { proxy in
                FirstLaunchIntroStartButton(dismiss: dismiss)
                    .frame(
                        width: FirstLaunchIntroOverlayMetrics.startButtonSize.width,
                        height: FirstLaunchIntroOverlayMetrics.startButtonSize.height
                    )
                    .opacity(isButtonVisible ? 1 : 0)
                    .animation(
                        .easeOut(duration: FirstLaunchIntroOverlayMetrics.startButtonRevealAnimationDuration),
                        value: isButtonVisible
                    )
                    .position(
                        x: proxy.size.width / 2,
                        y: proxy.size.height * FirstLaunchIntroOverlayMetrics.startButtonVerticalPosition
                    )
            }
        }
        .task {
            try? await Task.sleep(for: FirstLaunchIntroOverlayMetrics.startButtonRevealDelay)
            isButtonVisible = true
        }
    }
}

struct FirstLaunchIntroStartButton: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> FirstLaunchIntroStartButtonView {
        FirstLaunchIntroStartButtonView(dismiss: dismiss)
    }

    func updateNSView(_ nsView: FirstLaunchIntroStartButtonView, context: Context) {}
}

final class FirstLaunchIntroStartButtonView: NSView {
    private let dismiss: () -> Void
    private let label = NSTextField(labelWithString: "Get Started")
    private let arrowLayer = CAShapeLayer()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            updateAppearance(animated: true)
        }
    }

    init(dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        super.init(frame: NSRect(origin: .zero, size: FirstLaunchIntroOverlayMetrics.startButtonSize))
        wantsLayer = true
        layer?.cornerRadius = 31
        layer?.masksToBounds = false

        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        label.alignment = .center

        addSubview(label)
        arrowLayer.fillColor = nil
        arrowLayer.strokeColor = label.textColor?.cgColor
        arrowLayer.lineWidth = 2.2
        arrowLayer.lineCap = .round
        arrowLayer.lineJoin = .round
        layer?.addSublayer(arrowLayer)
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 30, y: 18, width: 112, height: 24)
        arrowLayer.frame = CGRect(x: bounds.width - 54, y: 22, width: 28, height: 18)
        arrowLayer.path = Self.makeArrowPath().cgPath
        layer?.cornerRadius = bounds.height / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        dismiss()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private static func makeArrowPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 18.2, y: 1.3))
        path.line(to: NSPoint(x: 26, y: 9))
        path.line(to: NSPoint(x: 18.2, y: 16.7))
        path.move(to: NSPoint(x: 25, y: 9))
        path.line(to: NSPoint(x: 1.5, y: 9))
        return path
    }

    private func updateAppearance(animated: Bool) {
        let changes = {
            self.layer?.backgroundColor = self.isHovered
                ? NSColor(calibratedWhite: 0.86, alpha: 0.96).cgColor
                : NSColor(calibratedWhite: 0.98, alpha: 0.9).cgColor
            self.layer?.borderColor = self.isHovered
                ? NSColor(calibratedWhite: 0, alpha: 0.22).cgColor
                : NSColor(calibratedWhite: 0, alpha: 0.1).cgColor
            self.layer?.borderWidth = 1
            self.layer?.shadowColor = NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.07, alpha: self.isHovered ? 0.3 : 0.22).cgColor
            self.layer?.shadowOpacity = 1
            self.layer?.shadowRadius = self.isHovered ? 30 : 25
            self.layer?.shadowOffset = CGSize(width: 0, height: self.isHovered ? -26 : -22)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                changes()
            }
        } else {
            changes()
        }
    }
}

struct FirstLaunchIntroWebView: NSViewRepresentable {
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "lineformIntro")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false

        if let introURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "FirstLaunchIntro") {
            webView.loadFileURL(introURL, allowingReadAccessTo: introURL.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let dismiss: () -> Void

        init(dismiss: @escaping () -> Void) {
            self.dismiss = dismiss
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "lineformIntro" {
                dismiss()
            }
        }
    }
}

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

    static func prepareForLaunch(defaults: UserDefaults = .standard) {
        #if DEBUG
        // Debug builds carry no first-release migration; nothing to prepare here.
        #else
        _ = migrateFirstPublicReleaseDefaultsIfNeeded(defaults: defaults) {
            NSDocumentController.shared.clearRecentDocuments(nil)
        }
        #endif
    }

    /// Lineform always launches to a clean slate: macOS never reopens the previous
    /// session's document windows. Without this, a document restored from an earlier
    /// session — often from a workspace the user has since navigated away from — reappears
    /// as a lone tab, and because the tab bar only shows with 2+ tabs there is no tab UI to
    /// close it, so it feels "stuck." Starting clean means quit/relaunch opens a fresh
    /// untitled document instead. (The first-release migration side effects in
    /// `prepareForLaunch` are unrelated and preserved.)
    static func shouldRestoreApplicationState(defaults: UserDefaults = .standard) -> Bool {
        false
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
        ManualSaveIntentMonitor.installIfNeeded()
        MainMenuIconDecorator.installIfNeeded()
        MainMenuIconDecorator.dumpMainMenuIfRequested()
        // Announcement check: off the main thread, gated by the user's setting, and at
        // most once a day. Detached from launch on purpose — nothing about it blocks a
        // window appearing, and a slow or hung network must never delay the first frame.
        //
        // Skipped under XCTest: the test host IS the app, so without this guard every
        // `xcodebuild test` run issued a live request to the production feed. Store tests
        // drive `checkIfNeeded` directly with a fake fetcher, so coverage is unaffected.
        if !AnnouncementStore.isRunningUnderTests {
            Task {
                await AnnouncementStore.shared.checkIfNeeded(
                    isEnabled: LineformSettingsStore.shared.checksForAnnouncements
                )
            }
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

        let overlay = FirstLaunchIntroWindow(
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

/// The intro overlay's window.
///
/// A `.borderless` `NSWindow` answers `false` to `canBecomeKey`, so `makeKeyAndOrderFront` orders it
/// front without ever making it key: no key event reaches its content, and the Get Started button
/// could not be operated from the keyboard however well the view itself behaved. Full-keyboard-access
/// and Switch Control users drive the app through the same key-event path, so this is what makes the
/// overlay dismissable without a mouse at all.
final class FirstLaunchIntroWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        EditorMotionPolicy.animation(
                            .easeOut(duration: FirstLaunchIntroOverlayMetrics.startButtonRevealAnimationDuration),
                            reduceMotion: reduceMotion
                        ),
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

/// The overlay's only control. Hand-drawn rather than an `NSButton` because the intro art dictates
/// its shape, which means every affordance `NSButton` gives for free has to be supplied here:
/// keyboard focus, Space/Return activation, and an accessibility identity. Without them the intro
/// was a full-screen, screen-saver-level window that hid every other app window and could be
/// dismissed only by clicking a control VoiceOver could not find and the keyboard could not reach —
/// a first launch that no VoiceOver, keyboard-only, or Switch Control user could get out of.
final class FirstLaunchIntroStartButtonView: NSView {
    private let dismiss: () -> Void
    private let label = NSTextField(labelWithString: String(localized: "Get Started"))
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

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Get Started"))
        setAccessibilityHelp(String(localized: "Dismisses the welcome screen and opens a new document"))
        // The label is drawn text, not a child control: hide it so VoiceOver reports one button,
        // not a button containing a static text of the same name.
        label.setAccessibilityElement(false)
    }

    /// Keyboard focus. The overlay window is borderless with a single control, so this view is the
    /// whole key-view loop.
    override var acceptsFirstResponder: Bool { true }

    override var canBecomeKeyView: Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    /// Space and Return activate, matching a real push button. Handled in `keyDown` rather than
    /// through `insertNewline(_:)`: a plain `NSView` never routes its key events through
    /// `interpretKeyEvents`, so the command selectors are never sent. Escape is deliberately NOT
    /// wired to dismiss — leaving is the same decision as starting (it marks the intro complete and
    /// opens the first document), so it should be a deliberate press, not a reflex.
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\n", String(UnicodeScalar(NSEnterCharacter)!):
            dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        dismiss()
        return true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // Sized from `label.intrinsicContentSize`, not a fixed 112pt, so a longer localized
        // string (e.g. German) isn't clipped: it's clamped to the space between the label's
        // left inset and the arrow glyph, the same room the original fixed width assumed.
        let labelX: CGFloat = 30
        let maxLabelWidth = max(0, (bounds.width - 54) - 8 - labelX)
        let labelWidth = min(max(label.intrinsicContentSize.width, 112), maxLabelWidth)
        label.frame = NSRect(x: labelX, y: 18, width: labelWidth, height: 24)
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

        // The String Catalog cannot reach the bundled HTML, so its two user-facing strings are
        // injected at document-end via a user script. If encoding somehow fails, inject nothing:
        // the HTML's own English text is a safe fallback, and a crash here would be a crash at
        // first launch — the worst possible moment.
        if let script = Self.localizationUserScript() {
            configuration.userContentController.addUserScript(script)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false

        if let introURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "FirstLaunchIntro") {
            webView.loadFileURL(introURL, allowingReadAccessTo: introURL.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// Builds the script that hands the HTML page its two `data-l10n-id`-tagged strings.
    /// `nil` on encode failure — deliberately unwrapped nowhere in this path — so the caller
    /// falls back to the page's own English text rather than crashing first launch.
    private static func localizationUserScript() -> WKUserScript? {
        let l10n: [String: String] = [
            "tagline": String(localized: "Simple markdown editing"),
            "replay": String(localized: "Replay")
        ]
        guard
            let data = try? JSONEncoder().encode(l10n),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let source = """
        const l10n = \(json);
        document.querySelectorAll('[data-l10n-id]').forEach(el => {
            const value = l10n[el.getAttribute('data-l10n-id')];
            if (value) el.textContent = value;
        });
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let dismiss: () -> Void

        init(dismiss: @escaping () -> Void) {
            self.dismiss = dismiss
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "lineformIntro" {
                dismiss()
            }
        }

        // Defense-in-depth for a bundled, in-process web view: only the local file load is allowed
        // to navigate the overlay. A real web link opens in the user's browser; anything else is
        // blocked — bundled JS can never point this view at remote content.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.isFileURL {
                decisionHandler(.allow)
            } else {
                if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }
    }
}

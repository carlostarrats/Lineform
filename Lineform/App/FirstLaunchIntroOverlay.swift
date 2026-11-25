import AppKit
import LineformCore
import SwiftUI
import WebKit

@MainActor
enum LineformLaunchDefaults {
    enum DockReopenAction: Equatable {
        case deferToSystem
        case showFirstLaunchIntro
        case openUntitledDocument
    }

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

    // Lineform always launches to a clean slate: macOS never reopens the previous session's
    // document windows. This is enforced per window (`ChromeView` sets `isRestorable = false`),
    // NOT by a delegate hook: the `applicationShouldRestoreApplicationState` that used to sit
    // here is not an `NSApplicationDelegate` method on macOS, so it was never called and quit →
    // relaunch reopened the last document whenever macOS kept windows (2026-11-17).

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

    static func dockReopenAction(
        hasVisibleWindows: Bool,
        hasOpenDocuments: Bool,
        shouldShowIntro: Bool
    ) -> DockReopenAction {
        if shouldShowIntro {
            return .showFirstLaunchIntro
        }
        if hasVisibleWindows || hasOpenDocuments {
            return .deferToSystem
        }
        return .openUntitledDocument
    }
}

@MainActor
final class LineformAppDelegate: NSObject, NSApplicationDelegate {
    private static let coldLaunchDocumentDelay: TimeInterval = 0.25
    private let firstLaunchIntroPresenter = FirstLaunchIntroPresenter()

    func applicationWillFinishLaunching(_ notification: Notification) {
        LineformLaunchDefaults.prepareForLaunch()
        firstLaunchIntroPresenter.showIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coldLaunchDocumentDelay) { [firstLaunchIntroPresenter] in
            firstLaunchIntroPresenter.showIfNeeded()
            if !AnnouncementStore.isRunningUnderTests {
                firstLaunchIntroPresenter.openColdLaunchDocumentIfNeeded()
            }
            #if DEBUG
            // Checking the welcome card on its own, without the full-screen intro.
            if ProcessInfo.processInfo.environment["LINEFORM_SHOW_FIRST_LAUNCH_WELCOME"] == "1" {
                FirstLaunchWelcomePresenter.shared.showWhenWindowAppears()
            }
            #endif
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

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        switch LineformLaunchDefaults.dockReopenAction(
            hasVisibleWindows: flag,
            hasOpenDocuments: !NSDocumentController.shared.documents.isEmpty,
            shouldShowIntro: FirstLaunchIntroPresenter.shouldShowIntro
        ) {
        case .deferToSystem:
            return true
        case .showFirstLaunchIntro:
            firstLaunchIntroPresenter.showIfNeeded()
            return false
        case .openUntitledDocument:
            NSDocumentController.shared.newDocument(nil)
            return false
        }
    }
}

@MainActor
final class FirstLaunchIntroPresenter {
    private var window: NSWindow?
    private var hiddenAppWindows: [NSWindow] = []
    private var shouldOpenUntitledDocumentAfterDismiss = false
    private var shouldAllowNextUntitledDocumentOpen = false
    private var isDismissing = false

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

    /// Create Lineform's ordinary untitled editor after SwiftUI has installed its scenes. A
    /// file-open launch has registered its document by this point and the first-launch intro owns
    /// its own New transition.
    func openColdLaunchDocumentIfNeeded(
        hasOpenDocuments: Bool = !NSDocumentController.shared.documents.isEmpty,
        shouldShowIntro: Bool = FirstLaunchIntroPresenter.shouldShowIntro,
        openDocument: () -> Void = { NSDocumentController.shared.newDocument(nil) }
    ) {
        guard !hasOpenDocuments, !shouldShowIntro else { return }
        openDocument()
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
        // The overlay has both keyboard and pointer activation paths. Treat completion as a
        // one-shot transition so a double-click cannot enqueue a second new document while the
        // fade is still running.
        guard !isDismissing else {
            return
        }
        isDismissing = true
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
        // Use the document controller's normal New command. `openUntitledDocumentAndDisplay(false)`
        // creates a document without asking the DocumentGroup to present it, which can leave the
        // first-launch overlay gone but no editor window visible. The standard action is the same
        // route as File ▸ New and guarantees a DocumentGroup window is requested.
        NSDocumentController.shared.newDocument(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Then the "what you get" card over that first window (§32).
        FirstLaunchWelcomePresenter.shared.showWhenWindowAppears()
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

        let webView = FirstLaunchIntroArtworkWebView(frame: .zero, configuration: configuration)
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

/// The intro's artwork is bundled WebGL, not an interactive web surface. Let the native,
/// accessible Get Started control above it receive pointer input reliably on every macOS release.
/// In particular, a WKWebView's composited layer can otherwise win hit testing over a sibling
/// AppKit view even when SwiftUI places that sibling later in a ZStack.
private final class FirstLaunchIntroArtworkWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - First-launch welcome (§32)

/// The Mac's "what you get" modal (owner, 2026-11-24, §32; mockup `mac-first-launch.html`):
/// after the intro's Start, a small card over the first editor window. Step 1 lists the iPhone's
/// four points in its own styling (white tiles on the paper colour, the same symbols); step 2
/// offers the guide, with a note that it is always in Help ▸ Lineform Guide. The small wordmark
/// sits at the top of both steps, in the same place; each step is as tall as what it holds.
enum FirstLaunchWelcomeCopy {
    struct Point: Equatable {
        var symbol: String
        var title: String
        var text: String
    }

    static var points: [Point] {
        [
            Point(symbol: "lock",
                  title: String(localized: "Free and private"),
                  text: String(localized: "No account, nothing to sign up for. Your writing stays with you.")),
            Point(symbol: "icloud",
                  title: String(localized: "Real files, in iCloud"),
                  text: String(localized: "Plain Markdown files that sync with Lineform for iPhone and open anywhere.")),
            Point(symbol: "doc.richtext",
                  title: String(localized: "More than text"),
                  text: String(localized: "Images, tables, math and diagrams. Export styled PDFs in a click.")),
            Point(symbol: "accessibility",
                  title: String(localized: "Made to be read"),
                  text: String(localized: "Reading themes, accessible fonts and read aloud. AI only if you connect your own.")),
        ]
    }

    static var next: String { String(localized: "Next") }
    static var guideTitle: String { String(localized: "The Guide") }
    static var guideText: String { String(localized: "Everything Lineform can do, in one page.") }
    static var openGuide: String { String(localized: "Open the Guide") }
    static var notNow: String { String(localized: "Not now") }
    static var guideFootnote: String { String(localized: "You can find the guide anytime in Help ▸ Lineform Guide.") }
}

/// Puts the welcome card over the first editor window, once, and takes it away.
@MainActor
final class FirstLaunchWelcomePresenter {
    static let shared = FirstLaunchWelcomePresenter()

    private var host: NSView?

    /// Waits for the first editor window (the intro's New is asynchronous), then shows the card.
    func showWhenWindowAppears(attempt: Int = 0) {
        guard host == nil else { return }
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.windowController?.document != nil }) {
            show(over: window)
        } else if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.showWhenWindowAppears(attempt: attempt + 1)
            }
        }
    }

    private func show(over window: NSWindow) {
        // Above the window's own content (SwiftUI draws its content over views added inside it).
        guard let content = window.contentView?.superview ?? window.contentView else { return }
        let view = FirstLaunchWelcomeKeyHost(rootView: FirstLaunchWelcomeView(
            openGuide: { [weak self] in
                if let url = URL(string: LineformLinks.guideURL) { NSWorkspace.shared.open(url) }
                self?.close()
            },
            close: { [weak self] in self?.close() }
        ))
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        content.addSubview(view, positioned: .above, relativeTo: nil)
        host = view
        window.makeFirstResponder(view)
    }

    private func close() {
        guard let view = host else { return }
        host = nil
        let window = view.window
        view.removeFromSuperview()
        // Back to writing: the editor takes the keyboard again.
        if let window, let editor = Self.firstTextView(in: window.contentView) {
            window.makeFirstResponder(editor)
        }
    }

    private static func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.isEditable { return text }
        for sub in view.subviews { if let found = firstTextView(in: sub) { return found } }
        return nil
    }
}

/// The card's host takes the keyboard, so typing never reaches the page behind it while the card
/// is up; Return and Esc reach its buttons.
final class FirstLaunchWelcomeKeyHost: NSHostingView<FirstLaunchWelcomeView> {
    override var acceptsFirstResponder: Bool { true }
}

struct FirstLaunchWelcomeView: View {
    var openGuide: () -> Void
    var close: () -> Void

    @State private var step = 0

    // The iPhone first run's colours (`FirstRunOverlay`): the card is always light, as there.
    static let paper = Color(red: 0xF7 / 255, green: 0xF6 / 255, blue: 0xF0 / 255)
    static let ink = Color(red: 0x14 / 255, green: 0x13 / 255, blue: 0x10 / 255)
    static let secondaryInk = Color(red: 0x5C / 255, green: 0x5A / 255, blue: 0x54 / 255)
    static let blue = Color(red: 0x2F / 255, green: 0x6B / 255, blue: 0xDE / 255)
    static let quietFill = Color(red: 0xE8 / 255, green: 0xE6 / 255, blue: 0xDF / 255)
    static let cardWidth: CGFloat = 400

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
            card
        }
        .environment(\.colorScheme, .light)
    }

    private var card: some View {
        VStack(spacing: 0) {
            Image("LineformWordmark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(639.0 / 255.0, contentMode: .fit)
                .frame(width: 112)
                .foregroundStyle(Self.ink)
                .padding(.bottom, 24)
                .accessibilityLabel(Text(verbatim: "Lineform"))
            Group {
                if step == 0 { pointsStep } else { guideStep }
            }
            pager.padding(.top, 10)
        }
        .padding(.top, 26)
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .frame(width: Self.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Self.paper)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
        )
        .foregroundStyle(Self.ink)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var pointsStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(FirstLaunchWelcomeCopy.points, id: \.symbol) { point in
                    row(point)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                pill(FirstLaunchWelcomeCopy.next, primary: true) {
                    // Straight to step 2: a crossfade showed both steps over each other.
                    step = 1
                }
                .keyboardShortcut(.defaultAction)
                // Esc on step 1 skips the guide offer too: the writer wants to write.
                Button("", action: close).keyboardShortcut(.cancelAction).hidden().frame(width: 0, height: 0)
            }
            .padding(.top, 26)
        }
    }

    private var guideStep: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(FirstLaunchWelcomeCopy.guideTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(FirstLaunchWelcomeCopy.guideText)
                    .font(.system(size: 13))
                    .foregroundStyle(Self.secondaryInk)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            VStack(spacing: 8) {
                pill(FirstLaunchWelcomeCopy.openGuide, primary: true, action: openGuide)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityAddTraits(.isLink)
                pill(FirstLaunchWelcomeCopy.notNow, primary: false, action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 26)
            Text(FirstLaunchWelcomeCopy.guideFootnote)
                .font(.system(size: 11.5))
                .foregroundStyle(Self.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    private func row(_ point: FirstLaunchWelcomeCopy.Point) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: point.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(point.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(point.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Self.secondaryInk)
                    .lineSpacing(2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(primary ? Color.white : Self.ink)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(primary ? Self.blue : Self.quietFill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var pager: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .fill(index == step ? Color(red: 0x7A / 255, green: 0x77 / 255, blue: 0x6F / 255)
                                        : Color(red: 0xD2 / 255, green: 0xCF / 255, blue: 0xC7 / 255))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "Step \(step + 1) of 2")))
    }
}

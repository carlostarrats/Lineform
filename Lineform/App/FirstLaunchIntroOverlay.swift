import AppKit
import SwiftUI
import WebKit

@MainActor
final class LineformAppDelegate: NSObject, NSApplicationDelegate {
    private let firstLaunchIntroPresenter = FirstLaunchIntroPresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [firstLaunchIntroPresenter] in
            firstLaunchIntroPresenter.showIfNeeded()
        }
    }
}

@MainActor
final class FirstLaunchIntroPresenter {
    private enum Defaults {
        static let completedKey = "LineformFirstLaunchIntroCompleted"
        static let alwaysShowKey = "LineformAlwaysShowFirstLaunchIntro"
    }

    private var window: NSWindow?
    private var hiddenAppWindows: [NSWindow] = []

    func showIfNeeded() {
        let defaults = UserDefaults.standard
        let environmentForcesIntro = ProcessInfo.processInfo.environment["LINEFORM_SHOW_FIRST_LAUNCH_INTRO"] == "1"
        let defaultsForceIntro = defaults.bool(forKey: Defaults.alwaysShowKey)
        guard environmentForcesIntro || defaultsForceIntro || !defaults.bool(forKey: Defaults.completedKey) else {
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

        let hostingView = NSHostingView(rootView: FirstLaunchIntroWebView { [weak self] in
            self?.dismiss()
        })
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
        UserDefaults.standard.set(true, forKey: Defaults.completedKey)
        guard let window else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                window.orderOut(nil)
                self?.window = nil
                self?.restoreHiddenAppWindows()
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

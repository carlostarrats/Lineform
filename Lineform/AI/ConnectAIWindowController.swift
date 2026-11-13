import AppKit
import SwiftUI

/// Owns the one Connect Your AI window. Created on the first `show()`, never at launch, so
/// nothing about it runs until the writer opens it.
@MainActor
final class ConnectAIWindowController: NSWindowController {
    static let shared = ConnectAIWindowController()

    private static let contentSize = NSSize(width: 680, height: 460)
    private var hasCentered = false

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        let window = self.window ?? makeWindow()
        if !window.isVisible {
            // A fresh view per opening: typed keys never linger in a closed window, and the
            // missing-key check runs again on every opening.
            window.contentViewController = makeContent()
            window.setContentSize(Self.contentSize)
        }
        if !hasCentered {
            window.center()
            hasCentered = true
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = ConnectAIPresentation.windowTitle
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        self.window = window
        return window
    }

    private func makeContent() -> NSHostingController<ConnectAIView> {
        NSHostingController(rootView: ConnectAIView(store: .shared, onDone: { [weak self] in
            self?.close()
        }))
    }
}

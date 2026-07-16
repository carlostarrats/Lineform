import AppKit
import SwiftUI

/// Intercepts a document window's close so that multiple custom tabs are not lost when
/// only the active document is asked to save. If any tab besides the active one has unsaved
/// changes, a confirmation sheet blocks the close and lets the user cancel or discard.
@MainActor
final class WindowCloseController: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    weak var originalDelegate: NSWindowDelegate?
    weak var tabStore: EditorTabStore?
    weak var documentSaveStatus: DocumentSaveStatus?

    /// Returns true when the window is allowed to close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let tabStore, let documentSaveStatus else {
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        let dirtyTabs = tabStore.tabs.filter { tab in
            tab.id != tabStore.selectedTabID &&
                (!tab.document.text.isEmpty || documentSaveStatus.isDirty(documentID: tab.document.id, currentText: tab.document.text))
        }

        guard !dirtyTabs.isEmpty else {
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        let alert = NSAlert()
        alert.messageText = "Close Window?"
        alert.informativeText = "You have \(dirtyTabs.count) tab(s) with unsaved changes. Closing this window will discard those changes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Anyway")
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
        alert.alertStyle = .warning

        let shouldClose = alert.runModal() == .alertSecondButtonReturn
        return shouldClose
    }

    // MARK: - Delegate forwarding

    func windowWillClose(_ notification: Notification) {
        originalDelegate?.windowWillClose?(notification)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        originalDelegate?.windowDidBecomeKey?(notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        originalDelegate?.windowDidResignKey?(notification)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        originalDelegate?.windowDidBecomeMain?(notification)
    }

    func windowDidResignMain(_ notification: Notification) {
        originalDelegate?.windowDidResignMain?(notification)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        originalDelegate?.windowDidMiniaturize?(notification)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        originalDelegate?.windowDidDeminiaturize?(notification)
    }

    func windowDidResize(_ notification: Notification) {
        originalDelegate?.windowDidResize?(notification)
    }

    func windowDidMove(_ notification: Notification) {
        originalDelegate?.windowDidMove?(notification)
    }

    func windowDidUpdate(_ notification: Notification) {
        originalDelegate?.windowDidUpdate?(notification)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        originalDelegate?.windowWillEnterFullScreen?(notification)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        originalDelegate?.windowDidEnterFullScreen?(notification)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        originalDelegate?.windowWillExitFullScreen?(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        originalDelegate?.windowDidExitFullScreen?(notification)
    }
}

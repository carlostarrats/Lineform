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
    /// Set by the container. Invoked with the ids of every unsaved tab when the user chooses
    /// "Save All"; the container saves them in turn and then closes the window.
    var saveTabsAndClose: (([UUID]) -> Void)?

    /// Returns true when the window is allowed to close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let tabStore, let documentSaveStatus else {
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        // This includes the selected tab. Saved documents are represented by NSDocument's
        // native dirty state, but untitled tabs deliberately keep that state clear so typing
        // cannot trigger an automatic Save panel. DocumentTab is the one definition that covers
        // both without losing the close-time prompt.
        let dirtyTabs = tabStore.tabs.filter {
            $0.hasUnsavedWork(documentSaveStatus: documentSaveStatus)
        }

        guard !dirtyTabs.isEmpty else {
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Save changes before closing?")
        // "tab(s)" was an English-only dodge around pluralization; the catalog carries real
        // plural variations per language instead (and English finally reads "1 tab").
        alert.informativeText = String(localized: "This window has \(dirtyTabs.count) tabs with unsaved changes. Closing this window will discard those changes unless you save them.")
        // Save All is the default (Return); Cancel is Escape; Don't Save takes a deliberate click.
        alert.addButton(withTitle: String(localized: "Save All"))      // .alertFirstButtonReturn
        alert.addButton(withTitle: String(localized: "Cancel"))        // .alertSecondButtonReturn
        alert.addButton(withTitle: String(localized: "Don't Save"))    // .alertThirdButtonReturn
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.buttons[2].keyEquivalent = ""
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Save every unsaved tab (active included) then close. Returning false keeps the
            // window open now; the coordinator calls performClose once the saves succeed.
            let allDirtyIDs = tabStore.tabs
                .filter { $0.hasUnsavedWork(documentSaveStatus: documentSaveStatus) }
                .map(\.id)
            saveTabsAndClose?(allDirtyIDs)
            return false
        case .alertThirdButtonReturn:
            // Don't Save — discard and proceed with the normal close.
            // Clear the active NSDocument too, otherwise AppKit would immediately present its
            // own second sheet for a saved active tab after this controller's explicit choice.
            (sender.windowController?.document as? NSDocument)?.updateChangeCount(.changeCleared)
            return originalDelegate?.windowShouldClose?(sender) ?? true
        default:
            // Cancel — keep the window open.
            return false
        }
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

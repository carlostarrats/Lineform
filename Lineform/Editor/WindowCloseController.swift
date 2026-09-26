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
    /// The production presenter stays modal; hosted tests inject only the chosen response.
    var presentCloseAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
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

        switch presentCloseAlert(alert) {
        case .alertFirstButtonReturn:
            // Save every unsaved tab (active included) then close. Returning false keeps the
            // window open now; the coordinator calls performClose once the saves succeed.
            let allDirtyIDs = tabStore.tabs
                .filter { $0.hasUnsavedWork(documentSaveStatus: documentSaveStatus) }
                .map(\.id)
            // AppKit may ask this delegate from inside its serialized can-close activity.
            // Starting a save here waits for that activity to finish, which cannot happen until
            // we return false. Resume only after the native close attempt has unwound.
            DispatchQueue.main.async { [weak self] in
                self?.saveTabsAndClose?(allDirtyIDs)
            }
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

    /// The tab-level alert has already made the save/discard decision for the final tab. Keep that
    /// tab alive while SwiftUI closes its DocumentGroup window: removing it first tears down the
    /// scene state that the original delegate needs, producing a stuck or replacement blank window.
    func prepareForTabApprovedClose(_ sender: NSWindow) {
        (sender.windowController?.document as? NSDocument)?.updateChangeCount(.changeCleared)
        sender.delegate = originalDelegate
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

/// Runs an already-approved tab close after its SwiftUI alert has actually left the document
/// window. A button action runs while the sheet is still attached; a runloop delay alone does not
/// establish that it is gone on macOS 27. The observer is installed before checking the current
/// sheet state, so an end event cannot be missed between the check and subscription.
@MainActor
final class WindowSheetDismissalGate {
    private weak var window: NSWindow?
    private var completion: (() -> Void)?
    private var observer: NSObjectProtocol?

    init(window: NSWindow, completion: @escaping () -> Void) {
        self.window = window
        self.completion = completion
    }

    func start() {
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.finishIfReady() }
        }
        // The sheet can have ended before this gate was created (for example, when a hosted
        // test invokes the action directly). Always re-check after the alert action unwinds.
        DispatchQueue.main.async { [self] in finishIfReady() }
        // Never retain a view/document forever if AppKit never posts the sheet-end event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in cancel() }
    }

    private func finishIfReady() {
        guard let window, window.isVisible,
              window.attachedSheet == nil, window.sheets.isEmpty else { return }
        let action = completion
        cancel()
        action?()
    }

    private func cancel() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        completion = nil
    }
}

/// DocumentGroup may autosave an Untitled document as a draft in Lineform's iCloud Documents
/// folder. Destructive scene dismissal skips AppKit's ordinary Don't Save cleanup, and closing a
/// nonfinal tab reuses its NSDocument. In either case an explicit discard must remove only the
/// system-created draft, after AppKit has stopped owning that URL. A user-chosen file is never
/// eligible: its tab already has a fileURL, and the backing NSDocument is not a draft.
@MainActor
enum DiscardedDraftAutosave {
    private static var pendingWindowCloses: [ObjectIdentifier: (NSObjectProtocol, Set<URL>)] = [:]

    static func currentURLs(for tab: DocumentTab?, backingDocument: NSDocument?) -> Set<URL> {
        guard let tab, tab.fileURL == nil,
              let backingDocument, backingDocument.isDraft
        else { return [] }
        return Set([backingDocument.fileURL, backingDocument.autosavedContentsFileURL]
            .compactMap { $0?.isFileURL == true ? $0?.standardizedFileURL : nil })
    }

    static func urls(for tab: DocumentTab?, backingDocument: NSDocument?) -> Set<URL> {
        guard let tab, tab.fileURL == nil else { return [] }
        var urls = tab.draftAutosaveURLs
        urls.formUnion(currentURLs(for: tab, backingDocument: backingDocument))
        return urls
    }

    /// The next tab shares this NSDocument. Leave its native draft and recovery markers behind
    /// with the outgoing tab; otherwise a clean saved sibling inherits a draft save panel.
    static func detachNativeDraft(from document: NSDocument) {
        guard document.isDraft else { return }
        document.autosavedContentsFileURL = nil
        document.isDraft = false
    }

    static func removeAfterWindowCloses(_ urls: Set<URL>, window: NSWindow) {
        let key = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard let (observer, urls) = pendingWindowCloses.removeValue(forKey: key) else { return }
                NotificationCenter.default.removeObserver(observer)
                DispatchQueue.main.async { removeIfUnowned(urls) }
            }
        }
        pendingWindowCloses[key] = (observer, urls)
    }

    static func removeIfUnowned(_ urls: Set<URL>) {
        for url in urls {
            guard !NSDocumentController.shared.documents.contains(where: {
                $0.fileURL?.standardizedFileURL == url
            }) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // AppKit may have removed the draft itself when the scene closed.
            } catch {
                NSLog(String(localized: "Lineform could not remove discarded draft at %@: %@"), url.path, error.localizedDescription)
            }
        }
    }
}

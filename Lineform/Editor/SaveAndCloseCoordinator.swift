import AppKit
import SwiftUI

/// Coordinates a single Save-and-Close-Tab operation. Created for a specific tab and
/// window document, it triggers the save (or Save As for untitled documents) and closes
/// the tab only after the save succeeds. If the user cancels the save panel, the tab
/// stays open.
@MainActor
final class SaveAndCloseCoordinator: NSObject {
    private let targetID: UUID
    private let tabStore: EditorTabStore
    private weak var activeWindow: NSWindow?
    private let document: NSDocument
    /// Cleared when the save chain ends, so the view can drop its reference. Without it this
    /// coordinator — and the `NSDocument` and `EditorTabStore` it holds STRONGLY — stayed alive
    /// in the view's `@State` until the next Save-and-Close, keeping a closed tab's document
    /// from ever deallocating. `SaveTabsBeforeCloseCoordinator` already did this; the two were
    /// asymmetric for no reason.
    private var onFinish: (() -> Void)?

    init(
        targetID: UUID,
        tabStore: EditorTabStore,
        activeWindow: NSWindow?,
        document: NSDocument,
        onFinish: (() -> Void)? = nil
    ) {
        self.targetID = targetID
        self.tabStore = tabStore
        self.activeWindow = activeWindow
        self.document = document
        self.onFinish = onFinish
        super.init()
    }

    func start() {
        document.save(
            withDelegate: self,
            didSave: #selector(document(_:didSave:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        // A cancelled save panel leaves the tab open — and still ends the chain, so the
        // coordinator is released rather than lingering for a callback that will never come.
        defer { finish() }
        guard didSave else { return }
        tabStore.closeTab(id: targetID)
        if tabStore.tabs.isEmpty {
            activeWindow?.performClose(nil)
        }
    }

    private func finish() {
        let callback = onFinish
        onFinish = nil
        callback?()
    }
}

/// Saves a queue of tabs (each made the window's backing document in turn) before closing the
/// window. Used when the user chooses "Save All" in the close-window confirmation so unsaved
/// non-active tabs are written rather than discarded. If the user cancels a save panel (an
/// untitled tab), the loop stops and the window stays open — nothing is lost.
@MainActor
final class SaveTabsBeforeCloseCoordinator: NSObject {
    private var remaining: [UUID]
    /// The tab whose save is currently in flight, so `didSave` can write the URL AppKit just
    /// minted back into the store. The queue head is popped before the save starts, so it can't
    /// serve this purpose.
    private var savingID: UUID?
    /// Makes the tab the window's active/backing document and returns it (nil if unavailable).
    private let activateTab: (UUID) -> NSDocument?
    /// Records where a just-saved tab now lives. Required for a tab that was UNTITLED at save
    /// time: the save panel gives its `NSDocument` a fileURL, but the chain immediately activates
    /// the next tab, which overwrites `backingDocument.fileURL` before the view's async
    /// `currentFileURL` write-back can run. Without this the store keeps `fileURL == nil`, so the
    /// tab still counts as unsaved (re-prompting the close alert and opening a second save panel
    /// that writes a duplicate copy) and stays detached from its file for the rest of the session.
    private let didSaveTab: (UUID, URL?) -> Void
    private weak var window: NSWindow?
    /// Retains self for the async save chain; cleared when the chain finishes or aborts.
    private var onFinish: (() -> Void)?

    init(
        tabIDs: [UUID],
        activateTab: @escaping (UUID) -> NSDocument?,
        didSaveTab: @escaping (UUID, URL?) -> Void,
        window: NSWindow?,
        onFinish: @escaping () -> Void
    ) {
        self.remaining = tabIDs
        self.activateTab = activateTab
        self.didSaveTab = didSaveTab
        self.window = window
        self.onFinish = onFinish
        super.init()
    }

    func start() { saveNext() }

    private func saveNext() {
        guard let nextID = remaining.first else {
            // Everything saved — closing now re-runs windowShouldClose, which finds no unsaved
            // tabs and lets the window close normally.
            window?.performClose(nil)
            finish()
            return
        }
        remaining.removeFirst()
        guard let document = activateTab(nextID) else {
            saveNext()
            return
        }
        savingID = nextID
        document.save(
            withDelegate: self,
            didSave: #selector(document(_:didSave:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let savedID = savingID
        savingID = nil
        guard didSave else {
            // User cancelled a save panel — abort the close and leave the window open.
            finish()
            return
        }
        // Before activating the next tab, which clobbers `backingDocument.fileURL`.
        if let savedID {
            didSaveTab(savedID, document.fileURL)
        }
        saveNext()
    }

    private func finish() {
        let callback = onFinish
        onFinish = nil
        callback?()
    }
}

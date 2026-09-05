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
    private let closeSavedTab: (UUID) -> Void
    private let didSaveSource: () -> Void
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
        document: NSDocument,
        closeSavedTab: @escaping (UUID) -> Void,
        didSaveSource: @escaping () -> Void = {},
        onFinish: (() -> Void)? = nil
    ) {
        self.targetID = targetID
        self.tabStore = tabStore
        self.document = document
        self.closeSavedTab = closeSavedTab
        self.didSaveSource = didSaveSource
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
        guard didSave else {
            finish()
            return
        }
        didSaveSource()
        // AppKit still owns the save serialization activity while delivering this callback.
        // Closing synchronously waits on that same activity and deadlocks the main thread.
        // Let it unwind, then use the container's ordinary close path, which retains the final
        // tab until DocumentGroup dismisses the scene and activates a sibling for other closes.
        let savedURL = document.fileURL
        DispatchQueue.main.async { [self] in
            defer { finish() }
            tabStore.updateFileURL(savedURL, forTabID: targetID)
            closeSavedTab(targetID)
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
    private let didSaveSource: () -> Void
    private weak var window: NSWindow?
    /// Retains self for the async save chain; cleared when the chain finishes or aborts.
    private var onFinish: (() -> Void)?

    init(
        tabIDs: [UUID],
        activateTab: @escaping (UUID) -> NSDocument?,
        didSaveTab: @escaping (UUID, URL?) -> Void,
        didSaveSource: @escaping () -> Void = {},
        window: NSWindow?,
        onFinish: @escaping () -> Void
    ) {
        self.remaining = tabIDs
        self.activateTab = activateTab
        self.didSaveTab = didSaveTab
        self.didSaveSource = didSaveSource
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
        didSaveSource()
        // Before activating the next tab, which clobbers `backingDocument.fileURL`.
        if let savedID {
            didSaveTab(savedID, document.fileURL)
        }
        // Repointing/saving the same window document or closing its window from inside this
        // callback re-enters AppKit's still-active save serialization activity and can deadlock.
        DispatchQueue.main.async { [self] in saveNext() }
    }

    private func finish() {
        let callback = onFinish
        onFinish = nil
        callback?()
    }
}


/// Saves the window's document and, only on success, runs a continuation. Used by the sidebar
/// switch prompt: the save may present a panel (an untitled tab), so the thing that happens
/// "after saving" cannot be sequenced synchronously. A cancelled panel runs nothing.
@MainActor
final class SaveThenContinueCoordinator: NSObject {
    private let document: NSDocument
    private let onSaved: () -> Void
    private let didSaveSource: () -> Void
    /// Cleared when the chain ends so the view can drop its reference — this object holds the
    /// NSDocument strongly, the same leak `SaveAndCloseCoordinator` documents.
    private var onFinish: (() -> Void)?

    init(
        document: NSDocument,
        onSaved: @escaping () -> Void,
        didSaveSource: @escaping () -> Void = {},
        onFinish: (() -> Void)? = nil
    ) {
        self.document = document
        self.onSaved = onSaved
        self.didSaveSource = didSaveSource
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
        defer { finish() }
        guard didSave else { return }
        didSaveSource()
        onSaved()
    }

    private func finish() {
        let callback = onFinish
        onFinish = nil
        callback?()
    }
}

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

    init(
        targetID: UUID,
        tabStore: EditorTabStore,
        activeWindow: NSWindow?,
        document: NSDocument
    ) {
        self.targetID = targetID
        self.tabStore = tabStore
        self.activeWindow = activeWindow
        self.document = document
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
        guard didSave else { return }
        tabStore.closeTab(id: targetID)
        if tabStore.tabs.isEmpty {
            activeWindow?.performClose(nil)
        }
    }
}

/// Saves a queue of tabs (each made the window's backing document in turn) before closing the
/// window. Used when the user chooses "Save All" in the close-window confirmation so unsaved
/// non-active tabs are written rather than discarded. If the user cancels a save panel (an
/// untitled tab), the loop stops and the window stays open — nothing is lost.
@MainActor
final class SaveTabsBeforeCloseCoordinator: NSObject {
    private var remaining: [UUID]
    /// Makes the tab the window's active/backing document and returns it (nil if unavailable).
    private let activateTab: (UUID) -> NSDocument?
    private weak var window: NSWindow?
    /// Retains self for the async save chain; cleared when the chain finishes or aborts.
    private var onFinish: (() -> Void)?

    init(
        tabIDs: [UUID],
        activateTab: @escaping (UUID) -> NSDocument?,
        window: NSWindow?,
        onFinish: @escaping () -> Void
    ) {
        self.remaining = tabIDs
        self.activateTab = activateTab
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
        document.save(
            withDelegate: self,
            didSave: #selector(document(_:didSave:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didSave else {
            // User cancelled a save panel — abort the close and leave the window open.
            finish()
            return
        }
        saveNext()
    }

    private func finish() {
        let callback = onFinish
        onFinish = nil
        callback?()
    }
}

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

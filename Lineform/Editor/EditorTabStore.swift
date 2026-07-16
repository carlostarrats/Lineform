import Foundation
import SwiftUI

@MainActor
final class EditorTabStore: ObservableObject {
    @Published var tabs: [DocumentTab]
    @Published var selectedTabID: UUID?

    init(initialDocument: LineformDocument, fileURL: URL? = nil) {
        let tab = DocumentTab(document: initialDocument, fileURL: fileURL)
        tabs = [tab]
        selectedTabID = tab.id
    }

    var selectedTabIndex: Int? {
        guard let selectedTabID else { return nil }
        return tabs.firstIndex { $0.id == selectedTabID }
    }

    var selectedTab: DocumentTab? {
        guard let index = selectedTabIndex else { return nil }
        return tabs[index]
    }

    var tabCount: Int { tabs.count }

    var shouldShowTabBar: Bool { tabs.count > 1 }

    func tabIndex(for url: URL) -> Int? {
        let standardized = url.standardizedFileURL
        return tabs.firstIndex { $0.fileURL?.standardizedFileURL == standardized }
    }

    @discardableResult
    func openTab(document: LineformDocument, fileURL: URL? = nil, displayMode: EditorDisplayMode = .write) -> UUID {
        if let existingIndex = fileURL.flatMap({ tabIndex(for: $0) }) {
            selectedTabID = tabs[existingIndex].id
            return tabs[existingIndex].id
        }
        let tab = DocumentTab(document: document, fileURL: fileURL, displayMode: displayMode)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab.id
    }

    func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    func selectNextTab() {
        guard let index = selectedTabIndex, !tabs.isEmpty else { return }
        let nextIndex = (index + 1) % tabs.count
        selectedTabID = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard let index = selectedTabIndex, !tabs.isEmpty else { return }
        let prevIndex = (index - 1 + tabs.count) % tabs.count
        selectedTabID = tabs[prevIndex].id
    }

    @discardableResult
    func closeTab(id: UUID) -> DocumentTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tabs.remove(at: index)

        if tabs.isEmpty {
            selectedTabID = nil
        } else if id == selectedTabID {
            let newIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[newIndex].id
        }

        return removed
    }

    func updateActiveTab(document: LineformDocument) {
        guard let index = selectedTabIndex else { return }
        tabs[index].document = document
    }

    func updateActiveTabFileURL(_ url: URL?) {
        guard let index = selectedTabIndex else { return }
        tabs[index].fileURL = url
    }

    func updateActiveTabDisplayMode(_ mode: EditorDisplayMode) {
        guard let index = selectedTabIndex else { return }
        tabs[index].displayMode = mode
    }

    func snapshotActiveTab() {
        guard let index = selectedTabIndex else { return }
        tabs[index].document = currentDocumentProvider?() ?? tabs[index].document
        currentDisplayModeProvider.map { tabs[index].displayMode = $0() }
    }

    /// Updates the file URL for every tab whose URL matches (or lives under) the rename.
    func retargetFileURL(from source: URL, to destination: URL, isDirectory: Bool) {
        let sourcePath = source.standardizedFileURL.path
        let destPath = destination.standardizedFileURL.path
        for index in tabs.indices {
            guard let url = tabs[index].fileURL else { continue }
            let targetPath = url.standardizedFileURL.path
            if targetPath == sourcePath {
                tabs[index].fileURL = destination
            } else if isDirectory, targetPath.hasPrefix(sourcePath + "/") {
                let suffix = String(targetPath.dropFirst(sourcePath.count))
                tabs[index].fileURL = URL(fileURLWithPath: destPath + suffix)
            }
        }
    }

    /// Clears the file URL for every tab pointing at the deleted file.
    func markFileDeleted(_ url: URL) {
        let deletedPath = url.standardizedFileURL.path
        for index in tabs.indices {
            guard let tabURL = tabs[index].fileURL else { continue }
            if tabURL.standardizedFileURL.path == deletedPath {
                tabs[index].fileURL = nil
            }
        }
    }

    var currentDocumentProvider: (() -> LineformDocument)?
    var currentDisplayModeProvider: (() -> EditorDisplayMode)?
}

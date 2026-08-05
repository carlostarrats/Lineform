import Foundation

struct DocumentTab: Identifiable, Equatable {
    let id: UUID
    var document: LineformDocument
    var fileURL: URL?
    var displayMode: EditorDisplayMode

    init(document: LineformDocument, fileURL: URL? = nil, displayMode: EditorDisplayMode = .write) {
        id = document.id
        self.document = document
        self.fileURL = fileURL
        self.displayMode = displayMode
    }

    var title: String {
        guard let fileURL else { return String(localized: "Untitled") }
        return fileURL.lastPathComponent
    }

    static func == (lhs: DocumentTab, rhs: DocumentTab) -> Bool {
        lhs.id == rhs.id
            && lhs.document == rhs.document
            && lhs.fileURL == rhs.fileURL
            && lhs.displayMode == rhs.displayMode
    }

    /// True when closing or discarding this tab would lose work: the document has edits
    /// since its last save, OR it is an untitled document (no file on disk yet) that
    /// holds content. A clean, saved file — however large — is NOT unsaved work.
    ///
    /// This deliberately does NOT treat `!text.isEmpty` alone as dirty: every non-empty
    /// saved file has text, so an unconditional emptiness check would misclassify every
    /// real file as dirty — marking it edited on tab switch (triggering a needless autosave
    /// rewrite), showing a false dirty dot, and prompting "save changes?" on a clean file.
    @MainActor
    func hasUnsavedWork(documentSaveStatus: DocumentSaveStatus) -> Bool {
        if documentSaveStatus.isDirty(documentID: document.id, currentText: document.text) {
            return true
        }
        return fileURL == nil && !document.text.isEmpty
    }
}
